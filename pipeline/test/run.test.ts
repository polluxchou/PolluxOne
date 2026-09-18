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
});
