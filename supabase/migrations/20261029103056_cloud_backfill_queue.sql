-- Queue only missing analyses, so enabling AI after a backup also processes older journals.
create function public.cloud_enqueue_missing(p_user uuid) returns integer language plpgsql set search_path='' as $$
declare n integer;
begin
  insert into public.cloud_jobs(user_id,kind,entry_id,input_hash)
  select e.user_id,'analyze',e.id,e.id||':'||e.revision from public.cloud_entries e
  join public.cloud_settings s on s.user_id=e.user_id and s.sync_enabled and s.ai_enabled
  where e.user_id=p_user and e.deleted_at is null and length(trim(e.text))>0 and e.text not like '%transcribing…%'
  and not exists(select 1 from public.cloud_jobs j where j.user_id=e.user_id and j.kind='analyze' and j.input_hash=e.id||':'||e.revision)
  order by e.updated_at desc limit 100 on conflict do nothing;
  get diagnostics n=row_count;
  return n;
end $$;
revoke all on function public.cloud_enqueue_missing(uuid) from public,anon,authenticated;
grant execute on function public.cloud_enqueue_missing(uuid) to service_role;;
