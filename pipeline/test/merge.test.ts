import { expect, test } from "vitest";
import type { Fact } from "../src/domain/types.js";
import { mergeFacts, numericSignature } from "../src/dedupe/merge.js";

function fact(id: string, sourceId: string, text: string): Fact {
  return { id, sourceId, text, quote: text };
}

test("the signature carries each number together with its unit, sorted", () => {
  expect(numericSignature("降准 0.5 个百分点，释放 1 万亿元，3 月 15 日生效"))
    .toEqual(["0.5个百", "15日生", "1万亿", "3月"]);
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

test("same figure in a different currency does NOT merge", () => {
  // 只取裸数字时两边签名都是 ["23"]，文本相似度 0.64 远超门槛，会被并成一条，
  // 其中一种币种在到达 ⑤ 的冲突检测之前就没了。单位进签名就是为了挡住这个。
  const facts = [
    fact("f0", "s0", "涉及金额约 23 亿美元"),
    fact("f1", "s1", "涉及金额约 23 亿欧元"),
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

test("MERGE_JACCARD is inclusive at exactly 0.45", () => {
  // 两串末尾带同一个「1」，所以数字签名相同，走的是 0.45 这条门槛。
  // "abcdefghij1" → 10 个 2-gram；"abcdefghijklmnopqrs1" → 19 个；共享 9，
  // 并集 20 —— jaccard 恰好 0.45。`>=` 归并、`>` 不归并，也抓「两个常量互换」。
  expect(mergeFacts([
    fact("f0", "s0", "abcdefghij 1"),
    fact("f1", "s1", "abcdefghijklmnopqrs 1"),
  ])).toHaveLength(1);

  // "abc1" / "abcd1" 的 jaccard 是 0.4，低于门槛，不该归并——挡住阈值被调低
  expect(mergeFacts([
    fact("f2", "s0", "abc 1"),
    fact("f3", "s1", "abcd 1"),
  ])).toHaveLength(2);
});

test("MERGE_JACCARD_NO_NUMBERS is inclusive at exactly 0.7", () => {
  // 两串都没有数字，走的是 0.7 这条门槛。
  // "abcdefgh" → 7 个 2-gram；"abcdefghijk" → 10 个；共享 7，并集 10 —— 恰好 0.7。
  expect(mergeFacts([
    fact("f0", "s0", "abcdefgh"),
    fact("f1", "s1", "abcdefghijk"),
  ])).toHaveLength(1);

  // "abc" / "abcd" 的 jaccard 是 0.667：低于 0.7 不该归并，
  // 但它高于 0.45 —— 所以两个常量被互换的话这一条会失败。
  expect(mergeFacts([
    fact("f2", "s0", "abc"),
    fact("f3", "s1", "abcd"),
  ])).toHaveLength(2);
});

test("a merged claim keeps the longest wording", () => {
  const facts = [
    fact("f0", "s0", "降准释放资金约 1 万亿元"),
    fact("f1", "s1", "此次降准将释放长期资金约 1 万亿元"),
  ];
  expect(mergeFacts(facts)[0]!.text).toBe("此次降准将释放长期资金约 1 万亿元");
});
