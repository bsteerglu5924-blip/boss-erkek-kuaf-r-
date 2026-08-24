-- ============ OTOMASYON 1: Yeni randevuda sahibe e-posta ============
-- Mevcut notify_telegram_appointment() trigger'indan bagimsiz calisir;
-- biri patlarsa digeri etkilenmez.

create or replace function public.notify_email_new_appointment()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_owner_email text;
  v_html text;
  v_when text;
  v_subject text;
begin
  select decrypted_secret into v_owner_email from vault.decrypted_secrets where name = 'owner_notification_email';
  if v_owner_email is null or v_owner_email = 'REPLACE_ME_SET_IN_SQL_EDITOR' then
    return new;
  end if;

  v_html := public.render_appointment_html(new.id, 'new');
  if v_html is null then
    return new;
  end if;

  v_when := to_char(new.starts_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI');
  v_subject := 'Yeni Randevu - ' || new.customer_name || ', ' || v_when;

  perform public.send_email(v_owner_email, v_subject, v_html, 'new_appointment', new.id);

  return new;
end;
$$;

create trigger trg_email_new_appointment
  after insert on appointments
  for each row execute function public.notify_email_new_appointment();

revoke execute on function public.notify_email_new_appointment() from public, anon, authenticated;
