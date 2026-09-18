// pipeline/src/net/http.ts
export type StatusClass = "ok" | "retry" | "fatal";

/**
 * 重试 400 是烧钱，不重试 429 是白扔一次完整调研。所以这两类在类型上分开，
 * 调用方没有"看情况"的余地。
 */
export function classifyStatus(status: number): StatusClass {
  if (status >= 200 && status < 300) return "ok";
  if (status === 429) return "retry";
  if (status >= 500) return "retry";
  return "fatal";
}

export interface RetryOptions {
  attempts: number;
  backoffMs: number;
}

export async function requestWithRetry(
  send: () => Promise<Response>,
  options: RetryOptions,
): Promise<Response> {
  let lastError: Error | null = null;

  for (let attempt = 0; attempt < options.attempts; attempt++) {
    let response: Response;
    try {
      response = await send();
    } catch (cause) {
      // 连接层失败没有状态码，一律当可重试——它通常是瞬时的。
      lastError = new Error(`网络请求失败：${(cause as Error).message}`, { cause });
      await sleep(options.backoffMs * 2 ** attempt);
      continue;
    }

    const verdict = classifyStatus(response.status);
    if (verdict === "ok") return response;

    if (verdict === "fatal") {
      const body = await response.text().catch(() => "");
      throw new Error(`请求被拒（${response.status}），重试也不会变：${body.slice(0, 300)}`);
    }

    lastError = new Error(`请求暂时失败（${response.status}）`);
    await sleep(options.backoffMs * 2 ** attempt);
  }

  throw lastError ?? new Error("请求失败且没有记录到原因");
}

function sleep(ms: number): Promise<void> {
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** 带超时的 fetch。没有超时的网络调用会让阶段卡死在 <60s 的预算之外。 */
export async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}
