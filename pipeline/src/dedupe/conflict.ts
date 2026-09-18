import type { ClaimId, MergedClaim } from "../domain/types.js";
import { numericSignature } from "./merge.js";
import { jaccard, shingles, TEXT_SHINGLE_K } from "./shingle.js";

/**
 * 两条 Claim 讲的是不是同一件事。
 *
 * 数值上目前和 `MERGE_JACCARD` 一样，但**故意是独立的常量**，因为两者的失败
 * 方向相反：归并多触发会丢掉一个数字（危险方向），所以它该偏保守；这里多
 * 触发只是把一条好 claim 扔掉（安全方向），**漏**触发才危险——一个有争议的
 * 数字会被当成定论播出去。将来标定时两边该往相反方向调，共用一个数就意味着
 * 为了归并调一次，会悄悄改掉冲突检测的漏检率，而且没有任何东西会报错。
 */
export const CONFLICT_SUBJECT_JACCARD = 0.45;

/** na 的每个数字（计重复）都能在 nb 里找到——na 只是说得少，没有和 nb 矛盾。 */
function isSubMultiset(na: string[], nb: string[]): boolean {
  const remaining = new Map<string, number>();
  for (const value of nb) remaining.set(value, (remaining.get(value) ?? 0) + 1);
  for (const value of na) {
    const left = remaining.get(value) ?? 0;
    if (left === 0) return false;
    remaining.set(value, left - 1);
  }
  return true;
}

/**
 * ⑤ 的确定性一半：文本讲的是同一件事，但数字对不上。
 *
 * 归并（④）要求签名一致才合并，所以这些 Claim 必然是分开的两条；
 * 它们的文本相似度却很高——这正是「两家都在说这件事，但数不一样」。
 *
 * **子集不算冲突。** 「3 月 15 日降准 0.5 个百分点」和「降准 0.5 个百分点」
 * 对共同提到的数字完全一致，后者只是没提日期——签名长度不等不等于说法不同。
 * 这一条顺带覆盖了「两边都没数字」和「只有一边有数字」：空集是任何集合的子集，
 * 所以不再需要单独的空签名 guard。
 *
 * 语义冲突（同一件事、说法相反、没有数字）检不出来，那需要模型，见下一个计划。
 */
export function findNumericConflicts(claims: MergedClaim[]): [ClaimId, ClaimId][] {
  const prints = claims.map((c) => shingles(c.text, TEXT_SHINGLE_K));
  const numbers = claims.map((c) => numericSignature(c.text));
  const pairs: [ClaimId, ClaimId][] = [];

  for (let i = 0; i < claims.length; i++) {
    for (let j = i + 1; j < claims.length; j++) {
      if (isSubMultiset(numbers[i]!, numbers[j]!) || isSubMultiset(numbers[j]!, numbers[i]!)) continue;
      if (jaccard(prints[i]!, prints[j]!) >= CONFLICT_SUBJECT_JACCARD) {
        pairs.push([claims[i]!.id, claims[j]!.id]);
      }
    }
  }
  return pairs;
}
