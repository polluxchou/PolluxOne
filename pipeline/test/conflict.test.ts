import { expect, test } from "vitest";
import type { MergedClaim } from "../src/domain/types.js";
import { findNumericConflicts } from "../src/dedupe/conflict.js";

function claim(id: string, text: string): MergedClaim {
  return { id, text, factIds: [] };
}

test("same claim, different figure — the Reuters vs Bloomberg case", () => {
  const claims: MergedClaim[] = [
    claim("c0", "此次交易涉及金额约 23 亿美元"),
    claim("c1", "此次交易涉及金额约 31 亿美元"),
  ];
  expect(findNumericConflicts(claims)).toEqual([["c0", "c1"]]);
});

test("agreeing figures are not a conflict", () => {
  const claims = [
    claim("c0", "此次交易涉及金额约 23 亿美元"),
    claim("c1", "该笔交易涉及金额约 23 亿美元"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});

test("different claims that happen to carry different numbers are not a conflict", () => {
  const claims = [
    claim("c0", "此次降准释放长期资金约 1 万亿元"),
    claim("c1", "港股通标的下个月新增 12 只"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});

test("a claim that merely omits a date is not in conflict", () => {
  // 「降准 0.5 个百分点」只是没提日期，对共同提到的数字完全一致。
  // 签名长度不等 ≠ 说法不同——子集关系才是判据。实测 jaccard 0.583，
  // 不挡住的话这一对会被误报成冲突，一条好 claim 就被扔了。
  const claims = [
    claim("c0", "3 月 15 日降准 0.5 个百分点"),
    claim("c1", "降准 0.5 个百分点"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});

test("a figure against an undisclosed figure is out of scope, not a conflict", () => {
  // 两句话确实矛盾，但一边根本没有数字可比。空集是任何集合的子集，
  // 所以这一类和语义冲突一样，留给下一个计划的模型阶段。
  const claims = [
    claim("c0", "此次交易涉及金额约 23 亿美元"),
    claim("c1", "此次交易涉及金额未披露"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});

test("CONFLICT_SUBJECT_JACCARD is inclusive at exactly 0.45", () => {
  // "abcdefghij1" → 10 个 2-gram；"abcdefghijklmnopqrs2" → 19 个；
  // 共享 9，并集 20 —— jaccard 恰好 0.45。签名 ["1"] 与 ["2"] 互不为子集。
  // `>=` 报冲突、`>` 不报，这是唯一钉住那个运算符的测试。
  expect(findNumericConflicts([
    claim("c0", "abcdefghij 1"),
    claim("c1", "abcdefghijklmnopqrs 2"),
  ])).toEqual([["c0", "c1"]]);
});

test("a claim with no numbers cannot conflict numerically", () => {
  const claims = [
    claim("c0", "多位分析师认为这一决定符合市场预期"),
    claim("c1", "多位分析师认为这一决定不符合市场预期"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});
