// pipeline/src/net/jina.ts
import { fetchWithTimeout, requestWithRetry } from "./http.js";

export interface Article {
  title: string;
  url: string;
  body: string;
}

const HEADER_KEYS = ["Title:", "URL Source:", "Markdown Content:"] as const;

/**
 * Jina Reader 用三段固定头部包着正文。头部不剥掉，③ 会把导航栏当事实抽。
 */
export function parseJinaResponse(text: string): Article {
  const titleMatch = /^Title:\s*(.*)$/m.exec(text);
  const urlMatch = /^URL Source:\s*(.*)$/m.exec(text);
  const marker = "Markdown Content:";
  const idx = text.indexOf(marker);
  const body = (idx === -1 ? text : text.slice(idx + marker.length)).trim();

  if (body === "") {
    // 空正文喂进 ③ 会抽出零个事实，白烧一轮 token 才发现。
    throw new Error(`Jina Reader 返回的正文为空：${urlMatch?.[1] ?? "(未知 URL)"}`);
  }

  return {
    title: titleMatch?.[1]?.trim() ?? "",
    url: urlMatch?.[1]?.trim() ?? "",
    body,
  };
}

export async function readArticle(url: string, timeoutMs = 45_000): Promise<Article> {
  const response = await requestWithRetry(
    () =>
      fetchWithTimeout(
        `https://r.jina.ai/${url}`,
        { headers: { Accept: "text/plain" } },
        timeoutMs,
      ),
    { attempts: 3, backoffMs: 1000 },
  );
  return parseJinaResponse(await response.text());
}

export { HEADER_KEYS };
