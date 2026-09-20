import { expect, test } from "vitest";
import type { DraftSentence } from "../src/domain/types.js";
import { bindEvidence, sentenceFingerprint, type BindResult } from "../src/draft/bind.js";

const VERIFIED = ["c0", "c1"];

/** 窄化到成功分支，失败时给出看得懂的报错。 */
function ok(result: BindResult) {
  if (!result.ok) throw new Error(`expected a clean bind, got ${JSON.stringify(result.problems)}`);
  return result;
}

test("a fact sentence gets its claims bound and a fingerprint", () => {
  const draft: DraftSentence[] = [
    { text: "此次降准释放长期资金约 1 万亿元。", kind: "fact", claimIds: ["c0"] },
  ];
  const out = ok(bindEvidence(draft, VERIFIED));
  expect(out.evidence).toEqual([
    {
      sentenceIndex: 0,
      claimIds: ["c0"],
      sentenceFingerprint: sentenceFingerprint("此次降准释放长期资金约 1 万亿元。"),
    },
  ]);
});

test("a fact sentence with no claims is rejected — the model made it up", () => {
  const draft: DraftSentence[] = [
    { text: "业内普遍认为这是重大利好。", kind: "fact", claimIds: [] },
  ];
  // 整体比对：失败时连 evidence 和 sentences 都不该有
  expect(bindEvidence(draft, VERIFIED)).toEqual({
    ok: false,
    problems: [{ kind: "fact-without-claim", sentenceIndex: 0 }],
  });
});

test("a claim that never passed verification is rejected", () => {
  const draft: DraftSentence[] = [
    { text: "此次降准释放长期资金约 1 万亿元。", kind: "fact", claimIds: ["c9"] },
  ];
  expect(bindEvidence(draft, VERIFIED)).toEqual({
    ok: false,
    problems: [{ kind: "unknown-claim", sentenceIndex: 0, claimId: "c9" }],
  });
});

test("an opinion sentence carrying claims has them stripped, not rejected", () => {
  const draft: DraftSentence[] = [
    { text: "我的判断是这一轮宽松还没到头。", kind: "opinion", claimIds: ["c0"] },
  ];
  const out = ok(bindEvidence(draft, VERIFIED));
  expect(out.sentences[0]!.claimIds).toEqual([]);
  expect(out.evidence).toEqual([]);
});

test("a transition sentence has its claims stripped too", () => {
  // 原来这条的 claimIds 本来就是空的，等于没验证「剥离」这件事——
  // 把剥离的条件从 `kind !== "fact"` 缩成 `kind === "opinion"` 也不会红。
  const draft: DraftSentence[] = [
    { text: "央行今天突然出手了。", kind: "transition", claimIds: ["c0"] },
  ];
  const out = ok(bindEvidence(draft, VERIFIED));
  expect(out.sentences[0]!.claimIds).toEqual([]);
  expect(out.evidence).toEqual([]);
});

test("every problem in a draft is reported, not just the first", () => {
  const draft: DraftSentence[] = [
    { text: "一。", kind: "fact", claimIds: [] },
    { text: "二。", kind: "fact", claimIds: ["c9"] },
  ];
  const out = bindEvidence(draft, VERIFIED);
  expect(out.ok).toBe(false);
  if (!out.ok) expect(out.problems).toHaveLength(2);
});

test("the fingerprint changes when the wording changes", () => {
  const before = sentenceFingerprint("涉及金额约 23 亿美元。");
  const after = sentenceFingerprint("涉及金额约 31 亿美元。");
  expect(before).not.toBe(after);
});

test("the fingerprint ignores punctuation, so a comma edit keeps the sources", () => {
  expect(sentenceFingerprint("降准，三月生效。")).toBe(sentenceFingerprint("降准三月生效"));
});

test("the fingerprint is sixteen hex characters", () => {
  // 没这一条，把 slice(0, 16) 改成 slice(0, 8) 不会有任何测试变红。
  expect(sentenceFingerprint("降准三月生效")).toMatch(/^[0-9a-f]{16}$/);
});
