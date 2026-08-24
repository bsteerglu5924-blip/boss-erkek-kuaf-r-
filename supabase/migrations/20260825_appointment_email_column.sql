-- ============ MUSTERI E-POSTA ALANI ============
-- Randevu hatirlatma maili gonderebilmek icin opsiyonel e-posta kolonu.
-- Nullable: telefon/WhatsApp uzerinden gelen akis aynen calismaya devam eder.

alter table appointments add column if not exists customer_email text;

alter table appointments
  add constraint appointments_customer_email_format
  check (customer_email is null or customer_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

-- book_appointment imzasi degisiyor: eski 6 parametreli surum drop edilmeli,
-- yoksa PostgREST "could not choose the best candidate function" hatasi verir.
drop function if exists public.book_appointment(uuid, uuid, timestamptz, text, text, text);

create or replace function public.book_appointment(
  p_barber_id uuid,
  p_service_id uuid,
  p_starts_at timestamptz,
  p_customer_name text,
  p_customer_phone text,
  p_notes text default null,
  p_customer_email text default null
) returns table (id uuid, starts_at timestamptz, ends_at timestamptz, status text)
language plpgsql
security definer
set search_path = public, pg_temp
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

  if p_starts_at <= now() then
    raise exception 'SLOT_IN_PAST' using errcode = 'P0001';
  end if;

  if trim(coalesce(p_customer_name, '')) = '' or trim(coalesce(p_customer_phone, '')) = '' then
    raise exception 'MISSING_CUSTOMER_INFO' using errcode = 'P0001';
  end if;

  -- E-posta opsiyonel; dolu ise formati gecerli olmali.
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

  return query
  select a.id, a.starts_at, a.ends_at, a.status from appointments a where a.id = v_new_id;
end;
$$;

grant execute on function public.book_appointment(uuid, uuid, timestamptz, text, text, text, text) to anon, authenticated, service_role;
