import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test, vi } from "vitest";
import { livePorts, main } from "../src/cli.js";
import type { Source, VerifiedClaim } from "../src/domain/types.js";
import { DEFAULT_MAX_TOKENS, isTruncated } from "../src/models/deepseek.js";
import { TokenLedger } from "../src/models/ledger.js";

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

// ——— livePorts：三处模型调用的上限，以及截断不重跑。全程离线，send 是替身。———

const CONFIG = {
  deepseek: { apiKey: "k", baseUrl: "https://api.deepseek.com" },
  zhipu: { apiKey: "z" },
};

/** 每次都回同一份内容的假发送器；finish_reason 由调用方决定。 */
function fakeSend(content: string, finishReason = "stop") {
  return vi.fn().mockImplementation(async () =>
    new Response(
      JSON.stringify({
        choices: [{ message: { content }, finish_reason: finishReason }],
        usage: { prompt_tokens: 10, completion_tokens: 5 },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    ),
  );
}

const maxTokensOf = (send: { mock: { calls: unknown[][] } }, call = 0): number =>
  (JSON.parse((send.mock.calls[call]![1] as RequestInit).body as string) as { max_tokens: number })
    .max_tokens;

const SOURCE: Source = {
  id: "s0",
  url: "https://a.com/1",
  publisher: "a.com",
  publishedAt: "2026-09-18T00:00:00Z",
  body: "央行今日宣布下调存款准备金率 0.5 个百分点。",
  creditedTo: null,
};

const CLAIMS: VerifiedClaim[] = [
  { id: "c0", text: "央行下调存款准备金率 0.5 个百分点", factIds: ["s0-f0"], independence: 3, confidence: "strong", conflictsWith: [] },
  { id: "c1", text: "此次降准释放资金 1 万亿元", factIds: ["s0-f1"], independence: 3, confidence: "strong", conflictsWith: [] },
];

const GOOD_DRAFT = '{"sentences":[{"text":"开场","kind":"transition","claimIds":[]},{"text":"央行降准了","kind":"fact","claimIds":["c0"]}]}';

test("三处调用都带着自己的输出上限，⑤ 的比默认更宽", async () => {
  const extract = fakeSend('{"facts":[]}');
  await livePorts(CONFIG, new TokenLedger(), extract).extractFacts(SOURCE);

  const conflict = fakeSend('{"pairs":[]}');
  await livePorts(CONFIG, new TokenLedger(), conflict).findSemanticConflicts(CLAIMS);

  const draft = fakeSend(GOOD_DRAFT);
  await livePorts(CONFIG, new TokenLedger(), draft).draftScript(CLAIMS, 60, 0.5);

  expect(maxTokensOf(extract)).toBe(DEFAULT_MAX_TOKENS);
  expect(maxTokensOf(draft)).toBe(DEFAULT_MAX_TOKENS);
  // ⑤ 的待判对数随 claim 数平方增长，它是三处里最可能顶满的一处。
  expect(maxTokensOf(conflict)).toBeGreaterThan(DEFAULT_MAX_TOKENS);
  // 8000 是实跑里被推理独吞掉的那个数，三处都不许再落回去。
  for (const send of [extract, conflict, draft]) expect(maxTokensOf(send)).toBeGreaterThan(8000);
});

test("成稿被截断时一次都不重跑——同样的上限重跑必然同样截断，每次都真付钱", async () => {
  const send = fakeSend("", "length");
  const error = await livePorts(CONFIG, new TokenLedger(), send)
    .draftScript(CLAIMS, 60, 0.5)
    .catch((e: unknown) => e);

  expect(isTruncated(error)).toBe(true);
  expect(send).toHaveBeenCalledTimes(1);
});

test("输出不合规才走「拒收+重跑」，而且重跑时把问题说给模型听", async () => {
  // fact 句的 claimIds 为空——§6.2 的校验器拒收，但这种毛病重跑一次可能就对了。
  const send = fakeSend('{"sentences":[{"text":"央行降准了","kind":"fact","claimIds":[]}]}');
  const error = await livePorts(CONFIG, new TokenLedger(), send)
    .draftScript(CLAIMS, 60, 0.5)
    .catch((e: unknown) => e);

  expect(send).toHaveBeenCalledTimes(2);
  expect(isTruncated(error)).toBe(false);
  expect((error as Error).message).toMatch(/两次都没通过校验/);
  const retryPrompt = JSON.parse((send.mock.calls[1]![1] as RequestInit).body as string) as {
    messages: { content: string }[];
  };
  expect(retryPrompt.messages[0]!.content).toMatch(/上一版被退回了/);
});

test("npm run brief really works end to end", () => {
  // 只保留这一条子进程测试：它验的是 `tsx src/cli.ts <path>` 这条真实调用
  // 能跑通，直接调 main 验不到。一条就够，不需要四条都付这个代价。
  const out = execFileSync("npx", ["tsx", "src/cli.ts", FIXTURE], { encoding: "utf8" });
  expect(JSON.parse(out).selection.verdict).toBe("ok");
});
