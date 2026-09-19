import { expect, test } from "vitest";
import { quantities } from "../src/dedupe/quantity.js";

/** `值\0量纲` 读起来太难看，测试里一律拆成对子比。 */
function q(text: string): [string, string][] {
  return quantities(text).map((t) => {
    const [value, dim] = t.split("\0");
    return [value!, dim!];
  });
}

test("a quantity is a value plus a one-character dimension", () => {
  expect(q("降准 0.5 个百分点，释放 1 万亿元，3 月 15 日生效")).toEqual([
    ["0.5", "个"],
    ["1000000000000", "元"],
    ["15", "日"],
    ["3", "月"],
  ]);
});

test("prose after the unit never reaches the quantity", () => {
  // 这就是误杀的根源：④ 的签名把「日生」「日起」吃进 token，于是任意行文
  // 差异都能造出「不相等的签名」。量纲只收一个字符，正文进不来。
  expect(q("新政自 3 月 15 日生效")).toEqual(q("新政自 3 月 15 日起生效"));
  expect(q("起步价 2 元起")).toEqual(q("起步价 2 元整"));
  expect(q("合同期为 5 年，随后续约")).toEqual(q("合同期为 5 年，之后再谈"));
});

test("the same value written differently is the same quantity", () => {
  expect(q("起步价 1.5 元")).toEqual(q("起步价 1.50 元"));
  expect(q("身价 2800 万欧元")).toEqual(q("身价 2,800 万欧元"));
  expect(q("释放资金约 1 万亿元")).toEqual(q("释放资金约 10000 亿元"));
  expect(q("释放资金约 1 万亿元")).toEqual([["1000000000000", "元"]]);
});

test("号 and 日 are the same dimension — a date written two ways", () => {
  expect(q("3 月 15 号起生效")).toEqual(q("3 月 15 日起生效"));
});

test("scaling is exact decimal, not floating point", () => {
  // `0.28 * 1e8` 在浮点里是 28000000.000000004，`0.57 * 1e8` 是 56999999.99999999。
  // 真走 `Number` 的话，两条说同一个数的 claim 会因为最后一位尾数被判成矛盾——
  // 这种误差没有阈值能挡，只能不产生它。
  expect(q("涉及 0.28 亿元")).toEqual(q("涉及 2800 万元"));
  expect(q("涉及 0.28 亿元")).toEqual([["28000000", "元"]]);
  expect(q("涉及 0.57 亿元")).toEqual(q("涉及 5700 万元"));
  expect(q("涉及 0.1 亿元")).toEqual([["10000000", "元"]]);
  expect(q("涨了 0.3 元")).toEqual([["0.3", "元"]]);
});

test("full-width digits are read, not skipped", () => {
  // 这是「漏检」那半边的根：`\d` 只认 ASCII，不归一的话全角数字取不出任何
  // 量，空集 ⊆ 任意集 —— 既不归并也不报冲突。
  expect(q("涉及金额约 ２３ 亿美元")).toEqual(q("涉及金额约 23 亿美元"));
  expect(q("涉及金额约 ２３ 亿美元")).toEqual([["2300000000", "美"]]);
  expect(q("同比增长 ４５％")).toEqual([["45", "%"]]);
});

test("different values on the same dimension stay different quantities", () => {
  // 归一的每一条都要有反向：放宽一处就问一次「这会不会让真分歧溜过去」。
  expect(q("起步价 2 元")).not.toEqual(q("起步价 3 元"));
  expect(q("起步价 1.5 元")).not.toEqual(q("起步价 1.55 元"));
  expect(q("身价 2,800 万欧元")).not.toEqual(q("身价 2,900 万欧元"));
  expect(q("释放资金约 1 万亿元")).not.toEqual(q("释放资金约 1000 亿元"));
  expect(q("3 月 15 号")).not.toEqual(q("3 月 16 日"));
  expect(q("涉及 ２３ 亿美元")).not.toEqual(q("涉及 31 亿美元"));
});

test("different dimensions on the same value stay different quantities", () => {
  // 量纲折叠是漏检方向（用户看不见），所以这里刻意不做同义单位归并。
  expect(q("涉及 23 亿美元")).not.toEqual(q("涉及 23 亿欧元"));
  expect(q("起步价 2 元")).not.toEqual(q("起步价 2 角"));
  expect(q("合同期 5 年")).not.toEqual(q("合同期 5 月"));
  // 量纲本身不能被当标点丢掉，否则「45%」和「45」会撞成一个量。
  expect(q("同比增长 45%")).not.toEqual(q("同比增长 45"));
});

test("十/百/千 are units, not scales", () => {
  // 把千当数量级的话「31.4 千米」会被读成 31400，凭空改掉数值本身。
  expect(q("全长 31.4 千米")).toEqual([["31.4", "千"]]);
  expect(q("全长 31.4 千米")).not.toEqual(q("全长 31400 米"));
  expect(q("上涨 3 百分点")).toEqual([["3", "百"]]);
});

test("punctuation stops the dimension", () => {
  expect(q("合同期为 5 年。")).toEqual([["5", "年"]]);
  expect(q("涉及 23 亿，随后回落")).toEqual([["2300000000", ""]]);
});

test("a sentence with no digits yields no quantities", () => {
  expect(q("央行今天突然出手了")).toEqual([]);
  // 已知敞口：中文数字认不出来，所以这一条**也**是空的。
  // 空集 ⊆ 任意集 —— 这类 claim 在 ⑤ 里永远不会报冲突。
  expect(q("此次降准释放长期资金约一万亿元")).toEqual([]);
});

test("repeated quantities are kept, not deduplicated", () => {
  // 多重集：「两地各 5 人」和「一地 5 人」说的量不一样多。
  expect(q("甲队 5 人，乙队 5 人")).toEqual([["5", "人"], ["5", "人"]]);
});
