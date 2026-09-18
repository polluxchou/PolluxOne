// pipeline/src/models/ledger.ts
import { costOf, type Usage } from "./pricing.js";

export type StageName =
  | "fetch"
  | "search"
  | "extract"
  | "conflict"
  | "draft";

interface TokenEntry {
  kind: "tokens";
  stage: StageName;
  model: string;
  usage: Usage;
}

/** 按次计费的一笔支出：没有 token，只有次数和单价。 */
interface FlatEntry {
  kind: "flat";
  stage: StageName;
  label: string;
  cents: number;
}

type Entry = TokenEntry | FlatEntry;

export interface Totals {
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
}

/** 分阶段的账：token 归 token，按次计费的钱单列一栏。 */
export interface StageTotals extends Totals {
  flatCostCents: number;
}

/**
 * spec §10.1：token 是一等产品对象。要展示给用户、要据以收费，
 * 所以它必须是**被记录的事实**，不是事后按字数估的账。
 */
export class TokenLedger {
  private entries: Entry[] = [];

  record(stage: StageName, model: string, usage: Usage): void {
    // 先算一次价：模型不在价目表里要在记账时就炸，而不是在结账时。
    costOf(model, usage);
    this.entries.push({ kind: "tokens", stage, model, usage });
  }

  /**
   * 按次计费的一笔支出（智谱 Web Search：0.01 元/次，没有 token）。
   *
   * 它必须是**独立的一条通道**，不能折算成假 token 塞进 record()：
   * 账单同时要回答「花了多少钱」和「烧了多少 token」两个问题，硬凑一个
   * token 数会让后者变成谎话，而 token 数正是解释账单为什么高的那条线索。
   * 于是：totalCostCents() 算它，totals() 的 token 数一个不动。
   */
  recordFlatCost(stage: StageName, label: string, cents: number): void {
    if (!Number.isFinite(cents) || cents < 0) {
      // NaN 会把整张账单变成 NaN，而且是在结账那一刻才发现。就地炸。
      throw new Error(`按次计费的金额必须是非负有限数，${label} 给的是 ${cents}`);
    }
    this.entries.push({ kind: "flat", stage, label, cents });
  }

  totals(): Totals {
    return this.entries.reduce<Totals>(
      (acc, e) =>
        e.kind === "tokens"
          ? {
              inputTokens: acc.inputTokens + e.usage.inputTokens,
              outputTokens: acc.outputTokens + e.usage.outputTokens,
              reasoningTokens: acc.reasoningTokens + (e.usage.reasoningTokens ?? 0),
            }
          : acc, // 按次计费没有 token，不许在这里凭空造一个。
      { inputTokens: 0, outputTokens: 0, reasoningTokens: 0 },
    );
  }

  byStage(): Record<string, StageTotals> {
    const out: Record<string, StageTotals> = {};
    const blank = (): StageTotals => ({
      inputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
      flatCostCents: 0,
    });

    for (const e of this.entries) {
      const cur = out[e.stage] ?? blank();
      out[e.stage] =
        e.kind === "tokens"
          ? {
              ...cur,
              inputTokens: cur.inputTokens + e.usage.inputTokens,
              outputTokens: cur.outputTokens + e.usage.outputTokens,
              reasoningTokens: cur.reasoningTokens + (e.usage.reasoningTokens ?? 0),
            }
          : { ...cur, flatCostCents: cur.flatCostCents + e.cents };
    }
    return out;
  }

  totalCostCents(): number {
    return this.entries.reduce(
      (sum, e) => sum + (e.kind === "tokens" ? costOf(e.model, e.usage) : e.cents),
      0,
    );
  }
}
