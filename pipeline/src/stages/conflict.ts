import type { ClaimId, MergedClaim } from "../domain/types.js";

export type Pair = [ClaimId, ClaimId];

const keyOf = (a: ClaimId, b: ClaimId): string => (a < b ? `${a}|${b}` : `${b}|${a}`);

/**
 * 已经被 findNumericConflicts 标过的对不必再问模型——那一步是代码判的，
 * 比模型更可靠，也更便宜。
 */
export function pairsToCheck(claims: MergedClaim[], alreadyKnown: Pair[] = []): Pair[] {
  const known = new Set(alreadyKnown.map(([a, b]) => keyOf(a, b)));
  const out: Pair[] = [];
  for (let i = 0; i < claims.length; i++) {
    for (let j = i + 1; j < claims.length; j++) {
      const a = claims[i]!.id;
      const b = claims[j]!.id;
      if (known.has(keyOf(a, b))) continue;
      out.push([a, b]);
    }
  }
  return out;
}

export function buildConflictPrompt(claims: MergedClaim[], pairs: Pair[]): string {
  const textById = new Map(claims.map((c) => [c.id, c.text]));
  const lines = pairs.map(
    ([a, b]) => `- ${a}: ${textById.get(a)}\n  ${b}: ${textById.get(b)}`,
  );
  return [
    "判断下面每一对陈述是否**互相矛盾**——即两者不可能同时为真。",
    "",
    "注意：角度不同、详略不同、互为补充，都**不算**矛盾。",
    "只有当一条为真会使另一条为假时，才算矛盾。",
    "",
    '输出 JSON：{"pairs":[{"a":"c0","b":"c1","conflict":true}]}',
    "",
    "待判断：",
    ...lines,
  ].join("\n");
}

export interface ConflictReply {
  pairs?: { a: string; b: string; conflict: unknown }[];
}

/**
 * 判决权在代码：模型只回答一个二分类，冲突图由这里构造。
 * 含糊的回答一律当"不冲突"——把好数据误杀成 conflicted 会让稿子变空，
 * 而真冲突还有数字检测那一层兜着。
 */
export function parseConflictReply(
  reply: ConflictReply,
  knownIds?: Set<ClaimId>,
): Pair[] {
  if (!Array.isArray(reply?.pairs)) return [];

  const out: Pair[] = [];
  for (const item of reply.pairs) {
    if (item?.conflict !== true) continue;
    if (typeof item.a !== "string" || typeof item.b !== "string") continue;
    if (knownIds && (!knownIds.has(item.a) || !knownIds.has(item.b))) continue;
    out.push([item.a, item.b]);
  }
  return out;
}
