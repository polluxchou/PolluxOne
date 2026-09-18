/** 5-gram 用于整篇正文比对，2-gram 用于短句比对。 */
export const BODY_SHINGLE_K = 5;
export const TEXT_SHINGLE_K = 2;

/**
 * 归一化到「只剩会影响语义的字符」。三步：
 *
 * 1. `NFKC` 把全角折成半角。中文媒体里全角数字很常见，不折叠的话同一件事
 *    写成 ０５ 和 05 会得到零重叠，两篇一模一样的稿会被判成互相独立的两个源。
 *    这是 JS 内置的，不引依赖。
 * 2. 去掉抓取残留的零宽字符（NFKC 不管这些）。
 * 3. 去掉空白与所有标点/符号。
 *
 * 中文没有词边界，逐字符 shingle 比分词更稳，也不用引分词依赖。
 *
 * **已知局限**：中文数字不会折成阿拉伯数字（「零点五」≠「0.5」）。
 * 真要处理得往上加一层数字归一，不在本包范围内。
 */
export function normalize(text: string): string {
  return text
    .normalize("NFKC")
    .replace(/[\u200B-\u200D\uFEFF]/gu, "")
    .replace(/[\s\p{P}\p{S}]+/gu, "");
}

export function shingles(text: string, k: number): Set<string> {
  const s = normalize(text);
  const out = new Set<string>();
  for (let i = 0; i + k <= s.length; i++) out.add(s.slice(i, i + k));
  return out;
}

/** 空集与空集判为相同：短于 k 的文本本函数无法比较，由调用方负责。 */
export function jaccard(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 && b.size === 0) return 1;
  let shared = 0;
  for (const x of a) if (b.has(x)) shared += 1;
  const union = a.size + b.size - shared;
  return union === 0 ? 1 : shared / union;
}
