-- Fiyatlandirma icin iki alan:
--   price_note  : tek sayiya sigmayan fiyatlar (orn. protez sac 13.000-30.000 TL).
--                 Doluysa price_try yerine bu gosterilir.
--   is_featured : "En cok tercih edilen" rozeti.
alter table services add column price_note text;
alter table services add column is_featured boolean not null default false;
