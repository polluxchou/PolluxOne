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
