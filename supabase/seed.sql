-- DIKKAT: Buradaki hizmet adlari, sureleri ve fiyatlari index.html'deki
-- "Hizmetlerimiz" bolumuyle elle senkron tutulur. Birini degistirirken
-- digerini de guncelleyin.

insert into barbers (name, slug, title, sort_order) values
  ('Ali Şengül', 'ali-sengul', 'Matematiksel Kesim ve Altın Oran Kaş Tasarımı Uzmanı', 1),
  ('Murat Cankaya', 'murat-cankaya', 'Saç, Sakal ve Tıraş Ustası', 2),
  ('Furkan Akar', 'furkan-akar', 'Protez Saç Uygulamaları Ustası', 3),
  ('Beytullah Özbek', 'beytullah-ozbek', 'Usta Berber', 4),
  ('Ahmet Tarık Örnek', 'ahmet-tarik-ornek', 'Usta Berber', 5),
  ('Toprak Kanık', 'toprak-kanik', 'Premium Traş Ustası', 6)
on conflict (slug) do update set name = excluded.name, title = excluded.title, sort_order = excluded.sort_order;

-- price_is_final = false olan hizmetlerde site "fiyat icin arayin" der; bot da
-- fiyat uydurmaz. price_note doluysa price_try yerine o gosterilir.
insert into services (name, slug, description, duration_minutes, price_try, price_is_final, price_note, is_featured, sort_order) values
  ('Matematiksel Kesim', 'matematiksel-kesim',
   'Yüz hattı ve kafa yapısına oranlanarak hesaplanan, imza kesim tekniğimiz.',
   45, 600, true, null, false, 1),

  ('Matematiksel Kesim + Sakal', 'matematiksel-kesim-sakal',
   'İmza matematiksel kesimimiz ve ardından sakal şekillendirme.',
   60, 700, true, null, false, 2),

  ('Saç Kesimi', 'sac-kesimi',
   'Yüz hattınıza ve tarzınıza uygun, makas ve tıraş makinesiyle detaylı kesim.',
   30, 500, true, null, false, 3),

  ('Saç + Sakal', 'sac-sakal',
   'Saç kesimi ve sakal şekillendirme birlikte.',
   45, 600, true, null, false, 4),

  ('Komple Bakım Paketi', 'ozel-bakim',
   'Saç kesimi, sakal, kaş alımı, yüz maskesi, saç maskesi, fön ve yıkama — hepsi tek seansta.',
   90, 800, true, null, true, 5),

  ('Saç Boyama', 'sac-boyama',
   'Doğal duruşlu, tarzınıza uygun saç boyama uygulaması.',
   60, 1500, true, null, false, 6),

  ('Keratin Bakımı', 'keratin-bakimi',
   'Saçı besleyen, pürüzsüzleştiren ve parlaklık kazandıran keratin uygulaması.',
   120, 3000, true, null, false, 7),

  ('Protez Saç', 'protez-sac',
   'Saç dökülmesine karşı protez saç uygulaması ve danışmanlık. Fiyat, saç tipi ve uygulamaya göre belirlenir.',
   90, null, true, '13.000 – 30.000 TL', false, 8),

  ('Protez Saç Bakımı', 'protez-sac-bakimi',
   'Mevcut protez saçın temizliği, bakımı ve yeniden uygulanması.',
   60, 1250, true, null, false, 9),

  ('Sakal & Tıraş', 'sakal-tiras',
   'Klasik jilet tıraşı, sakal şekillendirme ve bakımı.',
   20, 300, true, null, false, 10),

  ('Altın Oran Kaş Tasarımı', 'kas-tasarimi',
   'Yüz simetrinize göre ölçülü, doğal duruşlu kaş şekillendirme. Ali Şengül''ün uzmanlık alanı.',
   15, 350, true, null, false, 11),

  ('Kaş Alımı', 'kas-alimi',
   'Kaş çevresinin temizlenip düzeltilmesi.',
   10, 200, true, null, false, 12),

  ('Cilt Bakımı', 'cilt-bakimi',
   'Tıraş sonrası yatıştırıcı bakım ve yüz temizliği uygulamaları.',
   20, 500, true, null, false, 13),

  -- Premium Tıraş genel listede gösterilmez (bkz. index.html "Hizmetlerimiz"
  -- notu) — sadece Toprak Kanık secilince barber_services araciligiyla gorunur.
  ('Premium Traş', 'premium-tiras',
   'Toprak Kanık''ın uyguladığı, sıcak havlu ve özel bakım ürünleriyle desteklenen üst düzey jilet tıraşı deneyimi.',
   60, 1000, true, null, false, 14)
on conflict (slug) do update set
  name = excluded.name,
  description = excluded.description,
  duration_minutes = excluded.duration_minutes,
  price_try = excluded.price_try,
  price_is_final = excluded.price_is_final,
  price_note = excluded.price_note,
  is_featured = excluded.is_featured,
  sort_order = excluded.sort_order;

-- ============ BARBER_SERVICES ============
-- Her normal berber, Premium Tiras disindaki tum hizmetleri verir.
-- Toprak Kanik SADECE Premium Tiras verir (bilincli tasarim).
insert into barber_services (barber_id, service_id)
select b.id, s.id
from barbers b
cross join services s
where b.slug <> 'toprak-kanik' and s.slug <> 'premium-tiras'
on conflict do nothing;

insert into barber_services (barber_id, service_id)
select b.id, s.id
from barbers b, services s
where b.slug = 'toprak-kanik' and s.slug = 'premium-tiras'
on conflict do nothing;

-- ============ STYLE_CATALOG ============
-- "Bana Ne Yakışır" AI stil analizinin secebilecegi katalog. image_url
-- mutlaka herkese acik https URL olmali (Telegram sendPhoto URL'den ceker).
insert into style_catalog (name, description, image_url, look_type, tags, sort_order, active) values
  ('Pompadour', 'Üstü hacimli ve taralı, yanları kısa; klasik ama modern bir duruş.', 'https://www.bosskuafor.com/stil-pompadour.jpg', 'hair', array['pompadour','taramalı','hacimli','oval yüz','kare yüz'], 1, true),
  ('Klasik Taramalı Kesim', 'Düz geriye taranmış, pürüzsüz ve zarif bir klasik kesim.', 'https://www.bosskuafor.com/stil-klasik-taramali.jpg', 'hair', array['klasik','taramalı','zarif','iş hayatı','uzun yüz'], 2, true),
  ('Desenli Fade', 'Üstü uzun, yanları desenli sıfıra yakın kesilmiş, dikkat çekici bir görünüm.', 'https://www.bosskuafor.com/stil-desenli-fade.jpg', 'hair', array['fade','desenli','genç','dikkat çekici','yuvarlak yüz'], 3, true),
  ('Doğal Dalgalı Kesim', 'Orta boy, doğal dalgalı ve dokulu; bakımsız değil ama zahmetsiz görünen bir stil.', 'https://www.bosskuafor.com/stil-dogal-dalgali.jpg', 'hair', array['dalgalı','doğal','orta boy','rahat','kalp yüz'], 4, true),
  ('Taramalı Saç + Gür Sakal', 'Geriye taranmış saç ve dolgun, bakımlı sakalın birlikte oluşturduğu olgun görünüm.', 'https://www.bosskuafor.com/stil-taramali-sakal.jpg', 'hair_and_beard', array['sakal','taramalı','olgun','kombinasyon','uzun yüz'], 5, true),
  ('Kısa Fade + Şekilli Sakal', 'Temiz kısa fade kesim ve düzgün hatlarla şekillendirilmiş sakal kombinasyonu.', 'https://www.bosskuafor.com/stil-fade-sakal.jpg', 'hair_and_beard', array['fade','sakal','temiz','kombinasyon','kare yüz'], 6, true)
on conflict do nothing;
