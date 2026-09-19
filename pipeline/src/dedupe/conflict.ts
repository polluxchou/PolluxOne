import type { ClaimId, MergedClaim } from "../domain/types.js";
import { quantities } from "./quantity.js";
import { jaccard, shingles, TEXT_SHINGLE_K } from "./shingle.js";

/**
 * 两条 Claim 讲的是不是同一件事。
 *
 * 数值上目前和 `MERGE_JACCARD` 一样，但**故意是独立的常量**，因为两者的失败
 * 方向不同：归并多触发会丢掉一个数字（危险方向），所以它该偏保守；这里两个
 * 方向都有代价，且**不对称**——
 *
 * - 多触发（误杀）：一条好 claim 被扔出稿子。`MINIMUM_STRONG_CLAIMS = 3`，
 *   误杀一次就可能把整篇翻成「不建议播」。难看，但**用户看得见**。
 * - 漏触发（漏检）：两个互相打架的数字一起播出去，而且没有任何提示。
 *   **用户看不见**，所以这个方向更糟。
 *
 * 将来标定时两边该往相反方向调，共用一个数就意味着为了归并调一次，会悄悄
 * 改掉冲突检测的漏检率，而且没有任何东西会报错。
 */
export const CONFLICT_SUBJECT_JACCARD = 0.45;

/** na 的每个量（计重复）都能在 nb 里找到——na 只是说得少，没有和 nb 矛盾。 */
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
 * ⑤ 的确定性一半：文本讲的是同一件事，但**量**对不上。
 *
 * 归并（④）要求 `numericSignature` 一字不差才合并，所以到这里的 Claim 必然是
 * 分开的两条；它们的文本相似度却很高——可能是「两家都在说这件事，但数不
 * 一样」，也可能只是**两家的行文不同**。这两件事必须分得开。
 *
 * **判据是「同一个量纲上给出了不同的值」，不是「④ 的签名不相等」。**
 * ④ 的签名故意把数字后面的两个字一起吃进来（`numericSignature` 里写了为什么），
 * 于是「3 月 15 日生效」和「3 月 15 日起生效」拿到 `15日生` / `15日起`——
 * 两个签名不等，可没有任何一个数字不同。拿签名当矛盾的判据，等于把**任意
 * 行文差异**都读成数字打架。所以这里改比 `quantities()`：数值归一到精确
 * 十进制、量纲归一到一个字符，行文进不来。
 *
 * **子多重集不算冲突。** 「3 月 15 日降准 0.5 个百分点」和「降准 0.5 个百分点」
 * 对共同提到的量完全一致，后者只是没提日期——说得少不等于说得不一样。
 *
 * **残留风险，空集那一头。** 空集是任何集合的子多重集，所以「一条没有数字的
 * claim」和「一条有数字的 claim」永远不报冲突。这在前者**确实不含数字**时
 * 是对的（`23 亿美元` vs `金额未披露`，没有可比的量），在**数字没被认出来**时
 * 是漏检。代码区分不开这两种情形：`quantities()` 只能报告自己取到了什么，
 * 报告不了自己漏看了什么。全角数字这一路已经用 NFKC 堵上了，**中文数字
 * 仍然是敞开的**——「一万亿元」取不出任何量，和「2 万亿元」比就是空集 ⊆
 * 非空集，既不归并也不报冲突。要堵住得先有一层中文数字归一，不在本包范围内。
 *
 * 语义冲突（同一件事、说法相反、没有数字）检不出来，那需要模型，见下一个计划。
 */
export function findNumericConflicts(claims: MergedClaim[]): [ClaimId, ClaimId][] {
  const prints = claims.map((c) => shingles(c.text, TEXT_SHINGLE_K));
  const numbers = claims.map((c) => quantities(c.text));
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
