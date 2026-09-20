/**
 * 按下标分组的并查集。`dedupe/` 下两处都要用：
 * `independence.ts` 把转载并成一个信源，`merge.ts` 把重复的事实并成一条 claim。
 *
 * `groups()` 按**每组最小成员**的顺序返回，组内也升序——两个调用方都要
 * 稳定的输出顺序（`merge.ts` 用它给 claim 编号，而 fixture 里的 draft
 * 按名字引用 c0/c1/c2），所以顺序是接口的一部分，不是实现细节。
 */
export interface UnionFind {
  union(a: number, b: number): void;
  groups(): number[][];
}

export function createUnionFind(size: number): UnionFind {
  const parent = Array.from({ length: size }, (_, i) => i);

  const find = (i: number): number => {
    let root = i;
    while (parent[root] !== root) root = parent[root]!;
    // 路径压缩：把这一路上的节点直接挂到根上
    let walk = i;
    while (parent[walk] !== root) {
      const next = parent[walk]!;
      parent[walk] = root;
      walk = next;
    }
    return root;
  };

  return {
    union(a, b) {
      const ra = find(a);
      const rb = find(b);
      if (ra !== rb) parent[rb] = ra;
    },
    groups() {
      const byRoot = new Map<number, number[]>();
      for (let i = 0; i < size; i++) {
        const root = find(i);
        const bucket = byRoot.get(root);
        if (bucket) bucket.push(i);
        else byRoot.set(root, [i]);
      }
      return [...byRoot.values()];
    },
  };
}
