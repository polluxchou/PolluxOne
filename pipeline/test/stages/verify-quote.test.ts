import { describe, expect, it } from "vitest";
import { normalizeForQuote, verifyQuotes } from "../../src/stages/verify-quote.js";
import type { Fact, Source } from "../../src/domain/types.js";

const source: Source = {
  id: "s0",
  url: "https://a.com/1",
  publisher: "a.com",
  publishedAt: "2026-09-18T00:00:00Z",
  body: "央行今日宣布下调存款准备金率 0.5 个百分点，自 3 月 15 日起执行。",
  creditedTo: null,
};

const fact = (id: string, quote: string): Fact => ({
  id,
  sourceId: "s0",
  text: "t",
  quote,
});

describe("normalizeForQuote", () => {
  it("折叠空白", () => {
    expect(normalizeForQuote("a  b\n c")).toBe("abc");
  });

  it("NFKC 折叠全角数字", () => {
    expect(normalizeForQuote("０．５")).toBe("0.5");
  });
});

describe("verifyQuotes", () => {
  it("逐字命中的留下", () => {
    const { kept, rejected } = verifyQuotes([fact("f0", "下调存款准备金率")], [source]);
    expect(kept.map((f) => f.id)).toEqual(["f0"]);
    expect(rejected).toEqual([]);
  });

  it("空白差异不算改动", () => {
    const { kept } = verifyQuotes([fact("f0", "下调存款准备金率 0.5个百分点")], [source]);
    expect(kept).toHaveLength(1);
  });

  it("全角半角差异不算改动", () => {
    const { kept } = verifyQuotes([fact("f0", "０.５个百分点")], [source]);
    expect(kept).toHaveLength(1);
  });

  it("转述的被拒——这是整个校验存在的理由", () => {
    const { kept, rejected } = verifyQuotes(
      [fact("f0", "央行降低了存款准备金率")], // 原文是「下调」不是「降低」
      [source],
    );
    expect(kept).toEqual([]);
    expect(rejected[0]!.reason).toBe("not-verbatim");
  });

  it("改了数字的被拒——最危险的一种", () => {
    const { rejected } = verifyQuotes([fact("f0", "下调存款准备金率 5 个百分点")], [source]);
    expect(rejected).toHaveLength(1);
  });

  it("引用了不存在的 source 时被拒，而不是崩", () => {
    const orphan: Fact = { id: "f9", sourceId: "nope", text: "t", quote: "x" };
    const { kept, rejected } = verifyQuotes([orphan], [source]);
    expect(kept).toEqual([]);
    expect(rejected[0]!.reason).toBe("unknown-source");
  });

  it("只在自己的 source 里找——在别家正文里命中不算数", () => {
    const other: Source = { ...source, id: "s1", body: "完全不同的正文。" };
    const f = { ...fact("f0", "下调存款准备金率"), sourceId: "s1" };
    const { kept, rejected } = verifyQuotes([f], [source, other]);
    expect(kept).toEqual([]);
    expect(rejected[0]!.reason).toBe("not-verbatim");
  });

  it("空引文被拒——空串是任何字符串的子串", () => {
    const { rejected } = verifyQuotes([fact("f0", "   ")], [source]);
    expect(rejected[0]!.reason).toBe("empty");
  });
});
