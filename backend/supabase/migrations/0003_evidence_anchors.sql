-- 句内证据锚点：审稿页那条虚线下划线的位置。
-- start/length 以 **Character** 计，不是 UTF-16 code unit —— 句中一有中文，
-- 用 UTF-16 会让后面每条下划线整体错位，且越往后偏得越多。
create table evidence_anchors (
  id uuid primary key default gen_random_uuid(),
  sentence_id uuid not null,
  claim_id uuid not null,
  char_start integer not null check (char_start >= 0),
  char_length integer not null check (char_length > 0),
  -- 锚点依附于一条 evidence；evidence 没了，锚点没有意义
  foreign key (sentence_id, claim_id)
    references script_evidence (sentence_id, claim_id) on delete cascade,
  -- 同一条 evidence 的多个锚点不许起点相同
  unique (sentence_id, claim_id, char_start)
);

alter table evidence_anchors enable row level security;

create policy "evidence_anchors follow their evidence" on evidence_anchors
  for all using (
    exists (
      select 1 from script_evidence e
      join sentences s on s.id = e.sentence_id
      join paragraphs p on p.id = s.paragraph_id
      join script_sections sec on sec.id = p.section_id
      join scripts sc on sc.id = sec.script_id
      where e.sentence_id = evidence_anchors.sentence_id
        and e.claim_id = evidence_anchors.claim_id
        and sc.user_id = auth.uid()
    )
  );

create index evidence_anchors_by_sentence on evidence_anchors (sentence_id);

-- 被判为转载、已归并掉的篇数。与 independence 分开存：
-- 两者相加（3 + 6 = 9）正是 §5 开头「5 家门户转载不是 5 个源」要防的误读，
-- 合并成一个数就只剩「3 个独立信源」，没法显示「另有 6 篇未计入」。
alter table brief_claims
  add column merged_away_count integer not null default 0
  check (merged_away_count >= 0);
