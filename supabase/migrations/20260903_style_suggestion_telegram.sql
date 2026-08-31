-- ============ Gizli 2 oneriyi ustaya Telegram'dan gonder ============
-- Randevu 'confirmed' oldugunda, eger buna bagli tamamlanmis bir stil
-- analizi varsa, rank=1 ve rank=2 (musteriye HIC gosterilmeyen) oneriler
-- fotograflariyla birlikte Telegram'a gider. Mevcut sendMessage
-- bildirimlerine (20260824_telegram_notifications.sql) dokunmaz, tamamen
-- ek/bagimsiz bir trigger.
create or replace function public.notify_telegram_style_reveal()
returns trigger
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
  if new.status <> 'confirmed' or old.status is not distinct from new.status then
    return new;
  end if;

  select * into v_analysis
  from style_analyses
  where appointment_id = new.id
    and status = 'completed'
    and delivered_to_barber = false
  limit 1;

  if v_analysis.id is null then
    return new;
  end if;

  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into v_chat_id from vault.decrypted_secrets where name = 'telegram_chat_id';
  if v_token is null or v_chat_id is null then
    return new;
  end if;

  -- Once kilitle (cifte gonderimi engellemek icin), sonra gonder.
  update style_analyses set delivered_to_barber = true, updated_at = now() where id = v_analysis.id;

  select r into v_rank1 from jsonb_array_elements(v_analysis.recommendations) r where (r->>'rank')::int = 1;
  select r into v_rank2 from jsonb_array_elements(v_analysis.recommendations) r where (r->>'rank')::int = 2;

  v_caption_prefix := '🔒 Gizli Öneri — Müşteri: ' || new.customer_name || E'\n';

  if v_rank1 is not null and (v_rank1->>'image_url') is not null then
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendPhoto',
      body := jsonb_build_object(
        'chat_id', v_chat_id,
        'photo', v_rank1->>'image_url',
        'caption', v_caption_prefix || '(1. sıra) ' || coalesce(v_rank1->>'style_name','') || E'\n' || coalesce(v_rank1->>'reason','')
      ),
      headers := jsonb_build_object('Content-Type', 'application/json')
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
      headers := jsonb_build_object('Content-Type', 'application/json')
    );
  end if;

  return new;
end;
$$;

create trigger trg_notify_telegram_style_reveal
  after update of status on appointments
  for each row
  when (old.status is distinct from new.status and new.status = 'confirmed')
  execute function public.notify_telegram_style_reveal();
