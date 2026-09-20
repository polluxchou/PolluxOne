import type { ClaimId, DraftSentence, SentenceKind } from "../domain/types.js";

const KINDS = new Set<SentenceKind>(["fact", "opinion", "transition"]);

export type ProblemKind =
  | "no-sentences"
  | "bad-shape"
  | "empty-text"
  | "bad-kind"
  | "fact-without-claims"
  | "opinion-with-claims"
  | "unknown-claim";

export interface Problem {
  kind: ProblemKind;
  index: number;
  detail: string;
}

export type ValidateResult =
  | { ok: true; sentences: DraftSentence[] }
  | { ok: false; problems: Problem[] };

/**
 * DeepSeek 不支持 strict schema，所以 §6.2「fact 句必须挂 claim、opinion 句
 * 不许挂」这条**唯一的**保证就在这个函数里。它必须是拒收，不是尽量。
 *
 * 一次报齐全部问题：重跑时要把话说全，一次只报一个会让重跑次数线性增长。
 */
export function validateDraft(
  reply: { sentences?: unknown },
  allowedClaimIds: Set<ClaimId>,
): ValidateResult {
  const raw = reply?.sentences;
  if (!Array.isArray(raw)) {
    return { ok: false, problems: [{ kind: "bad-shape", index: -1, detail: "sentences 不是数组" }] };
  }
  if (raw.length === 0) {
    return { ok: false, problems: [{ kind: "no-sentences", index: -1, detail: "一句都没有" }] };
  }

  const problems: Problem[] = [];
  const sentences: DraftSentence[] = [];

  raw.forEach((item: unknown, index: number) => {
    const s = item as Partial<DraftSentence>;

    if (typeof s?.text !== "string" || s.text.trim() === "") {
      problems.push({ kind: "empty-text", index, detail: "文本为空" });
      return;
    }
    if (typeof s.kind !== "string" || !KINDS.has(s.kind as SentenceKind)) {
      problems.push({ kind: "bad-kind", index, detail: `未知的 kind：${String(s.kind)}` });
      return;
    }

    const claimIds = Array.isArray(s.claimIds) ? s.claimIds.filter((c) => typeof c === "string") : [];

    if (s.kind === "fact" && claimIds.length === 0) {
      // 这是整条产品承诺的断裂点：一句事实没有信源，却混在有信源的句子里。
      problems.push({ kind: "fact-without-claims", index, detail: s.text });
      return;
    }
    if (s.kind !== "fact" && claimIds.length > 0) {
      // 观点句挂信源是在给个人判断披一层客观外衣。
      problems.push({ kind: "opinion-with-claims", index, detail: s.text });
      return;
    }

    const unknown = claimIds.filter((c) => !allowedClaimIds.has(c));
    if (unknown.length > 0) {
      // 引用不存在的 claim 说明模型在编——这一条比其他任何问题都值得警惕。
      problems.push({ kind: "unknown-claim", index, detail: unknown.join("、") });
      return;
    }

    sentences.push({ text: s.text.trim(), kind: s.kind as SentenceKind, claimIds });
  });

  if (problems.length > 0) return { ok: false, problems };
  return { ok: true, sentences };
}
