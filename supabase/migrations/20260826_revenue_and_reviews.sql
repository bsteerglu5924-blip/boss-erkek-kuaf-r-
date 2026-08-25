-- ============ CIRO: appointments.charged_price_try ============
-- Ciro hesaplanabilmesi icin randevu basina "gercekte tahsil edilen"
-- tutar tutulur. Sabit fiyatli hizmetlerde randevu olusturulurken
-- otomatik dolar (asagidaki trigger); fiyat_note'lu (degisken fiyatli)
-- hizmetlerde ve indirim/istisna durumlarinda admin randevuyu
-- tamamlandi olarak isaretlerken elle girer/duzeltir.

alter table appointments add column charged_price_try numeric(10,2);

create or replace function public.set_appointment_charged_price()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.charged_price_try is null then
    select s.price_try into new.charged_price_try
    from services s
    where s.id = new.service_id and s.price_is_final = true;
  end if;
  return new;
end;
$$;

create trigger trg_set_appointment_charged_price
  before insert on appointments
  for each row execute function public.set_appointment_charged_price();

-- ============ REVIEWS (musteri yorumlari) ============
-- Spam'i onlemek ve gercek musteriler oldugundan emin olmak icin yorum
-- birakmak uyelik (auth) gerektirir. customer_name yorum aninda
-- profilden kopyalanip donduruluyor (denormalize) - cunku anon/diger
-- musteriler baskasinin profiles satirini okuyamaz (bkz. profiles RLS),
-- public yorum listesinde isim gostermek icin join yapilamaz.

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete set null,
  customer_name text not null,
  rating smallint not null check (rating between 1 and 5),
  comment text not null check (char_length(trim(comment)) > 0),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);

-- Musteri basina tek yorum: duzenleme var, tekrar tekrar ekleme yok.
create unique index reviews_one_per_profile on public.reviews (profile_id) where profile_id is not null;

alter table public.reviews enable row level security;

create policy reviews_public_read_approved on public.reviews
  for select to anon, authenticated
  using (status = 'approved');

create policy reviews_insert_own on public.reviews
  for insert to authenticated
  with check (profile_id = (select auth.uid()));

create policy reviews_admin_all on public.reviews
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Musteri kendi yorumunu (henuz onaylanmamis/reddedilmis olsa bile)
-- gorebilsin - form bunu "duzenle" moduna gecirmek icin kullanacak.
create policy reviews_select_own on public.reviews
  for select to authenticated
  using (profile_id = (select auth.uid()));

-- Musteri kendi yorumunu duzenleyebilsin ama sadece rating/comment -
-- status kolonuna yazma yetkisi yok (moderasyonu kendi kendine
-- onaylayamasin), bkz. asagidaki column-level grant.
create policy reviews_update_own on public.reviews
  for update to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

revoke update on public.reviews from authenticated;
grant update (rating, comment) on public.reviews to authenticated;

-- Yorum duzenlenince (rating/comment degisirse) tekrar moderasyona
-- dussun - onaylanmis bir yorumun icerigi admin onayi olmadan
-- degistirilip yayinda kalamasin.
create or replace function public.reset_review_status_on_edit()
returns trigger
language plpgsql
as $$
begin
  if new.rating is distinct from old.rating or new.comment is distinct from old.comment then
    new.status := 'pending';
  end if;
  return new;
end;
$$;

create trigger trg_reset_review_status_on_edit
  before update on public.reviews
  for each row execute function public.reset_review_status_on_edit();
