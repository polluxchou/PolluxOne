// pipeline/test/stages/fetch.test.ts
import { describe, expect, it } from "vitest";
import { parseJinaResponse } from "../../src/net/jina.js";
import { publisherOf, toSource } from "../../src/stages/fetch.js";

const SAMPLE = `Title: 央行宣布降准

URL Source: https://www.example.com.cn/news/1

Markdown Content:
央行今日宣布下调存款准备金率 0.5 个百分点。

本文转自新华社。
`;

describe("parseJinaResponse", () => {
  it("拆出标题、源 URL、正文", () => {
    const parsed = parseJinaResponse(SAMPLE);
    expect(parsed.title).toBe("央行宣布降准");
    expect(parsed.url).toBe("https://www.example.com.cn/news/1");
    expect(parsed.body).toContain("下调存款准备金率");
    expect(parsed.body).not.toContain("Markdown Content:");
  });

  it("头部缺失时不崩，正文退化为全文", () => {
    const parsed = parseJinaResponse("就是一段正文，没有任何头部。");
    expect(parsed.title).toBe("");
    expect(parsed.body).toBe("就是一段正文，没有任何头部。");
  });

  it("正文为空要抛——空正文喂进 ③ 会抽出零个事实，白烧一轮 token", () => {
    expect(() => parseJinaResponse("Title: x\n\nURL Source: https://a.com\n\nMarkdown Content:\n\n   ")).toThrow(
      /正文为空/,
    );
  });
});

describe("publisherOf", () => {
  it("从域名取发布方", () => {
    expect(publisherOf("https://www.chinanews.com.cn/news/1")).toBe("chinanews.com.cn");
    expect(publisherOf("https://finance.sina.com.cn/a/b")).toBe("sina.com.cn");
  });

  it("双段后缀不被切坏", () => {
    expect(publisherOf("https://www.bbc.co.uk/news")).toBe("bbc.co.uk");
  });

  it("非法 URL 抛", () => {
    expect(() => publisherOf("不是个链接")).toThrow();
  });
});

describe("toSource", () => {
  it("组装成 Source，id 稳定可复现", () => {
    const a = toSource("s0", parseJinaResponse(SAMPLE), "2026-09-18T00:00:00Z");
    expect(a.id).toBe("s0");
    expect(a.publisher).toBe("example.com.cn");
    expect(a.body).toContain("下调存款准备金率");
  });

  it("认出「本文转自X」并填进 creditedTo——独立源计数靠它", () => {
    const s = toSource("s0", parseJinaResponse(SAMPLE), "2026-09-18T00:00:00Z");
    expect(s.creditedTo).toBe("新华社");
  });

  it("没有转载声明时 creditedTo 是 null，不是空串", () => {
    const text = `Title: t

URL Source: https://a.com/1

Markdown Content:
一段没有转载声明的正文。
`;
    expect(toSource("s1", parseJinaResponse(text), "2026-09-18T00:00:00Z").creditedTo).toBeNull();
  });
});
