// pipeline/src/models/ledger.ts
import { costOf, type Usage } from "./pricing.js";

export type StageName =
  | "fetch"
  | "search"
  | "extract"
  | "conflict"
  | "draft";

interface Entry {
  stage: StageName;
  model: string;
  usage: Usage;
}

export interface Totals {
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
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
    this.entries.push({ stage, model, usage });
  }

  totals(): Totals {
    return this.entries.reduce<Totals>(
      (acc, e) => ({
        inputTokens: acc.inputTokens + e.usage.inputTokens,
        outputTokens: acc.outputTokens + e.usage.outputTokens,
        reasoningTokens: acc.reasoningTokens + (e.usage.reasoningTokens ?? 0),
      }),
      { inputTokens: 0, outputTokens: 0, reasoningTokens: 0 },
    );
  }

  byStage(): Record<string, Totals> {
    const out: Record<string, Totals> = {};
    for (const e of this.entries) {
      const cur = out[e.stage] ?? { inputTokens: 0, outputTokens: 0, reasoningTokens: 0 };
      out[e.stage] = {
        inputTokens: cur.inputTokens + e.usage.inputTokens,
        outputTokens: cur.outputTokens + e.usage.outputTokens,
        reasoningTokens: cur.reasoningTokens + (e.usage.reasoningTokens ?? 0),
      };
    }
    return out;
  }

  totalCostCents(): number {
    return this.entries.reduce((sum, e) => sum + costOf(e.model, e.usage), 0);
  }
}
