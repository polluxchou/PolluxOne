import { DEFAULT_CHARS_PER_SECOND, detectLanguage, estimateSeconds } from "../domain/prosody.js";
import type { DraftSentence } from "../domain/types.js";

/**
 * ⑦ 的长度检查。**刻意和 `validate-draft.ts` 分开，连返回类型都不共用。**
 *
 * 那边管的是 §6.2 的结构保证（fact 句必挂 claim、opinion 句不许挂、不许引用
 * 不存在的 claim）——违反了就是稿子不能用。这边管的是「拨盘上的时长有没有被
 * 兑现」——差了就是稿子不好用。两类问题的处置完全相反：结构违规两次都过不了
 * 就必须抛，长度不对再差也要把稿子交出去。共用一个 `Problem` 清单的话，重跑时
 * 那句抱怨里会同时混着「第 3 句没挂信源」和「整篇短了一半」，模型不知道该先
 * 改哪个，我们看日志也说不清到底是哪一类失败——「截断 vs 输出不合规」共用一条
 * 错误路径那次白烧 24000 token，就是这么来的。
 */

/**
 * 一句口播大约值多少秒。
 *
 * 不是拍的：从 `ios/Pollux One/Resources/demo-briefs` 那五份**真跑出来的**稿子
 * 数出来的——按 `estimateSeconds` 的口径（不计标点）每句 32 字，五份各自的
 * 均值落在 5.3–7.3 秒之间。取 [5, 8] 把五份全括住，还留一点余量。
 *
 * 写成「秒/句」而不是「字/句」是关键：一句话念多久基本与语种无关，
 * 而一句话多少个字随语种差三倍（中文 32 字 ≈ 拉丁 100 字符）。句数范围用秒来
 * 推，中英文各自都成立；用字数推的话，60 秒的英文稿会被要求写 24–38 句。
 */
export const SECONDS_PER_SENTENCE = { short: 5, long: 8 } as const;

/**
 * 容差。**两个方向不对称，因为两个方向的后果不对称**：
 *
 * - 长了会**当场超时**——用户按拨盘选了 1 分钟，多半是因为那边有个 1 分钟的
 *   硬头。而且 `estimateSeconds` 对数字是**系统性低估**的（见 prosody.ts：
 *   「0.5」按 2 个字符算，念出来是 3 个音节），首发场景又恰好是数字最密的
 *   财经口播——所以测出来 1.05 的稿子，真念可能已经 1.1 了。上限只给 5%。
 * - 短了只是稿子单薄，至少播得完。给 15%。
 *
 * 15% 这个上限也不是随手取的：拨盘相邻两档里最近的一对是 45→60 秒（+33%），
 * 容差必须小于它的一半，否则「落在容差内」可以意味着「你其实拿到了隔壁那一档」，
 * 拨盘的分辨率就白给了。
 */
export const LENGTH_TOLERANCE = { under: 0.15, over: 0.05 } as const;

/**
 * 容差的秒数下限：半句话。
 *
 * 比例容差在短档上会紧到模型够不着——30 秒档的 5% 只有 1.5 秒，不到四分之一
 * 句，而模型能调的最小单位就是一句话（删一句或加一句）。比半句话还紧的要求
 * 只会白花一次 `deepseek-v4-pro` 的重跑钱，换不回更准的长度。
 */
export const MIN_SLACK_SEC = 3;

export interface LengthTarget {
  /** 拨盘上选的那个秒数。 */
  durationSec: number;
  /** 既拿来定靶子、也拿来量成绩的那一个语速。见 `resolveDraftRate`。 */
  charsPerSecond: number;
  /** 目标字数，**不计标点**——和 `estimateSeconds` 的口径一致。 */
  chars: number;
  minSeconds: number;
  maxSeconds: number;
  minSentences: number;
  maxSentences: number;
}

/**
 * 目标字数要按语速算，而语速按**语种**不同（中文 5 字/秒、拉丁 16 字/秒）；
 * 可稿子的语种要等稿子写出来才知道——鸡生蛋。解法分两步：
 *
 * 1. **同一个数既当靶子又当尺子。** 定目标用哪个语速，事后量成绩
 *    （`core.seconds`、App 上显示的 `estimatedSeconds`）就用哪个。于是这个
 *    循环自洽：语速取得准不准是另一个问题（§9.2 ①：真实语速根本还没采集），
 *    但「要求 60 秒却交 31 秒」这种口径内的偏差，一定测得出来。两处用两个数
 *    才是真的没救——那样连「差了多少」都是假的。
 * 2. **蛋还没生出来，但下蛋的鸡在手上。** 稿子是照着 claim 写的，claim 是从
 *    正文里逐字抠出来的，三者同一个语种。所以拿 claim 文本去 `detectLanguage`，
 *    是「稿子的语种」在稿子存在之前最贴的代理——比 `cli.ts` 原来那句「抓到正文
 *    之前无从判断语种，只能先用中文的回落值」准，英文稿不会再被按 5 字/秒 定靶。
 *
 * `measured` 是这个用户的实测语速（§7 近 10 次的中位数）。**有就一定用它**：
 * App 上显示的秒数是按他的语速算的，靶子按语种默认值定的话，念得慢的人永远
 * 看到一个比拨盘大的数。
 */
export function resolveDraftRate(
  claims: readonly { text: string }[],
  measured?: number,
): number {
  if (measured !== undefined && Number.isFinite(measured) && measured > 0) return measured;
  return DEFAULT_CHARS_PER_SECOND[detectLanguage(claims.map((c) => c.text).join(""))];
}

export function lengthTarget(durationSec: number, charsPerSecond: number): LengthTarget {
  if (!(durationSec > 0)) throw new Error("durationSec must be positive");
  if (!(charsPerSecond > 0)) throw new Error("charsPerSecond must be positive");

  // 比例容差和半句话取大者——短档上比例带会紧到模型够不着。
  const slack = (fraction: number): number => Math.max(durationSec * fraction, MIN_SLACK_SEC);

  return {
    durationSec,
    charsPerSecond,
    chars: Math.round(durationSec * charsPerSecond),
    minSeconds: Math.max(0, durationSec - slack(LENGTH_TOLERANCE.under)),
    maxSeconds: durationSec + slack(LENGTH_TOLERANCE.over),
    // 下限至少 2 句：一句钩子加一句事实是「一篇稿」的最小形状。
    minSentences: Math.max(2, Math.round(durationSec / SECONDS_PER_SENTENCE.long)),
    maxSentences: Math.max(3, Math.round(durationSec / SECONDS_PER_SENTENCE.short)),
  };
}

export interface LengthOk {
  ok: true;
  seconds: number;
  chars: number;
  sentences: number;
}

export interface LengthMiss {
  ok: false;
  seconds: number;
  chars: number;
  sentences: number;
  direction: "too-short" | "too-long";
  /** 实测 ÷ 目标。0.52 = 只有一半，1.3 = 长了三成。 */
  ratio: number;
  /** 还差多少字：正数要加，负数要删。不计标点。 */
  charsOff: number;
}

export type LengthCheck = LengthOk | LengthMiss;

/**
 * 量的是**不计标点的可朗读字数**（`estimateSeconds` 的口径），不是 `text.length`。
 * 两者能差一成——中文标点密，按 `length` 量会让每一篇都虚长一截。
 *
 * **只判总时长，不判句数。** 句数范围是写进 prompt 的手段（防止模型把目标字数
 * 塞进一长句），不是验收标准：一篇刚好 60 秒却只有 7 句的稿子没有任何问题，
 * 为这个去重跑一次 `deepseek-v4-pro` 是白花钱。
 */
export function checkDraftLength(
  sentences: readonly DraftSentence[],
  target: LengthTarget,
): LengthCheck {
  const seconds = sentences.reduce(
    (total, s) => total + estimateSeconds(s.text, target.charsPerSecond),
    0,
  );
  const chars = Math.round(seconds * target.charsPerSecond);
  const shape = { seconds, chars, sentences: sentences.length };

  if (seconds >= target.minSeconds && seconds <= target.maxSeconds) return { ok: true, ...shape };
  return {
    ok: false,
    ...shape,
    direction: seconds > target.maxSeconds ? "too-long" : "too-short",
    ratio: seconds / target.durationSec,
    charsOff: target.chars - chars,
  };
}

const pct = (ratio: number): string => `${Math.round(ratio * 100)}%`;

/** 一行人话，给 stderr。重跑之后仍然不达标时也要把这行如实打出来。 */
export function describeLength(check: LengthCheck, target: LengthTarget): string {
  const head =
    `目标 ${target.durationSec} 秒／${target.chars} 字，` +
    `实得 ${check.seconds.toFixed(1)} 秒／${check.chars} 字（${check.sentences} 句）`;
  return check.ok ? `⑦ 长度：${head}，在容差内` : `⑦ 长度：${head}，是目标的 ${pct(check.ratio)}`;
}

/**
 * 重跑时说给模型听的那段话。**要把差了多少说成一个数**——只说「太短了」，
 * 模型不知道是差两句还是差一半。
 *
 * 加长那一条必须同时堵死唯一的歪路：名额有限（60 秒只有 3 条 claim），
 * 想写够长而手上事实不够时，模型最省力的做法就是编一条。
 */
export function lengthComplaint(miss: LengthMiss, target: LengthTarget): string {
  const want =
    `目标是不计标点 ${target.chars} 字、约 ${target.durationSec} 秒、` +
    `${target.minSentences}–${target.maxSentences} 句`;
  const got = `上一版只有 ${miss.chars} 字、约 ${miss.seconds.toFixed(0)} 秒、${miss.sentences} 句`;

  if (miss.direction === "too-short") {
    return [
      `整篇太短：${got}，${want}（只有目标的 ${pct(miss.ratio)}）。`,
      `再写一遍，补足约 ${miss.charsOff} 字。`,
      "补长度的合法办法只有一个：把已经列出的事实讲透——背景、机制、对听众意味着什么。",
      "同一条 claim 可以连着写几句，每一句照常挂它的 id。",
      "列表之外的事实一个字都不许编，宁可句子长一点也不许多一条事实。",
    ].join("\n");
  }
  return [
    `整篇太长：上一版有 ${miss.chars} 字、约 ${miss.seconds.toFixed(0)} 秒、${miss.sentences} 句，` +
      `${want}（是目标的 ${pct(miss.ratio)}）。`,
    `再写一遍，砍掉约 ${-miss.charsOff} 字——长了会当场超时，这一条比写得漂亮重要。`,
    "先砍修饰和重复的铺垫，再合并讲同一条 claim 的句子。",
    "不许靠删掉事实来变短：列出来的 claim 还是要都用上。",
  ].join("\n");
}
