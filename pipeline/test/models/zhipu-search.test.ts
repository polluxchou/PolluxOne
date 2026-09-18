// pipeline/test/models/zhipu-search.test.ts
import { describe, expect, it, vi } from "vitest";
import { TokenLedger } from "../../src/models/ledger.js";
import {
  CNY_PER_USD,
  MAX_QUERY_CHARS,
  ZHIPU_SEARCH_URL,
  ZhipuSearchClient,
  collectZhipuResults,
  searchCostCents,
} from "../../src/models/zhipu-search.js";

const reply = (searchResult: unknown) =>
  new Response(JSON.stringify({ id: "x", created: 1, search_result: searchResult }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });

describe("collectZhipuResults", () => {
  it("从 search_result 里收 link", () => {
    const urls = collectZhipuResults([
      { title: "A", link: "https://a.com/1", media: "甲媒体" },
      { title: "B", link: "https://b.com/2", media: "乙媒体" },
    ]);
    expect(urls).toEqual(["https://a.com/1", "https://b.com/2"]);
  });

  it("去重，保持首次出现的顺序", () => {
    const urls = collectZhipuResults([
      { link: "https://a.com/1" },
      { link: "https://b.com/2" },
      { link: "https://a.com/1" },
      { link: "https://c.com/3" },
    ]);
    expect(urls).toEqual(["https://a.com/1", "https://b.com/2", "https://c.com/3"]);
  });

  it("没有 link 的条目跳过，不塞 undefined 进 URL 列表", () => {
    const urls = collectZhipuResults([
      { title: "只有标题没有链接" },
      { link: "" },
      { link: "https://a.com/1" },
    ]);
    expect(urls).toEqual(["https://a.com/1"]);
  });

  it("search_result 整个缺失时返回空数组——没搜到不是崩溃", () => {
    expect(collectZhipuResults(undefined)).toEqual([]);
    expect(collectZhipuResults(null)).toEqual([]);
    // 出错时回包里这个字段可能根本不是数组
    expect(collectZhipuResults({ error: "quota" })).toEqual([]);
  });

  it("空数组就是空结果", () => {
    expect(collectZhipuResults([])).toEqual([]);
  });
});

describe("searchCostCents", () => {
  it("按档位定价，与返回多少条结果无关", () => {
    // 0.01 元/次，按 CNY_PER_USD 折成美分
    expect(searchCostCents("search_std")).toBeCloseTo((0.01 / CNY_PER_USD) * 100, 9);
    expect(searchCostCents("search_pro")).toBeCloseTo(searchCostCents("search_std") * 3, 9);
  });

  it("sogou / quark 是最贵的一档", () => {
    expect(searchCostCents("search_pro_sogou")).toBeGreaterThan(searchCostCents("search_pro"));
    expect(searchCostCents("search_pro_quark")).toBeCloseTo(
      searchCostCents("search_pro_sogou"),
      9,
    );
  });
});

describe("ZhipuSearchClient.findSources", () => {
  const client = (send: ReturnType<typeof vi.fn>, ledger = new TokenLedger(), config = {}) =>
    new ZhipuSearchClient("k", ledger, config, send);

  it("打到 web_search 端点，带 Bearer", async () => {
    const send = vi.fn().mockResolvedValue(reply([{ link: "https://a.com/1" }]));
    const urls = await client(send).findSources("央行降准");

    expect(urls).toEqual(["https://a.com/1"]);
    expect(send.mock.calls[0]![0]).toBe(ZHIPU_SEARCH_URL);
    const init = send.mock.calls[0]![1] as RequestInit;
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer k");
    expect(init.method).toBe("POST");
  });

  it("默认走最便宜的 search_std，近一周，20 条", async () => {
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send).findSources("央行降准");
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);

    expect(body.search_engine).toBe("search_std");
    // 一年前的报道对一条刚发生的新闻没有意义，还会污染独立源计数
    expect(body.search_recency_filter).toBe("oneWeek");
    expect(body.count).toBe(20);
  });

  it("档位和条数可配置", async () => {
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send, new TokenLedger(), {
      engine: "search_pro",
      count: 5,
      recency: "oneDay",
    }).findSources("央行降准");
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);

    expect(body.search_engine).toBe("search_pro");
    expect(body.count).toBe(5);
    expect(body.search_recency_filter).toBe("oneDay");
  });

  it("search_query 截断到 70 字符——文档写明了上限", async () => {
    const send = vi.fn().mockResolvedValue(reply([]));
    const long = "央".repeat(200);
    await client(send).findSources(long);
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);

    expect(body.search_query).toHaveLength(MAX_QUERY_CHARS);
    expect(body.search_query).toBe(long.slice(0, MAX_QUERY_CHARS));
  });

  it("短标题原样传，不补齐也不改写", async () => {
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send).findSources("央行降准 0.5 个百分点");
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);
    expect(body.search_query).toBe("央行降准 0.5 个百分点");
  });

  it("按次记账：一次调用一笔，和结果条数无关", async () => {
    const ledger = new TokenLedger();
    const send = vi
      .fn()
      .mockResolvedValue(reply([{ link: "https://a.com/1" }, { link: "https://b.com/2" }]));
    await client(send, ledger).findSources("央行降准");

    expect(ledger.totalCostCents()).toBeCloseTo(searchCostCents("search_std"), 9);
    // 搜索不产生 token，账本里的 token 数一个都不许动
    expect(ledger.totals()).toEqual({ inputTokens: 0, outputTokens: 0, reasoningTokens: 0 });
    expect(ledger.byStage().search!.flatCostCents).toBeCloseTo(
      searchCostCents("search_std"),
      9,
    );
  });

  it("搜到零条也照样计费——这一次是真花了钱的", async () => {
    const ledger = new TokenLedger();
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send, ledger).findSources("查无此事");
    expect(ledger.totalCostCents()).toBeCloseTo(searchCostCents("search_std"), 9);
  });

  it("贵的档位记贵的价", async () => {
    const ledger = new TokenLedger();
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send, ledger, { engine: "search_pro_quark" }).findSources("央行降准");
    expect(ledger.totalCostCents()).toBeCloseTo(searchCostCents("search_pro_quark"), 9);
  });

  it("重试掉的 429 不计费，只有拿到 200 的那一次算钱", async () => {
    const ledger = new TokenLedger();
    const send = vi
      .fn()
      .mockResolvedValueOnce(new Response("busy", { status: 429 }))
      .mockResolvedValueOnce(reply([{ link: "https://a.com/1" }]));
    const urls = await new ZhipuSearchClient("k", ledger, {}, send).findSources("央行降准");

    expect(urls).toEqual(["https://a.com/1"]);
    expect(send).toHaveBeenCalledTimes(2);
    expect(ledger.totalCostCents()).toBeCloseTo(searchCostCents("search_std"), 9);
  });

  it("401 这类不会因为重试而改变的错直接抛，也不记账", async () => {
    const ledger = new TokenLedger();
    const send = vi.fn().mockResolvedValue(new Response("bad key", { status: 401 }));
    await expect(
      new ZhipuSearchClient("k", ledger, {}, send).findSources("央行降准"),
    ).rejects.toThrow(/401/);
    expect(send).toHaveBeenCalledTimes(1);
    expect(ledger.totalCostCents()).toBe(0);
  });
});
