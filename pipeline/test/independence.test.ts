import { expect, test } from "vitest";
import type { Source } from "../src/domain/types.js";
import { groupSources, independenceOf } from "../src/dedupe/independence.js";

const WIRE = "央行今日宣布下调金融机构存款准备金率零点五个百分点，此次降准将释放长期资金约一万亿元，自三月十五日起生效。";

function src(id: string, publisher: string, body: string, creditedTo: string | null = null): Source {
  return { id, url: `https://${publisher}.example/${id}`, publisher, publishedAt: "2026-03-01T07:00:00Z", body, creditedTo };
}

test("one wire story plus five reposts counts as a single source", () => {
  const sources = [
    src("s0", "xinhua", WIRE),
    src("s1", "portal-a", `【转载】${WIRE}`),
    src("s2", "portal-b", `${WIRE}（完）`),
    src("s3", "portal-c", WIRE),
    src("s4", "portal-d", `快讯｜${WIRE}`),
    src("s5", "portal-e", WIRE),
  ];
  const groups = groupSources(sources);
  expect(groups).toHaveLength(1);
  expect(independenceOf(sources.map((s) => s.id), groups)).toBe(1);
});

test("an explicit credit line collapses a source into the one it credits", () => {
  const sources = [
    src("s0", "xinhua", WIRE),
    src("s1", "portal-a", "据新华社报道，央行今日决定实施降准，市场反应积极，多位分析师认为这一决定符合预期。", "xinhua"),
  ];
  expect(groupSources(sources)).toHaveLength(1);
});

test("same publisher is one source even when the two pieces differ", () => {
  const sources = [
    src("s0", "caixin", "央行降准零点五个百分点，为年内第二次，释放资金约一万亿元。"),
    src("s1", "caixin", "降准之后，按揭利率是否跟进下调？多位银行人士给出不同判断。"),
  ];
  expect(groupSources(sources)).toHaveLength(1);
});

test("a media group table collapses sibling outlets", () => {
  const sources = [
    src("s0", "outlet-a", "央行降准零点五个百分点，为年内第二次，释放资金约一万亿元。"),
    src("s1", "outlet-b", "降准之后，按揭利率是否跟进下调？多位银行人士给出不同判断。"),
  ];
  const groups = groupSources(sources, { "outlet-a": "group-x", "outlet-b": "group-x" });
  expect(groups).toHaveLength(1);
});

test("sources too short to fingerprint are never merged by fingerprint", () => {
  // 抓取失败的两条新闻各自产不出 shingle。两个空集的 Jaccard 是 1，
  // 所以这里必须靠 groupSources 的守卫挡住，否则独立源数会少算。
  const sources = [src("s0", "portal-a", "无正文"), src("s1", "portal-b", "")];
  expect(groupSources(sources)).toHaveLength(2);
});

test("genuinely independent reporting stays separate", () => {
  const sources = [
    src("s0", "pbc", "中国人民银行决定于三月十五日下调金融机构存款准备金率零点五个百分点。"),
    src("s1", "reuters", "Reuters 独立测算显示，此次操作对应释放的长期资金规模在一万亿元左右。"),
    src("s2", "caixin", "财新记者从多家银行了解到，降准落地后信贷投放节奏将有所前移。"),
  ];
  const groups = groupSources(sources);
  expect(groups).toHaveLength(3);
  expect(independenceOf(["s0", "s1", "s2"], groups)).toBe(3);
});

test("independence only counts the groups a claim actually cites", () => {
  const sources = [
    src("s0", "pbc", "中国人民银行决定于三月十五日下调金融机构存款准备金率零点五个百分点。"),
    src("s1", "reuters", "Reuters 独立测算显示，此次操作对应释放的长期资金规模在一万亿元左右。"),
    src("s2", "caixin", "财新记者从多家银行了解到，降准落地后信贷投放节奏将有所前移。"),
  ];
  const groups = groupSources(sources);
  expect(independenceOf(["s0", "s1"], groups)).toBe(2);
});
