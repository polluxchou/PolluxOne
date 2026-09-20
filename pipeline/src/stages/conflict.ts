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

/**
 * ⑤ 语义那一半问模型的那句话。
 *
 * 判据**不是**逻辑上的不可同时为真。这一步存在的理由是 spec §5.1 的
 * 「敢说这条别播」：两条摆进同一篇稿子会让听众无所适从的，就不能一起播。
 * 「官方否认将要降准」和「消息人士称降准已定」在逻辑上完全可以同时为真
 * （官方确实否认了，消息人士也确实那么说了），拿「不可同时为真」去问，
 * 模型答 `conflict: false` 是**答对了**——错的是判据。实跑五篇问了九百多对、
 * 判出零个冲突，包括专门埋进 mock 的那一对，就是这么漏的。
 *
 * 错误方向是不对称的，所以给正反两组例子而不只是一句话：误杀好数据会让
 * strong 掉到 `MINIMUM_STRONG_CLAIMS` 以下、把一篇好稿翻成「不建议播」，
 * 用户看得见；漏掉真冲突是把互相打架的两条一起播出去，用户看不见。
 * 反例那一组守的就是 §5 原文那句警告：角度不同、详略不同、互为补充不算矛盾。
 */
export function buildConflictPrompt(claims: MergedClaim[], pairs: Pair[]): string {
  const textById = new Map(claims.map((c) => [c.id, c.text]));
  const lines = pairs.map(
    ([a, b]) => `- ${a}: ${textById.get(a)}\n  ${b}: ${textById.get(b)}`,
  );
  return [
    "判断下面每一对陈述**能不能一起播**。",
    "",
    "判据不是「逻辑上能不能同时为真」，而是：这两条并排写进同一篇口播稿，",
    "听众听完会不会不知道该信哪一条。只要它们对**同一件事**给出了互相打架的",
    "说法，就算两句各自都属实，也算冲突——「官方否认」和「消息人士证实」",
    "可以同时是真话，但一起播出去就是自相矛盾。",
    "",
    "算冲突（conflict: true）——同一件事，说法实质上打架：",
    "- 「官方否认将要降准」对「消息人士称降准已定」",
    "  两句话都可能属实，但听众听完不知道到底降不降。",
    "- 「事故造成 3 人遇难」对「官方通报无人员伤亡」",
    "  同一件事的同一个维度，两个说法对不上。",
    "- 「会谈已取消」对「会谈如期举行」",
    "  同一件事，发生了和没发生。",
    "- 「该公司确认将裁员」对「该公司称没有裁员计划」",
    "  同一个主体对同一件事给出相反的口径。",
    "",
    "不算冲突（conflict: false）——并排播出去没有任何别扭：",
    "- 「降准释放长期资金约 1 万亿元」对「存款准备金率下调 0.5 个百分点」",
    "  同一件事的两个侧面，互为补充。",
    "- 「新政 3 月 15 日起生效」对「银行已开始前移信贷投放节奏」",
    "  一条说政策，一条说反应，讲的是链条的两端。",
    "- 「多家银行下调存款利率」对「某银行下调存款利率 10 个基点」",
    "  详略不同，后者是前者的一个具体例子。",
    "- 「分析师认为宽松还会继续」对「分析师认为宽松已近尾声」",
    "  不同的人对未来的不同看法，本来就该并陈，不是事实打架。",
    "- 「上午召开发布会」对「下午发布联合公报」",
    "  同一天里先后发生的两件事，不是同一件事的两个版本。",
    "",
    "拿不准就填 false。把互为补充的好数据误判成冲突会让稿子变空，",
    "代价比漏掉一对更大。",
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
