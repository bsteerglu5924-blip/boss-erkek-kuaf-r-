-- Trigger fonksiyonlari sadece trigger olarak calismali, RPC olarak
-- disaridan cagrilabilir olmamali (linter: anon/authenticated_security_
-- definer_function_executable ve function_search_path_mutable uyarilari).
revoke execute on function public.set_appointment_charged_price() from public, anon, authenticated;
revoke execute on function public.reset_review_status_on_edit() from public, anon, authenticated;

create or replace function public.reset_review_status_on_edit()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.rating is distinct from old.rating or new.comment is distinct from old.comment then
    new.status := 'pending';
  end if;
  return new;
end;
$$;

revoke execute on function public.reset_review_status_on_edit() from public, anon, authenticated;
