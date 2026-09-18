import type { Source, SourceId } from "../domain/types.js";
import { BODY_SHINGLE_K, jaccard, shingles } from "./shingle.js";

/** 正文相似度到这个值就判为同一份稿。用真实转载样本调过再改。 */
export const SAME_SOURCE_JACCARD = 0.5;

export interface SourceGroup {
  sourceIds: SourceId[];
}

/**
 * 把互相转载、互相署名、同一媒体主体的 Source 并成一组。
 * **组数才是 independence，信源条数不是。** 同一份通讯社稿被五家门户转载，
 * 是 1 个源不是 5 个——这个数字算错，整个「每句可溯源」的承诺就是假的。
 *
 * @param mediaGroups publisher → 媒体集团 key 的映射。同集团视为同一主体。
 */
export function groupSources(
  sources: Source[],
  mediaGroups: Record<string, string> = {},
): SourceGroup[] {
  const parent = sources.map((_, i) => i);

  const find = (i: number): number => {
    let root = i;
    while (parent[root] !== root) root = parent[root]!;
    let walk = i;
    while (parent[walk] !== root) {
      const next = parent[walk]!;
      parent[walk] = root;
      walk = next;
    }
    return root;
  };
  const union = (a: number, b: number): void => {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[rb] = ra;
  };

  const prints = sources.map((s) => shingles(s.body, BODY_SHINGLE_K));
  const subject = (s: Source): string => mediaGroups[s.publisher] ?? s.publisher;

  for (let i = 0; i < sources.length; i++) {
    for (let j = i + 1; j < sources.length; j++) {
      const a = sources[i]!;
      const b = sources[j]!;

      // 规则 1：正文指纹相似 —— 同一份稿的转载
      //
      // 先要求两边都产出了指纹。抓取失败或正文短于 k 的源产不出 shingle，
      // 而**两个空集的 Jaccard 是 1**——不挡的话，两条毫不相干的新闻会被
      // 并成一个源，独立源数就少算了。jaccard 是纯算术函数，「什么叫一个
      // 信源」的判断属于这里。
      if (prints[i]!.size > 0 && prints[j]!.size > 0
        && jaccard(prints[i]!, prints[j]!) >= SAME_SOURCE_JACCARD) {
        union(i, j);
        continue;
      }
      // 规则 2：显式署名指向对方
      if (a.creditedTo === b.publisher || b.creditedTo === a.publisher) {
        union(i, j);
        continue;
      }
      // 规则 3：同一媒体主体
      if (subject(a) === subject(b)) union(i, j);
    }
  }

  const byRoot = new Map<number, SourceId[]>();
  for (let i = 0; i < sources.length; i++) {
    const root = find(i);
    const bucket = byRoot.get(root);
    if (bucket) bucket.push(sources[i]!.id);
    else byRoot.set(root, [sources[i]!.id]);
  }
  return [...byRoot.values()].map((sourceIds) => ({ sourceIds }));
}

/** 一条 Claim 引用的这些信源，落在几个互不相关的组里。 */
export function independenceOf(cited: SourceId[], groups: SourceGroup[]): number {
  const wanted = new Set(cited);
  let count = 0;
  for (const group of groups) {
    if (group.sourceIds.some((id) => wanted.has(id))) count += 1;
  }
  return count;
}
