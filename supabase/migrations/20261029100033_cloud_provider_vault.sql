create function cloud_private.provider_secret(p_user uuid,p_provider text,p_value text default null,p_remove boolean default false)
returns text language plpgsql security definer set search_path='' as $$
declare sid uuid; result text;
begin
  if p_provider not in ('openai','openrouter') then raise exception 'INVALID_PROVIDER'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_user::text,1));
  select secret_id into sid from cloud_private.provider_keys where user_id=p_user and provider=p_provider;
  if p_remove then
    delete from cloud_private.provider_keys where user_id=p_user and provider=p_provider;
    if sid is not null then delete from vault.secrets where id=sid; end if; return null;
  elsif p_value is not null then
    if length(p_value)<20 or length(p_value)>500 then raise exception 'INVALID_KEY'; end if;
    if sid is null then
      sid:=vault.create_secret(p_value);
      insert into cloud_private.provider_keys values(p_user,p_provider,sid);
    else perform vault.update_secret(sid,p_value); end if;
    return 'configured';
  end if;
  select decrypted_secret into result from vault.decrypted_secrets where id=sid;
  return result;
end $$;
revoke all on function cloud_private.provider_secret(uuid,text,text,boolean) from public,anon,authenticated;
grant usage on schema cloud_private to service_role;
grant execute on function cloud_private.provider_secret(uuid,text,text,boolean) to service_role;
create function public.cloud_provider_secret(p_user uuid,p_provider text,p_value text default null,p_remove boolean default false)
returns text language sql set search_path='' as $$ select cloud_private.provider_secret(p_user,p_provider,p_value,p_remove); $$;

-- Commit only against the leased, current source revision. Deletion/edit races discard old AI output.;
