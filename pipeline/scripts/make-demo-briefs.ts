// pipeline/scripts/make-demo-briefs.ts
//
// 把 `test/fixtures/mock-news/` 里的五组虚构信源跑成五份 iOS 能直接加载的
// Brief，产物落在 `ios/Pollux One/Resources/demo-briefs/`。
//
//   npx tsx scripts/make-demo-briefs.ts            # 全部五篇，会真花钱
//   npx tsx scripts/make-demo-briefs.ts lanxin-q3  # 只跑一篇
//
// **这个脚本会调模型、会产生账单。** ③ 抽事实、⑤ 语义冲突、⑦ 成稿各是一次真
// 调用；①② 不跑——信源由 mock 直接给出，不碰搜索，不碰抓取。
//
// 和 `cli.ts` 的分工：那边是产品入口，从一个 URL 开始；这边是演示数据的产线，
// 从一组已知信源开始。两边共用同一批 stage 函数和同一个 `buildBrief`，所以这
// 五份产物走的是和真实流程一模一样的判定——**只有输入是假的，处理过程不是**。

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { buildBrief, type CoreResult } from "../src/core.js";
import { parseEnvFile } from "../src/config/env.js";
import { findNumericConflicts } from "../src/dedupe/conflict.js";
import { groupSources } from "../src/dedupe/independence.js";
import { DEFAULT_CHARS_PER_SECOND } from "../src/domain/prosody.js";
import type { DraftSentence, Fact, Source } from "../src/domain/types.js";
import { toBriefJson, type BriefJson, type NewsRefJson } from "../src/ios/brief.js";
import { DeepSeekClient } from "../src/models/deepseek.js";
import { TokenLedger } from "../src/models/ledger.js";
import {
  buildConflictPrompt,
  pairsToCheck,
  parseConflictReply,
  type ConflictReply,
  type Pair,
} from "../src/stages/conflict.js";
import { buildDraftPrompt } from "../src/stages/draft.js";
import { buildExtractPrompt, parseExtractReply, type ExtractReply } from "../src/stages/extract.js";
import { validateDraft } from "../src/stages/validate-draft.js";
import { verifyQuotes } from "../src/stages/verify-quote.js";

const EXTRACT_MODEL = "deepseek-flash";
const CONFLICT_MODEL = "deepseek-flash";
const DRAFT_MODEL = "deepseek-v4-pro";

/**
 * **实测到的第二个管线缺陷**（2026-09-18）：`DeepSeekClient.json` 的
 * `maxTokens` 默认 8000，而 `cli.ts` 三处调用一个都没覆盖它。
 *
 * 这两个模型会先思考再说话，而 `max_tokens` 管的是**思考 + 正文的总和**。
 * ⑤ 判冲突的待判对数随 claim 数**平方**增长（18 条 claim → 152 对），一到
 * 这个量级，8000 个 token 全被推理吃光：实测 `finish_reason` 是 `length`、
 * `reasoning_tokens` 正好 8000、`content` 是空串。
 *
 * 三件事同时发生，而且都是静默的：
 * 1. HTTP 状态是 200，`net/http.ts` 的重试只看状态码，不会重试；
 * 2. `DeepSeekClient` 先记账再解析——这 8000 个输出 token 照付；
 * 3. 抛出来的是「没有返回合法 JSON：」后面跟一个空字符串，看不出是被截断的。
 *
 * 于是 claim 一多，⑤ 就**必然**失败，而且每失败一次真付一次钱。
 * 这里把上限抬到够用；真正的修法是让 `deepseek.ts` 把 `finish_reason` 读出来，
 * 对 `length` 给一个说得清的错误，并把空 content 归进可重试那一类。
 */
const MAX_TOKENS = { extract: 16_000, conflict: 32_000, draft: 24_000 } as const;

const HERE = fileURLToPath(new URL(".", import.meta.url));
const FIXTURE_DIR = `${HERE}../test/fixtures/mock-news`;
const OUT_DIR = `${HERE}../../ios/Pollux One/Resources/demo-briefs`;

/**
 * 「这个月还剩多少 token」在管线里**没有来源**——那是账户余额，要问计费系统，
 * 而这个仓库里还没有计费系统。所以这里写一个明说的占位配额，按这一轮真实
 * 烧掉的量往下扣。它是这五份产物里唯一一个不来自账本的数，单独拎出来写在
 * 这儿，就是为了不让它混在 `budget` 的其他字段里冒充实测值。
 */
const PLACEHOLDER_MONTHLY_QUOTA = 3_000_000;

interface MockNews {
  synthetic: boolean;
  slug: string;
  news: NewsRefJson;
  durationSec: number;
  register: number;
  sources: Source[];
}

/** 磁盘和类型化代码之间的信任边界，和 `cli.ts` 的 `validate` 同一个理由。 */
export function readMockNews(path: string): MockNews {
  const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (typeof raw !== "object" || raw === null) throw new Error(`${path}: 不是一个 JSON 对象`);
  const o = raw as Record<string, unknown>;

  // 这一条不是形状校验，是纪律校验：没有明写 synthetic 的文件不许进这条产线。
  // 演示数据和真实报道混在一个目录里，是"虚构内容被当真"的第一步。
  if (o.synthetic !== true) throw new Error(`${path}: 缺 "synthetic": true，拒绝当演示数据用`);
  if (typeof o.slug !== "string" || o.slug === "") throw new Error(`${path}: slug 缺失`);
  if (typeof o.durationSec !== "number" || typeof o.register !== "number") {
    throw new Error(`${path}: durationSec / register 必须是数字`);
  }
  if (!Array.isArray(o.sources) || o.sources.length === 0) throw new Error(`${path}: sources 为空`);
  for (const s of o.sources as Source[]) {
    for (const key of ["id", "url", "publisher", "publishedAt", "body"] as const) {
      if (typeof s?.[key] !== "string" || s[key] === "") throw new Error(`${path}: 源缺 ${key}`);
    }
    if (!s.url.startsWith("https://example.com/")) {
      // 虚构正文挂一个看起来像真的域名，就是在造可能被当真的东西。
      throw new Error(`${path}: ${s.id} 的 url 必须是明显不存在的 example.com 域名`);
    }
  }
  return o as unknown as MockNews;
}

/** 外部动作全在这后面，和 `run.ts` 的 `Ports` 同一个用意。 */
export interface DemoPorts {
  extractFacts: (source: Source) => Promise<Fact[]>;
  findSemanticConflicts: (claims: CoreResult["claims"]) => Promise<Pair[]>;
  draftScript: (
    claims: CoreResult["claims"],
    durationSec: number,
    register: number,
  ) => Promise<{ sentences: DraftSentence[]; retries: number }>;
}

export interface RunStats {
  slug: string;
  claimCount: number;
  strongCount: number;
  conflictedCount: number;
  maxIndependence: number;
  sourceGroupCount: number;
  rawFactCount: number;
  rejectedFactCount: number;
  semanticPairsAsked: number;
  semanticConflictsFound: number;
  numericConflictPairs: number;
  draftRetries: number;
  sentenceCount: number;
  anchorCount: number;
  costCents: number;
  usedTokens: number;
}

function dumpClaims(claims: CoreResult["claims"]): void {
  for (const c of claims) {
    process.stderr.write(
      `    ${c.id} [${c.confidence} · ${c.independence} 源 · ${c.factIds.length} 事实] ${c.text}\n`,
    );
  }
}

/**
 * ③ 的结果可以缓存到磁盘，用 `POLLUX_FACT_CACHE=<目录>` 打开。
 *
 * 抽事实是这条产线上唯一**每个信源都要调一次**的步骤（5 篇 × 5 源 = 25 次），
 * 而调 fixture 措辞、调锚点、调产出形状时它的输入一个字都没变。不缓存的话，
 * 每改一次 mock 正文的标点都要重付一遍这 25 次。
 *
 * 默认关闭：产线跑真数据时，缓存会让「这一篇花了多少钱」变成一句假话——
 * 账本记的是这一次真调了的那几次，缓存命中的那几次一分钱都不会出现在里面。
 */
async function cachedFacts(news: MockNews, ports: DemoPorts): Promise<Fact[]> {
  const dir = process.env.POLLUX_FACT_CACHE;
  const path = dir === undefined ? null : `${dir}/${news.slug}.facts.json`;
  // 缓存按**正文内容**作废，不按文件名。改一个字就得重抽：拿着旧正文抽出来的
  // 引文去配新正文，verifyQuotes 会把它们当"模型编的"全部丢掉，而那时看到的
  // 是一份「引文对不上」的报告，不是一句「你的缓存过期了」。
  const stamp = createHash("sha256")
    .update(news.sources.map((s) => s.body).join("\u0000"))
    .digest("hex")
    .slice(0, 16);

  if (path !== null) {
    try {
      const cached = JSON.parse(readFileSync(path, "utf8")) as { stamp?: string; facts?: Fact[] };
      if (cached.stamp === stamp && Array.isArray(cached.facts)) {
        process.stderr.write(`  ⓘ 用了事实缓存——这一篇的账本不含抽取那一步\n`);
        return cached.facts;
      }
    } catch {
      // 没有缓存或读不动就正常调，下面写一份。
    }
  }

  const facts: Fact[] = [];
  for (const source of news.sources) facts.push(...(await ports.extractFacts(source)));
  if (path !== null && dir !== undefined) {
    mkdirSync(dir, { recursive: true });
    writeFileSync(path, `${JSON.stringify({ stamp, facts }, null, 2)}\n`, "utf8");
  }
  return facts;
}

/**
 * ③⑤⑦ 各一次模型调用，中间夹三遍 `buildBrief`。
 *
 * 顺序和 `run.ts` 一致，理由也一致：内核是纯函数、不花一分钱，重算一遍比维护
 * 一条"只补这一步"的旁路便宜；真正要计次的是夹在中间的那两次模型调用。
 */
async function makeOne(
  news: MockNews,
  ports: DemoPorts,
  ledger: TokenLedger,
  remainingThisMonth: number,
): Promise<{ brief: BriefJson; stats: RunStats }> {
  const sources = news.sources;

  // ③ 抽事实 + 逐字校验。校验是代码做的：模型说「这是逐字引文」只是自述。
  const rawFacts = await cachedFacts(news, ports);
  const { kept: facts, rejected } = verifyQuotes(rawFacts, sources);
  if (rejected.length > 0) {
    process.stderr.write(
      `  ⚠︎ ${rejected.length} 条引文没通过逐字校验，已丢弃：\n` +
        rejected.map((r) => `    [${r.reason}] ${r.fact.quote}`).join("\n") +
        "\n",
    );
  }

  const base = {
    durationSec: news.durationSec,
    register: news.register,
    charsPerSecond: DEFAULT_CHARS_PER_SECOND.cjk,
    sources,
    facts,
  };

  // 第一遍只为拿 claims：⑤ 的语义那一半要有成形的 claim 才问得了模型。
  const preSemantic = buildBrief({ ...base, draft: [] });
  if (preSemantic.selection.verdict === "insufficient") {
    // 「不建议播」是产品结论，不是故障——但对一份**演示**素材来说它是失败，
    // 所以这里把 claim 全表打出来，好看清是哪几条没攒够独立源。
    dumpClaims(preSemantic.claims);
    throw new Error(
      `${news.slug}: 只有 ${preSemantic.selection.strongFound ?? 0} 条 strong，写不出敢播的稿`,
    );
  }
  if (process.env.POLLUX_VERBOSE === "1") dumpClaims(preSemantic.claims);

  const numericPairs = findNumericConflicts(preSemantic.claims);
  const asked = pairsToCheck(preSemantic.claims, numericPairs);
  const externalConflicts = await ports.findSemanticConflicts(preSemantic.claims);

  // 带着语义冲突再跑一遍。成稿必须用这一份 claims。
  const checked = buildBrief({ ...base, draft: [], externalConflicts });
  if (checked.selection.verdict === "insufficient") {
    throw new Error(`${news.slug}: 语义冲突之后 strong 不够了，不出稿`);
  }

  // ⑦ 成稿
  const drafted = await ports.draftScript(checked.claims, news.durationSec, news.register);

  // 最后一遍带上稿子：⑧ 的挂信源要拿 draft 才做得了。
  const core = buildBrief({ ...base, draft: drafted.sentences, externalConflicts });

  const totals = ledger.totals();
  const used = totals.inputTokens + totals.outputTokens;
  const stageLabels: Record<string, string> = {
    extract: "抽取事实点",
    conflict: "交叉验证",
    draft: "成稿",
  };
  const byStage: Record<string, number> = {};
  for (const [stage, t] of Object.entries(ledger.byStage())) {
    // 和 `used` 用同一个口径（输入 + 输出，推理 token 已含在输出里）。
    // 两边口径不一致，进度条各段之和就不等于 used——`TokenBudget` 的注释
    // 把那种情况叫"进度条在撒谎"。
    byStage[stageLabels[stage] ?? stage] = t.inputTokens + t.outputTokens;
  }

  const groupCount = groupSources([...sources]).length;
  const brief = toBriefJson({
    id: `b-demo-${news.slug}`,
    news: news.news,
    sources,
    facts,
    core,
    counts: {
      sourceCount: sources.length,
      rawFactCount: rawFacts.length,
      rejectedFactCount: rejected.length,
      sourceGroupCount: groupCount,
    },
    budget: {
      used,
      budgeted: core.estimate.tokens,
      remainingThisMonth,
      costCents: Math.round(ledger.totalCostCents()),
      byStage,
    },
  });

  return {
    brief,
    stats: {
      slug: news.slug,
      claimCount: core.claims.length,
      strongCount: core.claims.filter((c) => c.confidence === "strong").length,
      conflictedCount: core.claims.filter((c) => c.confidence === "conflicted").length,
      maxIndependence: core.claims.reduce((m, c) => Math.max(m, c.independence), 0),
      sourceGroupCount: groupCount,
      rawFactCount: rawFacts.length,
      rejectedFactCount: rejected.length,
      semanticPairsAsked: asked.length,
      semanticConflictsFound: externalConflicts.length,
      numericConflictPairs: numericPairs.length,
      draftRetries: drafted.retries,
      sentenceCount: brief.sentences.length,
      anchorCount: brief.sentences.reduce((n, s) => n + s.anchors.length, 0),
      costCents: Math.round(ledger.totalCostCents()),
      usedTokens: used,
    },
  };
}

/**
 * **实测到的一个管线缺陷的绕行**（2026-09-18，deepseek-flash）：
 * 偶尔会 200 回来一个 `content` 为空串的回包——`finish_reason` 正常，token
 * 照扣，只是没有正文。`DeepSeekClient.json` 于是抛「没有返回合法 JSON：」
 * 后面跟一个空字符串，而 `net/http.ts` 的重试只看 HTTP 状态码，200 在它眼里
 * 是成功，不会重试。
 *
 * 后果是一整轮调研在第三次调用上全盘失败，前面花掉的钱一分不退。对一次
 * 5 篇 × 7 次调用的批量任务，这个概率高到必须处理。
 *
 * 这里就地重试，**不去改 `DeepSeekClient`**：那是产品路径上的共享代码，
 * 一个演示脚本不该顺手改掉它的重试语义。正确的修法是在 `deepseek.ts` 里把
 * 「空 content」和 429 归为同一类可重试失败，那是另一个计划的事。
 */
async function retryOnBlankReply<T>(label: string, call: () => Promise<T>): Promise<T> {
  let last: Error | null = null;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      return await call();
    } catch (error) {
      last = error as Error;
      if (!/没有返回合法 JSON/u.test(last.message)) throw last;
      process.stderr.write(`  ⚠︎ ${label} 第 ${attempt} 次拿到空回包，重试\n`);
    }
  }
  throw last ?? new Error(`${label} 失败且没有记录到原因`);
}

/** 真的会发请求的那一层。只有这个函数知道有网络这回事。 */
function livePorts(deepseek: DeepSeekClient): DemoPorts {
  return {
    extractFacts: async (source) =>
      parseExtractReply(
        source,
        await retryOnBlankReply(`抽事实 ${source.id}`, () =>
          deepseek.json<ExtractReply>(
            "extract",
            EXTRACT_MODEL,
            buildExtractPrompt(source),
            MAX_TOKENS.extract,
          ),
        ),
      ),

    findSemanticConflicts: async (claims) => {
      // 数字层已经判掉的对不必再问模型：那一层是代码判的，比模型可靠也免费。
      const pairs = pairsToCheck(claims, findNumericConflicts(claims));
      if (pairs.length === 0) return [];
      const reply = await retryOnBlankReply("判冲突", () =>
        deepseek.json<ConflictReply>(
          "conflict",
          CONFLICT_MODEL,
          buildConflictPrompt(claims, pairs),
          MAX_TOKENS.conflict,
        ),
      );
      return parseConflictReply(reply, new Set(claims.map((c) => c.id)));
    },

    draftScript: async (claims, durationSec, register) => {
      const prompt = buildDraftPrompt(claims, durationSec, register);
      const allowed = new Set(claims.filter((c) => c.confidence !== "conflicted").map((c) => c.id));
      const once = async (p: string) =>
        validateDraft(
          await retryOnBlankReply("成稿", () =>
            deepseek.json<{ sentences?: unknown }>("draft", DRAFT_MODEL, p, MAX_TOKENS.draft),
          ),
          allowed,
        );

      const first = await once(prompt);
      if (first.ok) return { sentences: first.sentences, retries: 0 };

      // §6.2 只有我们自己的校验器兜着，所以这里是拒收 + 重跑，不是"尽量"。
      const complaint = first.problems
        .map((p) => `${p.index < 0 ? "整体" : `第 ${p.index + 1} 句`}：${p.kind}（${p.detail}）`)
        .join("\n");
      process.stderr.write(`  ⚠︎ 成稿第一版被退回：\n${complaint.replace(/^/gmu, "    ")}\n`);
      const second = await once(
        `${prompt}\n\n上一版被退回了，逐条改掉下面的问题再输出一遍：\n${complaint}`,
      );
      if (second.ok) return { sentences: second.sentences, retries: 1 };

      throw new Error(
        `成稿两次都没通过校验：\n${second.problems.map((p) => `${p.kind} ${p.detail}`).join("\n")}`,
      );
    },
  };
}

function loadApiKey(): { apiKey: string; baseUrl: string } {
  const path = process.env.POLLUX_ENV_FILE ?? `${HERE}../.env.local`;
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    throw new Error(`读不到 ${path}。用 POLLUX_ENV_FILE 指一个 .env 文件，或照 .env.example 填。`);
  }
  const env = parseEnvFile(text);
  const apiKey = (env.DEEPSEEK_API_KEY ?? "").trim();
  // 这条产线不碰搜索，所以**不要** ZHIPU_API_KEY——多要一个用不上的密钥，
  // 只会让人为了跑通它而去把一个真密钥填进某个不该填的地方。
  if (apiKey === "") throw new Error(`${path} 里没有 DEEPSEEK_API_KEY`);
  return { apiKey, baseUrl: (env.DEEPSEEK_BASE_URL ?? "").trim() || "https://api.deepseek.com" };
}

export async function main(argv: string[]): Promise<number> {
  const only = argv.slice(2).filter((a) => !a.startsWith("-"));
  const files = readdirSync(FIXTURE_DIR)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .filter((f) => only.length === 0 || only.includes(f.replace(/\.json$/u, "")));

  if (files.length === 0) {
    process.stderr.write(`${FIXTURE_DIR} 里没有匹配的 fixture\n`);
    return 2;
  }

  const config = loadApiKey();
  mkdirSync(OUT_DIR, { recursive: true });

  const all: RunStats[] = [];
  let spentTokens = 0;
  let spentCents = 0;

  for (const file of files) {
    const news = readMockNews(`${FIXTURE_DIR}/${file}`);
    process.stderr.write(`\n▶ ${news.slug} — ${news.news.title}\n`);

    // 每篇一本账：`budget` 是这一篇的花费，不是这一轮的累计。
    const ledger = new TokenLedger();
    const deepseek = new DeepSeekClient(config, ledger);
    let result;
    try {
      result = await makeOne(
        news,
        livePorts(deepseek),
        ledger,
        PLACEHOLDER_MONTHLY_QUOTA - spentTokens,
      );
    } catch (error) {
      // 账单先出来，再往上抛。这一篇中途炸了——信源不够、模型回了个空包、
      // 稿子两次都没过校验——花掉的 token 一样要看得见。`cli.ts` 用一个
      // finally 守着同一条规矩，这条产线跑一批，更不该让失败那几篇的账
      // 跟着进程一起消失：这一轮到底花了多少，正是批量跑完最先要问的事。
      process.stderr.write(
        `  ✗ ${news.slug} 没跑完，这一篇已经花掉：${JSON.stringify(ledger.totals())}` +
          ` 约 ¥${(ledger.totalCostCents() / 100).toFixed(2)}\n` +
          `  之前几篇合计 ¥${(spentCents / 100).toFixed(2)}\n`,
      );
      throw error;
    }
    const { brief, stats } = result;

    spentTokens += stats.usedTokens;
    spentCents += stats.costCents;
    all.push(stats);

    writeFileSync(`${OUT_DIR}/${news.slug}.json`, `${JSON.stringify(brief, null, 2)}\n`, "utf8");
    process.stderr.write(
      `  claims ${stats.claimCount}（strong ${stats.strongCount} / conflicted ${stats.conflictedCount}）` +
        ` · 独立源组 ${stats.sourceGroupCount} · 事实 ${stats.rawFactCount}→${stats.rawFactCount - stats.rejectedFactCount}` +
        ` · ${stats.sentenceCount} 句 · ${stats.anchorCount} 个锚点 · ¥${(stats.costCents / 100).toFixed(2)}\n`,
    );
  }

  process.stderr.write(
    `\n合计：${spentTokens} token · ¥${(spentCents / 100).toFixed(2)}\n` +
      `产物：${OUT_DIR}\n`,
  );
  process.stdout.write(`${JSON.stringify(all, null, 2)}\n`);
  return 0;
}

const entry = process.argv[1];
if (entry !== undefined && entry.endsWith("make-demo-briefs.ts")) {
  void main(process.argv).then(
    (code) => process.exit(code),
    (error: Error) => {
      process.stderr.write(`${error.stack ?? error.message}\n`);
      process.exit(2);
    },
  );
}
