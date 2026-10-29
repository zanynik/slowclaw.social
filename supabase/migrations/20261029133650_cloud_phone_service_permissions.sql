grant select,insert,delete on cloud_private.phone_proofs to service_role;
-- Narrow, service-only lookup of a server-managed identity claim; no client execution.
alter function public.cloud_phone_user(text) security definer;
revoke all on function public.cloud_phone_user(text) from public,anon,authenticated;
grant execute on function public.cloud_phone_user(text) to service_role;
