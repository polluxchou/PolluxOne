// pipeline/test/models/ledger.test.ts
import { describe, expect, it } from "vitest";
import { PRICES, costOf } from "../../src/models/pricing.js";
import { TokenLedger } from "../../src/models/ledger.js";

describe("costOf", () => {
  it("按每百万 token 计价", () => {
    // sonnet-5: $2 输入 / $10 输出
    const cents = costOf("claude-sonnet-5", { inputTokens: 1_000_000, outputTokens: 0 });
    expect(cents).toBeCloseTo(200, 6);
  });

  it("输入输出分别计价", () => {
    const cents = costOf("claude-sonnet-5", {
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
    });
    expect(cents).toBeCloseTo(1200, 6);
  });

  it("未知模型要抛，不许静默按 0 计费", () => {
    expect(() => costOf("no-such-model", { inputTokens: 1, outputTokens: 1 })).toThrow(
      /no-such-model/,
    );
  });

  it("价目表覆盖本管线用到的全部模型", () => {
    expect(PRICES["deepseek-flash"]).toBeDefined();
    expect(PRICES["deepseek-v4-pro"]).toBeDefined();
    expect(PRICES["claude-sonnet-5"]).toBeDefined();
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
    ledger.record("search", "claude-sonnet-5", { inputTokens: 100, outputTokens: 50 });
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
    ledger.record("extract", "deepseek-flash", { inputTokens: 1_000_000, outputTokens: 0 });
    ledger.recordFlatCost("search", "zhipu:search_std", 0.14);
    // 15 美分的 token 费 + 0.14 美分的按次费
    expect(ledger.totalCostCents()).toBeCloseTo(15.14, 9);
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
