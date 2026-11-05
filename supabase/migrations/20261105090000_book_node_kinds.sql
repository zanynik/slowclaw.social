-- Book v2: besides the author's passages, the book holds short lines written on the phone
-- (chapter openings and connecting lines). Older apps keep working: the default is 'passage'.
alter table public.book_nodes
  add column kind text not null default 'passage' check (kind in ('passage', 'bridge', 'intro'));
