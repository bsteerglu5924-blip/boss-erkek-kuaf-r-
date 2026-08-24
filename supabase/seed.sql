insert into barbers (name, slug, title, sort_order) values
  ('Ali Şengül', 'ali-sengul', 'Matematiksel Kesim Uzmanı', 1),
  ('Murat Cankaya', 'murat-cankaya', 'Saç, Sakal ve Tıraş Ustası', 2),
  ('Furkan Akar', 'furkan-akar', 'Saç, Sakal ve Tıraş Ustası', 3)
on conflict (slug) do update set name = excluded.name, title = excluded.title, sort_order = excluded.sort_order;

-- price_try = 0 / price_is_final = false are placeholders until real prices are supplied.
insert into services (name, slug, description, duration_minutes, price_try, price_is_final, sort_order) values
  ('Matematiksel Kesim', 'matematiksel-kesim', 'Yüz hattı ve kafa yapısına oranlanarak hesaplanan, imza kesim tekniğimiz.', 45, 0, false, 1),
  ('Saç Kesimi', 'sac-kesimi', 'Yüz hattınıza ve tarzınıza uygun, makas ve tıraş makinesiyle detaylı kesim.', 30, 0, false, 2),
  ('Sakal & Tıraş', 'sakal-tiras', 'Klasik jilet tıraşı, sakal şekillendirme ve bakımı.', 20, 0, false, 3),
  ('Protez Saç Merkezi', 'protez-sac', 'Saç dökülmesine karşı protez saç uygulama ve danışmanlık hizmeti.', 60, 0, false, 4),
  ('Altın Oran Kaş Tasarımı', 'kas-tasarimi', 'Yüz simetrinize göre ölçülü, doğal duruşlu kaş şekillendirme.', 15, 0, false, 5),
  ('Cilt Bakımı', 'cilt-bakimi', 'Tıraş sonrası yatıştırıcı bakım ve yüz temizliği uygulamaları.', 20, 0, false, 6),
  ('Özel Bakım Paketleri', 'ozel-bakim', 'Saç, sakal ve cilt bakımını tek seansta birleştiren komple bakım.', 75, 0, false, 7)
on conflict (slug) do update set name = excluded.name, description = excluded.description, duration_minutes = excluded.duration_minutes, sort_order = excluded.sort_order;
