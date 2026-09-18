import type { Fact, Source } from "../domain/types.js";

export type RejectReason = "empty" | "unknown-source" | "not-verbatim";

export interface RejectedFact {
  fact: Fact;
  reason: RejectReason;
}

export interface VerifyResult {
  kept: Fact[];
  rejected: RejectedFact[];
}

/**
 * 归一化只处理**排版差异**：空白和全角半角。
 * 绝不做同义词、繁简、标点等价——那些会让"逐字"名存实亡。
 */
export function normalizeForQuote(text: string): string {
  return text.normalize("NFKC").replace(/\s+/gu, "");
}

/**
 * 护城河：模型说"这是逐字引文"只是**自述**，自述不能当证据。
 * 这里把每一条引文拿回它自称的那篇正文里比对，对不上就丢掉。
 *
 * 错误方向：丢掉一条真引文只是少一个事实点；放进一条假引文，
 * 整个"每句可溯源"的承诺就是假的。所以一律从严。
 */
export function verifyQuotes(facts: Fact[], sources: Source[]): VerifyResult {
  const bodyById = new Map(sources.map((s) => [s.id, normalizeForQuote(s.body)]));

  const kept: Fact[] = [];
  const rejected: RejectedFact[] = [];

  for (const fact of facts) {
    const quote = normalizeForQuote(fact.quote);
    if (quote === "") {
      // 空串是任何字符串的子串，放行它等于关掉整个校验。
      rejected.push({ fact, reason: "empty" });
      continue;
    }

    const body = bodyById.get(fact.sourceId);
    if (body === undefined) {
      rejected.push({ fact, reason: "unknown-source" });
      continue;
    }

    // 只在它自称的那篇正文里找。在别家正文里命中不算数——
    // 那说明它挂错了源，而挂错源正是 independence 算错的起点。
    if (!body.includes(quote)) {
      rejected.push({ fact, reason: "not-verbatim" });
      continue;
    }

    kept.push(fact);
  }

  return { kept, rejected };
}
