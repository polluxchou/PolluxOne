import type { VerifiedClaim } from "../domain/types.js";

const REGISTER_LABELS = [
  "极通俗：像跟朋友聊天，不用任何术语，比喻优先",
  "偏通俗：口语为主，术语出现时立刻用一句话解释",
  "中性：正常的新闻评论语感",
  "偏专业：可以直接使用行业术语，假设听众有基础",
  "专业：面向同行，术语不解释，重点在机制和影响链条",
] as const;

export function registerLabel(register: number): string {
  const clamped = Math.min(1, Math.max(0, register));
  const idx = Math.min(
    REGISTER_LABELS.length - 1,
    Math.round(clamped * (REGISTER_LABELS.length - 1)),
  );
  return REGISTER_LABELS[idx]!;
}

/**
 * ⑦ 成稿的 prompt。
 *
 * **传进来的就是要写进稿子的那几条**——⑥ 的 `Selection.picked`，由
 * `run.ts` 取好、按呈现顺序排好。这里不再自己筛一遍。
 *
 * 以前这里会把 conflicted 的静默滤掉。滤掉本身没错，错在它让「谁决定进稿」
 * 有了两个答案：⑥ 按名额和独立源数挑，这里按 confidence 滤，两个答案不一致
 * 时谁说了算没人知道——而它们确实不一致过，⑥ 挑 5 条、⑦ 写了 15 句就是那样
 * 来的。现在只有一个答案（⑥），于是这里的 conflicted 检查从「悄悄扔掉」改成
 * 「响一声」：真走到这一步说明接线错了，而静默正是上一个缺陷藏起来的方式。
 */
export function buildDraftPrompt(
  claims: VerifiedClaim[],
  durationSec: number,
  register: number,
): string {
  const conflicted = claims.filter((c) => c.confidence === "conflicted");
  if (conflicted.length > 0) {
    throw new Error(
      `conflicted 的 claim 不该被交到成稿这一步：${conflicted.map((c) => c.id).join("、")}` +
        "——⑥ 的 selection.picked 里不会有它们，调用方给错了",
    );
  }
  if (claims.length === 0) {
    throw new Error("没有可用的 claim，不应该走到成稿这一步——上层该出「不建议播」");
  }

  const list = claims
    .map((c) => `- ${c.id}（${c.independence} 个独立信源）：${c.text}`)
    .join("\n");

  return [
    `写一段 ${durationSec} 秒的口播稿。`,
    `语气：${registerLabel(register)}`,
    "",
    "结构要求：",
    "- 开头一句钩子（kind 为 transition），抓注意力，不陈述事实",
    "- 中间是事实句（kind 为 fact），每句必须标明它用了哪几条 claim",
    "- 结尾可以有一句你的判断（kind 为 opinion）",
    "",
    "硬性规则：",
    "- fact 句的 claimIds 不能为空，且只能引用下面列出的 id",
    "- opinion 句和 transition 句的 claimIds 必须是空数组",
    "- 不许写下面列表里没有的事实。一个字都不许编。",
    "",
    '输出 JSON：{"sentences":[{"text":"...","kind":"fact","claimIds":["c0"]}]}',
    "",
    "可用的事实：",
    list,
  ].join("\n");
}
