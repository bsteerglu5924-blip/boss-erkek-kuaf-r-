-- ============ TELEGRAM NOTIFICATIONS ============
create extension if not exists pg_net with schema extensions;

-- Secretlar Supabase Vault'ta tutulur (yalnizca postgres/service_role okuyabilir).
--
-- GERCEK DEGERLER BU DOSYAYA YAZILMAZ - repo public. Asagidaki placeholder'lar
-- yerine gercek token/chat id, Supabase SQL Editor'den elle girilir:
--
--   select vault.update_secret(
--     (select id from vault.secrets where name = 'telegram_bot_token'),
--     'BOTFATHER_DAN_ALINAN_TOKEN'
--   );
--
-- (Onceki surumde gercek token bu dosyaya gomulmus ve commit edilmisti;
--  o token BotFather /revoke ile iptal edildi.)
select vault.create_secret('REPLACE_ME_SET_IN_SQL_EDITOR', 'telegram_bot_token', 'Randevu bildirimleri icin Telegram bot token');
select vault.create_secret('REPLACE_ME_SET_IN_SQL_EDITOR', 'telegram_chat_id', 'Randevu bildirimleri icin Telegram chat id');

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
    headers := jsonb_build_object('Content-Type', 'application/json')
  );

  return new;
end;
$$;

create trigger trg_notify_telegram_insert
  after insert on appointments
  for each row execute function public.notify_telegram_appointment();

create trigger trg_notify_telegram_status
  after update of status on appointments
  for each row
  when (old.status is distinct from new.status)
  execute function public.notify_telegram_appointment();
