import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { loadConfig, type Config } from "./config/env.js";
import { buildBrief, type CoreInput } from "./core.js";
import { findNumericConflicts } from "./dedupe/conflict.js";
import { DEFAULT_CHARS_PER_SECOND } from "./domain/prosody.js";
import { DeepSeekClient } from "./models/deepseek.js";
import { TokenLedger } from "./models/ledger.js";
import { SearchClient } from "./models/search.js";
import { readArticle } from "./net/jina.js";
import { runPipeline, type Ports, type RunOptions } from "./run.js";
import {
  buildConflictPrompt,
  pairsToCheck,
  parseConflictReply,
  type ConflictReply,
} from "./stages/conflict.js";
import { buildDraftPrompt } from "./stages/draft.js";
import { buildExtractPrompt, parseExtractReply, type ExtractReply } from "./stages/extract.js";
import { validateDraft } from "./stages/validate-draft.js";

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
 * `.env.local` 就在这个文件的上一层，**按模块位置解析而不是按 cwd**：
 * `loadConfig` 的默认值 "pipeline/.env.local" 只在仓库根目录下成立，
 * 而 `npm run brief` 的 cwd 恰恰是 pipeline/。
 */
const ENV_PATH = fileURLToPath(new URL("../.env.local", import.meta.url));

/**
 * 把真实的网络和模型装进 `Ports`。**只有这个函数知道有网络这回事**——
 * `run.ts` 从头到尾一次请求都不发，所以它的测试才能全程离线。
 */
export function livePorts(config: Config, ledger: TokenLedger): Ports {
  const deepseek = new DeepSeekClient(config.deepseek, ledger);
  const search = new SearchClient(config.anthropic.apiKey, ledger);

  const draftOnce = async (prompt: string, allowed: Set<string>) =>
    validateDraft(
      await deepseek.json<{ sentences?: unknown }>("draft", DRAFT_MODEL, prompt),
      allowed,
    );

  return {
    readArticle: (url) => readArticle(url),
    findSources: (headline) => search.findSources(headline),

    extractFacts: async (source) =>
      parseExtractReply(
        source,
        await deepseek.json<ExtractReply>("extract", EXTRACT_MODEL, buildExtractPrompt(source)),
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
      );
      return parseConflictReply(reply, new Set(claims.map((c) => c.id)));
    },

    draftScript: async (claims, durationSec, register) => {
      const prompt = buildDraftPrompt(claims, durationSec, register);
      // conflicted 的 claim 既没进 prompt，也不许出现在稿子里。
      const allowed = new Set(claims.filter((c) => c.confidence !== "conflicted").map((c) => c.id));

      const first = await draftOnce(prompt, allowed);
      if (first.ok) return first.sentences;

      // §6.2 只有我们自己的校验器兜着（DeepSeek 不支持 json_schema），
      // 所以这里是**拒收+重跑**，不是"尽量"。问题一次报全，重跑才有意义。
      const complaint = first.problems
        .map((p) => `${p.index < 0 ? "整体" : `第 ${p.index + 1} 句`}：${p.kind}（${p.detail}）`)
        .join("\n");
      const second = await draftOnce(
        `${prompt}\n\n上一版被退回了，逐条改掉下面的问题再输出一遍：\n${complaint}`,
        allowed,
      );
      if (second.ok) return second.sentences;

      // 两次都过不了校验就出错，不许把没通过校验的稿子发出去。
      throw new Error(
        `成稿两次都没通过校验：\n${second.problems.map((p) => `${p.kind} ${p.detail}`).join("\n")}`,
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
      // 抓到正文之前无从判断语种，只能先用中文的回落值。spec §9.2 ①。
      charsPerSecond: DEFAULT_CHARS_PER_SECOND.cjk,
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
    process.stderr.write(
      `tokens: ${JSON.stringify(ledger.totals())}  约 ${ledger.totalCostCents().toFixed(2)} 美分\n`,
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
