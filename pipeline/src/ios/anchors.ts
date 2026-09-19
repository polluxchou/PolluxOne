// pipeline/src/ios/anchors.ts
//
// 句内证据锚点：iOS 上那条虚线下划线画在哪一段字上。
//
// 管线到 ⑧ 为止只回答「这一句挂了哪几条 claim」，不回答「这一句的哪几个字
// 是那条 claim 给的」。后者是这个文件的全部内容，而它的正确性由 iOS 侧的
// `AnchorRuns` 钉着：越界或重叠一律整句降级成无标记文本。降级不是崩溃，
// 所以错锚点不会被任何人发现——**划错位置比不划更糟**，因此这里的每一条
// 规则都往"宁可不产"的方向倒。

import type { ClaimId } from "../domain/types.js";

/** 和 Swift 的 `EvidenceAnchor` 逐字段对应。start/length 以 Character 计。 */
export interface EvidenceAnchor {
  start: number;
  length: number;
  claimId: ClaimId;
}

/**
 * **字素簇，不是 UTF-16 code unit，也不是 code point。**
 *
 * Swift 的 `Array(sentence.text)` 给的是 `[Character]`，一个 Character 是一个
 * 扩展字素簇。JS 的 `"str".length` 数的是 UTF-16 code unit，`[...str]` 数的是
 * code point——三者对纯中文恰好一致，对 emoji、带组合符的字、变体选择符就不
 * 一致了。既然 iOS 那边按字素簇切片，这边就必须按字素簇数，哪怕当下的语料
 * 里三者还没分家：一个"现在恰好相等"的口径差异，会在第一条带 emoji 的稿子
 * 上变成整句降级，而降级是静默的。
 *
 * `Intl.Segmenter` 是 JS 内置的，不引依赖。
 */
const SEGMENTER = new Intl.Segmenter("zh", { granularity: "grapheme" });

/** 句子有多少个 Character——iOS 侧 `Array(text).count` 的同一个数。 */
export function graphemeCount(text: string): number {
  let n = 0;
  for (const _ of SEGMENTER.segment(text)) n += 1;
  return n;
}

/**
 * UTF-16 下标 → 字素簇下标。只收录**字素簇边界**上的下标：落在簇中间的
 * 下标查不到，调用方据此整个放弃那个候选片段，而不是就近取整——就近取整
 * 正是"划错位置"的那一类错误。
 */
function boundaryMap(text: string): Map<number, number> {
  const map = new Map<number, number>();
  let g = 0;
  for (const part of SEGMENTER.segment(text)) {
    map.set(part.index, g);
    g += 1;
  }
  map.set(text.length, g); // 末尾也是一个合法边界
  return map;
}

/**
 * 归一化到"只折叠排版差异"：NFKC（全角折半角）、去零宽、去空白。
 *
 * **标点一个都不去**，和 `shingle.ts` 的 `normalize` 不同，因为这里比的是
 * 数字：去掉小数点会让「48.6」变成「486」，于是「486 亿元」能在一条只说过
 * 「48.6 亿元」的 claim 里配上——一个凭空多出一位的金额，正是这套产品最
 * 不能出的错。
 */
export function squash(text: string): string {
  return text
    .normalize("NFKC")
    .replace(/[\u200B-\u200D\uFEFF]/gu, "")
    .replace(/\s+/gu, "");
}

/**
 * 量词表。长的排前面，正则的选择分支是**最左优先**而不是最长优先，
 * 「亿」排在「亿美元」前面会让「120 亿美元」只划到「120 亿」。
 */
const UNITS = [
  "个百分点",
  "万亿美元",
  "万亿欧元",
  "亿美元",
  "亿欧元",
  "万美元",
  "万欧元",
  "个国家",
  "座车站",
  "百分点",
  "个基点",
  "万亿",
  "亿元",
  "万元",
  "公里",
  "千米",
  "人次",
  "小时",
  "分钟",
  "基点",
  "美元",
  "欧元",
  "英镑",
  "日元",
  "亿",
  "万",
  "千",
  "百",
  "元",
  "米",
  "座",
  "站",
  "人",
  "户",
  "家",
  "名",
  "年",
  "月",
  "日",
  "周",
  "天",
  "球",
  "粒",
  "场",
  "次",
  "轮",
  "局",
  "枚",
  "届",
  "吨",
  "套",
  "批",
  "台",
  "辆",
  "个",
  "条",
  "篇",
  "项",
  "款",
  "部",
  "倍",
  "岁",
  "片",
  "张",
  "块",
  "%",
  "‰",
];

const UNIT_ALT = [...UNITS].sort((a, b) => b.length - a.length).join("|");

/**
 * 一个「可定位片段」。
 *
 * - 可选的前缀英文词：「Apache 2.0」要整个划上，只划「2.0」读起来像个版本号
 *   从天上掉下来。
 * - 一段或多段「数字 + 量词」，中间允许空格：这一条让「2027 年 3 月」和
 *   「10 月 9 日」成为**一个**片段而不是两个相邻锚点——日期被拆成两截时
 *   iOS 上就是两条挨着的虚线，读起来像两条互不相干的证据。
 * - 可选的后缀英文词：「14 万亿 token」。
 *
 * 片段一律以数字或量词结尾，绝不以空白结尾——否则锚点末尾会盖住一个不属于
 * 证据的空格。
 */
const TERM = `\\d+(?:[.,]\\d+)?(?:\\s*(?:${UNIT_ALT}))?`;
const FRAGMENT = new RegExp(
  `(?:[A-Za-z][A-Za-z0-9.\\-]*\\s*)?${TERM}(?:\\s*${TERM})*(?:\\s*[A-Za-z][A-Za-z0-9]*)?`,
  "gu",
);

export interface ClaimText {
  id: ClaimId;
  text: string;
}

/**
 * 给一个事实句产出锚点。
 *
 * 规则（每一条都是"宁可不产"）：
 * - 只看这句自己挂的 claim。句子没挂 claim 就一个锚点都没有。
 * - 片段必须在某条 claim 的正文里**原样出现**（只折叠排版差异）。找不到就
 *   丢掉这个片段，不去猜。
 * - 一个片段命中多条 claim 时，按 `claimIds` 的顺序取第一条：句子自己给出的
 *   顺序是唯一有依据的排序，按别的规则挑等于在编一个理由。
 * - 正则扫描天然不重叠且已按位置递增，所以输出满足 iOS 侧的"不重叠"断言，
 *   不需要再排一次序。
 */
export function anchorsFor(
  sentenceText: string,
  claimIds: readonly ClaimId[],
  claims: readonly ClaimText[],
): EvidenceAnchor[] {
  if (claimIds.length === 0) return [];

  const textById = new Map(claims.map((c) => [c.id, squash(c.text)]));
  // claimIds 里可能有 claims 里没有的 id。那是上游的问题，这里只是不给它锚点。
  const candidates = claimIds.filter((id) => textById.has(id));
  if (candidates.length === 0) return [];

  const bounds = boundaryMap(sentenceText);
  const total = graphemeCount(sentenceText);
  const out: EvidenceAnchor[] = [];

  for (const match of sentenceText.matchAll(FRAGMENT)) {
    const raw = match[0];
    const at = match.index;
    if (raw === "" || at === undefined) continue;

    const needle = squash(raw);
    // 纯英文词（LEAD 或 TAIL 单独匹配上）不是可定位片段——「Apache」本身
    // 定位不到任何数字、日期、金额。要求至少有一位数字。
    if (!/\d/u.test(needle)) continue;

    const owner = candidates.find((id) => textById.get(id)!.includes(needle));
    if (owner === undefined) continue;

    const start = bounds.get(at);
    const end = bounds.get(at + raw.length);
    // 片段的两端不在字素簇边界上——夹逼会划错位置，直接放弃。
    if (start === undefined || end === undefined) continue;

    const length = end - start;
    if (length <= 0 || start + length > total) continue;

    out.push({ start, length, claimId: owner });
  }

  return out;
}
