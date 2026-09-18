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
