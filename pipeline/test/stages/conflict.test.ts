import { describe, expect, it } from "vitest";
import { buildConflictPrompt, parseConflictReply, pairsToCheck } from "../../src/stages/conflict.js";
import type { MergedClaim } from "../../src/domain/types.js";

const claims: MergedClaim[] = [
  { id: "c0", text: "官方否认将要降准", factIds: ["f0"] },
  { id: "c1", text: "消息人士称降准已定", factIds: ["f1"] },
  { id: "c2", text: "股市今日收涨", factIds: ["f2"] },
];

describe("pairsToCheck", () => {
  it("两两组合，不含自己", () => {
    expect(pairsToCheck(claims)).toEqual([
      ["c0", "c1"],
      ["c0", "c2"],
      ["c1", "c2"],
    ]);
  });

  it("已经被数字冲突标过的对不重复问模型——省 token", () => {
    expect(pairsToCheck(claims, [["c0", "c1"]])).toEqual([
      ["c0", "c2"],
      ["c1", "c2"],
    ]);
  });

  it("方向无关：[c1,c0] 也算已标过", () => {
    expect(pairsToCheck(claims, [["c1", "c0"]])).toEqual([
      ["c0", "c2"],
      ["c1", "c2"],
    ]);
  });

  it("少于两条时没有要检查的对", () => {
    expect(pairsToCheck([claims[0]!])).toEqual([]);
  });
});

describe("parseConflictReply", () => {
  it("只收下 conflict 为 true 的对", () => {
    const out = parseConflictReply({
      pairs: [
        { a: "c0", b: "c1", conflict: true },
        { a: "c0", b: "c2", conflict: false },
      ],
    });
    expect(out).toEqual([["c0", "c1"]]);
  });

  it("模型返回未知 id 时丢掉那一项而不是崩", () => {
    const out = parseConflictReply(
      { pairs: [{ a: "c0", b: "nope", conflict: true }] },
      new Set(["c0", "c1"]),
    );
    expect(out).toEqual([]);
  });

  it("conflict 不是布尔时当成 false——含糊即不冲突，避免误杀好数据", () => {
    const out = parseConflictReply({
      pairs: [{ a: "c0", b: "c1", conflict: "maybe" as never }],
    });
    expect(out).toEqual([]);
  });

  it("pairs 缺失时返回空数组", () => {
    expect(parseConflictReply({} as never)).toEqual([]);
  });
});

describe("buildConflictPrompt", () => {
  it("把待判的对和文本都写进去", () => {
    const prompt = buildConflictPrompt(claims, [["c0", "c1"]]);
    expect(prompt).toContain("官方否认将要降准");
    expect(prompt).toContain("消息人士称降准已定");
  });
});
