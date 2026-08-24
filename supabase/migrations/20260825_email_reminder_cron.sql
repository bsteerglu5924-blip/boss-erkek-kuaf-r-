-- ============ OTOMASYON 2: Randevudan 2 saat once musteriye hatirlatma ============
create extension if not exists pg_cron with schema extensions;

create or replace function public.send_appointment_reminders()
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_appt record;
  v_html text;
  v_when text;
  v_subject text;
begin
  for v_appt in
    select a.id, a.customer_email, a.starts_at
    from appointments a
    where a.status in ('pending', 'confirmed')
      and a.customer_email is not null
      and a.starts_at > now()
      and a.starts_at <= now() + interval '2 hours'
      and a.created_at <= a.starts_at - interval '2 hours'
      and not exists (
        select 1 from email_log el
        where el.appointment_id = a.id and el.kind = 'reminder_2h'
      )
  loop
    v_html := public.render_appointment_html(v_appt.id, 'reminder_2h');
    if v_html is null then
      continue;
    end if;

    v_when := to_char(v_appt.starts_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI');
    v_subject := 'Randevu Hatirlatmasi - ' || v_when;

    perform public.send_email(v_appt.customer_email, v_subject, v_html, 'reminder_2h', v_appt.id);
  end loop;
end;
$$;

revoke execute on function public.send_appointment_reminders() from public, anon, authenticated;

select cron.schedule(
  'appointment-reminder-2h',
  '*/15 * * * *',
  $$select public.send_appointment_reminders()$$
);
