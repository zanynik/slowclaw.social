create function public.cloud_save_entry(p_user uuid,p_id text,p_text text,p_title text,p_source text,p_recorded timestamptz,p_revision integer,p_deleted boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare old public.cloud_entries; next public.cloud_entries; h text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_user::text,0));
  if not exists(select 1 from public.cloud_settings where user_id=p_user and sync_enabled) then raise exception 'SYNC_DISABLED'; end if;
  h:=encode(extensions.digest(case when p_deleted then '' else p_text end,'sha256'),'hex');
  select * into old from public.cloud_entries where user_id=p_user and id=p_id for update;
  if found then
    if old.content_hash=h and (p_deleted or old.title=p_title) and (old.deleted_at is not null)=p_deleted then return jsonb_build_object('ok',true,'entry',to_jsonb(old)); end if;
    if old.revision<>p_revision then return jsonb_build_object('ok',false,'conflict',to_jsonb(old)); end if;
    update public.cloud_entries set text=p_text,title=p_title,source=p_source,content_hash=h,revision=revision+1,
      deleted_at=case when p_deleted then now() else null end,updated_at=now() where user_id=p_user and id=p_id returning * into next;
  else
    if p_revision<>0 then return jsonb_build_object('ok',false,'conflict',null); end if;
    if (select count(*) from public.cloud_entries where user_id=p_user)>=20000 then raise exception 'ENTRY_QUOTA'; end if;
    insert into public.cloud_entries(user_id,id,text,title,source,recorded_at,content_hash,deleted_at)
    values(p_user,p_id,p_text,p_title,p_source,coalesce(p_recorded,now()),h,case when p_deleted then now() else null end) returning * into next;
  end if;
  update public.cloud_jobs set status='cancelled',updated_at=now() where user_id=p_user and entry_id=p_id and status in ('pending','blocked','running','failed');
  update public.cloud_artifacts set stale=true where user_id=p_user and sources @> jsonb_build_array(jsonb_build_object('id',p_id));
  delete from public.cloud_units where user_id=p_user and entry_id=p_id;
  if p_deleted then
    -- Keep the deletion marker, remove copied text and source-derived output.
    update public.cloud_entries set text='',title='',content_hash=encode(extensions.digest('','sha256'),'hex') where user_id=p_user and id=p_id returning * into next;
    delete from public.cloud_artifacts where user_id=p_user and sources @> jsonb_build_array(jsonb_build_object('id',p_id));
    insert into public.cloud_jobs(user_id,kind,entry_id,input_hash) values(p_user,'purge_media',p_id,p_id||':'||next.revision) on conflict do nothing;
  elsif exists(select 1 from public.cloud_settings where user_id=p_user and ai_enabled) and length(trim(p_text))>0 then
    insert into public.cloud_jobs(user_id,kind,entry_id,input_hash) values(p_user,'analyze',p_id,p_id||':'||next.revision) on conflict do nothing;
  end if;
  return jsonb_build_object('ok',true,'entry',to_jsonb(next));
end $$;;
