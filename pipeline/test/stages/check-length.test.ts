import { describe, expect, it } from "vitest";
import { DEFAULT_CHARS_PER_SECOND } from "../../src/domain/prosody.js";
import type { DraftSentence } from "../../src/domain/types.js";
import {
  checkDraftLength,
  describeLength,
  lengthComplaint,
  lengthTarget,
  LENGTH_TOLERANCE,
  MIN_SLACK_SEC,
  resolveDraftRate,
  type LengthMiss,
} from "../../src/stages/check-length.js";

/** 一句 n 个可朗读字的中文句子。标点不算，所以这里一个标点都不放。 */
const line = (n: number, kind: DraftSentence["kind"] = "fact"): DraftSentence => ({
  text: "央".repeat(n),
  kind,
  claimIds: kind === "fact" ? ["c0"] : [],
});

/** 总共 n 个可朗读字，拆成三句——长度只看总量，句数是 prompt 那边的事。 */
const draftOf = (n: number): DraftSentence[] => [
  line(Math.floor(n / 3), "transition"),
  line(Math.floor(n / 3)),
  line(n - 2 * Math.floor(n / 3)),
];

const cjk60 = lengthTarget(60, DEFAULT_CHARS_PER_SECOND.cjk);

describe("lengthTarget", () => {
  it("目标字数就是时长乘语速", () => {
    expect(cjk60.chars).toBe(300);
    expect(lengthTarget(60, DEFAULT_CHARS_PER_SECOND.latin).chars).toBe(960);
  });

  it("句数范围按秒推，所以中英文都说得通——不是按字数推", () => {
    const latin60 = lengthTarget(60, DEFAULT_CHARS_PER_SECOND.latin);
    // 同样 60 秒，字数差三倍，句数范围必须一样：一句话念多久与语种无关。
    expect(latin60.minSentences).toBe(cjk60.minSentences);
    expect(latin60.maxSentences).toBe(cjk60.maxSentences);
    // 五份真跑出来的稿子每句 5.3–7.3 秒，60 秒该落在 8–12 句。
    expect(cjk60.minSentences).toBe(8);
    expect(cjk60.maxSentences).toBe(12);
  });

  it("容差两边不对称：长了会当场超时，短了只是单薄", () => {
    expect(cjk60.maxSeconds - 60).toBeLessThan(60 - cjk60.minSeconds);
    expect(cjk60.maxSeconds).toBeCloseTo(63, 5);
    expect(cjk60.minSeconds).toBeCloseTo(51, 5);
  });

  it("短了 15%：小于相邻两档最近那一对（45→60，差 33%）的一半", () => {
    // 否则「落在容差内」可以意味着「你其实拿到了隔壁那一档」，拨盘就白给了。
    expect(LENGTH_TOLERANCE.under).toBeLessThan((60 - 45) / 45 / 2);
  });

  it("短档上容差不小于半句话——比这还紧的要求只会白烧一次重跑", () => {
    const short = lengthTarget(30, DEFAULT_CHARS_PER_SECOND.cjk);
    // 30 秒的 5% 只有 1.5 秒，不到四分之一句；这里必须被 MIN_SLACK_SEC 顶上去。
    expect(short.maxSeconds - 30).toBe(MIN_SLACK_SEC);
    expect(30 - short.minSeconds).toBeGreaterThanOrEqual(MIN_SLACK_SEC);
  });

  it("非法的时长或语速直接抛，不静默出一个看着合理的靶子", () => {
    expect(() => lengthTarget(0, 5)).toThrow();
    expect(() => lengthTarget(60, 0)).toThrow();
    expect(() => lengthTarget(60, Number.NaN)).toThrow();
  });
});

describe("checkDraftLength", () => {
  it("正好踩在目标上就通过", () => {
    const r = checkDraftLength(draftOf(300), cjk60);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.seconds).toBeCloseTo(60, 5);
  });

  it("容差内接受——不为了几个字去烧一次 deepseek-v4-pro", () => {
    expect(checkDraftLength(draftOf(260), cjk60).ok).toBe(true);
    expect(checkDraftLength(draftOf(310), cjk60).ok).toBe(true);
  });

  it("要 60 秒交 31 秒要被抓住——这是实跑里真发生过的那一次", () => {
    const r = checkDraftLength(draftOf(153), cjk60);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.direction).toBe("too-short");
    expect(r.ratio).toBeCloseTo(153 / 300, 2);
    // 差多少字要是个数：只说「太短」，模型不知道是差两句还是差一半。
    expect(r.charsOff).toBe(147);
  });

  it("长了也要被抓住，而且比短了更早被抓住", () => {
    // 同样偏离 10%，长的那头不通过、短的那头通过。
    expect(checkDraftLength(draftOf(330), cjk60).ok).toBe(false);
    expect(checkDraftLength(draftOf(270), cjk60).ok).toBe(true);
    const r = checkDraftLength(draftOf(400), cjk60);
    if (r.ok) throw new Error("400 字不该算 60 秒");
    expect(r.direction).toBe("too-long");
    expect(r.charsOff).toBeLessThan(0);
  });

  it("量的是可朗读字数，标点不占时间", () => {
    const withPunctuation: DraftSentence[] = [
      { text: `${"央".repeat(300)}，。！`, kind: "fact", claimIds: ["c0"] },
    ];
    expect(checkDraftLength(withPunctuation, cjk60).ok).toBe(true);
  });

  it("一句都没有时不通过，而且方向是「太短」", () => {
    const r = checkDraftLength([], cjk60);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.direction).toBe("too-short");
  });
});

describe("resolveDraftRate", () => {
  const cjkClaims = [{ text: "央行下调存款准备金率 0.5 个百分点" }];
  const latinClaims = [{ text: "The central bank cut the reserve requirement ratio" }];

  it("稿子还没写出来，就照 claim 的语种判——claim 和稿子必然同一个语种", () => {
    expect(resolveDraftRate(cjkClaims)).toBe(DEFAULT_CHARS_PER_SECOND.cjk);
    expect(resolveDraftRate(latinClaims)).toBe(DEFAULT_CHARS_PER_SECOND.latin);
  });

  it("有实测语速就一定用它——App 上显示的秒数是按他的语速算的", () => {
    expect(resolveDraftRate(cjkClaims, 4.2)).toBe(4.2);
    expect(resolveDraftRate(latinClaims, 4.2)).toBe(4.2);
  });

  it("语速是 0 或 NaN 时回落，而不是拿它去除", () => {
    expect(resolveDraftRate(cjkClaims, 0)).toBe(DEFAULT_CHARS_PER_SECOND.cjk);
    expect(resolveDraftRate(cjkClaims, Number.NaN)).toBe(DEFAULT_CHARS_PER_SECOND.cjk);
  });
});

describe("lengthComplaint", () => {
  const miss = (chars: number): LengthMiss => {
    const r = checkDraftLength(draftOf(chars), cjk60);
    if (r.ok) throw new Error(`${chars} 字本该不达标`);
    return r;
  };

  it("太短时把差多少字说成一个数，并堵死「编一条事实来凑长度」", () => {
    const text = lengthComplaint(miss(153), cjk60);
    expect(text).toContain("太短");
    expect(text).toContain("147");
    expect(text).toContain("300");
    expect(text).toMatch(/不许编/);
  });

  it("太长时说砍多少字，而且不许靠删事实变短", () => {
    const text = lengthComplaint(miss(500), cjk60);
    expect(text).toContain("太长");
    expect(text).toContain("200");
    expect(text).toMatch(/删掉事实|超时/);
  });
});

describe("describeLength", () => {
  it("一行人话里目标和实得都在", () => {
    const text = describeLength(checkDraftLength(draftOf(153), cjk60), cjk60);
    expect(text).toContain("60");
    expect(text).toContain("300");
    expect(text).toContain("153");
  });
});
