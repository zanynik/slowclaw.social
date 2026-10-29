create or replace function public.cloud_commit_daily(p_job uuid,p_lease uuid,p_artifacts jsonb,p_sources jsonb,p_model text)
returns boolean language plpgsql set search_path='' as $$
declare j public.cloud_jobs; a jsonb; s jsonb; owner_id uuid;
begin
  select user_id into owner_id from public.cloud_jobs where id=p_job;
  if owner_id is null then return false; end if;
  perform pg_advisory_xact_lock(hashtextextended(owner_id::text,0));
  select * into j from public.cloud_jobs where id=p_job for update;
  if j.status<>'running' or j.lease_token<>p_lease or j.lease_until<now() then return false; end if;
  if not exists(select 1 from public.cloud_settings where user_id=j.user_id and sync_enabled and ai_enabled and daily_enabled) then return false; end if;
  -- Match every source version and hold locks until all derived output is committed.
  for s in select * from jsonb_array_elements(p_sources) loop
    perform 1 from public.cloud_entries where user_id=j.user_id and id=s->>'id' and revision=(s->>'revision')::integer and deleted_at is null for update;
    if not found then update public.cloud_jobs set status='cancelled',updated_at=now() where id=j.id; return false; end if;
  end loop;
  for a in select * from jsonb_array_elements(p_artifacts) loop
    if a->>'kind'='read' then
      insert into public.cloud_reads(user_id,url,title,description,source,score,reason,sources)
      values(j.user_id,a->'body'->>'url',a->>'title',a->'body'->>'description',a->'body'->>'source',(a->'body'->>'score')::double precision,a->'body'->>'reason',p_sources)
      on conflict(user_id,url) do update set title=excluded.title,description=excluded.description,score=excluded.score,reason=excluded.reason,sources=excluded.sources;
    else
      insert into public.cloud_artifacts(user_id,job_id,kind,title,body,sources,model)
      values(j.user_id,j.id,a->>'kind',a->>'title',a->'body',p_sources,p_model) on conflict(job_id,kind,title) do nothing;
    end if;
  end loop;
  update public.cloud_jobs set status='completed',lease_until=null,updated_at=now() where id=j.id;
  return true;
end $$;;
