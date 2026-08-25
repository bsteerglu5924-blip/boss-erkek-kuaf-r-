-- ============ UYELIK: profiles + is_admin() ============
-- Musteri uyelik sistemi. auth.users her satiri icin bir public.profiles
-- satiri tutulur; is_admin bayragi admin panelini kimin kullanabilecegini
-- belirler. Bu migration'dan once 'authenticated' = 'admin' varsayimi
-- vardi (tum RLS politikalari using(true)) - bkz. 20260826_admin_role_rls.sql.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- ============ is_admin() ============
-- security definer sart: profiles uzerindeki RLS politikasi bu fonksiyonu
-- cagiracak, fonksiyon da profiles'a bakacak - security definer olmazsa
-- sonsuz ozyineleme / RLS kilitlenmesi olur.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
$$;

grant execute on function public.is_admin() to anon, authenticated;

-- ============ profiles RLS ============
create policy profiles_select_own on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or public.is_admin());

create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- INSERT politikasi yok - satirlar sadece handle_new_user() trigger'i ile olusur.

-- Kolon bazli grant: uye kendi is_admin alanini true yapamasin. RLS tek
-- basina bunu engelleyemez (WITH CHECK sadece id = auth.uid() kontrol eder,
-- hangi kolonun degistigini degil).
revoke update on public.profiles from authenticated;
grant update (full_name, phone) on public.profiles to authenticated;

-- ============ auth.users -> profiles otomatik satir ============
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'phone')
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============ mevcut kullanicilari admin isaretle ============
-- Bu migration'dan once var olan her auth.users satiri (admin.html'e
-- girebilen tek tur hesap) zaten fiilen admin idi. Bu adim olmadan
-- admin.html'e giris kilitlenir.
insert into public.profiles (id, full_name, is_admin)
select u.id, u.raw_user_meta_data->>'full_name', true
from auth.users u
on conflict (id) do update set is_admin = true;
