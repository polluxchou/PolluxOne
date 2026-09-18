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
