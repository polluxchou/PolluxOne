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

// ── 判据从「④ 的签名不相等」换成「同一个量纲上给出了不同的值」之后 ──────────
//
// 下面每一对在换判据之前都实测被判 CONFLICT，而它们没有任何一个数字不同。
// ④ 的签名把数字后面的两个字一起吃进 token（`15日生` / `15日起`），于是
// **任意行文差异**都能造出互不为子多重集的签名。每一条误杀都可能让 strong
// 掉到 `MINIMUM_STRONG_CLAIMS` 以下，把整篇翻成「不建议播」。

test("wording differences after the number are not a numeric conflict", () => {
  // 旧签名 `15日生` vs `15日起`，jaccard 0.81 —— 单位槽里装的根本不是单位。
  expect(findNumericConflicts([
    claim("c0", "新政自 3 月 15 日生效"),
    claim("c1", "新政自 3 月 15 日起生效"),
  ])).toEqual([]);

  // 旧签名 `2元起` vs `2元整`，jaccard 0.67。
  expect(findNumericConflicts([
    claim("c0", "网约车起步价为 2 元起"),
    claim("c1", "网约车起步价为 2 元整"),
  ])).toEqual([]);
});

test("the same value written differently is not a numeric conflict", () => {
  // 千分位：旧签名 `2800万欧` vs `2`+`800万欧`，jaccard 1.00。
  expect(findNumericConflicts([
    claim("c0", "转会身价约 2800 万欧元"),
    claim("c1", "转会身价约 2,800 万欧元"),
  ])).toEqual([]);

  // 小数尾零：旧签名 `1.5元` vs `1.50元`，jaccard 0.70。
  expect(findNumericConflicts([
    claim("c0", "网约车起步价为 1.5 元"),
    claim("c1", "网约车起步价为 1.50 元"),
  ])).toEqual([]);

  // 数量级：旧签名 `1万亿` vs `10000亿元`，jaccard 0.71。
  expect(findNumericConflicts([
    claim("c0", "此次降准释放长期资金约 1 万亿元"),
    claim("c1", "此次降准释放长期资金约 10000 亿元"),
  ])).toEqual([]);
});

test("日 and 号 are the same day, not two figures", () => {
  // 旧签名 `15日起` vs `15号起`，jaccard 0.67。
  expect(findNumericConflicts([
    claim("c0", "新政自 3 月 15 日起生效"),
    claim("c1", "新政自 3 月 15 号起生效"),
  ])).toEqual([]);
});

// ── 反向：每放宽一条，都得钉住「真分歧仍然溜不过去」 ─────────────────────────
//
// 一个永远返回空数组的 `findNumericConflicts` 也能让上面全过。下面这些才是
// 真正约束判据的一侧：漏检没有任何下游能救，用户也看不见。

test("loosening the value normalisation does not let a real disagreement through", () => {
  const conflicting: [string, string][] = [
    ["网约车起步价为 2 元", "网约车起步价为 3 元"],
    ["网约车起步价为 1.5 元", "网约车起步价为 1.55 元"],
    ["转会身价约 2,800 万欧元", "转会身价约 2,900 万欧元"],
    ["此次降准释放长期资金约 1 万亿元", "此次降准释放长期资金约 1000 亿元"],
    ["新政自 3 月 15 日起生效", "新政自 3 月 16 号起生效"],
    // 量纲不同也是分歧：同一个数，两种币种。
    ["此次交易涉及金额约 23 亿美元", "此次交易涉及金额约 23 亿欧元"],
  ];
  for (const [a, b] of conflicting) {
    expect(findNumericConflicts([claim("c0", a), claim("c1", b)])).toEqual([["c0", "c1"]]);
  }
});

test("a full-width figure no longer slips past both the merge and the conflict gate", () => {
  // 换 NFKC 之前：签名 ["23亿美"] vs []，空集 ⊆ 任意集 —— 既不归并也不报
  // 冲突，两个打架的数字一起播出去，而且没有任何提示。这是这条流水线唯一
  // 不能犯的错，中文媒体用全角数字并不罕见。
  expect(findNumericConflicts([
    claim("c0", "此次交易涉及金额约 ２３ 亿美元"),
    claim("c1", "此次交易涉及金额约 31 亿美元"),
  ])).toEqual([["c0", "c1"]]);

  // 反向：全角和半角写的同一个数字仍然不算冲突。
  expect(findNumericConflicts([
    claim("c0", "此次交易涉及金额约 ２３ 亿美元"),
    claim("c1", "此次交易涉及金额约 23 亿美元"),
  ])).toEqual([]);
});

test("multiplicity counts — a repeated figure is not covered by a single match", () => {
  // 子**多重集**，不是子集。按集合算的话左边 {25个} ⊆ 右边 {25个,50个}，
  // 这一对就不报冲突——两家对第二轮的说法差一倍，却一起播出去。
  expect(findNumericConflicts([
    claim("c0", "首轮加息 25 个基点，二轮加息 25 个基点"),
    claim("c1", "首轮加息 25 个基点，二轮加息 50 个基点"),
  ])).toEqual([["c0", "c1"]]);

  // 反向：真的只是少说了一轮，仍然不算冲突。
  expect(findNumericConflicts([
    claim("c0", "首轮加息 25 个基点，二轮加息 50 个基点"),
    claim("c1", "首轮加息 25 个基点"),
  ])).toEqual([]);
});
