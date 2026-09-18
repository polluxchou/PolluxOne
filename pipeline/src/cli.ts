import { readFileSync } from "node:fs";
import { buildBrief, type CoreInput } from "./core.js";

/**
 * 把一份固定数据跑过确定性内核，结果打到 stdout。
 *
 *   npm run brief -- test/fixtures/reserve-cut.json
 *
 * 模型与网络层接进来之后，这个入口仍然有用：它是唯一能**不花一分钱**
 * 反复验证 ④⑤⑥⑧⑨ 的地方。
 */
function main(argv: string[]): number {
  const path = argv[2];
  if (path === undefined) {
    process.stderr.write("usage: brief <fixture.json>\n");
    return 2;
  }

  let input: CoreInput;
  try {
    input = JSON.parse(readFileSync(path, "utf8")) as CoreInput;
  } catch (error) {
    process.stderr.write(`cannot read ${path}: ${(error as Error).message}\n`);
    return 2;
  }

  const result = buildBrief(input);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);

  // 出稿了但绑定有问题，是最该被 CI 拦住的情况
  if (result.selection.verdict === "ok" && !result.bind.ok) return 1;
  return 0;
}

process.exit(main(process.argv));
