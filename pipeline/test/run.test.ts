import { describe, expect, it, vi } from "vitest";
import { runPipeline, type Ports } from "../src/run.js";

const article = (body: string, url = "https://a.com/1") => ({ title: "t", url, body });

const OPTIONS = { durationSec: 60, register: 0, charsPerSecond: 5 };

/** 三家都在说的同一组事实——同一条 claim 要靠它们才攒得到三个独立源。 */
const SHARED = ["降准 0.5 个百分点", "新增贷款 1 万亿元", "存款利率下调 10 个基点"];

// 各家独有的一大段。必须**够长且不重复**：正文 5-gram 相似度超过 0.5 时
// groupSources 会把三篇判成同一份稿的转载，independence 掉回 1，
// 这几条测试就会在测另一件事了。
const FILLER_A = "甲社记者在发布会现场逐条记录了整场问答的全部细节与背景说明材料。";
const FILLER_B = "乙报编辑部连夜整理了多位经济学家对本轮政策的不同解读与评论摘要。";
const FILLER_C = "丙台演播室邀请三位嘉宾从银行体系流动性角度展开长时间的讨论分析。";

const body = (filler: string) => `${filler}${SHARED.join("。")}。`;

const sharedFacts = (source: { id: string }) =>
  Promise.resolve(
    SHARED.map((text, i) => ({
      id: `${source.id}-f${i}`,
      sourceId: source.id,
      text,
      quote: text,
    })),
  );

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
    const result = await runPipeline("https://a.com/1", OPTIONS, ports({ draftScript }));
    expect(result.status).toBe("insufficient");
    expect(draftScript).not.toHaveBeenCalled();
  });

  it("被逐字校验拒掉的 fact 不进入后面的阶段", async () => {
    const extractFacts = vi.fn().mockResolvedValue([
      { id: "s0-f0", sourceId: "s0", text: "转述的", quote: "这段原文里没有" },
    ]);
    const result = await runPipeline("https://a.com/1", OPTIONS, ports({ extractFacts }));
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
      OPTIONS,
      ports({
        readArticle,
        findSources: vi.fn().mockResolvedValue(["https://b.com/1", "https://c.com/1"]),
      }),
    );
    expect(result.sources).toHaveLength(2);
  });

  // —— 下面几条不在计划里，是照着计划的两条排序理由往下推出来的 ——

  it("信源够了但 strong claim 不够，同样不进成稿", async () => {
    // 三个源各说各的一件事：每条 claim 只有一个独立源，全是 weak。
    // 源数这一关过了，稿子却依然不敢播——最贵的那一步照样不该花。
    const draftScript = vi.fn();
    const result = await runPipeline(
      "https://a.com/1",
      OPTIONS,
      ports({
        readArticle: vi
          .fn()
          .mockResolvedValueOnce(article("甲报道：降准 0.5 个百分点。", "https://a.com/1"))
          .mockResolvedValueOnce(article("乙报道：新增贷款 1 万亿元。", "https://b.com/1"))
          .mockResolvedValueOnce(article("丙报道：存款利率下调 10 个基点。", "https://c.com/1")),
        findSources: vi.fn().mockResolvedValue(["https://b.com/1", "https://c.com/1"]),
        extractFacts: vi.fn().mockImplementation((source: { id: string; body: string }) =>
          Promise.resolve([
            { id: `${source.id}-f0`, sourceId: source.id, text: source.body, quote: source.body },
          ]),
        ),
        draftScript,
      }),
    );
    expect(result.status).toBe("insufficient");
    expect(draftScript).not.toHaveBeenCalled();
  });

  it("三个独立源都说同一件事时才成稿，并且稿子挂得上信源", async () => {
    // 正文各自带一大段独有内容，否则三篇会被 groupSources 判成同一份稿的转载，
    // independence 就掉回 1，这条测试也就测不到它想测的东西了。
    const readArticle = vi
      .fn()
      .mockResolvedValueOnce(article(body(FILLER_A), "https://a.com/1"))
      .mockResolvedValueOnce(article(body(FILLER_B), "https://b.com/1"))
      .mockResolvedValueOnce(article(body(FILLER_C), "https://c.com/1"));

    const extractFacts = vi.fn().mockImplementation(sharedFacts);

    const draftScript = vi.fn().mockImplementation((claims: { id: string }[]) =>
      Promise.resolve([
        { text: "先说一句钩子。", kind: "transition", claimIds: [] },
        ...claims.map((c) => ({ text: `${c.id} 的事实句。`, kind: "fact", claimIds: [c.id] })),
      ]),
    );

    const result = await runPipeline(
      "https://a.com/1",
      OPTIONS,
      ports({
        readArticle,
        findSources: vi.fn().mockResolvedValue(["https://b.com/1", "https://c.com/1"]),
        extractFacts,
        draftScript,
      }),
    );

    expect(result.status).toBe("ok");
    expect(result.sources).toHaveLength(3);
    if (result.status !== "ok") return;
    expect(result.core.selection.verdict).toBe("ok");
    expect(result.core.claims.every((c) => c.independence === 3)).toBe(true);
    expect(result.core.bind.ok).toBe(true);
  });

  it("成稿只跑一次——最贵的那一步不许因为要重算而调两遍", async () => {
    // 实现里 buildBrief 调了两次（一次拿 claims 去成稿，一次带稿子回来绑定），
    // 内核是纯函数所以随便调；模型不是，所以钉住它只被调一次。
    const draftScript = vi.fn().mockResolvedValue([
      { text: "先说一句钩子。", kind: "transition", claimIds: [] },
    ]);

    await runPipeline(
      "https://a.com/1",
      OPTIONS,
      ports({
        readArticle: vi
          .fn()
          .mockResolvedValueOnce(article(body(FILLER_A), "https://a.com/1"))
          .mockResolvedValueOnce(article(body(FILLER_B), "https://b.com/1"))
          .mockResolvedValueOnce(article(body(FILLER_C), "https://c.com/1")),
        findSources: vi.fn().mockResolvedValue(["https://b.com/1", "https://c.com/1"]),
        extractFacts: vi.fn().mockImplementation(sharedFacts),
        draftScript,
      }),
    );

    expect(draftScript).toHaveBeenCalledTimes(1);
  });

  it("同一家媒体的多个页面在抓取之前就被收敛掉，不白花抓取的钱", async () => {
    const readArticle = vi.fn().mockResolvedValue(article("正文。", "https://a.com/1"));
    await runPipeline(
      "https://a.com/1",
      OPTIONS,
      ports({
        readArticle,
        // 第一条和原文同一家，第二三条同属 b.com——只该剩一条候选。
        findSources: vi
          .fn()
          .mockResolvedValue(["https://a.com/2", "https://b.com/1", "https://b.com/2"]),
      }),
    );
    expect(readArticle).toHaveBeenCalledTimes(2);
  });

  // —— ⑤ 的语义那一半：模型判出来的冲突对到底有没有进内核 ——

  /** 五件事，多到杀掉一对之后还剩得下三条 strong。 */
  const FIVE = [
    ...SHARED,
    "公开市场单日净投放三千亿元",
    "七天逆回购利率按兵不动",
  ];

  const fiveBody = (filler: string) => `${filler}${FIVE.join("。")}。`;

  const fiveFacts = (source: { id: string }) =>
    Promise.resolve(
      FIVE.map((text, i) => ({ id: `${source.id}-f${i}`, sourceId: source.id, text, quote: text })),
    );

  /** 三家独立媒体，正文各自带一段独有内容，否则会被判成同一份稿的转载。 */
  const threeOutlets = (make: (filler: string) => string) =>
    vi
      .fn()
      .mockResolvedValueOnce(article(make(FILLER_A), "https://a.com/1"))
      .mockResolvedValueOnce(article(make(FILLER_B), "https://b.com/1"))
      .mockResolvedValueOnce(article(make(FILLER_C), "https://c.com/1"));

  it("模型判出来的冲突对进得了内核，成稿看到的就是标好的那一份", async () => {
    // 端口以前定义了却从没被调用过，判出来的对无处可去。没有这一条，把
    // findSemanticConflicts 的结果整个丢掉不会有任何测试变红——而那正是
    // 「官方否认降准」和「消息人士称降准已定」一起进稿的那个洞。
    const findSemanticConflicts = vi
      .fn()
      .mockImplementation((claims: { id: string }[]) =>
        Promise.resolve([[claims[0]!.id, claims[1]!.id]]),
      );

    // ⑦ 拿到的是 ⑥ 挑出来的那几条，里面不会有 conflicted。这里记下它看到的
    // 那一份，用来确认判冲突发生在成稿**之前**。
    const seenByDraft: { id: string; confidence: string }[] = [];
    const draftScript = vi
      .fn()
      .mockImplementation((claims: { id: string; confidence: string }[]) => {
        seenByDraft.push(...claims);
        return Promise.resolve([
          { text: "先说一句钩子。", kind: "transition", claimIds: [] },
          ...claims.map((c) => ({ text: `${c.id} 的事实句。`, kind: "fact", claimIds: [c.id] })),
        ]);
      });

    const result = await runPipeline(
      "https://a.com/1",
      OPTIONS,
      ports({
        readArticle: threeOutlets(fiveBody),
        findSources: vi.fn().mockResolvedValue(["https://b.com/1", "https://c.com/1"]),
        extractFacts: vi.fn().mockImplementation(fiveFacts),
        findSemanticConflicts,
        draftScript,
      }),
    );

    expect(findSemanticConflicts).toHaveBeenCalledTimes(1);
    expect(result.status).toBe("ok");
    if (result.status !== "ok") return;

    // 这两条数字上完全看不出矛盾，只有模型判得出来。
    const conflicted = result.core.claims.filter((c) => c.confidence === "conflicted");
    expect(conflicted).toHaveLength(2);
    expect(conflicted[0]!.conflictsWith).toEqual([conflicted[1]!.id]);
    expect(conflicted[1]!.conflictsWith).toEqual([conflicted[0]!.id]);

    // 成稿必须在判冲突**之后**才拿到 claims：⑦ 若看到的是判冲突之前的那一份，
    // 打架的两条会一起写进稿子，这一层就等于没做。以前是把全部 claim（含标成
    // conflicted 的）交给 ⑦，靠它自己挑；现在交的是 ⑥ 挑完的 picked，所以
    // 「标好了」体现为**它一条 conflicted 都看不到**。
    expect(seenByDraft.filter((c) => c.confidence === "conflicted")).toHaveLength(0);
    expect(seenByDraft.map((c) => c.id)).toEqual(result.core.selection.picked);
    expect(result.core.bind.ok).toBe(true);
  });

  it("成稿拿到的就是 ⑥ 挑出来的那几条，不是全部非 conflicted 的", async () => {
    // 实跑证据：气候那篇 picked 是 5 条，成稿却拿到全部 14 条、写了 15 句——
    // iOS 阶段条上「选点 5 条」对「成稿 15 句」对不上，是 ⑥ 的产物被扔了。
    // 这里 60 秒 → factSlots 是 3，而 claim 有 5 条，名额比 claim 少，
    // 「交的是 picked」和「交的是全部」才区分得开。
    const seenByDraft: string[] = [];
    const draftScript = vi.fn().mockImplementation((claims: { id: string }[]) => {
      seenByDraft.push(...claims.map((c) => c.id));
      return Promise.resolve([
        { text: "先说一句钩子。", kind: "transition", claimIds: [] },
        ...claims.map((c) => ({ text: `${c.id} 的事实句。`, kind: "fact", claimIds: [c.id] })),
      ]);
    });

    const result = await runPipeline(
      "https://a.com/1",
      OPTIONS,
      ports({
        readArticle: threeOutlets(fiveBody),
        findSources: vi.fn().mockResolvedValue(["https://b.com/1", "https://c.com/1"]),
        extractFacts: vi.fn().mockImplementation(fiveFacts),
        draftScript,
      }),
    );

    expect(result.status).toBe("ok");
    if (result.status !== "ok") return;

    const picked = result.core.selection.picked;
    expect(picked).toHaveLength(result.core.estimate.factSlots);
    expect(picked.length).toBeLessThan(result.core.claims.length);
    // 顺序也照 picked 的来：那是 ⑥ 排好的呈现顺序，不是归并的下标顺序。
    expect(seenByDraft).toEqual(picked);
  });

  it("语义冲突把最后几条 strong 打掉时，最贵的那一步照样不花", async () => {
    // 三条 claim 杀掉一对只剩一条 strong——「敢说这条别播」在语义这一层
    // 同样成立，而且必须在成稿之前生效。
    const draftScript = vi.fn();
    const result = await runPipeline(
      "https://a.com/1",
      OPTIONS,
      ports({
        readArticle: threeOutlets(body),
        findSources: vi.fn().mockResolvedValue(["https://b.com/1", "https://c.com/1"]),
        extractFacts: vi.fn().mockImplementation(sharedFacts),
        findSemanticConflicts: vi
          .fn()
          .mockImplementation((claims: { id: string }[]) =>
            Promise.resolve([[claims[0]!.id, claims[1]!.id]]),
          ),
        draftScript,
      }),
    );

    expect(result.status).toBe("insufficient");
    expect(draftScript).not.toHaveBeenCalled();
  });

  it("本来就攒不出三条 strong 时连问都不问——冲突只会让 strong 更少", async () => {
    // 判冲突也是一次模型调用。此刻就出不了稿的，带上语义冲突之后同样出不了。
    const findSemanticConflicts = vi.fn().mockResolvedValue([]);
    await runPipeline(
      "https://a.com/1",
      OPTIONS,
      ports({
        readArticle: vi
          .fn()
          .mockResolvedValueOnce(article("甲报道：降准 0.5 个百分点。", "https://a.com/1"))
          .mockResolvedValueOnce(article("乙报道：新增贷款 1 万亿元。", "https://b.com/1"))
          .mockResolvedValueOnce(article("丙报道：存款利率下调 10 个基点。", "https://c.com/1")),
        findSources: vi.fn().mockResolvedValue(["https://b.com/1", "https://c.com/1"]),
        extractFacts: vi.fn().mockImplementation((source: { id: string; body: string }) =>
          Promise.resolve([
            { id: `${source.id}-f0`, sourceId: source.id, text: source.body, quote: source.body },
          ]),
        ),
        findSemanticConflicts,
      }),
    );
    expect(findSemanticConflicts).not.toHaveBeenCalled();
  });
});

// ——— 语速：⑦ 定靶用的那个数，必须和内核量长度用的是同一个 ———

describe("runPipeline 的语速", () => {
  const FILLERS = [FILLER_A, FILLER_B, FILLER_C];

  const threeOf = (make: (filler: string) => string, fillers = FILLERS) =>
    vi
      .fn()
      .mockResolvedValueOnce(article(make(fillers[0]!), "https://a.com/1"))
      .mockResolvedValueOnce(article(make(fillers[1]!), "https://b.com/1"))
      .mockResolvedValueOnce(article(make(fillers[2]!), "https://c.com/1"));

  /** 跑一遍，把 ⑦ 收到的第四个参数（语速）拿出来。 */
  async function rateSeenByDraft(
    options: { durationSec: number; register: number; charsPerSecond?: number },
    readArticle: ReturnType<typeof vi.fn>,
    extractFacts: ReturnType<typeof vi.fn>,
  ): Promise<{ rate: unknown; seconds: number }> {
    let rate: unknown;
    const draftScript = vi
      .fn()
      .mockImplementation((claims: { id: string }[], _d: number, _r: number, cps?: number) => {
        rate = cps;
        return Promise.resolve(
          claims.map((c) => ({ text: `${c.id} 的事实句。`, kind: "fact", claimIds: [c.id] })),
        );
      });

    const result = await runPipeline(
      "https://a.com/1",
      options,
      ports({
        readArticle,
        findSources: vi.fn().mockResolvedValue(["https://b.com/1", "https://c.com/1"]),
        extractFacts,
        draftScript,
      }),
    );
    if (result.status !== "ok") throw new Error(`本该出稿：${result.reason}`);
    return { rate, seconds: result.core.seconds };
  }

  it("用户的实测语速一路传到 ⑦，而且就是内核量长度用的那一个", async () => {
    // 靶子和尺子必须是同一个数：两处用两个数的话，「差了多少」本身就是假的。
    const { rate, seconds } = await rateSeenByDraft(
      { durationSec: 60, register: 0, charsPerSecond: 4 },
      threeOf(body),
      vi.fn().mockImplementation(sharedFacts),
    );
    expect(rate).toBe(4);
    // 三句「cN 的事实句。」= 3 × 6 个可朗读字，按 4 字/秒 算。
    expect(seconds).toBeCloseTo(18 / 4, 5);
  });

  it("没有实测语速时按 ① 抓回来的正文判语种——英文稿不会被按 5 字/秒 定靶", async () => {
    const EN = ["cut the ratio by half a point", "released one trillion yuan", "deposit rate down ten basis points"];
    const enBody = (filler: string) => `${filler} ${EN.join(". ")}.`;
    const enFacts = (source: { id: string }) =>
      Promise.resolve(
        EN.map((text, i) => ({ id: `${source.id}-f${i}`, sourceId: source.id, text, quote: text })),
      );

    const { rate } = await rateSeenByDraft(
      { durationSec: 60, register: 0 },
      threeOf(enBody, [
        "Reporters at the briefing wrote down every question and answer in careful detail today.",
        "The newsroom collected overnight commentary from several economists about this policy move.",
        "A studio panel of three guests discussed banking system liquidity at considerable length.",
      ]),
      vi.fn().mockImplementation(enFacts),
    );
    expect(rate).toBe(16);
  });

  it("中文正文不传语速时落到中文的默认值", async () => {
    const { rate } = await rateSeenByDraft(
      { durationSec: 60, register: 0 },
      threeOf(body),
      vi.fn().mockImplementation(sharedFacts),
    );
    expect(rate).toBe(5);
  });
});
