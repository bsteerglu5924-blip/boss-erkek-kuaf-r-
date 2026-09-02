-- ============ Gizli 2 oneriyi RANDEVU ALINIR ALINMAZ gonder ============
-- Onceki tasarim (20260903_style_suggestion_telegram.sql) fotograflari
-- SADECE appointments.status 'confirmed' olunca gonderiyordu. Salon bu
-- "onaylama" adimini fiilen kullanmiyor, randevular hep 'pending'
-- kaliyor — yani fotograflar hic gitmiyordu. Artik book_appointment
-- icinden, randevu olusturulur olusturulmaz dogrudan cagriliyor.

drop trigger if exists trg_notify_telegram_style_reveal on appointments;
drop function if exists public.notify_telegram_style_reveal();

create or replace function public.notify_telegram_style_reveal_now(
  p_appointment_id uuid,
  p_customer_name text
) returns void
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_token text;
  v_chat_id text;
  v_analysis record;
  v_rank1 jsonb;
  v_rank2 jsonb;
  v_caption_prefix text;
begin
  select * into v_analysis
  from style_analyses
  where appointment_id = p_appointment_id
    and status = 'completed'
    and delivered_to_barber = false
  limit 1;

  if v_analysis.id is null then
    return;
  end if;

  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into v_chat_id from vault.decrypted_secrets where name = 'telegram_chat_id';
  if v_token is null or v_chat_id is null then
    return;
  end if;

  -- Once kilitle (cifte gonderimi engellemek icin), sonra gonder.
  update style_analyses set delivered_to_barber = true, updated_at = now() where id = v_analysis.id;

  select r into v_rank1 from jsonb_array_elements(v_analysis.recommendations) r where (r->>'rank')::int = 1;
  select r into v_rank2 from jsonb_array_elements(v_analysis.recommendations) r where (r->>'rank')::int = 2;

  v_caption_prefix := '🔒 Gizli Öneri — Müşteri: ' || p_customer_name || E'\n';

  if v_rank1 is not null and (v_rank1->>'image_url') is not null then
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendPhoto',
      body := jsonb_build_object(
        'chat_id', v_chat_id,
        'photo', v_rank1->>'image_url',
        'caption', v_caption_prefix || '(1. sıra) ' || coalesce(v_rank1->>'style_name','') || E'\n' || coalesce(v_rank1->>'reason','')
      ),
      headers := jsonb_build_object('Content-Type', 'application/json')
    );
  end if;

  if v_rank2 is not null and (v_rank2->>'image_url') is not null then
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendPhoto',
      body := jsonb_build_object(
        'chat_id', v_chat_id,
        'photo', v_rank2->>'image_url',
        'caption', v_caption_prefix || '(2. sıra) ' || coalesce(v_rank2->>'style_name','') || E'\n' || coalesce(v_rank2->>'reason','')
      ),
      headers := jsonb_build_object('Content-Type', 'application/json')
    );
  end if;
end;
$$;

-- ============ book_appointment: reveal'i dogrudan cagir ============
create or replace function public.book_appointment(
  p_barber_id uuid,
  p_service_id uuid,
  p_starts_at timestamptz,
  p_customer_name text,
  p_customer_phone text,
  p_notes text default null,
  p_customer_email text default null,
  p_style_analysis_id uuid default null
) returns table (id uuid, starts_at timestamptz, ends_at timestamptz, status text)
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_duration int;
  v_ends_at timestamptz;
  v_barber_active boolean;
  v_new_id uuid;
  v_email text;
begin
  select b.active into v_barber_active from barbers b where b.id = p_barber_id;
  if v_barber_active is not true then
    raise exception 'BARBER_UNAVAILABLE' using errcode = 'P0001';
  end if;

  select s.duration_minutes into v_duration from services s where s.id = p_service_id and s.active = true;
  if v_duration is null then
    raise exception 'SERVICE_UNAVAILABLE' using errcode = 'P0001';
  end if;

  if not exists (
    select 1 from barber_services bs
    where bs.barber_id = p_barber_id and bs.service_id = p_service_id
  ) then
    raise exception 'SERVICE_UNAVAILABLE' using errcode = 'P0001';
  end if;

  if p_starts_at <= now() then
    raise exception 'SLOT_IN_PAST' using errcode = 'P0001';
  end if;

  if trim(coalesce(p_customer_name, '')) = '' or trim(coalesce(p_customer_phone, '')) = '' then
    raise exception 'MISSING_CUSTOMER_INFO' using errcode = 'P0001';
  end if;

  v_email := nullif(trim(lower(coalesce(p_customer_email, ''))), '');
  if v_email is not null and v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'INVALID_EMAIL' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_barber_id::text));

  v_ends_at := p_starts_at + make_interval(mins => v_duration);

  if exists (
    select 1 from blocked_times bt
    where bt.barber_id = p_barber_id
      and bt.during && tstzrange(p_starts_at, v_ends_at, '[)')
  ) then
    raise exception 'SLOT_UNAVAILABLE' using errcode = 'P0001';
  end if;

  begin
    insert into appointments (
      barber_id, service_id, starts_at, ends_at, service_duration_minutes,
      customer_name, customer_phone, customer_email, notes, status
    ) values (
      p_barber_id, p_service_id, p_starts_at, v_ends_at, v_duration,
      trim(p_customer_name), trim(p_customer_phone), v_email, p_notes, 'pending'
    ) returning appointments.id into v_new_id;
  exception when exclusion_violation then
    raise exception 'SLOT_UNAVAILABLE' using errcode = 'P0001';
  end;

  if p_style_analysis_id is not null then
    update style_analyses sa
    set appointment_id = v_new_id, updated_at = now()
    where sa.id = p_style_analysis_id
      and sa.appointment_id is null
      and sa.status = 'completed';

    -- Telegram gonderimi basarisiz olsa bile randevu olusturma islemi
    -- ETKILENMEMELI — bu yuzden ayri bir exception bloguna aliniyor.
    begin
      perform notify_telegram_style_reveal_now(v_new_id, trim(p_customer_name));
    exception when others then
      null;
    end;
  end if;

  return query
  select a.id, a.starts_at, a.ends_at, a.status from appointments a where a.id = v_new_id;
end;
$$;
