// pipeline/test/models/pricing.test.ts
import { describe, expect, it } from "vitest";
import {
  PRICES,
  costOf,
  isPeakRate,
  splitInputTokens,
  type ModelPrice,
} from "../../src/models/pricing.js";

/**
 * 北京时间字面量 → Date。**显式写 +08:00 而不是靠本地时区**：这些用例在
 * 任何一台机器上都必须是同一个时刻，CI 跑在 UTC 也一样。
 */
const beijing = (literal: string) => new Date(`${literal}+08:00`);

const MTOK = 1_000_000;

describe("isPeakRate", () => {
  it("周一 9:00 整已经是高峰——区间左闭", () => {
    expect(isPeakRate(beijing("2026-09-21T09:00:00"))).toBe(true);
  });

  it("周一 8:59:59 还是空闲", () => {
    expect(isPeakRate(beijing("2026-09-21T08:59:59.999"))).toBe(false);
  });

  it("11:59:59.999 是高峰，12:00:00 整是空闲——区间右开", () => {
    expect(isPeakRate(beijing("2026-09-21T11:59:59.999"))).toBe(true);
    expect(isPeakRate(beijing("2026-09-21T12:00:00"))).toBe(false);
  });

  it("午休 12:00–14:00 是空闲", () => {
    expect(isPeakRate(beijing("2026-09-21T12:30:00"))).toBe(false);
    expect(isPeakRate(beijing("2026-09-21T13:59:00"))).toBe(false);
  });

  it("14:00 整重新进高峰", () => {
    expect(isPeakRate(beijing("2026-09-21T14:00:00"))).toBe(true);
  });

  it("17:59 是高峰，18:00 整是空闲", () => {
    expect(isPeakRate(beijing("2026-09-21T17:59:00"))).toBe(true);
    expect(isPeakRate(beijing("2026-09-21T18:00:00"))).toBe(false);
  });

  it("深夜和清晨是空闲", () => {
    expect(isPeakRate(beijing("2026-09-21T00:00:00"))).toBe(false);
    expect(isPeakRate(beijing("2026-09-21T23:59:59"))).toBe(false);
  });

  it("周六全天空闲，哪怕在 9:00–18:00 之间", () => {
    expect(isPeakRate(beijing("2026-09-26T10:00:00"))).toBe(false);
    expect(isPeakRate(beijing("2026-09-26T15:00:00"))).toBe(false);
    expect(isPeakRate(beijing("2026-09-26T00:00:00"))).toBe(false);
  });

  it("周日全天空闲", () => {
    expect(isPeakRate(beijing("2026-09-27T10:00:00"))).toBe(false);
    expect(isPeakRate(beijing("2026-09-27T16:30:00"))).toBe(false);
  });

  it("周五 16:00 仍是工作日高峰", () => {
    expect(isPeakRate(beijing("2026-09-25T16:00:00"))).toBe(true);
  });

  /**
   * 服务器不在中国：同一个瞬间在纽约是**周日晚上**，在北京已经是周一上午 10 点。
   * 判定必须跟着北京走，否则一台跑在 UTC-4 的机器会把高峰全判成周末空闲，
   * 账少算一半。
   */
  it("跨时区：机器在纽约也判北京的时段", () => {
    // 纽约本地是周日晚上 22:00，同一瞬间北京已经是周一上午 10:00。
    // 读本地时钟会得到「周日」→ 空闲，把高峰的钱少算一半。
    const sundayEveningInNewYork = new Date("2026-09-20T22:00:00-04:00");
    expect(sundayEveningInNewYork.toISOString()).toBe("2026-09-21T02:00:00.000Z");
    expect(isPeakRate(sundayEveningInNewYork)).toBe(true);
  });

  it("跨时区：也不能直接按 UTC 判——UTC 周五 16:30 是北京周六凌晨", () => {
    const at = new Date("2026-09-26T00:30:00+08:00"); // 北京周六 00:30
    // 按 UTC 读是周五 16:30，正落在 14:00–18:00 里，会被误判成高峰
    expect(at.getUTCDay()).toBe(5);
    expect(at.getUTCHours()).toBe(16);
    expect(isPeakRate(at)).toBe(false);
  });

  it("跨时区：UTC 凌晨 1:30 正是北京周一上午的高峰", () => {
    const at = new Date("2026-09-21T09:30:00+08:00");
    expect(at.getUTCHours()).toBe(1); // 按 UTC 读会误判成空闲
    expect(isPeakRate(at)).toBe(true);
  });

  it("UTC 的正午对北京是 20:00，是空闲", () => {
    expect(isPeakRate(new Date("2026-09-21T12:00:00Z"))).toBe(false);
  });
});

describe("PRICES", () => {
  it("覆盖本管线用到的两个模型", () => {
    expect(PRICES["deepseek-flash"]).toBeDefined();
    expect(PRICES["deepseek-v4-pro"]).toBeDefined();
  });

  it("Anthropic 那条路已删，价目表里不许再留它的死价", () => {
    expect(PRICES["claude-sonnet-5"]).toBeUndefined();
  });

  it("照抄官方表：deepseek-flash（元/MTok ×100 = 分/MTok）", () => {
    expect(PRICES["deepseek-flash"]).toEqual({
      input: {
        cacheHit: { offPeak: 2, peak: 4 }, // 0.02 / 0.04 元
        cacheMiss: { offPeak: 100, peak: 200 }, // 1 / 2 元
      },
      output: { offPeak: 400, peak: 800 }, // 4 / 8 元
    });
  });

  it("照抄官方表：deepseek-v4-pro", () => {
    expect(PRICES["deepseek-v4-pro"]).toEqual({
      input: {
        cacheHit: { offPeak: 15, peak: 30 }, // 0.15 / 0.30 元
        cacheMiss: { offPeak: 450, peak: 900 }, // 4.5 / 9.0 元
      },
      output: { offPeak: 1350, peak: 2700 }, // 13.5 / 27.0 元
    });
  });

  it("空闲价正好是高峰价的一半——抄错一个数就在这里现形", () => {
    for (const price of Object.values(PRICES)) {
      const pairs: ModelPrice["output"][] = [
        price.input.cacheHit,
        price.input.cacheMiss,
        price.output,
      ];
      for (const pair of pairs) expect(pair.offPeak * 2).toBe(pair.peak);
    }
  });

  it("单价都是整数分——不许把浮点元留在账本单位里", () => {
    for (const price of Object.values(PRICES)) {
      for (const pair of [price.input.cacheHit, price.input.cacheMiss, price.output]) {
        expect(Number.isInteger(pair.offPeak)).toBe(true);
        expect(Number.isInteger(pair.peak)).toBe(true);
      }
    }
  });
});

describe("splitInputTokens", () => {
  it("和等于总数时照实用", () => {
    expect(
      splitInputTokens({
        inputTokens: 101,
        cacheHitTokens: 60,
        cacheMissTokens: 41,
      }),
    ).toEqual({ cacheHit: 60, cacheMiss: 41 });
  });

  it("字段缺失时全按未命中——偏贵是安全的方向", () => {
    expect(splitInputTokens({ inputTokens: 101 })).toEqual({
      cacheHit: 0,
      cacheMiss: 101,
    });
  });

  it("加起来对不上就全按未命中，不信那个便宜的数", () => {
    expect(
      splitInputTokens({
        inputTokens: 101,
        cacheHitTokens: 100,
        cacheMissTokens: 100,
      }),
    ).toEqual({ cacheHit: 0, cacheMiss: 101 });
  });

  it("负数也算对不上", () => {
    expect(
      splitInputTokens({
        inputTokens: 100,
        cacheHitTokens: 150,
        cacheMissTokens: -50,
      }),
    ).toEqual({ cacheHit: 0, cacheMiss: 100 });
  });

  it("NaN 不许漏进账本", () => {
    expect(
      splitInputTokens({
        inputTokens: 100,
        cacheHitTokens: Number.NaN,
        cacheMissTokens: Number.NaN,
      }),
    ).toEqual({ cacheHit: 0, cacheMiss: 100 });
  });

  it("全命中和全未命中都是合法的拆分", () => {
    expect(
      splitInputTokens({
        inputTokens: 80,
        cacheHitTokens: 80,
        cacheMissTokens: 0,
      }),
    ).toEqual({ cacheHit: 80, cacheMiss: 0 });
    expect(
      splitInputTokens({
        inputTokens: 80,
        cacheHitTokens: 0,
        cacheMissTokens: 80,
      }),
    ).toEqual({ cacheHit: 0, cacheMiss: 80 });
  });
});

describe("costOf", () => {
  it("按每百万 token 计价，单位人民币分", () => {
    // deepseek-flash 输入未命中·空闲 = 1 元/MTok = 100 分
    expect(costOf("deepseek-flash", { inputTokens: MTOK, outputTokens: 0 }, false)).toBeCloseTo(
      100,
      9,
    );
  });

  it("输入输出分别计价", () => {
    // 空闲：输入未命中 100 分 + 输出 400 分
    expect(
      costOf("deepseek-flash", { inputTokens: MTOK, outputTokens: MTOK }, false),
    ).toBeCloseTo(500, 9);
  });

  it("高峰价正好是空闲价的两倍", () => {
    const usage = { inputTokens: 12_345, outputTokens: 6_789 };
    expect(costOf("deepseek-flash", usage, true)).toBeCloseTo(
      costOf("deepseek-flash", usage, false) * 2,
      9,
    );
  });

  it("不传时段就按高峰计——偏贵的方向", () => {
    const usage = { inputTokens: MTOK, outputTokens: 0 };
    expect(costOf("deepseek-flash", usage)).toBeCloseTo(costOf("deepseek-flash", usage, true), 9);
    expect(costOf("deepseek-flash", usage)).toBeCloseTo(200, 9);
  });

  it("缓存命中的输入按命中价——flash 上便宜 50 倍", () => {
    const hit = costOf(
      "deepseek-flash",
      { inputTokens: MTOK, outputTokens: 0, cacheHitTokens: MTOK, cacheMissTokens: 0 },
      false,
    );
    const miss = costOf(
      "deepseek-flash",
      { inputTokens: MTOK, outputTokens: 0, cacheHitTokens: 0, cacheMissTokens: MTOK },
      false,
    );
    expect(hit).toBeCloseTo(2, 9);
    expect(miss).toBeCloseTo(hit * 50, 9);
  });

  it("混合拆分两段分别计价", () => {
    // 90 万命中 ×2 分 + 10 万未命中 ×100 分 = 1.8 + 10 = 11.8 分
    expect(
      costOf(
        "deepseek-flash",
        {
          inputTokens: MTOK,
          outputTokens: 0,
          cacheHitTokens: 900_000,
          cacheMissTokens: 100_000,
        },
        false,
      ),
    ).toBeCloseTo(11.8, 9);
  });

  it("拆分对不上时按全部未命中计，贵于照信那个拆分", () => {
    const bogus = {
      inputTokens: MTOK,
      outputTokens: 0,
      cacheHitTokens: MTOK, // 和 miss 加起来是 2×MTOK ≠ inputTokens
      cacheMissTokens: MTOK,
    };
    expect(costOf("deepseek-flash", bogus, false)).toBeCloseTo(100, 9);
  });

  it("v4-pro 比 flash 贵，每一档都是", () => {
    const usage = { inputTokens: 100_000, outputTokens: 50_000 };
    for (const peak of [true, false]) {
      expect(costOf("deepseek-v4-pro", usage, peak)).toBeGreaterThan(
        costOf("deepseek-flash", usage, peak),
      );
    }
  });

  it("未知模型要抛，不许静默按 0 计费", () => {
    expect(() => costOf("no-such-model", { inputTokens: 1, outputTokens: 1 })).toThrow(
      /no-such-model/,
    );
  });

  it("reasoning token 不参与计价——它已经含在 outputTokens 里", () => {
    const withReasoning = costOf(
      "deepseek-flash",
      { inputTokens: 101, outputTokens: 259, reasoningTokens: 189 },
      false,
    );
    const without = costOf("deepseek-flash", { inputTokens: 101, outputTokens: 259 }, false);
    expect(withReasoning).toBeCloseTo(without, 12);
  });

  it("空用量是零，不是 NaN", () => {
    expect(costOf("deepseek-flash", { inputTokens: 0, outputTokens: 0 }, false)).toBe(0);
  });
});
