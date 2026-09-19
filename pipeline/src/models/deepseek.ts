// pipeline/src/models/deepseek.ts
import { fetchWithTimeout, requestWithRetry } from "../net/http.js";
import type { TokenLedger, StageName } from "./ledger.js";
import { splitInputTokens, type Usage } from "./pricing.js";

interface RawUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  completion_tokens_details?: { reasoning_tokens?: number };
  /** DeepSeek 把输入 token 再拆成命中／未命中两栏，两者之和等于 prompt_tokens。 */
  prompt_cache_hit_tokens?: number;
  prompt_cache_miss_tokens?: number;
}

/**
 * `prompt_tokens` 仍然是输入总数；命中／未命中是它的拆分。
 *
 * 拆分不可信（字段缺失、为负、或两者之和对不上总数）时由 `splitInputTokens`
 * 统一**按全部未命中**兜底——未命中贵 50 倍，偏贵是安全的方向。规则只写在
 * pricing.ts 一处，这里和 `costOf` 共用，不许各写一份。
 */
export function extractUsage(raw: RawUsage | undefined): Required<Usage> {
  const inputTokens = raw?.prompt_tokens ?? 0;
  const split = splitInputTokens({
    inputTokens,
    cacheHitTokens: raw?.prompt_cache_hit_tokens,
    cacheMissTokens: raw?.prompt_cache_miss_tokens,
  });

  return {
    inputTokens,
    outputTokens: raw?.completion_tokens ?? 0,
    reasoningTokens: raw?.completion_tokens_details?.reasoning_tokens ?? 0,
    cacheHitTokens: split.cacheHit,
    cacheMissTokens: split.cacheMiss,
  };
}

export type Sender = (url: string, init: RequestInit) => Promise<Response>;

/**
 * 一次调用允许生成多少 token 的默认上限。
 *
 * DeepSeek 的 `max_tokens` 管的是**推理 + 正文的总和**，不是正文长度。flash
 * 是推理模型：顶满时 `reasoning_tokens` 可以独吞全部预算，`content` 只剩空
 * 字符串，而 HTTP 仍是 200、token 照付。
 *
 * 原来的 8000 就是这么被顶满的——⑤ 一次 152 对的交叉验证，光推理就正好
 * 8000。32000 的依据：按观测到的推理峰值 8000 留四倍余量，再加上最长的一次
 * 正文（⑦ 成稿几百字，连同 JSON 结构不到 2000 token）。
 *
 * 给宽是安全的方向：`max_tokens` 是**上限而不是预约**，没生成的部分一分钱
 * 都不收；给窄的代价却是整整一次调用全白付，而且还看不出是为什么。
 */
export const DEFAULT_MAX_TOKENS = 32_000;

/**
 * 输出被 `max_tokens` 截断。
 *
 * 单独一个类型，是为了和「模型输出不合规」分开：后者（JSON 形状不对、fact
 * 句没挂 claim）重跑一次可能就对了，值得重试；而截断是同样的请求配同样的
 * 上限，重跑**必然**同样截断，且每一次都真付钱。调用方用 `isTruncated`
 * 判断，不要去匹配错误文案。
 */
export class TruncatedOutputError extends Error {
  readonly name = "TruncatedOutputError";

  constructor(
    readonly model: string,
    readonly maxTokens: number,
    readonly completionTokens: number,
    readonly reasoningTokens: number,
  ) {
    super(
      `${model} 的输出被 max_tokens 截断：上限 ${maxTokens}，` +
        `实际生成 completion_tokens=${completionTokens}（其中 reasoning_tokens=${reasoningTokens}）。` +
        "max_tokens 管的是推理+正文的总和，推理顶满时正文会是空的。" +
        "重试同样会截断——要么调高上限，要么缩小这一步的输入。",
    );
  }
}

/** 是不是被截断。重试之前必须问这一句：截断重试只是把同一笔钱再付一遍。 */
export function isTruncated(error: unknown): error is TruncatedOutputError {
  return error instanceof TruncatedOutputError;
}

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
    maxTokens = DEFAULT_MAX_TOKENS,
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
      choices?: { message?: { content?: string }; finish_reason?: string }[];
      usage?: RawUsage;
    };

    // 先记账再解析：token 在模型开口的那一刻就花掉了，解析失败不退钱。
    const usage = extractUsage(payload.usage);
    this.ledger.record(stage, model, usage);

    // 截断的判断排在解析之前：被截断的 content 几乎必然不是合法 JSON，
    // 先解析的话真正的原因会被「没有返回合法 JSON：」盖掉——那条错误后面
    // 跟着的那个空字符串，就是实跑里白烧 24000 token 才找到原因的直接理由。
    //
    // 这里没有重试的余地：HTTP 是 200，`classifyStatus` 判 ok 本身没错；
    // 要挡的是调用方（⑦ 的「拒收+重跑」），所以这个错误必须是可识别的类型。
    if (payload.choices?.[0]?.finish_reason === "length") {
      throw new TruncatedOutputError(model, maxTokens, usage.outputTokens, usage.reasoningTokens);
    }

    const content = payload.choices?.[0]?.message?.content ?? "";
    try {
      return JSON.parse(content) as T;
    } catch {
      throw new Error(`${model} 没有返回合法 JSON：${content.slice(0, 400)}`);
    }
  }
}
