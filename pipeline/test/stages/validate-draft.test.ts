import { describe, expect, it } from "vitest";
import { validateDraft } from "../../src/stages/validate-draft.js";

const allowed = new Set(["c0", "c1"]);

describe("validateDraft", () => {
  it("合法的稿子通过", () => {
    const r = validateDraft(
      {
        sentences: [
          { text: "央行出手了。", kind: "transition", claimIds: [] },
          { text: "下调 0.5 个百分点。", kind: "fact", claimIds: ["c0"] },
          { text: "我认为还没到头。", kind: "opinion", claimIds: [] },
        ],
      },
      allowed,
    );
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.sentences).toHaveLength(3);
  });

  it("fact 句 claimIds 为空要拒——§6.2 的核心", () => {
    const r = validateDraft(
      { sentences: [{ text: "下调了。", kind: "fact", claimIds: [] }] },
      allowed,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems[0]!.kind).toBe("fact-without-claims");
  });

  it("opinion 句带 claimIds 要拒——观点不该冒充有信源", () => {
    const r = validateDraft(
      { sentences: [{ text: "我觉得。", kind: "opinion", claimIds: ["c0"] }] },
      allowed,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems[0]!.kind).toBe("opinion-with-claims");
  });

  it("引用了不存在的 claim 要拒——这是模型编造的信号", () => {
    const r = validateDraft(
      { sentences: [{ text: "x", kind: "fact", claimIds: ["c9"] }] },
      allowed,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems[0]!.kind).toBe("unknown-claim");
  });

  it("未知的 kind 要拒", () => {
    const r = validateDraft(
      { sentences: [{ text: "x", kind: "narration" as never, claimIds: [] }] },
      allowed,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems[0]!.kind).toBe("bad-kind");
  });

  it("空文本要拒", () => {
    const r = validateDraft(
      { sentences: [{ text: "   ", kind: "transition", claimIds: [] }] },
      allowed,
    );
    expect(r.ok).toBe(false);
  });

  it("一句都没有要拒", () => {
    const r = validateDraft({ sentences: [] }, allowed);
    expect(r.ok).toBe(false);
  });

  it("sentences 不是数组要拒而不是崩", () => {
    const r = validateDraft({ sentences: "nope" } as never, allowed);
    expect(r.ok).toBe(false);
  });

  it("全部问题一次报齐，重跑时能把话说全", () => {
    const r = validateDraft(
      {
        sentences: [
          { text: "a", kind: "fact", claimIds: [] },
          { text: "b", kind: "opinion", claimIds: ["c0"] },
        ],
      },
      allowed,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems).toHaveLength(2);
  });
});
