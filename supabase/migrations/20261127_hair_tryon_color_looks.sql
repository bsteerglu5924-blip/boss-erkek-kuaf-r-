-- "Saçını Dene" — saç rengi seçimi + yeni modeller (uzun saç, yana taralı...).
-- Tamamen eklemeli: mevcut sütun/tablolara dokunmaz; sadece iki fonksiyonun
-- donus tipine renk eklenir (drop + create).

alter table public.hair_tryon_results
  add column hair_color text not null default 'natural'
  check (hair_color in ('natural','black','dark_brown','chestnut','light_brown','blonde','gray'));

insert into public.hair_looks (slug, name, description, prompt, thumb_url, sort_order) values
  ('uzun-sac', 'Uzun Saç',
   'Kulak ve ense hizasını geçen, doğal akan uzun saç.',
   'long natural hair that falls past the ears down to the collar or shoulders, soft layers, flowing naturally with a center-to-side part',
   null, 60),
  ('orta-uzun-yana-tarali', 'Orta Uzun Yana Taralı',
   'Önden yana doğru taranmış, orta uzunlukta şık model.',
   'medium-long hair with a deep side part, the front swept and brushed to one side, soft volume on top, neat tapered sides',
   null, 70),
  ('kisa-kivircik', 'Kısa Kıvırcık',
   'Kısa, dolgun ve doğal kıvırcık.',
   'short natural curly hair, dense tight curls on top about 4 cm long, closely tapered sides',
   null, 80),
  ('dagnik-dokulu', 'Dağınık Dokulu',
   'Hareketli, dağınık dokulu modern görünüm.',
   'a modern messy textured quiff, medium length on top with natural separated texture and movement, short tapered sides',
   null, 90);

-- link: renk de donsun (Telegram aciklamasi icin)
drop function if exists public.link_hair_tryon_to_appointment(uuid, uuid);
create function public.link_hair_tryon_to_appointment(p_tryon_id uuid, p_appointment_id uuid)
returns table (
  customer_name text, look_name text, density text, hair_color text,
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

  return query select v_a.customer_name, v_r.look_name, v_r.density, v_r.hair_color, v_t.photo_path, v_r.image_path;
end;
$$;
revoke execute on function public.link_hair_tryon_to_appointment(uuid, uuid) from public, anon, authenticated;
grant execute on function public.link_hair_tryon_to_appointment(uuid, uuid) to service_role;

-- admin listesi: renk de gorunsun
drop function if exists public.admin_hair_tryons(int);
create function public.admin_hair_tryons(p_limit int default 40)
returns table (
  tryon_id uuid,
  created_at timestamptz,
  photo_path text,
  appointment_id uuid,
  customer_name text,
  customer_phone text,
  selected_look text,
  selected_density text,
  selected_color text,
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
         sr.look_name, sr.density, sr.hair_color, sr.image_path,
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
