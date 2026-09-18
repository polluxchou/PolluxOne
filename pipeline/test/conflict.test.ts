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

test("a claim with no numbers cannot conflict numerically", () => {
  const claims = [
    claim("c0", "多位分析师认为这一决定符合市场预期"),
    claim("c1", "多位分析师认为这一决定不符合市场预期"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});
