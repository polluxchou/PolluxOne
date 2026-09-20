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
    "3. 也不抽**报道行为本身**——谁查阅了什么材料、哪家媒体的记者到了现场、本报向谁求证过，",
    "   这些都是采访过程。它们确实是事实，但是关于这篇报道怎么做出来的事实，与新闻无关。",
    "   分界线：动作的发出者是**新闻当事方**就抽，是**报道这件事的媒体或其记者**就不抽。",
    "   同一个发布会，当事方开它是新闻，记者去听它不是。",
    "",
    "   ✗「白石湾日报查阅了公报全文以及随附的三份附件」——报社自己的工作流程",
    "   ✗「芜洲晚报驻外记者参加了公报发布会并在现场提问」——记者到场不是新闻",
    "   ✗「本报记者多次致电该公司求证」——求证这个动作不抽；对方真答了什么才抽，抽的是回答的内容",
    "   ✓「央行召开发布会宣布下调存款准备金率 0.5 个百分点」——发布会是新闻事件本身",
    "   ✓「该公司发表声明否认裁员」——当事方的动作，换谁来报道都成立",
    "",
    "4. 数字、日期、机构名必须完整保留在 quote 里。",
    "5. 抽不出就返回空数组，不要编。",
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
