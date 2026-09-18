import { createHash } from "node:crypto";
import { normalize } from "../dedupe/shingle.js";
import type { ClaimId, DraftSentence } from "../domain/types.js";

export type BindProblemKind = "fact-without-claim" | "unknown-claim";

export interface BindProblem {
  sentenceIndex: number;
  kind: BindProblemKind;
  claimId?: ClaimId;
}

export interface EvidenceRow {
  sentenceIndex: number;
  claimIds: ClaimId[];
  sentenceFingerprint: string;
}

export interface BindResult {
  ok: boolean;
  problems: BindProblem[];
  evidence: EvidenceRow[];
  /** opinion 句的 claimIds 已剥离 */
  sentences: DraftSentence[];
}

/**
 * 句子的内容指纹。标点和空白不计入——录制中 Safe Word 只改个逗号不该让信源掉，
 * 改了数字就必须掉。spec §9.2 ③。
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
      problems.push({ sentenceIndex, kind: "fact-without-claim" });
      sentences.push(sentence);
      return;
    }

    const unknown = sentence.claimIds.filter((id) => !verified.has(id));
    for (const claimId of unknown) {
      problems.push({ sentenceIndex, kind: "unknown-claim", claimId });
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

  return { ok: problems.length === 0, problems, evidence, sentences };
}
