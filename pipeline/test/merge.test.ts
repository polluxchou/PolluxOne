import { expect, test } from "vitest";
import type { Fact } from "../src/domain/types.js";
import { mergeFacts, numericSignature } from "../src/dedupe/merge.js";

function fact(id: string, sourceId: string, text: string): Fact {
  return { id, sourceId, text, quote: text };
}

test("numeric signature pulls out every number, sorted", () => {
  expect(numericSignature("降准 0.5 个百分点，释放 1 万亿元，3 月 15 日生效")).toEqual(["0.5", "1", "15", "3"]);
});

test("numeric signature is empty when there are no numbers", () => {
  expect(numericSignature("央行今天突然出手了")).toEqual([]);
});

test("the same fact worded differently by two outlets merges", () => {
  const facts = [
    fact("f0", "s0", "此次降准释放长期资金约 1 万亿元"),
    fact("f1", "s1", "此次降准将释放长期资金约 1 万亿元"),
  ];
  const claims = mergeFacts(facts);
  expect(claims).toHaveLength(1);
  expect(claims[0]!.factIds).toEqual(["f0", "f1"]);
});

test("same wording but a different number does NOT merge", () => {
  const facts = [
    fact("f0", "s0", "涉及金额约 23 亿美元"),
    fact("f1", "s1", "涉及金额约 31 亿美元"),
  ];
  expect(mergeFacts(facts)).toHaveLength(2);
});

test("unrelated facts stay apart", () => {
  const facts = [
    fact("f0", "s0", "此次降准释放长期资金约 1 万亿元"),
    fact("f1", "s1", "港股通标的下个月调整"),
  ];
  expect(mergeFacts(facts)).toHaveLength(2);
});

test("number-free facts need a higher bar to merge", () => {
  const near = [
    fact("f0", "s0", "多位分析师认为这一决定符合市场预期"),
    fact("f1", "s1", "多位分析师认为这一决定基本符合市场预期"),
  ];
  expect(mergeFacts(near)).toHaveLength(1);

  const looser = [
    fact("f2", "s0", "多位分析师认为这一决定符合市场预期"),
    fact("f3", "s1", "分析师对后续政策走向看法不一"),
  ];
  expect(mergeFacts(looser)).toHaveLength(2);
});

test("a merged claim keeps the longest wording", () => {
  const facts = [
    fact("f0", "s0", "降准释放资金约 1 万亿元"),
    fact("f1", "s1", "此次降准将释放长期资金约 1 万亿元"),
  ];
  expect(mergeFacts(facts)[0]!.text).toBe("此次降准将释放长期资金约 1 万亿元");
});
