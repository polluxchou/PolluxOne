import type { VerifiedClaim } from "../domain/types.js";
import { lengthTarget, resolveDraftRate } from "./check-length.js";

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
 *
 * **时长以前只是一句「写一段 60 秒的口播稿」**——60 这个数出现在 prompt 里，
 * 却没有任何东西把它翻译成模型能瞄准的量，实跑要 60 秒交了 31 秒。现在多给
 * 两个数：目标字数（时长 × 语速）和句数范围。两个都要给——只说字数，模型
 * 会把它塞进一长句；只说句数，每句多长又没个准。
 *
 * `charsPerSecond` 是这个用户的实测语速，不传就按 claim 的语种取默认值
 * （`resolveDraftRate` 里写了为什么这样解「稿子还没写出来就要知道语种」）。
 * 它可选，是因为**唯一有权威语速的地方是 `CoreInput`**：拿不到那个数的调用方
 * （脚本、测试）不该被逼着自己编一个，编出来的数会和事后量成绩的那把尺不一致。
 */
export function buildDraftPrompt(
  claims: VerifiedClaim[],
  durationSec: number,
  register: number,
  charsPerSecond?: number,
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

  const target = lengthTarget(durationSec, resolveDraftRate(claims, charsPerSecond));

  return [
    `写一段 ${durationSec} 秒的口播稿。`,
    `语气：${registerLabel(register)}`,
    "",
    "长度（硬指标，用户在拨盘上选的就是这个时长）：",
    `- 全篇不计标点约 ${target.chars} 字，${target.minSentences} 到 ${target.maxSentences} 句`,
    "- 短了播不满，长了会当场超时；两者都算没写对",
    // 名额是按时长发的（60 秒只有 3 条），所以「写够长」和「只能用列表里的事实」
    // 在算术上是有张力的。不明说这条合法的加长办法，模型最省力的出路就是编一条。
    "- 同一条 claim 可以连着写几句讲透（背景、机制、对听众意味着什么），每句照常挂它的 id",
    "",
    "结构要求：",
    "- 开头一句钩子（kind 为 transition），抓注意力，不陈述事实",
    "- 中间是事实句（kind 为 fact），每句必须标明它用了哪几条 claim",
    "- 结尾可以有一句你的判断（kind 为 opinion）",
    "",
    "硬性规则：",
    "- fact 句的 claimIds 不能为空，且只能引用下面列出的 id",
    "- opinion 句和 transition 句的 claimIds 必须是空数组",
    "- 不许写下面列表里没有的事实。一个字都不许编。宁可句子长，也不许多一条事实。",
    "",
    '输出 JSON：{"sentences":[{"text":"...","kind":"fact","claimIds":["c0"]}]}',
    "",
    "可用的事实：",
    list,
  ].join("\n");
}
