create table cloud_private.phone_proofs(id text primary key, pubkey text not null, created_at timestamptz not null default now());
alter table cloud_private.phone_proofs enable row level security;
create policy deny_clients on cloud_private.phone_proofs to anon,authenticated using(false) with check(false);
revoke all on cloud_private.phone_proofs from public,anon,authenticated;
create index phone_proofs_owner_time on cloud_private.phone_proofs(pubkey,created_at);
create function public.cloud_phone_claim(p_proof text,p_pubkey text,p_created bigint) returns void language plpgsql set search_path='' as $$
begin
 if p_proof !~ '^[a-f0-9]{64}$' or p_pubkey !~ '^[a-f0-9]{64}$' or abs(extract(epoch from now())-p_created)>65 then raise exception 'invalid phone proof'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_pubkey,0));
 delete from cloud_private.phone_proofs where created_at<now()-interval '1 hour';
 if (select count(*) from cloud_private.phone_proofs where pubkey=p_pubkey)>23 then raise exception 'phone login rate limit'; end if;
 insert into cloud_private.phone_proofs(id,pubkey) values(p_proof,p_pubkey);
end $$;
create function public.cloud_phone_user(p_pubkey text) returns uuid language sql stable set search_path='' as $$
 select id from auth.users where email=p_pubkey||'@phone.slowclaw.invalid' and raw_app_meta_data->>'slowclaw_pubkey'=p_pubkey limit 1;
$$;
revoke all on function public.cloud_phone_claim(text,text,bigint),public.cloud_phone_user(text) from public,anon,authenticated;
grant execute on function public.cloud_phone_claim(text,text,bigint),public.cloud_phone_user(text) to service_role;
update public.cloud_jobs set status='cancelled',error_code='APP_TRANSCRIPTION_ONLY',lease_until=null where kind='transcribe' and status in ('pending','running','blocked','failed');
