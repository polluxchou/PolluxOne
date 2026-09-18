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
