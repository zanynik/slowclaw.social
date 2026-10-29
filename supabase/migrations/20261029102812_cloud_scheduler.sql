-- Runtime URL and scheduler capability remain outside source control.
create table cloud_private.runtime (
  id integer primary key check(id=1),
  api_url text not null check(api_url ~ '^https://[a-z0-9]+\.supabase\.co$')
);
alter table cloud_private.runtime enable row level security;
revoke all on cloud_private.runtime from public,anon,authenticated;
create policy deny_clients on cloud_private.runtime for all to anon,authenticated using(false) with check(false);
create policy deny_clients on cloud_private.provider_keys for all to anon,authenticated using(false) with check(false);

do $$ begin
  if not exists(select 1 from vault.secrets where name='slowclaw-scheduler-token') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'slowclaw-scheduler-token','Internal processing scheduler capability');
  end if;
end $$;
create function cloud_private.tick() returns void language plpgsql security definer set search_path='' as $$
declare endpoint text; token text;
begin
  select api_url into endpoint from cloud_private.runtime where id=1;
  if endpoint is null then return; end if;
  select decrypted_secret into token from vault.decrypted_secrets where name='slowclaw-scheduler-token';
  if token is null then return; end if;
  perform net.http_post(url:=endpoint||'/functions/v1/cloud-worker',headers:=jsonb_build_object('Content-Type','application/json','x-slowclaw-cron',token),body:='{}'::jsonb,timeout_milliseconds:=140000);
end $$;
revoke all on function cloud_private.tick() from public,anon,authenticated;
select cron.schedule('slowclaw-cloud-worker','* * * * *','select cloud_private.tick();');;
