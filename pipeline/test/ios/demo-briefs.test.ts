import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { BRIEF_DIR, MOCK_DIR, checkAll, checkBrief } from "../../scripts/check-demo-briefs.js";
import { readMockNews } from "../../scripts/make-demo-briefs.js";

const slugs = readdirSync(BRIEF_DIR)
  .filter((f) => f.endsWith(".json"))
  .map((f) => f.replace(/\.json$/u, ""))
  .sort();

const load = (slug: string): Record<string, unknown> =>
  JSON.parse(readFileSync(`${BRIEF_DIR}/${slug}.json`, "utf8")) as Record<string, unknown>;

const bodiesOf = (slug: string): string[] =>
  (JSON.parse(readFileSync(`${MOCK_DIR}/${slug}.json`, "utf8")) as { sources: { body: string }[] })
    .sources.map((s) => s.body);

/** 深拷贝，好在上面动手脚而不弄脏磁盘上的那一份。 */
const clone = (slug: string): Record<string, any> => JSON.parse(JSON.stringify(load(slug)));

describe("ios/Pollux One/Resources/demo-briefs", () => {
  it("五份都在", () => {
    expect(slugs).toHaveLength(5);
  });

  it("逐条通过锚点与句子规则", () => {
    expect(checkAll()).toEqual([]);
  });

  it("每一份都真的调过模型，账也是真的", () => {
    for (const slug of slugs) {
      const brief = load(slug) as any;
      expect(brief.budget.used).toBeGreaterThan(0);
      expect(brief.budget.costCents).toBeGreaterThan(0);
      // 之和不等于 used，进度条就在撒谎——TokenBudget 自己的注释。
      const sum = Object.values<number>(brief.budget.byStage).reduce((a, b) => a + b, 0);
      expect(sum).toBe(brief.budget.used);
    }
  });

  it("每一份都有挂到三个独立信源的说法", () => {
    for (const slug of slugs) {
      const brief = load(slug) as any;
      const strong = Object.values<any>(brief.claims).filter((c) => c.independence >= 3);
      expect(strong.length, slug).toBeGreaterThanOrEqual(1);
    }
  });

  it("至少有一份记到了被归并掉的转载", () => {
    const merged = slugs.map(
      (s) => Object.values<any>((load(s) as any).claims).filter((c) => c.mergedAwayCount > 0).length,
    );
    expect(merged.reduce((a, b) => a + b, 0)).toBeGreaterThan(0);
  });
});

// 造假数据的纪律：这条产线只吃明说了自己是假的、且 url 明显不存在的文件。
// 这两条守的不是形状，是"虚构内容别被当真"——所以它们该有测试钉着。
describe("readMockNews 的造假纪律", () => {
  const write = (patch: Record<string, unknown>): string => {
    const base = JSON.parse(readFileSync(`${MOCK_DIR}/${slugs[0]!}.json`, "utf8")) as object;
    const dir = mkdtempSync(`${tmpdir()}/mock-news-`);
    const path = `${dir}/case.json`;
    writeFileSync(path, JSON.stringify({ ...base, ...patch }), "utf8");
    return path;
  };

  it("五份 fixture 自己都过得了这道关", () => {
    for (const f of readdirSync(MOCK_DIR).filter((f) => f.endsWith(".json"))) {
      expect(() => readMockNews(`${MOCK_DIR}/${f}`)).not.toThrow();
    }
  });

  it("没写 synthetic 的一律拒收", () => {
    expect(() => readMockNews(write({ synthetic: undefined }))).toThrow(/synthetic/u);
  });

  it("url 用了看起来像真的域名就拒收", () => {
    const sources = (
      JSON.parse(readFileSync(`${MOCK_DIR}/${slugs[0]!}.json`, "utf8")) as { sources: any[] }
    ).sources.map((s, i) => (i === 0 ? { ...s, url: "https://www.xinhuanet.com/a" } : s));
    expect(() => readMockNews(write({ sources }))).toThrow(/example\.com/u);
  });
});

// 校验器必须**真的会拒**。一个永远返回空数组的函数也能让上面那条测试通过，
// 所以这里逐条把产物改坏，看它有没有叫。
describe("校验器的每一条规则都咬得住", () => {
  const first = slugs[0]!;
  const bodies = bodiesOf(first);
  const check = (brief: unknown): string[] => checkBrief(brief, bodies, "mutant");

  const anchoredSentence = (b: Record<string, any>): any =>
    b.sentences.find((s: any) => s.anchors.length > 0);

  it("原样是干净的", () => {
    expect(check(clone(first))).toEqual([]);
  });

  it("锚点越界会被拒", () => {
    const b = clone(first);
    const s = anchoredSentence(b);
    s.anchors[0].length = [...s.text].length + 5;
    expect(check(b).join("\n")).toMatch(/越界/u);
  });

  it("锚点重叠会被拒", () => {
    const b = clone(first);
    const s = anchoredSentence(b);
    // 把第一个锚点撑长到盖住下一个——iOS 侧会因此整句降级。
    s.anchors.push({ start: s.anchors[0].start, length: 1, claimId: s.anchors[0].claimId });
    expect(check(b).join("\n")).toMatch(/重叠/u);
  });

  it("空锚点会被拒", () => {
    const b = clone(first);
    anchoredSentence(b).anchors[0].length = 0;
    expect(check(b).join("\n")).toMatch(/空锚点/u);
  });

  it("锚点错位一格会被拒——挪一个字，划出来的数就不在任何一篇报道里了", () => {
    const b = clone(first);
    const s = anchoredSentence(b);
    s.anchors[0].start += 1;
    expect(check(b).join("\n")).toMatch(/找不到|没有数字/u);
  });

  it("锚点指向这句没引用的 claim 会被拒", () => {
    const b = clone(first);
    const s = anchoredSentence(b);
    const outsider = Object.keys(b.claims).find((id) => !s.claimIds.includes(id))!;
    s.anchors[0].claimId = outsider;
    expect(check(b).join("\n")).toMatch(/这句没引用/u);
  });

  it("锚点指向不存在的 claim 会被拒", () => {
    const b = clone(first);
    anchoredSentence(b).anchors[0].claimId = "c-not-here";
    expect(check(b).join("\n")).toMatch(/不存在的 claim/u);
  });

  it("fact 句没有 claimIds 会被拒", () => {
    const b = clone(first);
    const s = b.sentences.find((s: any) => s.kind === "fact")!;
    s.claimIds = [];
    s.anchors = [];
    expect(check(b).join("\n")).toMatch(/没有 claimIds/u);
  });

  it("opinion 句挂了 claimIds 会被拒", () => {
    const b = clone(first);
    const s = b.sentences.find((s: any) => s.kind === "opinion")!;
    s.claimIds = [Object.keys(b.claims)[0]];
    expect(check(b).join("\n")).toMatch(/不许有 claimIds/u);
  });

  it("transition 句挂了锚点会被拒", () => {
    const b = clone(first);
    const s = b.sentences.find((s: any) => s.kind === "transition")!;
    s.anchors = [{ start: 0, length: 1, claimId: Object.keys(b.claims)[0] }];
    expect(check(b).join("\n")).toMatch(/不许有锚点/u);
  });

  it("byStage 之和对不上 used 会被拒", () => {
    const b = clone(first);
    b.budget.used += 1;
    expect(check(b).join("\n")).toMatch(/≠ used/u);
  });

  it("pacedToUser 写成 true 会被拒", () => {
    const b = clone(first);
    b.pacedToUser = true;
    expect(check(b).join("\n")).toMatch(/pacedToUser/u);
  });

  it("阶段没跑完会被拒", () => {
    const b = clone(first);
    b.stages[4].state = "running";
    expect(check(b).join("\n")).toMatch(/不是 done/u);
  });

  it("claim 的 sources 条数和 independence 对不上会被拒", () => {
    const b = clone(first);
    const id = Object.keys(b.claims)[0]!;
    b.claims[id].independence += 1;
    expect(check(b).join("\n")).toMatch(/sources 条数/u);
  });

  it("重查把信源查少了会被拒", () => {
    const b = clone(first);
    const id = Object.keys(b.claims).find((k) => b.claims[k].independence > 1)!;
    b.recheckResults = { [id]: { ...b.claims[id], independence: 1, sources: [] } };
    expect(check(b).join("\n")).toMatch(/重查把/u);
  });
});
