import { classifyClaims } from "./dedupe/classify.js";
import { mergeFacts } from "./dedupe/merge.js";
import { estimateBrief, type BriefEstimate } from "./domain/estimate.js";
import { breathMarks, estimateSeconds, type BreathMark } from "./domain/prosody.js";
import type { ClaimId, DraftSentence, Fact, Source, VerifiedClaim } from "./domain/types.js";
import { bindEvidence, type BindResult } from "./draft/bind.js";
import { selectClaims, type Selection } from "./draft/select.js";

export interface CoreInput {
  durationSec: number;
  register: number;
  /** 该用户的实测语速；没有就传语种默认值。见 spec §9.2 ①。 */
  charsPerSecond: number;
  sources: Source[];
  facts: Fact[];
  /** ⑦ 成稿的输出。本计划不产生它，由 fixture 提供。 */
  draft: DraftSentence[];
  mediaGroups?: Record<string, string>;
  /**
   * ⑤ 语义那一半的判定结果：数字上看不出来、只有模型判得了的矛盾对。
   * 内核自己算不出它，也不去算——它只把这些对并进 `classifyClaims` 的冲突图。
   * 不传等同于只有数字冲突那一层。
   */
  externalConflicts?: readonly (readonly [ClaimId, ClaimId])[];
}

export interface CoreResult {
  estimate: BriefEstimate;
  claims: VerifiedClaim[];
  selection: Selection;
  bind: BindResult;
  seconds: number;
  breaths: BreathMark[];
}

/**
 * ④⑤⑥⑧⑨ 串起来——**全程没有一次模型调用，也没有一次网络请求**。
 * 这正是 spec §11 那句「管线最关键的逻辑全部可以离线测试」的兑现。
 */
export function buildBrief(input: CoreInput): CoreResult {
  const estimate = estimateBrief(input.durationSec, input.register);

  const merged = mergeFacts(input.facts);
  const claims = classifyClaims(
    merged,
    input.facts,
    input.sources,
    input.mediaGroups,
    input.externalConflicts,
  );
  const selection = selectClaims(claims, estimate.factSlots);

  // 即便 insufficient 也照样跑绑定与时长：问题要浮出来，不能被一个 verdict 盖掉。
  //
  // 这里喂给 bind 的是**全部通过验证的** claim，不是 selection.picked——两个阶段
  // 管的事不同：selection 决定「在这个长度里谁配进稿」，bind 决定「这条引用是不是
  // 真的」。若改用 picked，insufficient 时 picked 是空的，于是每一句事实句都会报
  // unknown-claim，把「模型编了一句」这个唯一该浮出来的信号淹掉。
  const verifiedIds = claims.filter((c) => c.confidence !== "conflicted").map((c) => c.id);
  const bind = bindEvidence(input.draft, verifiedIds);

  const texts = input.draft.map((s) => s.text);
  return {
    estimate,
    claims,
    selection,
    bind,
    seconds: texts.reduce((total, t) => total + estimateSeconds(t, input.charsPerSecond), 0),
    breaths: breathMarks(texts),
  };
}
