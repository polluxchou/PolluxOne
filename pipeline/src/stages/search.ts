// pipeline/src/stages/search.ts
import { publisherOf } from "./fetch.js";

/**
 * 一家媒体的多个页面不是多个独立源。在抓取之前就按发布方收敛，
 * 既省抓取成本，也避免把同源页面送进 ⑤ 去搅浑 independence。
 */
export function selectCandidates(
  urls: string[],
  originalUrl: string,
  limit: number,
): string[] {
  let originalPublisher: string | null = null;
  try {
    originalPublisher = publisherOf(originalUrl);
  } catch {
    originalPublisher = null;
  }

  const takenPublishers = new Set<string>();
  if (originalPublisher) takenPublishers.add(originalPublisher);

  const out: string[] = [];
  for (const url of urls) {
    if (out.length >= limit) break;
    if (url === originalUrl) continue;

    let publisher: string;
    try {
      publisher = publisherOf(url);
    } catch {
      continue; // 一个坏 URL 不该让整个检索阶段失败
    }

    if (takenPublishers.has(publisher)) continue;
    takenPublishers.add(publisher);
    out.push(url);
  }

  return out;
}
