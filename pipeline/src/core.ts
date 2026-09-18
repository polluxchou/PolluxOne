import { classifyClaims } from "./dedupe/classify.js";
import { mergeFacts } from "./dedupe/merge.js";
import { estimateBrief, type BriefEstimate } from "./domain/estimate.js";
import { breathMarks, estimateSeconds, type BreathMark } from "./domain/prosody.js";
import type { DraftSentence, Fact, Source, VerifiedClaim } from "./domain/types.js";
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
}

export interface CoreResult {
  estimate: BriefEstimate;
  claims: VerifiedClaim[];
  selection: Selection;
  verdict: Selection["verdict"];
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
  const claims = classifyClaims(merged, input.facts, input.sources, input.mediaGroups ?? {});
  const selection = selectClaims(claims, estimate.factSlots);

  // 即便 insufficient 也照样跑绑定与时长：问题要浮出来，不能被一个 verdict 盖掉
  const verifiedIds = claims.filter((c) => c.confidence !== "conflicted").map((c) => c.id);
  const bind = bindEvidence(input.draft, verifiedIds);

  const texts = input.draft.map((s) => s.text);
  return {
    estimate,
    claims,
    selection,
    verdict: selection.verdict,
    bind,
    seconds: texts.reduce((total, t) => total + estimateSeconds(t, input.charsPerSecond), 0),
    breaths: breathMarks(texts),
  };
}
