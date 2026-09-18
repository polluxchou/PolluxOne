import type { ClaimId, VerifiedClaim } from "../domain/types.js";

/** 一篇稿至少要有这么多条 strong 打底，无论拨到多长。spec §5.1。 */
export const MINIMUM_STRONG_CLAIMS = 3;

export interface Selection {
  verdict: "ok" | "insufficient";
  /** 进稿的 Claim，已按呈现顺序排好 */
  picked: ClaimId[];
  /** 检出冲突、因此不进稿的 Claim——④ 不建议播那一屏要列出来 */
  conflicted: ClaimId[];
  reason?: string;
}

/**
 * ⑥ 的确定性一半：谁**有资格**进稿、够不够出稿。
 * 至于进稿的这几条怎么排、钩子怎么下，那是编辑判断，交给模型（下一个计划）。
 */
export function selectClaims(claims: VerifiedClaim[], factSlots: number): Selection {
  const conflicted = claims.filter((c) => c.confidence === "conflicted").map((c) => c.id);

  const byCorroboration = (a: VerifiedClaim, b: VerifiedClaim) =>
    b.independence - a.independence || a.id.localeCompare(b.id);

  const strong = claims.filter((c) => c.confidence === "strong").sort(byCorroboration);
  const weak = claims.filter((c) => c.confidence === "weak").sort(byCorroboration);

  if (strong.length < MINIMUM_STRONG_CLAIMS) {
    return {
      verdict: "insufficient",
      picked: [],
      conflicted,
      reason: `only ${strong.length} strong claims, need ${MINIMUM_STRONG_CLAIMS}`,
    };
  }

  const picked = [...strong, ...weak].slice(0, factSlots).map((c) => c.id);
  return { verdict: "ok", picked, conflicted };
}
