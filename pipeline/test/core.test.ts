import { expect, test } from "vitest";
import { buildBrief } from "../src/core.js";
import type { CoreInput } from "../src/core.js";
import type { Fact, Source } from "../src/domain/types.js";

const WIRE = "央行今日宣布下调金融机构存款准备金率零点五个百分点，此次降准将释放长期资金约一万亿元，自三月十五日起生效。";

function input(): CoreInput {
  return {
    durationSec: 60,
    register: 0.25,
    charsPerSecond: 5.5,
    sources: [
      { id: "s0", url: "https://pbc.example/a", publisher: "pbc", publishedAt: "2026-03-01T07:00:00Z", body: WIRE, creditedTo: null },
      { id: "s1", url: "https://portal.example/a", publisher: "portal", publishedAt: "2026-03-01T07:20:00Z", body: `【转载】${WIRE}`, creditedTo: null },
      { id: "s2", url: "https://reuters.example/a", publisher: "reuters", publishedAt: "2026-03-01T08:00:00Z", body: "Reuters 独立测算显示，此次操作对应释放的长期资金规模在一万亿元左右，生效日期为三月十五日。", creditedTo: null },
      { id: "s3", url: "https://caixin.example/a", publisher: "caixin", publishedAt: "2026-03-01T09:00:00Z", body: "财新记者从多家银行了解到，此次降准释放长期资金约 1 万亿元，三月十五日起生效，信贷投放节奏将前移。", creditedTo: null },
    ],
    facts: [
      { id: "f0", sourceId: "s0", text: "此次降准释放长期资金约 1 万亿元", quote: WIRE },
      { id: "f1", sourceId: "s1", text: "此次降准将释放长期资金约 1 万亿元", quote: WIRE },
      { id: "f2", sourceId: "s2", text: "此次降准释放长期资金约 1 万亿元", quote: "…一万亿元左右…" },
      { id: "f3", sourceId: "s3", text: "此次降准释放长期资金约 1 万亿元", quote: "…约 1 万亿元…" },
    ],
    draft: [
      { text: "央行今天突然出手了。", kind: "transition", claimIds: [] },
      { text: "此次降准释放长期资金约 1 万亿元。", kind: "fact", claimIds: ["c0"] },
      { text: "我的判断是这一轮宽松还没到头。", kind: "opinion", claimIds: [] },
    ],
  };
}

test("the four sources collapse to three groups and the claim is strong", () => {
  const out = buildBrief(input());
  expect(out.claims).toHaveLength(1);
  expect(out.claims[0]!.independence).toBe(3);
  expect(out.claims[0]!.confidence).toBe("strong");
});

test("one strong claim is not enough to produce a script", () => {
  const out = buildBrief(input());
  expect(out.selection.verdict).toBe("insufficient");
  expect(out.selection.reason).toBe("only 1 strong claims, need 3");
});

test("the estimate travels with the result", () => {
  const out = buildBrief(input());
  expect(out.estimate.durationSec).toBe(60);
  expect(out.estimate.factSlots).toBe(3);
});

test("binding and prosody still run so problems surface even when insufficient", () => {
  const out = buildBrief(input());
  expect(out.bind.ok).toBe(true);
  expect(out.seconds).toBeGreaterThan(0);
  expect(out.breaths.length).toBeGreaterThan(0);
});

/**
 * 四条 strong + 一对互相冲突的 claim。上面那个 fixture 永远停在 insufficient，
 * 于是「名额切片」和「排除 conflicted」这两段接缝一次都没被执行过——
 * 把 estimate.factSlots 换成 estimate.sources、或者删掉 conflicted 过滤，
 * 五个测试全绿。这个 fixture 专门用来走到 ok 分支。
 */
function sufficient(): CoreInput {
  const bodies = [
    "中国人民银行决定于三月十五日下调金融机构存款准备金率零点五个百分点。",
    "Reuters 独立测算显示，此次操作对应释放的长期资金规模在一万亿元左右。",
    "财新记者从多家银行了解到，降准落地后信贷投放节奏将有所前移。",
    "彭博社获得的数据显示，本轮操作对应的资金规模约 31 亿美元等值。",
  ];
  const sources: Source[] = bodies.map((body, i) => ({
    id: `s${i}`, url: `https://x${i}.example/a`, publisher: `p${i}`,
    publishedAt: "2026-03-01T07:00:00Z", body, creditedTo: null,
  }));
  const texts = [
    "此次降准释放长期资金约 1 万亿元",
    "存款准备金率下调 0.5 个百分点",
    "新政自 3 月 15 日起生效",
    "信贷投放节奏将有所前移",
  ];
  const facts: Fact[] = texts.flatMap((text, t) =>
    [0, 1, 2].map((s) => ({ id: `f${t}${s}`, sourceId: `s${s}`, text, quote: text })));
  facts.push({ id: "fx", sourceId: "s2", text: "涉及资金规模约 23 亿美元", quote: "x" });
  facts.push({ id: "fy", sourceId: "s3", text: "涉及资金规模约 31 亿美元", quote: "y" });
  return { durationSec: 60, register: 0.25, charsPerSecond: 5.5, sources, facts, draft: [] };
}

test("the slot budget actually limits what gets picked", () => {
  const out = buildBrief(sufficient());
  expect(out.selection.verdict).toBe("ok");
  // 四条 strong，名额只有三个。传成 estimate.sources（11）的话这里会是 4。
  expect(out.estimate.factSlots).toBe(3);
  expect(out.selection.picked).toHaveLength(3);
});

test("a sentence citing a conflicted claim does not bind", () => {
  // 删掉 `confidence !== "conflicted"` 那个过滤，这一条会变绿——上面的 fixture
  // 一条冲突 claim 都没有，所以那个过滤在别处全是空转。
  const conflicted = buildBrief(sufficient()).claims.find((c) => c.confidence === "conflicted");
  expect(conflicted).toBeDefined();

  const brief = sufficient();
  brief.draft = [{ text: "涉及资金规模约 23 亿美元。", kind: "fact", claimIds: [conflicted!.id] }];
  expect(buildBrief(brief).bind).toEqual({
    ok: false,
    problems: [{ kind: "unknown-claim", sentenceIndex: 0, claimId: conflicted!.id }],
  });
});

test("a fabricated fact sentence is caught", () => {
  const withLie = input();
  withLie.draft.push({ text: "这是年内第三次降准。", kind: "fact", claimIds: [] });
  expect(buildBrief(withLie).bind).toEqual({
    ok: false,
    problems: [{ kind: "fact-without-claim", sentenceIndex: 3 }],
  });
});

test("externalConflicts reaches the conflict graph", () => {
  // 没有这一条，`CoreInput.externalConflicts` 接了字段却不往下传（或者传错
  // 参数位）不会有任何测试变红——⑤ 的语义那一半就又成了死代码。
  const brief = sufficient();
  const [a, b] = buildBrief(brief).claims.filter((c) => c.confidence === "strong");
  expect(a).toBeDefined();
  expect(b).toBeDefined();

  brief.externalConflicts = [[a!.id, b!.id]];
  const claims = buildBrief(brief).claims;
  const byId = new Map(claims.map((c) => [c.id, c]));
  expect(byId.get(a!.id)!.confidence).toBe("conflicted");
  expect(byId.get(b!.id)!.confidence).toBe("conflicted");

  // 四条 strong 打掉两条只剩两条，低于三条的下限——⑥ 跟着改判，不敢播。
  expect(buildBrief(brief).selection.verdict).toBe("insufficient");
});
