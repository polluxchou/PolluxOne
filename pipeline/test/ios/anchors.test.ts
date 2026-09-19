import { describe, expect, it } from "vitest";
import { anchorsFor, graphemeCount, squash } from "../../src/ios/anchors.js";

const claims = [
  { id: "c0", text: "岚芯半导体第三季度营收 48.6 亿元，同比增长 31%" },
  { id: "c1", text: "十二英寸新厂将于 2027 年 3 月投产" },
  { id: "c2", text: "报告期内研发投入 9.4 亿元" },
];

/** 按字素簇切出锚点盖住的那段字——iOS 侧 `AnchorRuns` 做的就是这个。 */
const slice = (text: string, start: number, length: number): string =>
  [...new Intl.Segmenter("zh", { granularity: "grapheme" }).segment(text)]
    .map((p) => p.segment)
    .slice(start, start + length)
    .join("");

describe("graphemeCount", () => {
  it("中文一个字算一个", () => {
    expect(graphemeCount("营收 48.6 亿元")).toBe(10);
  });

  it("emoji 和带组合符的字符只算一个 Character——这里才和 UTF-16 分家", () => {
    // 这三个的 .length 分别是 8、2、2；iOS 的 Array(text).count 都是 1。
    expect(graphemeCount("👨‍👩‍👧")).toBe(1);
    expect(graphemeCount("é")).toBe(1); // e + U+0301
    expect(graphemeCount("🇨🇳")).toBe(1);
  });
});

describe("squash", () => {
  it("折叠全角和空白，但不动小数点", () => {
    expect(squash("４８.６ 亿元")).toBe("48.6亿元");
  });
});

describe("anchorsFor", () => {
  it("把 claim 里出现过的金额划出来，位置按 Character 计", () => {
    const text = "岚芯半导体第三季度营收 48.6 亿元。";
    const [anchor, ...rest] = anchorsFor(text, ["c0"], claims);
    expect(rest).toEqual([]);
    expect(anchor).toBeDefined();
    expect(slice(text, anchor!.start, anchor!.length)).toBe("48.6 亿元");
    expect(anchor!.claimId).toBe("c0");
  });

  it("日期连成一个锚点，不拆成两条挨着的虚线", () => {
    const text = "新厂 2027 年 3 月投产。";
    const anchors = anchorsFor(text, ["c1"], claims);
    expect(anchors).toHaveLength(1);
    expect(slice(text, anchors[0]!.start, anchors[0]!.length)).toBe("2027 年 3 月");
  });

  it("一句挂两条 claim 时各归各的，且互不重叠", () => {
    const text = "营收 48.6 亿元，研发投入 9.4 亿元。";
    const anchors = anchorsFor(text, ["c0", "c2"], claims);
    expect(anchors.map((a) => a.claimId)).toEqual(["c0", "c2"]);
    expect(anchors[0]!.start + anchors[0]!.length).toBeLessThanOrEqual(anchors[1]!.start);
    expect(slice(text, anchors[1]!.start, anchors[1]!.length)).toBe("9.4 亿元");
  });

  it("claim 里没有的数字不产锚点——划错位置比不划更糟", () => {
    expect(anchorsFor("营收 99.9 亿元。", ["c0"], claims)).toEqual([]);
  });

  it("小数点不被当成标点抹掉：48.6 不许配上一条只说过 486 的 claim", () => {
    const other = [{ id: "x", text: "营收 486 亿元" }];
    expect(anchorsFor("营收 48.6 亿元。", ["x"], other)).toEqual([]);
  });

  it("没挂 claim 的句子一个锚点都没有", () => {
    expect(anchorsFor("营收 48.6 亿元。", [], claims)).toEqual([]);
  });

  it("claimIds 指向不存在的 claim 时不产锚点，而不是抛错", () => {
    expect(anchorsFor("营收 48.6 亿元。", ["nope"], claims)).toEqual([]);
  });

  it("emoji 在前时偏移量仍然对得上 iOS 的切片", () => {
    const text = "📈 营收 48.6 亿元。";
    const anchors = anchorsFor(text, ["c0"], claims);
    expect(anchors).toHaveLength(1);
    expect(slice(text, anchors[0]!.start, anchors[0]!.length)).toBe("48.6 亿元");
  });

  it("产出的锚点永远按位置递增且不越界", () => {
    const text = "营收 48.6 亿元，同比增长 31%，研发投入 9.4 亿元。";
    const anchors = anchorsFor(text, ["c0", "c2"], claims);
    const total = graphemeCount(text);
    let cursor = 0;
    for (const a of anchors) {
      expect(a.start).toBeGreaterThanOrEqual(cursor);
      expect(a.length).toBeGreaterThan(0);
      expect(a.start + a.length).toBeLessThanOrEqual(total);
      cursor = a.start + a.length;
    }
    expect(anchors.length).toBeGreaterThan(1);
  });

  it("带前缀英文词的版本号整个划上，而不是只划数字", () => {
    const protocol = [{ id: "p", text: "模型采用 Apache 2.0 协议开源" }];
    const text = "这次是 Apache 2.0 协议。";
    const anchors = anchorsFor(text, ["p"], protocol);
    expect(anchors).toHaveLength(1);
    expect(slice(text, anchors[0]!.start, anchors[0]!.length)).toBe("Apache 2.0");
  });
});
