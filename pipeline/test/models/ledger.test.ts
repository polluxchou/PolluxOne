// pipeline/test/models/ledger.test.ts
import { describe, expect, it } from "vitest";
import { PRICES, costOf } from "../../src/models/pricing.js";
import { TokenLedger } from "../../src/models/ledger.js";

/** 周六 10:00（北京），全天空闲价。峰谷判定的边界用例在 pricing.test.ts。 */
const OFF_PEAK = new Date("2026-09-26T10:00:00+08:00");

describe("costOf", () => {
  it("按每百万 token 计价", () => {
    // deepseek-flash 输入·未命中·空闲：1 元/MTok = 100 分
    const cents = costOf("deepseek-flash", { inputTokens: 1_000_000, outputTokens: 0 }, false);
    expect(cents).toBeCloseTo(100, 6);
  });

  it("输入输出分别计价", () => {
    const cents = costOf(
      "deepseek-flash",
      {
        inputTokens: 1_000_000,
        outputTokens: 1_000_000,
      },
      false,
    );
    // 空闲：输入未命中 100 分 + 输出 4 元/MTok = 400 分
    expect(cents).toBeCloseTo(500, 6);
  });

  it("未知模型要抛，不许静默按 0 计费", () => {
    expect(() => costOf("no-such-model", { inputTokens: 1, outputTokens: 1 })).toThrow(
      /no-such-model/,
    );
  });

  it("价目表覆盖本管线用到的全部模型", () => {
    expect(PRICES["deepseek-flash"]).toBeDefined();
    expect(PRICES["deepseek-v4-pro"]).toBeDefined();
  });
});

describe("TokenLedger", () => {
  it("累加各阶段用量", () => {
    const ledger = new TokenLedger();
    ledger.record("extract", "deepseek-flash", { inputTokens: 1000, outputTokens: 500 });
    ledger.record("extract", "deepseek-flash", { inputTokens: 2000, outputTokens: 300 });
    expect(ledger.totals().inputTokens).toBe(3000);
    expect(ledger.totals().outputTokens).toBe(800);
  });

  it("按阶段分组——⑤ 的进度条要显示每阶段花了多少", () => {
    const ledger = new TokenLedger();
    ledger.record("search", "deepseek-v4-pro", { inputTokens: 100, outputTokens: 50 });
    ledger.record("extract", "deepseek-flash", { inputTokens: 900, outputTokens: 20 });
    const byStage = ledger.byStage();
    expect(byStage.search!.inputTokens).toBe(100);
    expect(byStage.extract!.inputTokens).toBe(900);
  });

  it("reasoning token 不重复计价——它已经含在 outputTokens 里", () => {
    const ledger = new TokenLedger();
    ledger.record("extract", "deepseek-flash", {
      inputTokens: 101,
      outputTokens: 259,
      reasoningTokens: 189,
    });
    const plain = new TokenLedger();
    plain.record("extract", "deepseek-flash", { inputTokens: 101, outputTokens: 259 });
    expect(ledger.totalCostCents()).toBeCloseTo(plain.totalCostCents(), 9);
  });

  it("reasoning token 仍然被记下来——它是解释账单为什么高的唯一线索", () => {
    const ledger = new TokenLedger();
    ledger.record("extract", "deepseek-flash", {
      inputTokens: 101,
      outputTokens: 259,
      reasoningTokens: 189,
    });
    expect(ledger.totals().reasoningTokens).toBe(189);
  });

  it("空账本是零，不是 NaN", () => {
    const ledger = new TokenLedger();
    expect(ledger.totalCostCents()).toBe(0);
    expect(ledger.totals().inputTokens).toBe(0);
  });
});

describe("TokenLedger.recordFlatCost", () => {
  it("按次计费的钱要进总账——不记等于账单少算", () => {
    const ledger = new TokenLedger();
    ledger.recordFlatCost("search", "zhipu:search_std", 0.14);
    ledger.recordFlatCost("search", "zhipu:search_std", 0.14);
    expect(ledger.totalCostCents()).toBeCloseTo(0.28, 9);
  });

  it("按次计费不产生 token——不许为了凑一行账而编一个 token 数", () => {
    const ledger = new TokenLedger();
    ledger.recordFlatCost("search", "zhipu:search_std", 0.14);
    expect(ledger.totals()).toEqual({
      inputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
    });
  });

  it("和 token 计费并存时两边各算各的", () => {
    const ledger = new TokenLedger();
    ledger.record(
      "extract",
      "deepseek-flash",
      { inputTokens: 1_000_000, outputTokens: 0 },
      OFF_PEAK,
    );
    ledger.recordFlatCost("search", "zhipu:search_std", 0.14);
    // 100 分的 token 费（输入全按未命中·空闲）+ 0.14 分的按次费
    expect(ledger.totalCostCents()).toBeCloseTo(100.14, 9);
    expect(ledger.totals().inputTokens).toBe(1_000_000);
  });

  it("byStage 里单列一栏——⑤ 的分阶段展示要对得上", () => {
    const ledger = new TokenLedger();
    ledger.recordFlatCost("search", "zhipu:search_std", 0.14);
    ledger.record("extract", "deepseek-flash", { inputTokens: 900, outputTokens: 20 });

    const byStage = ledger.byStage();
    expect(byStage.search!.flatCostCents).toBeCloseTo(0.14, 9);
    // 搜索阶段的 token 仍然是 0，这是事实，不是漏记
    expect(byStage.search!.inputTokens).toBe(0);
    expect(byStage.extract!.flatCostCents).toBe(0);
    expect(byStage.extract!.inputTokens).toBe(900);
  });

  it("同一阶段里 token 费和按次费互不覆盖", () => {
    const ledger = new TokenLedger();
    ledger.record("search", "deepseek-flash", { inputTokens: 100, outputTokens: 50 });
    ledger.recordFlatCost("search", "zhipu:search_std", 0.14);

    const search = ledger.byStage().search!;
    expect(search.inputTokens).toBe(100);
    expect(search.outputTokens).toBe(50);
    expect(search.flatCostCents).toBeCloseTo(0.14, 9);
  });

  it("金额不是非负有限数就地炸——NaN 会把整张账单变成 NaN", () => {
    const ledger = new TokenLedger();
    expect(() => ledger.recordFlatCost("search", "zhipu:search_std", Number.NaN)).toThrow(
      /zhipu:search_std/,
    );
    expect(() => ledger.recordFlatCost("search", "zhipu:search_std", -1)).toThrow();
    expect(ledger.totalCostCents()).toBe(0);
  });

  it("零元的一次（比如免费额度内）记得下，也不影响别的", () => {
    const ledger = new TokenLedger();
    ledger.recordFlatCost("search", "zhipu:free", 0);
    expect(ledger.totalCostCents()).toBe(0);
    expect(ledger.byStage().search!.flatCostCents).toBe(0);
  });
});

describe("TokenLedger 的峰谷判定", () => {
  /** 周一 10:00（北京），高峰。 */
  const PEAK = new Date("2026-09-21T10:00:00+08:00");

  it("高峰记下来的一笔正好是空闲那笔的两倍", () => {
    const usage = { inputTokens: 1_000_000, outputTokens: 1_000_000 };

    const peak = new TokenLedger();
    peak.record("draft", "deepseek-v4-pro", usage, PEAK);

    const offPeak = new TokenLedger();
    offPeak.record("draft", "deepseek-v4-pro", usage, OFF_PEAK);

    expect(peak.totalCostCents()).toBeCloseTo(offPeak.totalCostCents() * 2, 9);
  });

  it("金额只取决于调用发生的时刻，不取决于结账的时刻", () => {
    const ledger = new TokenLedger();
    ledger.record("extract", "deepseek-flash", { inputTokens: 1_000_000, outputTokens: 0 }, PEAK);

    // 无论这个测试在一天里的哪一刻跑，这笔账都是高峰价：判定在记账时就冻住了。
    expect(ledger.totalCostCents()).toBeCloseTo(200, 9);
    // 反复结账得到同一个数——不重算，就不会随时间漂。
    expect(ledger.totalCostCents()).toBe(ledger.totalCostCents());
  });

  it("同一本账里两笔不同时段的调用各按各的时段计", () => {
    const usage = { inputTokens: 1_000_000, outputTokens: 0 };
    const ledger = new TokenLedger();
    ledger.record("extract", "deepseek-flash", usage, PEAK); // 200 分
    ledger.record("extract", "deepseek-flash", usage, OFF_PEAK); // 100 分
    expect(ledger.totalCostCents()).toBeCloseTo(300, 9);
  });

  it("缓存命中的拆分一路带进账本——命中那笔便宜 50 倍", () => {
    const hit = new TokenLedger();
    hit.record(
      "extract",
      "deepseek-flash",
      { inputTokens: 1_000_000, outputTokens: 0, cacheHitTokens: 1_000_000, cacheMissTokens: 0 },
      OFF_PEAK,
    );
    const miss = new TokenLedger();
    miss.record("extract", "deepseek-flash", { inputTokens: 1_000_000, outputTokens: 0 }, OFF_PEAK);

    expect(hit.totalCostCents()).toBeCloseTo(2, 9);
    expect(miss.totalCostCents()).toBeCloseTo(hit.totalCostCents() * 50, 9);
    // token 数不因为拆分而变：inputTokens 始终是总数
    expect(hit.totals().inputTokens).toBe(1_000_000);
  });
});
