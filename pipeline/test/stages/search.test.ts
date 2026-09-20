// pipeline/test/stages/search.test.ts
import { describe, expect, it } from "vitest";
import { selectCandidates } from "../../src/stages/search.js";

describe("selectCandidates", () => {
  it("剔除原文自己", () => {
    const out = selectCandidates(
      ["https://a.com/1", "https://b.com/2"],
      "https://a.com/1",
      10,
    );
    expect(out).toEqual(["https://b.com/2"]);
  });

  it("同一发布方只留第一个——一家媒体的多个页面不是多个独立源", () => {
    const out = selectCandidates(
      ["https://a.com/1", "https://a.com/2", "https://b.com/1"],
      "https://z.com/0",
      10,
    );
    expect(out).toEqual(["https://a.com/1", "https://b.com/1"]);
  });

  it("剔除和原文同一发布方的页面", () => {
    const out = selectCandidates(
      ["https://a.com/other", "https://b.com/1"],
      "https://a.com/1",
      10,
    );
    expect(out).toEqual(["https://b.com/1"]);
  });

  it("按上限截断——抓取是最贵的一步", () => {
    const out = selectCandidates(
      ["https://a.com/1", "https://b.com/1", "https://c.com/1"],
      "https://z.com/0",
      2,
    );
    expect(out).toHaveLength(2);
  });

  it("非法 URL 被跳过而不是让整个阶段崩", () => {
    const out = selectCandidates(["不是链接", "https://b.com/1"], "https://z.com/0", 10);
    expect(out).toEqual(["https://b.com/1"]);
  });

  it("全部被剔除时返回空数组——上层据此走「信源不足」", () => {
    expect(selectCandidates(["https://a.com/1"], "https://a.com/1", 10)).toEqual([]);
  });
});
