-- ============ BARBER_SERVICES ============
-- Hangi berberin hangi hizmeti verebildigini tanimlar. Bos birakilan
-- (barber, service) kombinasyonu rezervasyon akisinda hic gorunmez ve
-- book_appointment/get_available_slots tarafindan da reddedilir.
create table barber_services (
  barber_id uuid not null references barbers(id) on delete cascade,
  service_id uuid not null references services(id) on delete cascade,
  primary key (barber_id, service_id)
);

alter table barber_services enable row level security;

create policy barber_services_public_read on barber_services
  for select to anon, authenticated using (true);

create policy barber_services_admin_all on barber_services
  for all to authenticated using (true) with check (true);

-- ============ get_available_slots: berber-hizmet uyumu kontrolu ============
create or replace function public.get_available_slots(
  p_barber_id uuid,
  p_service_id uuid,
  p_date date
) returns table (slot_start timestamptz, slot_end timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_duration int;
  v_open timestamptz;
  v_close timestamptz;
  v_now timestamptz := now();
begin
  if not exists (
    select 1 from barber_services bs
    where bs.barber_id = p_barber_id and bs.service_id = p_service_id
  ) then
    return;
  end if;

  select duration_minutes into v_duration
  from services
  where id = p_service_id and active = true;

  if v_duration is null then
    return;
  end if;

  v_open := (p_date::text || ' 08:30')::timestamp at time zone 'Europe/Istanbul';
  v_close := (p_date::text || ' 20:30')::timestamp at time zone 'Europe/Istanbul';

  return query
  select gs as slot_start, gs + make_interval(mins => v_duration) as slot_end
  from generate_series(v_open, v_close - make_interval(mins => v_duration), interval '15 minutes') as gs
  where gs + make_interval(mins => v_duration) > v_now
    and not exists (
      select 1 from appointments a
      where a.barber_id = p_barber_id
        and a.status in ('pending','confirmed')
        and a.during && tstzrange(gs, gs + make_interval(mins => v_duration), '[)')
    )
    and not exists (
      select 1 from blocked_times b
      where b.barber_id = p_barber_id
        and b.during && tstzrange(gs, gs + make_interval(mins => v_duration), '[)')
    );
end;
$$;

-- ============ book_appointment: berber-hizmet uyumu kontrolu ============
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
