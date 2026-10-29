do $$ declare t text; begin
  foreach t in array array['cloud_settings','cloud_entries','cloud_media','cloud_jobs','cloud_artifacts','cloud_units','cloud_reads','cloud_usage'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from anon, authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    execute format('create policy owner_read on public.%I for select to authenticated using ((select auth.uid())=user_id)',t);
  end loop;
end $$;
grant insert,update on public.cloud_settings to authenticated;
create policy owner_insert on public.cloud_settings for insert to authenticated with check ((select auth.uid())=user_id);
create policy owner_update on public.cloud_settings for update to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);
grant update(state,title) on public.cloud_artifacts to authenticated;
create policy owner_update on public.cloud_artifacts for update to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);
grant update(read_at) on public.cloud_reads to authenticated;
create policy owner_update on public.cloud_reads for update to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('slowclaw-audio','slowclaw-audio',false,52428800,array['audio/mp4','audio/mpeg','audio/wav','audio/x-wav','audio/webm','audio/aac','audio/flac','application/octet-stream'])
on conflict(id) do nothing;
create policy cloud_audio_read on storage.objects for select to authenticated
using(bucket_id='slowclaw-audio' and exists(select 1 from public.cloud_media m join public.cloud_entries e on e.user_id=m.user_id and e.id=m.entry_id
where m.object_path=name and m.user_id=(select auth.uid()) and m.status='uploaded' and e.deleted_at is null));
-- No direct client upload/delete policies. Short-lived signed upload URLs are issued after quota/ownership checks.

-- Serialize changes per account. Retrying an acknowledged write is idempotent; stale writes return a conflict.;
