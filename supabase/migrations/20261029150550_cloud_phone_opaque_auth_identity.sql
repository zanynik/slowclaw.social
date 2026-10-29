-- Public signup must not be able to reserve a known phone identity's internal email.
select vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'slowclaw_phone_login_pepper') where not exists(select 1 from vault.secrets where name='slowclaw_phone_login_pepper');
create function public.cloud_phone_email(p_pubkey text) returns text language sql stable security definer set search_path='' as $$
 select encode(extensions.hmac(p_pubkey,decrypted_secret,'sha256'),'hex')||'@phone.slowclaw.invalid' from vault.decrypted_secrets where name='slowclaw_phone_login_pepper' and p_pubkey ~ '^[a-f0-9]{64}$' limit 1;
$$;
create or replace function public.cloud_phone_user(p_pubkey text) returns uuid language sql stable security definer set search_path='' as $$
 select id from auth.users where raw_app_meta_data->>'slowclaw_pubkey'=p_pubkey order by created_at limit 1;
$$;
revoke all on function public.cloud_phone_email(text),public.cloud_phone_user(text) from public,anon,authenticated;
grant execute on function public.cloud_phone_email(text),public.cloud_phone_user(text) to service_role;
