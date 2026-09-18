import type { Fact, MergedClaim } from "../domain/types.js";
import { jaccard, shingles, TEXT_SHINGLE_K } from "./shingle.js";

/** 数字一致时，文本相似到这个值就算同一件事。 */
export const MERGE_JACCARD = 0.45;
/** 两边都没有数字时，门槛抬高——没有数字可对，只能更信文本。 */
export const MERGE_JACCARD_NO_NUMBERS = 0.7;

/**
 * 一句话里的全部数字，排序后作为签名。
 * 数字是口播稿里最容易翻车的东西：**数字不一致，绝不归并**。
 * 单位暂不解析（「23 亿美元」只取 23）——单位差异留给下一个计划的语义冲突检测。
 */
export function numericSignature(text: string): string[] {
  const found = text.match(/\d+(?:\.\d+)?/g) ?? [];
  return [...found].sort();
}

function sameNumbers(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

/**
 * ④ 归并：说同一件事的 Fact 合成一个 Claim。
 * 返回 MergedClaim——independence 和 confidence 是 ⑤ 的事，这里连字段都没有。
 */
export function mergeFacts(facts: Fact[]): MergedClaim[] {
  const parent = facts.map((_, i) => i);
  const find = (i: number): number => {
    let root = i;
    while (parent[root] !== root) root = parent[root]!;
    return root;
  };
  const union = (a: number, b: number): void => {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  };

  const prints = facts.map((f) => shingles(f.text, TEXT_SHINGLE_K));
  const numbers = facts.map((f) => numericSignature(f.text));

  for (let i = 0; i < facts.length; i++) {
    for (let j = i + 1; j < facts.length; j++) {
      const na = numbers[i]!;
      const nb = numbers[j]!;
      if (!sameNumbers(na, nb)) continue;

      const bar = na.length === 0 ? MERGE_JACCARD_NO_NUMBERS : MERGE_JACCARD;
      if (jaccard(prints[i]!, prints[j]!) >= bar) union(i, j);
    }
  }

  const byRoot = new Map<number, number[]>();
  for (let i = 0; i < facts.length; i++) {
    const root = find(i);
    const bucket = byRoot.get(root);
    if (bucket) bucket.push(i);
    else byRoot.set(root, [i]);
  }

  return [...byRoot.values()].map((indices, n) => {
    // 最长的措辞信息量最大，用它当 Claim 的表述
    const longest = indices.reduce((best, i) =>
      facts[i]!.text.length > facts[best]!.text.length ? i : best, indices[0]!);
    return {
      id: `c${n}`,
      text: facts[longest]!.text,
      factIds: indices.map((i) => facts[i]!.id),
    } satisfies MergedClaim;
  });
}
