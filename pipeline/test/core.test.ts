import { expect, test } from "vitest";
import { buildBrief } from "../src/core.js";
import type { CoreInput } from "../src/core.js";

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
  expect(out.verdict).toBe("insufficient");
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

test("a fabricated fact sentence is caught", () => {
  const withLie = input();
  withLie.draft.push({ text: "这是年内第三次降准。", kind: "fact", claimIds: [] });
  expect(buildBrief(withLie).bind).toEqual({
    ok: false,
    problems: [{ kind: "fact-without-claim", sentenceIndex: 3 }],
  });
});
