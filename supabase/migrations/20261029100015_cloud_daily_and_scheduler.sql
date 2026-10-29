create function public.cloud_commit_daily(p_job uuid,p_lease uuid,p_artifacts jsonb,p_sources jsonb,p_model text)
returns boolean language plpgsql set search_path='' as $$
declare j public.cloud_jobs; a jsonb; s jsonb;
begin
  select * into j from public.cloud_jobs where id=p_job for update;
  if j.status<>'running' or j.lease_token<>p_lease or j.lease_until<now() then return false; end if;
  if not exists(select 1 from public.cloud_settings where user_id=j.user_id and sync_enabled and ai_enabled and daily_enabled) then return false; end if;
  -- Match every source version and hold locks until all derived output is committed.
  for s in select * from jsonb_array_elements(p_sources) loop
    perform 1 from public.cloud_entries where user_id=j.user_id and id=s->>'id' and revision=(s->>'revision')::integer and deleted_at is null for update;
    if not found then update public.cloud_jobs set status='cancelled',updated_at=now() where id=j.id; return false; end if;
  end loop;
  for a in select * from jsonb_array_elements(p_artifacts) loop
    insert into public.cloud_artifacts(user_id,job_id,kind,title,body,sources,model)
    values(j.user_id,j.id,a->>'kind',a->>'title',a->'body',p_sources,p_model) on conflict(job_id,kind,title) do nothing;
  end loop;
  update public.cloud_jobs set status='completed',lease_until=null,updated_at=now() where id=j.id;
  return true;
end $$;

-- Remove Vault copies when an account is deleted (ordinary FK cascade removes the mapping).
create function cloud_private.remove_provider_key() returns trigger language plpgsql security definer set search_path='' as $$
begin delete from vault.secrets where id=old.secret_id; return old; end $$;
revoke all on function cloud_private.remove_provider_key() from public,anon,authenticated;
create trigger provider_key_removed after delete on cloud_private.provider_keys for each row execute function cloud_private.remove_provider_key();

-- Cron credentials are generated inside Postgres, never checked into source or returned to a client.
create function public.cloud_scheduler_authorized(p_token text) returns boolean language sql security definer set search_path='' as $$
  select coalesce(length(p_token)=64 and extensions.digest(p_token,'sha256')=extensions.digest((select decrypted_secret from vault.decrypted_secrets where name='slowclaw-scheduler-token'),'sha256'),false);
$$;

-- A lease and conservative spend reservation are committed before any provider call.
-- Unknown outcomes remain reserved; provider-side limits are still recommended.;
