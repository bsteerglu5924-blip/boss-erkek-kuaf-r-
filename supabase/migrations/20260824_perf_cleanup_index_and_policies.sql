-- Add missing FK index, and collapse the two permissive SELECT policies on
-- barbers/services (public_read + admin_all) into one per role/action to
-- satisfy the Supabase performance lint (multiple_permissive_policies).
create index idx_appointments_service_id on appointments (service_id);

drop policy barbers_public_read on barbers;
drop policy barbers_admin_all on barbers;
create policy barbers_select on barbers for select to anon, authenticated using (active = true or (select auth.role()) = 'authenticated');
create policy barbers_admin_write on barbers for insert to authenticated with check (true);
create policy barbers_admin_update on barbers for update to authenticated using (true) with check (true);
create policy barbers_admin_delete on barbers for delete to authenticated using (true);

drop policy services_public_read on services;
drop policy services_admin_all on services;
create policy services_select on services for select to anon, authenticated using (active = true or (select auth.role()) = 'authenticated');
create policy services_admin_write on services for insert to authenticated with check (true);
create policy services_admin_update on services for update to authenticated using (true) with check (true);
create policy services_admin_delete on services for delete to authenticated using (true);
