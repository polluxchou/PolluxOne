export type ScriptLanguage = "cjk" | "latin";

/**
 * 没有该用户历史语速时的回落值（字符/秒）。
 *
 * **注意：真实语速目前根本没有采集**——见 spec §9.2 ①。所以新用户的第一篇稿
 * 必然走这两个数字，产品文案不能上来就说「按你的语速」。
 *
 * 数值和 iOS 侧 `ScriptLanguage.defaultCharactersPerSecond`
 * （`ios/Pollux One/Domain/ScriptLanguage.swift`）保持一致，那边写了推导：
 * 5 字/秒 = 300 字/分，从容的上镜语速；16 字符/秒 ≈ 190 wpm。
 * 两边必须一致——不然 App 告诉用户「83 秒」，提词器却按另一个速度起步。
 */
export const DEFAULT_CHARS_PER_SECOND: Record<ScriptLanguage, number> = {
  cjk: 5,
  latin: 16,
};

const CJK = /[㐀-䶿一-鿿぀-ヿ가-힯]/u;

/**
 * CJK 占字母总数的两成就算中文。iOS 侧 `ScriptLanguage.detect` 独立地也用了
 * 两成这个阈值，但**分母口径不同**：那边是全部 unicode scalar（含数字标点），
 * 这边只数字母。金融稿数字密集时两边可能在边界上分道扬镳——真要统一，
 * 该先对齐分母而不是单独调这里的乘数。
 */
export function detectLanguage(text: string): ScriptLanguage {
  let cjk = 0;
  let letters = 0;
  for (const ch of text) {
    if (CJK.test(ch)) cjk += 1;
    else if (/\p{L}/u.test(ch)) letters += 1;
  }
  return cjk > 0 && cjk * 4 >= letters ? "cjk" : "latin";
}

/**
 * 只数会念出声的字符——标点、符号、空白都不占时间，抓取残留的零宽字符
 * 当然也不占（`shingle.ts` 的 `normalize` 同样剥它们；同一份抓来的稿子
 * 会同时喂给两边，不能一边当噪声一边当"要花时间念"）。
 *
 * **已知局限**：数字按字符计会系统性低估播报时长。「0.5」剥完标点剩 2 个
 * 字符，念出来是「零点五」3 个音节；「5%」的 % 被当符号剥掉只剩 1 个字符，
 * 念出来是「百分之五」4 个音节。金融口播恰好是首发场景，数字密度最高——
 * 真要修需要一层中文数字朗读归一（基数/序数、年份逐位读、量词），
 * 超出「确定性字符计数」这个任务的范围，记在这里。
 */
function spokenLength(text: string): number {
  return [...text
    .replace(/[\u200B-\u200D\uFEFF]/gu, "")
    .replace(/[\s\p{P}\p{S}]+/gu, "")].length;
}

export function estimateSeconds(text: string, charsPerSecond: number): number {
  if (charsPerSecond <= 0) throw new Error("charsPerSecond must be positive");
  return spokenLength(text) / charsPerSecond;
}

export type BreathKind = "long" | "short";

/**
 * 判别联合，不是「可选字段 + 注释约定」：short 必须带句内位置，long 必须不带。
 * 写成 `charOffset?: number` 的话，TS 在 `kind === "long"` 分支里不会把它窄化掉，
 * 也拦不住以后有人给 long 塞一个 charOffset。序列化成 JSON 给 Swift 端消费时
 * 形状完全一样。
 */
export type BreathMark =
  | { sentenceIndex: number; kind: "long" }
  | { sentenceIndex: number; kind: "short"; charOffset: number };

const INTERNAL = /[，、；：,;:]/u;

/**
 * ⑨ 气口：句末标点 = 长气口，句中顿号逗号 = 短气口。
 * 比让模型猜准，而且确定性——同一份稿两次跑出来一模一样。
 */
export function breathMarks(sentences: string[]): BreathMark[] {
  const marks: BreathMark[] = [];
  sentences.forEach((sentence, sentenceIndex) => {
    [...sentence].forEach((ch, charOffset) => {
      if (INTERNAL.test(ch)) marks.push({ sentenceIndex, kind: "short", charOffset });
    });
    marks.push({ sentenceIndex, kind: "long" });
  });
  return marks;
}
