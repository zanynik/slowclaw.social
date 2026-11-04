-- Living book: passages the phone accepted into the book, with their place on the
-- reading path and on the 2D map. Text only; the vectors stay on the phone.
create table public.book_nodes (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id text not null check (length(id) between 1 and 200),
  journal_id text,
  text text not null default '' check (length(text) <= 4000),
  position double precision not null default 0,
  chapter integer not null default 0,
  chapter_title text not null default '' check (length(chapter_title) <= 120),
  x real not null default 0.5,
  y real not null default 0.5,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted boolean not null default false,
  synced_at timestamptz not null default clock_timestamp(),
  primary key (user_id, id)
);

create index book_nodes_sync on public.book_nodes (user_id, synced_at);
create trigger book_nodes_touch before insert or update on public.book_nodes
  for each row execute function public.touch_synced();

alter table public.book_nodes enable row level security;
create policy book_nodes_owner on public.book_nodes for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.book_nodes from anon;
grant select, insert, update, delete on public.book_nodes to authenticated;

-- Nostr keys linked to an account. Only the cloud-login function writes here, and only
-- after checking both a signed proof from the key and a valid session for the account.
create table cloud_private.nostr_links (
  pubkey text primary key check (pubkey ~ '^[a-f0-9]{64}$'),
  user_id uuid not null references auth.users(id) on delete cascade,
  linked_at timestamptz not null default now()
);
alter table cloud_private.nostr_links enable row level security;
create policy deny_clients on cloud_private.nostr_links to anon, authenticated using (false) with check (false);
revoke all on cloud_private.nostr_links from public, anon, authenticated;
grant select, insert, update, delete on cloud_private.nostr_links to service_role;

create function public.cloud_nostr_link(p_pubkey text, p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_pubkey !~ '^[a-f0-9]{64}$' or p_user is null then raise exception 'invalid link'; end if;
  insert into cloud_private.nostr_links (pubkey, user_id) values (p_pubkey, p_user)
  on conflict (pubkey) do update set user_id = excluded.user_id, linked_at = now();
end;
$$;

-- Linked account first; otherwise the account an earlier build created for this key.
create function public.cloud_nostr_user(p_pubkey text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select user_id from cloud_private.nostr_links where pubkey = p_pubkey),
    (select id from auth.users where raw_app_meta_data->>'slowclaw_pubkey' = p_pubkey order by created_at limit 1)
  );
$$;

revoke all on function public.cloud_nostr_link(text, uuid) from public, anon, authenticated;
revoke all on function public.cloud_nostr_user(text) from public, anon, authenticated;
grant execute on function public.cloud_nostr_link(text, uuid) to service_role;
grant execute on function public.cloud_nostr_user(text) to service_role;
