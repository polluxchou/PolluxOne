import type { Fact, Source } from "../domain/types.js";

export interface ExtractReply {
  facts: { text: string; quote: string }[];
}

export function buildExtractPrompt(source: Source): string {
  return [
    "你是一个新闻事实抽取器。从下面这篇报道里抽出原子事实点。",
    "",
    "规则：",
    "1. 每个事实点必须附带 quote —— 从原文里**逐字**复制的一段，一个字都不能改、不能转述、不能合并。",
    "2. 只抽事实，不抽评论、预测、情绪。",
    "3. 数字、日期、机构名必须完整保留在 quote 里。",
    "4. 抽不出就返回空数组，不要编。",
    "",
    '输出 JSON：{"facts":[{"text":"事实的简述","quote":"原文逐字片段"}]}',
    "",
    "报道正文：",
    source.body,
  ].join("\n");
}

export function parseExtractReply(source: Source, reply: ExtractReply): Fact[] {
  if (!Array.isArray(reply?.facts)) {
    throw new Error(`${source.id} 的抽取结果里 facts 不是数组`);
  }

  const facts: Fact[] = [];
  for (const raw of reply.facts) {
    // 没有 quote 的事实无从校验，留着它等于在可溯源的链条上留一个洞。
    if (typeof raw?.text !== "string" || typeof raw?.quote !== "string") continue;
    if (raw.text.trim() === "" || raw.quote.trim() === "") continue;
    facts.push({
      id: `${source.id}-f${facts.length}`,
      sourceId: source.id,
      text: raw.text.trim(),
      quote: raw.quote.trim(),
    });
  }
  return facts;
}
