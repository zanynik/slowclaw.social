-- Commit a transcript only while its source, job lease and AI consent are still current.
create function public.cloud_commit_transcript(p_job uuid,p_lease uuid,p_revision integer,p_text text)
returns boolean language plpgsql set search_path='' as $$
declare j public.cloud_jobs; e public.cloud_entries; owner_id uuid; result jsonb;
begin
  select user_id into owner_id from public.cloud_jobs where id=p_job;
  if owner_id is null then return false; end if;
  perform pg_advisory_xact_lock(hashtextextended(owner_id::text,0));
  select * into j from public.cloud_jobs where id=p_job for update;
  if j.kind<>'transcribe' or j.status<>'running' or j.lease_token<>p_lease or j.lease_until<now() then return false; end if;
  if not exists(select 1 from public.cloud_settings where user_id=owner_id and sync_enabled and ai_enabled) then
    update public.cloud_jobs set status='blocked',error_code='PROCESSING_DISABLED',updated_at=now() where id=p_job; return false;
  end if;
  select * into e from public.cloud_entries where user_id=owner_id and id=j.entry_id and revision=p_revision and deleted_at is null for update;
  if not found then update public.cloud_jobs set status='cancelled',updated_at=now() where id=p_job; return false; end if;
  result:=public.cloud_save_entry(owner_id,e.id,p_text,e.title,e.source,e.recorded_at,e.revision,false);
  if not (result->>'ok')::boolean then return false; end if;
  update public.cloud_jobs set status='completed',lease_until=null,updated_at=now() where id=p_job;
  return true;
end $$;
revoke all on function public.cloud_commit_transcript(uuid,uuid,integer,text) from public,anon,authenticated;
grant execute on function public.cloud_commit_transcript(uuid,uuid,integer,text) to service_role;
create index cloud_usage_owner_time on public.cloud_usage(user_id,created_at);
create index cloud_usage_job on public.cloud_usage(job_id);;
