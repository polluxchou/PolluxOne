// pipeline/test/models/zhipu-search.test.ts
import { describe, expect, it, vi } from "vitest";
import { TokenLedger } from "../../src/models/ledger.js";
import {
  DEFAULT_BLOCKED_DOMAINS,
  MAX_QUERY_CHARS,
  ZHIPU_SEARCH_URL,
  ZhipuSearchClient,
  ageInDays,
  collectZhipuResults,
  filterUsableItems,
  isBlockedDomain,
  parsePublishDate,
  searchCostCents,
} from "../../src/models/zhipu-search.js";

const reply = (searchResult: unknown) =>
  new Response(JSON.stringify({ id: "x", created: 1, search_result: searchResult }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });

/** 时间基准全程写死：过滤要按发布日期算，跑测试的日子不该影响结果。 */
const NOW = new Date("2026-09-18T03:00:00Z");
/** 实测回包里的新鲜日期长这样（横杠）。 */
const FRESH = "2026-09-16";
/** 实测回包里 35 条旧闻长这样（斜杠）。 */
const STALE = "2025/05/15";

const opts = (over: Partial<Parameters<typeof filterUsableItems>[1]> = {}) => ({
  now: NOW,
  maxAgeDays: 7,
  blockedDomains: DEFAULT_BLOCKED_DOMAINS,
  ...over,
});

describe("parsePublishDate", () => {
  it("横杠和斜杠两种格式都认——实测同一次响应里混用", () => {
    expect(parsePublishDate("2026-09-16")).toBe(Date.UTC(2026, 8, 16));
    expect(parsePublishDate("2025/05/15")).toBe(Date.UTC(2025, 4, 15));
  });

  it("不带前导零的月日也认", () => {
    expect(parsePublishDate("2026-9-6")).toBe(Date.UTC(2026, 8, 6));
  });

  it("按 UTC 解析，不看跑测试这台机器的时区", () => {
    // new Date("2025/05/15") 会按本地时区解析，和 "2025-05-15" 差出半天。
    expect(parsePublishDate("2025/05/15")).toBe(parsePublishDate("2025-05-15"));
  });

  it("带时间的也认，日期部分说了算", () => {
    expect(parsePublishDate("2026-09-16 08:30:00")).toBe(Date.UTC(2026, 8, 16));
    expect(parsePublishDate("2026-09-16T08:30:00Z")).toBe(Date.UTC(2026, 8, 16));
  });

  it("解析不了的一律 null——当作日期缺失处理", () => {
    expect(parsePublishDate("")).toBeNull();
    expect(parsePublishDate("昨天")).toBeNull();
    expect(parsePublishDate("2026-09")).toBeNull();
    expect(parsePublishDate(undefined)).toBeNull();
    expect(parsePublishDate(null)).toBeNull();
    expect(parsePublishDate(20260916)).toBeNull();
  });

  it("不存在的日期不许被 Date.UTC 默默进位", () => {
    // Date.UTC(2026, 1, 31) 会变成 3 月 3 日——那是个凭空捏造的发布日期。
    expect(parsePublishDate("2026-02-31")).toBeNull();
    expect(parsePublishDate("2026-13-01")).toBeNull();
  });
});

describe("ageInDays", () => {
  it("按整天算，同一天是 0 天", () => {
    expect(ageInDays(Date.UTC(2026, 8, 18), NOW)).toBe(0);
    expect(ageInDays(Date.UTC(2026, 8, 16), NOW)).toBe(2);
    expect(ageInDays(Date.UTC(2025, 4, 15), NOW)).toBe(491);
  });

  it("未来的日期是负数", () => {
    expect(ageInDays(Date.UTC(2026, 8, 19), NOW)).toBe(-1);
  });

  it("时间基准是传进来的，不是今天", () => {
    const later = new Date("2026-10-18T00:00:00Z");
    expect(ageInDays(Date.UTC(2026, 8, 18), later)).toBe(30);
  });
});

describe("isBlockedDomain", () => {
  it("百科 / 维基 / 知乎默认拦掉", () => {
    expect(isBlockedDomain("https://baike.baidu.com/item/x", DEFAULT_BLOCKED_DOMAINS)).toBe(true);
    expect(isBlockedDomain("https://zh.wikipedia.org/wiki/x", DEFAULT_BLOCKED_DOMAINS)).toBe(true);
    expect(isBlockedDomain("https://www.zhihu.com/question/1", DEFAULT_BLOCKED_DOMAINS)).toBe(true);
  });

  it("新闻站照过", () => {
    expect(isBlockedDomain("https://www.yicai.com/news/1.html", DEFAULT_BLOCKED_DOMAINS)).toBe(
      false,
    );
    // 同一家的新闻域名不该被百科那条连坐
    expect(isBlockedDomain("https://news.baidu.com/x", DEFAULT_BLOCKED_DOMAINS)).toBe(false);
  });

  it("按域名边界匹配，不做子串匹配", () => {
    expect(isBlockedDomain("https://notzhihu.com/a", DEFAULT_BLOCKED_DOMAINS)).toBe(false);
    expect(isBlockedDomain("https://zhihu.com.evil.cn/a", DEFAULT_BLOCKED_DOMAINS)).toBe(false);
  });

  it("URL 解析不了就当命中——用不了的东西不留", () => {
    expect(isBlockedDomain("not a url", DEFAULT_BLOCKED_DOMAINS)).toBe(true);
  });

  it("黑名单是可配置的判断，不是铁律", () => {
    expect(isBlockedDomain("https://baike.baidu.com/item/x", [])).toBe(false);
    expect(isBlockedDomain("https://a.com/1", ["a.com"])).toBe(true);
  });
});

describe("filterUsableItems", () => {
  it("窗口内的留下", () => {
    const kept = filterUsableItems(
      [{ link: "https://a.com/1", publish_date: FRESH }],
      opts(),
    );
    expect(kept.map((i) => i.link)).toEqual(["https://a.com/1"]);
  });

  it("超出窗口的旧闻丢掉——引擎的 recency 不起作用，这一关只能自己把", () => {
    const kept = filterUsableItems(
      [
        { link: "https://a.com/1", publish_date: FRESH },
        { link: "https://b.com/2", publish_date: STALE },
        { link: "https://c.com/3", publish_date: "2026-09-01" },
      ],
      opts(),
    );
    expect(kept.map((i) => i.link)).toEqual(["https://a.com/1"]);
  });

  it("窗口边界上的留下，再早一天就丢", () => {
    const items = [
      { link: "https://a.com/1", publish_date: "2026-09-11" }, // 7 天
      { link: "https://b.com/2", publish_date: "2026-09-10" }, // 8 天
    ];
    expect(filterUsableItems(items, opts()).map((i) => i.link)).toEqual(["https://a.com/1"]);
  });

  it("窗口可配置", () => {
    const items = [{ link: "https://a.com/1", publish_date: "2026-08-20" }];
    expect(filterUsableItems(items, opts())).toEqual([]);
    expect(filterUsableItems(items, opts({ maxAgeDays: 60 })).map((i) => i.link)).toEqual([
      "https://a.com/1",
    ]);
  });

  it("publish_date 缺失或解析不出来的一律丢掉", () => {
    const kept = filterUsableItems(
      [
        { link: "https://a.com/1" },
        { link: "https://b.com/2", publish_date: "" },
        { link: "https://c.com/3", publish_date: "近日" },
        { link: "https://d.com/4", publish_date: FRESH },
      ],
      opts(),
    );
    // 少一个源只是少一个源；留一条日期不明的旧闻会让 independence 虚高。
    expect(kept.map((i) => i.link)).toEqual(["https://d.com/4"]);
  });

  it("差一天的未来日期留着——publish_date 没有时区", () => {
    const kept = filterUsableItems(
      [
        { link: "https://a.com/1", publish_date: "2026-09-19" },
        { link: "https://b.com/2", publish_date: "2026-10-01" },
      ],
      opts(),
    );
    expect(kept.map((i) => i.link)).toEqual(["https://a.com/1"]);
  });

  it("百科页丢掉：它不是新闻报道，不能拿来印证一条新闻", () => {
    const kept = filterUsableItems(
      [
        { link: "https://baike.baidu.com/item/存款准备金率", publish_date: FRESH },
        { link: "https://zh.wikipedia.org/wiki/x", publish_date: FRESH },
        { link: "https://www.zhihu.com/question/1", publish_date: FRESH },
        { link: "https://www.yicai.com/news/1.html", publish_date: FRESH },
      ],
      opts(),
    );
    expect(kept.map((i) => i.link)).toEqual(["https://www.yicai.com/news/1.html"]);
  });

  it("没有 link 的条目丢掉——std / pro 的 link 实测全是空字符串", () => {
    const kept = filterUsableItems(
      [
        // search_std / search_pro 的真实形状：只有摘要，没有任何 URL
        { title: "央行降准", content: "……", link: "", media: "", icon: "", publish_date: FRESH },
        { title: "只有标题", publish_date: FRESH },
        { link: "https://a.com/1", publish_date: FRESH },
      ],
      opts(),
    );
    expect(kept.map((i) => i.link)).toEqual(["https://a.com/1"]);
  });

  it("search_result 整个缺失或不是数组时返回空数组", () => {
    expect(filterUsableItems(undefined, opts())).toEqual([]);
    expect(filterUsableItems(null, opts())).toEqual([]);
    expect(filterUsableItems({ error: "quota" }, opts())).toEqual([]);
    expect(filterUsableItems([], opts())).toEqual([]);
  });

  it("数组里混着 null 也不崩", () => {
    expect(filterUsableItems([null, undefined, 42], opts())).toEqual([]);
  });
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
    // 0.01 元/次 = 1 分/次。账本就是人民币分，中间没有汇率可折。
    expect(searchCostCents("search_std")).toBe(1);
    expect(searchCostCents("search_pro")).toBeCloseTo(searchCostCents("search_std") * 3, 9);
  });

  it("按次计费是整数分——浮点尾巴不许进账本", () => {
    for (const engine of [
      "search_std",
      "search_pro",
      "search_pro_sogou",
      "search_pro_quark",
    ] as const) {
      expect(Number.isInteger(searchCostCents(engine))).toBe(true);
    }
  });

  it("sogou / quark 是最贵的一档", () => {
    expect(searchCostCents("search_pro_sogou")).toBeGreaterThan(searchCostCents("search_pro"));
    expect(searchCostCents("search_pro_quark")).toBeCloseTo(
      searchCostCents("search_pro_sogou"),
      9,
    );
  });

  it("默认档位 0.05 元/次 = 5 分——贵四倍，但只有它给 link", () => {
    expect(searchCostCents("search_pro_sogou")).toBe(5);
  });
});

describe("ZhipuSearchClient.findSources", () => {
  const client = (send: ReturnType<typeof vi.fn>, ledger = new TokenLedger(), config = {}) =>
    new ZhipuSearchClient("k", ledger, config, send);

  it("打到 web_search 端点，带 Bearer", async () => {
    const send = vi.fn().mockResolvedValue(reply([{ link: "https://a.com/1", publish_date: FRESH }]));
    const urls = await client(send).findSources("央行降准", NOW);

    expect(urls).toEqual(["https://a.com/1"]);
    expect(send.mock.calls[0]![0]).toBe(ZHIPU_SEARCH_URL);
    const init = send.mock.calls[0]![1] as RequestInit;
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer k");
    expect(init.method).toBe("POST");
  });

  it("默认走 search_pro_sogou——实测只有它返回 link", async () => {
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send).findSources("央行降准", NOW);
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);

    expect(body.search_engine).toBe("search_pro_sogou");
  });

  it("不传 count / search_recency_filter——实测都被无视", async () => {
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send, new TokenLedger(), { maxResults: 5, maxAgeDays: 1 }).findSources(
      "央行降准",
      NOW,
    );
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);

    // 传一个不起作用的参数，只会让人以为它起作用了
    expect(body.count).toBeUndefined();
    expect(body.search_recency_filter).toBeUndefined();
    expect(Object.keys(body).sort()).toEqual(["search_engine", "search_query"]);
  });

  it("档位可配置", async () => {
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send, new TokenLedger(), { engine: "search_pro" }).findSources("央行降准", NOW);
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);

    expect(body.search_engine).toBe("search_pro");
  });

  it("先过滤再截断：前几条全是百科和旧闻时也不会截出个空手", async () => {
    const send = vi.fn().mockResolvedValue(
      reply([
        { link: "https://baike.baidu.com/item/x", publish_date: FRESH },
        { link: "https://old.com/1", publish_date: STALE },
        { link: "https://a.com/1", publish_date: FRESH },
        { link: "https://b.com/2", publish_date: FRESH },
        { link: "https://c.com/3", publish_date: FRESH },
      ]),
    );
    const urls = await client(send, new TokenLedger(), { maxResults: 2 }).findSources(
      "央行降准",
      NOW,
    );
    expect(urls).toEqual(["https://a.com/1", "https://b.com/2"]);
  });

  it("截断在过滤之后，条数由调用方定", async () => {
    const items = Array.from({ length: 50 }, (_, i) => ({
      link: `https://n${i}.com/1`,
      publish_date: FRESH,
    }));
    // 每次调用现造一个 Response：Response 的 body 只能读一次。
    const send = vi.fn().mockImplementation(async () => reply(items));

    // 引擎无视 count：传 5 也照样回 50 条，截断是我们自己做的
    expect(
      await client(send, new TokenLedger(), { maxResults: 5 }).findSources("央行降准", NOW),
    ).toHaveLength(5);
    expect(await client(send).findSources("央行降准", NOW)).toHaveLength(20);
  });

  it("实测那 50 条的形状：百科 + 旧闻 + 缺日期，剩下的才是能用的", async () => {
    const send = vi.fn().mockResolvedValue(
      reply([
        ...Array.from({ length: 7 }, (_, i) => ({
          link: `https://baike.baidu.com/item/${i}`,
          publish_date: FRESH,
        })),
        ...Array.from({ length: 35 }, (_, i) => ({
          link: `https://old${i}.com/1`,
          publish_date: STALE,
        })),
        ...Array.from({ length: 4 }, (_, i) => ({ link: `https://nodate${i}.com/1` })),
        { link: "https://a.com/1", publish_date: FRESH },
        { link: "https://b.com/2", publish_date: "2026-09-18" },
      ]),
    );
    const urls = await client(send).findSources("央行降准", NOW);
    expect(urls).toEqual(["https://a.com/1", "https://b.com/2"]);
  });

  it("时间基准可注入：同一份数据换个基准日就全过期", async () => {
    const send = vi.fn().mockResolvedValue(reply([{ link: "https://a.com/1", publish_date: FRESH }]));
    const later = new Date("2026-12-01T00:00:00Z");
    expect(await client(send).findSources("央行降准", later)).toEqual([]);
  });

  it("黑名单可配置", async () => {
    const send = vi
      .fn()
      .mockResolvedValue(reply([{ link: "https://baike.baidu.com/item/x", publish_date: FRESH }]));
    const urls = await client(send, new TokenLedger(), { blockedDomains: [] }).findSources(
      "央行降准",
      NOW,
    );
    expect(urls).toEqual(["https://baike.baidu.com/item/x"]);
  });

  it("search_query 截断到 70 字符——文档写明了上限", async () => {
    const send = vi.fn().mockResolvedValue(reply([]));
    const long = "央".repeat(200);
    await client(send).findSources(long, NOW);
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);

    expect(body.search_query).toHaveLength(MAX_QUERY_CHARS);
    expect(body.search_query).toBe(long.slice(0, MAX_QUERY_CHARS));
  });

  it("短标题原样传，不补齐也不改写", async () => {
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send).findSources("央行降准 0.5 个百分点", NOW);
    const body = JSON.parse((send.mock.calls[0]![1] as RequestInit).body as string);
    expect(body.search_query).toBe("央行降准 0.5 个百分点");
  });

  it("按次记账：一次调用一笔，和结果条数无关", async () => {
    const ledger = new TokenLedger();
    const send = vi.fn().mockResolvedValue(
      reply([
        { link: "https://a.com/1", publish_date: FRESH },
        { link: "https://b.com/2", publish_date: FRESH },
      ]),
    );
    await client(send, ledger).findSources("央行降准", NOW);

    expect(ledger.totalCostCents()).toBeCloseTo(searchCostCents("search_pro_sogou"), 9);
    // 搜索不产生 token，账本里的 token 数一个都不许动
    expect(ledger.totals()).toEqual({ inputTokens: 0, outputTokens: 0, reasoningTokens: 0 });
    expect(ledger.byStage().search!.flatCostCents).toBeCloseTo(
      searchCostCents("search_pro_sogou"),
      9,
    );
  });

  it("搜到零条也照样计费——这一次是真花了钱的", async () => {
    const ledger = new TokenLedger();
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send, ledger).findSources("查无此事", NOW);
    expect(ledger.totalCostCents()).toBeCloseTo(searchCostCents("search_pro_sogou"), 9);
  });

  it("全被过滤掉也照样计费——钱花在那一次请求上，不在结果上", async () => {
    const ledger = new TokenLedger();
    const send = vi
      .fn()
      .mockResolvedValue(reply([{ link: "https://old.com/1", publish_date: STALE }]));
    expect(await client(send, ledger).findSources("央行降准", NOW)).toEqual([]);
    expect(ledger.totalCostCents()).toBeCloseTo(searchCostCents("search_pro_sogou"), 9);
  });

  it("贵的档位记贵的价", async () => {
    const ledger = new TokenLedger();
    const send = vi.fn().mockResolvedValue(reply([]));
    await client(send, ledger, { engine: "search_pro_quark" }).findSources("央行降准", NOW);
    expect(ledger.totalCostCents()).toBeCloseTo(searchCostCents("search_pro_quark"), 9);
  });

  it("重试掉的 429 不计费，只有拿到 200 的那一次算钱", async () => {
    const ledger = new TokenLedger();
    const send = vi
      .fn()
      .mockResolvedValueOnce(new Response("busy", { status: 429 }))
      .mockResolvedValueOnce(reply([{ link: "https://a.com/1", publish_date: FRESH }]));
    const urls = await new ZhipuSearchClient("k", ledger, {}, send).findSources("央行降准", NOW);

    expect(urls).toEqual(["https://a.com/1"]);
    expect(send).toHaveBeenCalledTimes(2);
    expect(ledger.totalCostCents()).toBeCloseTo(searchCostCents("search_pro_sogou"), 9);
  });

  it("401 这类不会因为重试而改变的错直接抛，也不记账", async () => {
    const ledger = new TokenLedger();
    const send = vi.fn().mockResolvedValue(new Response("bad key", { status: 401 }));
    await expect(
      new ZhipuSearchClient("k", ledger, {}, send).findSources("央行降准", NOW),
    ).rejects.toThrow(/401/);
    expect(send).toHaveBeenCalledTimes(1);
    expect(ledger.totalCostCents()).toBe(0);
  });
});
