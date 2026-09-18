import { expect, test } from "vitest";
import type { Confidence, VerifiedClaim } from "../src/domain/types.js";
import { selectClaims } from "../src/draft/select.js";

function claim(id: string, confidence: Confidence, independence: number): VerifiedClaim {
  return { id, text: id, factIds: [], independence, confidence, conflictsWith: [] };
}

test("strong claims are picked first, most-corroborated first", () => {
  const claims = [
    claim("c0", "strong", 3),
    claim("c1", "strong", 5),
    claim("c2", "strong", 4),
  ];
  const out = selectClaims(claims, 3);
  expect(out.verdict).toBe("ok");
  expect(out.picked).toEqual(["c1", "c2", "c0"]);
});

test("weak claims fill the remaining slots once three strong are in", () => {
  // 三条 strong 故意打乱着传进来。排序是稳定的，所以去掉 id 那半个 tie-break
  // 会原样吐回 c2,c0,c1——这一条就是用来钉住它的。
  const claims = [
    claim("c2", "strong", 3), claim("c0", "strong", 3), claim("c1", "strong", 3),
    claim("c3", "weak", 2), claim("c4", "weak", 1),
  ];
  const out = selectClaims(claims, 5);
  expect(out.picked).toEqual(["c0", "c1", "c2", "c3", "c4"]);
});

test("fewer than three strong claims means no script at all", () => {
  const claims = [
    claim("c0", "strong", 3), claim("c1", "strong", 3),
    claim("c2", "weak", 1), claim("c3", "weak", 1), claim("c4", "weak", 1),
  ];
  const out = selectClaims(claims, 5);
  expect(out.verdict).toBe("insufficient");
  expect(out.picked).toEqual([]);
  expect(out.strongFound).toBe(2);
  expect(out.reason).toBe("only 2 strong claims, need 3");
});

test("a refusal still reports what was in conflict", () => {
  // 「不建议播」那一屏既要说明为什么没出稿，也要把冲突摆出来。
  // 没有这一条的话，把 insufficient 分支里的 conflicted 硬写成 [] 六个测试全过。
  const claims = [
    claim("c0", "strong", 3),
    { ...claim("c1", "conflicted", 4), conflictsWith: ["c2"] },
    { ...claim("c2", "conflicted", 4), conflictsWith: ["c1"] },
  ];
  const out = selectClaims(claims, 5);
  expect(out.verdict).toBe("insufficient");
  expect(out.conflicted).toEqual(["c1", "c2"]);
});

test("a nonsensical slot count is a caller error, not an empty script", () => {
  // slice(0, -1) 返回的是「除最后一个之外的全部」，所以负数名额会**多**出稿，
  // 不是不出稿。名额来自 estimateBrief（保证 ≥ 3），走到这里就是调用方错了。
  const claims = [claim("c0", "strong", 3), claim("c1", "strong", 3), claim("c2", "strong", 3)];
  expect(() => selectClaims(claims, -1)).toThrow(/factSlots/);
  expect(() => selectClaims(claims, 2.5)).toThrow(/factSlots/);
});

test("a long duration does not lower the bar", () => {
  const claims = [claim("c0", "strong", 3), claim("c1", "strong", 3)];
  expect(selectClaims(claims, 14).verdict).toBe("insufficient");
});

test("conflicted claims never enter the script but are reported", () => {
  const claims = [
    claim("c0", "strong", 3), claim("c1", "strong", 3), claim("c2", "strong", 3),
    { ...claim("c3", "conflicted", 4), conflictsWith: ["c4"] },
    { ...claim("c4", "conflicted", 4), conflictsWith: ["c3"] },
  ];
  const out = selectClaims(claims, 5);
  expect(out.verdict).toBe("ok");
  expect(out.picked).toEqual(["c0", "c1", "c2"]);
  expect(out.conflicted).toEqual(["c3", "c4"]);
});

test("never picks more than the slots allow", () => {
  const claims = [
    claim("c0", "strong", 3), claim("c1", "strong", 3),
    claim("c2", "strong", 3), claim("c3", "strong", 3),
  ];
  expect(selectClaims(claims, 3).picked).toHaveLength(3);
});
