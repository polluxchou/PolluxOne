-- 每次 take 一行。§7 的「近 10 次中位」需要真的有 10 个样本可取，
-- 而 user_reading_rates 一个语种只有一行。
create table reading_rate_samples (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  language text not null check (language in ('cjk', 'latin')),
  chars_per_second real not null check (chars_per_second > 0),
  recorded_at timestamptz not null default now()
);

alter table reading_rate_samples enable row level security;

create policy "reading_rate_samples are owner-scoped" on reading_rate_samples
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 取最近 N 条的查询要走这个索引
create index reading_rate_samples_recent
  on reading_rate_samples (user_id, language, recorded_at desc);
