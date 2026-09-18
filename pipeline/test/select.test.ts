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
  const claims = [
    claim("c0", "strong", 3), claim("c1", "strong", 3), claim("c2", "strong", 3),
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
  expect(out.reason).toBe("only 2 strong claims, need 3");
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
