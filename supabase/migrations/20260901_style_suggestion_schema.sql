-- ============ "BANA NE YAKIŞIR?" ŞEMA ============
-- Musteri 3 fotograf yukler, AI (Claude vision, ayri bir Edge Function
-- icinde) style_catalog'dan 3 stil secip siralar. Musteriye SADECE rank=3
-- gosterilir; rank=1/2 gizli kalir ve randevu onaylaninca Telegram'a gider
-- (bkz. 20260903_style_suggestion_telegram.sql). Bu dosyada sema, RLS,
-- storage bucket ve erisim RPC'leri var.

-- ============ STYLE_CATALOG ============
-- Kucuk, elle yonetilen bir referans stil listesi. Gorseller fal.ai/
-- Higgsfield ile tek tek uretilip statik dosya olarak siteye eklenir,
-- image_url TAM https URL olarak (Telegram sendPhoto URL'den ceker).
create table style_catalog (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  image_url text not null,
  look_type text not null check (look_type in ('hair','beard','hair_and_beard')),
  tags text[] not null default '{}',
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table style_catalog enable row level security;

-- appointments/blocked_times ile ayni desen: public policy yok, sadece
-- admin ve service-role (Edge Function) erisir.
create policy style_catalog_admin_all on style_catalog
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ============ STYLE_ANALYSES ============
create table style_analyses (
  id uuid primary key default gen_random_uuid(),
  status text not null default 'pending' check (status in ('pending','processing','completed','failed')),
  consent boolean not null default false check (consent = true),
  photo_front_path text,
  photo_side_path text,
  photo_back_path text,
  recommendations jsonb,
  error_message text,
  appointment_id uuid references appointments(id) on delete set null,
  delivered_to_barber boolean not null default false,
  ip_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_style_analyses_appointment on style_analyses (appointment_id);

alter table style_analyses enable row level security;
-- Tamamen kilitli (appointments/blocked_times deseni) — erisim sadece
-- asagidaki SECURITY DEFINER RPC'ler uzerinden.
create policy style_analyses_admin_all on style_analyses
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ============ STORAGE BUCKET (private) ============
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('style-photos', 'style-photos', false, 8388608, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- Musteri (anon/authenticated) yukleyebilir ama okuyamaz; sadece
-- service-role (Edge Function) okur.
create policy style_photos_insert on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'style-photos');

-- ============ create_style_analysis ============
create or replace function public.create_style_analysis(p_consent boolean)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_consent is not true then
    raise exception 'CONSENT_REQUIRED' using errcode = 'P0001';
  end if;

  insert into style_analyses (consent, status)
  values (true, 'pending')
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.create_style_analysis(boolean) to anon, authenticated;

-- ============ attach_style_analysis_photos ============
create or replace function public.attach_style_analysis_photos(
  p_analysis_id uuid,
  p_photo_front_path text,
  p_photo_side_path text,
  p_photo_back_path text
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prefix text := p_analysis_id::text || '/';
  v_status text;
begin
  select status into v_status from style_analyses where id = p_analysis_id;
  if v_status is null then
    raise exception 'ANALYSIS_NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_status <> 'pending' then
    raise exception 'ANALYSIS_NOT_PENDING' using errcode = 'P0001';
  end if;

  if left(p_photo_front_path, length(v_prefix)) <> v_prefix
    or left(p_photo_side_path, length(v_prefix)) <> v_prefix
    or left(p_photo_back_path, length(v_prefix)) <> v_prefix
  then
    raise exception 'INVALID_PHOTO_PATH' using errcode = 'P0001';
  end if;

  update style_analyses set
    photo_front_path = p_photo_front_path,
    photo_side_path = p_photo_side_path,
    photo_back_path = p_photo_back_path,
    updated_at = now()
  where id = p_analysis_id;
end;
$$;

grant execute on function public.attach_style_analysis_photos(uuid, text, text, text) to anon, authenticated;

-- ============ get_style_analysis_reveal ============
-- KRITIK: bu fonksiyon hicbir dalda rank=1/2 dondurmemeli, sadece rank=3.
create or replace function public.get_style_analysis_reveal(p_analysis_id uuid)
returns table (status text, style_name text, description text, image_url text, reason text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_reveal jsonb;
begin
  select sa.status into v_status from style_analyses sa where sa.id = p_analysis_id;

  if v_status is null then
    return;
  end if;

  if v_status <> 'completed' then
    return query select v_status, null::text, null::text, null::text, null::text;
    return;
  end if;

  select r into v_reveal
  from style_analyses sa, jsonb_array_elements(sa.recommendations) r
  where sa.id = p_analysis_id and (r->>'rank')::int = 3;

  return query select
    v_status,
    v_reveal->>'style_name',
    v_reveal->>'description',
    v_reveal->>'image_url',
    v_reveal->>'reason';
end;
$$;

grant execute on function public.get_style_analysis_reveal(uuid) to anon, authenticated;
