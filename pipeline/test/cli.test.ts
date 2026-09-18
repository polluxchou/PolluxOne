import { execFileSync } from "node:child_process";
import { expect, test } from "vitest";

function run(fixture: string): { code: number; out: string } {
  try {
    return { code: 0, out: execFileSync("npx", ["tsx", "src/cli.ts", fixture], { encoding: "utf8" }) };
  } catch (error) {
    const e = error as { status: number; stdout: string };
    return { code: e.status, out: e.stdout };
  }
}

test("the reserve-cut fixture produces a script and exits zero", () => {
  const { code, out } = run("test/fixtures/reserve-cut.json");
  expect(code).toBe(0);

  const result = JSON.parse(out);
  expect(result.selection.verdict).toBe("ok");
  expect(result.bind.ok).toBe(true);
});

test("the twelve-repost source set is counted honestly", () => {
  const { out } = run("test/fixtures/reserve-cut.json");
  const result = JSON.parse(out);
  const trillion = result.claims.find((c: { text: string }) => c.text.includes("1 万亿"));
  expect(trillion.independence).toBe(3);
  expect(trillion.confidence).toBe("strong");
});

test("the Reuters/Bloomberg figures come out conflicted and stay out of the script", () => {
  const { out } = run("test/fixtures/reserve-cut.json");
  const result = JSON.parse(out);
  expect(result.selection.conflicted).toHaveLength(2);
  for (const id of result.selection.conflicted) {
    expect(result.selection.picked).not.toContain(id);
  }
});

test("a missing fixture path exits non-zero", () => {
  const { code } = run("test/fixtures/does-not-exist.json");
  expect(code).not.toBe(0);
});
