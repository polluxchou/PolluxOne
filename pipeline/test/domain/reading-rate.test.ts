import { describe, expect, it } from "vitest";
import { medianRate, resolveCharsPerSecond } from "../../src/domain/reading-rate.js";
import { DEFAULT_CHARS_PER_SECOND } from "../../src/domain/prosody.js";

describe("medianRate", () => {
  it("奇数个取中间", () => {
    expect(medianRate([4, 5, 6])).toBe(5);
  });

  it("偶数个取中间两个的平均", () => {
    expect(medianRate([4, 5, 6, 7])).toBe(5.5);
  });

  it("中位数而不是平均——一次读错稿的极慢 take 不该拉低整体", () => {
    expect(medianRate([5, 5, 5, 5, 0.5])).toBe(5);
  });

  it("只取最近 10 个", () => {
    const rates = [...Array(15).fill(9), ...Array(0)];
    expect(medianRate(rates.slice(-10))).toBe(9);
  });

  it("空数组返回 null", () => {
    expect(medianRate([])).toBeNull();
  });
});

describe("resolveCharsPerSecond", () => {
  it("有历史就用历史", () => {
    expect(resolveCharsPerSecond("cjk", [6, 6, 6])).toBe(6);
  });

  it("没有历史就退回语种默认值——新用户第一篇必然走这条", () => {
    expect(resolveCharsPerSecond("cjk", [])).toBe(DEFAULT_CHARS_PER_SECOND.cjk);
    expect(resolveCharsPerSecond("latin", [])).toBe(DEFAULT_CHARS_PER_SECOND.latin);
  });
});
