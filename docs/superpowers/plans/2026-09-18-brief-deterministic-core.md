# 调研管线的确定性内核 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 spec §3 里"刻意不用 AI"的那四个阶段（④归并 ⑤交叉验证 ⑧挂信源 ⑨时长气口）连同 §10.1 的成本估算，做成一个零网络、零模型、可离线断言的 TypeScript 包，并用一条真实新闻的固定数据跑通端到端。

**Architecture:** 新建 `pipeline/` 独立包，纯函数为主，**零运行时依赖**。每个模块单一职责、数据进数据出——和 `ios/Engines/` 下每个 Engine 的分工方式一致。模型与网络层完全不在本计划内，因此全部逻辑都能用固定 fixture 断言。

**Tech Stack:** TypeScript 5 / Node 20+ / vitest（唯一的测试依赖）/ tsx（跑 CLI）。运行时依赖为零。

---

## 为什么只做这一段

spec §12 把"后端管线 + estimateBrief + user_reading_rates"打成一段。真写起来它跨三个工具链、十几个阶段，不是一个计划能交付的东西。按"每个计划自身要能产出可运行、可测试的软件"切开：

- **本计划（第一段之一）**：确定性内核。给定一组已抓好的 source/fact/draft 固定数据，算出独立源分组、归并 Claim、判定 confidence、选点、逐句绑定信源、算时长与气口，输出 Script 骨架 + 证据层 JSON。**正确性是客观可断言的。**
- **下一个计划（第一段之二）**：模型与网络层（①抓原文 ②扩展检索 ③抽事实 ⑦成稿）+ 阶段状态机 + 真实新闻端到端 + 两个锚点的稿件质量人工评估。**质量是主观评估的。**

先做本计划的理由：spec §11 自己写了"前四项不需要调用任何模型"，而那四项恰好就是 §3 说的护城河所在。**护城河先焊死，再去接模型。**

## 与 spec 的四处偏离（有意的，理由在此）

| spec 怎么写 | 本计划怎么做 | 为什么 |
|---|---|---|
| §5「5-gram shingle + **MinHash**」 | 5-gram shingle + **精确 Jaccard** | MinHash 是为规模准备的。12–30 个源的量级下，精确 Jaccard 更短、更快、而且**精确**——护城河上的算术不该引入近似误差。源数真涨到几百再换。 |
| §4.3 ④「**embedding 聚类** + 规则」 | 数字签名 + 字符 2-gram Jaccard | embedding 要调接口，一调就破了 §11「不调模型即可离线测试」那条收益。而 §11 才是本计划的立足点。embedding 作为后续升级记录在案。 |
| §5「冲突检测交给 `deepseek-flash` 做二分类」 | 先做**确定性的数字冲突**，语义冲突留给下一个计划 | §5.1 自己举的例子就是「路透 23 亿 vs 彭博 31 亿」——**最危险的冲突是数字冲突，而它根本不需要模型**。文本相似但数字不同即冲突，一条规则、可断言。 |
| §12「`user_reading_rates` 也在第一段」 | 本计划只建**表**；iOS 侧采集拆成独立计划 | 采集在 Swift 侧、改 `SessionManager` 的 take 结束路径，与本包无关。本包把 `charsPerSecond` 当**注入参数**，缺省回落语种默认值——不阻塞任何事。 |

---

## 文件结构

```
pipeline/
  package.json                 零运行时依赖；devDeps: typescript vitest tsx
  tsconfig.json
  src/
    domain/
      types.ts                 Source · Fact · MergedClaim · VerifiedClaim · DraftSentence
      estimate.ts              §10.1 estimateBrief（纯函数）
      prosody.ts               ⑨ 语种判定 · 秒数 · 气口
    dedupe/
      shingle.ts               归一化 · 5-gram/2-gram shingle · Jaccard
      independence.ts          ⑤ 信源分组（并查集）+ 独立源计数
      merge.ts                 ④ Fact → MergedClaim 归并（数字签名 + Jaccard）
      conflict.ts              ⑤ 确定性数字冲突
      classify.ts              ⑤ confidence 判定（strong/weak/conflicted）
    draft/
      select.ts                ⑥ 名额分配 + insufficient 门槛
      bind.ts                  ⑧ 逐句挂信源 + schema 校验 + 句子指纹
    core.ts                    组合 ④⑤⑥⑧⑨
    cli.ts                     命令行入口
  test/
    fixtures/
      reserve-cut.json         降准那条：14 源（12 篇转载）+ 86 facts + 一份 draft
      conflicted-figures.json  §5.1 的数字冲突样本
    *.test.ts
backend/supabase/migrations/
  0002_briefs.sql              §9 的新表 + §9.2 ⑤ 的 sentence_prosody + user_reading_rates
```

每个文件一个职责。`dedupe/` 下五个文件加起来不到 300 行，但它们是 §3 说的"不用 AI 的那三步"的全部实现——**值得各自成文件、各自有测试**。

---

### Task 1: 包脚手架

**Files:**
- Create: `pipeline/package.json`
- Create: `pipeline/tsconfig.json`
- Create: `pipeline/src/domain/types.ts`
- Create: `pipeline/test/smoke.test.ts`
- Modify: `.gitignore`

- [ ] **Step 1: 建 package.json**

```json
{
  "name": "pollux-pipeline",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "vitest run",
    "typecheck": "tsc --noEmit",
    "brief": "tsx src/cli.ts"
  },
  "devDependencies": {
    "tsx": "^4.19.2",
    "typescript": "^5.7.2",
    "vitest": "^2.1.8"
  }
}
```

运行时依赖故意为零——和 iOS 侧「V1 无第三方 SPM 包」同一条纪律。

- [ ] **Step 2: 建 tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "verbatimModuleSyntax": true,
    "skipLibCheck": true,
    "types": ["node"]
  },
  "include": ["src", "test"]
}
```

`noUncheckedIndexedAccess` 打开是有意的：本包大量按下标取数组元素，这个开关会逼出每一处漏判。

- [ ] **Step 3: 把 node_modules 加进 .gitignore**

在 `.gitignore` 的 `# Web / Next.js` 段之后插入：

```
# Pipeline
pipeline/node_modules/
pipeline/*.tsbuildinfo
```

- [ ] **Step 4: 写一个 smoke 测试，确认 vitest 跑得起来**

`pipeline/test/smoke.test.ts`：

```ts
import { expect, test } from "vitest";

test("vitest runs", () => {
  expect(1 + 1).toBe(2);
});
```

- [ ] **Step 5: 安装并跑**

```bash
cd pipeline && npm install && npm test
```

Expected: `1 passed`

- [ ] **Step 6: 提交**

```bash
git add .gitignore pipeline/package.json pipeline/package-lock.json pipeline/tsconfig.json pipeline/test/smoke.test.ts
git commit -m "Give the research pipeline a home with no runtime dependencies"
```

---

### Task 2: 领域类型

**Files:**
- Create: `pipeline/src/domain/types.ts`

- [ ] **Step 1: 写下全部纯类型**

```ts
export type SourceId = string;
export type FactId = string;
export type ClaimId = string;

/** 一个信源。`body` 是抓到的正文；指纹不存字段，由 dedupe 现算——少一个要维护的不变量。 */
export interface Source {
  id: SourceId;
  url: string;
  publisher: string;
  /** ISO 8601 */
  publishedAt: string;
  body: string;
  /** 正文里显式写明的转载来源，如「新华社」。没有则 null。 */
  creditedTo: string | null;
}

/** 从单个 Source 抽出的原子事实。`quote` 是逐字引文——spec §4.3 说这是后面一切的根。 */
export interface Fact {
  id: FactId;
  sourceId: SourceId;
  text: string;
  quote: string;
}

export type Confidence = "strong" | "weak" | "conflicted";

/** ④ 归并的产物。此时还不知道有几个独立源，也还不知道敢不敢播。 */
export interface MergedClaim {
  id: ClaimId;
  text: string;
  factIds: FactId[];
}

/**
 * ⑤ 交叉验证的产物。`independence` 是互不相关的信源组数量，不是信源条数。
 *
 * 和 MergedClaim 分开是有意的：④ 出来的东西还不知道有几个独立源。若两者共用
 * 一个类型，就得先塞一个 `independence: 0` 的占位值——那是**一个关于自己
 * 有多少信源的谎**。在一个以可溯源为唯一承诺的产品里，这种中间态不该在
 * 类型上存在。
 */
export interface VerifiedClaim extends MergedClaim {
  independence: number;
  confidence: Confidence;
  conflictsWith: ClaimId[];
}

export type SentenceKind = "fact" | "opinion" | "transition";

/** ⑦ 成稿的输出形状。fact 句必须带 claimIds，opinion 句不许带——§6.2。 */
export interface DraftSentence {
  text: string;
  kind: SentenceKind;
  claimIds: ClaimId[];
}
```

- [ ] **Step 2: typecheck**

```bash
cd pipeline && npm run typecheck
```

Expected: 无输出（成功）

- [ ] **Step 3: 提交**

```bash
git add pipeline/src/domain/types.ts
git commit -m "Name the things the pipeline passes around"
```

---

### Task 3: 文本指纹

**Files:**
- Create: `pipeline/src/dedupe/shingle.ts`
- Test: `pipeline/test/shingle.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/shingle.test.ts`：

```ts
import { expect, test } from "vitest";
import { jaccard, normalize, shingles } from "../src/dedupe/shingle.js";

test("normalize strips punctuation and whitespace, keeps characters", () => {
  expect(normalize("央行宣布：下调 0.5 个百分点。")).toBe("央行宣布下调05个百分点");
});

test("full-width digits fold onto their ASCII forms", () => {
  // 中文媒体里全角数字很常见。不折叠的话，同一件事写成 ０５ 和 05
  // 会得到零重叠——两篇一模一样的稿会被判成互相独立的两个源。
  expect(normalize("降准０．５个百分点")).toBe(normalize("降准0.5个百分点"));
  expect(normalize("释放资金１万亿")).toBe("释放资金1万亿");
});

test("zero-width characters left over from scraping do not affect the fingerprint", () => {
  expect(normalize("降准\u200B零点五\uFEFF个百分点")).toBe("降准零点五个百分点");
});

test("identical text has jaccard 1", () => {
  const a = shingles("下调存款准备金率０点五个百分点", 5);
  expect(jaccard(a, a)).toBe(1);
});

test("unrelated text has jaccard 0", () => {
  const a = shingles("下调存款准备金率零点五个百分点", 5);
  const b = shingles("港股通标的调整散户要注意什么", 5);
  expect(jaccard(a, b)).toBe(0);
});

test("partial overlap gives the exact ratio, pinning the union formula", () => {
  // abcdefg → abc bcd cde def efg（5 个）
  // cdefghi → cde def efg fgh ghi（5 个）
  // 共享 3 个，并集 5 + 5 − 3 = 7
  expect(jaccard(shingles("abcdefg", 3), shingles("cdefghi", 3))).toBeCloseTo(3 / 7, 10);
});

test("a repost that only changed its lede still scores high", () => {
  const wire = "央行今日宣布下调金融机构存款准备金率零点五个百分点，此次降准将释放长期资金约一万亿元，自三月十五日起生效。";
  const repost = "【快讯】央行今日宣布下调金融机构存款准备金率零点五个百分点，此次降准将释放长期资金约一万亿元，自三月十五日起生效。";
  // 实测 46/48。钉到小数点后三位，这样改错了并集公式会当场失败——
  // 原来的 > 0.9 太松，`shared/(union+1)` 之类的错能混过去。
  expect(jaccard(shingles(wire, 5), shingles(repost, 5))).toBeCloseTo(0.9583, 3);
});

test("two texts with no shingles at all are treated as identical", () => {
  expect(jaccard(shingles("abc", 5), shingles("xy", 5))).toBe(1);
});
```

最后一条是刻意的：短于 k 的文本产不出 shingle，两个空集判为相同——调用方必须自己保证正文够长，而不是靠这个函数给出一个似是而非的分数。

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/shingle.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/dedupe/shingle.js"`

- [ ] **Step 3: 实现**

`pipeline/src/dedupe/shingle.ts`：

```ts
/** 5-gram 用于整篇正文比对，2-gram 用于短句比对。 */
export const BODY_SHINGLE_K = 5;
export const TEXT_SHINGLE_K = 2;

/**
 * 归一化到「只剩会影响语义的字符」。三步：
 *
 * 1. `NFKC` 把全角折成半角。中文媒体里全角数字很常见，不折叠的话同一件事
 *    写成 ０５ 和 05 会得到零重叠，两篇一模一样的稿会被判成互相独立的两个源。
 *    这是 JS 内置的，不引依赖。
 * 2. 去掉抓取残留的零宽字符（NFKC 不管这些）。
 * 3. 去掉空白与所有标点/符号。
 *
 * 中文没有词边界，逐字符 shingle 比分词更稳，也不用引分词依赖。
 *
 * **已知局限**：中文数字不会折成阿拉伯数字（「零点五」≠「0.5」）。
 * 真要处理得往上加一层数字归一，不在本包范围内。
 */
export function normalize(text: string): string {
  return text
    .normalize("NFKC")
    .replace(/[\u200B-\u200D\uFEFF]/gu, "")
    .replace(/[\s\p{P}\p{S}]+/gu, "");
}

export function shingles(text: string, k: number): Set<string> {
  const s = normalize(text);
  const out = new Set<string>();
  for (let i = 0; i + k <= s.length; i++) out.add(s.slice(i, i + k));
  return out;
}

/** 空集与空集判为相同：短于 k 的文本本函数无法比较，由调用方负责。 */
export function jaccard(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 && b.size === 0) return 1;
  let shared = 0;
  for (const x of a) if (b.has(x)) shared += 1;
  const union = a.size + b.size - shared;
  return union === 0 ? 1 : shared / union;
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/shingle.test.ts
```

Expected: `8 passed`

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/dedupe/shingle.ts pipeline/test/shingle.test.ts
git commit -m "Measure how much two pieces of text overlap"
```

---

### Task 4: 独立源计数（本计划最关键的一个）

spec §11 第一行：「构造『1 篇通讯社稿 + 5 篇转载』，必须判成 independence = 1。这是最关键的单测。」

**Files:**
- Create: `pipeline/src/dedupe/independence.ts`
- Test: `pipeline/test/independence.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/independence.test.ts`：

```ts
import { expect, test } from "vitest";
import type { Source } from "../src/domain/types.js";
import { groupSources, independenceOf } from "../src/dedupe/independence.js";

const WIRE = "央行今日宣布下调金融机构存款准备金率零点五个百分点，此次降准将释放长期资金约一万亿元，自三月十五日起生效。";

function src(id: string, publisher: string, body: string, creditedTo: string | null = null): Source {
  return { id, url: `https://${publisher}.example/${id}`, publisher, publishedAt: "2026-03-01T07:00:00Z", body, creditedTo };
}

test("one wire story plus five reposts counts as a single source", () => {
  const sources = [
    src("s0", "xinhua", WIRE),
    src("s1", "portal-a", `【转载】${WIRE}`),
    src("s2", "portal-b", `${WIRE}（完）`),
    src("s3", "portal-c", WIRE),
    src("s4", "portal-d", `快讯｜${WIRE}`),
    src("s5", "portal-e", WIRE),
  ];
  const groups = groupSources(sources);
  expect(groups).toHaveLength(1);
  expect(independenceOf(sources.map((s) => s.id), groups)).toBe(1);
});

test("an explicit credit line collapses a source into the one it credits", () => {
  const sources = [
    src("s0", "xinhua", WIRE),
    src("s1", "portal-a", "据新华社报道，央行今日决定实施降准，市场反应积极，多位分析师认为这一决定符合预期。", "xinhua"),
  ];
  expect(groupSources(sources)).toHaveLength(1);
});

test("rule 2 works whichever way round the credit line sits", () => {
  // 上一条测试里被 credit 的一方排在前面，只命中了 `b.creditedTo === a.publisher`。
  // 这一条把顺序倒过来，钉住另半个子句——不然把它删掉，七个测试照样全绿。
  const sources = [
    src("s0", "portal-a", "据新华社报道，央行今日决定实施降准，市场反应积极，多位分析师认为这一决定符合预期。", "xinhua"),
    src("s1", "xinhua", WIRE),
  ];
  expect(groupSources(sources)).toHaveLength(1);
});

test("the fingerprint threshold is inclusive at exactly 0.5", () => {
  // abcdefg → abcde bcdef cdefg；bcdefgh → bcdef cdefg defgh
  // 共享 2 个，并集 3 + 3 − 2 = 4，jaccard 恰好 0.5。
  // `>=` 归并、`>` 不归并——这是唯一能钉住那个运算符的测试。
  const atThreshold = [src("s0", "portal-a", "abcdefg"), src("s1", "portal-b", "bcdefgh")];
  expect(groupSources(atThreshold)).toHaveLength(1);

  // abcdefg vs cdefghi 只共享 cdefg，jaccard 0.2，不该归并
  const below = [src("s0", "portal-a", "abcdefg"), src("s1", "portal-b", "cdefghi")];
  expect(groupSources(below)).toHaveLength(2);
});

test("same publisher is one source even when the two pieces differ", () => {
  const sources = [
    src("s0", "caixin", "央行降准零点五个百分点，为年内第二次，释放资金约一万亿元。"),
    src("s1", "caixin", "降准之后，按揭利率是否跟进下调？多位银行人士给出不同判断。"),
  ];
  expect(groupSources(sources)).toHaveLength(1);
});

test("a media group table collapses sibling outlets", () => {
  const sources = [
    src("s0", "outlet-a", "央行降准零点五个百分点，为年内第二次，释放资金约一万亿元。"),
    src("s1", "outlet-b", "降准之后，按揭利率是否跟进下调？多位银行人士给出不同判断。"),
  ];
  const groups = groupSources(sources, { "outlet-a": "group-x", "outlet-b": "group-x" });
  expect(groups).toHaveLength(1);
});

test("sources too short to fingerprint are never merged by fingerprint", () => {
  // 抓取失败的两条新闻各自产不出 shingle。两个空集的 Jaccard 是 1，
  // 所以这里必须靠 groupSources 的守卫挡住，否则独立源数会少算。
  const sources = [src("s0", "portal-a", "无正文"), src("s1", "portal-b", "")];
  expect(groupSources(sources)).toHaveLength(2);
});

test("genuinely independent reporting stays separate", () => {
  const sources = [
    src("s0", "pbc", "中国人民银行决定于三月十五日下调金融机构存款准备金率零点五个百分点。"),
    src("s1", "reuters", "Reuters 独立测算显示，此次操作对应释放的长期资金规模在一万亿元左右。"),
    src("s2", "caixin", "财新记者从多家银行了解到，降准落地后信贷投放节奏将有所前移。"),
  ];
  const groups = groupSources(sources);
  expect(groups).toHaveLength(3);
  expect(independenceOf(["s0", "s1", "s2"], groups)).toBe(3);
});

test("independence only counts the groups a claim actually cites", () => {
  const sources = [
    src("s0", "pbc", "中国人民银行决定于三月十五日下调金融机构存款准备金率零点五个百分点。"),
    src("s1", "reuters", "Reuters 独立测算显示，此次操作对应释放的长期资金规模在一万亿元左右。"),
    src("s2", "caixin", "财新记者从多家银行了解到，降准落地后信贷投放节奏将有所前移。"),
  ];
  const groups = groupSources(sources);
  expect(independenceOf(["s0", "s1"], groups)).toBe(2);
});
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/independence.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/dedupe/independence.js"`

- [ ] **Step 3: 实现**

`pipeline/src/dedupe/independence.ts`：

```ts
import type { Source, SourceId } from "../domain/types.js";
import { BODY_SHINGLE_K, jaccard, shingles } from "./shingle.js";

/** 正文相似度到这个值就判为同一份稿。用真实转载样本调过再改。 */
export const SAME_SOURCE_JACCARD = 0.5;

export interface SourceGroup {
  sourceIds: SourceId[];
}

/**
 * 把互相转载、互相署名、同一媒体主体的 Source 并成一组。
 * **组数才是 independence，信源条数不是。** 同一份通讯社稿被五家门户转载，
 * 是 1 个源不是 5 个——这个数字算错，整个「每句可溯源」的承诺就是假的。
 *
 * **已知盲区**——两处都朝「独立源算多了」这个危险方向，修法涉及产品判断而非
 * 机械修复，记在下一个计划里：
 *
 * 1. 只逐字摘引 wire 稿一段、其余自己写的轻改转载，整篇 5-gram Jaccard 会远低于
 *    0.5，三条规则全部漏掉，于是同一份通稿被当成两个独立源。要接住它得上段落级
 *    或滑窗级相似度。
 * 2. 两家门户都写「据新华社报道」、而新华社原稿不在本次信源集合里时，rule 2 不匹配
 *    ——它比的是 `a.creditedTo === b.publisher`，不是两边 `creditedTo` 相等。
 *
 * @param mediaGroups publisher → 媒体集团 key 的映射。同集团视为同一主体。
 */
export function groupSources(
  sources: Source[],
  mediaGroups: Record<string, string> = {},
): SourceGroup[] {
  const parent = sources.map((_, i) => i);

  const find = (i: number): number => {
    let root = i;
    while (parent[root] !== root) root = parent[root]!;
    let walk = i;
    while (parent[walk] !== root) {
      const next = parent[walk]!;
      parent[walk] = root;
      walk = next;
    }
    return root;
  };
  const union = (a: number, b: number): void => {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  };

  const prints = sources.map((s) => shingles(s.body, BODY_SHINGLE_K));
  const subject = (s: Source): string => mediaGroups[s.publisher] ?? s.publisher;

  for (let i = 0; i < sources.length; i++) {
    for (let j = i + 1; j < sources.length; j++) {
      const a = sources[i]!;
      const b = sources[j]!;

      // 规则 1：正文指纹相似 —— 同一份稿的转载
      //
      // 先要求两边都产出了指纹。抓取失败或正文短于 k 的源产不出 shingle，
      // 而**两个空集的 Jaccard 是 1**——不挡的话，两条毫不相干的新闻会被
      // 并成一个源，独立源数就少算了。jaccard 是纯算术函数，「什么叫一个
      // 信源」的判断属于这里。
      if (prints[i]!.size > 0 && prints[j]!.size > 0
        && jaccard(prints[i]!, prints[j]!) >= SAME_SOURCE_JACCARD) {
        union(i, j);
        continue;
      }
      // 规则 2：显式署名指向对方
      if (a.creditedTo === b.publisher || b.creditedTo === a.publisher) {
        union(i, j);
        continue;
      }
      // 规则 3：同一媒体主体
      if (subject(a) === subject(b)) union(i, j);
    }
  }

  const byRoot = new Map<number, SourceId[]>();
  for (let i = 0; i < sources.length; i++) {
    const root = find(i);
    const bucket = byRoot.get(root);
    if (bucket) bucket.push(sources[i]!.id);
    else byRoot.set(root, [sources[i]!.id]);
  }
  return [...byRoot.values()].map((sourceIds) => ({ sourceIds }));
}

/** 一条 Claim 引用的这些信源，落在几个互不相关的组里。 */
export function independenceOf(cited: SourceId[], groups: SourceGroup[]): number {
  const wanted = new Set(cited);
  let count = 0;
  for (const group of groups) {
    if (group.sourceIds.some((id) => wanted.has(id))) count += 1;
  }
  return count;
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/independence.test.ts
```

Expected: `9 passed`

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/dedupe/independence.ts pipeline/test/independence.test.ts
git commit -m "Count sources that are actually independent of each other"
```

---

### Task 5: 归并事实点

**Files:**
- Create: `pipeline/src/dedupe/merge.ts`
- Test: `pipeline/test/merge.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/merge.test.ts`：

```ts
import { expect, test } from "vitest";
import type { Fact } from "../src/domain/types.js";
import { mergeFacts, numericSignature } from "../src/dedupe/merge.js";

function fact(id: string, sourceId: string, text: string): Fact {
  return { id, sourceId, text, quote: text };
}

test("the signature carries each number together with its unit, sorted", () => {
  expect(numericSignature("降准 0.5 个百分点，释放 1 万亿元，3 月 15 日生效"))
    .toEqual(["0.5个百", "15日生", "1万亿", "3月"]);
});

test("numeric signature is empty when there are no numbers", () => {
  expect(numericSignature("央行今天突然出手了")).toEqual([]);
});

test("the same fact worded differently by two outlets merges", () => {
  const facts = [
    fact("f0", "s0", "此次降准释放长期资金约 1 万亿元"),
    fact("f1", "s1", "此次降准将释放长期资金约 1 万亿元"),
  ];
  const claims = mergeFacts(facts);
  expect(claims).toHaveLength(1);
  expect(claims[0]!.factIds).toEqual(["f0", "f1"]);
});

test("same wording but a different number does NOT merge", () => {
  const facts = [
    fact("f0", "s0", "涉及金额约 23 亿美元"),
    fact("f1", "s1", "涉及金额约 31 亿美元"),
  ];
  expect(mergeFacts(facts)).toHaveLength(2);
});

test("same figure in a different currency does NOT merge", () => {
  // 只取裸数字时两边签名都是 ["23"]，文本相似度 0.64 远超门槛，会被并成一条，
  // 其中一种币种在到达 ⑤ 的冲突检测之前就没了。单位进签名就是为了挡住这个。
  const facts = [
    fact("f0", "s0", "涉及金额约 23 亿美元"),
    fact("f1", "s1", "涉及金额约 23 亿欧元"),
  ];
  expect(mergeFacts(facts)).toHaveLength(2);
});

test("unrelated facts stay apart", () => {
  const facts = [
    fact("f0", "s0", "此次降准释放长期资金约 1 万亿元"),
    fact("f1", "s1", "港股通标的下个月调整"),
  ];
  expect(mergeFacts(facts)).toHaveLength(2);
});

test("number-free facts need a higher bar to merge", () => {
  const near = [
    fact("f0", "s0", "多位分析师认为这一决定符合市场预期"),
    fact("f1", "s1", "多位分析师认为这一决定基本符合市场预期"),
  ];
  expect(mergeFacts(near)).toHaveLength(1);

  const looser = [
    fact("f2", "s0", "多位分析师认为这一决定符合市场预期"),
    fact("f3", "s1", "分析师对后续政策走向看法不一"),
  ];
  expect(mergeFacts(looser)).toHaveLength(2);
});

test("MERGE_JACCARD is inclusive at exactly 0.45", () => {
  // 两串末尾带同一个「1」，所以数字签名相同，走的是 0.45 这条门槛。
  // "abcdefghij1" → 10 个 2-gram；"abcdefghijklmnopqrs1" → 19 个；共享 9，
  // 并集 20 —— jaccard 恰好 0.45。`>=` 归并、`>` 不归并，也抓「两个常量互换」。
  expect(mergeFacts([
    fact("f0", "s0", "abcdefghij 1"),
    fact("f1", "s1", "abcdefghijklmnopqrs 1"),
  ])).toHaveLength(1);

  // "abc1" / "abcd1" 的 jaccard 是 0.4，低于门槛，不该归并——挡住阈值被调低
  expect(mergeFacts([
    fact("f2", "s0", "abc 1"),
    fact("f3", "s1", "abcd 1"),
  ])).toHaveLength(2);
});

test("MERGE_JACCARD_NO_NUMBERS is inclusive at exactly 0.7", () => {
  // 两串都没有数字，走的是 0.7 这条门槛。
  // "abcdefgh" → 7 个 2-gram；"abcdefghijk" → 10 个；共享 7，并集 10 —— 恰好 0.7。
  expect(mergeFacts([
    fact("f0", "s0", "abcdefgh"),
    fact("f1", "s1", "abcdefghijk"),
  ])).toHaveLength(1);

  // "abc" / "abcd" 的 jaccard 是 0.667：低于 0.7 不该归并，
  // 但它高于 0.45 —— 所以两个常量被互换的话这一条会失败。
  expect(mergeFacts([
    fact("f2", "s0", "abc"),
    fact("f3", "s1", "abcd"),
  ])).toHaveLength(2);
});

test("a merged claim keeps the longest wording", () => {
  const facts = [
    fact("f0", "s0", "降准释放资金约 1 万亿元"),
    fact("f1", "s1", "此次降准将释放长期资金约 1 万亿元"),
  ];
  expect(mergeFacts(facts)[0]!.text).toBe("此次降准将释放长期资金约 1 万亿元");
});
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/merge.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/dedupe/merge.js"`

- [ ] **Step 3: 实现**

`pipeline/src/dedupe/merge.ts`：

```ts
import type { Fact, MergedClaim } from "../domain/types.js";
import { jaccard, shingles, TEXT_SHINGLE_K } from "./shingle.js";

/** 数字一致时，文本相似到这个值就算同一件事。 */
export const MERGE_JACCARD = 0.45;
/** 两边都没有数字时，门槛抬高——没有数字可对，只能更信文本。 */
export const MERGE_JACCARD_NO_NUMBERS = 0.7;

/** 数字，加上紧跟的最多两个非数字非空白字符。 */
const NUMBER_WITH_UNIT = /(\d+(?:\.\d+)?)\s*([^\d\s]{0,2})/gu;

/**
 * 一句话里的全部「数字 + 单位」，排序后作为签名。
 * 数字是口播稿里最容易翻车的东西：**签名不一致，绝不归并**。
 *
 * 为什么单位必须一起吃进来：只取裸数字时，「涉及金额约 23 亿美元」和
 * 「涉及金额约 23 亿欧元」的签名都是 `["23"]`，而两句的 2-gram 相似度是
 * 0.64，远超归并门槛——它们会被并成一条，其中一种币种**在到达 ⑤ 的冲突
 * 检测之前就消失了**。数字不同本来指望 ⑤ 去判冲突，可这一类 gate 压根
 * 不触发，所以补在这里，不能推给下一个计划。
 *
 * 只吃两个字符是刻意的：「亿美」「亿欧」已经足够区分，再多吃会把
 * 「日起生效」这类行文差异也算进签名，让同一事实的两种措辞不归并。
 * 少归并是安全方向（claim 显得信源更少、被标 weak），多归并不是。
 *
 * 仍然不做单位换算或归一化：「1.50」≠「1.5」、「5%」≠「5 个百分点」，
 * 这些都是漏归并，朝安全方向。
 */
export function numericSignature(text: string): string[] {
  return [...text.matchAll(NUMBER_WITH_UNIT)].map((m) => m[1]! + (m[2] ?? "")).sort();
}

function sameNumbers(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

/**
 * ④ 归并：说同一件事的 Fact 合成一个 Claim。
 * 返回 MergedClaim——independence 和 confidence 是 ⑤ 的事，这里连字段都没有。
 */
export function mergeFacts(facts: Fact[]): MergedClaim[] {
  const parent = facts.map((_, i) => i);
  const find = (i: number): number => {
    let root = i;
    while (parent[root] !== root) root = parent[root]!;
    return root;
  };
  const union = (a: number, b: number): void => {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  };

  const prints = facts.map((f) => shingles(f.text, TEXT_SHINGLE_K));
  const numbers = facts.map((f) => numericSignature(f.text));

  for (let i = 0; i < facts.length; i++) {
    for (let j = i + 1; j < facts.length; j++) {
      const na = numbers[i]!;
      const nb = numbers[j]!;
      if (!sameNumbers(na, nb)) continue;

      const bar = na.length === 0 ? MERGE_JACCARD_NO_NUMBERS : MERGE_JACCARD;
      if (jaccard(prints[i]!, prints[j]!) >= bar) union(i, j);
    }
  }

  const byRoot = new Map<number, number[]>();
  for (let i = 0; i < facts.length; i++) {
    const root = find(i);
    const bucket = byRoot.get(root);
    if (bucket) bucket.push(i);
    else byRoot.set(root, [i]);
  }

  return [...byRoot.values()].map((indices, n) => {
    // 最长的措辞信息量最大，用它当 Claim 的表述
    const longest = indices.reduce((best, i) =>
      facts[i]!.text.length > facts[best]!.text.length ? i : best, indices[0]!);
    return {
      id: `c${n}`,
      text: facts[longest]!.text,
      factIds: indices.map((i) => facts[i]!.id),
    } satisfies MergedClaim;
  });
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/merge.test.ts
```

Expected: `10 passed`

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/dedupe/merge.ts pipeline/test/merge.test.ts
git commit -m "Fold facts that say the same thing into one claim"
```

---

### Task 6: 数字冲突

spec §5.1 举的例子就是这个：路透 23 亿 vs 彭博 31 亿。**最危险的冲突是数字冲突，而它不需要模型。**

**Files:**
- Create: `pipeline/src/dedupe/conflict.ts`
- Test: `pipeline/test/conflict.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/conflict.test.ts`：

```ts
import { expect, test } from "vitest";
import type { MergedClaim } from "../src/domain/types.js";
import { findNumericConflicts } from "../src/dedupe/conflict.js";

function claim(id: string, text: string): MergedClaim {
  return { id, text, factIds: [] };
}

test("same claim, different figure — the Reuters vs Bloomberg case", () => {
  const claims: MergedClaim[] = [
    claim("c0", "此次交易涉及金额约 23 亿美元"),
    claim("c1", "此次交易涉及金额约 31 亿美元"),
  ];
  expect(findNumericConflicts(claims)).toEqual([["c0", "c1"]]);
});

test("agreeing figures are not a conflict", () => {
  const claims = [
    claim("c0", "此次交易涉及金额约 23 亿美元"),
    claim("c1", "该笔交易涉及金额约 23 亿美元"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});

test("different claims that happen to carry different numbers are not a conflict", () => {
  const claims = [
    claim("c0", "此次降准释放长期资金约 1 万亿元"),
    claim("c1", "港股通标的下个月新增 12 只"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});

test("a claim that merely omits a date is not in conflict", () => {
  // 「降准 0.5 个百分点」只是没提日期，对共同提到的数字完全一致。
  // 签名长度不等 ≠ 说法不同——子集关系才是判据。实测 jaccard 0.583，
  // 不挡住的话这一对会被误报成冲突，一条好 claim 就被扔了。
  const claims = [
    claim("c0", "3 月 15 日降准 0.5 个百分点"),
    claim("c1", "降准 0.5 个百分点"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});

test("a figure against an undisclosed figure is out of scope, not a conflict", () => {
  // 两句话确实矛盾，但一边根本没有数字可比。空集是任何集合的子集，
  // 所以这一类和语义冲突一样，留给下一个计划的模型阶段。
  const claims = [
    claim("c0", "此次交易涉及金额约 23 亿美元"),
    claim("c1", "此次交易涉及金额未披露"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});

test("CONFLICT_SUBJECT_JACCARD is inclusive at exactly 0.45", () => {
  // "abcdefghij1" → 10 个 2-gram；"abcdefghijklmnopqrs2" → 19 个；
  // 共享 9，并集 20 —— jaccard 恰好 0.45。签名 ["1"] 与 ["2"] 互不为子集。
  // `>=` 报冲突、`>` 不报，这是唯一钉住那个运算符的测试。
  expect(findNumericConflicts([
    claim("c0", "abcdefghij 1"),
    claim("c1", "abcdefghijklmnopqrs 2"),
  ])).toEqual([["c0", "c1"]]);
});

test("a claim with no numbers cannot conflict numerically", () => {
  const claims = [
    claim("c0", "多位分析师认为这一决定符合市场预期"),
    claim("c1", "多位分析师认为这一决定不符合市场预期"),
  ];
  expect(findNumericConflicts(claims)).toEqual([]);
});
```

最后一条记录了本计划的边界：那两句是**真冲突**，但它是语义冲突，不是数字冲突。检出它需要模型，属于下一个计划。测试写出来是为了让这个洞**可见**，不是为了掩盖它。

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/conflict.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/dedupe/conflict.js"`

- [ ] **Step 3: 实现**

`pipeline/src/dedupe/conflict.ts`：

```ts
import type { ClaimId, MergedClaim } from "../domain/types.js";
import { numericSignature } from "./merge.js";
import { jaccard, shingles, TEXT_SHINGLE_K } from "./shingle.js";

/**
 * 两条 Claim 讲的是不是同一件事。
 *
 * 数值上目前和 `MERGE_JACCARD` 一样，但**故意是独立的常量**，因为两者的失败
 * 方向相反：归并多触发会丢掉一个数字（危险方向），所以它该偏保守；这里多
 * 触发只是把一条好 claim 扔掉（安全方向），**漏**触发才危险——一个有争议的
 * 数字会被当成定论播出去。将来标定时两边该往相反方向调，共用一个数就意味着
 * 为了归并调一次，会悄悄改掉冲突检测的漏检率，而且没有任何东西会报错。
 */
export const CONFLICT_SUBJECT_JACCARD = 0.45;

/** na 的每个数字（计重复）都能在 nb 里找到——na 只是说得少，没有和 nb 矛盾。 */
function isSubMultiset(na: string[], nb: string[]): boolean {
  const remaining = new Map<string, number>();
  for (const value of nb) remaining.set(value, (remaining.get(value) ?? 0) + 1);
  for (const value of na) {
    const left = remaining.get(value) ?? 0;
    if (left === 0) return false;
    remaining.set(value, left - 1);
  }
  return true;
}

/**
 * ⑤ 的确定性一半：文本讲的是同一件事，但数字对不上。
 *
 * 归并（④）要求签名一致才合并，所以这些 Claim 必然是分开的两条；
 * 它们的文本相似度却很高——这正是「两家都在说这件事，但数不一样」。
 *
 * **子集不算冲突。** 「3 月 15 日降准 0.5 个百分点」和「降准 0.5 个百分点」
 * 对共同提到的数字完全一致，后者只是没提日期——签名长度不等不等于说法不同。
 * 这一条顺带覆盖了「两边都没数字」和「只有一边有数字」：空集是任何集合的子集，
 * 所以不再需要单独的空签名 guard。
 *
 * 语义冲突（同一件事、说法相反、没有数字）检不出来，那需要模型，见下一个计划。
 */
export function findNumericConflicts(claims: MergedClaim[]): [ClaimId, ClaimId][] {
  const prints = claims.map((c) => shingles(c.text, TEXT_SHINGLE_K));
  const numbers = claims.map((c) => numericSignature(c.text));
  const pairs: [ClaimId, ClaimId][] = [];

  for (let i = 0; i < claims.length; i++) {
    for (let j = i + 1; j < claims.length; j++) {
      if (isSubMultiset(numbers[i]!, numbers[j]!) || isSubMultiset(numbers[j]!, numbers[i]!)) continue;
      if (jaccard(prints[i]!, prints[j]!) >= CONFLICT_SUBJECT_JACCARD) {
        pairs.push([claims[i]!.id, claims[j]!.id]);
      }
    }
  }
  return pairs;
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/conflict.test.ts
```

Expected: `7 passed`

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/dedupe/conflict.ts pipeline/test/conflict.test.ts
git commit -m "Catch the two outlets that disagree about a number"
```

---

### Task 7: confidence 判定

**Files:**
- Create: `pipeline/src/dedupe/classify.ts`
- Test: `pipeline/test/classify.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/classify.test.ts`：

```ts
import { expect, test } from "vitest";
import type { Fact, MergedClaim, Source } from "../src/domain/types.js";
import { classifyClaims, STRONG_INDEPENDENCE } from "../src/dedupe/classify.js";

const BODIES: Record<string, string> = {
  pbc: "中国人民银行决定于三月十五日下调金融机构存款准备金率零点五个百分点。",
  reuters: "Reuters 独立测算显示，此次操作对应释放的长期资金规模在一万亿元左右。",
  caixin: "财新记者从多家银行了解到，降准落地后信贷投放节奏将有所前移。",
};

function src(id: string, publisher: string): Source {
  return { id, url: `https://${publisher}.example/${id}`, publisher, publishedAt: "2026-03-01T07:00:00Z", body: BODIES[publisher]!, creditedTo: null };
}
function fact(id: string, sourceId: string): Fact {
  return { id, sourceId, text: "t", quote: "t" };
}
function claim(id: string, factIds: string[]): MergedClaim {
  return { id, text: "涉及金额约 23 亿美元", factIds };
}

test("three independent groups make a claim strong", () => {
  const sources = [src("s0", "pbc"), src("s1", "reuters"), src("s2", "caixin")];
  const facts = [fact("f0", "s0"), fact("f1", "s1"), fact("f2", "s2")];
  const [out] = classifyClaims([claim("c0", ["f0", "f1", "f2"])], facts, sources);
  expect(out!.independence).toBe(STRONG_INDEPENDENCE);
  expect(out!.confidence).toBe("strong");
});

test("a single source makes a claim weak, however many reposts back it", () => {
  const sources = [src("s0", "pbc"), src("s1", "pbc")];
  const facts = [fact("f0", "s0"), fact("f1", "s1")];
  const [out] = classifyClaims([claim("c0", ["f0", "f1"])], facts, sources);
  expect(out!.independence).toBe(1);
  expect(out!.confidence).toBe("weak");
});

test("two independent groups is one short of strong", () => {
  // 门槛是 3。没有这一条，把 STRONG_INDEPENDENCE 改成 2 不会有任何测试变红
  // ——而那正是危险方向：只有两个独立源的说法会被当成可以对着镜头说。
  const sources = [src("s0", "pbc"), src("s1", "reuters")];
  const facts = [fact("f0", "s0"), fact("f1", "s1")];
  const [out] = classifyClaims([claim("c0", ["f0", "f1"])], facts, sources);
  expect(out!.independence).toBe(2);
  expect(out!.confidence).toBe("weak");
});

test("a claim that conflicts with nothing is left alone", () => {
  // 只有两条 claim 且两条都冲突时，「把所有 claim 都标成 conflicted」这种错
  // 也能过。加一条不冲突的当阴性对照。
  const sources = [src("s0", "pbc"), src("s1", "reuters"), src("s2", "caixin")];
  const facts = [fact("f0", "s0"), fact("f1", "s1"), fact("f2", "s2")];
  const claims: MergedClaim[] = [
    { ...claim("c0", ["f0", "f1", "f2"]), text: "涉及金额约 23 亿美元" },
    { ...claim("c1", ["f0", "f1", "f2"]), text: "涉及金额约 31 亿美元" },
    { ...claim("c2", ["f0", "f1", "f2"]), text: "降准落地后信贷投放节奏将有所前移" },
  ];
  const out = classifyClaims(claims, facts, sources);
  expect(out.map((c) => c.confidence)).toEqual(["conflicted", "conflicted", "strong"]);
  expect(out[2]!.conflictsWith).toEqual([]);
});

test("mediaGroups reaches the source grouping", () => {
  // 没有这一条，把 groupSources(sources, mediaGroups) 写成 groupSources(sources)
  // 不会有任何测试变红——而「同集团算一个源」是 §5 的三条规则之一。
  const sources = [src("s0", "pbc"), src("s1", "reuters"), src("s2", "caixin")];
  const facts = [fact("f0", "s0"), fact("f1", "s1"), fact("f2", "s2")];

  expect(classifyClaims([claim("c0", ["f0", "f1", "f2"])], facts, sources)[0]!.independence).toBe(3);

  const grouped = classifyClaims([claim("c0", ["f0", "f1", "f2"])], facts, sources,
    { pbc: "g", reuters: "g", caixin: "g" });
  expect(grouped[0]!.independence).toBe(1);
  expect(grouped[0]!.confidence).toBe("weak");
});

test("a claim citing facts that were not supplied is a caller error, not a weak claim", () => {
  // 全部 factId 都解析不到时 independence 会悄悄变成 0，而这条 claim 仍被标成
  // weak——一条**没有任何信源支撑**的说法会带着「弱」的标签进稿。这只可能是
  // 调用方传错了数组，所以响亮地失败。
  expect(() => classifyClaims([claim("c0", ["f9"])], [fact("f0", "s0")], [src("s0", "pbc")]))
    .toThrow(/c0/);
});

test("a numeric conflict overrides independence entirely", () => {
  const sources = [src("s0", "pbc"), src("s1", "reuters"), src("s2", "caixin")];
  const facts = [fact("f0", "s0"), fact("f1", "s1"), fact("f2", "s2")];
  const claims: MergedClaim[] = [
    { ...claim("c0", ["f0", "f1", "f2"]), text: "涉及金额约 23 亿美元" },
    { ...claim("c1", ["f0", "f1", "f2"]), text: "涉及金额约 31 亿美元" },
  ];
  const out = classifyClaims(claims, facts, sources);
  expect(out.map((c) => c.confidence)).toEqual(["conflicted", "conflicted"]);
  expect(out[0]!.conflictsWith).toEqual(["c1"]);
  expect(out[1]!.conflictsWith).toEqual(["c0"]);
});
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/classify.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/dedupe/classify.js"`

- [ ] **Step 3: 实现**

`pipeline/src/dedupe/classify.ts`：

```ts
import type { ClaimId, Fact, MergedClaim, Source, VerifiedClaim } from "../domain/types.js";
import { findNumericConflicts } from "./conflict.js";
import { groupSources, independenceOf } from "./independence.js";

/** 到这个独立源组数才算「敢播」。spec §5 定的。 */
export const STRONG_INDEPENDENCE = 3;

/**
 * ⑤ 交叉验证：给每条 Claim 填上 independence 与 confidence。
 * 冲突优先级最高——三个独立源都说的话，只要和另一条数字打架，照样不进稿。
 */
export function classifyClaims(
  claims: MergedClaim[],
  facts: Fact[],
  sources: Source[],
  mediaGroups: Record<string, string> = {},
): VerifiedClaim[] {
  const groups = groupSources(sources, mediaGroups);
  const sourceOfFact = new Map(facts.map((f) => [f.id, f.sourceId]));

  const conflicts = new Map<ClaimId, ClaimId[]>();
  for (const [a, b] of findNumericConflicts(claims)) {
    conflicts.set(a, [...(conflicts.get(a) ?? []), b]);
    conflicts.set(b, [...(conflicts.get(b) ?? []), a]);
  }

  return claims.map((claim) => {
    // 部分 factId 解析不到时静默丢弃：只会让 independence 变小，claim 被标得
    // 更弱，是安全方向。但**全部**解析不到意味着调用方传的 facts 和产出
    // claims 的那份不是同一个数组——那时 independence 会是 0，而这条毫无
    // 信源支撑的说法仍会被标成 weak 进稿。那是调用方的 bug，响亮地失败。
    const cited = claim.factIds
      .map((id) => sourceOfFact.get(id))
      .filter((id): id is string => id !== undefined);
    if (claim.factIds.length > 0 && cited.length === 0) {
      throw new Error(
        `claim ${claim.id} cites ${claim.factIds.length} fact(s), none of which are in the facts array`,
      );
    }
    const independence = independenceOf(cited, groups);
    const against = conflicts.get(claim.id) ?? [];

    return {
      ...claim,
      independence,
      conflictsWith: against,
      confidence: against.length > 0
        ? "conflicted"
        : independence >= STRONG_INDEPENDENCE ? "strong" : "weak",
    } satisfies VerifiedClaim;
  });
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/classify.test.ts
```

Expected: `7 passed`

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/dedupe/classify.ts pipeline/test/classify.test.ts
git commit -m "Decide which claims are safe enough to say out loud"
```

---

### Task 8: 成本估算

**Files:**
- Create: `pipeline/src/domain/estimate.ts`
- Test: `pipeline/test/estimate.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/estimate.test.ts`：

```ts
import { expect, test } from "vitest";
import { DURATION_STEPS, ESTIMATE_COEFFICIENTS, estimateBrief } from "../src/domain/estimate.js";

test("the dial's ten duration steps are the ones the mock shows", () => {
  expect(DURATION_STEPS).toEqual([30, 45, 60, 90, 120, 150, 180, 240, 300, 360]);
});

test("an off-step duration snaps to the nearest step", () => {
  expect(estimateBrief(100, 0.5).durationSec).toBe(90);
  expect(estimateBrief(1, 0.5).durationSec).toBe(30);
  expect(estimateBrief(9999, 0.5).durationSec).toBe(360);
});

test("register is clamped to 0..1", () => {
  expect(estimateBrief(60, -3).register).toBe(0);
  expect(estimateBrief(60, 7).register).toBe(1);
});

test("the 1:00 通俗 anchor", () => {
  const e = estimateBrief(60, 0.25);
  expect(e.tokens).toBe(68500);
  expect(e.sources).toBe(11);
  expect(e.factSlots).toBe(3);
  expect(e.researchMinutes).toBe(4);
});

test("the 3:00 偏专业 anchor", () => {
  const e = estimateBrief(180, 0.75);
  expect(e.tokens).toBe(175500);
  expect(e.sources).toBe(21);
  expect(e.factSlots).toBe(7);
  // 2 + 3×1.2 + 0.75×2.5 = 7.475 → 7
  expect(e.researchMinutes).toBe(7);
});

test("both axes only ever push cost up", () => {
  const cheap = estimateBrief(30, 0);
  const dear = estimateBrief(360, 1);
  expect(cheap.tokens).toBeLessThan(dear.tokens);
  for (let i = 1; i < DURATION_STEPS.length; i++) {
    const prev = estimateBrief(DURATION_STEPS[i - 1]!, 0.5).tokens;
    expect(estimateBrief(DURATION_STEPS[i]!, 0.5).tokens).toBeGreaterThan(prev);
  }
});

test("a value exactly between two steps rounds down", () => {
  // 拨盘被拖拽时中点天天经过。`<` 加上从左往右 reduce，等距时保留更小的档——
  // 改成 `<=` 会把所有中点静默翻向上，而 Swift 端若实现方式不同就会和这里分歧。
  expect(estimateBrief(37.5, 0.5).durationSec).toBe(30);
  expect(estimateBrief(105, 0.5).durationSec).toBe(90);
  expect(estimateBrief(270, 0.5).durationSec).toBe(240);
});

test("the register axis pushes cost up too", () => {
  // 上一条只扫了 duration 轴，名字却说「两轴」。这一条把 register 轴补上。
  let previous = -1;
  for (const register of [0, 0.2, 0.4, 0.6, 0.8, 1]) {
    const tokens = estimateBrief(120, register).tokens;
    expect(tokens).toBeGreaterThan(previous);
    previous = tokens;
  }
});

test("the source count rounds rather than truncates", () => {
  // 两个锚点取整前恰好都是整数（11.0 和 21.0），所以 round→floor 这个改动
  // 在它们身上完全隐身。(90, 0.5) 取整前是 14.5，能区分。
  const e = estimateBrief(90, 0.5);
  expect(e.sources).toBe(15);
  expect(e.tokens).toBe(104000);
  expect(e.factSlots).toBe(4);
  expect(e.researchMinutes).toBe(5);
});

test("the coefficients are pinned so a change has to be deliberate", () => {
  expect(ESTIMATE_COEFFICIENTS).toEqual({
    tokensBase: 15000,
    tokensPerSecond: 600,
    tokensPerRegister: 70000,
    sourcesBase: 6,
    sourcesPerMinute: 3,
    sourcesPerRegister: 8,
    secondsPerFactSlot: 25,
    minimumFactSlots: 3,
    minutesBase: 2,
    minutesPerMinute: 1.2,
    minutesPerRegister: 2.5,
  });
});
```

最后一条不是在测逻辑，是在**钉住系数**。这些数字现在是从 mock 里定的，下一个计划要用真实样本回归校准；钉住之后任何调整都会亮一条失败的测试，逼人当面记下"为什么改"。

**做回归标定的人注意**：这条测试会在你第一次改系数时失败，那是设计如此，不是你引入的 bug。把期望值和新系数一起更新即可。

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/estimate.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/domain/estimate.js"`

- [ ] **Step 3: 实现**

`pipeline/src/domain/estimate.ts`：

```ts
/** ② 拨盘纵轴的十档。iOS 侧的拨盘必须用同一组值。 */
export const DURATION_STEPS = [30, 45, 60, 90, 120, 150, 180, 240, 300, 360] as const;

/**
 * 这些系数目前来自 mock 的手调值。
 * **下一个计划要用真实样本的实际消耗把它们回归出来**——spec §10.1 的未决问题之一：
 * 估低了用户会觉得被骗。测试钉住当前值，改动必须是明知故犯。
 */
export const ESTIMATE_COEFFICIENTS = {
  tokensBase: 15000,
  tokensPerSecond: 600,
  tokensPerRegister: 70000,
  sourcesBase: 6,
  sourcesPerMinute: 3,
  sourcesPerRegister: 8,
  secondsPerFactSlot: 25,
  minimumFactSlots: 3,
  minutesBase: 2,
  minutesPerMinute: 1.2,
  minutesPerRegister: 2.5,
} as const;

export interface BriefEstimate {
  durationSec: number;
  /** 0 = 八卦，1 = 专业 */
  register: number;
  sources: number;
  factSlots: number;
  tokens: number;
  researchMinutes: number;
}

/**
 * 落到最近的一档。**等距时保留更小的那一档**（`<` 加上从左往右扫描）——
 * 拨盘拖拽时中点天天经过，这个方向必须是写明的决定，不能是实现的副产品。
 *
 * iOS 侧的拨盘本来只会产出这十个值，所以这里的 snap 是**防御性**的；
 * 档位的权威定义始终是 `DURATION_STEPS` 本身。
 */
function snapDuration(durationSec: number): number {
  return DURATION_STEPS.reduce((best, step) =>
    Math.abs(step - durationSec) < Math.abs(best - durationSec) ? step : best,
    DURATION_STEPS[0]);
}

/**
 * §10.1：花钱之前就把账算给用户看。
 * 纯函数，没有 IO——iOS 侧照抄同一组系数即可得到同样的数字。
 */
export function estimateBrief(durationSec: number, register: number): BriefEstimate {
  const c = ESTIMATE_COEFFICIENTS;
  const sec = snapDuration(durationSec);
  const reg = Math.min(1, Math.max(0, register));

  return {
    durationSec: sec,
    register: reg,
    // register 是连续量（拨盘可以停在任意位置），所以这一项会出小数。
    // token 是计数单位，而且同一个对象里另外三个字段都取整了。
    tokens: Math.round(c.tokensBase + sec * c.tokensPerSecond + reg * c.tokensPerRegister),
    sources: Math.round(c.sourcesBase + (sec / 60) * c.sourcesPerMinute + reg * c.sourcesPerRegister),
    factSlots: Math.max(c.minimumFactSlots, Math.round(sec / c.secondsPerFactSlot)),
    researchMinutes: Math.round(c.minutesBase + (sec / 60) * c.minutesPerMinute + reg * c.minutesPerRegister),
  };
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/estimate.test.ts
```

Expected: `10 passed`

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/domain/estimate.ts pipeline/test/estimate.test.ts
git commit -m "Work out what a brief will cost before spending anything"
```

---

### Task 9: 时长与气口

**Files:**
- Create: `pipeline/src/domain/prosody.ts`
- Test: `pipeline/test/prosody.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/prosody.test.ts`：

```ts
import { expect, test } from "vitest";
import { breathMarks, DEFAULT_CHARS_PER_SECOND, detectLanguage, estimateSeconds } from "../src/domain/prosody.js";

test("language comes from the share of CJK characters", () => {
  expect(detectLanguage("央行今天突然出手了")).toBe("cjk");
  expect(detectLanguage("The central bank moved today")).toBe("latin");
  expect(detectLanguage("央行 announced 降准")).toBe("cjk");
});

test("seconds come from the injected rate, not a guess", () => {
  expect(estimateSeconds("十个字的一句话", 5)).toBeCloseTo(1.4, 5);
  expect(estimateSeconds("十个字的一句话", 10)).toBeCloseTo(0.7, 5);
});

test("punctuation and spaces do not take time to read", () => {
  expect(estimateSeconds("央行，出手。", 5)).toBeCloseTo(estimateSeconds("央行出手", 5), 5);
});

test("spaces do not take time to read either", () => {
  // 上一条用的是中文短句，里面根本没有空格——把正则里的 `\s` 删掉也不会红。
  expect(estimateSeconds("hello world", 5)).toBeCloseTo(estimateSeconds("helloworld", 5), 5);
});

test("with no rate on file, the language default is used", () => {
  // 这两个值必须和 iOS 侧 ScriptLanguage.defaultCharactersPerSecond 一致，
  // 否则 App 告诉用户「83 秒」、提词器却按另一个速度起步。
  expect(DEFAULT_CHARS_PER_SECOND).toEqual({ cjk: 5, latin: 16 });
  expect(estimateSeconds("央行今天突然出手了", DEFAULT_CHARS_PER_SECOND.cjk)).toBeCloseTo(9 / 5, 5);
  expect(estimateSeconds("hello world", DEFAULT_CHARS_PER_SECOND.latin)).toBeCloseTo(10 / 16, 5);
});

test("a sentence-final stop is a long breath, an internal comma a short one", () => {
  // 「，」在 下0 调1 准2 备3 金4 率5 ，6 —— charOffset 是 6
  expect(breathMarks(["央行今天突然出手了。", "下调准备金率，三月生效。"])).toEqual([
    { sentenceIndex: 0, kind: "long" },
    { sentenceIndex: 1, kind: "short", charOffset: 6 },
    { sentenceIndex: 1, kind: "long" },
  ]);
});

test("a sentence with no terminal punctuation still gets a long breath after it", () => {
  expect(breathMarks(["央行今天突然出手了"])).toEqual([{ sentenceIndex: 0, kind: "long" }]);
});
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/prosody.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/domain/prosody.js"`

- [ ] **Step 3: 实现**

`pipeline/src/domain/prosody.ts`：

```ts
export type ScriptLanguage = "cjk" | "latin";

/**
 * 没有该用户历史语速时的回落值（字符/秒）。
 *
 * **注意：真实语速目前根本没有采集**——见 spec §9.2 ①。所以新用户的第一篇稿
 * 必然走这两个数字，产品文案不能上来就说「按你的语速」。
 *
 * 数值和 iOS 侧 `ScriptLanguage.defaultCharactersPerSecond`
 * （`ios/Pollux One/Domain/ScriptLanguage.swift`）保持一致，那边写了推导：
 * 5 字/秒 = 300 字/分，从容的上镜语速；16 字符/秒 ≈ 190 wpm。
 * 两边必须一致——不然 App 告诉用户「83 秒」，提词器却按另一个速度起步。
 */
export const DEFAULT_CHARS_PER_SECOND: Record<ScriptLanguage, number> = {
  cjk: 5,
  latin: 16,
};

// 范围端点写成转义不是洁癖：\u3400 是 CJK 扩展 A 的起点、\u4e00 是基本区、
// \u3040 是平假名、\uac00 是谚文。写成字面量的话那几个生僻字没人认得出，
// 「这个区间到底圈了什么」这个意图就丢了。
const CJK = /[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]/u;

/**
 * CJK 占字母总数的两成就算中文。iOS 侧 `ScriptLanguage.detect` 独立地也用了
 * 两成这个阈值，但**分母口径不同**：那边是全部 unicode scalar（含数字标点），
 * 这边只数字母。金融稿数字密集时两边可能在边界上分道扬镳——真要统一，
 * 该先对齐分母而不是单独调这里的乘数。
 */
export function detectLanguage(text: string): ScriptLanguage {
  let cjk = 0;
  let letters = 0;
  for (const ch of text) {
    if (CJK.test(ch)) cjk += 1;
    else if (/\p{L}/u.test(ch)) letters += 1;
  }
  return cjk > 0 && cjk * 4 >= letters ? "cjk" : "latin";
}

/**
 * 只数会念出声的字符——标点、符号、空白都不占时间，抓取残留的零宽字符
 * 当然也不占（`shingle.ts` 的 `normalize` 同样剥它们；同一份抓来的稿子
 * 会同时喂给两边，不能一边当噪声一边当"要花时间念"）。
 *
 * **已知局限**：数字按字符计会系统性低估播报时长。「0.5」剥完标点剩 2 个
 * 字符，念出来是「零点五」3 个音节；「5%」的 % 被当符号剥掉只剩 1 个字符，
 * 念出来是「百分之五」4 个音节。金融口播恰好是首发场景，数字密度最高——
 * 真要修需要一层中文数字朗读归一（基数/序数、年份逐位读、量词），
 * 超出「确定性字符计数」这个任务的范围，记在这里。
 */
function spokenLength(text: string): number {
  return [...text
    .replace(/[\u200B-\u200D\uFEFF]/gu, "")
    .replace(/[\s\p{P}\p{S}]+/gu, "")].length;
}

export function estimateSeconds(text: string, charsPerSecond: number): number {
  if (charsPerSecond <= 0) throw new Error("charsPerSecond must be positive");
  return spokenLength(text) / charsPerSecond;
}

export type BreathKind = "long" | "short";

/**
 * 判别联合，不是「可选字段 + 注释约定」：short 必须带句内位置，long 必须不带。
 * 写成 `charOffset?: number` 的话，TS 在 `kind === "long"` 分支里不会把它窄化掉，
 * 也拦不住以后有人给 long 塞一个 charOffset。序列化成 JSON 给 Swift 端消费时
 * 形状完全一样。
 */
export type BreathMark =
  | { sentenceIndex: number; kind: "long" }
  | { sentenceIndex: number; kind: "short"; charOffset: number };

const INTERNAL = /[，、；：,;:]/u;

/**
 * ⑨ 气口：句末标点 = 长气口，句中顿号逗号 = 短气口。
 * 比让模型猜准，而且确定性——同一份稿两次跑出来一模一样。
 */
export function breathMarks(sentences: string[]): BreathMark[] {
  const marks: BreathMark[] = [];
  sentences.forEach((sentence, sentenceIndex) => {
    [...sentence].forEach((ch, charOffset) => {
      if (INTERNAL.test(ch)) marks.push({ sentenceIndex, kind: "short", charOffset });
    });
    marks.push({ sentenceIndex, kind: "long" });
  });
  return marks;
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/prosody.test.ts
```

Expected: `7 passed`

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/domain/prosody.ts pipeline/test/prosody.test.ts
git commit -m "Say how long a script takes and where the breaths fall"
```

---

### Task 10: 选点与 insufficient 门槛

**Files:**
- Create: `pipeline/src/draft/select.ts`
- Test: `pipeline/test/select.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/select.test.ts`：

```ts
import { expect, test } from "vitest";
import type { Confidence, VerifiedClaim } from "../src/domain/types.js";
import { selectClaims } from "../src/draft/select.js";

function claim(id: string, confidence: Confidence, independence: number): VerifiedClaim {
  return { id, text: id, factIds: [], independence, confidence, conflictsWith: [] };
}

test("strong claims are picked first, most-corroborated first", () => {
  const claims = [
    claim("c0", "strong", 3),
    claim("c1", "strong", 5),
    claim("c2", "strong", 4),
  ];
  const out = selectClaims(claims, 3);
  expect(out.verdict).toBe("ok");
  expect(out.picked).toEqual(["c1", "c2", "c0"]);
});

test("weak claims fill the remaining slots once three strong are in", () => {
  // 三条 strong 故意打乱着传进来。排序是稳定的，所以去掉 id 那半个 tie-break
  // 会原样吐回 c2,c0,c1——这一条就是用来钉住它的。
  const claims = [
    claim("c2", "strong", 3), claim("c0", "strong", 3), claim("c1", "strong", 3),
    claim("c3", "weak", 2), claim("c4", "weak", 1),
  ];
  const out = selectClaims(claims, 5);
  expect(out.picked).toEqual(["c0", "c1", "c2", "c3", "c4"]);
});

test("fewer than three strong claims means no script at all", () => {
  const claims = [
    claim("c0", "strong", 3), claim("c1", "strong", 3),
    claim("c2", "weak", 1), claim("c3", "weak", 1), claim("c4", "weak", 1),
  ];
  const out = selectClaims(claims, 5);
  expect(out.verdict).toBe("insufficient");
  expect(out.picked).toEqual([]);
  expect(out.strongFound).toBe(2);
  expect(out.reason).toBe("only 2 strong claims, need 3");
});

test("a refusal still reports what was in conflict", () => {
  // 「不建议播」那一屏既要说明为什么没出稿，也要把冲突摆出来。
  // 没有这一条的话，把 insufficient 分支里的 conflicted 硬写成 [] 六个测试全过。
  const claims = [
    claim("c0", "strong", 3),
    { ...claim("c1", "conflicted", 4), conflictsWith: ["c2"] },
    { ...claim("c2", "conflicted", 4), conflictsWith: ["c1"] },
  ];
  const out = selectClaims(claims, 5);
  expect(out.verdict).toBe("insufficient");
  expect(out.conflicted).toEqual(["c1", "c2"]);
});

test("a nonsensical slot count is a caller error, not an empty script", () => {
  // slice(0, -1) 返回的是「除最后一个之外的全部」，所以负数名额会**多**出稿，
  // 不是不出稿。名额来自 estimateBrief（保证 ≥ 3），走到这里就是调用方错了。
  const claims = [claim("c0", "strong", 3), claim("c1", "strong", 3), claim("c2", "strong", 3)];
  expect(() => selectClaims(claims, -1)).toThrow(/factSlots/);
  expect(() => selectClaims(claims, 2.5)).toThrow(/factSlots/);
});

test("a long duration does not lower the bar", () => {
  const claims = [claim("c0", "strong", 3), claim("c1", "strong", 3)];
  expect(selectClaims(claims, 14).verdict).toBe("insufficient");
});

test("conflicted claims never enter the script but are reported", () => {
  const claims = [
    claim("c0", "strong", 3), claim("c1", "strong", 3), claim("c2", "strong", 3),
    { ...claim("c3", "conflicted", 4), conflictsWith: ["c4"] },
    { ...claim("c4", "conflicted", 4), conflictsWith: ["c3"] },
  ];
  const out = selectClaims(claims, 5);
  expect(out.verdict).toBe("ok");
  expect(out.picked).toEqual(["c0", "c1", "c2"]);
  expect(out.conflicted).toEqual(["c3", "c4"]);
});

test("never picks more than the slots allow", () => {
  const claims = [
    claim("c0", "strong", 3), claim("c1", "strong", 3),
    claim("c2", "strong", 3), claim("c3", "strong", 3),
  ];
  expect(selectClaims(claims, 3).picked).toHaveLength(3);
});
```

第四条是 spec §5.1 那条补充的直接翻译：**拨到 6 分钟专业也要至少 3 条 strong 打底——时长是用户的期望，不是伪造事实的理由。**

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/select.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/draft/select.js"`

- [ ] **Step 3: 实现**

`pipeline/src/draft/select.ts`：

```ts
import type { ClaimId, VerifiedClaim } from "../domain/types.js";

/**
 * 一篇稿至少要有这么多条 strong 打底，无论拨到多长。spec §5.1。
 *
 * 和 `classify.ts` 的 `STRONG_INDEPENDENCE` 数值相同但**是两回事**，别去合并：
 * 那个是「几个独立源才让一条 claim 算 strong」，这个是「一篇稿要几条 strong」。
 */
export const MINIMUM_STRONG_CLAIMS = 3;

export interface Selection {
  verdict: "ok" | "insufficient";
  /** 进稿的 Claim，已按呈现顺序排好 */
  picked: ClaimId[];
  /** 检出冲突、因此不进稿的 Claim——⑥ 不建议播那一屏要列出来 */
  conflicted: ClaimId[];
  /** insufficient 时实际有几条 strong。UI 要用中文说「还差 N 条」，
   *  不能去正则解析下面那句英文。 */
  strongFound?: number;
  /** 给日志和测试看的英文。用户看到的文案由 UI 拿 strongFound 和
   *  MINIMUM_STRONG_CLAIMS 自己拼。 */
  reason?: string;
}

/**
 * ⑥ 的确定性一半：谁**有资格**进稿、够不够出稿。
 * 至于进稿的这几条怎么排、钩子怎么下，那是编辑判断，交给模型（下一个计划）。
 */
export function selectClaims(claims: VerifiedClaim[], factSlots: number): Selection {
  // `slice(0, -1)` 返回的是「除最后一个之外的全部」，不是空数组——名额传成负数
  // 会产出一篇**比该有的更满**的稿子，正是这一阶段要防的方向。
  // 名额来自 estimateBrief，那边保证 ≥ 3；走到这里说明调用方传错了。
  if (!Number.isInteger(factSlots) || factSlots < 0) {
    throw new Error(`factSlots must be a non-negative integer, got ${factSlots}`);
  }

  const conflicted = claims.filter((c) => c.confidence === "conflicted").map((c) => c.id);

  // numeric 排序：默认的 localeCompare 把 "c10" 排在 "c9" 前面，而 6 分钟有
  // 14 个名额，claim 过十条是现实的。同分时谁进稿由这一行决定，不只是显示顺序。
  const byCorroboration = (a: VerifiedClaim, b: VerifiedClaim) =>
    b.independence - a.independence || a.id.localeCompare(b.id, undefined, { numeric: true });

  const strong = claims.filter((c) => c.confidence === "strong").sort(byCorroboration);
  const weak = claims.filter((c) => c.confidence === "weak").sort(byCorroboration);

  if (strong.length < MINIMUM_STRONG_CLAIMS) {
    return {
      verdict: "insufficient",
      picked: [],
      conflicted,
      strongFound: strong.length,
      reason: `only ${strong.length} strong claims, need ${MINIMUM_STRONG_CLAIMS}`,
    };
  }

  const picked = [...strong, ...weak].slice(0, factSlots).map((c) => c.id);
  return { verdict: "ok", picked, conflicted };
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/select.test.ts
```

Expected: `8 passed`

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/draft/select.ts pipeline/test/select.test.ts
git commit -m "Pick which claims earn a place in eighty seconds"
```

---

### Task 11: 逐句挂信源

这是 §3 那句话的落地处：**信源是程序绑上去的，不是模型自称的。**

**Files:**
- Create: `pipeline/src/draft/bind.ts`
- Test: `pipeline/test/bind.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/bind.test.ts`：

```ts
import { expect, test } from "vitest";
import type { DraftSentence } from "../src/domain/types.js";
import { bindEvidence, sentenceFingerprint, type BindResult } from "../src/draft/bind.js";

const VERIFIED = ["c0", "c1"];

/** 窄化到成功分支，失败时给出看得懂的报错。 */
function ok(result: BindResult) {
  if (!result.ok) throw new Error(`expected a clean bind, got ${JSON.stringify(result.problems)}`);
  return result;
}

test("a fact sentence gets its claims bound and a fingerprint", () => {
  const draft: DraftSentence[] = [
    { text: "此次降准释放长期资金约 1 万亿元。", kind: "fact", claimIds: ["c0"] },
  ];
  const out = ok(bindEvidence(draft, VERIFIED));
  expect(out.evidence).toEqual([
    {
      sentenceIndex: 0,
      claimIds: ["c0"],
      sentenceFingerprint: sentenceFingerprint("此次降准释放长期资金约 1 万亿元。"),
    },
  ]);
});

test("a fact sentence with no claims is rejected — the model made it up", () => {
  const draft: DraftSentence[] = [
    { text: "业内普遍认为这是重大利好。", kind: "fact", claimIds: [] },
  ];
  // 整体比对：失败时连 evidence 和 sentences 都不该有
  expect(bindEvidence(draft, VERIFIED)).toEqual({
    ok: false,
    problems: [{ kind: "fact-without-claim", sentenceIndex: 0 }],
  });
});

test("a claim that never passed verification is rejected", () => {
  const draft: DraftSentence[] = [
    { text: "此次降准释放长期资金约 1 万亿元。", kind: "fact", claimIds: ["c9"] },
  ];
  expect(bindEvidence(draft, VERIFIED)).toEqual({
    ok: false,
    problems: [{ kind: "unknown-claim", sentenceIndex: 0, claimId: "c9" }],
  });
});

test("an opinion sentence carrying claims has them stripped, not rejected", () => {
  const draft: DraftSentence[] = [
    { text: "我的判断是这一轮宽松还没到头。", kind: "opinion", claimIds: ["c0"] },
  ];
  const out = ok(bindEvidence(draft, VERIFIED));
  expect(out.sentences[0]!.claimIds).toEqual([]);
  expect(out.evidence).toEqual([]);
});

test("a transition sentence has its claims stripped too", () => {
  // 原来这条的 claimIds 本来就是空的，等于没验证「剥离」这件事——
  // 把剥离的条件从 `kind !== "fact"` 缩成 `kind === "opinion"` 也不会红。
  const draft: DraftSentence[] = [
    { text: "央行今天突然出手了。", kind: "transition", claimIds: ["c0"] },
  ];
  const out = ok(bindEvidence(draft, VERIFIED));
  expect(out.sentences[0]!.claimIds).toEqual([]);
  expect(out.evidence).toEqual([]);
});

test("every problem in a draft is reported, not just the first", () => {
  const draft: DraftSentence[] = [
    { text: "一。", kind: "fact", claimIds: [] },
    { text: "二。", kind: "fact", claimIds: ["c9"] },
  ];
  const out = bindEvidence(draft, VERIFIED);
  expect(out.ok).toBe(false);
  if (!out.ok) expect(out.problems).toHaveLength(2);
});

test("the fingerprint changes when the wording changes", () => {
  const before = sentenceFingerprint("涉及金额约 23 亿美元。");
  const after = sentenceFingerprint("涉及金额约 31 亿美元。");
  expect(before).not.toBe(after);
});

test("the fingerprint ignores punctuation, so a comma edit keeps the sources", () => {
  expect(sentenceFingerprint("降准，三月生效。")).toBe(sentenceFingerprint("降准三月生效"));
});

test("the fingerprint is sixteen hex characters", () => {
  // 没这一条，把 slice(0, 16) 改成 slice(0, 8) 不会有任何测试变红。
  expect(sentenceFingerprint("降准三月生效")).toMatch(/^[0-9a-f]{16}$/);
});
```

最后两条是 spec §9.2 ③ 的要求：Safe Word 当场改稿之后，**改了数字就必须掉信源，只动标点不该掉。**

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/bind.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/draft/bind.js"`

- [ ] **Step 3: 实现**

`pipeline/src/draft/bind.ts`：

```ts
import { createHash } from "node:crypto";
import { normalize } from "../dedupe/shingle.js";
import type { ClaimId, DraftSentence } from "../domain/types.js";

/** 判别联合：`fact-without-claim` 永远没有 claimId，`unknown-claim` 永远有。 */
export type BindProblem =
  | { kind: "fact-without-claim"; sentenceIndex: number }
  | { kind: "unknown-claim"; sentenceIndex: number; claimId: ClaimId };

export interface EvidenceRow {
  /**
   * **这是快照序号，不是稳定外键。** 它只在传进来的那个 draft 数组里有效。
   * spec §8.1 的审稿页允许逐句删除，删掉一句之后其后每一行的下标都会挪位——
   * 指纹防的是 Safe Word 当场改写，**不防删除**（spec §9.2 ③ 自己也把
   * 「审稿时删句要清理孤儿 evidence」单列成一条）。下一个计划落库时必须给
   * 句子一个稳定 id，别把这个字段当外键用。
   */
  sentenceIndex: number;
  claimIds: ClaimId[];
  sentenceFingerprint: string;
}

/**
 * 失败时**不返回** evidence 和 sentences——不是省事，是让「忘了检查 ok 就去用
 * evidence」在类型上不可能发生。那正好是这个函数存在的理由的反面：把没通过
 * 校验的绑定挂到句子上。
 */
export type BindResult =
  | { ok: true; evidence: EvidenceRow[]; sentences: DraftSentence[] }
  | { ok: false; problems: BindProblem[] };

/**
 * 句子的内容指纹。标点和空白不计入——录制中 Safe Word 只改个逗号不该让信源掉，
 * 改了数字就必须掉。spec §9.2 ③。
 *
 * 只取 16 个十六进制字符（64 位）是够的：这不是一个要和几百万条比对的内容
 * 索引，而是「这一行的当前文本还等于记录时的那份吗」这样一次成对比较。
 * 别看见截断就去改成整串。
 */
export function sentenceFingerprint(text: string): string {
  return createHash("sha256").update(normalize(text)).digest("hex").slice(0, 16);
}

/**
 * ⑧ 挂信源：**纯查表 + 校验，没有模型参与**。
 *
 * 这就是「每一句都可溯源」这句话敢写出来的全部理由：绑定是算出来的。
 * 一旦这一步改成"让模型判断"，那句宣传就变成虚假宣传。
 */
export function bindEvidence(draft: DraftSentence[], verifiedClaimIds: ClaimId[]): BindResult {
  const verified = new Set(verifiedClaimIds);
  const problems: BindProblem[] = [];
  const evidence: EvidenceRow[] = [];
  const sentences: DraftSentence[] = [];

  draft.forEach((sentence, sentenceIndex) => {
    if (sentence.kind !== "fact") {
      // 观点不该伪装成有据可依
      sentences.push({ ...sentence, claimIds: [] });
      return;
    }

    if (sentence.claimIds.length === 0) {
      problems.push({ kind: "fact-without-claim", sentenceIndex });
      sentences.push(sentence);
      return;
    }

    const unknown = sentence.claimIds.filter((id) => !verified.has(id));
    for (const claimId of unknown) {
      problems.push({ kind: "unknown-claim", sentenceIndex, claimId });
    }
    sentences.push(sentence);
    if (unknown.length === 0) {
      evidence.push({
        sentenceIndex,
        claimIds: sentence.claimIds,
        sentenceFingerprint: sentenceFingerprint(sentence.text),
      });
    }
  });

  // 一条问题都没有才算绑成了。半好半坏的绑定不发出去——模型既然已经证明
  // 它分不清哪些 claim 通过了验证，这一句里"对的那一半"也不值得信。
  if (problems.length > 0) return { ok: false, problems };
  return { ok: true, evidence, sentences };
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/bind.test.ts
```

Expected: `9 passed`

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/draft/bind.ts pipeline/test/bind.test.ts
git commit -m "Bind sources to sentences by lookup, never by the model's word"
```

---

### Task 12: 组合内核

**Files:**
- Create: `pipeline/src/core.ts`
- Test: `pipeline/test/core.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/core.test.ts`：

```ts
import { expect, test } from "vitest";
import { buildBrief } from "../src/core.js";
import type { CoreInput } from "../src/core.js";
import type { Fact, Source } from "../src/domain/types.js";

const WIRE = "央行今日宣布下调金融机构存款准备金率零点五个百分点，此次降准将释放长期资金约一万亿元，自三月十五日起生效。";

function input(): CoreInput {
  return {
    durationSec: 60,
    register: 0.25,
    charsPerSecond: 5.5,
    sources: [
      { id: "s0", url: "https://pbc.example/a", publisher: "pbc", publishedAt: "2026-03-01T07:00:00Z", body: WIRE, creditedTo: null },
      { id: "s1", url: "https://portal.example/a", publisher: "portal", publishedAt: "2026-03-01T07:20:00Z", body: `【转载】${WIRE}`, creditedTo: null },
      { id: "s2", url: "https://reuters.example/a", publisher: "reuters", publishedAt: "2026-03-01T08:00:00Z", body: "Reuters 独立测算显示，此次操作对应释放的长期资金规模在一万亿元左右，生效日期为三月十五日。", creditedTo: null },
      { id: "s3", url: "https://caixin.example/a", publisher: "caixin", publishedAt: "2026-03-01T09:00:00Z", body: "财新记者从多家银行了解到，此次降准释放长期资金约 1 万亿元，三月十五日起生效，信贷投放节奏将前移。", creditedTo: null },
    ],
    facts: [
      { id: "f0", sourceId: "s0", text: "此次降准释放长期资金约 1 万亿元", quote: WIRE },
      { id: "f1", sourceId: "s1", text: "此次降准将释放长期资金约 1 万亿元", quote: WIRE },
      { id: "f2", sourceId: "s2", text: "此次降准释放长期资金约 1 万亿元", quote: "…一万亿元左右…" },
      { id: "f3", sourceId: "s3", text: "此次降准释放长期资金约 1 万亿元", quote: "…约 1 万亿元…" },
    ],
    draft: [
      { text: "央行今天突然出手了。", kind: "transition", claimIds: [] },
      { text: "此次降准释放长期资金约 1 万亿元。", kind: "fact", claimIds: ["c0"] },
      { text: "我的判断是这一轮宽松还没到头。", kind: "opinion", claimIds: [] },
    ],
  };
}

test("the four sources collapse to three groups and the claim is strong", () => {
  const out = buildBrief(input());
  expect(out.claims).toHaveLength(1);
  expect(out.claims[0]!.independence).toBe(3);
  expect(out.claims[0]!.confidence).toBe("strong");
});

test("one strong claim is not enough to produce a script", () => {
  const out = buildBrief(input());
  expect(out.selection.verdict).toBe("insufficient");
  expect(out.selection.reason).toBe("only 1 strong claims, need 3");
});

test("the estimate travels with the result", () => {
  const out = buildBrief(input());
  expect(out.estimate.durationSec).toBe(60);
  expect(out.estimate.factSlots).toBe(3);
});

test("binding and prosody still run so problems surface even when insufficient", () => {
  const out = buildBrief(input());
  expect(out.bind.ok).toBe(true);
  expect(out.seconds).toBeGreaterThan(0);
  expect(out.breaths.length).toBeGreaterThan(0);
});

/**
 * 四条 strong + 一对互相冲突的 claim。上面那个 fixture 永远停在 insufficient，
 * 于是「名额切片」和「排除 conflicted」这两段接缝一次都没被执行过——
 * 把 estimate.factSlots 换成 estimate.sources、或者删掉 conflicted 过滤，
 * 五个测试全绿。这个 fixture 专门用来走到 ok 分支。
 */
function sufficient(): CoreInput {
  const bodies = [
    "中国人民银行决定于三月十五日下调金融机构存款准备金率零点五个百分点。",
    "Reuters 独立测算显示，此次操作对应释放的长期资金规模在一万亿元左右。",
    "财新记者从多家银行了解到，降准落地后信贷投放节奏将有所前移。",
    "彭博社获得的数据显示，本轮操作对应的资金规模约 31 亿美元等值。",
  ];
  const sources: Source[] = bodies.map((body, i) => ({
    id: `s${i}`, url: `https://x${i}.example/a`, publisher: `p${i}`,
    publishedAt: "2026-03-01T07:00:00Z", body, creditedTo: null,
  }));
  const texts = [
    "此次降准释放长期资金约 1 万亿元",
    "存款准备金率下调 0.5 个百分点",
    "新政自 3 月 15 日起生效",
    "信贷投放节奏将有所前移",
  ];
  const facts: Fact[] = texts.flatMap((text, t) =>
    [0, 1, 2].map((s) => ({ id: `f${t}${s}`, sourceId: `s${s}`, text, quote: text })));
  facts.push({ id: "fx", sourceId: "s2", text: "涉及资金规模约 23 亿美元", quote: "x" });
  facts.push({ id: "fy", sourceId: "s3", text: "涉及资金规模约 31 亿美元", quote: "y" });
  return { durationSec: 60, register: 0.25, charsPerSecond: 5.5, sources, facts, draft: [] };
}

test("the slot budget actually limits what gets picked", () => {
  const out = buildBrief(sufficient());
  expect(out.selection.verdict).toBe("ok");
  // 四条 strong，名额只有三个。传成 estimate.sources（11）的话这里会是 4。
  expect(out.estimate.factSlots).toBe(3);
  expect(out.selection.picked).toHaveLength(3);
});

test("a sentence citing a conflicted claim does not bind", () => {
  // 删掉 `confidence !== "conflicted"` 那个过滤，这一条会变绿——上面的 fixture
  // 一条冲突 claim 都没有，所以那个过滤在别处全是空转。
  const conflicted = buildBrief(sufficient()).claims.find((c) => c.confidence === "conflicted");
  expect(conflicted).toBeDefined();

  const brief = sufficient();
  brief.draft = [{ text: "涉及资金规模约 23 亿美元。", kind: "fact", claimIds: [conflicted!.id] }];
  expect(buildBrief(brief).bind).toEqual({
    ok: false,
    problems: [{ kind: "unknown-claim", sentenceIndex: 0, claimId: conflicted!.id }],
  });
});

test("a fabricated fact sentence is caught", () => {
  const withLie = input();
  withLie.draft.push({ text: "这是年内第三次降准。", kind: "fact", claimIds: [] });
  expect(buildBrief(withLie).bind).toEqual({
    ok: false,
    problems: [{ kind: "fact-without-claim", sentenceIndex: 3 }],
  });
});
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/core.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/core.js"`

- [ ] **Step 3: 实现**

`pipeline/src/core.ts`：

```ts
import { classifyClaims } from "./dedupe/classify.js";
import { mergeFacts } from "./dedupe/merge.js";
import { estimateBrief, type BriefEstimate } from "./domain/estimate.js";
import { breathMarks, estimateSeconds, type BreathMark } from "./domain/prosody.js";
import type { DraftSentence, Fact, Source, VerifiedClaim } from "./domain/types.js";
import { bindEvidence, type BindResult } from "./draft/bind.js";
import { selectClaims, type Selection } from "./draft/select.js";

export interface CoreInput {
  durationSec: number;
  register: number;
  /** 该用户的实测语速；没有就传语种默认值。见 spec §9.2 ①。 */
  charsPerSecond: number;
  sources: Source[];
  facts: Fact[];
  /** ⑦ 成稿的输出。本计划不产生它，由 fixture 提供。 */
  draft: DraftSentence[];
  mediaGroups?: Record<string, string>;
}

export interface CoreResult {
  estimate: BriefEstimate;
  claims: VerifiedClaim[];
  selection: Selection;
  bind: BindResult;
  seconds: number;
  breaths: BreathMark[];
}

/**
 * ④⑤⑥⑧⑨ 串起来——**全程没有一次模型调用，也没有一次网络请求**。
 * 这正是 spec §11 那句「管线最关键的逻辑全部可以离线测试」的兑现。
 */
export function buildBrief(input: CoreInput): CoreResult {
  const estimate = estimateBrief(input.durationSec, input.register);

  const merged = mergeFacts(input.facts);
  const claims = classifyClaims(merged, input.facts, input.sources, input.mediaGroups);
  const selection = selectClaims(claims, estimate.factSlots);

  // 即便 insufficient 也照样跑绑定与时长：问题要浮出来，不能被一个 verdict 盖掉。
  //
  // 这里喂给 bind 的是**全部通过验证的** claim，不是 selection.picked——两个阶段
  // 管的事不同：selection 决定「在这个长度里谁配进稿」，bind 决定「这条引用是不是
  // 真的」。若改用 picked，insufficient 时 picked 是空的，于是每一句事实句都会报
  // unknown-claim，把「模型编了一句」这个唯一该浮出来的信号淹掉。
  const verifiedIds = claims.filter((c) => c.confidence !== "conflicted").map((c) => c.id);
  const bind = bindEvidence(input.draft, verifiedIds);

  const texts = input.draft.map((s) => s.text);
  return {
    estimate,
    claims,
    selection,
    bind,
    seconds: texts.reduce((total, t) => total + estimateSeconds(t, input.charsPerSecond), 0),
    breaths: breathMarks(texts),
  };
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/core.test.ts
```

Expected: `7 passed`

- [ ] **Step 5: 提交**

```bash
git add pipeline/src/core.ts pipeline/test/core.test.ts
git commit -m "Run the deterministic stages end to end"
```

---

### Task 13: 命令行入口

**Files:**
- Create: `pipeline/src/cli.ts`
- Create: `pipeline/test/fixtures/reserve-cut.json`
- Test: `pipeline/test/cli.test.ts`

- [ ] **Step 1: 写 fixture**

`pipeline/test/fixtures/reserve-cut.json` —— 降准那条，三个独立源、一篇转载、一条数字冲突：

```json
{
  "durationSec": 60,
  "register": 0.25,
  "charsPerSecond": 5.5,
  "sources": [
    { "id": "s0", "url": "https://pbc.example/a", "publisher": "pbc", "publishedAt": "2026-03-01T07:00:00Z", "body": "央行今日宣布下调金融机构存款准备金率零点五个百分点，此次降准将释放长期资金约一万亿元，自三月十五日起生效。", "creditedTo": null },
    { "id": "s1", "url": "https://portal.example/a", "publisher": "portal", "publishedAt": "2026-03-01T07:20:00Z", "body": "【转载】央行今日宣布下调金融机构存款准备金率零点五个百分点，此次降准将释放长期资金约一万亿元，自三月十五日起生效。", "creditedTo": null },
    { "id": "s2", "url": "https://reuters.example/a", "publisher": "reuters", "publishedAt": "2026-03-01T08:00:00Z", "body": "Reuters 独立测算显示，此次操作对应释放的长期资金规模在一万亿元左右，生效日期为三月十五日，涉及资金规模约 23 亿美元等值。", "creditedTo": null },
    { "id": "s3", "url": "https://caixin.example/a", "publisher": "caixin", "publishedAt": "2026-03-01T09:00:00Z", "body": "财新记者从多家银行了解到，此次降准释放长期资金约 1 万亿元，三月十五日起生效，信贷投放节奏将前移。", "creditedTo": null },
    { "id": "s4", "url": "https://bbg.example/a", "publisher": "bloomberg", "publishedAt": "2026-03-01T09:30:00Z", "body": "彭博社获得的数据显示，本轮操作对应的资金规模约 31 亿美元等值，与其他机构测算存在差异。", "creditedTo": null }
  ],
  "facts": [
    { "id": "f0", "sourceId": "s0", "text": "此次降准释放长期资金约 1 万亿元", "quote": "此次降准将释放长期资金约一万亿元" },
    { "id": "f1", "sourceId": "s1", "text": "此次降准将释放长期资金约 1 万亿元", "quote": "此次降准将释放长期资金约一万亿元" },
    { "id": "f2", "sourceId": "s2", "text": "此次降准释放长期资金约 1 万亿元", "quote": "长期资金规模在一万亿元左右" },
    { "id": "f3", "sourceId": "s3", "text": "此次降准释放长期资金约 1 万亿元", "quote": "释放长期资金约 1 万亿元" },
    { "id": "f4", "sourceId": "s0", "text": "存款准备金率下调 0.5 个百分点", "quote": "下调金融机构存款准备金率零点五个百分点" },
    { "id": "f5", "sourceId": "s2", "text": "存款准备金率下调 0.5 个百分点", "quote": "下调零点五个百分点" },
    { "id": "f6", "sourceId": "s3", "text": "存款准备金率下调 0.5 个百分点", "quote": "降准零点五个百分点" },
    { "id": "f7", "sourceId": "s0", "text": "新政自 3 月 15 日起生效", "quote": "自三月十五日起生效" },
    { "id": "f8", "sourceId": "s2", "text": "新政自 3 月 15 日起生效", "quote": "生效日期为三月十五日" },
    { "id": "f9", "sourceId": "s3", "text": "新政自 3 月 15 日起生效", "quote": "三月十五日起生效" },
    { "id": "f10", "sourceId": "s2", "text": "涉及资金规模约 23 亿美元", "quote": "涉及资金规模约 23 亿美元等值" },
    { "id": "f11", "sourceId": "s4", "text": "涉及资金规模约 31 亿美元", "quote": "资金规模约 31 亿美元等值" }
  ],
  "draft": [
    { "text": "央行今天突然出手了。", "kind": "transition", "claimIds": [] },
    { "text": "存款准备金率下调 0.5 个百分点，3 月 15 日正式生效。", "kind": "fact", "claimIds": ["c1", "c2"] },
    { "text": "这次将释放长期资金约 1 万亿元。", "kind": "fact", "claimIds": ["c0"] },
    { "text": "我的判断是，这一轮宽松还没到头。", "kind": "opinion", "claimIds": [] }
  ]
}
```

- [ ] **Step 2: 写失败的测试**

`pipeline/test/cli.test.ts`：

```ts
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { main } from "../src/cli.js";

const FIXTURE = "test/fixtures/reserve-cut.json";

/**
 * 直接调 main 并截获输出。原来每条测试都 spawn 一个 `npx tsx` 子进程，
 * 一次约 330ms，而且把真实异常和 stderr 都吃掉了——失败原因是「fixture 坏了」
 * 还是「npx 不在」看起来一模一样。
 *
 * 另：fixture 的 draft 里写死了 c0/c1/c2。这些 id 是 `mergeFacts` 按 fact
 * 出现顺序发的**位置句柄**，不是稳定键——调换 facts 数组的顺序，draft 会
 * 悄悄指向另外几条 claim，而这里没有任何测试会发现。
 */
function run(...args: string[]): { code: number; out: string; err: string } {
  const out: string[] = [];
  const err: string[] = [];
  const realOut = process.stdout.write.bind(process.stdout);
  const realErr = process.stderr.write.bind(process.stderr);
  process.stdout.write = ((c: unknown) => { out.push(String(c)); return true; }) as typeof process.stdout.write;
  process.stderr.write = ((c: unknown) => { err.push(String(c)); return true; }) as typeof process.stderr.write;
  try {
    return { code: main(["node", "cli", ...args]), out: out.join(""), err: err.join("") };
  } finally {
    process.stdout.write = realOut;
    process.stderr.write = realErr;
  }
}

/** 拿真 fixture 改坏一个字段，写到临时文件。 */
function malformed(patch: Record<string, unknown>): string {
  const base = JSON.parse(readFileSync(FIXTURE, "utf8")) as Record<string, unknown>;
  const path = join(mkdtempSync(join(tmpdir(), "pollux-cli-")), "bad.json");
  writeFileSync(path, JSON.stringify({ ...base, ...patch }));
  return path;
}

test("the reserve-cut fixture produces a script and exits zero", () => {
  const { code, out } = run(FIXTURE);
  expect(code).toBe(0);

  const result = JSON.parse(out);
  expect(result.selection.verdict).toBe("ok");
  expect(result.bind.ok).toBe(true);
});

test("the repost does not get counted as an independent source", () => {
  const result = JSON.parse(run(FIXTURE).out);
  const trillion = result.claims.find((c: { text: string }) => c.text.includes("1 万亿"));
  expect(trillion.independence).toBe(3);
  expect(trillion.confidence).toBe("strong");
});

test("the Reuters/Bloomberg figures come out conflicted and stay out of the script", () => {
  const result = JSON.parse(run(FIXTURE).out);
  expect(result.selection.conflicted).toHaveLength(2);
  for (const id of result.selection.conflicted) {
    expect(result.selection.picked).not.toContain(id);
  }
});

test("a missing fixture path exits two", () => {
  // 原来是 not.toBe(0)，那样连「npx 自己没装」都算通过。
  expect(run("test/fixtures/does-not-exist.json").code).toBe(2);
});

test("a duration that is not a number is refused, not quietly treated as 30 seconds", () => {
  // snapDuration 用 `<` 比较，NaN < NaN 恒假，reduce 从不更新，
  // 于是静默落回第一档 30 秒——实测过，一个看起来很合理的错答案。
  const { code, err } = run(malformed({ durationSec: "六十" }));
  expect(code).toBe(2);
  expect(err).toMatch(/durationSec/);
});

test("a fact citing a source that is not in the file is refused", () => {
  const base = JSON.parse(readFileSync(FIXTURE, "utf8")) as { facts: Record<string, unknown>[] };
  const facts = base.facts.map((f, i) => (i === 0 ? { ...f, sourceId: "s99" } : f));
  const { code, err } = run(malformed({ facts }));
  expect(code).toBe(2);
  expect(err).toMatch(/s99/);
});

test("npm run brief really works end to end", () => {
  // 只保留这一条子进程测试：它验的是 `tsx src/cli.ts <path>` 这条真实调用
  // 能跑通，直接调 main 验不到。一条就够，不需要四条都付这个代价。
  const out = execFileSync("npx", ["tsx", "src/cli.ts", FIXTURE], { encoding: "utf8" });
  expect(JSON.parse(out).selection.verdict).toBe("ok");
});
```

- [ ] **Step 3: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/cli.test.ts
```

Expected: FAIL —— `src/cli.ts` 不存在，四条全部失败

- [ ] **Step 4: 实现**

`pipeline/src/cli.ts`：

```ts
import { readFileSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { buildBrief, type CoreInput } from "./core.js";

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
    process.stderr.write("usage: brief <fixture.json>\n");
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

// 只有被当作脚本直接跑时才退出进程；被 import（测试）时什么都不做。
// realpathSync 是必须的：macOS 上 /tmp 是 /private/tmp 的符号链接，
// 不解开的话 argv[1] 和 import.meta.url 对不上，守卫会恒假。
const entry = process.argv[1];
if (entry !== undefined && import.meta.url === pathToFileURL(realpathSync(entry)).href) {
  process.exit(main(process.argv));
}
```

- [ ] **Step 5: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/cli.test.ts
```

Expected: `7 passed`

- [ ] **Step 6: 手动看一眼输出**

```bash
cd pipeline && npm run brief -- test/fixtures/reserve-cut.json
```

Expected: JSON 里 `verdict: "ok"`、「1 万亿」那条 `independence: 3`、`selection.conflicted` 有两条

- [ ] **Step 7: 全量测试**

```bash
cd pipeline && npm test && npm run typecheck
```

Expected: 全部通过，typecheck 无输出

- [ ] **Step 8: 提交**

```bash
git add pipeline/src/cli.ts pipeline/test/cli.test.ts pipeline/test/fixtures/reserve-cut.json
git commit -m "Feed one news story through the core from the command line"
```

---

### Task 14: 数据库迁移

**Files:**
- Create: `backend/supabase/migrations/0002_briefs.sql`

- [ ] **Step 1: 写迁移**

`backend/supabase/migrations/0002_briefs.sql`：

```sql
-- ---------------------------------------------------------------------------
-- Brief（一次「新闻 → 口播稿」任务）及其证据层
-- 设计见 docs/superpowers/specs/2026-09-17-news-brief-pipeline-design.md §9
-- ---------------------------------------------------------------------------

create table briefs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- 只有两类：文本、图。链接是文本的子情况，由管线自己判断（§9 决策）
  input_kind text not null check (input_kind in ('text', 'image')),
  input_payload text not null,
  -- 口述路径带的「我想怎么播」，链接/截图路径为 null（§2.3）
  angle text,
  duration_sec integer not null,
  -- 0.0 八卦 – 1.0 专业
  register real not null check (register >= 0 and register <= 1),
  status text not null default 'queued'
    check (status in ('queued', 'running', 'drafted', 'confirmed', 'insufficient', 'failed', 'canceled')),
  verdict text,
  tokens_budget integer not null,
  tokens_used integer not null default 0,
  cost_cents integer not null default 0,
  script_id uuid references scripts (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table briefs enable row level security;

create policy "briefs are owner-scoped" on briefs
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 阶段状态机（§4.2）。每阶段结果落库，所以可观测、可重跑、可分别记 token。
create table brief_stages (
  id uuid primary key default gen_random_uuid(),
  brief_id uuid not null references briefs (id) on delete cascade,
  stage text not null,
  status text not null default 'pending'
    check (status in ('pending', 'running', 'done', 'failed')),
  tokens_used integer not null default 0,
  result jsonb,
  error text,
  started_at timestamptz,
  ended_at timestamptz,
  unique (brief_id, stage)
);

alter table brief_stages enable row level security;

create policy "brief_stages follow their brief" on brief_stages
  for all using (
    exists (select 1 from briefs b where b.id = brief_stages.brief_id and b.user_id = auth.uid())
  );

create table brief_sources (
  id uuid primary key default gen_random_uuid(),
  brief_id uuid not null references briefs (id) on delete cascade,
  url text not null,
  publisher text not null,
  published_at timestamptz,
  body text not null,
  -- 存下来只为审计和排查；分组时由管线从 body 现算，不依赖这一列
  fingerprint text,
  credited_to text
);

alter table brief_sources enable row level security;

create policy "brief_sources follow their brief" on brief_sources
  for all using (
    exists (select 1 from briefs b where b.id = brief_sources.brief_id and b.user_id = auth.uid())
  );

create table brief_facts (
  id uuid primary key default gen_random_uuid(),
  brief_id uuid not null references briefs (id) on delete cascade,
  source_id uuid not null references brief_sources (id) on delete cascade,
  text text not null,
  -- 原文逐字引文。后面一切的根（§4.3）
  quote text not null
);

alter table brief_facts enable row level security;

create policy "brief_facts follow their brief" on brief_facts
  for all using (
    exists (select 1 from briefs b where b.id = brief_facts.brief_id and b.user_id = auth.uid())
  );

create table brief_claims (
  id uuid primary key default gen_random_uuid(),
  brief_id uuid not null references briefs (id) on delete cascade,
  text text not null,
  -- 互不相关的信源组数量，不是信源条数
  independence integer not null default 0,
  confidence text not null check (confidence in ('strong', 'weak', 'conflicted'))
);

alter table brief_claims enable row level security;

create policy "brief_claims follow their brief" on brief_claims
  for all using (
    exists (select 1 from briefs b where b.id = brief_claims.brief_id and b.user_id = auth.uid())
  );

create table claim_facts (
  claim_id uuid not null references brief_claims (id) on delete cascade,
  fact_id uuid not null references brief_facts (id) on delete cascade,
  primary key (claim_id, fact_id)
);

alter table claim_facts enable row level security;

create policy "claim_facts follow their claim" on claim_facts
  for all using (
    exists (
      select 1 from brief_claims c join briefs b on b.id = c.brief_id
      where c.id = claim_facts.claim_id and b.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 证据层：挂在 Script 旁边，Script 自己不加字段（§4.1）
-- ---------------------------------------------------------------------------

create table script_evidence (
  sentence_id uuid not null references sentences (id) on delete cascade,
  claim_id uuid not null references brief_claims (id) on delete cascade,
  -- 写入时的句子内容指纹。Safe Word 当场改稿后文本一变，这一句降级为
  -- 「已改动 · 无信源」，而不是继续显示旧信源（§9.2 ③）
  sentence_fingerprint text not null,
  primary key (sentence_id, claim_id)
);

alter table script_evidence enable row level security;

create policy "script_evidence follows its script" on script_evidence
  for all using (
    exists (
      select 1 from sentences s
      join paragraphs p on p.id = s.paragraph_id
      join script_sections sec on sec.id = p.section_id
      join scripts sc on sc.id = sec.script_id
      where s.id = script_evidence.sentence_id and sc.user_id = auth.uid()
    )
  );

-- 气口与重读。同样挂在旁边——sentences 表不加列（§9.2 ⑤）
create table sentence_prosody (
  sentence_id uuid primary key references sentences (id) on delete cascade,
  breath_after text check (breath_after in ('long', 'short', 'none')),
  emphasis_spans jsonb not null default '[]'::jsonb
);

alter table sentence_prosody enable row level security;

create policy "sentence_prosody follows its script" on sentence_prosody
  for all using (
    exists (
      select 1 from sentences s
      join paragraphs p on p.id = s.paragraph_id
      join script_sections sec on sec.id = p.section_id
      join scripts sc on sc.id = sec.script_id
      where s.id = sentence_prosody.sentence_id and sc.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 实测语速。这份数据目前根本不存在（§9.2 ①）——本迁移只建表，
-- iOS 侧的采集是另一个计划。
-- ---------------------------------------------------------------------------

create table user_reading_rates (
  user_id uuid not null references auth.users (id) on delete cascade,
  language text not null check (language in ('cjk', 'latin')),
  chars_per_second real not null check (chars_per_second > 0),
  sample_count integer not null default 1,
  updated_at timestamptz not null default now(),
  primary key (user_id, language)
);

alter table user_reading_rates enable row level security;

create policy "user_reading_rates are owner-scoped" on user_reading_rates
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create index brief_stages_brief_idx on brief_stages (brief_id);
create index brief_sources_brief_idx on brief_sources (brief_id);
create index brief_facts_brief_idx on brief_facts (brief_id);
create index brief_claims_brief_idx on brief_claims (brief_id);
create index briefs_user_status_idx on briefs (user_id, status);
```

- [ ] **Step 2: 本地建库验证**

机器上有 Homebrew 的 Postgres 17，但**不在 PATH 里，而且默认 locale 会让 `initdb` 直接报错**。
下面这套是实际跑通过的，照抄即可（端口 55432，走 Unix socket，不监听网络）：

```bash
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
D=/tmp/pollux-pgdata
LC_ALL=C initdb -D "$D" -U postgres --auth=trust --locale=C --encoding=UTF8
LC_ALL=C pg_ctl -D "$D" -o "-p 55432 -k /tmp -c listen_addresses=" -l "$D/server.log" start
LC_ALL=C psql -h /tmp -p 55432 -U postgres -c "create database t;"
```

`0001` 引用 `auth.users` 和 `auth.uid()`，本地没有 Supabase 的 auth schema，先打个桩：

```bash
LC_ALL=C psql -h /tmp -p 55432 -U postgres -d t -v ON_ERROR_STOP=1 <<'SQL'
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
create function auth.uid() returns uuid language sql stable as $$ select '00000000-0000-0000-0000-000000000000'::uuid $$;
SQL
```

然后依次跑两个迁移：

```bash
cd /Users/fengzhou/Code/PolluxOne
LC_ALL=C psql -h /tmp -p 55432 -U postgres -d t -q -v ON_ERROR_STOP=1 -f backend/supabase/migrations/0001_init.sql
LC_ALL=C psql -h /tmp -p 55432 -U postgres -d t -q -v ON_ERROR_STOP=1 -f backend/supabase/migrations/0002_briefs.sql
```

Expected: 两条都静默成功（`-q` 下无输出即为通过；有 `ERROR:` 就是失败）

- [ ] **Step 3: 确认外键指向真的存在**

```bash
psql "$DATABASE_URL" -c "\d script_evidence" -c "\d user_reading_rates"
```

Expected: `script_evidence.sentence_id` 指向 `sentences(id)`、`claim_id` 指向 `brief_claims(id)`；`user_reading_rates` 有 `(user_id, language)` 复合主键

- [ ] **Step 4: 提交**

```bash
git add backend/supabase/migrations/0002_briefs.sql
git commit -m "Make room for briefs, their evidence, and how fast people read"
```

---

### Task 15: 抽出共享的 union-find

审查发现 `dedupe/` 下两个兄弟模块各写了一套 union-find：`independence.ts` 的
`find` 带路径压缩，`merge.ts` 的不带。两者都正确，规模下性能也都无所谓——
问题是同职责的代码在同一个目录里有两种写法，以后改一个忘了改另一个。

**Files:**
- Create: `pipeline/src/dedupe/union-find.ts`
- Modify: `pipeline/src/dedupe/independence.ts`
- Modify: `pipeline/src/dedupe/merge.ts`
- Test: `pipeline/test/union-find.test.ts`

- [ ] **Step 1: 写失败的测试**

`pipeline/test/union-find.test.ts`：

```ts
import { expect, test } from "vitest";
import { createUnionFind } from "../src/dedupe/union-find.js";

test("everything starts in its own group", () => {
  expect(createUnionFind(3).groups()).toEqual([[0], [1], [2]]);
});

test("union merges two groups", () => {
  const uf = createUnionFind(3);
  uf.union(0, 2);
  expect(uf.groups()).toEqual([[0, 2], [1]]);
});

test("grouping is transitive", () => {
  const uf = createUnionFind(4);
  uf.union(0, 1);
  uf.union(1, 2);
  expect(uf.groups()).toEqual([[0, 1, 2], [3]]);
});

test("union is idempotent", () => {
  const uf = createUnionFind(2);
  uf.union(0, 1);
  uf.union(0, 1);
  uf.union(1, 0);
  expect(uf.groups()).toEqual([[0, 1]]);
});

test("a long chain still resolves, whichever order it was built in", () => {
  const uf = createUnionFind(64);
  for (let i = 63; i > 0; i--) uf.union(i - 1, i);
  const groups = uf.groups();
  expect(groups).toHaveLength(1);
  expect(groups[0]).toHaveLength(64);
});

test("groups come back in order of first member", () => {
  const uf = createUnionFind(5);
  uf.union(3, 1);
  expect(uf.groups()).toEqual([[0], [1, 3], [2], [4]]);
});

test("size zero has no groups", () => {
  expect(createUnionFind(0).groups()).toEqual([]);
});
```

- [ ] **Step 2: 跑测试确认它失败**

```bash
cd pipeline && npx vitest run test/union-find.test.ts
```

Expected: FAIL，报 `Failed to resolve import "../src/dedupe/union-find.js"`

- [ ] **Step 3: 实现**

`pipeline/src/dedupe/union-find.ts`：

```ts
/**
 * 按下标分组的并查集。`dedupe/` 下两处都要用：
 * `independence.ts` 把转载并成一个信源，`merge.ts` 把重复的事实并成一条 claim。
 *
 * `groups()` 按**每组最小成员**的顺序返回，组内也升序——两个调用方都要
 * 稳定的输出顺序（`merge.ts` 用它给 claim 编号，而 fixture 里的 draft
 * 按名字引用 c0/c1/c2），所以顺序是接口的一部分，不是实现细节。
 */
export interface UnionFind {
  union(a: number, b: number): void;
  groups(): number[][];
}

export function createUnionFind(size: number): UnionFind {
  const parent = Array.from({ length: size }, (_, i) => i);

  const find = (i: number): number => {
    let root = i;
    while (parent[root] !== root) root = parent[root]!;
    // 路径压缩：把这一路上的节点直接挂到根上
    let walk = i;
    while (parent[walk] !== root) {
      const next = parent[walk]!;
      parent[walk] = root;
      walk = next;
    }
    return root;
  };

  return {
    union(a, b) {
      const ra = find(a);
      const rb = find(b);
      if (ra !== rb) parent[rb] = ra;
    },
    groups() {
      const byRoot = new Map<number, number[]>();
      for (let i = 0; i < size; i++) {
        const root = find(i);
        const bucket = byRoot.get(root);
        if (bucket) bucket.push(i);
        else byRoot.set(root, [i]);
      }
      return [...byRoot.values()];
    },
  };
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd pipeline && npx vitest run test/union-find.test.ts
```

Expected: `7 passed`

- [ ] **Step 5: 让 independence.ts 用它**

在 `pipeline/src/dedupe/independence.ts` 里，把 import 改成：

```ts
import type { Source, SourceId } from "../domain/types.js";
import { BODY_SHINGLE_K, jaccard, shingles } from "./shingle.js";
import { createUnionFind } from "./union-find.js";
```

删掉 `groupSources` 里从 `const parent = sources.map(...)` 到 `const union = ...};` 的整段本地并查集，换成一行：

```ts
  const uf = createUnionFind(sources.length);
```

把两处 `union(i, j)` 改成 `uf.union(i, j)`，并把函数结尾从 `const byRoot = new Map...` 那整段换成：

```ts
  return uf.groups().map((members) => ({
    sourceIds: members.map((i) => sources[i]!.id),
  }));
```

- [ ] **Step 6: 让 merge.ts 用它**

在 `pipeline/src/dedupe/merge.ts` 里，import 加一行：

```ts
import { createUnionFind } from "./union-find.js";
```

删掉 `mergeFacts` 里的本地 `parent` / `find` / `union`，换成：

```ts
  const uf = createUnionFind(facts.length);
```

把 `union(i, j)` 改成 `uf.union(i, j)`，并把结尾的 `const byRoot = ...` 整段换成：

```ts
  return uf.groups().map((indices, n) => {
    // 最长的措辞信息量最大，用它当 Claim 的表述
    const longest = indices.reduce((best, i) =>
      facts[i]!.text.length > facts[best]!.text.length ? i : best, indices[0]!);
    return {
      id: `c${n}`,
      text: facts[longest]!.text,
      factIds: indices.map((i) => facts[i]!.id),
    } satisfies MergedClaim;
  });
```

- [ ] **Step 7: 全量测试——这一步是重点**

```bash
cd pipeline && npm test && npm run typecheck
```

Expected: 现有的每一个测试都照旧通过，只是多了 union-find 自己的 7 个。
**一个都不许改。** 这是纯重构：任何既有测试变红都说明抽取改变了行为，
报告出来，不要去动测试。

- [ ] **Step 8: 提交**

```bash
git add pipeline/src/dedupe/union-find.ts pipeline/test/union-find.test.ts \
        pipeline/src/dedupe/independence.ts pipeline/src/dedupe/merge.ts
git commit -m "Give the two groupers one union-find instead of two"
```

---

### Task 16: 收口

**Files:**
- Create: `pipeline/README.md`
- Modify: `README.md`

- [ ] **Step 1: 写 pipeline/README.md**

```markdown
# pipeline

「新闻 → 口播稿」调研管线。设计见
`docs/superpowers/specs/2026-09-17-news-brief-pipeline-design.md`。

**这个包目前只有确定性内核**——spec §3 说的「刻意不用 AI 的那几步」：

| 阶段 | 模块 |
|---|---|
| ④ 归并去重 | `src/dedupe/merge.ts` |
| ⑤ 交叉验证 | `src/dedupe/independence.ts` · `conflict.ts` · `classify.ts` |
| ⑥ 选点（名额与门槛） | `src/draft/select.ts` |
| ⑧ 挂信源 | `src/draft/bind.ts` |
| ⑨ 时长与气口 | `src/domain/prosody.ts` |
| §10.1 成本估算 | `src/domain/estimate.ts` |

`src/dedupe/union-find.ts` 是上面两处分组共用的原语；`src/core.ts` 把这几段串起来，
`src/cli.ts` 是磁盘与类型化代码之间的信任边界（它校验输入，因为畸形输入最坏的
后果不是报错，是一个看起来很合理的错答案）。

①抓原文 ②扩展检索 ③抽事实 ⑦成稿 属于模型与网络层，**还没做**。

## 跑

    npm install
    npm test          # 97 个，全部离线，不需要任何 API key
    npm run typecheck
    npm run brief -- test/fixtures/reserve-cut.json

`npm test` 一次模型都不调、一个网络请求都不发。这是有意的：**护城河上的算术
必须能不花钱地反复验证。**

`npm run brief` 喂进去的是降准那条新闻的五个信源，其中**一个是另一个的逐字转载**。
出来的结果里那条头条事实是 `independence: 3` 而不是 4——这一个数字就是整个包
存在的理由。路透说 23 亿、彭博说 31 亿，两条都被标成 `conflicted` 且不进稿。

退出码：`0` 正常 · `1` 出稿了但绑定失败 · `2` 输入读不了或管线抛错。

## 运行时依赖为零

和 iOS 侧「V1 无第三方 SPM 包」同一条纪律。devDependencies 只有 typescript、
vitest、tsx。
```

- [ ] **Step 2: 在根 README 的项目结构里加一行**

把根 `README.md` 里这段：

```
├── backend/      Supabase schema / RLS migrations
```

改成：

```
├── backend/      Supabase schema / RLS migrations
├── pipeline/     「新闻 → 口播稿」调研管线（TypeScript，零运行时依赖）
```

- [ ] **Step 3: 全量验证**

```bash
cd /Users/fengzhou/Code/PolluxOne/pipeline && npm test && npm run typecheck
cd /Users/fengzhou/Code/PolluxOne && ./scripts/test-engines.sh
```

Expected: pipeline 全绿；iOS harness 仍然 `TOTAL: N passed, 0 failed`（本计划没碰 Swift，但要确认没连带破坏）

- [ ] **Step 4: 提交**

```bash
git add pipeline/README.md README.md
git commit -m "Say what the pipeline does and does not do yet"
```

---

## 完成标准

- `cd pipeline && npm test` 全绿，**零 API key、零网络**
- `npm run brief -- test/fixtures/reserve-cut.json`：`selection.verdict` 为 `ok`、「1 万亿」那条 `independence: 3`（不是 4，因为一篇是转载）、路透/彭博两条 `conflicted` 且不进稿
- spec §11 的前四行测试全部有对应的断言
- `0002_briefs.sql` 在本地 Postgres 上跑得过

## 交给下一个计划的东西

1. **模型与网络层**：①抓原文 ②扩展检索 ③抽事实 ⑦成稿，以及 §4.2 的阶段状态机
2. **语义冲突检测**：数字之外的冲突，需要 `deepseek-flash` 二分类
3. **`ESTIMATE_COEFFICIENTS` 回归校准**：用真实样本的实际消耗，把 Task 8 里钉住的系数换成量出来的
4. **两个锚点的稿件质量评估**：`1:00 通俗` 与 `3:00 偏专业`，spec §11 最后一行——这才是第一段真正要回答的问题
5. **`user_reading_rates` 的 iOS 采集**：导出 `ReadingPacer.rate`，独立计划
6. **`angle` 的消费**：迁移已经建了列（§2.3），但把它当 ⑥ 选点的软约束是模型侧的事
7. **独立源规则集的两个盲区**（§5 的规则现在漏这两类，都朝算多的方向）：
   轻改+只摘引一段的转载逃过整篇 Jaccard；两家都引一个不在信源集合里的通讯社时
   `creditedTo` 不相等匹配。前者要段落级相似度，后者要决定「同 creditedTo 是否即归并」
8. **claim id 是位置函数**：`c${n}` 由 fact 到达顺序决定。当前是「一次跑到底」，
   同一次运行内稳定就够用。真要支持「人工改完事实列表再从 ④ 增量重跑」，
   得换成内容 hash 或最小 factId
9. **落库时的文本口径**：本包只产出**句子文本**，从不拼接整篇——spec §9.2 ④ 警告过
   两边各拼一次会让提词器的字偏移永久性偏移且随脚本长度累积。排版口径由
   `PromptScriptText` 唯一持有。下一个计划写库时必须守住这条
