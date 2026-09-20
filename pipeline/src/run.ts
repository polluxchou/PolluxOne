// pipeline/src/run.ts
import { buildBrief, type CoreResult } from "./core.js";
import { DEFAULT_CHARS_PER_SECOND, detectLanguage } from "./domain/prosody.js";
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
   * ⑤ 的语义一半：数字上看不出来、但两条不能一起播的分歧——「官方否认将要
   * 降准」对「消息人士称降准已定」，两句话一个数字都没有，
   * `findNumericConflicts` 永远判不出来。
   *
   * 判据是「摆进同一篇稿子会让听众无所适从」，**不是**「逻辑上不可同时为真」：
   * 上面那一对在逻辑上完全可以同时为真（官方确实否认了，消息人士也确实那么
   * 说了），按后者去问，模型答「不冲突」并没有答错。判据的正文在
   * `buildConflictPrompt`，这里的例子和那边的例子必须是同一套。
   *
   * 判定结果经 `CoreInput.externalConflicts` 并回内核的冲突图，和代码判出来的
   * 数字冲突**合并**。判决权仍在代码：模型只回一个二分类。
   */
  findSemanticConflicts: (claims: MergedClaim[]) => Promise<Pair[]>;
  /**
   * ⑦ 成稿。`charsPerSecond` 是**靶子和尺子共用的那一个语速**：目标字数
   * 由它乘时长算出来，事后 `core.seconds` 也由它量。两处用两个数的话，
   * 「差了多少」本身就是假的。
   *
   * 它可选，是为了那些手上根本没有语速的调用方（脚本、测试）——见
   * `resolveDraftRate`：不传就按 claim 文本的语种取默认值，而不是让每个
   * 调用方各编一个数。`runPipeline` 自己**永远传**。
   */
  draftScript: (
    claims: CoreResult["claims"],
    durationSec: number,
    register: number,
    charsPerSecond?: number,
  ) => Promise<DraftSentence[]>;
}

export interface RunOptions {
  durationSec: number;
  register: number;
  /**
   * 该用户的实测语速（§7 近 10 次的中位数）。**没有就别传**——不传时
   * `runPipeline` 会照 ① 抓回来的正文判语种，取 `DEFAULT_CHARS_PER_SECOND`。
   *
   * 这比调用方自己先垫一个值强：调用方在抓到正文之前无从判断语种，垫出来的
   * 只能是中文那个 5，于是一篇英文稿会被按 5 字/秒 定靶（60 秒要 300 个英文
   * 字符，实际约 960），拨盘从一开始就错了一个量级。
   */
  charsPerSecond?: number;
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

  // 语速在这里定下来，全程只有这一个值：⑦ 拿它定目标字数，最后一遍 buildBrief
  // 拿它算 `seconds`，App 上显示的也是同一个数。用户有实测语速就用他的；没有就
  // 照**用户自己给的那篇**正文判语种——稿子是照它里面的事实写的，语种一致。
  const charsPerSecond =
    options.charsPerSecond ??
    DEFAULT_CHARS_PER_SECOND[detectLanguage(`${first.title} ${first.body}`)];

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

  // ④⑤⑥⑧⑨ 全部是已建成的确定性内核，这里只是喂给它。内核是纯函数、不花
  // 一分钱，所以下面跑了三遍——每一遍手上多知道一件事，重算一遍都比维护一条
  // 「只补这一步」的旁路便宜。真正要计次的是夹在中间的那两次模型调用。
  const base = {
    durationSec: options.durationSec,
    register: options.register,
    charsPerSecond,
    sources,
    facts,
  };

  // 源数够了不等于敢播：三篇报道也可能一条 strong 都攒不出来。这是真正决定
  // 「敢不敢播」的那一关，源数只是它的前哨。
  const insufficient = (core: CoreResult): RunResult => ({
    status: "insufficient",
    sources,
    rejectedQuotes,
    core,
    reason: `只有 ${core.selection.strongFound ?? 0} 条说法有足够的独立信源支撑，写不出一篇敢播的稿`,
  });

  // 第一遍只为拿 claims：⑤ 的语义一半要有成形的 claim 才问得了模型。
  // 传空 draft 是安全的：draft 为空时 bindEvidence 返回 ok 且 evidence 为空，
  // selectClaims 也只在 factSlots 非法时抛，而 estimateBrief 保证 factSlots ≥ 3。
  const preSemantic = buildBrief({ ...base, draft: [] });
  // 这一关排在问模型之前，理由是单向的：冲突只会让 strong 变少、不会变多，
  // 所以此刻就写不出稿的，带上语义冲突之后同样写不出——那笔钱不必花。
  if (preSemantic.selection.verdict === "insufficient") return insufficient(preSemantic);

  // ⑤ 的语义一半。判出来的对并回内核的冲突图，和数字那一层合并。
  const externalConflicts = await ports.findSemanticConflicts(preSemantic.claims);

  // 带着语义冲突再跑一遍。**成稿必须用这一份 claims**：⑦ 拿到的若是第一遍的
  // 结果，互相矛盾的两条会一起写进稿子，⑤ 的语义那一半就等于没做。
  const checked = buildBrief({ ...base, draft: [], externalConflicts });
  // 语义冲突可能正好把最后几条 strong 打掉。那就依然不敢播，成稿照样不花。
  if (checked.selection.verdict === "insufficient") return insufficient(checked);

  // ⑦ 成稿——唯一一步「前面都成立才值得花」的调用。
  // ⑦ 除了这些 claim 之外不许看到任何别的东西。
  //
  // 交给它的是 **⑥ 挑出来的那几条**，不是全部非 conflicted 的。⑥ 的产物以前
  // 只用来判「敢不敢播」，挑完就扔了：气候那篇 picked 是 5 条，成稿却拿到了
  // 全部 14 条、写了 15 句——iOS 阶段条上「选点 5 条」对「成稿 15 句」对不上，
  // 不是数错了，是这一步的结果没传下去。
  //
  // 顺序用 picked 的顺序，不用 claims 的：`Selection.picked` 是「已按呈现顺序
  // 排好」的（strong 在前、同分按独立源数降序），那是 ⑥ 的编辑判断，
  // claims 的下标顺序只是归并的副产物。
  const byId = new Map(checked.claims.map((c) => [c.id, c]));
  // picked 里的 id 全部来自 checked.claims，get 不会落空。
  const picked = checked.selection.picked.map((id) => byId.get(id)!);
  const draft = await ports.draftScript(
    picked,
    options.durationSec,
    options.register,
    charsPerSecond,
  );

  // 最后一遍带上稿子：⑧ 的挂信源要拿 draft 才做得了。冲突图要跟着一起带，
  // 否则最终结果里那几条语义矛盾的 claim 会重新变回 strong。
  const final = buildBrief({ ...base, draft, externalConflicts });

  return { status: "ok", sources, rejectedQuotes, core: final };
}
