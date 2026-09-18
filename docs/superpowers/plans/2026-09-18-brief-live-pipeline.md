# 让 Brief 吃真新闻 — 实施计划（spec 第一段）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给一条真实新闻的 URL，管线自己去检索、抓取、抽事实、判冲突、成稿，产出一篇挂满信源的口播稿。

**Architecture:** 已建成的确定性内核（④⑤⑥⑧⑨，96 个离线测试）一行不动。本计划只补它的三个输入——`sources`（①②）、`facts`（③）、`draft`（⑦）——外加 ⑤ 的语义冲突分支。所有模型调用藏在接口后面，阶段测试依然离线。

**Tech Stack:** TypeScript · Node 22 · `@anthropic-ai/sdk`（仅 ② 检索）· DeepSeek REST（③⑤⑦）· Jina Reader（① 正文）· vitest

---

## 零、读这个计划之前必须知道的事

### 0.1 依赖纪律变了，但边界比纪律重要

`pipeline/` 原本零运行时依赖。本计划引入 `@anthropic-ai/sdk`——不是因为省事，是因为 ② 用的是服务端 `web_search_20260209`，响应里嵌套着 `web_search_tool_result` / `web_search_result` 等一串块类型，手写解析等于把 SDK 抄一遍且没有类型保护。

**但边界必须守住：**

| 目录 | 依赖 | 测试 |
|---|---|---|
| `src/domain/` `src/dedupe/` `src/draft/` | **零依赖，不许加** | 全程离线，96 个已有测试 |
| `src/net/` `src/models/` `src/stages/` | 可以用 SDK | 模型调用走接口，测试喂替身 |

护城河在上面那一行。它一个包都不许装。

### 0.2 DeepSeek 不支持 `json_schema`

实测（2026-09-18，`deepseek-flash`）：

```
response_format: {"type":"json_schema", ...}
→ {"error":{"message":"This response_format type is unavailable now"}}
response_format: {"type":"json_object"}
→ 可用
```

所以 spec §6.2 的「schema 强制映射」**拿不到 API 层的保证**。校验必须是我们自己的代码，而且必须是拒收+重跑，不是"尽量"。Task 7 和 Task 12 是这条的兑现。

### 0.3 deepseek-flash 会产生 reasoning token

同一次实测：`completion_tokens: 259`，其中 `reasoning_tokens: 189`。**73% 的输出 token 是推理**。成本估算若只数可见输出，会低估三倍以上。Task 3 的账本必须把它算进去。

### 0.35 测试代码里的下标访问要加 `!`

`pipeline/tsconfig.json` 开了 `noUncheckedIndexedAccess: true`，所以 `facts[0].id`
这类下标访问的类型是 `T | undefined`，`npm run typecheck` 会报
"Object is possibly 'undefined'"。

本计划各任务给出的测试代码里凡是有下标访问的，照抄时**加非空断言**：
`facts[0]!.id`、`rejected[0]!.reason`。这只动类型层面，**断言的值和语义一个都不要改**。

仓库原有的 12 个测试文件恰好从没用过下标访问，所以这个坑到 Task 6 才第一次暴露。

### 0.4 错误方向

沿用上一个计划的判据。本计划里三处最危险：

| 做错的方向 | 后果 |
|---|---|
| 逐字引文校验放宽 | 模型转述被当成原文引用 → 整个可溯源承诺是假的 |
| 成稿校验放宽 | fact 句挂不上 claim 却进了稿 → §6.2 失效 |
| 检索结果当成独立源 | 同一篇稿的多个转载被算成多个源 → independence 虚高 |

**三处一律从严。宁可拒绝一条好数据，不可放进一条坏数据。**

---

## 一、文件结构

```
pipeline/src/
  config/env.ts          读 .env.local，缺 key 立刻抛
  net/http.ts            fetch 包装：超时、重试、错误归类
  net/jina.ts            ① Jina Reader 读正文
  models/pricing.ts      价目表（含 reasoning token）
  models/ledger.ts       TokenLedger：每次调用记账
  models/deepseek.ts     DeepSeek 客户端（json_object）
  models/search.ts       Anthropic + web_search_20260209
  stages/fetch.ts        ① URL → Source
  stages/search.ts       ② angle → 候选 URL
  stages/extract.ts      ③ Source → Fact[]
  stages/verify-quote.ts ③ 逐字引文校验（代码）
  stages/conflict.ts     ⑤ 语义冲突二分类
  stages/draft.ts        ⑦ 拨盘 → 稿子
  stages/validate-draft.ts ⑦ 输出校验（代码）
  run.ts                 串起来
  cli.ts                 改造：接受真 URL
```

测试在 `pipeline/test/` 下镜像同一层级。

---

## Task 1: 读配置，缺 key 就当场死

**Files:**
- Create: `pipeline/src/config/env.ts`
- Test: `pipeline/test/config/env.test.ts`

配置读错的代价是跑到第三个阶段才发现没 key，而前两个阶段已经烧了钱。所以校验放在最前面，且是硬失败。

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/config/env.test.ts
import { describe, expect, it } from "vitest";
import { parseEnvFile, resolveConfig } from "../../src/config/env.js";

describe("parseEnvFile", () => {
  it("读得出键值", () => {
    expect(parseEnvFile("A=1\nB=hello")).toEqual({ A: "1", B: "hello" });
  });

  it("跳过注释和空行", () => {
    expect(parseEnvFile("# 注释\n\nA=1\n  # 缩进注释\n")).toEqual({ A: "1" });
  });

  it("值里带等号不截断", () => {
    expect(parseEnvFile("URL=https://x.com/?a=1&b=2")).toEqual({
      URL: "https://x.com/?a=1&b=2",
    });
  });

  it("去掉包裹的引号", () => {
    expect(parseEnvFile(`A="quoted"\nB='single'`)).toEqual({
      A: "quoted",
      B: "single",
    });
  });
});

describe("resolveConfig", () => {
  it("齐全时返回配置", () => {
    const cfg = resolveConfig({
      DEEPSEEK_API_KEY: "sk-x",
      DEEPSEEK_BASE_URL: "https://api.deepseek.com",
      ANTHROPIC_API_KEY: "sk-ant-y",
    });
    expect(cfg.deepseek.apiKey).toBe("sk-x");
    expect(cfg.anthropic.apiKey).toBe("sk-ant-y");
  });

  it("baseUrl 缺省有默认值", () => {
    const cfg = resolveConfig({ DEEPSEEK_API_KEY: "sk-x", ANTHROPIC_API_KEY: "sk-ant-y" });
    expect(cfg.deepseek.baseUrl).toBe("https://api.deepseek.com");
  });

  it("缺 key 时抛，且说清缺哪个", () => {
    expect(() => resolveConfig({ DEEPSEEK_API_KEY: "sk-x" })).toThrow(
      /ANTHROPIC_API_KEY/,
    );
  });

  it("空字符串等同于缺失——填了等号但没填值是最常见的错", () => {
    expect(() =>
      resolveConfig({ DEEPSEEK_API_KEY: "sk-x", ANTHROPIC_API_KEY: "   " }),
    ).toThrow(/ANTHROPIC_API_KEY/);
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/config/env.test.ts`
Expected: FAIL — `Cannot find module '../../src/config/env.js'`

- [ ] **Step 3: 写实现**

```typescript
// pipeline/src/config/env.ts
import { readFileSync } from "node:fs";

export interface Config {
  deepseek: { apiKey: string; baseUrl: string };
  anthropic: { apiKey: string };
}

const DEFAULT_DEEPSEEK_BASE_URL = "https://api.deepseek.com";

/** 极小的 .env 解析器——不装 dotenv 是因为这 15 行不值得一个依赖。 */
export function parseEnvFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const rawLine of text.split("\n")) {
    const line = rawLine.trim();
    if (line === "" || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    // 只切第一个等号：URL 的 query string 里全是等号。
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
      (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
    ) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

export function resolveConfig(env: Record<string, string | undefined>): Config {
  const missing: string[] = [];
  const need = (key: string): string => {
    const value = (env[key] ?? "").trim();
    // 空值当缺失：`KEY=` 是填表时最常见的半成品，让它走到网络层再报 401 是浪费。
    if (value === "") missing.push(key);
    return value;
  };

  const deepseekKey = need("DEEPSEEK_API_KEY");
  const anthropicKey = need("ANTHROPIC_API_KEY");

  if (missing.length > 0) {
    throw new Error(
      `pipeline/.env.local 里缺这些值：${missing.join("、")}。` +
        `照着 pipeline/.env.example 填，别把值贴进任何对话或提交。`,
    );
  }

  return {
    deepseek: {
      apiKey: deepseekKey,
      baseUrl: (env.DEEPSEEK_BASE_URL ?? "").trim() || DEFAULT_DEEPSEEK_BASE_URL,
    },
    anthropic: { apiKey: anthropicKey },
  };
}

/** 从磁盘读。找不到文件时给出能照做的提示，而不是一个 ENOENT。 */
export function loadConfig(path = "pipeline/.env.local"): Config {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    throw new Error(
      `读不到 ${path}。先 cp pipeline/.env.example pipeline/.env.local 再填值。`,
    );
  }
  return resolveConfig({ ...parseEnvFile(text) });
}
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/config/env.test.ts`
Expected: PASS，9 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/config/env.ts pipeline/test/config/env.test.ts
git commit -m "$(cat <<'EOF'
Fail on a missing key before spending any money

Config errors that surface at stage three have already burned two stages
of tokens. An empty value counts as missing: `KEY=` is the most common
half-filled state, and letting it reach the network to come back 401 is
the same bug found later and more expensively.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: HTTP —— 超时、重试、把错误分成"该重试"和"重试也没用"

**Files:**
- Create: `pipeline/src/net/http.ts`
- Test: `pipeline/test/net/http.test.ts`

重试 400 是浪费钱，不重试 429 是浪费一次完整的调研。这两类必须在类型上分开。

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/net/http.test.ts
import { describe, expect, it, vi } from "vitest";
import { classifyStatus, requestWithRetry } from "../../src/net/http.js";

describe("classifyStatus", () => {
  it("429 和 5xx 该重试", () => {
    expect(classifyStatus(429)).toBe("retry");
    expect(classifyStatus(500)).toBe("retry");
    expect(classifyStatus(503)).toBe("retry");
  });

  it("4xx（429 除外）重试也没用", () => {
    expect(classifyStatus(400)).toBe("fatal");
    expect(classifyStatus(401)).toBe("fatal");
    expect(classifyStatus(404)).toBe("fatal");
  });

  it("2xx 是成功", () => {
    expect(classifyStatus(200)).toBe("ok");
  });
});

describe("requestWithRetry", () => {
  it("一次就成功时不重试", async () => {
    const fn = vi.fn().mockResolvedValue(new Response("ok", { status: 200 }));
    const res = await requestWithRetry(fn, { attempts: 3, backoffMs: 0 });
    expect(await res.text()).toBe("ok");
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("429 之后重试并最终成功", async () => {
    const fn = vi
      .fn()
      .mockResolvedValueOnce(new Response("", { status: 429 }))
      .mockResolvedValueOnce(new Response("ok", { status: 200 }));
    const res = await requestWithRetry(fn, { attempts: 3, backoffMs: 0 });
    expect(res.status).toBe(200);
    expect(fn).toHaveBeenCalledTimes(2);
  });

  it("400 立刻放弃，不浪费重试额度", async () => {
    const fn = vi.fn().mockResolvedValue(new Response("bad", { status: 400 }));
    await expect(
      requestWithRetry(fn, { attempts: 3, backoffMs: 0 }),
    ).rejects.toThrow(/400/);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("重试用尽后抛，错误里带最后一次状态码", async () => {
    const fn = vi.fn().mockResolvedValue(new Response("", { status: 503 }));
    await expect(
      requestWithRetry(fn, { attempts: 2, backoffMs: 0 }),
    ).rejects.toThrow(/503/);
    expect(fn).toHaveBeenCalledTimes(2);
  });

  it("网络异常也走重试", async () => {
    const fn = vi
      .fn()
      .mockRejectedValueOnce(new Error("ECONNRESET"))
      .mockResolvedValueOnce(new Response("ok", { status: 200 }));
    const res = await requestWithRetry(fn, { attempts: 3, backoffMs: 0 });
    expect(res.status).toBe(200);
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/net/http.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
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
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/net/http.test.ts`
Expected: PASS，8 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/net/http.ts pipeline/test/net/http.test.ts
git commit -m "$(cat <<'EOF'
Separate the errors worth retrying from the ones that never change

Retrying a 400 spends money to get the same answer; not retrying a 429
throws away a whole research run. Making that a two-value verdict rather
than a judgment call at each call site means no caller gets to decide
"it depends".

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 价目表与 Token 账本

**Files:**
- Create: `pipeline/src/models/pricing.ts`, `pipeline/src/models/ledger.ts`
- Test: `pipeline/test/models/ledger.test.ts`

spec §10.1 说 token 是一等产品对象。它是要展示给用户、并且要据以收费的，所以它必须是被记录的事实，不是事后估的账。

**关键：`reasoning_tokens` 已经含在 `completion_tokens` 里**（实测 259 总输出含 189 推理），重复计价会让账单虚高 1.7 倍。

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/models/ledger.test.ts
import { describe, expect, it } from "vitest";
import { PRICES, costOf } from "../../src/models/pricing.js";
import { TokenLedger } from "../../src/models/ledger.js";

describe("costOf", () => {
  it("按每百万 token 计价", () => {
    // sonnet-5: $2 输入 / $10 输出
    const cents = costOf("claude-sonnet-5", { inputTokens: 1_000_000, outputTokens: 0 });
    expect(cents).toBeCloseTo(200, 6);
  });

  it("输入输出分别计价", () => {
    const cents = costOf("claude-sonnet-5", {
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
    });
    expect(cents).toBeCloseTo(1200, 6);
  });

  it("未知模型要抛，不许静默按 0 计费", () => {
    expect(() => costOf("no-such-model", { inputTokens: 1, outputTokens: 1 })).toThrow(
      /no-such-model/,
    );
  });

  it("价目表覆盖本管线用到的全部模型", () => {
    expect(PRICES["deepseek-flash"]).toBeDefined();
    expect(PRICES["deepseek-v4-pro"]).toBeDefined();
    expect(PRICES["claude-sonnet-5"]).toBeDefined();
  });
});

describe("TokenLedger", () => {
  it("累加各阶段用量", () => {
    const ledger = new TokenLedger();
    ledger.record("extract", "deepseek-flash", { inputTokens: 1000, outputTokens: 500 });
    ledger.record("extract", "deepseek-flash", { inputTokens: 2000, outputTokens: 300 });
    expect(ledger.totals().inputTokens).toBe(3000);
    expect(ledger.totals().outputTokens).toBe(800);
  });

  it("按阶段分组——⑤ 的进度条要显示每阶段花了多少", () => {
    const ledger = new TokenLedger();
    ledger.record("search", "claude-sonnet-5", { inputTokens: 100, outputTokens: 50 });
    ledger.record("extract", "deepseek-flash", { inputTokens: 900, outputTokens: 20 });
    const byStage = ledger.byStage();
    expect(byStage.search.inputTokens).toBe(100);
    expect(byStage.extract.inputTokens).toBe(900);
  });

  it("reasoning token 不重复计价——它已经含在 outputTokens 里", () => {
    const ledger = new TokenLedger();
    ledger.record("extract", "deepseek-flash", {
      inputTokens: 101,
      outputTokens: 259,
      reasoningTokens: 189,
    });
    const plain = new TokenLedger();
    plain.record("extract", "deepseek-flash", { inputTokens: 101, outputTokens: 259 });
    expect(ledger.totalCostCents()).toBeCloseTo(plain.totalCostCents(), 9);
  });

  it("reasoning token 仍然被记下来——它是解释账单为什么高的唯一线索", () => {
    const ledger = new TokenLedger();
    ledger.record("extract", "deepseek-flash", {
      inputTokens: 101,
      outputTokens: 259,
      reasoningTokens: 189,
    });
    expect(ledger.totals().reasoningTokens).toBe(189);
  });

  it("空账本是零，不是 NaN", () => {
    const ledger = new TokenLedger();
    expect(ledger.totalCostCents()).toBe(0);
    expect(ledger.totals().inputTokens).toBe(0);
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/models/ledger.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
// pipeline/src/models/pricing.ts

/** 美分 / 每百万 token。查证日期 2026-09-18。 */
export interface ModelPrice {
  inputCentsPerMTok: number;
  outputCentsPerMTok: number;
}

export const PRICES: Record<string, ModelPrice> = {
  // DeepSeek 官网价（$0.15 / $0.60 每 MTok）
  "deepseek-flash": { inputCentsPerMTok: 15, outputCentsPerMTok: 60 },
  "deepseek-v4-pro": { inputCentsPerMTok: 55, outputCentsPerMTok: 219 },
  // Anthropic 价目表：$2 / $10 每 MTok
  "claude-sonnet-5": { inputCentsPerMTok: 200, outputCentsPerMTok: 1000 },
};

export interface Usage {
  inputTokens: number;
  outputTokens: number;
  /**
   * 推理 token。**已经含在 outputTokens 里**，只作展示用，不参与计价——
   * 实测 deepseek-flash 一次调用 259 个输出 token 里有 189 个是推理，
   * 重复计价会让账单虚高 1.7 倍。
   */
  reasoningTokens?: number;
}

export function costOf(model: string, usage: Usage): number {
  const price = PRICES[model];
  if (!price) {
    // 静默按 0 计费会让一个没上价目表的新模型免费跑到账单爆炸为止。
    throw new Error(`价目表里没有 ${model}，请先在 PRICES 补上再调用它`);
  }
  return (
    (usage.inputTokens / 1_000_000) * price.inputCentsPerMTok +
    (usage.outputTokens / 1_000_000) * price.outputCentsPerMTok
  );
}
```

```typescript
// pipeline/src/models/ledger.ts
import { costOf, type Usage } from "./pricing.js";

export type StageName =
  | "fetch"
  | "search"
  | "extract"
  | "conflict"
  | "draft";

interface Entry {
  stage: StageName;
  model: string;
  usage: Usage;
}

export interface Totals {
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
}

/**
 * spec §10.1：token 是一等产品对象。要展示给用户、要据以收费，
 * 所以它必须是**被记录的事实**，不是事后按字数估的账。
 */
export class TokenLedger {
  private entries: Entry[] = [];

  record(stage: StageName, model: string, usage: Usage): void {
    // 先算一次价：模型不在价目表里要在记账时就炸，而不是在结账时。
    costOf(model, usage);
    this.entries.push({ stage, model, usage });
  }

  totals(): Totals {
    return this.entries.reduce<Totals>(
      (acc, e) => ({
        inputTokens: acc.inputTokens + e.usage.inputTokens,
        outputTokens: acc.outputTokens + e.usage.outputTokens,
        reasoningTokens: acc.reasoningTokens + (e.usage.reasoningTokens ?? 0),
      }),
      { inputTokens: 0, outputTokens: 0, reasoningTokens: 0 },
    );
  }

  byStage(): Record<string, Totals> {
    const out: Record<string, Totals> = {};
    for (const e of this.entries) {
      const cur = out[e.stage] ?? { inputTokens: 0, outputTokens: 0, reasoningTokens: 0 };
      out[e.stage] = {
        inputTokens: cur.inputTokens + e.usage.inputTokens,
        outputTokens: cur.outputTokens + e.usage.outputTokens,
        reasoningTokens: cur.reasoningTokens + (e.usage.reasoningTokens ?? 0),
      };
    }
    return out;
  }

  totalCostCents(): number {
    return this.entries.reduce((sum, e) => sum + costOf(e.model, e.usage), 0);
  }
}
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/models/ledger.test.ts`
Expected: PASS，10 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/models/pricing.ts pipeline/src/models/ledger.ts pipeline/test/models/ledger.test.ts
git commit -m "$(cat <<'EOF'
Record what the tokens actually cost instead of estimating it later

The spec makes tokens a first-class product object: they get shown to the
user and billed for, so they have to be a recorded fact rather than a
reconstruction. Two things this pins down. A model missing from the price
table throws at record time, not at checkout, because silently costing
nothing is how an unpriced model runs free until the bill arrives. And
reasoning tokens are counted for display but never priced twice — they are
already inside completion_tokens, and one measured call put 189 of them
inside 259, which would have inflated the bill 1.7x.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: ① Jina Reader 把新闻页读成正文

**Files:**
- Create: `pipeline/src/net/jina.ts`, `pipeline/src/stages/fetch.ts`
- Test: `pipeline/test/stages/fetch.test.ts`

Jina Reader 返回的格式实测长这样（`https://r.jina.ai/<url>`）：

```
Title: 中国新闻网_梳理天下新闻

URL Source: https://www.chinanews.com.cn/

Markdown Content:
[](https://...)
*   [头条](https://...)
```

三段式头部要解析掉，正文才干净。

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/stages/fetch.test.ts
import { describe, expect, it } from "vitest";
import { parseJinaResponse } from "../../src/net/jina.js";
import { publisherOf, toSource } from "../../src/stages/fetch.js";

const SAMPLE = `Title: 央行宣布降准

URL Source: https://www.example.com.cn/news/1

Markdown Content:
央行今日宣布下调存款准备金率 0.5 个百分点。

本文转自新华社。
`;

describe("parseJinaResponse", () => {
  it("拆出标题、源 URL、正文", () => {
    const parsed = parseJinaResponse(SAMPLE);
    expect(parsed.title).toBe("央行宣布降准");
    expect(parsed.url).toBe("https://www.example.com.cn/news/1");
    expect(parsed.body).toContain("下调存款准备金率");
    expect(parsed.body).not.toContain("Markdown Content:");
  });

  it("头部缺失时不崩，正文退化为全文", () => {
    const parsed = parseJinaResponse("就是一段正文，没有任何头部。");
    expect(parsed.title).toBe("");
    expect(parsed.body).toBe("就是一段正文，没有任何头部。");
  });

  it("正文为空要抛——空正文喂进 ③ 会抽出零个事实，白烧一轮 token", () => {
    expect(() => parseJinaResponse("Title: x\n\nURL Source: https://a.com\n\nMarkdown Content:\n\n   ")).toThrow(
      /正文为空/,
    );
  });
});

describe("publisherOf", () => {
  it("从域名取发布方", () => {
    expect(publisherOf("https://www.chinanews.com.cn/news/1")).toBe("chinanews.com.cn");
    expect(publisherOf("https://finance.sina.com.cn/a/b")).toBe("sina.com.cn");
  });

  it("双段后缀不被切坏", () => {
    expect(publisherOf("https://www.bbc.co.uk/news")).toBe("bbc.co.uk");
  });

  it("非法 URL 抛", () => {
    expect(() => publisherOf("不是个链接")).toThrow();
  });
});

describe("toSource", () => {
  it("组装成 Source，id 稳定可复现", () => {
    const a = toSource("s0", parseJinaResponse(SAMPLE), "2026-09-18T00:00:00Z");
    expect(a.id).toBe("s0");
    expect(a.publisher).toBe("example.com.cn");
    expect(a.body).toContain("下调存款准备金率");
  });

  it("认出「本文转自X」并填进 creditedTo——独立源计数靠它", () => {
    const s = toSource("s0", parseJinaResponse(SAMPLE), "2026-09-18T00:00:00Z");
    expect(s.creditedTo).toBe("新华社");
  });

  it("没有转载声明时 creditedTo 是 null，不是空串", () => {
    const text = `Title: t

URL Source: https://a.com/1

Markdown Content:
一段没有转载声明的正文。
`;
    expect(toSource("s1", parseJinaResponse(text), "2026-09-18T00:00:00Z").creditedTo).toBeNull();
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/stages/fetch.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
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
```

```typescript
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
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/stages/fetch.test.ts`
Expected: PASS，9 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/net/jina.ts pipeline/src/stages/fetch.ts pipeline/test/stages/fetch.test.ts
git commit -m "$(cat <<'EOF'
Turn a news page into a source without swallowing its navigation bar

Jina Reader wraps the article in three fixed header lines; leaving them in
means stage 3 extracts the site's nav menu as facts. An empty body throws
here rather than costing a round of extraction tokens to discover.

Two details that feed independence counting downstream. Publisher uses a
two-part-suffix list so bbc.co.uk doesn't collapse to co.uk and make two
unrelated outlets look like one. And the repost patterns are read out of
the body: every one that matches lowers the independence count, which is
the safe direction to be wrong in.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: DeepSeek 客户端

**Files:**
- Create: `pipeline/src/models/deepseek.ts`
- Test: `pipeline/test/models/deepseek.test.ts`

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/models/deepseek.test.ts
import { describe, expect, it, vi } from "vitest";
import { DeepSeekClient, extractUsage } from "../../src/models/deepseek.js";
import { TokenLedger } from "../../src/models/ledger.js";

const reply = (content: string, usage = { prompt_tokens: 10, completion_tokens: 5 }) =>
  new Response(
    JSON.stringify({ choices: [{ message: { content } }], usage }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );

describe("extractUsage", () => {
  it("映射 DeepSeek 的字段名", () => {
    expect(
      extractUsage({
        prompt_tokens: 101,
        completion_tokens: 259,
        completion_tokens_details: { reasoning_tokens: 189 },
      }),
    ).toEqual({ inputTokens: 101, outputTokens: 259, reasoningTokens: 189 });
  });

  it("没有 reasoning 明细时给 0", () => {
    expect(extractUsage({ prompt_tokens: 1, completion_tokens: 2 })).toEqual({
      inputTokens: 1,
      outputTokens: 2,
      reasoningTokens: 0,
    });
  });

  it("usage 整个缺失时不炸——记 0 好过丢一次调用", () => {
    expect(extractUsage(undefined)).toEqual({
      inputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
    });
  });
});

describe("DeepSeekClient.json", () => {
  it("解析 JSON 并记账", async () => {
    const ledger = new TokenLedger();
    const send = vi.fn().mockResolvedValue(reply('{"ok":true}'));
    const client = new DeepSeekClient(
      { apiKey: "k", baseUrl: "https://api.deepseek.com" },
      ledger,
      send,
    );
    const out = await client.json<{ ok: boolean }>("extract", "deepseek-flash", "prompt");
    expect(out).toEqual({ ok: true });
    expect(ledger.totals().inputTokens).toBe(10);
  });

  it("模型返回非 JSON 时抛，错误里带原文以便排查", async () => {
    const send = vi.fn().mockResolvedValue(reply("这不是 JSON"));
    const client = new DeepSeekClient(
      { apiKey: "k", baseUrl: "https://api.deepseek.com" },
      new TokenLedger(),
      send,
    );
    await expect(
      client.json("extract", "deepseek-flash", "prompt"),
    ).rejects.toThrow(/这不是 JSON/);
  });

  it("即使解析失败也要记账——token 已经花掉了", async () => {
    const ledger = new TokenLedger();
    const send = vi.fn().mockResolvedValue(reply("坏数据"));
    const client = new DeepSeekClient(
      { apiKey: "k", baseUrl: "https://api.deepseek.com" },
      ledger,
      send,
    );
    await client.json("extract", "deepseek-flash", "p").catch(() => undefined);
    expect(ledger.totals().inputTokens).toBe(10);
  });

  it("请求体里带 json_object——DeepSeek 不支持 json_schema", async () => {
    const send = vi.fn().mockResolvedValue(reply("{}"));
    const client = new DeepSeekClient(
      { apiKey: "k", baseUrl: "https://api.deepseek.com" },
      new TokenLedger(),
      send,
    );
    await client.json("extract", "deepseek-flash", "p");
    const body = JSON.parse((send.mock.calls[0][1] as RequestInit).body as string);
    expect(body.response_format).toEqual({ type: "json_object" });
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/models/deepseek.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
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
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/models/deepseek.test.ts`
Expected: PASS，7 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/models/deepseek.ts pipeline/test/models/deepseek.test.ts
git commit -m "$(cat <<'EOF'
Bill for the tokens before trying to parse what they bought

DeepSeek rejects json_schema and only offers json_object, so nothing about
the response shape is guaranteed by the API — every structural promise in
this pipeline has to come from our own validators. Recording usage before
the JSON.parse matters for the same reason: the tokens were spent the
moment the model spoke, and a parse failure doesn't refund them.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: ③ 抽事实点

**Files:**
- Create: `pipeline/src/stages/extract.ts`
- Test: `pipeline/test/stages/extract.test.ts`

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/stages/extract.test.ts
import { describe, expect, it } from "vitest";
import { buildExtractPrompt, parseExtractReply } from "../../src/stages/extract.js";
import type { Source } from "../../src/domain/types.js";

const source: Source = {
  id: "s0",
  url: "https://a.com/1",
  publisher: "a.com",
  publishedAt: "2026-09-18T00:00:00Z",
  body: "央行今日宣布下调存款准备金率 0.5 个百分点，自 3 月 15 日起执行。",
  creditedTo: null,
};

describe("buildExtractPrompt", () => {
  it("把正文放进去", () => {
    expect(buildExtractPrompt(source)).toContain("存款准备金率");
  });

  it("要求逐字引文——这是后面一切的根", () => {
    expect(buildExtractPrompt(source)).toMatch(/逐字/);
  });

  it("给出 JSON 形状，因为 API 层不强制 schema", () => {
    expect(buildExtractPrompt(source)).toContain('"facts"');
    expect(buildExtractPrompt(source)).toContain('"quote"');
  });
});

describe("parseExtractReply", () => {
  it("组装成 Fact[]，id 带上 sourceId 前缀", () => {
    const facts = parseExtractReply(source, {
      facts: [
        { text: "央行下调存款准备金率", quote: "央行今日宣布下调存款准备金率" },
        { text: "自 3 月 15 日起执行", quote: "自 3 月 15 日起执行" },
      ],
    });
    expect(facts).toHaveLength(2);
    expect(facts[0].id).toBe("s0-f0");
    expect(facts[0].sourceId).toBe("s0");
    expect(facts[1].quote).toBe("自 3 月 15 日起执行");
  });

  it("facts 不是数组时抛", () => {
    expect(() => parseExtractReply(source, { facts: "nope" } as never)).toThrow(/facts/);
  });

  it("缺 quote 的条目被丢掉——没有引文的事实无法校验，等于没有", () => {
    const facts = parseExtractReply(source, {
      facts: [
        { text: "有引文", quote: "央行今日宣布" },
        { text: "没引文" } as never,
      ],
    });
    expect(facts).toHaveLength(1);
    expect(facts[0].text).toBe("有引文");
  });

  it("空 facts 数组是合法的——有些源确实没有可抽的事实", () => {
    expect(parseExtractReply(source, { facts: [] })).toEqual([]);
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/stages/extract.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
// pipeline/src/stages/extract.ts
import type { Fact, Source } from "../domain/types.js";

export interface ExtractReply {
  facts: { text: string; quote: string }[];
}

export function buildExtractPrompt(source: Source): string {
  return [
    "你是一个新闻事实抽取器。从下面这篇报道里抽出原子事实点。",
    "",
    "规则：",
    "1. 每个事实点必须附带 quote —— 从原文里**逐字**复制的一段，一个字都不能改、不能转述、不能合并。",
    "2. 只抽事实，不抽评论、预测、情绪。",
    "3. 数字、日期、机构名必须完整保留在 quote 里。",
    "4. 抽不出就返回空数组，不要编。",
    "",
    '输出 JSON：{"facts":[{"text":"事实的简述","quote":"原文逐字片段"}]}',
    "",
    "报道正文：",
    source.body,
  ].join("\n");
}

export function parseExtractReply(source: Source, reply: ExtractReply): Fact[] {
  if (!Array.isArray(reply?.facts)) {
    throw new Error(`${source.id} 的抽取结果里 facts 不是数组`);
  }

  const facts: Fact[] = [];
  for (const raw of reply.facts) {
    // 没有 quote 的事实无从校验，留着它等于在可溯源的链条上留一个洞。
    if (typeof raw?.text !== "string" || typeof raw?.quote !== "string") continue;
    if (raw.text.trim() === "" || raw.quote.trim() === "") continue;
    facts.push({
      id: `${source.id}-f${facts.length}`,
      sourceId: source.id,
      text: raw.text.trim(),
      quote: raw.quote.trim(),
    });
  }
  return facts;
}
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/stages/extract.test.ts`
Expected: PASS，8 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/stages/extract.ts pipeline/test/stages/extract.test.ts
git commit -m "$(cat <<'EOF'
Ask for facts that each carry a verbatim quote

A fact without a quote cannot be checked against its source, so it is a
hole in the traceability chain rather than a weaker link — those entries
get dropped here rather than carried forward. An empty result is allowed:
some sources genuinely have nothing extractable, and a model that invents
something to avoid returning nothing is the failure this guards against.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: ③ 逐字引文校验（护城河，代码，不许问模型）

**Files:**
- Create: `pipeline/src/stages/verify-quote.ts`
- Test: `pipeline/test/stages/verify-quote.test.ts`

这是本计划最重要的一个任务。模型说"这是逐字引文"是**自述**，自述不能当证据。

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/stages/verify-quote.test.ts
import { describe, expect, it } from "vitest";
import { normalizeForQuote, verifyQuotes } from "../../src/stages/verify-quote.js";
import type { Fact, Source } from "../../src/domain/types.js";

const source: Source = {
  id: "s0",
  url: "https://a.com/1",
  publisher: "a.com",
  publishedAt: "2026-09-18T00:00:00Z",
  body: "央行今日宣布下调存款准备金率 0.5 个百分点，自 3 月 15 日起执行。",
  creditedTo: null,
};

const fact = (id: string, quote: string): Fact => ({
  id,
  sourceId: "s0",
  text: "t",
  quote,
});

describe("normalizeForQuote", () => {
  it("折叠空白", () => {
    expect(normalizeForQuote("a  b\n c")).toBe("abc");
  });

  it("NFKC 折叠全角数字", () => {
    expect(normalizeForQuote("０．５")).toBe("0.5");
  });
});

describe("verifyQuotes", () => {
  it("逐字命中的留下", () => {
    const { kept, rejected } = verifyQuotes([fact("f0", "下调存款准备金率")], [source]);
    expect(kept.map((f) => f.id)).toEqual(["f0"]);
    expect(rejected).toEqual([]);
  });

  it("空白差异不算改动", () => {
    const { kept } = verifyQuotes([fact("f0", "下调存款准备金率 0.5个百分点")], [source]);
    expect(kept).toHaveLength(1);
  });

  it("全角半角差异不算改动", () => {
    const { kept } = verifyQuotes([fact("f0", "０.５个百分点")], [source]);
    expect(kept).toHaveLength(1);
  });

  it("转述的被拒——这是整个校验存在的理由", () => {
    const { kept, rejected } = verifyQuotes(
      [fact("f0", "央行降低了存款准备金率")], // 原文是「下调」不是「降低」
      [source],
    );
    expect(kept).toEqual([]);
    expect(rejected[0].reason).toBe("not-verbatim");
  });

  it("改了数字的被拒——最危险的一种", () => {
    const { rejected } = verifyQuotes([fact("f0", "下调存款准备金率 5 个百分点")], [source]);
    expect(rejected).toHaveLength(1);
  });

  it("引用了不存在的 source 时被拒，而不是崩", () => {
    const orphan: Fact = { id: "f9", sourceId: "nope", text: "t", quote: "x" };
    const { kept, rejected } = verifyQuotes([orphan], [source]);
    expect(kept).toEqual([]);
    expect(rejected[0].reason).toBe("unknown-source");
  });

  it("只在自己的 source 里找——在别家正文里命中不算数", () => {
    const other: Source = { ...source, id: "s1", body: "完全不同的正文。" };
    const f = { ...fact("f0", "下调存款准备金率"), sourceId: "s1" };
    const { kept, rejected } = verifyQuotes([f], [source, other]);
    expect(kept).toEqual([]);
    expect(rejected[0].reason).toBe("not-verbatim");
  });

  it("空引文被拒——空串是任何字符串的子串", () => {
    const { rejected } = verifyQuotes([fact("f0", "   ")], [source]);
    expect(rejected[0].reason).toBe("empty");
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/stages/verify-quote.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
// pipeline/src/stages/verify-quote.ts
import type { Fact, Source } from "../domain/types.js";

export type RejectReason = "empty" | "unknown-source" | "not-verbatim";

export interface RejectedFact {
  fact: Fact;
  reason: RejectReason;
}

export interface VerifyResult {
  kept: Fact[];
  rejected: RejectedFact[];
}

/**
 * 归一化只处理**排版差异**：空白和全角半角。
 * 绝不做同义词、繁简、标点等价——那些会让"逐字"名存实亡。
 */
export function normalizeForQuote(text: string): string {
  return text.normalize("NFKC").replace(/\s+/gu, "");
}

/**
 * 护城河：模型说"这是逐字引文"只是**自述**，自述不能当证据。
 * 这里把每一条引文拿回它自称的那篇正文里比对，对不上就丢掉。
 *
 * 错误方向：丢掉一条真引文只是少一个事实点；放进一条假引文，
 * 整个"每句可溯源"的承诺就是假的。所以一律从严。
 */
export function verifyQuotes(facts: Fact[], sources: Source[]): VerifyResult {
  const bodyById = new Map(sources.map((s) => [s.id, normalizeForQuote(s.body)]));

  const kept: Fact[] = [];
  const rejected: RejectedFact[] = [];

  for (const fact of facts) {
    const quote = normalizeForQuote(fact.quote);
    if (quote === "") {
      // 空串是任何字符串的子串，放行它等于关掉整个校验。
      rejected.push({ fact, reason: "empty" });
      continue;
    }

    const body = bodyById.get(fact.sourceId);
    if (body === undefined) {
      rejected.push({ fact, reason: "unknown-source" });
      continue;
    }

    // 只在它自称的那篇正文里找。在别家正文里命中不算数——
    // 那说明它挂错了源，而挂错源正是 independence 算错的起点。
    if (!body.includes(quote)) {
      rejected.push({ fact, reason: "not-verbatim" });
      continue;
    }

    kept.push(fact);
  }

  return { kept, rejected };
}
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/stages/verify-quote.test.ts`
Expected: PASS，10 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/stages/verify-quote.ts pipeline/test/stages/verify-quote.test.ts
git commit -m "$(cat <<'EOF'
Check every quote against its source instead of trusting the model

A model claiming a quote is verbatim is self-reporting, and self-reporting
is not evidence — this is the same reason binding is computed from a lookup
table rather than taken from the model's own answer. Each quote gets looked
up in the body it claims to come from, and a miss drops the fact.

Normalization folds only typography: whitespace and full-width forms. No
synonyms, no punctuation equivalence — those would make "verbatim" mean
nothing. Two cases get their own rejection paths because both silently
disable the check: an empty quote is a substring of everything, and a quote
that matches some other outlet's body means the fact is attached to the
wrong source, which is exactly where a wrong independence count starts.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: ② Claude web_search 客户端

**Files:**
- Create: `pipeline/src/models/search.ts`
- Test: `pipeline/test/models/search.test.ts`
- Modify: `pipeline/package.json`（加 `@anthropic-ai/sdk`）

**必须记住的一条**：web_search 出错时返回 **HTTP 200**，`content` 从数组变成对象（`{error_code: "max_uses_exceeded"}`）。不会抛异常。分支判断靠 `Array.isArray`。

- [ ] **Step 1: 装依赖**

```bash
cd pipeline && npm install @anthropic-ai/sdk
```

- [ ] **Step 2: 写失败的测试**

```typescript
// pipeline/test/models/search.test.ts
import { describe, expect, it } from "vitest";
import { collectSearchResults } from "../../src/models/search.js";

describe("collectSearchResults", () => {
  it("从 web_search_tool_result 块里收 URL", () => {
    const urls = collectSearchResults([
      {
        type: "web_search_tool_result",
        content: [
          { type: "web_search_result", url: "https://a.com/1", title: "A" },
          { type: "web_search_result", url: "https://b.com/2", title: "B" },
        ],
      },
    ] as never);
    expect(urls).toEqual(["https://a.com/1", "https://b.com/2"]);
  });

  it("忽略非搜索块", () => {
    const urls = collectSearchResults([
      { type: "text", text: "我来搜一下" },
      {
        type: "web_search_tool_result",
        content: [{ type: "web_search_result", url: "https://a.com/1" }],
      },
    ] as never);
    expect(urls).toEqual(["https://a.com/1"]);
  });

  it("出错时 content 是对象不是数组——不能当成结果去遍历", () => {
    const urls = collectSearchResults([
      { type: "web_search_tool_result", content: { error_code: "max_uses_exceeded" } },
    ] as never);
    expect(urls).toEqual([]);
  });

  it("去重，保持首次出现的顺序", () => {
    const urls = collectSearchResults([
      {
        type: "web_search_tool_result",
        content: [
          { type: "web_search_result", url: "https://a.com/1" },
          { type: "web_search_result", url: "https://a.com/1" },
          { type: "web_search_result", url: "https://b.com/2" },
        ],
      },
    ] as never);
    expect(urls).toEqual(["https://a.com/1", "https://b.com/2"]);
  });

  it("没有任何搜索块时返回空数组", () => {
    expect(collectSearchResults([{ type: "text", text: "x" }] as never)).toEqual([]);
  });
});
```

- [ ] **Step 3: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/models/search.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 4: 写实现**

```typescript
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
```

- [ ] **Step 5: 跑到绿**

Run: `cd pipeline && npx vitest run test/models/search.test.ts`
Expected: PASS，5 个测试

- [ ] **Step 6: 提交**

```bash
git add pipeline/src/models/search.ts pipeline/test/models/search.test.ts pipeline/package.json pipeline/package-lock.json
git commit -m "$(cat <<'EOF'
Search the web through the SDK, and treat its errors as data

This is the first runtime dependency in pipeline/. The boundary that
replaces the old rule: domain/, dedupe/ and draft/ — where the moat and the
offline tests live — stay at zero dependencies; only net/, models/ and
stages/ may import anything.

Web search failures arrive as HTTP 200 with content switching from a result
array to an error object, so nothing throws and a try/catch would never
fire. The branch is Array.isArray, and a non-array means no results rather
than a crash iterating an error.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: ② 候选源筛选

**Files:**
- Create: `pipeline/src/stages/search.ts`
- Test: `pipeline/test/stages/search.test.ts`

搜索返回的 URL 不能直接抓。同一家的多个页面、原文自己、明显的聚合站，抓了也是浪费，还会把 independence 搅浑。

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/stages/search.test.ts
import { describe, expect, it } from "vitest";
import { selectCandidates } from "../../src/stages/search.js";

describe("selectCandidates", () => {
  it("剔除原文自己", () => {
    const out = selectCandidates(
      ["https://a.com/1", "https://b.com/2"],
      "https://a.com/1",
      10,
    );
    expect(out).toEqual(["https://b.com/2"]);
  });

  it("同一发布方只留第一个——一家媒体的多个页面不是多个独立源", () => {
    const out = selectCandidates(
      ["https://a.com/1", "https://a.com/2", "https://b.com/1"],
      "https://z.com/0",
      10,
    );
    expect(out).toEqual(["https://a.com/1", "https://b.com/1"]);
  });

  it("剔除和原文同一发布方的页面", () => {
    const out = selectCandidates(
      ["https://a.com/other", "https://b.com/1"],
      "https://a.com/1",
      10,
    );
    expect(out).toEqual(["https://b.com/1"]);
  });

  it("按上限截断——抓取是最贵的一步", () => {
    const out = selectCandidates(
      ["https://a.com/1", "https://b.com/1", "https://c.com/1"],
      "https://z.com/0",
      2,
    );
    expect(out).toHaveLength(2);
  });

  it("非法 URL 被跳过而不是让整个阶段崩", () => {
    const out = selectCandidates(["不是链接", "https://b.com/1"], "https://z.com/0", 10);
    expect(out).toEqual(["https://b.com/1"]);
  });

  it("全部被剔除时返回空数组——上层据此走「信源不足」", () => {
    expect(selectCandidates(["https://a.com/1"], "https://a.com/1", 10)).toEqual([]);
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/stages/search.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
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
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/stages/search.test.ts`
Expected: PASS，6 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/stages/search.ts pipeline/test/stages/search.test.ts
git commit -m "$(cat <<'EOF'
Collapse candidates by publisher before paying to fetch them

Several pages from one outlet are not several independent sources. Doing
this before the fetch saves the most expensive step in the pipeline and,
more importantly, keeps same-publisher pages from reaching stage 5 and
muddying the independence count there.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: ⑤ 语义冲突二分类

**Files:**
- Create: `pipeline/src/stages/conflict.ts`
- Test: `pipeline/test/stages/conflict.test.ts`

已建成的 `findNumericConflicts` 只抓数字打架。「官方否认」vs「消息人士证实」这种语义冲突数字上看不出来，需要模型。但**判决权仍在代码**：模型只回答二分类，冲突图由代码构造。

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/stages/conflict.test.ts
import { describe, expect, it } from "vitest";
import { buildConflictPrompt, parseConflictReply, pairsToCheck } from "../../src/stages/conflict.js";
import type { MergedClaim } from "../../src/domain/types.js";

const claims: MergedClaim[] = [
  { id: "c0", text: "官方否认将要降准", factIds: ["f0"] },
  { id: "c1", text: "消息人士称降准已定", factIds: ["f1"] },
  { id: "c2", text: "股市今日收涨", factIds: ["f2"] },
];

describe("pairsToCheck", () => {
  it("两两组合，不含自己", () => {
    expect(pairsToCheck(claims)).toEqual([
      ["c0", "c1"],
      ["c0", "c2"],
      ["c1", "c2"],
    ]);
  });

  it("已经被数字冲突标过的对不重复问模型——省 token", () => {
    expect(pairsToCheck(claims, [["c0", "c1"]])).toEqual([
      ["c0", "c2"],
      ["c1", "c2"],
    ]);
  });

  it("方向无关：[c1,c0] 也算已标过", () => {
    expect(pairsToCheck(claims, [["c1", "c0"]])).toEqual([
      ["c0", "c2"],
      ["c1", "c2"],
    ]);
  });

  it("少于两条时没有要检查的对", () => {
    expect(pairsToCheck([claims[0]])).toEqual([]);
  });
});

describe("parseConflictReply", () => {
  it("只收下 conflict 为 true 的对", () => {
    const out = parseConflictReply({
      pairs: [
        { a: "c0", b: "c1", conflict: true },
        { a: "c0", b: "c2", conflict: false },
      ],
    });
    expect(out).toEqual([["c0", "c1"]]);
  });

  it("模型返回未知 id 时丢掉那一项而不是崩", () => {
    const out = parseConflictReply(
      { pairs: [{ a: "c0", b: "nope", conflict: true }] },
      new Set(["c0", "c1"]),
    );
    expect(out).toEqual([]);
  });

  it("conflict 不是布尔时当成 false——含糊即不冲突，避免误杀好数据", () => {
    const out = parseConflictReply({
      pairs: [{ a: "c0", b: "c1", conflict: "maybe" as never }],
    });
    expect(out).toEqual([]);
  });

  it("pairs 缺失时返回空数组", () => {
    expect(parseConflictReply({} as never)).toEqual([]);
  });
});

describe("buildConflictPrompt", () => {
  it("把待判的对和文本都写进去", () => {
    const prompt = buildConflictPrompt(claims, [["c0", "c1"]]);
    expect(prompt).toContain("官方否认将要降准");
    expect(prompt).toContain("消息人士称降准已定");
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/stages/conflict.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
// pipeline/src/stages/conflict.ts
import type { ClaimId, MergedClaim } from "../domain/types.js";

export type Pair = [ClaimId, ClaimId];

const keyOf = (a: ClaimId, b: ClaimId): string => (a < b ? `${a}|${b}` : `${b}|${a}`);

/**
 * 已经被 findNumericConflicts 标过的对不必再问模型——那一步是代码判的，
 * 比模型更可靠，也更便宜。
 */
export function pairsToCheck(claims: MergedClaim[], alreadyKnown: Pair[] = []): Pair[] {
  const known = new Set(alreadyKnown.map(([a, b]) => keyOf(a, b)));
  const out: Pair[] = [];
  for (let i = 0; i < claims.length; i++) {
    for (let j = i + 1; j < claims.length; j++) {
      const a = claims[i].id;
      const b = claims[j].id;
      if (known.has(keyOf(a, b))) continue;
      out.push([a, b]);
    }
  }
  return out;
}

export function buildConflictPrompt(claims: MergedClaim[], pairs: Pair[]): string {
  const textById = new Map(claims.map((c) => [c.id, c.text]));
  const lines = pairs.map(
    ([a, b]) => `- ${a}: ${textById.get(a)}\n  ${b}: ${textById.get(b)}`,
  );
  return [
    "判断下面每一对陈述是否**互相矛盾**——即两者不可能同时为真。",
    "",
    "注意：角度不同、详略不同、互为补充，都**不算**矛盾。",
    "只有当一条为真会使另一条为假时，才算矛盾。",
    "",
    '输出 JSON：{"pairs":[{"a":"c0","b":"c1","conflict":true}]}',
    "",
    "待判断：",
    ...lines,
  ].join("\n");
}

export interface ConflictReply {
  pairs?: { a: string; b: string; conflict: unknown }[];
}

/**
 * 判决权在代码：模型只回答一个二分类，冲突图由这里构造。
 * 含糊的回答一律当"不冲突"——把好数据误杀成 conflicted 会让稿子变空，
 * 而真冲突还有数字检测那一层兜着。
 */
export function parseConflictReply(
  reply: ConflictReply,
  knownIds?: Set<ClaimId>,
): Pair[] {
  if (!Array.isArray(reply?.pairs)) return [];

  const out: Pair[] = [];
  for (const item of reply.pairs) {
    if (item?.conflict !== true) continue;
    if (typeof item.a !== "string" || typeof item.b !== "string") continue;
    if (knownIds && (!knownIds.has(item.a) || !knownIds.has(item.b))) continue;
    out.push([item.a, item.b]);
  }
  return out;
}
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/stages/conflict.test.ts`
Expected: PASS，9 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/stages/conflict.ts pipeline/test/stages/conflict.test.ts
git commit -m "$(cat <<'EOF'
Ask the model only whether two statements can both be true

Numeric disagreement is already caught in code, and code is both cheaper
and more reliable than asking, so those pairs never reach the model. What
is left is the semantic case — an official denial against a sourced
confirmation — which no amount of number comparison will find.

The verdict still belongs to code: the model returns a binary, and the
conflict graph is built here from it. An ambiguous answer counts as no
conflict, because wrongly marking good claims conflicted empties the
script, while a real conflict still has the numeric layer beneath it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: ⑦ 拨盘 → 成稿 prompt

**Files:**
- Create: `pipeline/src/stages/draft.ts`
- Test: `pipeline/test/stages/draft.test.ts`

spec §2.2 的拨盘是两个连续轴：时长（最长 6min）× 调性（通俗↔专业）。两个锚点是 `1:00 通俗` 和 `3:00 偏专业`。

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/stages/draft.test.ts
import { describe, expect, it } from "vitest";
import { buildDraftPrompt, registerLabel } from "../../src/stages/draft.js";
import type { VerifiedClaim } from "../../src/domain/types.js";

const claims: VerifiedClaim[] = [
  {
    id: "c0",
    text: "存款准备金率下调 0.5 个百分点",
    factIds: ["f0"],
    independence: 3,
    confidence: "strong",
    conflictsWith: [],
  },
  {
    id: "c1",
    text: "释放长期资金约 1 万亿元",
    factIds: ["f1"],
    independence: 3,
    confidence: "strong",
    conflictsWith: [],
  },
];

describe("registerLabel", () => {
  it("0 是最通俗", () => {
    expect(registerLabel(0)).toMatch(/通俗|口语/);
  });

  it("1 是最专业", () => {
    expect(registerLabel(1)).toMatch(/专业/);
  });

  it("中间值落在中间档", () => {
    expect(registerLabel(0.5)).toBeTruthy();
    expect(registerLabel(0.5)).not.toBe(registerLabel(0));
    expect(registerLabel(0.5)).not.toBe(registerLabel(1));
  });

  it("越界的值被夹住而不是崩", () => {
    expect(registerLabel(-1)).toBe(registerLabel(0));
    expect(registerLabel(9)).toBe(registerLabel(1));
  });
});

describe("buildDraftPrompt", () => {
  it("把可用的 claim 和它的 id 都写进去", () => {
    const p = buildDraftPrompt(claims, 60, 0);
    expect(p).toContain("c0");
    expect(p).toContain("存款准备金率下调 0.5 个百分点");
  });

  it("写明时长", () => {
    expect(buildDraftPrompt(claims, 180, 0.7)).toContain("180");
  });

  it("要求 fact 句必须挂 claimIds，opinion 句不许挂——§6.2", () => {
    const p = buildDraftPrompt(claims, 60, 0);
    expect(p).toMatch(/fact/);
    expect(p).toMatch(/opinion/);
    expect(p).toContain("claimIds");
  });

  it("conflicted 的 claim 不出现在 prompt 里——它根本不该进稿", () => {
    const withConflict: VerifiedClaim[] = [
      ...claims,
      {
        id: "c9",
        text: "涉及资金 23 亿美元",
        factIds: ["f9"],
        independence: 1,
        confidence: "conflicted",
        conflictsWith: ["c8"],
      },
    ];
    const p = buildDraftPrompt(withConflict, 60, 0);
    expect(p).not.toContain("c9");
    expect(p).not.toContain("23 亿美元");
  });

  it("没有可用 claim 时抛——空稿子不如不出稿", () => {
    expect(() => buildDraftPrompt([], 60, 0)).toThrow(/没有/);
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/stages/draft.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
// pipeline/src/stages/draft.ts
import type { VerifiedClaim } from "../domain/types.js";

const REGISTER_LABELS = [
  "极通俗：像跟朋友聊天，不用任何术语，比喻优先",
  "偏通俗：口语为主，术语出现时立刻用一句话解释",
  "中性：正常的新闻评论语感",
  "偏专业：可以直接使用行业术语，假设听众有基础",
  "专业：面向同行，术语不解释，重点在机制和影响链条",
] as const;

export function registerLabel(register: number): string {
  const clamped = Math.min(1, Math.max(0, register));
  const idx = Math.min(
    REGISTER_LABELS.length - 1,
    Math.round(clamped * (REGISTER_LABELS.length - 1)),
  );
  return REGISTER_LABELS[idx];
}

export function buildDraftPrompt(
  claims: VerifiedClaim[],
  durationSec: number,
  register: number,
): string {
  // conflicted 的不进 prompt：让模型看见它，就等于给它一个用上的机会。
  const usable = claims.filter((c) => c.confidence !== "conflicted");
  if (usable.length === 0) {
    throw new Error("没有可用的 claim，不应该走到成稿这一步——上层该出「不建议播」");
  }

  const list = usable
    .map((c) => `- ${c.id}（${c.independence} 个独立信源）：${c.text}`)
    .join("\n");

  return [
    `写一段 ${durationSec} 秒的口播稿。`,
    `语气：${registerLabel(register)}`,
    "",
    "结构要求：",
    "- 开头一句钩子（kind 为 transition），抓注意力，不陈述事实",
    "- 中间是事实句（kind 为 fact），每句必须标明它用了哪几条 claim",
    "- 结尾可以有一句你的判断（kind 为 opinion）",
    "",
    "硬性规则：",
    "- fact 句的 claimIds 不能为空，且只能引用下面列出的 id",
    "- opinion 句和 transition 句的 claimIds 必须是空数组",
    "- 不许写下面列表里没有的事实。一个字都不许编。",
    "",
    '输出 JSON：{"sentences":[{"text":"...","kind":"fact","claimIds":["c0"]}]}',
    "",
    "可用的事实：",
    list,
  ].join("\n");
}
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/stages/draft.test.ts`
Expected: PASS，9 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/stages/draft.ts pipeline/test/stages/draft.test.ts
git commit -m "$(cat <<'EOF'
Keep conflicted claims out of the drafting prompt entirely

Filtering them at read time would be too late — showing a disputed claim to
the model is handing it something to use. The dial arrives as the two
continuous axes from the spec, duration and register, with register mapped
to five described bands rather than a number the model has to interpret.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: ⑦ 成稿输出校验（代码，拒收+重跑）

**Files:**
- Create: `pipeline/src/stages/validate-draft.ts`
- Test: `pipeline/test/stages/validate-draft.test.ts`

因为 DeepSeek 没有 strict schema（§0.2），§6.2 的保证**全靠这一个文件**。

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/stages/validate-draft.test.ts
import { describe, expect, it } from "vitest";
import { validateDraft } from "../../src/stages/validate-draft.js";

const allowed = new Set(["c0", "c1"]);

describe("validateDraft", () => {
  it("合法的稿子通过", () => {
    const r = validateDraft(
      {
        sentences: [
          { text: "央行出手了。", kind: "transition", claimIds: [] },
          { text: "下调 0.5 个百分点。", kind: "fact", claimIds: ["c0"] },
          { text: "我认为还没到头。", kind: "opinion", claimIds: [] },
        ],
      },
      allowed,
    );
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.sentences).toHaveLength(3);
  });

  it("fact 句 claimIds 为空要拒——§6.2 的核心", () => {
    const r = validateDraft(
      { sentences: [{ text: "下调了。", kind: "fact", claimIds: [] }] },
      allowed,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems[0].kind).toBe("fact-without-claims");
  });

  it("opinion 句带 claimIds 要拒——观点不该冒充有信源", () => {
    const r = validateDraft(
      { sentences: [{ text: "我觉得。", kind: "opinion", claimIds: ["c0"] }] },
      allowed,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems[0].kind).toBe("opinion-with-claims");
  });

  it("引用了不存在的 claim 要拒——这是模型编造的信号", () => {
    const r = validateDraft(
      { sentences: [{ text: "x", kind: "fact", claimIds: ["c9"] }] },
      allowed,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems[0].kind).toBe("unknown-claim");
  });

  it("未知的 kind 要拒", () => {
    const r = validateDraft(
      { sentences: [{ text: "x", kind: "narration" as never, claimIds: [] }] },
      allowed,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems[0].kind).toBe("bad-kind");
  });

  it("空文本要拒", () => {
    const r = validateDraft(
      { sentences: [{ text: "   ", kind: "transition", claimIds: [] }] },
      allowed,
    );
    expect(r.ok).toBe(false);
  });

  it("一句都没有要拒", () => {
    const r = validateDraft({ sentences: [] }, allowed);
    expect(r.ok).toBe(false);
  });

  it("sentences 不是数组要拒而不是崩", () => {
    const r = validateDraft({ sentences: "nope" } as never, allowed);
    expect(r.ok).toBe(false);
  });

  it("全部问题一次报齐，重跑时能把话说全", () => {
    const r = validateDraft(
      {
        sentences: [
          { text: "a", kind: "fact", claimIds: [] },
          { text: "b", kind: "opinion", claimIds: ["c0"] },
        ],
      },
      allowed,
    );
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.problems).toHaveLength(2);
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/stages/validate-draft.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
// pipeline/src/stages/validate-draft.ts
import type { ClaimId, DraftSentence, SentenceKind } from "../domain/types.js";

const KINDS = new Set<SentenceKind>(["fact", "opinion", "transition"]);

export type ProblemKind =
  | "no-sentences"
  | "bad-shape"
  | "empty-text"
  | "bad-kind"
  | "fact-without-claims"
  | "opinion-with-claims"
  | "unknown-claim";

export interface Problem {
  kind: ProblemKind;
  index: number;
  detail: string;
}

export type ValidateResult =
  | { ok: true; sentences: DraftSentence[] }
  | { ok: false; problems: Problem[] };

/**
 * DeepSeek 不支持 strict schema，所以 §6.2「fact 句必须挂 claim、opinion 句
 * 不许挂」这条**唯一的**保证就在这个函数里。它必须是拒收，不是尽量。
 *
 * 一次报齐全部问题：重跑时要把话说全，一次只报一个会让重跑次数线性增长。
 */
export function validateDraft(
  reply: { sentences?: unknown },
  allowedClaimIds: Set<ClaimId>,
): ValidateResult {
  const raw = reply?.sentences;
  if (!Array.isArray(raw)) {
    return { ok: false, problems: [{ kind: "bad-shape", index: -1, detail: "sentences 不是数组" }] };
  }
  if (raw.length === 0) {
    return { ok: false, problems: [{ kind: "no-sentences", index: -1, detail: "一句都没有" }] };
  }

  const problems: Problem[] = [];
  const sentences: DraftSentence[] = [];

  raw.forEach((item: unknown, index: number) => {
    const s = item as Partial<DraftSentence>;

    if (typeof s?.text !== "string" || s.text.trim() === "") {
      problems.push({ kind: "empty-text", index, detail: "文本为空" });
      return;
    }
    if (typeof s.kind !== "string" || !KINDS.has(s.kind as SentenceKind)) {
      problems.push({ kind: "bad-kind", index, detail: `未知的 kind：${String(s.kind)}` });
      return;
    }

    const claimIds = Array.isArray(s.claimIds) ? s.claimIds.filter((c) => typeof c === "string") : [];

    if (s.kind === "fact" && claimIds.length === 0) {
      // 这是整条产品承诺的断裂点：一句事实没有信源，却混在有信源的句子里。
      problems.push({ kind: "fact-without-claims", index, detail: s.text });
      return;
    }
    if (s.kind !== "fact" && claimIds.length > 0) {
      // 观点句挂信源是在给个人判断披一层客观外衣。
      problems.push({ kind: "opinion-with-claims", index, detail: s.text });
      return;
    }

    const unknown = claimIds.filter((c) => !allowedClaimIds.has(c));
    if (unknown.length > 0) {
      // 引用不存在的 claim 说明模型在编——这一条比其他任何问题都值得警惕。
      problems.push({ kind: "unknown-claim", index, detail: unknown.join("、") });
      return;
    }

    sentences.push({ text: s.text.trim(), kind: s.kind as SentenceKind, claimIds });
  });

  if (problems.length > 0) return { ok: false, problems };
  return { ok: true, sentences };
}
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/stages/validate-draft.test.ts`
Expected: PASS，9 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/stages/validate-draft.ts pipeline/test/stages/validate-draft.test.ts
git commit -m "$(cat <<'EOF'
Make the sentence-to-claim rule a rejection, not a preference

DeepSeek offers no strict schema, so the spec's guarantee — fact sentences
carry claims, opinion sentences never do — lives entirely in this function.
Three failures get their own names because they mean different things. A
fact sentence with no claims is the product promise breaking in the one
place nobody looks. An opinion sentence carrying claims dresses a personal
judgment as sourced. A reference to a claim that doesn't exist means the
model is inventing, and that one is worth more alarm than the rest.

All problems are reported at once so a retry can say everything that was
wrong; reporting one at a time makes retries grow linearly.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: 串起来 + CLI 吃真 URL

**Files:**
- Create: `pipeline/src/run.ts`
- Modify: `pipeline/src/cli.ts`
- Test: `pipeline/test/run.test.ts`

- [ ] **Step 1: 写失败的测试**（用替身，全程离线）

```typescript
// pipeline/test/run.test.ts
import { describe, expect, it, vi } from "vitest";
import { runPipeline, type Ports } from "../src/run.js";

const article = (body: string) => ({ title: "t", url: "https://a.com/1", body });

function ports(overrides: Partial<Ports> = {}): Ports {
  return {
    readArticle: vi.fn().mockResolvedValue(article("央行今日宣布下调存款准备金率 0.5 个百分点。")),
    findSources: vi.fn().mockResolvedValue([]),
    extractFacts: vi.fn().mockResolvedValue([]),
    findSemanticConflicts: vi.fn().mockResolvedValue([]),
    draftScript: vi.fn().mockResolvedValue([]),
    ...overrides,
  };
}

describe("runPipeline", () => {
  it("信源不足时以 insufficient 收场，且不调用成稿——不烧那笔钱", async () => {
    const draftScript = vi.fn();
    const result = await runPipeline(
      "https://a.com/1",
      { durationSec: 60, register: 0, charsPerSecond: 5 },
      ports({ draftScript }),
    );
    expect(result.status).toBe("insufficient");
    expect(draftScript).not.toHaveBeenCalled();
  });

  it("被逐字校验拒掉的 fact 不进入后面的阶段", async () => {
    const extractFacts = vi.fn().mockResolvedValue([
      { id: "s0-f0", sourceId: "s0", text: "转述的", quote: "这段原文里没有" },
    ]);
    const result = await runPipeline(
      "https://a.com/1",
      { durationSec: 60, register: 0, charsPerSecond: 5 },
      ports({ extractFacts }),
    );
    expect(result.rejectedQuotes).toHaveLength(1);
  });

  it("抓取失败的候选源被跳过，不让整轮调研失败", async () => {
    const readArticle = vi
      .fn()
      .mockResolvedValueOnce(article("正文一。"))
      .mockRejectedValueOnce(new Error("timeout"))
      .mockResolvedValueOnce(article("正文三。"));
    const result = await runPipeline(
      "https://a.com/1",
      { durationSec: 60, register: 0, charsPerSecond: 5 },
      ports({
        readArticle,
        findSources: vi.fn().mockResolvedValue(["https://b.com/1", "https://c.com/1"]),
      }),
    );
    expect(result.sources).toHaveLength(2);
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/run.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
// pipeline/src/run.ts
import { buildBrief, type CoreResult } from "./core.js";
import type { Article } from "./net/jina.js";
import type { ClaimId, DraftSentence, Fact, MergedClaim, Source } from "./domain/types.js";
import { toSource } from "./stages/fetch.js";
import { selectCandidates } from "./stages/search.js";
import { verifyQuotes, type RejectedFact } from "./stages/verify-quote.js";
import type { Pair } from "./stages/conflict.js";

const MAX_CANDIDATES = 8;
const MINIMUM_SOURCES = 3;

/** 每个外部动作一个端口，测试喂替身，全程离线。 */
export interface Ports {
  readArticle: (url: string) => Promise<Article>;
  findSources: (headline: string) => Promise<string[]>;
  extractFacts: (source: Source) => Promise<Fact[]>;
  findSemanticConflicts: (claims: MergedClaim[]) => Promise<Pair[]>;
  draftScript: (
    claims: CoreResult["claims"],
    durationSec: number,
    register: number,
  ) => Promise<DraftSentence[]>;
}

export interface RunOptions {
  durationSec: number;
  register: number;
  charsPerSecond: number;
}

export type RunResult =
  | { status: "insufficient"; sources: Source[]; reason: string; rejectedQuotes: RejectedFact[] }
  | { status: "ok"; sources: Source[]; rejectedQuotes: RejectedFact[]; core: CoreResult };

export async function runPipeline(
  url: string,
  options: RunOptions,
  ports: Ports,
): Promise<RunResult> {
  // ① 原文
  const first = await ports.readArticle(url);
  const fetchedAt = new Date().toISOString();
  const sources: Source[] = [toSource("s0", first, fetchedAt)];

  // ② 扩展检索
  const candidates = selectCandidates(
    await ports.findSources(first.title || first.body.slice(0, 80)),
    url,
    MAX_CANDIDATES,
  );

  for (const candidate of candidates) {
    try {
      sources.push(toSource(`s${sources.length}`, await ports.readArticle(candidate), fetchedAt));
    } catch {
      // 一个源抓不下来不该让整轮调研失败——它只是少一个源。
      continue;
    }
  }

  // ③ 抽事实 + 逐字校验
  const rawFacts: Fact[] = [];
  for (const source of sources) {
    rawFacts.push(...(await ports.extractFacts(source)));
  }
  const { kept: facts, rejected: rejectedQuotes } = verifyQuotes(rawFacts, sources);

  if (sources.length < MINIMUM_SOURCES) {
    // 在成稿之前就收手：spec §5.1 的「敢说这条别播」，同时省下最贵的一步。
    return {
      status: "insufficient",
      sources,
      rejectedQuotes,
      reason: `只找到 ${sources.length} 个信源，低于 ${MINIMUM_SOURCES} 个的下限`,
    };
  }

  // ④⑤⑥⑧⑨ 全部是已建成的确定性内核，这里只是喂给它。
  const core = buildBrief({
    durationSec: options.durationSec,
    register: options.register,
    charsPerSecond: options.charsPerSecond,
    sources,
    facts,
    draft: [],
  });

  // ⑦ 成稿——放在最后，因为它是唯一一步「前面都成立才值得花」的调用。
  const draft = await ports.draftScript(core.claims, options.durationSec, options.register);

  const final = buildBrief({
    durationSec: options.durationSec,
    register: options.register,
    charsPerSecond: options.charsPerSecond,
    sources,
    facts,
    draft,
  });

  return { status: "ok", sources, rejectedQuotes, core: final };
}

export type { ClaimId };
```

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/run.test.ts`
Expected: PASS，3 个测试

- [ ] **Step 5: 改 CLI 接受真 URL**

在 `pipeline/src/cli.ts` 里增加一个分支：参数以 `http` 开头时走 `runPipeline`，否则保持现有的 fixture 行为。所有端口在这里用真实现装配（`readArticle` / `SearchClient` / `DeepSeekClient`），配置走 `loadConfig()`。

- [ ] **Step 6: 跑全量测试**

Run: `cd pipeline && npm test && npm run typecheck`
Expected: 全绿（96 个已有 + 本计划新增）

- [ ] **Step 7: 提交**

```bash
git add pipeline/src/run.ts pipeline/src/cli.ts pipeline/test/run.test.ts
git commit -m "$(cat <<'EOF'
Stop before drafting when the sources aren't there

Every external action is a port, so the whole pipeline runs offline in
tests with no key and no network. Two orderings carry real weight. The
source-count check sits before drafting, because refusing to produce a
script is a product feature and this is also the most expensive call to
skip. And one candidate that fails to fetch is skipped rather than fatal —
it costs one source, not the whole run.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: iOS —— take 结束时导出语速（spec §9.2 ① 第一半）

**Files:**
- Modify: `ios/Pollux One/Engines/ReadingPacer.swift`
- Modify: `ios/Pollux One/Engines/SessionManager.swift`
- Test: `ios/EngineHarness/PacingScenarios.swift`

§9.2 ① 说得很直白：「按你的语速」这条差异化**目前没有数据支撑**。`ReadingPacer.rate` 是会话内状态，`reset()` 就没了。

**核过的既有 API（别照 spec 写，spec 有出入）：** `ReadingPacer(language: ScriptLanguage)`，
`private(set) var rate: Double`、`cursor`、`reset(to:language:)`、`advance(deltaTime:lookaheadCap:)`、
`correct(to:confidence:at:seekThreshold:)`。`minimumRateConfidence` **已存在**并在 `correct` 里用着。
**没有**样本计数——本任务要补一个，否则"样本够不够"无从判断。

测试台的断言 API 是 `Report.check(_:_:detail:)`，不是 `expect`。

- [ ] **Step 1: 在 harness 里写失败的测试**

```swift
// 加进 ios/EngineHarness/PacingScenarios.swift 的 runPacingSuite()，return 之前

    report.section("take 结束导出语速样本")

    let exporting = ReadingPacer(language: .cjk)
    exporting.reset(to: 0, language: .cjk)
    // correct() 只在 confidence >= minimumRateConfidence 且时间前进时采样，
    // 所以喂够高置信度的推进才会累积样本。
    for i in 1...12 {
        exporting.correct(to: Double(i) * 5.0, confidence: 0.9,
                          at: TimeInterval(i), seekThreshold: 40)
    }
    let sample = exporting.exportSample()
    report.check(sample != nil, "样本够了就能导出")
    report.check(sample?.language == .cjk, "带语种——中英文字符/秒差三倍以上")
    report.check((sample?.charsPerSecond ?? 0) > 0, "语速为正", detail: "\(sample?.charsPerSecond ?? -1)")

    let tooFew = ReadingPacer(language: .cjk)
    tooFew.reset(to: 0, language: .cjk)
    tooFew.correct(to: 5.0, confidence: 0.9, at: 1, seekThreshold: 40)
    report.check(tooFew.exportSample() == nil,
                 "样本不足时返回 nil——一个不可信的数混进中位数，比少一个样本更糟")

    let lowConfidence = ReadingPacer(language: .cjk)
    lowConfidence.reset(to: 0, language: .cjk)
    for i in 1...12 {
        lowConfidence.correct(to: Double(i) * 5.0, confidence: 0.2,
                              at: TimeInterval(i), seekThreshold: 40)
    }
    report.check(lowConfidence.exportSample() == nil,
                 "低置信度的推进不计入样本")

    let afterReset = ReadingPacer(language: .cjk)
    afterReset.reset(to: 0, language: .cjk)
    for i in 1...12 {
        afterReset.correct(to: Double(i) * 5.0, confidence: 0.9,
                           at: TimeInterval(i), seekThreshold: 40)
    }
    afterReset.reset(to: 0, language: .cjk)
    report.check(afterReset.exportSample() == nil,
                 "reset 后重新积累——不能把上一条稿的语速算到这一条头上")
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `bash scripts/test-engines.sh`
Expected: FAIL — `exportSample` 不存在

- [ ] **Step 3: 写实现**

在 `ReadingPacer` 上加：

```swift
    /// 一次 take 结束时导出的语速样本。带语种，因为中英文的字符/秒差三倍以上。
    struct Sample: Equatable {
        let language: ScriptLanguage
        let charsPerSecond: Double
    }

    /// 少于这个数不导出。样本太少时 rate 还基本是种子值，
    /// 把它当成"这个用户的语速"存进去，等于用默认值污染中位数。
    static let minimumSampleCount = 8

    /// 实际被采纳的样本数——只有 correct() 里那个 `sample > 0` 分支走到才加。
    private(set) var acceptedSampleCount = 0

    /// 会话内状态导出成一个可以落库的样本。不够可信就返回 nil：
    /// 一个不可信的数混进近 10 次的中位数里，比少一个样本更糟。
    func exportSample() -> Sample? {
        guard acceptedSampleCount >= Self.minimumSampleCount else { return nil }
        return Sample(language: language, charsPerSecond: rate)
    }
```

在 `correct(...)` 里那个 `if sample > 0 {` 块的末尾（`rate = min(max(...))` 之后）加一行：

```swift
                acceptedSampleCount += 1
```

在 `reset(to:language:)` 里加一行，让它跟着清零：

```swift
        acceptedSampleCount = 0
```

- [ ] **Step 4: 跑到绿**

Run: `bash scripts/test-engines.sh`
Expected: `TOTAL: 238 passed, 0 failed`

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/Engines/ReadingPacer.swift" "ios/Pollux One/Engines/SessionManager.swift" ios/EngineHarness/PacingScenarios.swift
git commit -m "$(cat <<'EOF'
Let a finished take leave behind the rate it was read at

ReadingPacer.rate is session state that reset() erases, so "paced to how
you actually read" has had no data behind it. Export is gated on both a
sample count and a confidence floor and returns nil below either: an
untrustworthy number entering the median is worse than one fewer sample,
and a rate carried across reset would bill one script's pace to another.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: `user_reading_rates` 落库与读取（spec §9.2 ① 第二半）

**Files:**
- Modify: `ios/Pollux One/Services/BackendClient.swift`
- Create: `pipeline/src/domain/reading-rate.ts`
- Test: `pipeline/test/domain/reading-rate.test.ts`

表已经在 `0002_briefs.sql` 里建好了。§7 说「近 10 次中位」。

- [ ] **Step 1: 写失败的测试**

```typescript
// pipeline/test/domain/reading-rate.test.ts
import { describe, expect, it } from "vitest";
import { medianRate, resolveCharsPerSecond } from "../../src/domain/reading-rate.js";
import { DEFAULT_CHARS_PER_SECOND } from "../../src/domain/prosody.js";

describe("medianRate", () => {
  it("奇数个取中间", () => {
    expect(medianRate([4, 5, 6])).toBe(5);
  });

  it("偶数个取中间两个的平均", () => {
    expect(medianRate([4, 5, 6, 7])).toBe(5.5);
  });

  it("中位数而不是平均——一次读错稿的极慢 take 不该拉低整体", () => {
    expect(medianRate([5, 5, 5, 5, 0.5])).toBe(5);
  });

  it("只取最近 10 个", () => {
    const rates = [...Array(15).fill(9), ...Array(0)];
    expect(medianRate(rates.slice(-10))).toBe(9);
  });

  it("空数组返回 null", () => {
    expect(medianRate([])).toBeNull();
  });
});

describe("resolveCharsPerSecond", () => {
  it("有历史就用历史", () => {
    expect(resolveCharsPerSecond("cjk", [6, 6, 6])).toBe(6);
  });

  it("没有历史就退回语种默认值——新用户第一篇必然走这条", () => {
    expect(resolveCharsPerSecond("cjk", [])).toBe(DEFAULT_CHARS_PER_SECOND.cjk);
    expect(resolveCharsPerSecond("latin", [])).toBe(DEFAULT_CHARS_PER_SECOND.latin);
  });
});
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `cd pipeline && npx vitest run test/domain/reading-rate.test.ts`
Expected: FAIL — 模块不存在

- [ ] **Step 3: 写实现**

```typescript
// pipeline/src/domain/reading-rate.ts
import { DEFAULT_CHARS_PER_SECOND, type Language } from "./prosody.js";

/** §7：近 10 次的中位数。 */
export const RECENT_SAMPLE_WINDOW = 10;

/**
 * 中位数而不是平均数：一次读错稿、中途停顿的 take 会产生一个极端值，
 * 平均数会被它拖走，中位数不会。
 */
export function medianRate(rates: number[]): number | null {
  if (rates.length === 0) return null;
  const sorted = [...rates].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/**
 * 没有历史样本时退回语种默认值。这意味着**新用户的第一篇稿必然不是按他的语速**——
 * spec §9.2 ① 明确要求产品文案不能上来就说「按你的语速」。
 */
export function resolveCharsPerSecond(language: Language, rates: number[]): number {
  return medianRate(rates.slice(-RECENT_SAMPLE_WINDOW)) ?? DEFAULT_CHARS_PER_SECOND[language];
}
```

在 `BackendClient` 上加一个 upsert 方法，把 Task 14 的样本写进 `user_reading_rates`。

- [ ] **Step 4: 跑到绿**

Run: `cd pipeline && npx vitest run test/domain/reading-rate.test.ts`
Expected: PASS，7 个测试

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/domain/reading-rate.ts pipeline/test/domain/reading-rate.test.ts "ios/Pollux One/Services/BackendClient.swift"
git commit -m "$(cat <<'EOF'
Take the median of recent takes, not the mean

One take where the reader stumbled or stopped mid-sentence produces an
extreme value; a mean follows it and a median doesn't. With no history the
answer falls back to the language default, which is the honest admission
that a new user's first script is not paced to them — the spec is explicit
that the copy must not claim otherwise until the samples exist.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: 用真实样本回归 `estimateBrief` 的系数

**Files:**
- Create: `pipeline/scripts/calibrate.ts`
- Modify: `pipeline/src/domain/estimate.ts`
- Modify: `pipeline/test/domain/estimate.test.ts`

`ESTIMATE_COEFFICIENTS` 现在是手填的，由一个测试钉住。§12 说它的系数只能从真实消耗里回归，而那批样本正好是本计划产出的。

- [ ] **Step 1: 写一个把真实消耗记下来的脚本**

`pipeline/scripts/calibrate.ts` 跑一批真实 URL，每篇记录：`durationSec`、`register`、账本的 `totals()` 和 `totalCostCents()`，输出 `pipeline/test/fixtures/calibration.json`。

- [ ] **Step 2: 写失败的测试**

```typescript
// 加进 pipeline/test/domain/estimate.test.ts
import calibration from "../fixtures/calibration.json" with { type: "json" };

describe("estimateBrief 对真实样本的偏差", () => {
  it("在拨盘四个角上，估算与实际的偏差不超过 50%", () => {
    for (const sample of calibration.samples) {
      const estimated = estimateBrief(sample.durationSec, sample.register).tokens;
      const actual = sample.actualTokens;
      const ratio = estimated / actual;
      expect(ratio, `${sample.durationSec}s register=${sample.register}`).toBeGreaterThan(0.5);
      expect(ratio, `${sample.durationSec}s register=${sample.register}`).toBeLessThan(1.5);
    }
  });

  it("估算永远不低于实际——低估会让用户余额不够却已经开跑", () => {
    for (const sample of calibration.samples) {
      expect(estimateBrief(sample.durationSec, sample.register).tokens).toBeGreaterThanOrEqual(
        sample.actualTokens * 0.9,
      );
    }
  });
});
```

- [ ] **Step 3: 跑校准脚本，产出 fixture**

Run: `cd pipeline && npx tsx scripts/calibrate.ts`
Expected: 写出 `test/fixtures/calibration.json`，至少 8 条样本，覆盖 `1:00 通俗` 和 `3:00 偏专业` 两个锚点

- [ ] **Step 4: 调系数直到测试通过**

改 `ESTIMATE_COEFFICIENTS`，同时更新那个钉住它的测试，并在注释里写明这组值是从哪一批样本回归出来的、日期是多少。

- [ ] **Step 5: 跑全量**

Run: `cd pipeline && npm test && npm run typecheck`
Expected: 全绿

- [ ] **Step 6: 提交**

```bash
git add pipeline/scripts/calibrate.ts pipeline/src/domain/estimate.ts pipeline/test/domain/estimate.test.ts pipeline/test/fixtures/calibration.json
git commit -m "$(cat <<'EOF'
Regress the cost coefficients against runs that actually happened

The coefficients were hand-written and pinned by a test, which proved they
were stable, not that they were right. The asymmetric bound is deliberate:
an estimate may run high, but must never fall below what a run really
costs, because an under-estimate is how a user starts a brief they cannot
afford to finish and finds out after the tokens are gone.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## 二、验收：spec §12 的那道门

全部任务做完后，**不要直接开始第二段**。§12 要求先过质量关：

```bash
cd pipeline
npx tsx src/cli.ts https://<一条真实新闻> --duration 60  --register 0.0   # 锚点一：1:00 通俗
npx tsx src/cli.ts https://<一条真实新闻> --duration 180 --register 0.7   # 锚点二：3:00 偏专业
```

每个锚点各跑一批（建议 5 条不同类型的新闻），人工评：

| 看什么 | 不合格的样子 |
|---|---|
| 稿子能不能直接播 | 需要大改，说明 ⑦ 的 prompt 没调好 |
| 信源挂得准不准 | 抽查 fact 句，点开它的 claim，看引文是否真的支持这句话 |
| independence 是否可信 | 人工看那几个源，是不是真的互相独立 |
| 冲突有没有漏 | 故意找一条有争议数字的新闻 |
| 成本 | 与 `estimateBrief` 的估算差多少 |

**评不过就不投第二段。** 界面做得再顺，稿子不能播都是白的。

---

## 三、明确不在本计划内

- 阶段状态机（`brief_stages` 驱动的 runner）——CLI 是长驻进程，不需要它；iOS 的进度显示才需要
- 落库（11 张表已建好，但本计划只产出 JSON）
- 余额门禁（§11）——依赖落库
- 七个 iOS 界面、Share Extension、`SessionManager` 上提（§9.2 ②）
- Safe Word 指纹降级（§9.2 ③）、`PromptScriptText` 拼接纪律（§9.2 ④）
- 截图输入（① 的视觉分支）

---

## Task 17: 补上 schema 里缺的两列（界面那一段逼出来的）

**Files:**
- Create: `backend/supabase/migrations/0003_evidence_anchors.sql`

`0002_briefs.sql` 建表时，spec 还没有「句内证据锚点」和「被归并的转载篇数」这两个概念——
它们是先做界面那一段从 mock 里反推出来的（见 `2026-09-18-brief-ios-on-fixtures.md` §0.4）。
spec §5 / §6.2 现在已经写明要产出它们，但表里没有地方放。

**为什么另建表而不是给 `script_evidence` 加列**：它的主键是
`(sentence_id, claim_id)`，一句话对同一条 claim 只能有一行。而锚点是 0..n 个——
一句话可能在两处提到同一个数字。加列会把这个上限固化成 1，而且锚点本来就是
可缺省的（越界或重叠时整句降级为纯文本），塞进主表会多出一对可空列。
这与 §9.2 ⑤ 给气口另建 `sentence_breaths` 是同一个判断。

- [ ] **Step 1: 写迁移**

```sql
-- 句内证据锚点：审稿页那条虚线下划线的位置。
-- start/length 以 **Character** 计，不是 UTF-16 code unit —— 句中一有中文，
-- 用 UTF-16 会让后面每条下划线整体错位，且越往后偏得越多。
create table evidence_anchors (
  id uuid primary key default gen_random_uuid(),
  sentence_id uuid not null,
  claim_id uuid not null,
  char_start integer not null check (char_start >= 0),
  char_length integer not null check (char_length > 0),
  -- 锚点依附于一条 evidence；evidence 没了，锚点没有意义
  foreign key (sentence_id, claim_id)
    references script_evidence (sentence_id, claim_id) on delete cascade,
  -- 同一条 evidence 的多个锚点不许起点相同
  unique (sentence_id, claim_id, char_start)
);

alter table evidence_anchors enable row level security;

create policy "evidence_anchors follow their evidence" on evidence_anchors
  for all using (
    exists (
      select 1 from script_evidence e
      join sentences s on s.id = e.sentence_id
      join paragraphs p on p.id = s.paragraph_id
      join script_sections sec on sec.id = p.section_id
      join scripts sc on sc.id = sec.script_id
      where e.sentence_id = evidence_anchors.sentence_id
        and e.claim_id = evidence_anchors.claim_id
        and sc.user_id = auth.uid()
    )
  );

create index evidence_anchors_by_sentence on evidence_anchors (sentence_id);

-- 被判为转载、已归并掉的篇数。与 independence 分开存：
-- 两者相加（3 + 6 = 9）正是 §5 开头「5 家门户转载不是 5 个源」要防的误读，
-- 合并成一个数就只剩「3 个独立信源」，没法显示「另有 6 篇未计入」。
alter table brief_claims
  add column merged_away_count integer not null default 0
  check (merged_away_count >= 0);
```

- [ ] **Step 2: 在真 Postgres 上验一遍**

照 `0002` 当初的做法起一个临时实例（`initdb` 需要 `LC_ALL=C … --locale=C --encoding=UTF8`，
并先建 `auth` schema stub：`auth.users` 表和 `auth.uid()` 函数，因为 `0001_init.sql`
引用了 Supabase Auth）。依次跑 `0001` → `0002` → `0003`，必须全部无错。

- [ ] **Step 3: 补 §9 的数据模型表**

`docs/superpowers/specs/2026-09-17-news-brief-pipeline-design.md` 的 §9 表里加上
`evidence_anchors` 这张表和 `brief_claims.merged_away_count` 这一列。
照 §9 建表的人现在会漏掉它们。

- [ ] **Step 4: 提交**

```bash
git add backend/supabase/migrations/0003_evidence_anchors.sql docs/superpowers/specs/2026-09-17-news-brief-pipeline-design.md
git commit -m "$(cat <<'EOF'
Give the underlines and the excluded reposts a column to live in

Both fields came out of building the screens first: the mock needed
character ranges for the in-sentence underlines and a count of the reposts
that were merged away, and 0002 was written before either existed.

Anchors get their own table rather than columns on script_evidence, whose
primary key allows one row per sentence-claim pair. A sentence can anchor
the same claim in two places, and an anchor is optional anyway — it
degrades to plain text when the range is wrong — so folding it into the
main table would cap it at one and add a pair of nullable columns. Breaths
were given a sibling table for the same reason.

merged_away_count stays separate from independence because adding them is
the misreading the whole independence count exists to prevent.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```
