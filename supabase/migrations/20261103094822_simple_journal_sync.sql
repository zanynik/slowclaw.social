-- Simple text-only sync for the rebuilt app: journals, spaces and space items.
-- Clients talk to these tables directly through PostgREST; row-level security
-- limits every row to its owner. Audio is never stored in the cloud.

create or replace function public.touch_synced()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Last edit wins: ignore writes older than what is stored.
  if tg_op = 'UPDATE' and new.updated_at < old.updated_at then
    return old;
  end if;
  new.synced_at := clock_timestamp();
  return new;
end;
$$;

create table public.spaces (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id text not null check (length(id) between 1 and 200),
  name text not null default '' check (length(name) <= 80),
  icon text not null default 'tray' check (length(icon) <= 60),
  summary text not null default '' check (length(summary) <= 4000),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted boolean not null default false,
  synced_at timestamptz not null default clock_timestamp(),
  primary key (user_id, id)
);

create table public.journals (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id text not null check (length(id) between 1 and 200),
  title text not null default '' check (length(title) <= 300),
  body text not null default '' check (octet_length(body) <= 1000000),
  space_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted boolean not null default false,
  synced_at timestamptz not null default clock_timestamp(),
  primary key (user_id, id)
);

create table public.space_items (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id text not null check (length(id) between 1 and 200),
  space_id text not null,
  journal_id text,
  kind text not null check (kind in ('todo', 'idea', 'question', 'note')),
  text text not null default '' check (length(text) <= 2000),
  done boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted boolean not null default false,
  synced_at timestamptz not null default clock_timestamp(),
  primary key (user_id, id)
);

create index spaces_sync on public.spaces (user_id, synced_at);
create index journals_sync on public.journals (user_id, synced_at);
create index space_items_sync on public.space_items (user_id, synced_at);

create trigger spaces_touch before insert or update on public.spaces
  for each row execute function public.touch_synced();
create trigger journals_touch before insert or update on public.journals
  for each row execute function public.touch_synced();
create trigger space_items_touch before insert or update on public.space_items
  for each row execute function public.touch_synced();

alter table public.spaces enable row level security;
alter table public.journals enable row level security;
alter table public.space_items enable row level security;

create policy spaces_owner on public.spaces for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy journals_owner on public.journals for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy space_items_owner on public.space_items for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

revoke all on public.spaces, public.journals, public.space_items from anon;
grant select, insert, update, delete on public.spaces, public.journals, public.space_items to authenticated;

-- Carry over journals already synced by the previous cloud version.
insert into public.journals (user_id, id, title, body, created_at, updated_at, deleted)
select user_id, id, title, text, recorded_at, updated_at, deleted_at is not null
from public.cloud_entries
on conflict (user_id, id) do nothing;

-- The previous AI worker polled every minute; the new app does everything on the phone.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'slowclaw-cloud-worker') then
    perform cron.unschedule('slowclaw-cloud-worker');
  end if;
end;
$$;
