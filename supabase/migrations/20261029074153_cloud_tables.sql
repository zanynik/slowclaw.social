create schema if not exists cloud_private;
revoke all on schema cloud_private from public, anon, authenticated;

create table public.cloud_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  sync_enabled boolean not null default false,
  ai_enabled boolean not null default false,
  daily_enabled boolean not null default false,
  provider text not null default 'openai' check (provider in ('openai','openrouter')),
  daily_limit integer not null default 20 check (daily_limit between 0 and 200),
  daily_budget numeric(8,2) not null default 1 check (daily_budget between 0 and 20),
  monthly_budget numeric(8,2) not null default 10 check (monthly_budget between 0 and 200),
  updated_at timestamptz not null default now()
);
create table public.cloud_entries (
  user_id uuid not null references auth.users(id) on delete cascade,
  id text not null check (length(id) between 1 and 200),
  text text not null default '' check (octet_length(text)<=1000000),
  title text not null default '' check (length(title)<=240),
  source text not null default 'text' check (length(source)<=100),
  recorded_at timestamptz not null default now(),
  revision integer not null default 1,
  content_hash text not null,
  deleted_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(user_id,id)
);
create index cloud_entries_changes on public.cloud_entries(user_id,updated_at,id);
create table public.cloud_media (
  user_id uuid not null,
  id uuid not null default gen_random_uuid(),
  entry_id text not null,
  object_path text not null unique,
  filename text not null check (length(filename)<=240),
  mime text not null,
  bytes bigint not null check (bytes between 1 and 52428800),
  sha256 text not null check (sha256 ~ '^[a-f0-9]{64}$'),
  status text not null default 'pending' check (status in ('pending','uploaded','deleting')),
  created_at timestamptz not null default now(),
  primary key(user_id,id),
  foreign key(user_id,entry_id) references public.cloud_entries(user_id,id) on delete cascade,
  unique(user_id,entry_id,sha256)
);
create table public.cloud_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('analyze','transcribe','daily','purge_media')),
  entry_id text,
  input_hash text not null,
  payload jsonb not null default '{}',
  status text not null default 'pending' check (status in ('pending','running','completed','failed','blocked','cancelled')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id,kind,input_hash)
);
create index cloud_jobs_pending on public.cloud_jobs(status,available_at);
create index cloud_jobs_owner on public.cloud_jobs(user_id,created_at desc);
create table public.cloud_artifacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  job_id uuid references public.cloud_jobs(id) on delete cascade,
  kind text not null check(kind in ('summary','action','space','moment','daily','profile')),
  title text not null check(length(title)<=240),
  body jsonb not null,
  sources jsonb not null default '[]',
  state text not null default 'proposed' check(state in ('proposed','accepted','dismissed','completed')),
  stale boolean not null default false,
  model text not null,
  created_at timestamptz not null default now(),
  unique(job_id,kind,title)
);
create index cloud_artifacts_owner on public.cloud_artifacts(user_id,kind,created_at desc);
create table public.cloud_units (
  user_id uuid not null,
  entry_id text not null,
  ordinal integer not null,
  revision integer not null,
  quote text not null,
  start_offset integer not null,
  end_offset integer not null,
  embedding extensions.vector(1536),
  model text not null,
  primary key(user_id,entry_id,ordinal),
  foreign key(user_id,entry_id) references public.cloud_entries(user_id,id) on delete cascade
);
create table public.cloud_reads (
  user_id uuid not null references auth.users(id) on delete cascade,
  url text not null check(length(url)<=2048 and url like 'https://%'),
  title text not null,
  description text not null default '',
  source text not null,
  score double precision not null default 0,
  reason text not null default '',
  read_at timestamptz,
  created_at timestamptz not null default now(),
  primary key(user_id,url)
);
create table public.cloud_usage (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  job_id uuid not null references public.cloud_jobs(id) on delete cascade,
  attempt integer not null,
  reserved_usd numeric(9,4) not null,
  created_at timestamptz not null default now(),
  unique(job_id,attempt)
);
-- Private mapping; decrypted provider keys never enter a client-visible table.
create table cloud_private.provider_keys (
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null check(provider in ('openai','openrouter')),
  secret_id uuid not null references vault.secrets(id),
  primary key(user_id,provider)
);
alter table cloud_private.provider_keys enable row level security;;
