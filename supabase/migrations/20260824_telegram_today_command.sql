-- ============ TELEGRAM "BUGÜN" KOMUTU ============
create or replace function public.handle_telegram_command(
  p_chat_id text,
  p_text text
) returns void
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_token text;
  v_owner_chat_id text;
  v_normalized text;
  v_today date;
  v_reply text;
  v_row record;
  v_count int := 0;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into v_owner_chat_id from vault.decrypted_secrets where name = 'telegram_chat_id';

  if v_token is null or v_owner_chat_id is null then
    return;
  end if;

  -- sadece yetkili sohbetten gelen komutlara cevap ver
  if p_chat_id is distinct from v_owner_chat_id then
    return;
  end if;

  v_normalized := lower(trim(leading '/' from trim(coalesce(p_text, ''))));

  if v_normalized not in ('bugün', 'bugun') then
    return;
  end if;

  v_today := (now() at time zone 'Europe/Istanbul')::date;

  v_reply := '📋 Bugünkü Randevular (' || to_char(v_today, 'DD.MM.YYYY') || ')' || E'\n';

  for v_row in
    select a.starts_at, a.customer_name, a.customer_phone, a.status, s.name as service_name, b.name as barber_name
    from appointments a
    join services s on s.id = a.service_id
    join barbers b on b.id = a.barber_id
    where (a.starts_at at time zone 'Europe/Istanbul')::date = v_today
      and a.status in ('pending', 'confirmed')
    order by a.starts_at
  loop
    v_count := v_count + 1;
    v_reply := v_reply || E'\n' || '⏰ ' || to_char(v_row.starts_at at time zone 'Europe/Istanbul', 'HH24:MI')
      || ' — ' || v_row.customer_name || ' (' || v_row.service_name || ', ' || v_row.barber_name || ')'
      || case when v_row.status = 'pending' then ' [onay bekliyor]' else '' end;
  end loop;

  if v_count = 0 then
    v_reply := v_reply || E'\n' || 'Bugün için randevu yok.';
  else
    v_reply := v_reply || E'\n\n' || 'Toplam: ' || v_count || ' randevu';
  end if;

  perform net.http_post(
    url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
    body := jsonb_build_object('chat_id', v_owner_chat_id, 'text', v_reply),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
end;
$$;

revoke execute on function public.handle_telegram_command(text, text) from public, anon, authenticated;
grant execute on function public.handle_telegram_command(text, text) to service_role;
