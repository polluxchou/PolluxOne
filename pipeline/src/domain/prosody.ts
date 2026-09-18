export type ScriptLanguage = "cjk" | "latin";

/**
 * 没有该用户历史语速时的回落值（字符/秒）。
 * **注意：真实语速目前根本没有采集**——见 spec §9.2 ①。
 * 所以新用户的第一篇稿必然走这两个数字，产品文案不能上来就说「按你的语速」。
 */
export const DEFAULT_CHARS_PER_SECOND: Record<ScriptLanguage, number> = {
  cjk: 5.5,
  latin: 14.5,
};

const CJK = /[㐀-䶿一-鿿぀-ヿ가-힯]/u;

export function detectLanguage(text: string): ScriptLanguage {
  let cjk = 0;
  let letters = 0;
  for (const ch of text) {
    if (CJK.test(ch)) cjk += 1;
    else if (/\p{L}/u.test(ch)) letters += 1;
  }
  return cjk > 0 && cjk * 4 >= letters ? "cjk" : "latin";
}

/** 只数会念出声的字符——标点和空白不占时间。 */
function spokenLength(text: string): number {
  return [...text.replace(/[\s\p{P}\p{S}]+/gu, "")].length;
}

export function estimateSeconds(text: string, charsPerSecond: number): number {
  if (charsPerSecond <= 0) throw new Error("charsPerSecond must be positive");
  return spokenLength(text) / charsPerSecond;
}

export type BreathKind = "long" | "short";

export interface BreathMark {
  sentenceIndex: number;
  kind: BreathKind;
  /** short 气口在句内的字符位置；long 气口在句末，不带这个字段。 */
  charOffset?: number;
}

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
