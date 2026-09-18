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
