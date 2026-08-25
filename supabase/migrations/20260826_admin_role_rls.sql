-- ============ ADMIN ROLU: using(true) -> is_admin() ============
-- Uyelik sistemi acildigindan beri 'authenticated' rolu artik "kayit olan
-- herhangi bir musteri" anlamina geliyor, "admin" degil. Bu migration'dan
-- once her authenticated politikasi using(true)/with check(true) idi -
-- yani ilk kayit olan musteri tum randevulari, telefon/e-posta bilgilerini,
-- sohbet kayitlarini okuyup yazabilirdi. Hepsi public.is_admin() ile
-- degistiriliyor (bkz. 20260826_membership_profiles.sql).

-- ---------- appointments ----------
drop policy appointments_admin_all on appointments;
create policy appointments_admin_all on appointments
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------- blocked_times ----------
drop policy blocked_times_admin_all on blocked_times;
create policy blocked_times_admin_all on blocked_times
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------- barbers ----------
drop policy barbers_select on barbers;
create policy barbers_select on barbers
  for select to anon, authenticated
  using (active = true or public.is_admin());

drop policy barbers_admin_write on barbers;
create policy barbers_admin_write on barbers
  for insert to authenticated
  with check (public.is_admin());

drop policy barbers_admin_update on barbers;
create policy barbers_admin_update on barbers
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy barbers_admin_delete on barbers;
create policy barbers_admin_delete on barbers
  for delete to authenticated
  using (public.is_admin());

-- ---------- services ----------
drop policy services_select on services;
create policy services_select on services
  for select to anon, authenticated
  using (active = true or public.is_admin());

drop policy services_admin_write on services;
create policy services_admin_write on services
  for insert to authenticated
  with check (public.is_admin());

drop policy services_admin_update on services;
create policy services_admin_update on services
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy services_admin_delete on services;
create policy services_admin_delete on services
  for delete to authenticated
  using (public.is_admin());

-- ---------- chat_sessions / chat_messages ----------
drop policy chat_sessions_admin_read on chat_sessions;
create policy chat_sessions_admin_read on chat_sessions
  for select to authenticated
  using (public.is_admin());

drop policy chat_messages_admin_read on chat_messages;
create policy chat_messages_admin_read on chat_messages
  for select to authenticated
  using (public.is_admin());

-- ---------- email_log ----------
drop policy email_log_admin_read on email_log;
create policy email_log_admin_read on email_log
  for select to authenticated
  using (public.is_admin());
