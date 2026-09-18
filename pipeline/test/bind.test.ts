import { expect, test } from "vitest";
import type { DraftSentence } from "../src/domain/types.js";
import { bindEvidence, sentenceFingerprint } from "../src/draft/bind.js";

const VERIFIED = ["c0", "c1"];

test("a fact sentence gets its claims bound and a fingerprint", () => {
  const draft: DraftSentence[] = [
    { text: "此次降准释放长期资金约 1 万亿元。", kind: "fact", claimIds: ["c0"] },
  ];
  const out = bindEvidence(draft, VERIFIED);
  expect(out.ok).toBe(true);
  expect(out.problems).toEqual([]);
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
  const out = bindEvidence(draft, VERIFIED);
  expect(out.ok).toBe(false);
  expect(out.problems).toEqual([{ sentenceIndex: 0, kind: "fact-without-claim" }]);
});

test("a claim that never passed verification is rejected", () => {
  const draft: DraftSentence[] = [
    { text: "此次降准释放长期资金约 1 万亿元。", kind: "fact", claimIds: ["c9"] },
  ];
  const out = bindEvidence(draft, VERIFIED);
  expect(out.ok).toBe(false);
  expect(out.problems).toEqual([{ sentenceIndex: 0, kind: "unknown-claim", claimId: "c9" }]);
});

test("an opinion sentence carrying claims has them stripped, not rejected", () => {
  const draft: DraftSentence[] = [
    { text: "我的判断是这一轮宽松还没到头。", kind: "opinion", claimIds: ["c0"] },
  ];
  const out = bindEvidence(draft, VERIFIED);
  expect(out.ok).toBe(true);
  expect(out.sentences[0]!.claimIds).toEqual([]);
  expect(out.evidence).toEqual([]);
});

test("a transition sentence needs no claims", () => {
  const draft: DraftSentence[] = [
    { text: "央行今天突然出手了。", kind: "transition", claimIds: [] },
  ];
  expect(bindEvidence(draft, VERIFIED).ok).toBe(true);
});

test("every problem in a draft is reported, not just the first", () => {
  const draft: DraftSentence[] = [
    { text: "一。", kind: "fact", claimIds: [] },
    { text: "二。", kind: "fact", claimIds: ["c9"] },
  ];
  const out = bindEvidence(draft, VERIFIED);
  expect(out.problems).toHaveLength(2);
});

test("the fingerprint changes when the wording changes", () => {
  const before = sentenceFingerprint("涉及金额约 23 亿美元。");
  const after = sentenceFingerprint("涉及金额约 31 亿美元。");
  expect(before).not.toBe(after);
});

test("the fingerprint ignores punctuation, so a comma edit keeps the sources", () => {
  expect(sentenceFingerprint("降准，三月生效。")).toBe(sentenceFingerprint("降准三月生效"));
});
