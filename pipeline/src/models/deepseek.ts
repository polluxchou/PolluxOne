// pipeline/src/models/deepseek.ts
import { fetchWithTimeout, requestWithRetry } from "../net/http.js";
import type { TokenLedger, StageName } from "./ledger.js";
import type { Usage } from "./pricing.js";

interface RawUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  completion_tokens_details?: { reasoning_tokens?: number };
}

export function extractUsage(raw: RawUsage | undefined): Required<Usage> {
  return {
    inputTokens: raw?.prompt_tokens ?? 0,
    outputTokens: raw?.completion_tokens ?? 0,
    reasoningTokens: raw?.completion_tokens_details?.reasoning_tokens ?? 0,
  };
}

export type Sender = (url: string, init: RequestInit) => Promise<Response>;

/**
 * DeepSeek 只支持 `json_object`，不支持 `json_schema`（2026-09-18 实测：
 * "This response_format type is unavailable now"）。所以这里拿不到任何
 * 结构保证——保证全部由调用方的校验器提供。见 Task 7、Task 12。
 */
export class DeepSeekClient {
  constructor(
    private readonly config: { apiKey: string; baseUrl: string },
    private readonly ledger: TokenLedger,
    private readonly send: Sender = (url, init) => fetchWithTimeout(url, init, 120_000),
  ) {}

  async json<T>(
    stage: StageName,
    model: string,
    prompt: string,
    maxTokens = 8000,
  ): Promise<T> {
    const response = await requestWithRetry(
      () =>
        this.send(`${this.config.baseUrl}/chat/completions`, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${this.config.apiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            model,
            messages: [{ role: "user", content: prompt }],
            response_format: { type: "json_object" },
            max_tokens: maxTokens,
          }),
        }),
      { attempts: 3, backoffMs: 1500 },
    );

    const payload = (await response.json()) as {
      choices?: { message?: { content?: string } }[];
      usage?: RawUsage;
    };

    // 先记账再解析：token 在模型开口的那一刻就花掉了，解析失败不退钱。
    this.ledger.record(stage, model, extractUsage(payload.usage));

    const content = payload.choices?.[0]?.message?.content ?? "";
    try {
      return JSON.parse(content) as T;
    } catch {
      throw new Error(`${model} 没有返回合法 JSON：${content.slice(0, 400)}`);
    }
  }
}
