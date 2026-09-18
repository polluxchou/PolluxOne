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
