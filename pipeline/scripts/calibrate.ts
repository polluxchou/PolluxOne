// pipeline/scripts/calibrate.ts
//
// Task 16 Step 1：把**真实跑过**的消耗记下来，给 `ESTIMATE_COEFFICIENTS` 的回归当样本。
//
// 用法（会发请求、会调模型、会产生账单）：
//
//     npx tsx scripts/calibrate.ts https://… https://…     # URL 直接给在命令行
//     npx tsx scripts/calibrate.ts                          # 不给就读 scripts/calibration-urls.txt
//
// 清单文件一行一条 URL，`#` 开头和空行忽略。默认路径按**模块位置**解析而不是
// 按 cwd，理由和 cli.ts 的 ENV_PATH 一样：npm 脚本的 cwd 是 pipeline/，而仓库
// 根目录下跑同一条命令时 cwd 又不是。
//
// 输出 `pipeline/test/fixtures/calibration.json`。
//
// **这个脚本只是器具，不是数据。** 在有人真的拿真 key 跑过它之前，那份 fixture
// 不存在，`ESTIMATE_COEFFICIENTS` 也不该动——一组"看起来经过真实样本验证"而
// 其实是编出来的系数，比一组明说是手填的系数糟得多。

import { mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { loadConfig } from "../src/config/env.js";
import { estimateBrief } from "../src/domain/estimate.js";
import { DEFAULT_CHARS_PER_SECOND } from "../src/domain/prosody.js";
import { livePorts } from "../src/cli.js";
import { TokenLedger, type Totals } from "../src/models/ledger.js";
import { runPipeline } from "../src/run.js";

/**
 * ② 拨盘上的两个锚点，和计划里人工评估用的是同一组：
 * `1:00 通俗` 和 `3:00 偏专业`。
 */
export const ANCHORS = [
  { durationSec: 60, register: 0 },
  { durationSec: 180, register: 0.7 },
] as const;

export interface Anchor {
  durationSec: number;
  register: number;
}

/** 账本里校准需要读的那一部分。测试喂替身，所以这里要的是接口不是 `TokenLedger`。 */
export interface LedgerLike {
  totals(): Totals;
  byStage(): Record<string, Totals>;
  totalCostCents(): number;
}

export type SampleStatus = "ok" | "insufficient" | "error";

export interface CalibrationSample {
  url: string;
  durationSec: number;
  register: number;
  /** `estimateBrief` 事前的预估——回归要比的就是它和 `actualTokens` 的关系。 */
  estimatedTokens: number;
  /** 账本 `totals()` 的 input + output。 */
  actualTokens: number;
  actualCostCents: number;
  status: SampleStatus;
  byStage: Record<string, Totals>;
  /** 只有 `status === "error"` 时有。 */
  error?: string;
}

export interface CalibrationFile {
  generatedAt: string;
  anchors: Anchor[];
  samples: CalibrationSample[];
}

/**
 * 跑一条 URL × 一个锚点。**账本由调用方创建并传进来**，不是由实现方返回。
 *
 * 这个方向是故意的：一轮跑到一半抛异常时，返回值没了，但抓取和抽取的
 * token 已经烧掉了。账本握在调用方手里，那笔钱才还读得到。
 */
export type RunOnce<L extends LedgerLike> = (
  url: string,
  anchor: Anchor,
  ledger: L,
) => Promise<"ok" | "insufficient">;

/** 账本的具体类型是参数：真实那条路要的是 `TokenLedger` 本身，测试喂的是替身。 */
export interface CalibrateDeps<L extends LedgerLike = LedgerLike> {
  createLedger: () => L;
  run: RunOnce<L>;
}

/**
 * `reasoningTokens` **不加**：它已经含在 `outputTokens` 里（见 pricing.ts），
 * 再加一次会让实际用量虚高，而虚高的实际用量会把系数往上推——
 * 方向上无害，但那是拿一个记账错误去补另一个估算错误。
 */
function tokensOf(totals: Totals): number {
  return totals.inputTokens + totals.outputTokens;
}

/**
 * 跑完整批，每条 URL × 每个锚点一条样本。
 *
 * 两条纪律写在这里而不是留给调用方：
 *
 * 1. **`insufficient` 的样本照记。** 它们一样烧了 token——抓取和抽取都发生过，
 *    只是没走到成稿。把它们从样本里剔掉，回归出来的系数会系统性偏低，而偏低
 *    正是最危险的方向：用户余额不够却已经开跑，钱花完了才知道。
 * 2. **一条抛异常不中断整批。** 记成一条带 `error` 的样本继续下一条。它烧掉的
 *    token 同样进账本、同样进样本。
 */
export async function collectSamples<L extends LedgerLike>(
  urls: readonly string[],
  deps: CalibrateDeps<L>,
  anchors: readonly Anchor[] = ANCHORS,
): Promise<CalibrationSample[]> {
  const samples: CalibrationSample[] = [];

  for (const url of urls) {
    for (const anchor of anchors) {
      const ledger = deps.createLedger();
      let status: SampleStatus;
      let error: string | undefined;

      try {
        status = await deps.run(url, anchor, ledger);
      } catch (thrown) {
        status = "error";
        error = thrown instanceof Error ? thrown.message : String(thrown);
      }

      const sample: CalibrationSample = {
        url,
        durationSec: anchor.durationSec,
        register: anchor.register,
        estimatedTokens: estimateBrief(anchor.durationSec, anchor.register).tokens,
        actualTokens: tokensOf(ledger.totals()),
        actualCostCents: ledger.totalCostCents(),
        status,
        byStage: ledger.byStage(),
      };
      if (error !== undefined) sample.error = error;
      samples.push(sample);
    }
  }

  return samples;
}

/** 一行一条 URL，`#` 开头和空行忽略。 */
export function parseUrlList(text: string): string[] {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("#"));
}

const URL_LIST_PATH = fileURLToPath(new URL("./calibration-urls.txt", import.meta.url));
const OUTPUT_PATH = fileURLToPath(new URL("../test/fixtures/calibration.json", import.meta.url));
const ENV_PATH = fileURLToPath(new URL("../.env.local", import.meta.url));

export function resolveUrls(argv: readonly string[]): string[] {
  const fromArgv = argv.slice(2).filter((arg) => arg.startsWith("http"));
  if (fromArgv.length > 0) return fromArgv;
  return parseUrlList(readFileSync(URL_LIST_PATH, "utf8"));
}

/** 把真实的网络和模型装进来。**只有这里知道有网络这回事。** */
function liveDeps(): CalibrateDeps<TokenLedger> {
  const config = loadConfig(ENV_PATH);
  return {
    createLedger: () => new TokenLedger(),
    run: async (url, anchor, ledger) => {
      const result = await runPipeline(
        url,
        {
          durationSec: anchor.durationSec,
          register: anchor.register,
          // 抓到正文之前无从判断语种，和 cli.ts 用同一个回落值。
          charsPerSecond: DEFAULT_CHARS_PER_SECOND.cjk,
        },
        livePorts(config, ledger),
      );
      return result.status;
    },
  };
}

export async function main(argv: readonly string[]): Promise<number> {
  let urls: string[];
  try {
    urls = resolveUrls(argv);
  } catch (error) {
    process.stderr.write(
      `读不到 URL 清单：${(error as Error).message}\n` +
        `把 URL 直接给在命令行，或建一份 ${URL_LIST_PATH}（一行一条）。\n`,
    );
    return 2;
  }
  if (urls.length === 0) {
    process.stderr.write("URL 清单是空的，没有可校准的样本。\n");
    return 2;
  }

  const samples = await collectSamples(urls, liveDeps());

  const file: CalibrationFile = {
    generatedAt: new Date().toISOString(),
    anchors: ANCHORS.map((a) => ({ durationSec: a.durationSec, register: a.register })),
    samples,
  };
  mkdirSync(dirname(OUTPUT_PATH), { recursive: true });
  writeFileSync(OUTPUT_PATH, `${JSON.stringify(file, null, 2)}\n`);

  const failed = samples.filter((s) => s.status === "error").length;
  process.stderr.write(
    `写出 ${samples.length} 条样本到 ${OUTPUT_PATH}` +
      (failed > 0 ? `（其中 ${failed} 条跑挂了，已记为 error 样本）` : "") +
      "\n",
  );
  return 0;
}

// 只有被当作脚本直接跑时才动手。被 import（测试）时什么都不做——
// realpathSync 的理由同 cli.ts：macOS 上 /tmp 是 /private/tmp 的符号链接。
const entry = process.argv[1];
if (entry !== undefined && import.meta.url === pathToFileURL(realpathSync(entry)).href) {
  void main(process.argv).then(
    (code) => process.exit(code),
    (error: Error) => {
      process.stderr.write(`${error.message}\n`);
      process.exit(2);
    },
  );
}
