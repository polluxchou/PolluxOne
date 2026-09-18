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
    // 部分 factId 解析不到时静默丢弃：只会让 independence 变小，claim 被标得
    // 更弱，是安全方向。但**全部**解析不到意味着调用方传的 facts 和产出
    // claims 的那份不是同一个数组——那时 independence 会是 0，而这条毫无
    // 信源支撑的说法仍会被标成 weak 进稿。那是调用方的 bug，响亮地失败。
    const cited = claim.factIds
      .map((id) => sourceOfFact.get(id))
      .filter((id): id is string => id !== undefined);
    if (claim.factIds.length > 0 && cited.length === 0) {
      throw new Error(
        `claim ${claim.id} cites ${claim.factIds.length} fact(s), none of which are in the facts array`,
      );
    }
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
