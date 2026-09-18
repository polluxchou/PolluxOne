import type { ClaimId, VerifiedClaim } from "../domain/types.js";

/**
 * 一篇稿至少要有这么多条 strong 打底，无论拨到多长。spec §5.1。
 *
 * 和 `classify.ts` 的 `STRONG_INDEPENDENCE` 数值相同但**是两回事**，别去合并：
 * 那个是「几个独立源才让一条 claim 算 strong」，这个是「一篇稿要几条 strong」。
 */
export const MINIMUM_STRONG_CLAIMS = 3;

export interface Selection {
  verdict: "ok" | "insufficient";
  /** 进稿的 Claim，已按呈现顺序排好 */
  picked: ClaimId[];
  /** 检出冲突、因此不进稿的 Claim——⑥ 不建议播那一屏要列出来 */
  conflicted: ClaimId[];
  /** insufficient 时实际有几条 strong。UI 要用中文说「还差 N 条」，
   *  不能去正则解析下面那句英文。 */
  strongFound?: number;
  /** 给日志和测试看的英文。用户看到的文案由 UI 拿 strongFound 和
   *  MINIMUM_STRONG_CLAIMS 自己拼。 */
  reason?: string;
}

/**
 * ⑥ 的确定性一半：谁**有资格**进稿、够不够出稿。
 * 至于进稿的这几条怎么排、钩子怎么下，那是编辑判断，交给模型（下一个计划）。
 */
export function selectClaims(claims: VerifiedClaim[], factSlots: number): Selection {
  // `slice(0, -1)` 返回的是「除最后一个之外的全部」，不是空数组——名额传成负数
  // 会产出一篇**比该有的更满**的稿子，正是这一阶段要防的方向。
  // 名额来自 estimateBrief，那边保证 ≥ 3；走到这里说明调用方传错了。
  if (!Number.isInteger(factSlots) || factSlots < 0) {
    throw new Error(`factSlots must be a non-negative integer, got ${factSlots}`);
  }

  const conflicted = claims.filter((c) => c.confidence === "conflicted").map((c) => c.id);

  // numeric 排序：默认的 localeCompare 把 "c10" 排在 "c9" 前面，而 6 分钟有
  // 14 个名额，claim 过十条是现实的。同分时谁进稿由这一行决定，不只是显示顺序。
  const byCorroboration = (a: VerifiedClaim, b: VerifiedClaim) =>
    b.independence - a.independence || a.id.localeCompare(b.id, undefined, { numeric: true });

  const strong = claims.filter((c) => c.confidence === "strong").sort(byCorroboration);
  const weak = claims.filter((c) => c.confidence === "weak").sort(byCorroboration);

  if (strong.length < MINIMUM_STRONG_CLAIMS) {
    return {
      verdict: "insufficient",
      picked: [],
      conflicted,
      strongFound: strong.length,
      reason: `only ${strong.length} strong claims, need ${MINIMUM_STRONG_CLAIMS}`,
    };
  }

  const picked = [...strong, ...weak].slice(0, factSlots).map((c) => c.id);
  return { verdict: "ok", picked, conflicted };
}
