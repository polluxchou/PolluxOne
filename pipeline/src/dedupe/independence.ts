import type { Source, SourceId } from "../domain/types.js";
import { BODY_SHINGLE_K, jaccard, shingles } from "./shingle.js";
import { createUnionFind } from "./union-find.js";

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
 * **已知盲区**——两处都朝「独立源算多了」这个危险方向，修法涉及产品判断而非
 * 机械修复，记在下一个计划里：
 *
 * 1. 只逐字摘引 wire 稿一段、其余自己写的轻改转载，整篇 5-gram Jaccard 会远低于
 *    0.5，三条规则全部漏掉，于是同一份通稿被当成两个独立源。要接住它得上段落级
 *    或滑窗级相似度。
 * 2. 两家门户都写「据新华社报道」、而新华社原稿不在本次信源集合里时，rule 2 不匹配
 *    ——它比的是 `a.creditedTo === b.publisher`，不是两边 `creditedTo` 相等。
 *
 * @param mediaGroups publisher → 媒体集团 key 的映射。同集团视为同一主体。
 */
export function groupSources(
  sources: Source[],
  mediaGroups: Record<string, string> = {},
): SourceGroup[] {
  const uf = createUnionFind(sources.length);

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
        uf.union(i, j);
        continue;
      }
      // 规则 2：显式署名指向对方
      if (a.creditedTo === b.publisher || b.creditedTo === a.publisher) {
        uf.union(i, j);
        continue;
      }
      // 规则 3：同一媒体主体
      if (subject(a) === subject(b)) uf.union(i, j);
    }
  }

  return uf.groups().map((members) => ({
    sourceIds: members.map((i) => sources[i]!.id),
  }));
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
