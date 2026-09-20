import type { ClaimId, Fact, MergedClaim, Source, VerifiedClaim } from "../domain/types.js";
import { findNumericConflicts } from "./conflict.js";
import { groupSources, independenceOf } from "./independence.js";

/** 到这个独立源组数才算「敢播」。spec §5 定的。 */
export const STRONG_INDEPENDENCE = 3;

/** 无序对的规范化键：`[a,b]` 和 `[b,a]` 是同一对。`\0` 不可能出现在 id 里。 */
const pairKey = (a: ClaimId, b: ClaimId): string => (a < b ? `${a}\0${b}` : `${b}\0${a}`);

/**
 * ⑤ 交叉验证：给每条 Claim 填上 independence 与 confidence。
 * 冲突优先级最高——三个独立源都说的话，只要和另一条数字打架，照样不进稿。
 *
 * `externalConflicts` 是 ⑤ 的**语义那一半**的入口：数字对不上由这里的
 * `findNumericConflicts` 判，而「官方否认降准」对「消息人士称降准已定」这种
 * 数字上完全看不出来的矛盾只有模型判得了。模型的判定在内核之外产生，
 * 由调用方喂进来，和代码判出来的那一半**合并**（不是替换）——两层都可能
 * 命中同一对，方向还可能相反，所以按无序对去重。
 *
 * 这个参数有默认值，不传时行为和从前一字不差。
 */
export function classifyClaims(
  claims: MergedClaim[],
  facts: Fact[],
  sources: Source[],
  mediaGroups: Record<string, string> = {},
  externalConflicts: readonly (readonly [ClaimId, ClaimId])[] = [],
): VerifiedClaim[] {
  const groups = groupSources(sources, mediaGroups);
  const sourceOfFact = new Map(facts.map((f) => [f.id, f.sourceId]));

  const conflicts = new Map<ClaimId, ClaimId[]>();
  const seen = new Set<string>();
  for (const [a, b] of [...findNumericConflicts(claims), ...externalConflicts]) {
    // 去重发生在建图之前，所以同一对无论被判了几次、方向如何，
    // conflictsWith 里都只出现一次——下游拿它当「和谁打架」的清单印出来。
    if (seen.has(pairKey(a, b))) continue;
    seen.add(pairKey(a, b));
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
