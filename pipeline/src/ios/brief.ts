// pipeline/src/ios/brief.ts
//
// 管线的产物 → iOS 的 `Brief`。
//
// 契约在 `ios/Pollux One/Domain/Brief/BriefModels.swift` / `Evidence.swift` /
// `BriefStage.swift`，这里的每个字段名和大小写都是照着那三个文件抄的：Swift 侧
// 用的是默认的 `JSONDecoder`，没有 `keyDecodingStrategy`，所以字段名对不上就是
// 解码失败，不是某个字段变 nil。

import type { CoreResult } from "../core.js";
import { groupSources } from "../dedupe/independence.js";
import type { ClaimId, Fact, SentenceKind, Source, VerifiedClaim } from "../domain/types.js";
import { anchorsFor, type EvidenceAnchor } from "./anchors.js";

export interface NewsRefJson {
  publisher: string;
  title: string;
  url: string | null;
}

export interface SourceRefJson {
  publisher: string;
  /** mock 第二列：逐字引文。 */
  note: string;
  /** mock 第三列，形如 "15:02"。 */
  time: string;
}

export interface ClaimEvidenceJson {
  id: string;
  independence: number;
  mergedAwayCount: number;
  sources: SourceRefJson[];
}

export interface BriefSentenceJson {
  id: string;
  text: string;
  kind: SentenceKind;
  claimIds: string[];
  anchors: EvidenceAnchor[];
}

export interface BriefStageJson {
  name: string;
  state: "done" | "running" | "pending";
  count: string | null;
  detail: string | null;
}

export interface TokenBudgetJson {
  used: number;
  budgeted: number;
  remainingThisMonth: number;
  costCents: number;
  byStage: Record<string, number>;
}

export interface BriefJson {
  id: string;
  news: NewsRefJson;
  status: "researching" | "ready" | "insufficient";
  estimatedSeconds: number;
  pacedToUser: boolean;
  sentences: BriefSentenceJson[];
  claims: Record<string, ClaimEvidenceJson>;
  recheckResults: Record<string, ClaimEvidenceJson> | null;
  stages: BriefStageJson[];
  budget: TokenBudgetJson;
  insufficientReason: string | null;
}

/** spec §8 ⑤ 的九个阶段，顺序即展示顺序。 */
export const STAGE_NAMES = [
  "抓取原文",
  "扩展检索",
  "抽取事实点",
  "归并去重",
  "交叉验证",
  "选点",
  "成稿",
  "挂信源",
  "时长与气口",
] as const;

/**
 * `"2026-09-17T08:40:00+08:00"` → `"08:40"`。
 *
 * **从字符串上切，不经过 `Date`**：`new Date(...).getHours()` 读的是跑这个
 * 脚本的机器的时区，同一份 fixture 在两台机器上会产出两个不同的时刻。
 * 信源上那个时间是「这家媒体在它自己的时区发稿的钟点」，不是一个可以被
 * 重新投影的瞬间。
 */
export function clockOf(publishedAt: string): string {
  const match = /T(\d{2}:\d{2})/u.exec(publishedAt);
  if (match === null) throw new Error(`publishedAt 里读不出时刻：${publishedAt}`);
  return match[1]!;
}

interface Cited {
  source: Source;
  quote: string;
}

/**
 * 一条 claim 的证据面板。
 *
 * `independence` 是**互不相关的信源组数**，每组只露一个代表；被归并掉的那几篇
 * 进 `mergedAwayCount`，不进 `sources`。两者分开正是 `Evidence.swift` 里写的
 * 理由：把它们相加是用户最容易犯的误读。
 */
function evidenceOf(
  claim: VerifiedClaim,
  facts: readonly Fact[],
  sources: readonly Source[],
): ClaimEvidenceJson {
  const factById = new Map(facts.map((f) => [f.id, f]));
  const sourceById = new Map(sources.map((s) => [s.id, s]));

  // 同一个源可能为同一条 claim 供了多个 fact，按 sourceId 收敛，留最早的引文。
  const cited = new Map<string, Cited>();
  for (const factId of claim.factIds) {
    const fact = factById.get(factId);
    if (fact === undefined) continue;
    const source = sourceById.get(fact.sourceId);
    if (source === undefined) continue;
    if (!cited.has(source.id)) cited.set(source.id, { source, quote: fact.quote });
  }

  const groups = groupSources([...sources]);
  const rows: SourceRefJson[] = [];
  for (const group of groups) {
    const members = group.sourceIds
      .map((id) => cited.get(id))
      .filter((c): c is Cited => c !== undefined)
      // 一组之内谁当代表：最早发的那家。转载晚于原稿，这条排序顺带让代表
      // 总是原稿而不是转载。
      .sort((a, b) => a.source.publishedAt.localeCompare(b.source.publishedAt));
    const first = members[0];
    if (first === undefined) continue;
    rows.push({
      publisher: first.source.publisher,
      note: `「${first.quote}」`,
      time: clockOf(first.source.publishedAt),
    });
  }

  // 内核算的 independence 和这里数出来的组数必须是同一个数。对不上说明两边
  // 对"一个信源"的定义已经分家了，而界面上那个数字是从这里来的——宁可在
  // 生成时炸掉，也不要发出去一个和内核不一致的可信度。
  if (rows.length !== claim.independence) {
    throw new Error(
      `claim ${claim.id} 的独立源数对不上：内核说 ${claim.independence}，证据面板数出 ${rows.length}`,
    );
  }

  return {
    id: claim.id,
    independence: claim.independence,
    mergedAwayCount: cited.size - rows.length,
    sources: rows,
  };
}

export interface StageCounts {
  /** 原文 1 篇 + 扩展检索若干篇。 */
  sourceCount: number;
  /** ③ 抽出来的原始事实条数。 */
  rawFactCount: number;
  /** ③ 逐字校验丢掉的条数。 */
  rejectedFactCount: number;
  /** 信源归并之后的独立源组数。 */
  sourceGroupCount: number;
}

function stagesOf(counts: StageCounts, core: CoreResult, sentenceCount: number): BriefStageJson[] {
  const claims = core.claims;
  const strong = claims.filter((c) => c.confidence === "strong").length;
  const kept = counts.rawFactCount - counts.rejectedFactCount;
  const evidenceRows = core.bind.ok ? core.bind.evidence.length : 0;

  const extracted =
    counts.rejectedFactCount > 0
      ? `${kept} 条 · ${counts.rejectedFactCount} 条引文对不上已丢弃`
      : `${kept} 条`;

  const values: string[] = [
    "1 篇",
    `${counts.sourceCount - 1} 篇`,
    extracted,
    `${claims.length} 点 · ${counts.sourceGroupCount} 独立源`,
    `${strong} / ${claims.length}`,
    `${core.selection.picked.length} 条`,
    `${sentenceCount} 句`,
    `${evidenceRows} 句挂上`,
    `${Math.round(core.seconds)} 秒 · ${core.breaths.length} 个气口`,
  ];

  // detail 是"进行中那一阶段底下的实时说明"——九个阶段全 done，所以一律 nil。
  return STAGE_NAMES.map((name, i) => ({
    name,
    state: "done" as const,
    count: values[i]!,
    detail: null,
  }));
}

export interface ToBriefInput {
  id: string;
  news: NewsRefJson;
  sources: readonly Source[];
  facts: readonly Fact[];
  core: CoreResult;
  counts: StageCounts;
  budget: TokenBudgetJson;
}

export function toBriefJson(input: ToBriefInput): BriefJson {
  const { core } = input;
  if (!core.bind.ok) {
    // 绑定没过就没有 evidence 也没有 sentences——`BindResult` 的类型就是为了
    // 让"忘了检查 ok 就去用"不可能发生。这里如实炸掉，不发半成品。
    throw new Error(
      `${input.id} 的挂信源没通过：${core.bind.problems.map((p) => p.kind).join("、")}`,
    );
  }

  const claimById = new Map(core.claims.map((c) => [c.id, c]));
  const claimTexts = core.claims.map((c) => ({ id: c.id, text: c.text }));

  const sentences: BriefSentenceJson[] = core.bind.sentences.map((s, i) => ({
    id: `s${i + 1}`,
    text: s.text,
    kind: s.kind,
    // bindEvidence 已经把非 fact 句的 claimIds 清成空数组；锚点跟着一起空。
    claimIds: [...s.claimIds],
    anchors: s.kind === "fact" ? anchorsFor(s.text, s.claimIds, claimTexts) : [],
  }));

  const used = new Set<ClaimId>();
  for (const s of sentences) for (const id of s.claimIds) used.add(id);

  const claims: Record<string, ClaimEvidenceJson> = {};
  for (const id of [...used].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))) {
    const claim = claimById.get(id);
    if (claim === undefined) throw new Error(`稿子引用了不存在的 claim ${id}`);
    claims[id] = evidenceOf(claim, input.facts, input.sources);
  }

  return {
    id: input.id,
    news: input.news,
    status: "ready",
    estimatedSeconds: Math.round(core.seconds),
    // 这几篇没有任何用户的实测语速，用的是语种默认值。写 true 就是
    // `reading-rate.ts` 里点名不许说的那句「按你的语速」。
    pacedToUser: false,
    sentences,
    claims,
    // 重查没有真的跑过。给一条编的"重查之后"证据，等于凭空造几家媒体。
    // 解出来是 nil 时 `BriefRecheck` 会如实答「没找到新的」。
    recheckResults: null,
    stages: stagesOf(input.counts, core, sentences.length),
    budget: input.budget,
    insufficientReason: null,
  };
}
