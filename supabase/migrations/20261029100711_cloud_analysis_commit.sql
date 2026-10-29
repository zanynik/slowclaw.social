create function public.cloud_commit_analysis(p_job uuid,p_lease uuid,p_revision integer,p_artifacts jsonb,p_units jsonb,p_model text)
returns boolean language plpgsql set search_path='' as $$
declare j public.cloud_jobs; e public.cloud_entries; a jsonb; u jsonb;
begin
  select * into j from public.cloud_jobs where id=p_job for update;
  if j.status<>'running' or j.lease_token<>p_lease or j.lease_until<now() then return false; end if;
  select * into e from public.cloud_entries where user_id=j.user_id and id=j.entry_id for update;
  if not found or e.deleted_at is not null or e.revision<>p_revision
    or not exists(select 1 from public.cloud_settings where user_id=j.user_id and sync_enabled and ai_enabled) then
    update public.cloud_jobs set status='cancelled',updated_at=now() where id=j.id; return false;
  end if;
  delete from public.cloud_artifacts where job_id=j.id;
  for a in select * from jsonb_array_elements(p_artifacts) loop
    insert into public.cloud_artifacts(user_id,job_id,kind,title,body,sources,model)
    values(j.user_id,j.id,a->>'kind',a->>'title',a->'body',jsonb_build_array(jsonb_build_object('id',e.id,'revision',e.revision)),p_model);
  end loop;
  delete from public.cloud_units where user_id=j.user_id and entry_id=e.id;
  for u in select * from jsonb_array_elements(p_units) loop
    if substring(e.text from (u->>'start')::integer+1 for (u->>'end')::integer-(u->>'start')::integer)<>u->>'quote' then raise exception 'INVALID_SOURCE'; end if;
    insert into public.cloud_units(user_id,entry_id,ordinal,revision,quote,start_offset,end_offset,embedding,model)
    values(j.user_id,e.id,(u->>'ordinal')::integer,e.revision,u->>'quote',(u->>'start')::integer,(u->>'end')::integer,(u->>'embedding')::extensions.vector,'text-embedding-3-small:1536');
  end loop;
  update public.cloud_jobs set status='completed',lease_until=null,updated_at=now() where id=j.id;
  return true;
end $$;

-- Explicit grants prevent service-only RPCs being callable by ordinary accounts.
do $$ declare f record; begin
  for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'cloud_%' loop
    execute format('revoke all on function %s from public,anon,authenticated',f.signature);
    execute format('grant execute on function %s to service_role',f.signature);
  end loop;
end $$;;
