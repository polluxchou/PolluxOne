import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { loadConfig, type Config } from "./config/env.js";
import { buildBrief, type CoreInput } from "./core.js";
import { findNumericConflicts } from "./dedupe/conflict.js";
import type { DraftSentence } from "./domain/types.js";
import { DeepSeekClient, DEFAULT_MAX_TOKENS, type Sender } from "./models/deepseek.js";
import { TokenLedger } from "./models/ledger.js";
import { ZhipuSearchClient } from "./models/zhipu-search.js";
import { readArticle } from "./net/jina.js";
import { runPipeline, type Ports, type RunOptions } from "./run.js";
import {
  checkDraftLength,
  describeLength,
  lengthComplaint,
  lengthTarget,
  resolveDraftRate,
  type LengthMiss,
} from "./stages/check-length.js";
import {
  buildConflictPrompt,
  pairsToCheck,
  parseConflictReply,
  type ConflictReply,
} from "./stages/conflict.js";
import { buildDraftPrompt } from "./stages/draft.js";
import { buildExtractPrompt, parseExtractReply, type ExtractReply } from "./stages/extract.js";
import { validateDraft, type Problem } from "./stages/validate-draft.js";

/**
 * 从磁盘读进来的东西只是**形状像** CoreInput，`as` 一个检查都不做。
 * 这三类畸形输入的后果都不是「报错」：
 *
 * - 缺 `facts` → 在 `mergeFacts` 里抛一个看不懂的 TypeError
 * - `durationSec` 写成非数字字符串 → `snapDuration` 每次比较都是 NaN，
 *   `NaN < NaN` 恒假，reduce 从不更新，**静默返回 30 秒**——一个看起来
 *   很合理的错答案（实测过）
 * - fact 指向不存在的 source → 悄悄少算独立源，没有任何提示
 *
 * 这个文件是磁盘和类型化代码之间的信任边界，检查就该在这里，不必引校验库。
 */
function validate(raw: unknown, path: string): CoreInput {
  const bad = (why: string): never => {
    throw new Error(`${path}: ${why}`);
  };
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) bad("expected a JSON object");
  const o = raw as Record<string, unknown>;

  for (const key of ["durationSec", "register", "charsPerSecond"] as const) {
    if (typeof o[key] !== "number" || !Number.isFinite(o[key])) {
      bad(`${key} must be a finite number, got ${JSON.stringify(o[key])}`);
    }
  }
  for (const key of ["sources", "facts", "draft"] as const) {
    if (!Array.isArray(o[key])) bad(`${key} must be an array, got ${JSON.stringify(o[key])}`);
  }

  const input = o as unknown as CoreInput;
  const known = new Set(input.sources.map((s) => s.id));
  for (const fact of input.facts) {
    if (!known.has(fact.sourceId)) bad(`fact ${fact.id} cites unknown source ${fact.sourceId}`);
  }
  return input;
}

const USAGE =
  "usage: brief <fixture.json>              离线跑确定性内核，不花钱\n" +
  "       brief <https://…> [秒数] [语气]   真 URL，会调模型、会花钱\n";

/**
 * 把一份固定数据跑过确定性内核，结果打到 stdout。
 *
 *   npm run brief -- test/fixtures/reserve-cut.json
 *
 * 模型与网络层接进来之后，这个入口仍然有用：它是唯一能**不花一分钱**
 * 反复验证 ④⑤⑥⑧⑨ 的地方。
 *
 * 退出码：0 正常 · 1 出稿了但绑定失败 · 2 输入读不了或管线抛了错。
 */
export function main(argv: string[]): number {
  const path = argv[2];
  if (path === undefined) {
    process.stderr.write(USAGE);
    return 2;
  }

  let input: CoreInput;
  try {
    input = validate(JSON.parse(readFileSync(path, "utf8")), path);
  } catch (error) {
    process.stderr.write(`${(error as Error).message}\n`);
    return 2;
  }

  let result;
  try {
    result = buildBrief(input);
  } catch (error) {
    // 管线自己抛错也走 2，不能让异常逃出去：未捕获异常的默认退出码**也是 1**，
    // 会和下面「出稿了但绑定失败」撞车，CI 就分不清是数据坏了还是绑定坏了。
    process.stderr.write(`${path}: pipeline failed: ${(error as Error).message}\n`);
    return 2;
  }

  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);

  // 出稿了但绑定有问题，是最该被 CI 拦住的情况
  if (result.selection.verdict === "ok" && !result.bind.ok) return 1;
  return 0;
}

// ——— 下面是真 URL 那条路。走到这里就会发请求、会调模型、会产生账单。———

/** 抽事实和判冲突量大而结构简单，用便宜的；成稿只有一次，用贵的。 */
const EXTRACT_MODEL = "deepseek-flash";
const CONFLICT_MODEL = "deepseek-flash";
const DRAFT_MODEL = "deepseek-v4-pro";

/**
 * 三处调用各自的输出上限。`max_tokens` 管的是推理+正文的总和，而且是**上限
 * 不是预约**——没生成的部分不收钱。所以每一处都按最坏情况给，不按平均给：
 * 给窄了要赔上整整一次调用的钱，给宽了什么都不赔。
 */
const EXTRACT_MAX_TOKENS = DEFAULT_MAX_TOKENS; // 输入一篇报道，输出十几条 fact，默认够
/** ⑤ 的待判对数随 claim 数**平方**增长（18 条 claim = 152 对），推理和回包一起涨，给双倍。 */
const CONFLICT_MAX_TOKENS = 2 * DEFAULT_MAX_TOKENS;
const DRAFT_MAX_TOKENS = DEFAULT_MAX_TOKENS; // 几百字正文 + 推理，默认够

/**
 * ⑦ 最多调这么多次，**结构问题和长度问题合用这一个预算**。
 *
 * 2 是今天的花销上限，没有涨：⑦ 跑在 deepseek-v4-pro 上，每多一次都真付钱。
 * 给两类问题各配一次重跑（最坏 3 次）在「第一版结构错、第二版长度错」这种
 * 罕见序列上才有用，不值当把最贵那一步的账单上限提五成。用完预算而结构是
 * 合格的，就按实际长度出稿——见 draftScript 里接受时的那段。
 */
const MAX_DRAFT_ATTEMPTS = 2;

/**
 * `.env.local` 就在这个文件的上一层，**按模块位置解析而不是按 cwd**：
 * `loadConfig` 的默认值 "pipeline/.env.local" 只在仓库根目录下成立，
 * 而 `npm run brief` 的 cwd 恰恰是 pipeline/。
 */
const ENV_PATH = fileURLToPath(new URL("../.env.local", import.meta.url));

/**
 * 把真实的网络和模型装进 `Ports`。**只有这个函数知道有网络这回事**——
 * `run.ts` 从头到尾一次请求都不发，所以它的测试才能全程离线。
 */
export function livePorts(config: Config, ledger: TokenLedger, send?: Sender): Ports {
  // send 只为测试存在：不传就是真 fetch，这个文件仍然是唯一知道有网络的地方。
  const deepseek = new DeepSeekClient(config.deepseek, ledger, send);
  const search = new ZhipuSearchClient(config.zhipu.apiKey, ledger);

  const draftOnce = async (prompt: string, allowed: Set<string>) =>
    validateDraft(
      await deepseek.json<{ sentences?: unknown }>("draft", DRAFT_MODEL, prompt, DRAFT_MAX_TOKENS),
      allowed,
    );

  return {
    readArticle: (url) => readArticle(url),
    findSources: (headline) => search.findSources(headline),

    extractFacts: async (source) =>
      parseExtractReply(
        source,
        await deepseek.json<ExtractReply>(
          "extract",
          EXTRACT_MODEL,
          buildExtractPrompt(source),
          EXTRACT_MAX_TOKENS,
        ),
      ),

    findSemanticConflicts: async (claims) => {
      // 判决权在代码：模型只回一个二分类，冲突图由 parseConflictReply 构造，
      // 再由 runPipeline 经 CoreInput.externalConflicts 并进内核的冲突图。
      // 数字层已经判掉的对不必再问模型：那一层是代码判的，比模型可靠也免费。
      // pairsToCheck 的第二个参数就是为此存在的，不传等于每次都为已知结论再付一次钱。
      const pairs = pairsToCheck(claims, findNumericConflicts(claims));
      if (pairs.length === 0) return [];
      const reply = await deepseek.json<ConflictReply>(
        "conflict",
        CONFLICT_MODEL,
        buildConflictPrompt(claims, pairs),
        CONFLICT_MAX_TOKENS,
      );
      return parseConflictReply(reply, new Set(claims.map((c) => c.id)));
    },

    draftScript: async (claims, durationSec, register, charsPerSecond) => {
      // 靶子和尺子共用这一个语速——两处用两个数的话，「差了多少」本身就是假的。
      const rate = resolveDraftRate(claims, charsPerSecond);
      const target = lengthTarget(durationSec, rate);
      const prompt = buildDraftPrompt(claims, durationSec, register, rate);
      // conflicted 的 claim 既没进 prompt，也不许出现在稿子里。
      const allowed = new Set(claims.filter((c) => c.confidence !== "conflicted").map((c) => c.id));

      // 下面这条「拒收+重跑」只对**输出不合规**和**长度不达标**成立，而且这
      // 两类走的是各自的类型、各自的抱怨话术：结构问题来自 validateDraft 的
      // problems，长度问题来自 checkDraftLength 的 LengthMiss。一次重跑只带
      // 一类问题，模型才知道该改哪儿。
      //
      // 被 max_tokens 截断不属于这两类，所以它走的是另一条路：`draftOnce` 里
      // 抛出的 TruncatedOutputError 从这个循环里直接穿出去，一次都不重跑。同样
      // 的 prompt 配同样的上限，重跑必然同样截断，而每一次截断都真付钱。
      let complaint: string | null = null;
      let problems: Problem[] = [];
      // 结构过了、只是长度不达标的那一版。留着它，是因为「什么都不给」比
      // 「短了 20 秒」糟得多——见下面接受时的那段。
      let best: { sentences: DraftSentence[]; miss: LengthMiss } | null = null;

      for (let attempt = 0; attempt < MAX_DRAFT_ATTEMPTS; attempt += 1) {
        const result = await draftOnce(
          complaint === null
            ? prompt
            : `${prompt}\n\n上一版被退回了，逐条改掉下面的问题再输出一遍：\n${complaint}`,
          allowed,
        );

        if (!result.ok) {
          // §6.2 只有我们自己的校验器兜着（DeepSeek 不支持 json_schema），
          // 所以这里是**拒收+重跑**，不是"尽量"。问题一次报全，重跑才有意义。
          problems = result.problems;
          complaint = result.problems
            .map((p) => `${p.index < 0 ? "整体" : `第 ${p.index + 1} 句`}：${p.kind}（${p.detail}）`)
            .join("\n");
          continue;
        }

        const length = checkDraftLength(result.sentences, target);
        if (length.ok) return result.sentences;

        // 两版都不达标时留更接近的那一版，而不是无脑要第二版：重跑没有
        // 「一定更好」这回事，第二版完全可能从短了两成变成长了三成。
        if (best === null || Math.abs(length.ratio - 1) < Math.abs(best.miss.ratio - 1)) {
          best = { sentences: result.sentences, miss: length };
        }
        problems = [];
        complaint = lengthComplaint(length, target);
      }

      if (best !== null) {
        // 长度不对**不作废整篇稿**。三种结局排序很清楚：长了会当场超时最糟，
        // 短了单薄但播得完，而「因为 40 秒不是 60 秒就什么都不给」比前两者都糟。
        // App 上显示的本来就是实测秒数（core.seconds，和这里同一把尺），所以
        // 一篇 40 秒的稿标着「40 秒」不算撒谎——只是拨盘这一次从"保证"降成了
        // "请求"，那就把降级如实打出来，不许闷着。
        process.stderr.write(
          `${describeLength(best.miss, target)}——重跑过一次仍未落进容差，按实际长度出稿\n`,
        );
        return best.sentences;
      }

      // 结构问题两次都过不了才出错，不许把没通过校验的稿子发出去。
      // 注意这和上面那一条不矛盾：短一点的稿子还是稿子，没挂信源的句子不是。
      throw new Error(
        `成稿两次都没通过校验：\n${problems.map((p) => `${p.kind} ${p.detail}`).join("\n")}`,
      );
    },
  };
}

function parseNumber(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value)) throw new Error(`不是一个数：${raw}`);
  return value;
}

/**
 * 真 URL 那条路。退出码和 fixture 那条一致：
 * 0 正常（含「不建议播」——那是产品结论，不是故障）· 1 出稿了但绑定失败 · 2 出错。
 */
export async function briefFromUrl(url: string, argv: string[]): Promise<number> {
  const ledger = new TokenLedger();
  let options: RunOptions;
  let config: Config;
  try {
    options = {
      durationSec: parseNumber(argv[3], 60),
      register: parseNumber(argv[4], 0.5),
      // 不传 charsPerSecond：命令行这条路没有用户的实测语速（§9.2 ①：真实语速
      // 还没开始采集），而语种要等 ① 抓到正文才判得了——那正是 runPipeline 里
      // 做的事。以前这里垫一个中文的 5，英文稿就会被按 5 字/秒 定靶。
    };
    config = loadConfig(ENV_PATH);
  } catch (error) {
    process.stderr.write(`${(error as Error).message}\n`);
    return 2;
  }

  let result;
  try {
    result = await runPipeline(url, options, livePorts(config, ledger));
  } catch (error) {
    process.stderr.write(`${url}: pipeline failed: ${(error as Error).message}\n`);
    return 2;
  } finally {
    // 账单先打出来：管线中途抛错，花掉的 token 一样要给用户看见。
    // 账本单位是人民币分，除以 100 打成元，和 ④ 确认页上那个 ¥ 是同一个数。
    process.stderr.write(
      `tokens: ${JSON.stringify(ledger.totals())}  约 ¥${(ledger.totalCostCents() / 100).toFixed(2)}\n`,
    );
  }

  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);

  if (result.status === "insufficient") {
    process.stderr.write(`不建议播：${result.reason}\n`);
    return 0;
  }
  if (result.core.selection.verdict === "ok" && !result.core.bind.ok) return 1;
  return 0;
}

/** 分派：`http` 开头走真 URL，其余仍是那条一分钱不花的 fixture 路。 */
export async function runCli(argv: string[]): Promise<number> {
  const target = argv[2];
  if (target !== undefined && target.startsWith("http")) return briefFromUrl(target, argv);
  return main(argv);
}

// 只有被当作脚本直接跑时才退出进程；被 import（测试）时什么都不做。
// realpathSync 是必须的：macOS 上 /tmp 是 /private/tmp 的符号链接，
// 不解开的话 argv[1] 和 import.meta.url 对不上，守卫会恒假。
const entry = process.argv[1];
if (entry !== undefined && import.meta.url === pathToFileURL(realpathSync(entry)).href) {
  // 真 URL 那条路是异步的，异常必须在这里收住：未捕获的 rejection 默认退出码
  // 是 1，会和「出稿了但绑定失败」撞车，CI 就分不清是网络挂了还是绑定坏了。
  void runCli(process.argv).then(
    (code) => process.exit(code),
    (error: Error) => {
      process.stderr.write(`${error.message}\n`);
      process.exit(2);
    },
  );
}
