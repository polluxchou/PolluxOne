// pipeline/src/models/pricing.ts

/**
 * 计价单位：**人民币分 / 每百万 token**，表里全是整数分。查证日期 2026-09-18，
 * 来源 https://api-docs.deepseek.com/zh-cn/quick_start/pricing （官方以元/百万
 * token 报价，这里 ×100 存成分）。
 *
 * 这里**没有汇率**。DeepSeek 和智谱都按人民币报价，spec §10.1 给用户看的也是
 * ¥——中间再插一个手填的 USD 汇率，等于往账本里掺一个会随时间漂移、且事后
 * 无法从账目复现的数。
 */

/**
 * 同一档价的两个时段价。DeepSeek 的官方表里 `offPeak` 恰好是 `peak` 的一半，
 * 但这里**两个数都照抄**而不是写成 `peak / 2`：那个二分之一是官方此刻的定价
 * 策略，不是价目表的结构。它哪天不再成立，改的应该是数字，不是代码。
 */
export interface RatePair {
  /** 高峰时段单价，分 / 百万 token。 */
  peak: number;
  /** 空闲时段单价，分 / 百万 token。 */
  offPeak: number;
}

/**
 * 一个模型的完整价目。四个维度在类型里各占一层，一个都不摊平成裸数字：
 *
 *   模型 → 输入 / 输出 → （输入再分）缓存命中 / 未命中 → 高峰 / 空闲
 *
 * 输出没有缓存一说，所以它只有时段那一层——把它硬凑成和输入一样的形状，
 * 会凭空造出「输出·缓存命中」这种不存在的价。
 */
export interface ModelPrice {
  input: { cacheHit: RatePair; cacheMiss: RatePair };
  output: RatePair;
}

export const PRICES: Record<string, ModelPrice> = {
  // 元/MTok：命中 0.02/0.04，未命中 1/2，输出 4/8
  "deepseek-flash": {
    input: {
      cacheHit: { offPeak: 2, peak: 4 },
      cacheMiss: { offPeak: 100, peak: 200 },
    },
    output: { offPeak: 400, peak: 800 },
  },
  // 元/MTok：命中 0.15/0.30，未命中 4.5/9.0，输出 13.5/27.0
  "deepseek-v4-pro": {
    input: {
      cacheHit: { offPeak: 15, peak: 30 },
      cacheMiss: { offPeak: 450, peak: 900 },
    },
    output: { offPeak: 1350, peak: 2700 },
  },
};

/** 北京时间相对 UTC 的固定偏移。中国不实行夏令时，这个数全年不变。 */
const BEIJING_UTC_OFFSET_MS = 8 * 60 * 60 * 1000;

const PEAK_WINDOWS_MINUTES = [
  [9 * 60, 12 * 60],
  [14 * 60, 18 * 60],
] as const;

/**
 * 这一刻算不算高峰时段：**北京时间**周一至周五 9:00–12:00 和 14:00–18:00。
 *
 * 纯函数，时刻由调用方给。**故意不在这里取 `new Date()`**：那会让同一笔账在
 * 不同时刻结出不同的钱——不可复现，也没法测。
 *
 * 实现上先把时刻平移 8 小时再一律读 `getUTC*`，而不是读本地的 `getHours()`：
 * 服务器不一定在中国，本地时区是什么与这条计费规则无关。
 *
 * 区间是**左闭右开**：11:59:59.999 仍是高峰，12:00:00.000 已经是空闲。
 */
export function isPeakRate(at: Date): boolean {
  const beijing = new Date(at.getTime() + BEIJING_UTC_OFFSET_MS);

  const weekday = beijing.getUTCDay();
  if (weekday === 0 || weekday === 6) return false; // 周日 / 周六全天空闲

  const minutes =
    beijing.getUTCHours() * 60 + beijing.getUTCMinutes();
  return PEAK_WINDOWS_MINUTES.some(([from, to]) => minutes >= from && minutes < to);
}

export interface Usage {
  /** `prompt_tokens`：输入 token **总数**。下面两项是它的拆分，不是它之外的量。 */
  inputTokens: number;
  outputTokens: number;
  /**
   * 推理 token。**已经含在 outputTokens 里**，只作展示用，不参与计价——
   * 实测 deepseek-flash 一次调用 259 个输出 token 里有 189 个是推理，
   * 重复计价会让账单虚高 1.7 倍。
   */
  reasoningTokens?: number;
  /** `prompt_cache_hit_tokens`。命中价比未命中便宜 50 倍，丢掉它等于全按未命中算。 */
  cacheHitTokens?: number;
  /** `prompt_cache_miss_tokens`。 */
  cacheMissTokens?: number;
}

export interface InputSplit {
  cacheHit: number;
  cacheMiss: number;
}

/** 拆分只关心输入那三个数，不必为了调用它凑一个完整的 `Usage`。 */
export type InputTokenCounts = Pick<
  Usage,
  "inputTokens" | "cacheHitTokens" | "cacheMissTokens"
>;

/**
 * 把输入 token 拆成命中／未命中两份。
 *
 * **对不上就全按未命中计**——字段缺失、是负数、或者两者之和不等于
 * `inputTokens`（上游改了字段语义、回包被截断、我们这边映射错了，都会长这样）。
 * 理由是方向性的：未命中是**贵**的那一档（50 倍），偏贵是安全的。用户看到的
 * 账单只会比真实的高，④ 确认页那道余额门禁只会更保守；反过来按命中兜底，
 * 账会算少，门禁会放行一笔其实付不起的调研。
 *
 * 判据用「和等于总数」而不是「字段存在」：两个字段都在、加起来却不对，
 * 说明我们对这份回包的理解是错的，此时更不该相信那个便宜的数。
 */
export function splitInputTokens(usage: InputTokenCounts): InputSplit {
  const { inputTokens, cacheHitTokens: hit, cacheMissTokens: miss } = usage;

  const trustworthy =
    typeof hit === "number" &&
    typeof miss === "number" &&
    Number.isFinite(hit) &&
    Number.isFinite(miss) &&
    hit >= 0 &&
    miss >= 0 &&
    hit + miss === inputTokens;

  return trustworthy
    ? { cacheHit: hit, cacheMiss: miss }
    : { cacheHit: 0, cacheMiss: inputTokens };
}

const rate = (pair: RatePair, peak: boolean): number => (peak ? pair.peak : pair.offPeak);

/**
 * 一次调用多少**人民币分**。
 *
 * `peak` 是**已经判好的结果**，不是时刻：判定归 `isPeakRate`，而且应当在记账
 * 那一刻做完并存下来（见 `TokenLedger.record`）。这个函数因此是纯的——同一笔
 * 用量任何时候重算都是同一个数。
 *
 * 不传 `peak` 就按高峰计：偏贵的方向，和上面拆分对不上时的兜底同一个道理。
 */
export function costOf(model: string, usage: Usage, peak = true): number {
  const price = PRICES[model];
  if (!price) {
    // 静默按 0 计费会让一个没上价目表的新模型免费跑到账单爆炸为止。
    throw new Error(`价目表里没有 ${model}，请先在 PRICES 补上再调用它`);
  }

  const { cacheHit, cacheMiss } = splitInputTokens(usage);

  return (
    (cacheHit / 1_000_000) * rate(price.input.cacheHit, peak) +
    (cacheMiss / 1_000_000) * rate(price.input.cacheMiss, peak) +
    (usage.outputTokens / 1_000_000) * rate(price.output, peak)
  );
}
