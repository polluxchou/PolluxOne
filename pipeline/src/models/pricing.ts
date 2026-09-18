// pipeline/src/models/pricing.ts

/** 美分 / 每百万 token。查证日期 2026-09-18。 */
export interface ModelPrice {
  inputCentsPerMTok: number;
  outputCentsPerMTok: number;
}

export const PRICES: Record<string, ModelPrice> = {
  // DeepSeek 官网价（$0.15 / $0.60 每 MTok）
  "deepseek-flash": { inputCentsPerMTok: 15, outputCentsPerMTok: 60 },
  "deepseek-v4-pro": { inputCentsPerMTok: 55, outputCentsPerMTok: 219 },
  // Anthropic 价目表：$2 / $10 每 MTok
  "claude-sonnet-5": { inputCentsPerMTok: 200, outputCentsPerMTok: 1000 },
};

export interface Usage {
  inputTokens: number;
  outputTokens: number;
  /**
   * 推理 token。**已经含在 outputTokens 里**，只作展示用，不参与计价——
   * 实测 deepseek-flash 一次调用 259 个输出 token 里有 189 个是推理，
   * 重复计价会让账单虚高 1.7 倍。
   */
  reasoningTokens?: number;
}

export function costOf(model: string, usage: Usage): number {
  const price = PRICES[model];
  if (!price) {
    // 静默按 0 计费会让一个没上价目表的新模型免费跑到账单爆炸为止。
    throw new Error(`价目表里没有 ${model}，请先在 PRICES 补上再调用它`);
  }
  return (
    (usage.inputTokens / 1_000_000) * price.inputCentsPerMTok +
    (usage.outputTokens / 1_000_000) * price.outputCentsPerMTok
  );
}
