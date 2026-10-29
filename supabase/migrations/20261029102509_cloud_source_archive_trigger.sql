create function cloud_private.entry_revision_history() returns trigger language plpgsql set search_path='' as $$
begin
  if new.deleted_at is not null then
    delete from public.cloud_entry_history where user_id=new.user_id and id=new.id;
    update public.cloud_reads set reason='' where user_id=new.user_id and sources @> jsonb_build_array(jsonb_build_object('id',new.id));
  elsif old.revision<>new.revision then
    insert into public.cloud_entry_history(user_id,id,text,title,source,recorded_at,revision,content_hash,deleted_at,updated_at) values
      (old.user_id,old.id,old.text,old.title,old.source,old.recorded_at,old.revision,old.content_hash,old.deleted_at,old.updated_at) on conflict do nothing;
  end if;
  return new;
end $$;
revoke all on function cloud_private.entry_revision_history() from public,anon,authenticated;
grant execute on function cloud_private.entry_revision_history() to service_role;
create trigger cloud_entry_history after update on public.cloud_entries for each row execute function cloud_private.entry_revision_history();;
