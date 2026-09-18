import type { Fact, MergedClaim } from "../domain/types.js";
import { jaccard, shingles, TEXT_SHINGLE_K } from "./shingle.js";
import { createUnionFind } from "./union-find.js";

/** 数字一致时，文本相似到这个值就算同一件事。 */
export const MERGE_JACCARD = 0.45;
/** 两边都没有数字时，门槛抬高——没有数字可对，只能更信文本。 */
export const MERGE_JACCARD_NO_NUMBERS = 0.7;

/** 数字，加上紧跟的最多两个非数字非空白字符。 */
const NUMBER_WITH_UNIT = /(\d+(?:\.\d+)?)\s*([^\d\s]{0,2})/gu;

/**
 * 一句话里的全部「数字 + 单位」，排序后作为签名。
 * 数字是口播稿里最容易翻车的东西：**签名不一致，绝不归并**。
 *
 * 为什么单位必须一起吃进来：只取裸数字时，「涉及金额约 23 亿美元」和
 * 「涉及金额约 23 亿欧元」的签名都是 `["23"]`，而两句的 2-gram 相似度是
 * 0.64，远超归并门槛——它们会被并成一条，其中一种币种**在到达 ⑤ 的冲突
 * 检测之前就消失了**。数字不同本来指望 ⑤ 去判冲突，可这一类 gate 压根
 * 不触发，所以补在这里，不能推给下一个计划。
 *
 * 只吃两个字符是刻意的：「亿美」「亿欧」已经足够区分，再多吃会把
 * 「日起生效」这类行文差异也算进签名，让同一事实的两种措辞不归并。
 * 少归并是安全方向（claim 显得信源更少、被标 weak），多归并不是。
 *
 * 仍然不做单位换算或归一化：「1.50」≠「1.5」、「5%」≠「5 个百分点」，
 * 这些都是漏归并，朝安全方向。
 */
export function numericSignature(text: string): string[] {
  return [...text.matchAll(NUMBER_WITH_UNIT)].map((m) => m[1]! + (m[2] ?? "")).sort();
}

function sameNumbers(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

/**
 * ④ 归并：说同一件事的 Fact 合成一个 Claim。
 * 返回 MergedClaim——independence 和 confidence 是 ⑤ 的事，这里连字段都没有。
 */
export function mergeFacts(facts: Fact[]): MergedClaim[] {
  const uf = createUnionFind(facts.length);

  const prints = facts.map((f) => shingles(f.text, TEXT_SHINGLE_K));
  const numbers = facts.map((f) => numericSignature(f.text));

  for (let i = 0; i < facts.length; i++) {
    for (let j = i + 1; j < facts.length; j++) {
      const na = numbers[i]!;
      const nb = numbers[j]!;
      if (!sameNumbers(na, nb)) continue;

      const bar = na.length === 0 ? MERGE_JACCARD_NO_NUMBERS : MERGE_JACCARD;
      if (jaccard(prints[i]!, prints[j]!) >= bar) uf.union(i, j);
    }
  }

  return uf.groups().map((indices, n) => {
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
