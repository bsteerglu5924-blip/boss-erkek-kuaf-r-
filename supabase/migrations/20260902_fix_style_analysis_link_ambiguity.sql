-- ============ book_appointment: "column reference id is ambiguous" duzeltmesi ============
-- returns table(id uuid, ...) ciktisi PL/pgSQL icinde "id" adinda bir
-- degisken gibi davraniyor; bare "id" kullanan UPDATE ... WHERE id = ...
-- bu yuzden style_analyses.id ile karisip hata veriyordu. Stil analizi
-- yapmis biri randevu almaya calistiginda TUM islem (randevu dahil)
-- basarisiz oluyordu. Sutun referansi tabloya nitelikli hale getirildi.
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
  end if;

  return query
  select a.id, a.starts_at, a.ends_at, a.status from appointments a where a.id = v_new_id;
end;
$$;
