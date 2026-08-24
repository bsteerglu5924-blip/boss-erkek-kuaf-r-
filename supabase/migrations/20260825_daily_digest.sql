-- ============ OTOMASYON 3: Gunluk ozet (09:00 Europe/Istanbul) ============
-- Onem sirasi: 1) pending + 3 saat icinde (ACIL), 2) diger pending, 3) confirmed.
-- Turkiye kalici UTC+3 (DST yok), bu yuzden cron '0 6 * * *' UTC = 09:00 Istanbul,
-- kayma riski olmadan sabit kalir.

create or replace function public.send_daily_digest()
returns void
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_today date;
  v_row record;
  v_count int := 0;
  v_pending_count int := 0;
  v_confirmed_count int := 0;
  v_new_24h int;
  v_cancelled_24h int;
  v_text text;
  v_owner_email text;
  v_html_rows text := '';
  v_html text;
  v_label text;
  v_accent text;
begin
  v_today := (now() at time zone 'Europe/Istanbul')::date;

  select count(*) into v_new_24h from appointments where created_at >= now() - interval '24 hours';
  select count(*) into v_cancelled_24h from appointments
    where status = 'cancelled' and created_at >= now() - interval '24 hours';

  v_text := '📋 ' || to_char(v_today, 'DD.MM.YYYY') || ' — Günün Randevu Özeti' || E'\n';

  for v_row in
    select
      a.id, a.starts_at, a.customer_name, a.customer_phone, a.status,
      s.name as service_name, b.name as barber_name,
      case
        when a.status = 'pending' and a.starts_at <= now() + interval '3 hours' then 1
        when a.status = 'pending' then 2
        else 3
      end as priority
    from appointments a
    join services s on s.id = a.service_id
    join barbers b on b.id = a.barber_id
    where (a.starts_at at time zone 'Europe/Istanbul')::date = v_today
      and a.status in ('pending', 'confirmed')
    order by priority, a.starts_at
  loop
    v_count := v_count + 1;
    if v_row.status = 'pending' then
      v_pending_count := v_pending_count + 1;
    else
      v_confirmed_count := v_confirmed_count + 1;
    end if;

    if v_row.priority = 1 then
      v_label := '🔴 ACİL — onay bekliyor';
      v_accent := '#6E2430';
    elsif v_row.priority = 2 then
      v_label := '🟡 Onay bekliyor';
      v_accent := '#7A5A2A';
    else
      v_label := '🟢 Onaylı';
      v_accent := '#3F7D4F';
    end if;

    v_text := v_text || E'\n' || to_char(v_row.starts_at at time zone 'Europe/Istanbul', 'HH24:MI')
      || ' ' || v_label || ' — ' || v_row.customer_name
      || ' (' || v_row.service_name || ', ' || v_row.barber_name || ')';

    v_html_rows := v_html_rows ||
      '<tr><td style="padding:8px 0;border-bottom:1px solid rgba(33,28,19,0.12);white-space:nowrap;font-weight:bold;color:#211C13;">' ||
        to_char(v_row.starts_at at time zone 'Europe/Istanbul', 'HH24:MI') || '</td>' ||
      '<td style="padding:8px 12px;border-bottom:1px solid rgba(33,28,19,0.12);color:' || v_accent || ';font-weight:bold;white-space:nowrap;">' ||
        v_label || '</td>' ||
      '<td style="padding:8px 0;border-bottom:1px solid rgba(33,28,19,0.12);color:#211C13;">' ||
        v_row.customer_name || ' <span style="color:#5B563F;">(' || v_row.service_name || ', ' || v_row.barber_name || ')</span></td></tr>';
  end loop;

  if v_count = 0 then
    v_text := v_text || E'\n' || 'Bugün için randevu yok.';
  else
    v_text := v_text || E'\n\n' || 'Toplam: ' || v_count || ' randevu (' || v_pending_count || ' onay bekliyor, ' || v_confirmed_count || ' onaylı)';
  end if;

  if v_new_24h > 0 or v_cancelled_24h > 0 then
    v_text := v_text || E'\n' || 'Son 24 saatte: ' || v_new_24h || ' yeni, ' || v_cancelled_24h || ' iptal';
  end if;

  perform public.tg_send(v_text);

  select decrypted_secret into v_owner_email from vault.decrypted_secrets where name = 'owner_notification_email';
  if v_owner_email is not null and v_owner_email <> 'REPLACE_ME_SET_IN_SQL_EDITOR' then
    v_html :=
      '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#EAE2CE;padding:24px 0;font-family:Arial,Helvetica,sans-serif;">' ||
      '<tr><td align="center">' ||
      '<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#F4EFDF;border-radius:6px;overflow:hidden;">' ||
      '<tr><td style="background:#8C6A34;padding:20px 28px;">' ||
      '<span style="color:#FFFFFF;font-size:20px;font-weight:bold;">BOSS Kuafor - Gunun Ozeti (' || to_char(v_today, 'DD.MM.YYYY') || ')</span>' ||
      '</td></tr>' ||
      '<tr><td style="padding:20px 28px;">' ||
      case when v_count = 0 then
        '<p style="margin:0;color:#211C13;font-size:15px;">Bugun icin randevu yok.</p>'
      else
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;">' || v_html_rows || '</table>' ||
        '<p style="margin:16px 0 0;color:#5B563F;font-size:13px;">Toplam ' || v_count || ' randevu - ' || v_pending_count || ' onay bekliyor, ' || v_confirmed_count || ' onayli.</p>'
      end ||
      case when v_new_24h > 0 or v_cancelled_24h > 0 then
        '<p style="margin:8px 0 0;color:#5B563F;font-size:13px;">Son 24 saatte: ' || v_new_24h || ' yeni, ' || v_cancelled_24h || ' iptal.</p>'
      else '' end ||
      '</td></tr>' ||
      '</table>' ||
      '</td></tr>' ||
      '</table>';

    perform public.send_email(v_owner_email, 'Gunun Ozeti - ' || to_char(v_today, 'DD.MM.YYYY'), v_html);
  end if;
end;
$$;

revoke execute on function public.send_daily_digest() from public, anon, authenticated;

select cron.schedule(
  'daily-appointment-digest',
  '0 6 * * *',
  $$select public.send_daily_digest()$$
);
