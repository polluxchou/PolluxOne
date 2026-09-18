// pipeline/src/models/zhipu-search.ts
import { fetchWithTimeout, requestWithRetry } from "../net/http.js";
import type { TokenLedger } from "./ledger.js";

export const ZHIPU_SEARCH_URL = "https://open.bigmodel.cn/api/paas/v4/web_search";

export type ZhipuSearchEngine =
  | "search_std"
  | "search_pro"
  | "search_pro_sogou"
  | "search_pro_quark";

/** 智谱 Web Search 按**次**计价，单位人民币元/次。查证日期 2026-09-18。 */
export const ZHIPU_SEARCH_PRICE_YUAN: Record<ZhipuSearchEngine, number> = {
  search_std: 0.01,
  search_pro: 0.03,
  search_pro_sogou: 0.05,
  search_pro_quark: 0.05,
};

/**
 * 一次检索多少**人民币分**。engine 决定价格，和返回多少条结果无关。
 *
 * 账本和价目表现在都以人民币分记账，这里只是元换分，中间**没有汇率**：
 * 原先那个手填的 `CNY_PER_USD` 是 Anthropic 时代的遗留，它会随时间漂移，
 * 而且事后无法从账目里复现——账单上的每一分钱都该能被重新算出来。
 *
 * `Math.round`：0.03 × 100 在二进制浮点下未必正好是 3，而按次计费本来就是整数分。
 */
export function searchCostCents(engine: ZhipuSearchEngine): number {
  return Math.round(ZHIPU_SEARCH_PRICE_YUAN[engine] * 100);
}

/** 文档写明 search_query 建议 ≤70 字符，超了按截断处理更可控。 */
export const MAX_QUERY_CHARS = 70;

export interface ZhipuSearchItem {
  title?: string;
  content?: string;
  link?: string;
  media?: string;
  icon?: string;
  refer?: string;
  publish_date?: string;
}

/**
 * 从 `search_result` 里收 URL：去重，保持首次出现顺序。
 *
 * 入参声明成 unknown 而不是数组：智谱在没有命中时会把 `search_result` 整个
 * 省掉，取到 undefined 再去 for...of 就是一个 TypeError，而不是「没搜到」。
 */
export function collectZhipuResults(searchResult: unknown): string[] {
  if (!Array.isArray(searchResult)) return [];

  const seen = new Set<string>();
  const urls: string[] = [];

  for (const item of searchResult) {
    const link = (item as ZhipuSearchItem | null)?.link;
    if (typeof link !== "string" || link === "") continue;
    if (seen.has(link)) continue;
    seen.add(link);
    urls.push(link);
  }

  return urls;
}

export type Sender = (url: string, init: RequestInit) => Promise<Response>;

export interface ZhipuSearchConfig {
  /** 默认 search_std——最便宜的一档（0.01 元/次），先跑通再谈升级。 */
  engine?: ZhipuSearchEngine;
  /** 1-50。默认 20：selectCandidates 后面会按发布方收敛到 8，20 条够它挑。 */
  count?: number;
  /**
   * 默认 oneWeek。这是新闻管线：一年前的报道对一条刚发生的新闻没有意义，
   * 而且会混进 ⑤ 的独立源计数里，把一个虚高的 independence 送进选点。
   */
  recency?: "oneDay" | "oneWeek" | "oneMonth" | "oneYear" | "noLimit";
}

/**
 * 智谱 BigModel 的 Web Search API。**不是模型调用**——它不产生 token，
 * 只按次收费，所以记账走 ledger.recordFlatCost 而不是 record。
 */
export class ZhipuSearchClient {
  private readonly engine: ZhipuSearchEngine;
  private readonly count: number;
  private readonly recency: string;

  constructor(
    private readonly apiKey: string,
    private readonly ledger: TokenLedger,
    config: ZhipuSearchConfig = {},
    private readonly send: Sender = (url, init) => fetchWithTimeout(url, init, 45_000),
  ) {
    this.engine = config.engine ?? "search_std";
    this.count = config.count ?? 20;
    this.recency = config.recency ?? "oneWeek";
  }

  async findSources(headline: string): Promise<string[]> {
    const response = await requestWithRetry(
      () =>
        this.send(ZHIPU_SEARCH_URL, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${this.apiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            search_query: headline.slice(0, MAX_QUERY_CHARS),
            search_engine: this.engine,
            search_recency_filter: this.recency,
            count: this.count,
          }),
        }),
      { attempts: 3, backoffMs: 1000 },
    );

    // 先记账再解析：拿到 200 的那一刻这一次就已经被计费了，回包解析不出来
    // 也不退钱。重试掉的 429/5xx 不计费，所以记一次而不是记 attempts 次。
    this.ledger.recordFlatCost("search", `zhipu:${this.engine}`, searchCostCents(this.engine));

    const payload = (await response.json()) as { search_result?: unknown };
    return collectZhipuResults(payload.search_result);
  }
}
