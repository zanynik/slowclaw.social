create table cloud_private.qr_logins(id text primary key check(id ~ '^[a-f0-9]{64}$'), secret_hash text not null,address_hash text not null,created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '2 minutes',payload text check(length(payload)<=20000),consumed boolean not null default false);
alter table cloud_private.qr_logins enable row level security;
create policy deny_clients on cloud_private.qr_logins to anon,authenticated using(false) with check(false);
revoke all on cloud_private.qr_logins from public,anon,authenticated;
grant select,insert,update,delete on cloud_private.qr_logins to service_role;
create index qr_logins_created on cloud_private.qr_logins(created_at);
create function public.cloud_qr(p_action text,p_id text,p_secret text,p_payload text,p_address text) returns jsonb language plpgsql set search_path='' as $$
declare r cloud_private.qr_logins;
begin
 if p_id !~ '^[a-f0-9]{64}$' then raise exception 'invalid QR'; end if;
 if p_action='start' then
  if p_secret !~ '^[a-f0-9]{64}$' or p_address !~ '^[a-f0-9]{64}$' then raise exception 'invalid capability'; end if;
  perform pg_advisory_xact_lock(hashtextextended('cloud_qr_creation',0));
  delete from cloud_private.qr_logins where created_at<now()-interval '10 minutes';
  if (select count(*) from cloud_private.qr_logins)>999 or (select count(*) from cloud_private.qr_logins where address_hash=p_address)>11 then raise exception 'QR quota'; end if;
  insert into cloud_private.qr_logins(id,secret_hash,address_hash) values(p_id,encode(extensions.digest(p_secret,'sha256'),'hex'),p_address) returning * into r;
  return jsonb_build_object('expires',extract(epoch from r.expires_at));
 end if;
 select * into r from cloud_private.qr_logins where id=p_id for update;
 if not found or r.expires_at<=now() or r.consumed then return jsonb_build_object('error','QR_EXPIRED'); end if;
 if p_action='complete' then
  if p_payload is null or length(p_payload) not between 40 and 20000 then raise exception 'invalid sealed session'; end if;
  if r.payload is not null and r.payload<>p_payload then raise exception 'already approved'; end if;
  update cloud_private.qr_logins set payload=p_payload where id=p_id;
  return jsonb_build_object('ok',true);
 end if;
 if p_action not in ('poll','ack') or p_secret !~ '^[a-f0-9]{64}$' or encode(extensions.digest(p_secret,'sha256'),'hex')<>r.secret_hash then return jsonb_build_object('error','QR_EXPIRED'); end if;
 if p_action='ack' then
  if r.payload is null then return jsonb_build_object('error','QR_NOT_APPROVED'); end if;
  update cloud_private.qr_logins set payload=null,consumed=true where id=p_id;
  return jsonb_build_object('ok',true);
 end if;
 return jsonb_build_object('payload',r.payload);
end $$;
revoke all on function public.cloud_qr(text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.cloud_qr(text,text,text,text,text) to service_role;
