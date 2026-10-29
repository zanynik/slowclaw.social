create table public.cloud_entry_history (
  user_id uuid not null, id text not null, revision integer not null,
  text text not null, title text not null, source text not null, recorded_at timestamptz not null,
  content_hash text not null, deleted_at timestamptz, updated_at timestamptz not null,
  primary key(user_id,id,revision),
  foreign key(user_id,id) references public.cloud_entries(user_id,id) on delete cascade
);


alter table public.cloud_entry_history enable row level security;
revoke all on public.cloud_entry_history from anon,authenticated;
grant select on public.cloud_entry_history to authenticated;
grant all on public.cloud_entry_history to service_role;
create policy owner_read on public.cloud_entry_history for select to authenticated using ((select auth.uid())=user_id);
alter table public.cloud_usage drop constraint if exists cloud_usage_job_id_attempt_key;;
