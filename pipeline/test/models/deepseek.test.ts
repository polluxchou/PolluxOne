// pipeline/test/models/deepseek.test.ts
import { describe, expect, it, vi } from "vitest";
import {
  DeepSeekClient,
  DEFAULT_MAX_TOKENS,
  extractUsage,
  isTruncated,
  TruncatedOutputError,
} from "../../src/models/deepseek.js";
import { TokenLedger } from "../../src/models/ledger.js";

const reply = (content: string, usage = { prompt_tokens: 10, completion_tokens: 5 }) =>
  new Response(
    JSON.stringify({ choices: [{ message: { content } }], usage }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );

/**
 * 实跑里那个静默的钱漏长这样：HTTP 200、finish_reason=length、推理把上限顶满、
 * content 是空字符串。三件事同时发生，没有一件会自己喊出来。
 */
const truncated = (maxTokens = DEFAULT_MAX_TOKENS) =>
  new Response(
    JSON.stringify({
      choices: [{ message: { content: "" }, finish_reason: "length" }],
      usage: {
        prompt_tokens: 4321,
        completion_tokens: maxTokens,
        completion_tokens_details: { reasoning_tokens: maxTokens },
      },
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );

const clientWith = (send: unknown, ledger = new TokenLedger()) =>
  new DeepSeekClient(
    { apiKey: "k", baseUrl: "https://api.deepseek.com" },
    ledger,
    send as never,
  );

const bodyOf = (send: { mock: { calls: unknown[][] } }, call = 0) =>
  JSON.parse((send.mock.calls[call]![1] as RequestInit).body as string) as {
    max_tokens: number;
  };

describe("extractUsage", () => {
  it("映射 DeepSeek 的字段名", () => {
    expect(
      extractUsage({
        prompt_tokens: 101,
        completion_tokens: 259,
        completion_tokens_details: { reasoning_tokens: 189 },
        prompt_cache_hit_tokens: 0,
        prompt_cache_miss_tokens: 101,
      }),
    ).toEqual({
      inputTokens: 101,
      outputTokens: 259,
      reasoningTokens: 189,
      cacheHitTokens: 0,
      cacheMissTokens: 101,
    });
  });

  it("命中／未命中照实拆开——命中价便宜 50 倍，丢掉拆分等于全按未命中计", () => {
    const usage = extractUsage({
      prompt_tokens: 1000,
      completion_tokens: 10,
      prompt_cache_hit_tokens: 960,
      prompt_cache_miss_tokens: 40,
    });
    expect(usage.cacheHitTokens).toBe(960);
    expect(usage.cacheMissTokens).toBe(40);
    // prompt_tokens 仍然是总数，不是「除了命中之外的那部分」
    expect(usage.inputTokens).toBe(1000);
    expect(usage.cacheHitTokens + usage.cacheMissTokens).toBe(usage.inputTokens);
  });

  it("没有拆分字段时全记未命中——偏贵的方向才是安全的", () => {
    const usage = extractUsage({ prompt_tokens: 101, completion_tokens: 2 });
    expect(usage.cacheHitTokens).toBe(0);
    expect(usage.cacheMissTokens).toBe(101);
  });

  it("只给了一半（缺 miss）也当全部未命中——半份拆分不比没有更可信", () => {
    const usage = extractUsage({ prompt_tokens: 100, prompt_cache_hit_tokens: 100 });
    expect(usage.cacheHitTokens).toBe(0);
    expect(usage.cacheMissTokens).toBe(100);
  });

  it("两者之和对不上 prompt_tokens 时全记未命中", () => {
    const usage = extractUsage({
      prompt_tokens: 101,
      prompt_cache_hit_tokens: 90,
      prompt_cache_miss_tokens: 5, // 90 + 5 ≠ 101
    });
    expect(usage.cacheHitTokens).toBe(0);
    expect(usage.cacheMissTokens).toBe(101);
  });

  it("没有 reasoning 明细时给 0", () => {
    expect(extractUsage({ prompt_tokens: 1, completion_tokens: 2 })).toEqual({
      inputTokens: 1,
      outputTokens: 2,
      reasoningTokens: 0,
      cacheHitTokens: 0,
      cacheMissTokens: 1,
    });
  });

  it("usage 整个缺失时不炸——记 0 好过丢一次调用", () => {
    expect(extractUsage(undefined)).toEqual({
      inputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
      cacheHitTokens: 0,
      cacheMissTokens: 0,
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
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);
    expect(body.response_format).toEqual({ type: "json_object" });
  });
});

describe("max_tokens 截断", () => {
  it("finish_reason 是 length 时说出「被截断」，而不是那条后面跟着空字符串的「没有返回合法 JSON」", async () => {
    const send = vi.fn().mockResolvedValue(truncated());
    const error = (await clientWith(send)
      .json("conflict", "deepseek-flash", "p")
      .catch((e: unknown) => e)) as Error;

    expect(error).toBeInstanceOf(TruncatedOutputError);
    expect(error.message).toMatch(/截断/);
    // 这条正是实跑里白烧 24000 token 的那句：看不出被截断了，只看见一片空白。
    expect(error.message).not.toMatch(/没有返回合法 JSON/);
  });

  it("错误里带上上限、实际 completion_tokens 和 reasoning_tokens——不带就等于还得再猜一轮", async () => {
    const send = vi.fn().mockResolvedValue(truncated(8000));
    const error = (await clientWith(send)
      .json("conflict", "deepseek-flash", "p", 8000)
      .catch((e: unknown) => e)) as TruncatedOutputError;

    expect(error.maxTokens).toBe(8000);
    expect(error.completionTokens).toBe(8000);
    expect(error.reasoningTokens).toBe(8000);
    expect(error.message).toContain("8000");
    expect(error.message).toContain("deepseek-flash");
  });

  it("截断照样记账——这 8000 个输出 token 是真付了钱的", async () => {
    const ledger = new TokenLedger();
    const send = vi.fn().mockResolvedValue(truncated(8000));
    await clientWith(send, ledger).json("conflict", "deepseek-flash", "p", 8000).catch(() => undefined);

    expect(ledger.totals().outputTokens).toBe(8000);
    expect(ledger.totals().inputTokens).toBe(4321);
  });

  it("截断能和「输出不合规」分开：前者重试必然重演，后者重试有意义", async () => {
    const truncatedError = await clientWith(vi.fn().mockResolvedValue(truncated()))
      .json("draft", "deepseek-v4-pro", "p")
      .catch((e: unknown) => e);
    const malformedError = await clientWith(vi.fn().mockResolvedValue(reply("这不是 JSON")))
      .json("draft", "deepseek-v4-pro", "p")
      .catch((e: unknown) => e);

    expect(isTruncated(truncatedError)).toBe(true);
    expect(isTruncated(malformedError)).toBe(false);
    // 两个都是 Error，靠文案区分是不可靠的，所以调用方问的是类型。
    expect(malformedError).toBeInstanceOf(Error);
  });

  it("finish_reason 是 stop 就照常解析，别把正常回复也当截断", async () => {
    const send = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          choices: [{ message: { content: '{"ok":true}' }, finish_reason: "stop" }],
          usage: { prompt_tokens: 10, completion_tokens: 5 },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );
    await expect(clientWith(send).json("extract", "deepseek-flash", "p")).resolves.toEqual({
      ok: true,
    });
  });

  it("默认上限够推理模型用——8000 被实跑证明太小了", async () => {
    const send = vi.fn().mockResolvedValue(reply("{}"));
    await clientWith(send).json("extract", "deepseek-flash", "p");

    expect(bodyOf(send).max_tokens).toBe(DEFAULT_MAX_TOKENS);
    expect(DEFAULT_MAX_TOKENS).toBeGreaterThan(8000);
  });

  it("显式给的上限压过默认值", async () => {
    const send = vi.fn().mockResolvedValue(reply("{}"));
    await clientWith(send).json("conflict", "deepseek-flash", "p", 12_345);

    expect(bodyOf(send).max_tokens).toBe(12_345);
  });
});
