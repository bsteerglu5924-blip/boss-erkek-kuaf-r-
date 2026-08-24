-- ============ E-POSTA ALTYAPISI (Resend) ============
-- Telegram entegrasyonuyla ayni desen: vault secret + net.http_post.

-- Secretlar Supabase Vault'ta tutulur (yalnizca postgres/service_role okuyabilir).
-- GERCEK DEGERLER BU DOSYAYA YAZILMAZ - repo public. Placeholder'lar yerine
-- gercek deger Supabase SQL Editor'den elle girilir:
--
--   select vault.update_secret((select id from vault.secrets where name = 'resend_api_key'), 're_XXXX');
--   select vault.update_secret((select id from vault.secrets where name = 'email_from'), 'BOSS Kuafor <randevu@bosskuafor.com>');
--   select vault.update_secret((select id from vault.secrets where name = 'owner_notification_email'), 'sahibin@adresi.com');
select vault.create_secret('REPLACE_ME_SET_IN_SQL_EDITOR', 'resend_api_key', 'Resend API anahtari (e-posta gonderimi)');
select vault.create_secret('REPLACE_ME_SET_IN_SQL_EDITOR', 'email_from', 'Gonderen adresi, ornek: BOSS Kuafor <randevu@bosskuafor.com>');
select vault.create_secret('REPLACE_ME_SET_IN_SQL_EDITOR', 'owner_notification_email', 'Isletme sahibinin bildirim/ozet mailleri alacagi adres');

-- ============ email_log ============
-- Cron/trigger mukerrer gonderimini engellemek icin idempotency kaydi.
create table if not exists email_log (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid references appointments(id) on delete cascade,
  kind text,
  recipient text,
  subject text,
  net_request_id bigint,
  created_at timestamptz not null default now(),
  constraint email_log_appointment_kind_unique unique (appointment_id, kind)
);

create index if not exists idx_email_log_appointment on email_log (appointment_id);

alter table email_log enable row level security;

create policy email_log_admin_read on email_log for select to authenticated using (true);

-- ============ send_email ============
create or replace function public.send_email(
  p_to text,
  p_subject text,
  p_html text,
  p_kind text default null,
  p_appointment_id uuid default null
) returns void
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_api_key text;
  v_from text;
  v_request_id bigint;
begin
  if p_to is null or trim(p_to) = '' then
    return;
  end if;

  -- Secret kontrolu ONCE yapilir: anahtar henuz girilmemisse email_log'a
  -- hic dokunma. Aksi halde secret sonradan girildiginde bu randevu icin
  -- gonderim, zaten "denendi" isaretlendigi icin bir daha asla tetiklenmez.
  select decrypted_secret into v_api_key from vault.decrypted_secrets where name = 'resend_api_key';
  select decrypted_secret into v_from from vault.decrypted_secrets where name = 'email_from';

  if v_api_key is null or v_from is null or v_api_key = 'REPLACE_ME_SET_IN_SQL_EDITOR' then
    return;
  end if;

  -- Idempotency: randevuya bagli gonderimlerde ayni (appointment_id, kind) icin
  -- ikinci kez calisilirsa satir eklenmez -> zaten gonderilmis demektir, cik.
  if p_appointment_id is not null and p_kind is not null then
    insert into email_log (appointment_id, kind, recipient, subject)
    values (p_appointment_id, p_kind, p_to, p_subject)
    on conflict (appointment_id, kind) do nothing;

    if not found then
      return;
    end if;
  end if;

  select net.http_post(
    url := 'https://api.resend.com/emails',
    body := jsonb_build_object('from', v_from, 'to', p_to, 'subject', p_subject, 'html', p_html),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_api_key)
  ) into v_request_id;

  if p_appointment_id is not null and p_kind is not null then
    update email_log set net_request_id = v_request_id
    where appointment_id = p_appointment_id and kind = p_kind;
  end if;
end;
$$;

revoke execute on function public.send_email(text, text, text, text, uuid) from public, anon, authenticated;

-- ============ tg_send ============
-- Telegram gonderimini tek yere toplayan yardimci (gunluk ozet bunu kullanir).
-- Mevcut notify_telegram_appointment() bozulmasin diye oldugu gibi birakildi.
create or replace function public.tg_send(p_text text)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_token text;
  v_chat_id text;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into v_chat_id from vault.decrypted_secrets where name = 'telegram_chat_id';

  if v_token is null or v_chat_id is null then
    return;
  end if;

  perform net.http_post(
    url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
    body := jsonb_build_object('chat_id', v_chat_id, 'text', p_text),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
end;
$$;

revoke execute on function public.tg_send(text) from public, anon, authenticated;

-- ============ render_appointment_html ============
-- p_kind: 'new' (sahibe bildirim) / 'reminder_2h' (musteriye hatirlatma)
create or replace function public.render_appointment_html(p_appointment_id uuid, p_kind text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row appointments%rowtype;
  v_barber_name text;
  v_service_name text;
  v_when text;
  v_title text;
  v_intro text;
  v_accent text := '#8C6A34';
begin
  select * into v_row from appointments a where a.id = p_appointment_id;
  if not found then
    return null;
  end if;

  select b.name into v_barber_name from barbers b where b.id = v_row.barber_id;
  select s.name into v_service_name from services s where s.id = v_row.service_id;
  v_when := to_char(v_row.starts_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI');

  if p_kind = 'reminder_2h' then
    v_title := 'Randevu Hatirlatmasi';
    v_intro := 'Randevunuza yaklasik 2 saat kaldi.';
  else
    v_title := 'Yeni Randevu';
    v_accent := '#6E2430';
    v_intro := 'Yeni bir randevu olusturuldu.';
  end if;

  return
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#EAE2CE;padding:24px 0;font-family:Arial,Helvetica,sans-serif;">' ||
    '<tr><td align="center">' ||
    '<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#F4EFDF;border-radius:6px;overflow:hidden;">' ||
    '<tr><td style="background:' || v_accent || ';padding:20px 28px;">' ||
    '<span style="color:#FFFFFF;font-size:20px;font-weight:bold;">BOSS Kuafor - ' || v_title || '</span>' ||
    '</td></tr>' ||
    '<tr><td style="padding:24px 28px 8px;">' ||
    '<p style="margin:0 0 18px;color:#211C13;font-size:15px;">' || v_intro || '</p>' ||
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:15px;color:#211C13;">' ||
    '<tr><td style="padding:6px 0;color:#5B563F;width:120px;">Musteri</td><td style="padding:6px 0;font-weight:bold;">' || v_row.customer_name || '</td></tr>' ||
    '<tr><td style="padding:6px 0;color:#5B563F;">Telefon</td><td style="padding:6px 0;">' || v_row.customer_phone || '</td></tr>' ||
    '<tr><td style="padding:6px 0;color:#5B563F;">Hizmet</td><td style="padding:6px 0;">' || coalesce(v_service_name, '-') || '</td></tr>' ||
    '<tr><td style="padding:6px 0;color:#5B563F;">Berber</td><td style="padding:6px 0;">' || coalesce(v_barber_name, '-') || '</td></tr>' ||
    '<tr><td style="padding:6px 0;color:#5B563F;">Tarih/Saat</td><td style="padding:6px 0;font-weight:bold;color:#7A5A2A;">' || v_when || '</td></tr>' ||
    case when v_row.notes is not null and trim(v_row.notes) <> '' then
      '<tr><td style="padding:6px 0;color:#5B563F;">Not</td><td style="padding:6px 0;">' || v_row.notes || '</td></tr>'
    else '' end ||
    '</table>' ||
    '</td></tr>' ||
    '<tr><td style="padding:8px 28px 28px;">' ||
    '<a href="https://wa.me/905451166205" style="display:inline-block;margin-top:12px;padding:10px 20px;background:#8C6A34;color:#FFFFFF;text-decoration:none;border-radius:4px;font-size:14px;font-weight:bold;">WhatsApptan Yaz</a>' ||
    '</td></tr>' ||
    '</table>' ||
    '</td></tr>' ||
    '</table>';
end;
$$;

revoke execute on function public.render_appointment_html(uuid, text) from public, anon, authenticated;
