-- ============ CHATBOT: SESSIONS + MESSAGES ============
-- Sohbet gecmisi sunucuda tutulur; istemci sadece son mesaji gonderir.
-- ip_hash = SHA-256(ip + CHAT_IP_SALT) -- ham IP asla saklanmaz (KVKK).

create table chat_sessions (
  id uuid primary key,
  ip_hash text not null,
  user_message_count int not null default 0,
  booked_appointment_id uuid references appointments(id),
  created_at timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);

create table chat_messages (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references chat_sessions(id) on delete cascade,
  role text not null check (role in ('user','assistant')),
  content text not null,
  created_at timestamptz not null default now()
);

create index idx_chat_sessions_ip_created on chat_sessions (ip_hash, created_at desc);
create index idx_chat_sessions_last_message on chat_sessions (last_message_at desc);
create index idx_chat_messages_session on chat_messages (session_id, created_at);

-- ============ RLS ============
-- appointments deseni: anon icin hic policy yok -> tamamen kapali.
-- Erisim yalnizca service_role (Edge Function) ve asagidaki SECURITY DEFINER RPC uzerinden.
alter table chat_sessions enable row level security;
alter table chat_messages enable row level security;

-- Admin panel sadece OKUR; sohbet duzenlenemez/silinemez.
create policy chat_sessions_admin_read on chat_sessions for select to authenticated using (true);
create policy chat_messages_admin_read on chat_messages for select to authenticated using (true);

-- ============ chat_begin_turn ============
-- Tek cagrida atomik olarak: oturumu ac/dogrula, limitleri uygula,
-- kullanici mesajini yaz, son 20 mesaji geri dondur.
create or replace function public.chat_begin_turn(
  p_session_id uuid,
  p_ip_hash text,
  p_message text
) returns table (role text, content text)
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

  -- Ayni oturuma es zamanli iki istek gelirse sayaci yarislamasin.
  perform pg_advisory_xact_lock(hashtext(p_session_id::text));

  select cs.user_message_count, cs.ip_hash into v_count, v_ip_hash
  from chat_sessions cs where cs.id = p_session_id;

  if v_count is null then
    v_count := 0;
    v_ip_hash := p_ip_hash;
    insert into chat_sessions (id, ip_hash) values (p_session_id, p_ip_hash);
  elsif v_ip_hash is distinct from p_ip_hash then
    -- Baskasinin oturum id'si ele gecirilmis: yeni oturum acmaya zorla.
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

  return query
  select m.role, m.content
  from (
    select cm.role, cm.content, cm.created_at
    from chat_messages cm
    where cm.session_id = p_session_id
    order by cm.created_at desc, cm.id desc
    limit 20
  ) m
  order by m.created_at;
end;
$$;

revoke execute on function public.chat_begin_turn(uuid, text, text) from public, anon, authenticated;
grant execute on function public.chat_begin_turn(uuid, text, text) to service_role;

-- ============ chat_log_reply ============
create or replace function public.chat_log_reply(
  p_session_id uuid,
  p_content text
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into chat_messages (session_id, role, content)
  values (p_session_id, 'assistant', p_content);

  update chat_sessions set last_message_at = now() where id = p_session_id;
end;
$$;

revoke execute on function public.chat_log_reply(uuid, text) from public, anon, authenticated;
grant execute on function public.chat_log_reply(uuid, text) to service_role;

-- ============ chat_mark_booked ============
create or replace function public.chat_mark_booked(
  p_session_id uuid,
  p_appointment_id uuid
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update chat_sessions
  set booked_appointment_id = p_appointment_id
  where id = p_session_id;
end;
$$;

revoke execute on function public.chat_mark_booked(uuid, uuid) from public, anon, authenticated;
grant execute on function public.chat_mark_booked(uuid, uuid) to service_role;

-- ============ Mevcut randevu RPC'lerini bot da cagirabilsin ============
grant execute on function public.get_available_slots(uuid, uuid, date) to service_role;
grant execute on function public.book_appointment(uuid, uuid, timestamptz, text, text, text) to service_role;
