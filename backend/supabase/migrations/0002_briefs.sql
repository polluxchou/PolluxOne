-- ---------------------------------------------------------------------------
-- Brief（一次「新闻 → 口播稿」任务）及其证据层
-- 设计见 docs/superpowers/specs/2026-09-17-news-brief-pipeline-design.md §9
-- ---------------------------------------------------------------------------

create table briefs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 只有两类：文本、图。链接是文本的子情况，由管线自己判断（§9 决策）
  input_kind text not null check (input_kind in ('text', 'image')),
  input_payload text not null,
  -- 口述路径带的「我想怎么播」，链接/截图路径为 null（§2.3）
  angle text,
  duration_sec integer not null,
  -- 0.0 八卦 – 1.0 专业
  register real not null check (register >= 0 and register <= 1),
  status text not null default 'queued'
    check (status in ('queued', 'running', 'drafted', 'confirmed', 'insufficient', 'failed', 'canceled')),
  verdict text,
  tokens_budget integer not null,
  tokens_used integer not null default 0,
  cost_cents integer not null default 0,
  script_id uuid references scripts (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table briefs enable row level security;

create policy "briefs are owner-scoped" on briefs
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 阶段状态机（§4.2）。每阶段结果落库，所以可观测、可重跑、可分别记 token。
create table brief_stages (
  id uuid primary key default gen_random_uuid(),
  brief_id uuid not null references briefs (id) on delete cascade,
  stage text not null,
  status text not null default 'pending'
    check (status in ('pending', 'running', 'done', 'failed')),
  tokens_used integer not null default 0,
  result jsonb,
  error text,
  started_at timestamptz,
  ended_at timestamptz,
  unique (brief_id, stage)
);

alter table brief_stages enable row level security;

create policy "brief_stages follow their brief" on brief_stages
  for all using (
    exists (select 1 from briefs b where b.id = brief_stages.brief_id and b.user_id = auth.uid())
  );

create table brief_sources (
  id uuid primary key default gen_random_uuid(),
  brief_id uuid not null references briefs (id) on delete cascade,
  url text not null,
  publisher text not null,
  published_at timestamptz,
  body text not null,
  -- 存下来只为审计和排查；分组时由管线从 body 现算，不依赖这一列
  fingerprint text,
  credited_to text
);

alter table brief_sources enable row level security;

create policy "brief_sources follow their brief" on brief_sources
  for all using (
    exists (select 1 from briefs b where b.id = brief_sources.brief_id and b.user_id = auth.uid())
  );

create table brief_facts (
  id uuid primary key default gen_random_uuid(),
  brief_id uuid not null references briefs (id) on delete cascade,
  source_id uuid not null references brief_sources (id) on delete cascade,
  text text not null,
  -- 原文逐字引文。后面一切的根（§4.3）
  quote text not null
);

alter table brief_facts enable row level security;

create policy "brief_facts follow their brief" on brief_facts
  for all using (
    exists (select 1 from briefs b where b.id = brief_facts.brief_id and b.user_id = auth.uid())
  );

create table brief_claims (
  id uuid primary key default gen_random_uuid(),
  brief_id uuid not null references briefs (id) on delete cascade,
  text text not null,
  -- 互不相关的信源组数量，不是信源条数
  independence integer not null default 0,
  confidence text not null check (confidence in ('strong', 'weak', 'conflicted'))
);

alter table brief_claims enable row level security;

create policy "brief_claims follow their brief" on brief_claims
  for all using (
    exists (select 1 from briefs b where b.id = brief_claims.brief_id and b.user_id = auth.uid())
  );

create table claim_facts (
  claim_id uuid not null references brief_claims (id) on delete cascade,
  fact_id uuid not null references brief_facts (id) on delete cascade,
  primary key (claim_id, fact_id)
);

alter table claim_facts enable row level security;

create policy "claim_facts follow their claim" on claim_facts
  for all using (
    exists (
      select 1 from brief_claims c join briefs b on b.id = c.brief_id
      where c.id = claim_facts.claim_id and b.user_id = auth.uid()
    )
  );

-- 谁和谁冲突。只在 brief_claims 上记一个 confidence = 'conflicted' 是不够的：
-- 「不建议播」那一屏要把冲突双方并排摆给用户看（路透 23 亿 vs 彭博 31 亿），
-- 光知道「这条有冲突」没法渲染。管线两边都写一行，读的时候按 claim_id 查即可。
create table claim_conflicts (
  claim_id uuid not null references brief_claims (id) on delete cascade,
  conflicts_with uuid not null references brief_claims (id) on delete cascade,
  primary key (claim_id, conflicts_with),
  check (claim_id <> conflicts_with)
);

alter table claim_conflicts enable row level security;

create policy "claim_conflicts follow their claim" on claim_conflicts
  for all using (
    exists (
      select 1 from brief_claims c join briefs b on b.id = c.brief_id
      where c.id = claim_conflicts.claim_id and b.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 证据层：挂在 Script 旁边，Script 自己不加字段（§4.1）
-- ---------------------------------------------------------------------------

create table script_evidence (
  sentence_id uuid not null references sentences (id) on delete cascade,
  claim_id uuid not null references brief_claims (id) on delete cascade,
  -- 写入时的句子内容指纹。Safe Word 当场改稿后文本一变，这一句降级为
  -- 「已改动 · 无信源」，而不是继续显示旧信源（§9.2 ③）
  sentence_fingerprint text not null,
  primary key (sentence_id, claim_id)
);

alter table script_evidence enable row level security;

create policy "script_evidence follows its script" on script_evidence
  for all using (
    exists (
      select 1 from sentences s
      join paragraphs p on p.id = s.paragraph_id
      join script_sections sec on sec.id = p.section_id
      join scripts sc on sc.id = sec.script_id
      where s.id = script_evidence.sentence_id and sc.user_id = auth.uid()
    )
  );

-- 气口。同样挂在旁边——sentences 表不加列（§9.2 ⑤）
--
-- **一句多行**，不是一句一行：`breathMarks` 对每个句内逗号都吐一个带位置的
-- short，句末再吐一个 long。做成每句单个枚举的话，那一列永远只会是 'long'，
-- 而提词器真正用来配速的句内短气口全部无处可去。
--
-- check 约束把 TS 侧的判别联合固化在这里：short 必须带位置，long 必须不带。
-- 重读（emphasis）目前没有任何代码产出，等有了再单独建表。
create table sentence_breaths (
  id uuid primary key default gen_random_uuid(),
  sentence_id uuid not null references sentences (id) on delete cascade,
  kind text not null check (kind in ('long', 'short')),
  char_offset integer,
  check ((kind = 'short') = (char_offset is not null))
);

alter table sentence_breaths enable row level security;

create policy "sentence_breaths follow their script" on sentence_breaths
  for all using (
    exists (
      select 1 from sentences s
      join paragraphs p on p.id = s.paragraph_id
      join script_sections sec on sec.id = p.section_id
      join scripts sc on sc.id = sec.script_id
      where s.id = sentence_breaths.sentence_id and sc.user_id = auth.uid()
    )
  );

create index sentence_breaths_sentence_idx on sentence_breaths (sentence_id);

-- ---------------------------------------------------------------------------
-- 实测语速。这份数据目前根本不存在（§9.2 ①）——本迁移只建表，
-- iOS 侧的采集是另一个计划。
-- ---------------------------------------------------------------------------

create table user_reading_rates (
  user_id uuid not null references auth.users (id) on delete cascade,
  language text not null check (language in ('cjk', 'latin')),
  chars_per_second real not null check (chars_per_second > 0),
  sample_count integer not null default 1,
  updated_at timestamptz not null default now(),
  primary key (user_id, language)
);

alter table user_reading_rates enable row level security;

create policy "user_reading_rates are owner-scoped" on user_reading_rates
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create index brief_stages_brief_idx on brief_stages (brief_id);
create index brief_sources_brief_idx on brief_sources (brief_id);
create index brief_facts_brief_idx on brief_facts (brief_id);
create index brief_claims_brief_idx on brief_claims (brief_id);
create index briefs_user_status_idx on briefs (user_id, status);
