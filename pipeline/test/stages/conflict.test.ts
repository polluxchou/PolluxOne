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

  // 下面几条只验 prompt 的正文。判据改对了没有，只有真调模型才看得出来，
  // 那件事离线测不了——所以这里**不**编一个模型回复来假装测到了它。
  // 能钉住的是：判据这句话和那两组例子还在不在 prompt 里。

  it("判据是「能不能一起播」，不是「逻辑上能不能同时为真」", () => {
    const prompt = buildConflictPrompt(claims, [["c0", "c1"]]);
    expect(prompt).toContain("能不能一起播");
    expect(prompt).toContain("不知道该信哪一条");
    // 旧判据把「官方否认 vs 消息人士证实」判成不冲突——它俩逻辑上确实
    // 可以同时为真。这句话不能再出现，否则等于把那个洞又写回去。
    expect(prompt).not.toContain("只有当一条为真会使另一条为假时");
  });

  it("「官方否认 vs 消息人士证实」作为正例写进 prompt——实跑漏掉的就是这一对", () => {
    // 例子和待判的对无关，只给一对都不相干的 claim 也必须在。
    const prompt = buildConflictPrompt(claims, [["c0", "c2"]]);
    expect(prompt).toContain("conflict: true");
    const positives = prompt.slice(prompt.indexOf("算冲突（conflict: true）"));
    expect(positives).toContain("「官方否认将要降准」对「消息人士称降准已定」");
    // 判据本身也要说清「各自都属实」不是免死金牌，否则那一对还是会被放过。
    expect(prompt).toContain("就算两句各自都属实，也算冲突");
  });

  it("反例挡住误杀：角度不同、详略不同、互为补充都不算冲突", () => {
    const prompt = buildConflictPrompt(claims, [["c0", "c1"]]);
    const negatives = prompt.slice(prompt.indexOf("不算冲突（conflict: false）"));
    expect(negatives).toContain("互为补充");
    expect(negatives).toContain("详略不同");
    // 误杀会让 strong 掉到 MINIMUM_STRONG_CLAIMS 以下、把好稿翻成「不建议播」，
    // 而漏掉一对用户看不见。所以拿不准的那一档必须明写成 false。
    expect(negatives).toContain("拿不准就填 false");
  });

  it("正例在反例之前，两组都不为空", () => {
    const prompt = buildConflictPrompt(claims, [["c0", "c1"]]);
    const positive = prompt.indexOf("算冲突（conflict: true）");
    const negative = prompt.indexOf("不算冲突（conflict: false）");
    expect(positive).toBeGreaterThan(-1);
    expect(negative).toBeGreaterThan(positive);
  });
});
