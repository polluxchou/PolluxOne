import { DEFAULT_CHARS_PER_SECOND, type ScriptLanguage } from "./prosody.js";

/** §7：近 10 次的中位数。 */
export const RECENT_SAMPLE_WINDOW = 10;

/**
 * 中位数而不是平均数：一次读错稿、中途停顿的 take 会产生一个极端值，
 * 平均数会被它拖走，中位数不会。
 */
export function medianRate(rates: number[]): number | null {
  if (rates.length === 0) return null;
  const sorted = [...rates].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
}

/**
 * 没有历史样本时退回语种默认值。这意味着**新用户的第一篇稿必然不是按他的语速**——
 * spec §9.2 ① 明确要求产品文案不能上来就说「按你的语速」。iOS 侧 `Brief.pacedToUser`
 * 守的就是这条：这个函数走到 `??` 右边时，那个字段必须是假。
 */
export function resolveCharsPerSecond(language: ScriptLanguage, rates: number[]): number {
  return medianRate(rates.slice(-RECENT_SAMPLE_WINDOW)) ?? DEFAULT_CHARS_PER_SECOND[language];
}
