import { describe, expect, it } from "vitest";
import { buildDraftPrompt, registerLabel } from "../../src/stages/draft.js";
import type { VerifiedClaim } from "../../src/domain/types.js";

const claims: VerifiedClaim[] = [
  {
    id: "c0",
    text: "存款准备金率下调 0.5 个百分点",
    factIds: ["f0"],
    independence: 3,
    confidence: "strong",
    conflictsWith: [],
  },
  {
    id: "c1",
    text: "释放长期资金约 1 万亿元",
    factIds: ["f1"],
    independence: 3,
    confidence: "strong",
    conflictsWith: [],
  },
];

describe("registerLabel", () => {
  it("0 是最通俗", () => {
    expect(registerLabel(0)).toMatch(/通俗|口语/);
  });

  it("1 是最专业", () => {
    expect(registerLabel(1)).toMatch(/专业/);
  });

  it("中间值落在中间档", () => {
    expect(registerLabel(0.5)).toBeTruthy();
    expect(registerLabel(0.5)).not.toBe(registerLabel(0));
    expect(registerLabel(0.5)).not.toBe(registerLabel(1));
  });

  it("越界的值被夹住而不是崩", () => {
    expect(registerLabel(-1)).toBe(registerLabel(0));
    expect(registerLabel(9)).toBe(registerLabel(1));
  });
});

describe("buildDraftPrompt", () => {
  it("把可用的 claim 和它的 id 都写进去", () => {
    const p = buildDraftPrompt(claims, 60, 0);
    expect(p).toContain("c0");
    expect(p).toContain("存款准备金率下调 0.5 个百分点");
  });

  it("写明时长", () => {
    expect(buildDraftPrompt(claims, 180, 0.7)).toContain("180");
  });

  it("要求 fact 句必须挂 claimIds，opinion 句不许挂——§6.2", () => {
    const p = buildDraftPrompt(claims, 60, 0);
    expect(p).toMatch(/fact/);
    expect(p).toMatch(/opinion/);
    expect(p).toContain("claimIds");
  });

  it("conflicted 的 claim 不出现在 prompt 里——它根本不该进稿", () => {
    const withConflict: VerifiedClaim[] = [
      ...claims,
      {
        id: "c9",
        text: "涉及资金 23 亿美元",
        factIds: ["f9"],
        independence: 1,
        confidence: "conflicted",
        conflictsWith: ["c8"],
      },
    ];
    const p = buildDraftPrompt(withConflict, 60, 0);
    expect(p).not.toContain("c9");
    expect(p).not.toContain("23 亿美元");
  });

  it("没有可用 claim 时抛——空稿子不如不出稿", () => {
    expect(() => buildDraftPrompt([], 60, 0)).toThrow(/没有/);
  });
});
