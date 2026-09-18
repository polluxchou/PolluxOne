import type { ClaimId, MergedClaim } from "../domain/types.js";
import { MERGE_JACCARD, numericSignature } from "./merge.js";
import { jaccard, shingles, TEXT_SHINGLE_K } from "./shingle.js";

/**
 * ⑤ 的确定性一半：文本讲的是同一件事，但数字对不上。
 *
 * 归并（④）要求数字一致才合并，所以这些 Claim 必然是分开的两条；
 * 它们的文本相似度却很高——这正是「两家都在说这件事，但数不一样」。
 *
 * 语义冲突（同一件事、说法相反、没有数字）检不出来，那需要模型，见下一个计划。
 */
export function findNumericConflicts(claims: MergedClaim[]): [ClaimId, ClaimId][] {
  const prints = claims.map((c) => shingles(c.text, TEXT_SHINGLE_K));
  const numbers = claims.map((c) => numericSignature(c.text));
  const pairs: [ClaimId, ClaimId][] = [];

  for (let i = 0; i < claims.length; i++) {
    for (let j = i + 1; j < claims.length; j++) {
      const na = numbers[i]!;
      const nb = numbers[j]!;
      if (na.length === 0 || nb.length === 0) continue;
      if (na.length === nb.length && na.every((v, k) => v === nb[k])) continue;
      if (jaccard(prints[i]!, prints[j]!) >= MERGE_JACCARD) {
        pairs.push([claims[i]!.id, claims[j]!.id]);
      }
    }
  }
  return pairs;
}
