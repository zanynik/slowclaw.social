-- Preparatory schema for the future server adapter; NOT applied by the current runtime.
-- Apply once through an authorized database administrator after reviewing the plan.
begin;
create schema if not exists slowclaw;
revoke all on schema slowclaw from public, anon, authenticated;
create table slowclaw.sessions (
  id text primary key, browser_hash text not null, pair_hash text not null,
  pubkey text, created bigint not null, expires bigint not null,
  closed integer not null default 0 check (closed in (0,1)),
  snapshot text, updated bigint
);
create index on slowclaw.sessions(expires);
create table slowclaw.transfers (
  id text primary key, session text not null references slowclaw.sessions(id) on delete cascade,
  meta text not null, bytes bigint not null check (bytes >= 0),
  status text not null, created bigint not null
);
create index on slowclaw.transfers(session);
create table slowclaw.proofs (
  id text primary key, session text not null references slowclaw.sessions(id) on delete cascade
);
create table slowclaw.journal_edits (
  id text primary key, session text not null references slowclaw.sessions(id) on delete cascade,
  sealed text not null, status text not null default 'queued', result text, created bigint not null,
  queue_order bigint generated always as identity unique
);
create index on slowclaw.journal_edits(session, queue_order);
alter table slowclaw.sessions enable row level security;
alter table slowclaw.transfers enable row level security;
alter table slowclaw.proofs enable row level security;
alter table slowclaw.journal_edits enable row level security;
revoke all on all tables in schema slowclaw from public, anon, authenticated;
revoke all on all sequences in schema slowclaw from public, anon, authenticated;
-- Provision a separate least-privilege server role and its RLS policies/grants.
-- No browser/anonymous policies are provided. Private storage is provisioned separately.
commit;
