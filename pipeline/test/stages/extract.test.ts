import { describe, expect, it } from "vitest";
import { buildExtractPrompt, parseExtractReply } from "../../src/stages/extract.js";
import type { Source } from "../../src/domain/types.js";

const source: Source = {
  id: "s0",
  url: "https://a.com/1",
  publisher: "a.com",
  publishedAt: "2026-09-18T00:00:00Z",
  body: "央行今日宣布下调存款准备金率 0.5 个百分点，自 3 月 15 日起执行。",
  creditedTo: null,
};

describe("buildExtractPrompt", () => {
  it("把正文放进去", () => {
    expect(buildExtractPrompt(source)).toContain("存款准备金率");
  });

  it("要求逐字引文——这是后面一切的根", () => {
    expect(buildExtractPrompt(source)).toMatch(/逐字/);
  });

  it("给出 JSON 形状，因为 API 层不强制 schema", () => {
    expect(buildExtractPrompt(source)).toContain('"facts"');
    expect(buildExtractPrompt(source)).toContain('"quote"');
  });
});

describe("parseExtractReply", () => {
  it("组装成 Fact[]，id 带上 sourceId 前缀", () => {
    const facts = parseExtractReply(source, {
      facts: [
        { text: "央行下调存款准备金率", quote: "央行今日宣布下调存款准备金率" },
        { text: "自 3 月 15 日起执行", quote: "自 3 月 15 日起执行" },
      ],
    });
    expect(facts).toHaveLength(2);
    expect(facts[0]!.id).toBe("s0-f0");
    expect(facts[0]!.sourceId).toBe("s0");
    expect(facts[1]!.quote).toBe("自 3 月 15 日起执行");
  });

  it("facts 不是数组时抛", () => {
    expect(() => parseExtractReply(source, { facts: "nope" } as never)).toThrow(/facts/);
  });

  it("缺 quote 的条目被丢掉——没有引文的事实无法校验，等于没有", () => {
    const facts = parseExtractReply(source, {
      facts: [
        { text: "有引文", quote: "央行今日宣布" },
        { text: "没引文" } as never,
      ],
    });
    expect(facts).toHaveLength(1);
    expect(facts[0]!.text).toBe("有引文");
  });

  it("空 facts 数组是合法的——有些源确实没有可抽的事实", () => {
    expect(parseExtractReply(source, { facts: [] })).toEqual([]);
  });
});
