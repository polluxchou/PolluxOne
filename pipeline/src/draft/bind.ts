import { createHash } from "node:crypto";
import { normalize } from "../dedupe/shingle.js";
import type { ClaimId, DraftSentence } from "../domain/types.js";

/** 判别联合：`fact-without-claim` 永远没有 claimId，`unknown-claim` 永远有。 */
export type BindProblem =
  | { kind: "fact-without-claim"; sentenceIndex: number }
  | { kind: "unknown-claim"; sentenceIndex: number; claimId: ClaimId };

export interface EvidenceRow {
  /**
   * **这是快照序号，不是稳定外键。** 它只在传进来的那个 draft 数组里有效。
   * spec §8.1 的审稿页允许逐句删除，删掉一句之后其后每一行的下标都会挪位——
   * 指纹防的是 Safe Word 当场改写，**不防删除**（spec §9.2 ③ 自己也把
   * 「审稿时删句要清理孤儿 evidence」单列成一条）。下一个计划落库时必须给
   * 句子一个稳定 id，别把这个字段当外键用。
   */
  sentenceIndex: number;
  claimIds: ClaimId[];
  sentenceFingerprint: string;
}

/**
 * 失败时**不返回** evidence 和 sentences——不是省事，是让「忘了检查 ok 就去用
 * evidence」在类型上不可能发生。那正好是这个函数存在的理由的反面：把没通过
 * 校验的绑定挂到句子上。
 */
export type BindResult =
  | { ok: true; evidence: EvidenceRow[]; sentences: DraftSentence[] }
  | { ok: false; problems: BindProblem[] };

/**
 * 句子的内容指纹。标点和空白不计入——录制中 Safe Word 只改个逗号不该让信源掉，
 * 改了数字就必须掉。spec §9.2 ③。
 *
 * 只取 16 个十六进制字符（64 位）是够的：这不是一个要和几百万条比对的内容
 * 索引，而是「这一行的当前文本还等于记录时的那份吗」这样一次成对比较。
 * 别看见截断就去改成整串。
 */
export function sentenceFingerprint(text: string): string {
  return createHash("sha256").update(normalize(text)).digest("hex").slice(0, 16);
}

/**
 * ⑧ 挂信源：**纯查表 + 校验，没有模型参与**。
 *
 * 这就是「每一句都可溯源」这句话敢写出来的全部理由：绑定是算出来的。
 * 一旦这一步改成"让模型判断"，那句宣传就变成虚假宣传。
 */
export function bindEvidence(draft: DraftSentence[], verifiedClaimIds: ClaimId[]): BindResult {
  const verified = new Set(verifiedClaimIds);
  const problems: BindProblem[] = [];
  const evidence: EvidenceRow[] = [];
  const sentences: DraftSentence[] = [];

  draft.forEach((sentence, sentenceIndex) => {
    if (sentence.kind !== "fact") {
      // 观点不该伪装成有据可依
      sentences.push({ ...sentence, claimIds: [] });
      return;
    }

    if (sentence.claimIds.length === 0) {
      problems.push({ kind: "fact-without-claim", sentenceIndex });
      sentences.push(sentence);
      return;
    }

    const unknown = sentence.claimIds.filter((id) => !verified.has(id));
    for (const claimId of unknown) {
      problems.push({ kind: "unknown-claim", sentenceIndex, claimId });
    }
    sentences.push(sentence);
    if (unknown.length === 0) {
      evidence.push({
        sentenceIndex,
        claimIds: sentence.claimIds,
        sentenceFingerprint: sentenceFingerprint(sentence.text),
      });
    }
  });

  // 一条问题都没有才算绑成了。半好半坏的绑定不发出去——模型既然已经证明
  // 它分不清哪些 claim 通过了验证，这一句里"对的那一半"也不值得信。
  if (problems.length > 0) return { ok: false, problems };
  return { ok: true, evidence, sentences };
}
