// pipeline/src/models/search.ts
import Anthropic from "@anthropic-ai/sdk";
import type { TokenLedger } from "./ledger.js";

const SEARCH_MODEL = "claude-sonnet-5";

/**
 * web_search 的错误**不抛异常**：HTTP 200，但 `content` 从结果数组变成一个
 * 错误对象（例如 `{error_code:"max_uses_exceeded"}`）。
 * 所以分支判断必须靠 Array.isArray，不能靠 try/catch。
 */
export function collectSearchResults(blocks: Anthropic.ContentBlock[]): string[] {
  const seen = new Set<string>();
  const urls: string[] = [];

  for (const block of blocks) {
    if (block.type !== "web_search_tool_result") continue;
    const content = (block as { content: unknown }).content;
    if (!Array.isArray(content)) continue; // 这就是错误对象那一支

    for (const item of content) {
      const url = (item as { url?: string })?.url;
      if (typeof url !== "string" || url === "") continue;
      if (seen.has(url)) continue;
      seen.add(url);
      urls.push(url);
    }
  }

  return urls;
}

export class SearchClient {
  private readonly client: Anthropic;

  constructor(
    apiKey: string,
    private readonly ledger: TokenLedger,
  ) {
    this.client = new Anthropic({ apiKey });
  }

  /** 让 sonnet 边搜边判断覆盖缺口——这是 Pro 版相对基础版最大的能力差。 */
  async findSources(headline: string, maxUses = 6): Promise<string[]> {
    const response = await this.client.messages.create({
      model: SEARCH_MODEL,
      max_tokens: 16000,
      thinking: { type: "adaptive" },
      tools: [{ type: "web_search_20260209", name: "web_search", max_uses: maxUses }],
      messages: [
        {
          role: "user",
          content: [
            `围绕这条新闻找**互相独立**的报道：${headline}`,
            "",
            "要求：",
            "- 优先找不同媒体集团的原创报道，不要找同一篇稿的转载",
            "- 覆盖不同角度：当事方、监管方、行业影响、反方意见",
            "- 每搜一轮后判断还缺哪个角度，再搜下一轮",
          ].join("\n"),
        },
      ],
    });

    this.ledger.record("search", SEARCH_MODEL, {
      inputTokens: response.usage.input_tokens,
      outputTokens: response.usage.output_tokens,
    });

    return collectSearchResults(response.content);
  }
}
