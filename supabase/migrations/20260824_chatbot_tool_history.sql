-- Sohbet gecmisine ARAC cagrilarini da ekle.
--
-- Onceki surumde chat_messages yalnizca metin sakliyordu. Bu yuzden model,
-- bir sonraki turda onceki turun tool_use / tool_result bloklarini goremiyor,
-- "randevu olusturuldu" diye halusinasyon yapabiliyordu. Artik her turun tam
-- icerik blogu (blocks jsonb) saklaniyor ve aynen geri oynatiliyor.

alter table chat_messages add column blocks jsonb;

alter table chat_messages drop constraint chat_messages_role_check;
alter table chat_messages add constraint chat_messages_role_check
  check (role in ('user','assistant','tool'));

-- ============ chat_begin_turn (blocks dahil) ============
drop function if exists public.chat_begin_turn(uuid, text, text);

create or replace function public.chat_begin_turn(
  p_session_id uuid,
  p_ip_hash text,
  p_message text
) returns table (role text, content text, blocks jsonb)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_session_limit constant int := 15;
  v_daily_limit   constant int := 40;
  v_count int;
  v_ip_hash text;
  v_daily int;
begin
  if trim(coalesce(p_message, '')) = '' then
    raise exception 'EMPTY_MESSAGE' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_session_id::text));

  select cs.user_message_count, cs.ip_hash into v_count, v_ip_hash
  from chat_sessions cs where cs.id = p_session_id;

  if v_count is null then
    v_count := 0;
    v_ip_hash := p_ip_hash;
    insert into chat_sessions (id, ip_hash) values (p_session_id, p_ip_hash);
  elsif v_ip_hash is distinct from p_ip_hash then
    raise exception 'SESSION_MISMATCH' using errcode = 'P0001';
  end if;

  if v_count >= v_session_limit then
    raise exception 'SESSION_LIMIT' using errcode = 'P0001';
  end if;

  select coalesce(sum(cs.user_message_count), 0) into v_daily
  from chat_sessions cs
  where cs.ip_hash = p_ip_hash
    and cs.created_at > now() - interval '24 hours';

  if v_daily >= v_daily_limit then
    raise exception 'DAILY_LIMIT' using errcode = 'P0001';
  end if;

  insert into chat_messages (session_id, role, content)
  values (p_session_id, 'user', left(trim(p_message), 1000));

  update chat_sessions
  set user_message_count = user_message_count + 1,
      last_message_at = now()
  where id = p_session_id;

  -- Arac turlari da sayildigi icin pencere genis tutuluyor; kirpma
  -- Edge Function tarafinda tool_use/tool_result cifti bozulmayacak
  -- sekilde yapiliyor.
  return query
  select m.role, m.content, m.blocks
  from (
    select cm.role, cm.content, cm.blocks, cm.created_at, cm.id
    from chat_messages cm
    where cm.session_id = p_session_id
    order by cm.created_at desc, cm.id desc
    limit 60
  ) m
  order by m.created_at, m.id;
end;
$$;

revoke execute on function public.chat_begin_turn(uuid, text, text) from public, anon, authenticated;
grant execute on function public.chat_begin_turn(uuid, text, text) to service_role;

-- ============ chat_log_turn ============
-- Asistan ve arac turlarini tam icerik bloguyla kaydeder.
create or replace function public.chat_log_turn(
  p_session_id uuid,
  p_role text,
  p_content text,
  p_blocks jsonb
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_role not in ('assistant','tool') then
    raise exception 'INVALID_ROLE' using errcode = 'P0001';
  end if;

  insert into chat_messages (session_id, role, content, blocks)
  values (p_session_id, p_role, coalesce(p_content, ''), p_blocks);

  update chat_sessions set last_message_at = now() where id = p_session_id;
end;
$$;

revoke execute on function public.chat_log_turn(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.chat_log_turn(uuid, text, text, jsonb) to service_role;
