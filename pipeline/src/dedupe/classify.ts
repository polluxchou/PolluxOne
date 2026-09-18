import type { ClaimId, Fact, MergedClaim, Source, VerifiedClaim } from "../domain/types.js";
import { findNumericConflicts } from "./conflict.js";
import { groupSources, independenceOf } from "./independence.js";

/** 到这个独立源组数才算「敢播」。spec §5 定的。 */
export const STRONG_INDEPENDENCE = 3;

/**
 * ⑤ 交叉验证：给每条 Claim 填上 independence 与 confidence。
 * 冲突优先级最高——三个独立源都说的话，只要和另一条数字打架，照样不进稿。
 */
export function classifyClaims(
  claims: MergedClaim[],
  facts: Fact[],
  sources: Source[],
  mediaGroups: Record<string, string> = {},
): VerifiedClaim[] {
  const groups = groupSources(sources, mediaGroups);
  const sourceOfFact = new Map(facts.map((f) => [f.id, f.sourceId]));

  const conflicts = new Map<ClaimId, ClaimId[]>();
  for (const [a, b] of findNumericConflicts(claims)) {
    conflicts.set(a, [...(conflicts.get(a) ?? []), b]);
    conflicts.set(b, [...(conflicts.get(b) ?? []), a]);
  }

  return claims.map((claim) => {
    const cited = claim.factIds
      .map((id) => sourceOfFact.get(id))
      .filter((id): id is string => id !== undefined);
    const independence = independenceOf(cited, groups);
    const against = conflicts.get(claim.id) ?? [];

    return {
      ...claim,
      independence,
      conflictsWith: against,
      confidence: against.length > 0
        ? "conflicted"
        : independence >= STRONG_INDEPENDENCE ? "strong" : "weak",
    } satisfies VerifiedClaim;
  });
}
