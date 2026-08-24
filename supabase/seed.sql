-- DIKKAT: Buradaki hizmet adlari, sureleri ve fiyatlari index.html'deki
-- "Hizmetlerimiz" bolumuyle elle senkron tutulur. Birini degistirirken
-- digerini de guncelleyin.

insert into barbers (name, slug, title, sort_order) values
  ('Ali Şengül', 'ali-sengul', 'Matematiksel Kesim Uzmanı', 1),
  ('Murat Cankaya', 'murat-cankaya', 'Saç, Sakal ve Tıraş Ustası', 2),
  ('Furkan Akar', 'furkan-akar', 'Protez Saç Uygulamaları Ustası', 3),
  ('Beytullah Özbek', 'beytullah-ozbek', 'Usta Berber', 4),
  ('Ahmet Tarık Örnek', 'ahmet-tarik-ornek', 'Usta Berber', 5)
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
   20, null, false, null, false, 10),

  ('Altın Oran Kaş Tasarımı', 'kas-tasarimi',
   'Yüz simetrinize göre ölçülü, doğal duruşlu kaş şekillendirme.',
   15, null, false, null, false, 11),

  ('Cilt Bakımı', 'cilt-bakimi',
   'Tıraş sonrası yatıştırıcı bakım ve yüz temizliği uygulamaları.',
   20, null, false, null, false, 12)
on conflict (slug) do update set
  name = excluded.name,
  description = excluded.description,
  duration_minutes = excluded.duration_minutes,
  price_try = excluded.price_try,
  price_is_final = excluded.price_is_final,
  price_note = excluded.price_note,
  is_featured = excluded.is_featured,
  sort_order = excluded.sort_order;
