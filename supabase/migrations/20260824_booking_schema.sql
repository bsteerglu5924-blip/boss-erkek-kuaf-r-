-- Extension for exclusion constraint on uuid + range (kept out of public schema)
create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;

-- ============ BARBERS ============
create table barbers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  title text,
  photo_url text,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ============ SERVICES ============
create table services (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  description text,
  duration_minutes int not null check (duration_minutes > 0),
  price_try numeric(10,2),
  price_is_final boolean not null default false,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ============ APPOINTMENTS ============
create table appointments (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references barbers(id),
  service_id uuid not null references services(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  service_duration_minutes int not null,
  customer_name text not null,
  customer_phone text not null,
  status text not null default 'pending' check (status in ('pending','confirmed','completed','cancelled','no_show')),
  notes text,
  created_at timestamptz not null default now(),
  during tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,
  constraint appointments_time_order check (ends_at > starts_at)
);

alter table appointments
  add constraint appointments_no_overlap
  exclude using gist (barber_id with =, during with &&)
  where (status in ('pending','confirmed'));

create index idx_appointments_barber_starts on appointments (barber_id, starts_at);

-- ============ BLOCKED TIMES ============
create table blocked_times (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references barbers(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text,
  created_at timestamptz not null default now(),
  during tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,
  constraint blocked_times_time_order check (ends_at > starts_at)
);

create index idx_blocked_times_barber_starts on blocked_times (barber_id, starts_at);

-- ============ RLS ============
alter table barbers enable row level security;
alter table services enable row level security;
alter table appointments enable row level security;
alter table blocked_times enable row level security;

create policy barbers_public_read on barbers for select to anon, authenticated using (active = true);
create policy barbers_admin_all on barbers for all to authenticated using (true) with check (true);

create policy services_public_read on services for select to anon, authenticated using (active = true);
create policy services_admin_all on services for all to authenticated using (true) with check (true);

-- appointments/blocked_times: no anon policies at all -> anon fully denied, access only via SECURITY DEFINER RPCs
create policy appointments_admin_all on appointments for all to authenticated using (true) with check (true);
create policy blocked_times_admin_all on blocked_times for all to authenticated using (true) with check (true);

-- ============ get_available_slots ============
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

grant execute on function public.get_available_slots(uuid, uuid, date) to anon, authenticated;

-- ============ book_appointment ============
create or replace function public.book_appointment(
  p_barber_id uuid,
  p_service_id uuid,
  p_starts_at timestamptz,
  p_customer_name text,
  p_customer_phone text,
  p_notes text default null
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
      customer_name, customer_phone, notes, status
    ) values (
      p_barber_id, p_service_id, p_starts_at, v_ends_at, v_duration,
      trim(p_customer_name), trim(p_customer_phone), p_notes, 'pending'
    ) returning appointments.id into v_new_id;
  exception when exclusion_violation then
    raise exception 'SLOT_UNAVAILABLE' using errcode = 'P0001';
  end;

  return query
  select a.id, a.starts_at, a.ends_at, a.status from appointments a where a.id = v_new_id;
end;
$$;

grant execute on function public.book_appointment(uuid, uuid, timestamptz, text, text, text) to anon, authenticated;
