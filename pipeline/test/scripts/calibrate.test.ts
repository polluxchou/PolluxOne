// pipeline/test/scripts/calibrate.test.ts
//
// 全程离线：`runPipeline` 和账本都是从外面注进去的，这里喂的是已知用量的替身。
// 校准脚本本身要真跑才有数据，但它**怎么聚合、怎么对待失败**必须现在就钉住——
// 那两条正是最容易在真跑那天悄悄出错、而错了又看不出来的地方。
import { describe, expect, it } from "vitest";
import {
  ANCHORS,
  collectSamples,
  parseUrlList,
  type Anchor,
  type CalibrateDeps,
} from "../../scripts/calibrate.js";
import { estimateBrief } from "../../src/domain/estimate.js";
import { TokenLedger } from "../../src/models/ledger.js";

/**
 * 账本用真的。它本来就不联网、不花钱，而校准要校的恰恰是"从账本读出来的数"——
 * 换成手写的 stub 就等于把被测的那段算术自己抄了一遍。
 */
const MODEL = "deepseek-flash";

/** 一次典型的跑动在账本上留下的痕迹：抓取、抽取、成稿各记一笔。 */
function recordTypicalRun(ledger: TokenLedger): void {
  ledger.record("search", MODEL, { inputTokens: 1_000, outputTokens: 200 });
  ledger.record("extract", MODEL, { inputTokens: 8_000, outputTokens: 1_500, reasoningTokens: 900 });
  ledger.record("draft", MODEL, { inputTokens: 4_000, outputTokens: 2_000 });
}

function sumOfStages(byStage: Record<string, { inputTokens: number; outputTokens: number }>): number {
  return Object.values(byStage).reduce((sum, t) => sum + t.inputTokens + t.outputTokens, 0);
}

function deps(
  run: CalibrateDeps<TokenLedger>["run"],
): CalibrateDeps<TokenLedger> {
  return { createLedger: () => new TokenLedger(), run };
}

const ONE_ANCHOR: Anchor[] = [{ durationSec: 60, register: 0 }];

describe("collectSamples 的聚合", () => {
  it("actualTokens 等于各阶段之和", async () => {
    const samples = await collectSamples(
      ["https://a.example/1"],
      deps(async (_url, _anchor, ledger) => {
        recordTypicalRun(ledger);
        return "ok";
      }),
      ONE_ANCHOR,
    );

    expect(samples).toHaveLength(1);
    const sample = samples[0]!;
    expect(sample.actualTokens).toBe(sumOfStages(sample.byStage));
    expect(sample.actualTokens).toBe(1_000 + 200 + 8_000 + 1_500 + 4_000 + 2_000);
  });

  it("推理 token 不重复计入——它已经含在 outputTokens 里", async () => {
    const samples = await collectSamples(
      ["https://a.example/1"],
      deps(async (_url, _anchor, ledger) => {
        ledger.record("extract", MODEL, {
          inputTokens: 100,
          outputTokens: 259,
          reasoningTokens: 189,
        });
        return "ok";
      }),
      ONE_ANCHOR,
    );

    // 359，不是 548。多加那 189 会让实际用量虚高，回归出来的系数跟着虚高。
    expect(samples[0]!.actualTokens).toBe(359);
  });

  it("每条 URL 都跑满全部锚点，各自一条样本", async () => {
    const seen: Array<[string, number, number]> = [];
    const samples = await collectSamples(
      ["https://a.example/1", "https://b.example/2"],
      deps(async (url, anchor, ledger) => {
        seen.push([url, anchor.durationSec, anchor.register]);
        ledger.record("draft", MODEL, { inputTokens: 10, outputTokens: 10 });
        return "ok";
      }),
    );

    expect(samples).toHaveLength(2 * ANCHORS.length);
    expect(seen).toHaveLength(2 * ANCHORS.length);
    // 每条样本一本自己的账，不是全批共用一本。
    expect(samples.every((s) => s.actualTokens === 20)).toBe(true);
  });
});

describe("collectSamples 对没成稿的那些", () => {
  it("insufficient 的样本要留着，不能当作没跑过", async () => {
    const samples = await collectSamples(
      ["https://a.example/1"],
      deps(async (_url, _anchor, ledger) => {
        // 抓取和抽取都发生过，只是没走到成稿——钱一样花了。
        ledger.record("search", MODEL, { inputTokens: 1_000, outputTokens: 200 });
        ledger.record("extract", MODEL, { inputTokens: 8_000, outputTokens: 1_500 });
        return "insufficient";
      }),
      ONE_ANCHOR,
    );

    expect(samples).toHaveLength(1);
    expect(samples[0]!.status).toBe("insufficient");
    // 把它剔掉会让回归出来的估算系统性偏低，而偏低正是最危险的方向：
    // 用户余额不够却已经开跑。
    expect(samples[0]!.actualTokens).toBe(10_700);
    expect(samples[0]!.actualCostCents).toBeGreaterThan(0);
  });
});

describe("collectSamples 对跑挂的那些", () => {
  it("一条抛异常时记成 error 样本，后面的 URL 继续跑", async () => {
    const attempted: string[] = [];
    const samples = await collectSamples(
      ["https://ok.example/1", "https://boom.example/2", "https://ok.example/3"],
      deps(async (url, _anchor, ledger) => {
        attempted.push(url);
        // 抛之前已经烧掉的 token 一样要能读到。
        ledger.record("search", MODEL, { inputTokens: 500, outputTokens: 100 });
        if (url.includes("boom")) throw new Error("jina 502");
        ledger.record("draft", MODEL, { inputTokens: 1_000, outputTokens: 400 });
        return "ok";
      }),
      ONE_ANCHOR,
    );

    expect(attempted).toEqual([
      "https://ok.example/1",
      "https://boom.example/2",
      "https://ok.example/3",
    ]);
    expect(samples.map((s) => s.status)).toEqual(["ok", "error", "ok"]);
    expect(samples[1]!.error).toContain("jina 502");
    // 挂掉那条烧掉的 token 也进样本：它是真花出去的。
    expect(samples[1]!.actualTokens).toBe(600);
    expect(samples[2]!.actualTokens).toBe(2_000);
  });

  it("非 Error 抛出物也记得下来", async () => {
    const samples = await collectSamples(
      ["https://a.example/1"],
      deps(async () => {
        throw "字符串也能被 throw";
      }),
      ONE_ANCHOR,
    );

    expect(samples[0]!.status).toBe("error");
    expect(samples[0]!.error).toContain("字符串");
  });
});

describe("输出的形状", () => {
  it("回归那两条断言将来要读的字段都在", async () => {
    const samples = await collectSamples(
      ["https://a.example/1"],
      deps(async (_url, _anchor, ledger) => {
        recordTypicalRun(ledger);
        return "ok";
      }),
    );

    for (const sample of samples) {
      // Task 16 Step 2 的断言逐字读这三个字段：
      //   estimateBrief(sample.durationSec, sample.register).tokens / sample.actualTokens
      expect(typeof sample.durationSec).toBe("number");
      expect(typeof sample.register).toBe("number");
      expect(typeof sample.actualTokens).toBe("number");
      expect(sample.estimatedTokens).toBe(
        estimateBrief(sample.durationSec, sample.register).tokens,
      );
    }

    // 两个锚点都在：`1:00 通俗` 和 `3:00 偏专业`。
    expect(samples.map((s) => [s.durationSec, s.register])).toEqual([
      [60, 0],
      [180, 0.7],
    ]);
  });
});

describe("parseUrlList", () => {
  it("一行一条，忽略空行和 # 注释", () => {
    const urls = parseUrlList(
      ["# 2026-09-18 这一批", "https://a.example/1", "", "  https://b.example/2  ", "# 停用"].join(
        "\n",
      ),
    );
    expect(urls).toEqual(["https://a.example/1", "https://b.example/2"]);
  });
});
