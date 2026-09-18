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
