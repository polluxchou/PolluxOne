// pipeline/src/stages/fetch.ts
import type { Article } from "../net/jina.js";
import type { Source, SourceId } from "../domain/types.js";

/** 双段后缀：切早了会把 bbc.co.uk 切成 co.uk，把两家不同媒体判成同一家。 */
const TWO_PART_SUFFIXES = new Set([
  "com.cn", "net.cn", "org.cn", "gov.cn", "co.uk", "co.jp", "com.hk", "com.tw",
]);

export function publisherOf(url: string): string {
  const host = new URL(url).hostname.toLowerCase().replace(/^www\./, "");
  const parts = host.split(".");
  if (parts.length <= 2) return host;
  const lastTwo = parts.slice(-2).join(".");
  if (TWO_PART_SUFFIXES.has(lastTwo)) return parts.slice(-3).join(".");
  return lastTwo;
}

/**
 * 正文里的转载声明。认出来的每一条都会让 independence 少算一个——
 * 这正是我们要的方向：少算是安全的，多算是致命的。
 */
const CREDIT_PATTERNS: RegExp[] = [
  /本文转自\s*([^\s，。,.]{2,12})/,
  /来源[:：]\s*([^\s，。,.]{2,12})/,
  /据\s*([^\s，。,.]{2,8})\s*报道/,
  /（?综合\s*([^\s，。,.]{2,12})\s*）?/,
];

export function creditedToOf(body: string): string | null {
  for (const pattern of CREDIT_PATTERNS) {
    const m = pattern.exec(body);
    if (m?.[1]) return m[1];
  }
  return null;
}

export function toSource(id: SourceId, article: Article, fetchedAt: string): Source {
  return {
    id,
    url: article.url,
    publisher: publisherOf(article.url),
    // Jina 不稳定地返回发布时间，抓取时间是我们唯一敢保证的值。
    publishedAt: fetchedAt,
    body: article.body,
    creditedTo: creditedToOf(article.body),
  };
}
