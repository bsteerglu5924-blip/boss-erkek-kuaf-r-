-- ============ "SAÇINI DENE" — AI PROTEZ SAÇ SİMÜLASYONU ============
-- Musteri kendi fotografini yukler, bir saç modeli secer; Edge Function
-- (hair-tryon) fal.ai goruntu duzenleme modeliyle yuzu degistirmeden sadece
-- sac bolgesini uretir. Musteri beğendigi gorunumu secip randevu alir; secim,
-- orijinal foto ve AI gorseli admin panelinde ve Telegram'da gorunur.
--
-- Tamamen EKLEMELI bir migration: mevcut tablo/fonksiyonlara dokunmaz.
-- Erisim deseni mevcut sema ile ayni: tablolar kilitli (sadece admin),
-- musteri islemleri SECURITY DEFINER RPC'ler uzerinden.

-- ============ HAIR_LOOKS (model katalogu) ============
create table public.hair_looks (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  description text,
  -- Modele giden Ingilizce stil tarifi (musteriye gosterilmez).
  prompt text not null,
  thumb_url text,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.hair_looks enable row level security;
create policy hair_looks_admin_all on public.hair_looks
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into public.hair_looks (slug, name, description, prompt, thumb_url, sort_order) values
  ('klasik-yandan-ayrik', 'Klasik Yandan Ayrık',
   'Zamansız, düzgün ve bakımlı klasik erkek saçı.',
   'a classic side-parted men''s haircut: short tapered sides, neatly combed top with a clean, defined natural side part, medium-short length on top',
   'stil-klasik-taramali.jpg', 10),
  ('geri-taranmis', 'Geri Taranmış',
   'Güçlü ve şık, tamamen geriye taranmış görünüm.',
   'slicked-back hair: top combed straight back with a light natural sheen, tapered sides, tidy and masculine',
   'stil-taramali-sakal.jpg', 20),
  ('kisa-fade', 'Kısa Fade',
   'Yanlar kısa fade, üstte kısa dokulu kesim. Modern ve pratik.',
   'a short modern textured crop on top (about 3 cm) with a clean mid skin-fade on the sides and back',
   'stil-fade-sakal.jpg', 30),
  ('pompadour', 'Pompadour',
   'Önde hacimli, yukarı ve geriye şekillenmiş iddialı model.',
   'a voluminous pompadour: height and volume at the front swept up and back, short faded sides, polished finish',
   'stil-pompadour.jpg', 40),
  ('dogal-dalgali', 'Doğal Dalgalı (Orta Boy)',
   'Orta uzunlukta, doğal dalgalı ve hareketli saç.',
   'medium-length natural wavy hair with soft movement and texture on top, tapered neat sides',
   'stil-dogal-dalgali.jpg', 50);

-- ============ HAIR_TRYONS (bir musteri denemesi = 1 foto) ============
create table public.hair_tryons (
  id uuid primary key default gen_random_uuid(),
  consent boolean not null default false check (consent = true),
  photo_path text,
  selected_result_id uuid,
  appointment_id uuid references public.appointments(id) on delete set null,
  delivered_to_barber boolean not null default false,
  ip_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_hair_tryons_appointment on public.hair_tryons (appointment_id);
create index idx_hair_tryons_created on public.hair_tryons (created_at desc);

alter table public.hair_tryons enable row level security;
create policy hair_tryons_admin_all on public.hair_tryons
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ============ HAIR_TRYON_RESULTS (uretilen her AI gorsel) ============
create table public.hair_tryon_results (
  id uuid primary key default gen_random_uuid(),
  tryon_id uuid not null references public.hair_tryons(id) on delete cascade,
  look_id uuid references public.hair_looks(id) on delete set null,
  look_name text not null,
  density text not null default 'natural' check (density in ('light','natural','full')),
  status text not null default 'processing' check (status in ('processing','completed','failed')),
  image_path text,
  error_message text,
  ip_hash text,
  created_at timestamptz not null default now()
);

create index idx_hair_results_tryon on public.hair_tryon_results (tryon_id);
create index idx_hair_results_ip_day on public.hair_tryon_results (ip_hash, created_at);

alter table public.hair_tryon_results enable row level security;
create policy hair_results_admin_all on public.hair_tryon_results
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

alter table public.hair_tryons
  add constraint hair_tryons_selected_result_fk
  foreign key (selected_result_id) references public.hair_tryon_results(id) on delete set null;

-- ============ STORAGE (private bucketlar) ============
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('tryon-photos',  'tryon-photos',  false, 8388608, array['image/jpeg','image/png','image/webp']),
  ('tryon-results', 'tryon-results', false, 8388608, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- Musteri yukleyebilir ama okuyamaz; Edge Function (service-role) okur/yazar.
create policy tryon_photos_insert on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'tryon-photos');

-- Admin panelinin signed URL uretebilmesi icin okuma.
create policy tryon_admin_read on storage.objects
  for select to authenticated
  using (bucket_id in ('tryon-photos','tryon-results') and public.is_admin());

-- ============ RPC: katalog (musteriye acik, prompt HARIC) ============
create or replace function public.get_hair_looks()
returns table (id uuid, name text, description text, thumb_url text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select l.id, l.name, l.description, l.thumb_url
  from hair_looks l
  where l.active = true
  order by l.sort_order, l.name;
$$;
grant execute on function public.get_hair_looks() to anon, authenticated;

-- ============ RPC: deneme olustur ============
create or replace function public.create_hair_tryon(p_consent boolean)
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
  insert into hair_tryons (consent) values (true) returning id into v_id;
  return v_id;
end;
$$;
grant execute on function public.create_hair_tryon(boolean) to anon, authenticated;

-- ============ RPC: foto bagla (tek seferlik) ============
create or replace function public.attach_hair_tryon_photo(p_tryon_id uuid, p_photo_path text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_existing text;
  v_found boolean;
begin
  select (t.id is not null), t.photo_path into v_found, v_existing
  from hair_tryons t where t.id = p_tryon_id;
  if v_found is not true then
    raise exception 'TRYON_NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_existing is not null then
    raise exception 'PHOTO_ALREADY_ATTACHED' using errcode = 'P0001';
  end if;
  if left(p_photo_path, length(p_tryon_id::text) + 1) <> p_tryon_id::text || '/' then
    raise exception 'INVALID_PHOTO_PATH' using errcode = 'P0001';
  end if;
  update hair_tryons set photo_path = p_photo_path, updated_at = now() where id = p_tryon_id;
end;
$$;
grant execute on function public.attach_hair_tryon_photo(uuid, text) to anon, authenticated;

-- ============ RPC: "Bu görünümü istiyorum" — secimi kaydet ============
create or replace function public.select_hair_result(p_tryon_id uuid, p_result_id uuid)
returns table (look_name text, density text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_res record;
begin
  select r.* into v_res
  from hair_tryon_results r
  where r.id = p_result_id and r.tryon_id = p_tryon_id and r.status = 'completed';
  if v_res.id is null then
    raise exception 'RESULT_NOT_FOUND' using errcode = 'P0001';
  end if;

  -- Randevuya baglandiktan sonra secim degistirilemez.
  update hair_tryons
  set selected_result_id = p_result_id, updated_at = now()
  where id = p_tryon_id and appointment_id is null;
  if not found then
    raise exception 'TRYON_LOCKED' using errcode = 'P0001';
  end if;

  return query select v_res.look_name, v_res.density;
end;
$$;
grant execute on function public.select_hair_result(uuid, uuid) to anon, authenticated;

-- ============ RPC (sadece service-role): randevuya bagla ============
create or replace function public.link_hair_tryon_to_appointment(p_tryon_id uuid, p_appointment_id uuid)
returns table (
  customer_name text, look_name text, density text,
  original_path text, result_path text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t record;
  v_r record;
  v_a record;
begin
  select * into v_t from hair_tryons where id = p_tryon_id;
  if v_t.id is null or v_t.selected_result_id is null then
    raise exception 'TRYON_NOT_READY' using errcode = 'P0001';
  end if;
  if v_t.appointment_id is not null then
    raise exception 'ALREADY_LINKED' using errcode = 'P0001';
  end if;

  -- Sadece az once olusturulmus bir randevuya baglanabilir.
  select a.id, a.customer_name into v_a
  from appointments a
  where a.id = p_appointment_id and a.created_at > now() - interval '2 hours';
  if v_a.id is null then
    raise exception 'APPOINTMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  select * into v_r from hair_tryon_results where id = v_t.selected_result_id;

  update hair_tryons
  set appointment_id = p_appointment_id, updated_at = now()
  where id = p_tryon_id;

  return query select v_a.customer_name, v_r.look_name, v_r.density, v_t.photo_path, v_r.image_path;
end;
$$;
revoke execute on function public.link_hair_tryon_to_appointment(uuid, uuid) from public, anon, authenticated;
grant execute on function public.link_hair_tryon_to_appointment(uuid, uuid) to service_role;

-- ============ RPC (sadece service-role): Telegram bildirimi ============
create or replace function public.notify_telegram_hair_tryon(
  p_tryon_id uuid,
  p_original_url text,
  p_result_url text,
  p_caption text
) returns void
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_token text;
  v_chat_id text;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into v_chat_id from vault.decrypted_secrets where name = 'telegram_chat_id';
  if v_token is null or v_chat_id is null then
    return;
  end if;

  update hair_tryons set delivered_to_barber = true, updated_at = now()
  where id = p_tryon_id and delivered_to_barber = false;
  if not found then
    return;
  end if;

  -- "Soguk baglanti" zaman asimi icin isinma istegi (bkz. telegram_connection_warmup).
  perform net.http_get(
    url := 'https://api.telegram.org/bot' || v_token || '/getMe',
    timeout_milliseconds := 15000
  );

  perform net.http_post(
    url := 'https://api.telegram.org/bot' || v_token || '/sendPhoto',
    body := jsonb_build_object('chat_id', v_chat_id, 'photo', p_original_url, 'caption', '📷 Önce — ' || p_caption),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 15000
  );
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || v_token || '/sendPhoto',
    body := jsonb_build_object('chat_id', v_chat_id, 'photo', p_result_url, 'caption', '✨ AI sonrası — ' || p_caption),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 15000
  );
end;
$$;
revoke execute on function public.notify_telegram_hair_tryon(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.notify_telegram_hair_tryon(uuid, text, text, text) to service_role;

-- ============ RPC (sadece admin): panel listesi ============
create or replace function public.admin_hair_tryons(p_limit int default 40)
returns table (
  tryon_id uuid,
  created_at timestamptz,
  photo_path text,
  appointment_id uuid,
  customer_name text,
  customer_phone text,
  selected_look text,
  selected_density text,
  selected_image_path text,
  result_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
  select t.id, t.created_at, t.photo_path, t.appointment_id,
         a.customer_name, a.customer_phone,
         sr.look_name, sr.density, sr.image_path,
         (select count(*) from hair_tryon_results r where r.tryon_id = t.id and r.status = 'completed')
  from hair_tryons t
  left join appointments a on a.id = t.appointment_id
  left join hair_tryon_results sr on sr.id = t.selected_result_id
  where t.photo_path is not null
  order by t.created_at desc
  limit least(coalesce(p_limit, 40), 200);
end;
$$;
revoke execute on function public.admin_hair_tryons(int) from public, anon;
grant execute on function public.admin_hair_tryons(int) to authenticated;
