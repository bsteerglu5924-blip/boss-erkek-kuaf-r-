-- ============ Telegram "soguk baglanti" zaman asimi duzeltmesi ============
-- Gercek kullanicida gozlemlendi: rank=1 fotografi neredeyse hep gitmiyordu,
-- rank=2 hep gidiyordu. net._http_response loglarinda kok neden bulundu:
-- api.telegram.org'a ayni "patlama" icindeki ILK istek TLS handshake'te
-- 5sn (sonra denendi: 15sn) zaman asimina ugruyor, hemen ardindan gelen
-- istek ise saniyenin altinda basariyla tamamlaniyor. Bu net bir
-- "soguk baglanti" sorunu — timeout'u uzatmak yetmedi (114'te 15sn'de
-- bile ilk istek yine zaman asimina ugradi).
--
-- Cozum: gercek fotograflardan once ucuz/gorunmez bir getMe istegi atip
-- "soguk baglanti" bedelini bu harcanabilir istege yukluyoruz. Canli
-- testte (5 ardisik istek, hepsi basarili) dogrulandi.

create or replace function public.notify_telegram_style_reveal_now(
  p_appointment_id uuid,
  p_customer_name text
) returns void
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_token text;
  v_chat_id text;
  v_analysis record;
  v_rank1 jsonb;
  v_rank2 jsonb;
  v_caption_prefix text;
begin
  select * into v_analysis
  from style_analyses
  where appointment_id = p_appointment_id
    and status = 'completed'
    and delivered_to_barber = false
  limit 1;

  if v_analysis.id is null then
    return;
  end if;

  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into v_chat_id from vault.decrypted_secrets where name = 'telegram_chat_id';
  if v_token is null or v_chat_id is null then
    return;
  end if;

  update style_analyses set delivered_to_barber = true, updated_at = now() where id = v_analysis.id;

  select r into v_rank1 from jsonb_array_elements(v_analysis.recommendations) r where (r->>'rank')::int = 1;
  select r into v_rank2 from jsonb_array_elements(v_analysis.recommendations) r where (r->>'rank')::int = 2;

  v_caption_prefix := '🔒 Gizli Öneri — Müşteri: ' || p_customer_name || E'\n';

  perform net.http_get(
    url := 'https://api.telegram.org/bot' || v_token || '/getMe',
    timeout_milliseconds := 15000
  );

  if v_rank1 is not null and (v_rank1->>'image_url') is not null then
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendPhoto',
      body := jsonb_build_object(
        'chat_id', v_chat_id,
        'photo', v_rank1->>'image_url',
        'caption', v_caption_prefix || '(1. sıra) ' || coalesce(v_rank1->>'style_name','') || E'\n' || coalesce(v_rank1->>'reason','')
      ),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 15000
    );
  end if;

  if v_rank2 is not null and (v_rank2->>'image_url') is not null then
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendPhoto',
      body := jsonb_build_object(
        'chat_id', v_chat_id,
        'photo', v_rank2->>'image_url',
        'caption', v_caption_prefix || '(2. sıra) ' || coalesce(v_rank2->>'style_name','') || E'\n' || coalesce(v_rank2->>'reason','')
      ),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 15000
    );
  end if;
end;
$$;

-- Ayni soguk-baglanti riski tasidigi icin mevcut randevu bildirimi de
-- guclendirildi (timeout uzatildi). Bu fonksiyon simdilik tek istek
-- attigi icin isindirma eklenmedi; ileride sorun gozlenirse eklenebilir.
create or replace function public.notify_telegram_appointment()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_token text;
  v_chat_id text;
  v_barber_name text;
  v_service_name text;
  v_when text;
  v_header text;
  v_text text;
  v_row record;
begin
  if tg_op = 'INSERT' then
    v_header := '🆕 Yeni Randevu';
    v_row := new;
  elsif tg_op = 'UPDATE' and new.status = 'cancelled' then
    v_header := '❌ Randevu İptal Edildi';
    v_row := new;
  elsif tg_op = 'UPDATE' and new.status = 'confirmed' then
    v_header := '✅ Randevu Onaylandı';
    v_row := new;
  elsif tg_op = 'UPDATE' and new.status = 'completed' then
    v_header := '✔️ Randevu Tamamlandı';
    v_row := new;
  elsif tg_op = 'UPDATE' and new.status = 'no_show' then
    v_header := '⚠️ Müşteri Gelmedi';
    v_row := new;
  else
    return new;
  end if;

  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into v_chat_id from vault.decrypted_secrets where name = 'telegram_chat_id';

  if v_token is null or v_chat_id is null then
    return new;
  end if;

  select b.name into v_barber_name from barbers b where b.id = v_row.barber_id;
  select s.name into v_service_name from services s where s.id = v_row.service_id;
  v_when := to_char(v_row.starts_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI');

  v_text := v_header || E'\n'
    || '👤 Müşteri: ' || v_row.customer_name || E'\n'
    || '📞 Telefon: ' || v_row.customer_phone || E'\n'
    || '💇 Hizmet: ' || coalesce(v_service_name, '-') || E'\n'
    || '👨‍🦰 Berber: ' || coalesce(v_barber_name, '-') || E'\n'
    || '📅 Tarih/Saat: ' || v_when;

  if v_row.notes is not null and trim(v_row.notes) <> '' then
    v_text := v_text || E'\n' || '📝 Not: ' || v_row.notes;
  end if;

  perform net.http_post(
    url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
    body := jsonb_build_object('chat_id', v_chat_id, 'text', v_text),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 15000
  );

  return new;
end;
$$;
