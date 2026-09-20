// pipeline/src/models/zhipu-search.ts
import { fetchWithTimeout, requestWithRetry } from "../net/http.js";
import type { TokenLedger } from "./ledger.js";

export const ZHIPU_SEARCH_URL = "https://open.bigmodel.cn/api/paas/v4/web_search";

/**
 * 四个档位都留在类型里，但**只有 `search_pro_sogou` 对本管线可用**。
 * 2026-09-18 用真 key 实测同一个 query：
 *
 * | engine             | 结果数 | 带 link 的 |
 * |--------------------|-------|-----------|
 * | `search_std`       | 2     | **0**     |
 * | `search_pro`       | 2     | **0**     |
 * | `search_pro_sogou` | 50    | 50        |
 *
 * `search_std` / `search_pro` 的 `link`、`media`、`icon` 全是空字符串，只有
 * `title` / `content` / `publish_date` / `refer` 有值——文档没写这件事。
 *
 * 没有 URL，这条管线断在三处：抓不到全文（③ 抽事实点要读原文）、判不了发布方
 * （`publisherOf(url)` 是 ⑤ 独立源三条规则之一）、也给不了用户可点开的溯源链接。
 * 所以贵四倍也只能走 sogou。`search_pro_quark` 没实测过，同样不该当默认。
 */
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

/** 实测唯一会返回 link 的档位，因此也是默认档位（0.05 元/次 = 5 分/次）。 */
export const DEFAULT_ENGINE: ZhipuSearchEngine = "search_pro_sogou";

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
 * 默认丢弃的域名。
 *
 * **这是判断，不是事实**：这几个站点是可编辑的聚合/百科/问答页面，不是新闻报道。
 * 拿百科页去"印证"一条新闻是错的——它的内容常常就是从那条新闻抄来的，
 * 算成独立源就是 ⑤ 的 independence 虚高。实测里 50 条结果混了 7 条
 * `baike.baidu.com`，所以这不是假想的风险。
 *
 * 将来大概要调（比如某些百科页确实带一手引文，或者要再加几个内容农场域名），
 * 所以它可配置，别把它当成一条铁律。
 */
export const DEFAULT_BLOCKED_DOMAINS: readonly string[] = [
  "baike.baidu.com",
  "wikipedia.org",
  "zhihu.com",
];

/** 新鲜度默认窗口：一周。和原先传给引擎的 `oneWeek` 是同一个产品意图。 */
export const DEFAULT_MAX_AGE_DAYS = 7;

/**
 * 允许 `publish_date` 比"今天"早一天——`publish_date` 只有日期没有时区，
 * 一家 UTC+8 的媒体在我们的 UTC 日历上完全可能标成"明天"。
 * 不留这一天，会把最新鲜的那几条误杀。
 */
const FUTURE_SLACK_DAYS = 1;

const DAY_MS = 86_400_000;

/**
 * 把 `publish_date` 解析成那一天 UTC 零点的毫秒数；解析不了返回 null。
 *
 * 实测同一次响应里**两种格式混用**：`"2026-09-16"` 和 `"2025/05/15"`，
 * 所以横杠和斜杠都要认。
 *
 * 不用 `new Date(raw)`：它对 `"2025/05/15"` 按**本地时区**解析、对
 * `"2026-09-16"` 按 UTC 解析，同一份数据会差出半天，还会随跑测试的机器漂。
 */
export function parsePublishDate(raw: unknown): number | null {
  if (typeof raw !== "string") return null;
  const m = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[T ]\S*)?$/.exec(raw.trim());
  if (!m) return null;

  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const ms = Date.UTC(year, month - 1, day);
  const back = new Date(ms);
  // 回读一遍挡住 2026-02-31 这种会被 Date.UTC 默默进位成 3 月 3 日的日期。
  const roundTrips =
    back.getUTCFullYear() === year &&
    back.getUTCMonth() === month - 1 &&
    back.getUTCDate() === day;
  if (!roundTrips) return null;
  return ms;
}

/**
 * 发布日期距今几天（整天数，正数表示过去）。
 *
 * `now` 必须传进来，函数里**不许 `new Date()`**：否则同一份固定数据的测试
 * 结果会随运行日期漂移，今天绿明天红。
 */
export function ageInDays(publishedAtMs: number, now: Date): number {
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  return Math.round((today - publishedAtMs) / DAY_MS);
}

/** 域名命中黑名单（含子域）。URL 解析不了也算命中——用不了的东西不留。 */
export function isBlockedDomain(url: string, blockedDomains: readonly string[]): boolean {
  let host: string;
  try {
    host = new URL(url).hostname.toLowerCase().replace(/^www\./, "");
  } catch {
    return true;
  }
  return blockedDomains.some((blocked) => {
    const b = blocked.toLowerCase().replace(/^www\./, "");
    // endsWith("." + b) 而不是 includes(b)：不然 `notzhihu.com` 也会被判中。
    return host === b || host.endsWith(`.${b}`);
  });
}

export interface FreshnessOptions {
  /** 时间基准。必传，见 `ageInDays`。 */
  now: Date;
  maxAgeDays: number;
  blockedDomains: readonly string[];
}

/**
 * 从原始 `search_result` 里筛出**能用的新闻条目**：有 link、不在黑名单、
 * 发布日期能解析且落在窗口内。
 *
 * 为什么 `publish_date` 缺失或解析不出来的一律丢掉：
 * 留下一条日期不明的旧报道，可能让去年的一次降准被当成今天这条的"独立印证"，
 * independence 就虚高了——那是这个产品最危险的失败模式。丢掉一条日期缺失的
 * 新报道，代价只是少一个源。**少算是安全的，多算是致命的。**
 * 实测 50 条里就有 4 条完全没有 `publish_date`。
 *
 * 入参声明成 unknown 而不是数组：智谱在没有命中时会把 `search_result` 整个
 * 省掉，取到 undefined 再去 for...of 就是一个 TypeError，而不是「没搜到」。
 */
export function filterUsableItems(
  searchResult: unknown,
  options: FreshnessOptions,
): ZhipuSearchItem[] {
  if (!Array.isArray(searchResult)) return [];

  const out: ZhipuSearchItem[] = [];
  for (const raw of searchResult) {
    const item = raw as ZhipuSearchItem | null;
    const link = item?.link;
    if (typeof link !== "string" || link === "") continue;
    if (isBlockedDomain(link, options.blockedDomains)) continue;

    const published = parsePublishDate(item?.publish_date);
    if (published === null) continue;

    const age = ageInDays(published, options.now);
    if (age > options.maxAgeDays) continue;
    if (age < -FUTURE_SLACK_DAYS) continue;

    out.push(item as ZhipuSearchItem);
  }
  return out;
}

/**
 * 从 `search_result` 里收 URL：去重，保持首次出现顺序。
 *
 * 只管取 link 和去重，**新鲜度和黑名单不在这里**——那是 `filterUsableItems` 的事。
 *
 * 入参同样是 unknown，理由见上。
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
  /** 默认 `search_pro_sogou`——实测唯一会返回 link 的档位，见 `ZhipuSearchEngine`。 */
  engine?: ZhipuSearchEngine;
  /**
   * 最多返回多少条 URL。默认 20：selectCandidates 后面会按发布方收敛到 8，20 条够它挑。
   *
   * 这是**本地截断**，不是发给引擎的 `count`：实测 sogou 无视 `count`
   * （传 5 返回 50，传 10 还是 50），所以截断在过滤之后自己做。
   */
  maxResults?: number;
  /**
   * 多旧算旧，默认 7 天。
   *
   * 这一关只能我们自己把：实测 sogou 同样无视 `search_recency_filter`——
   * 传 `oneWeek`，50 条里 40 条是一周以前的，其中 35 条来自 2025 年 5 月。
   * 一年前的报道对一条刚发生的新闻没有意义，还会混进 ⑤ 的独立源计数，
   * 把一个虚高的 independence 送进选点。
   */
  maxAgeDays?: number;
  /** 覆盖默认黑名单。传空数组就是不过滤域名。见 `DEFAULT_BLOCKED_DOMAINS`。 */
  blockedDomains?: readonly string[];
}

/**
 * 智谱 BigModel 的 Web Search API。**不是模型调用**——它不产生 token，
 * 只按次收费，所以记账走 ledger.recordFlatCost 而不是 record。
 */
export class ZhipuSearchClient {
  private readonly engine: ZhipuSearchEngine;
  private readonly maxResults: number;
  private readonly maxAgeDays: number;
  private readonly blockedDomains: readonly string[];

  constructor(
    private readonly apiKey: string,
    private readonly ledger: TokenLedger,
    config: ZhipuSearchConfig = {},
    private readonly send: Sender = (url, init) => fetchWithTimeout(url, init, 45_000),
  ) {
    this.engine = config.engine ?? DEFAULT_ENGINE;
    this.maxResults = config.maxResults ?? 20;
    this.maxAgeDays = config.maxAgeDays ?? DEFAULT_MAX_AGE_DAYS;
    this.blockedDomains = config.blockedDomains ?? DEFAULT_BLOCKED_DOMAINS;
  }

  /**
   * `now` 是时间基准，只在这一层落地默认值，往下全是显式传递——
   * 过滤逻辑里不许出现 `new Date()`，否则测试会随运行日期飘。
   */
  async findSources(headline: string, now: Date = new Date()): Promise<string[]> {
    const response = await requestWithRetry(
      () =>
        this.send(ZHIPU_SEARCH_URL, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${this.apiKey}`,
            "Content-Type": "application/json",
          },
          // 只传这两个参数。`count` 和 `search_recency_filter` 实测都被
          // sogou 无视（见 ZhipuSearchConfig 上的两段注释），传一个不起作用
          // 的参数只会让人以为它起作用了——条数和新鲜度都在下面自己把关。
          body: JSON.stringify({
            search_query: headline.slice(0, MAX_QUERY_CHARS),
            search_engine: this.engine,
          }),
        }),
      { attempts: 3, backoffMs: 1000 },
    );

    // 先记账再解析：拿到 200 的那一刻这一次就已经被计费了，回包解析不出来
    // 也不退钱。重试掉的 429/5xx 不计费，所以记一次而不是记 attempts 次。
    this.ledger.recordFlatCost("search", `zhipu:${this.engine}`, searchCostCents(this.engine));

    const payload = (await response.json()) as { search_result?: unknown };
    // 顺序是有意的：**先过滤再截断**。反过来的话，前 20 条里若全是百科页和
    // 2025 年 5 月的旧闻（实测就是这个分布），过滤完一条不剩。
    const usable = filterUsableItems(payload.search_result, {
      now,
      maxAgeDays: this.maxAgeDays,
      blockedDomains: this.blockedDomains,
    });
    return collectZhipuResults(usable).slice(0, this.maxResults);
  }
}
