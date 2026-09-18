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
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);
    expect(body.response_format).toEqual({ type: "json_object" });
  });
});
