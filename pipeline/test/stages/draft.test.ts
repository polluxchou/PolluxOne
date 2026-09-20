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

  // 这一条以前测的是「conflicted 被悄悄滤掉」。现在谁进稿只有 ⑥ 一个答案
  // （run.ts 交进来的就是 selection.picked，里面不可能有 conflicted），
  // 所以这里从「滤」改成「抛」：真收到 conflicted 说明接线错了，而静默地
  // 滤掉正是「⑥ 挑了 5 条、⑦ 写了 15 句」那个缺陷能藏这么久的方式。
  it("conflicted 的 claim 被交进来时抛——不再悄悄滤掉，那会让谁决定进稿有两个答案", () => {
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
    expect(() => buildDraftPrompt(withConflict, 60, 0)).toThrow(/c9/);
    expect(() => buildDraftPrompt(withConflict, 60, 0)).toThrow(/conflicted/);
  });

  it("交进来几条就写几条——这里不再自己挑，挑是 ⑥ 的事", () => {
    const p = buildDraftPrompt([claims[1]!], 60, 0);
    const list = p.slice(p.indexOf("可用的事实："));
    expect(list).toContain("c1");
    // c0 是 strong、也不冲突，只是没被交进来——就不该出现在可用列表里。
    // （"c0" 在输出格式那一行的示例里有，所以只看列表那一段。）
    expect(list).not.toContain("c0");
    expect(p).not.toContain("存款准备金率下调 0.5 个百分点");
  });

  it("没有可用 claim 时抛——空稿子不如不出稿", () => {
    expect(() => buildDraftPrompt([], 60, 0)).toThrow(/没有/);
  });
});

// —— 时长以前只是 prompt 里的一个数字，不约束任何东西：实跑要 60 秒交了 31 秒 ——

describe("buildDraftPrompt 里的长度指标", () => {
  it("写明目标字数和句数范围——只说字数，模型会塞进一长句", () => {
    const p = buildDraftPrompt(claims, 60, 0);
    // 60 秒 × 5 字/秒（中文 claim 判出来的默认语速）
    expect(p).toContain("300 字");
    expect(p).toMatch(/8 到 12 句/);
  });

  it("两个方向的后果都说了——短了播不满，长了会超时", () => {
    const p = buildDraftPrompt(claims, 60, 0);
    expect(p).toMatch(/短了/);
    expect(p).toMatch(/超时/);
  });

  it("目标字数跟着时长走", () => {
    expect(buildDraftPrompt(claims, 30, 0)).toContain("150 字");
    expect(buildDraftPrompt(claims, 180, 0)).toContain("900 字");
  });

  it("传进来实测语速就按它定靶，不用语种默认值", () => {
    // 念得慢的人（4 字/秒）拿到的是更短的稿：App 上显示的秒数按他的语速算，
    // 靶子按默认值定的话，他永远看到一个比拨盘大的数。
    expect(buildDraftPrompt(claims, 60, 0, 4)).toContain("240 字");
  });

  it("英文 claim 按拉丁语速定靶——不然 60 秒的英文稿会被要求写 300 个字符", () => {
    const english: VerifiedClaim[] = [
      {
        id: "c0",
        text: "The central bank cut the reserve requirement ratio by half a point",
        factIds: ["f0"],
        independence: 3,
        confidence: "strong",
        conflictsWith: [],
      },
    ];
    const p = buildDraftPrompt(english, 60, 0);
    expect(p).toContain("960 字");
    // 句数范围跟中文一样：一句话念多久与语种无关。
    expect(p).toMatch(/8 到 12 句/);
  });

  it("给出把稿子写够长的合法办法——名额有限，不说这条模型就会编一条事实", () => {
    // 60 秒只有 3 条 claim（factSlots），却要写 8–12 句：这两个数之间有张力，
    // 「同一条 claim 可以连着写几句」是唯一不靠编造就能填满的出路。
    const p = buildDraftPrompt(claims, 60, 0);
    expect(p).toMatch(/同一条 claim 可以连着写几句/);
  });
});
