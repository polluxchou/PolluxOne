// pipeline/src/run.ts
import { buildBrief, type CoreResult } from "./core.js";
import type { DraftSentence, Fact, MergedClaim, Source } from "./domain/types.js";
import type { Article } from "./net/jina.js";
import type { Pair } from "./stages/conflict.js";
import { toSource } from "./stages/fetch.js";
import { selectCandidates } from "./stages/search.js";
import { verifyQuotes, type RejectedFact } from "./stages/verify-quote.js";

/** 一轮调研最多抓这么多篇扩展报道。抓取按篇计费，上限必须是个明写的数。 */
export const MAX_CANDIDATES = 8;

/**
 * 少于这么多篇就不成稿。
 *
 * 和 `select.ts` 的 `MINIMUM_STRONG_CLAIMS` 数值相同但**是两回事**：那个问
 * 「一篇稿要几条 strong 打底」，这个问「值不值得开始往下花钱」。
 */
export const MINIMUM_SOURCES = 3;

/**
 * 每个外部动作一个端口，测试喂替身，全程离线。
 *
 * 这个接口的存在本身就是 spec §11「管线最关键的逻辑全部可以离线测试」的
 * 兑现方式：`runPipeline` 自己一次 fetch 都不发，网络和模型全在这五个函数
 * 后面，由 `cli.ts` 在真正要花钱的时候才装配进来。
 */
export interface Ports {
  readArticle: (url: string) => Promise<Article>;
  findSources: (headline: string) => Promise<string[]>;
  extractFacts: (source: Source) => Promise<Fact[]>;
  /**
   * ⑤ 的语义一半。**目前还没有接进来**：`buildBrief` 只收 sources / facts /
   * draft，冲突图是 `classifyClaims` 内部靠 `findNumericConflicts` 自己算的，
   * 没有任何入口能把模型判出来的这几对喂进去。
   *
   * 端口留在这里是为了记着这个缺口，而不是假装它接好了。真要接通，得让内核
   * 多收一个「外部冲突对」参数——那是内核的设计变更，不在本任务范围内。
   * 在那之前宁可不调用它：调了也只能丢掉，白花一次模型钱，还会让人以为
   * 语义冲突已经在把关了。
   */
  findSemanticConflicts: (claims: MergedClaim[]) => Promise<Pair[]>;
  draftScript: (
    claims: CoreResult["claims"],
    durationSec: number,
    register: number,
  ) => Promise<DraftSentence[]>;
}

export interface RunOptions {
  durationSec: number;
  register: number;
  charsPerSecond: number;
}

export type RunResult =
  | {
      status: "insufficient";
      sources: Source[];
      reason: string;
      rejectedQuotes: RejectedFact[];
      /** 连内核都没跑到（信源太少）时没有这个字段。 */
      core?: CoreResult;
    }
  | { status: "ok"; sources: Source[]; rejectedQuotes: RejectedFact[]; core: CoreResult };

/**
 * ①②③ 拿输入，④⑤⑥⑧⑨ 交给已建成的确定性内核，⑦ 放在最后。
 *
 * 顺序上有两处是**产品决定**，不是实现顺手：
 *
 * 1. 够不够出稿的判断全部排在成稿之前。拒绝出稿是 spec §5.1 的功能
 *    （「敢说这条别播」），而成稿又恰好是最贵的一次调用——两条理由指向
 *    同一个顺序。
 * 2. 一个候选源抓不下来只跳过。它只是少一个源，不是全盘皆输。
 */
export async function runPipeline(
  url: string,
  options: RunOptions,
  ports: Ports,
): Promise<RunResult> {
  // ① 原文
  const first = await ports.readArticle(url);
  const fetchedAt = new Date().toISOString();
  const sources: Source[] = [toSource("s0", first, fetchedAt)];

  // ② 扩展检索。selectCandidates 在抓取之前就按发布方收敛，省的是抓取的钱。
  const candidates = selectCandidates(
    await ports.findSources(first.title || first.body.slice(0, 80)),
    url,
    MAX_CANDIDATES,
  );

  for (const candidate of candidates) {
    try {
      sources.push(toSource(`s${sources.length}`, await ports.readArticle(candidate), fetchedAt));
    } catch {
      // 一个源抓不下来不该让整轮调研失败——它只是少一个源。
      continue;
    }
  }

  // ③ 抽事实 + 逐字校验。校验是代码做的：模型说「这是逐字引文」只是自述。
  const rawFacts: Fact[] = [];
  for (const source of sources) {
    rawFacts.push(...(await ports.extractFacts(source)));
  }
  const { kept: facts, rejected: rejectedQuotes } = verifyQuotes(rawFacts, sources);

  if (sources.length < MINIMUM_SOURCES) {
    // 在成稿之前就收手：§5.1 的「敢说这条别播」，同时省下最贵的一步。
    return {
      status: "insufficient",
      sources,
      rejectedQuotes,
      reason: `只找到 ${sources.length} 个信源，低于 ${MINIMUM_SOURCES} 个的下限`,
    };
  }

  // ④⑤⑥⑧⑨ 全部是已建成的确定性内核，这里只是喂给它。
  // 第一次传空 draft 是安全的：draft 为空时 bindEvidence 返回 ok 且 evidence 为空，
  // selectClaims 也只在 factSlots 非法时抛，而 estimateBrief 保证 factSlots ≥ 3。
  // 拿的就是它的 claims——⑦ 除了这些 claim 之外不许看到任何别的东西。
  const core = buildBrief({
    durationSec: options.durationSec,
    register: options.register,
    charsPerSecond: options.charsPerSecond,
    sources,
    facts,
    draft: [],
  });

  if (core.selection.verdict === "insufficient") {
    // 源数够了不等于敢播：三篇报道也可能一条 strong 都攒不出来。
    // 上面那条理由在这里同样成立，所以这一步也排在成稿之前——而且这是
    // 真正决定「敢不敢播」的那一关，源数只是它的前哨。
    return {
      status: "insufficient",
      sources,
      rejectedQuotes,
      core,
      reason: `只有 ${core.selection.strongFound ?? 0} 条说法有足够的独立信源支撑，写不出一篇敢播的稿`,
    };
  }

  // ⑦ 成稿——唯一一步「前面都成立才值得花」的调用。
  const draft = await ports.draftScript(core.claims, options.durationSec, options.register);

  // 再跑一遍内核，这次带上稿子：⑧ 的挂信源要拿 draft 才做得了。
  // 内核是纯函数、不花一分钱，重算一遍比维护一条「只补 bind」的旁路便宜。
  const final = buildBrief({
    durationSec: options.durationSec,
    register: options.register,
    charsPerSecond: options.charsPerSecond,
    sources,
    facts,
    draft,
  });

  return { status: "ok", sources, rejectedQuotes, core: final };
}
