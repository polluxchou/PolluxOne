export type SourceId = string;
export type FactId = string;
export type ClaimId = string;

/** 一个信源。`body` 是抓到的正文；指纹不存字段，由 dedupe 现算——少一个要维护的不变量。 */
export interface Source {
  id: SourceId;
  url: string;
  publisher: string;
  /** ISO 8601 */
  publishedAt: string;
  body: string;
  /** 正文里显式写明的转载来源，如「新华社」。没有则 null。 */
  creditedTo: string | null;
}

/** 从单个 Source 抽出的原子事实。`quote` 是逐字引文——spec §4.3 说这是后面一切的根。 */
export interface Fact {
  id: FactId;
  sourceId: SourceId;
  text: string;
  quote: string;
}

export type Confidence = "strong" | "weak" | "conflicted";

/** ④ 归并的产物。此时还不知道有几个独立源，也还不知道敢不敢播。 */
export interface MergedClaim {
  id: ClaimId;
  text: string;
  factIds: FactId[];
}

/**
 * ⑤ 交叉验证的产物。`independence` 是互不相关的信源组数量，不是信源条数。
 *
 * 和 MergedClaim 分开是有意的：④ 出来的东西还不知道有几个独立源。若两者共用
 * 一个类型，就得先塞一个 `independence: 0` 的占位值——那是**一个关于自己
 * 有多少信源的谎**。在一个以可溯源为唯一承诺的产品里，这种中间态不该在
 * 类型上存在。
 */
export interface VerifiedClaim extends MergedClaim {
  independence: number;
  confidence: Confidence;
  conflictsWith: ClaimId[];
}

export type SentenceKind = "fact" | "opinion" | "transition";

/** ⑦ 成稿的输出形状。fact 句必须带 claimIds，opinion 句不许带——§6.2。 */
export interface DraftSentence {
  text: string;
  kind: SentenceKind;
  claimIds: ClaimId[];
}
