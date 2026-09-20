// pipeline/scripts/check-demo-briefs.ts
//
// 对 `ios/Pollux One/Resources/demo-briefs/*.json` 逐条验收。
//
//   npx tsx scripts/check-demo-briefs.ts
//
// 这个文件**不 import 产出它们的那几个模块**（`src/ios/anchors.ts`、
// `src/ios/brief.ts`），字素切分也是在这里另写一遍的。共用一份实现的话，
// 锚点算错在哪一步，校验就会在同一步同样地错——那种校验只能证明代码和它
// 自己一致。
//
// 它检的是 iOS 侧会当真的那些不变量：
//
// - `AnchorRuns` 越界/重叠就**整句降级**成无标记文本，不崩溃。所以一个错锚点
//   在 app 里的表现是"这句话的虚线莫名其妙没了"——没有人会发现。
// - `BriefSentence.canRecheckSources` 只认 kind，观点句挂了 claim 就会在审稿页
//   上冒出一个不该有的重查按钮。
// - `TokenBudget` 的注释把 byStage 之和不等于 used 叫"进度条在撒谎"。

import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
export const BRIEF_DIR = `${HERE}../../ios/Pollux One/Resources/demo-briefs`;
export const MOCK_DIR = `${HERE}../test/fixtures/mock-news`;

const STAGE_NAMES = [
  "抓取原文",
  "扩展检索",
  "抽取事实点",
  "归并去重",
  "交叉验证",
  "选点",
  "成稿",
  "挂信源",
  "时长与气口",
];

/** 和 Swift 的 `Array(text)` 同一个口径：扩展字素簇。这里是独立的第二份实现。 */
function characters(text: string): string[] {
  return [...new Intl.Segmenter("zh", { granularity: "grapheme" }).segment(text)].map(
    (p) => p.segment,
  );
}

/** 只折叠排版差异，标点一个不去——小数点去掉会让 48.6 冒充 486。 */
function squash(text: string): string {
  return text
    .normalize("NFKC")
    .replace(/[\u200B-\u200D\uFEFF]/gu, "")
    .replace(/\s+/gu, "");
}

const isStr = (v: unknown): v is string => typeof v === "string";
const isInt = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v);

export function checkBrief(brief: unknown, mockBodies: string[], where: string): string[] {
  const bad: string[] = [];
  const fail = (msg: string): void => {
    bad.push(`${where}: ${msg}`);
  };

  if (typeof brief !== "object" || brief === null) return [`${where}: 不是一个 JSON 对象`];
  const b = brief as Record<string, unknown>;

  // —— 能不能被 Swift 的 JSONDecoder 解开 ——
  if (!isStr(b.id)) fail("id 不是字符串");
  if (b.status !== "ready" && b.status !== "researching" && b.status !== "insufficient") {
    fail(`status 不是三个枚举值之一：${String(b.status)}`);
  }
  if (!isInt(b.estimatedSeconds) || (b.estimatedSeconds as number) <= 0) {
    fail(`estimatedSeconds 必须是正整数，实际 ${String(b.estimatedSeconds)}`);
  }
  // 这几篇没有任何用户的实测语速。写 true 就是界面上那句不许说的「按你的语速」。
  if (b.pacedToUser !== false) fail("pacedToUser 必须是 false——这些稿没有用户语速数据");
  if (b.insufficientReason !== null) fail("ready 的 brief 不该带 insufficientReason");

  const news = b.news as Record<string, unknown> | undefined;
  if (!news || !isStr(news.publisher) || !isStr(news.title)) fail("news 缺 publisher / title");

  // —— 阶段 ——
  const stages = b.stages;
  if (!Array.isArray(stages) || stages.length !== STAGE_NAMES.length) {
    fail(`stages 必须是 ${STAGE_NAMES.length} 个阶段`);
  } else {
    stages.forEach((raw, i) => {
      const s = raw as Record<string, unknown>;
      if (s.name !== STAGE_NAMES[i]) fail(`第 ${i + 1} 个阶段名应为 ${STAGE_NAMES[i]}，实际 ${String(s.name)}`);
      if (s.state !== "done") fail(`阶段 ${String(s.name)} 不是 done`);
      if (!isStr(s.count) || s.count === "") fail(`阶段 ${String(s.name)} 的 count 为空`);
      if (s.detail !== null) fail(`done 的阶段 ${String(s.name)} 不该带 detail`);
    });
  }

  // —— 账 ——
  const budget = b.budget as Record<string, unknown> | undefined;
  if (!budget) fail("缺 budget");
  else {
    for (const k of ["used", "budgeted", "remainingThisMonth", "costCents"] as const) {
      if (!isInt(budget[k])) fail(`budget.${k} 不是整数`);
    }
    const byStage = budget.byStage as Record<string, unknown> | undefined;
    if (typeof byStage !== "object" || byStage === null) fail("budget.byStage 不是对象");
    else {
      let sum = 0;
      for (const [k, v] of Object.entries(byStage)) {
        if (!isInt(v)) fail(`budget.byStage["${k}"] 不是整数`);
        else sum += v;
      }
      // TokenBudget 的注释：之和不等于 used，进度条就在撒谎。
      if (sum !== budget.used) fail(`budget.byStage 之和 ${sum} ≠ used ${String(budget.used)}`);
    }
    if ((budget.used as number) <= 0) fail("budget.used 是 0——这一篇根本没调过模型");
  }

  // —— claim 证据面板 ——
  const claims = b.claims as Record<string, Record<string, unknown>> | undefined;
  if (typeof claims !== "object" || claims === null) return [...bad, `${where}: claims 不是对象`];
  for (const [id, c] of Object.entries(claims)) {
    if (c.id !== id) fail(`claims["${id}"].id 是 ${String(c.id)}`);
    if (!isInt(c.independence) || (c.independence as number) < 1) fail(`${id} 的 independence 非法`);
    if (!isInt(c.mergedAwayCount) || (c.mergedAwayCount as number) < 0) {
      fail(`${id} 的 mergedAwayCount 非法`);
    }
    const srcs = c.sources;
    if (!Array.isArray(srcs) || srcs.length !== c.independence) {
      fail(`${id} 的 sources 条数应等于 independence ${String(c.independence)}`);
    } else {
      for (const s of srcs as Record<string, unknown>[]) {
        if (!isStr(s.publisher) || !isStr(s.note) || !isStr(s.time)) fail(`${id} 的 source 字段缺失`);
        else if (!/^\d{2}:\d{2}$/u.test(s.time)) fail(`${id} 的 time "${s.time}" 不是 HH:mm`);
      }
    }
  }

  // 重查只能让信源变多——iOS 侧 `BriefRecheck` 对变少是 assertionFailure。
  const recheck = b.recheckResults;
  if (recheck !== null && recheck !== undefined) {
    if (typeof recheck !== "object") fail("recheckResults 既不是 null 也不是对象");
    else {
      for (const [id, r] of Object.entries(recheck as Record<string, Record<string, unknown>>)) {
        const before = claims[id];
        if (before === undefined) fail(`recheckResults 里的 ${id} 不在 claims 里`);
        else if ((r.independence as number) < (before.independence as number)) {
          fail(`重查把 ${id} 的独立源从 ${String(before.independence)} 减到 ${String(r.independence)}`);
        }
      }
    }
  }

  // —— 句子与锚点 ——
  const sentences = b.sentences;
  if (!Array.isArray(sentences) || sentences.length === 0) return [...bad, `${where}: sentences 为空`];

  const ids = new Set<string>();
  let factCount = 0;
  let anchorTotal = 0;

  sentences.forEach((raw, i) => {
    const s = raw as Record<string, unknown>;
    const at = `第 ${i + 1} 句`;
    if (!isStr(s.id) || s.id === "") return fail(`${at} 缺 id`);
    if (ids.has(s.id)) fail(`${at} 的 id ${s.id} 重复`);
    ids.add(s.id);

    if (!isStr(s.text) || s.text.trim() === "") return fail(`${at} 文本为空`);
    if (s.kind !== "fact" && s.kind !== "opinion" && s.kind !== "transition") {
      return fail(`${at} 的 kind 非法：${String(s.kind)}`);
    }
    const claimIds = s.claimIds;
    const anchors = s.anchors;
    if (!Array.isArray(claimIds)) return fail(`${at} 的 claimIds 不是数组`);
    if (!Array.isArray(anchors)) return fail(`${at} 的 anchors 不是数组`);

    if (s.kind === "fact") {
      factCount += 1;
      // 一句事实没有信源，却混在有信源的句子里——整条产品承诺的断裂点。
      if (claimIds.length === 0) fail(`${at}（fact）没有 claimIds`);
    } else {
      // 观点句挂信源是在给个人判断披一层客观外衣。
      if (claimIds.length > 0) fail(`${at}（${s.kind}）不许有 claimIds`);
      if (anchors.length > 0) fail(`${at}（${s.kind}）不许有锚点`);
    }

    for (const id of claimIds as unknown[]) {
      if (!isStr(id) || claims[id] === undefined) fail(`${at} 引用了不存在的 claim ${String(id)}`);
    }

    const chars = characters(s.text);
    const sorted = [...(anchors as Record<string, unknown>[])].sort(
      (a, b2) => (a.start as number) - (b2.start as number),
    );
    let cursor = 0;
    for (const a of sorted) {
      anchorTotal += 1;
      const start = a.start;
      const length = a.length;
      const claimId = a.claimId;
      if (!isInt(start) || !isInt(length)) {
        fail(`${at} 的锚点 start/length 不是整数`);
        continue;
      }
      if (length <= 0) fail(`${at} 有一个空锚点（length ${length}）`);
      if (start < 0) fail(`${at} 的锚点 start 是负数`);
      // 越界：iOS 侧会整句降级，虚线静默消失。
      if (start + length > chars.length) {
        fail(`${at} 的锚点越界：${start}+${length} > ${chars.length} 个 Character`);
        continue;
      }
      // 重叠：同上，整句降级。
      if (start < cursor) fail(`${at} 的锚点与前一个重叠（start ${start} < ${cursor}）`);
      cursor = start + length;

      if (!isStr(claimId) || claims[claimId] === undefined) {
        fail(`${at} 的锚点指向不存在的 claim ${String(claimId)}`);
        continue;
      }
      if (!(claimIds as string[]).includes(claimId)) {
        fail(`${at} 的锚点挂到了这句没引用的 claim ${claimId}`);
      }

      const piece = chars.slice(start, start + length).join("");
      // 「数字、日期、金额等可定位片段」——一段不含数字的字不是可定位片段。
      if (!/\d/u.test(piece)) fail(`${at} 的锚点「${piece}」里没有数字，不是可定位片段`);
      // 最要紧的一条：划下去的那个数，得真的在这条新闻的报道里出现过。
      // 位置划错时它几乎必然落空——「48.6 亿元」错一格就成了「8.6 亿元」。
      if (!mockBodies.some((body) => squash(body).includes(squash(piece)))) {
        fail(`${at} 的锚点「${piece}」在任何一篇信源正文里都找不到`);
      }
    }
  });

  if (factCount === 0) fail("一句事实句都没有");
  if (anchorTotal === 0) fail("五篇演示稿不该一个锚点都没有");

  return bad;
}

export function checkAll(): string[] {
  const bodiesBySlug = new Map<string, string[]>();
  for (const f of readdirSync(MOCK_DIR).filter((f) => f.endsWith(".json"))) {
    const m = JSON.parse(readFileSync(`${MOCK_DIR}/${f}`, "utf8")) as {
      slug: string;
      sources: { body: string }[];
    };
    bodiesBySlug.set(m.slug, m.sources.map((s) => s.body));
  }

  const files = readdirSync(BRIEF_DIR).filter((f) => f.endsWith(".json")).sort();
  if (files.length === 0) return [`${BRIEF_DIR} 里一个产物都没有`];

  const bad: string[] = [];
  for (const f of files) {
    const brief = JSON.parse(readFileSync(`${BRIEF_DIR}/${f}`, "utf8")) as { id?: unknown };
    const slug = f.replace(/\.json$/u, "");
    const bodies = bodiesBySlug.get(slug);
    if (bodies === undefined) {
      bad.push(`${f}: 找不到对应的 mock 新闻 ${slug}.json`);
      continue;
    }
    if (brief.id !== `b-demo-${slug}`) bad.push(`${f}: id 应为 b-demo-${slug}，实际 ${String(brief.id)}`);
    bad.push(...checkBrief(brief, bodies, f));
  }
  return bad;
}

const entry = process.argv[1];
if (entry !== undefined && entry.endsWith("check-demo-briefs.ts")) {
  const problems = checkAll();
  if (problems.length === 0) {
    const n = readdirSync(BRIEF_DIR).filter((f) => f.endsWith(".json")).length;
    process.stdout.write(`${n} 份产出全部通过\n`);
    process.exit(0);
  }
  process.stderr.write(`${problems.join("\n")}\n\n共 ${problems.length} 条不合格\n`);
  process.exit(1);
}
