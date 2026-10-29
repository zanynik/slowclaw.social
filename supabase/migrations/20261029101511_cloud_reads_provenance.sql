alter table public.cloud_reads add column if not exists sources jsonb not null default '[]';;
