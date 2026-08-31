// Mirrors ios/Pollux One/Domain/ScriptModels.swift — Web and iOS read/write
// the same shape so a script synced from one renders identically on the
// other. Keep the two in sync by hand for V1; there is no shared package.

export type Sentence = {
  id: string;
  order: number;
  text: string;
};

export type Paragraph = {
  id: string;
  order: number;
  sentences: Sentence[];
};

export type ScriptSection = {
  id: string;
  title: string | null;
  order: number;
  paragraphs: Paragraph[];
};

export type Script = {
  id: string;
  title: string;
  version: number;
  sections: ScriptSection[];
  createdAt: string;
  updatedAt: string;
  progress?: {
    completedSentences: number;
    totalSentences: number;
    fractionComplete: number;
  };
};

export function scriptSentenceCount(script: Script): number {
  return script.sections.reduce(
    (sectionTotal, section) =>
      sectionTotal +
      section.paragraphs.reduce((paragraphTotal, paragraph) => paragraphTotal + paragraph.sentences.length, 0),
    0
  );
}

// Web's editor is a single flat textarea, not a rich section/paragraph UI —
// long-form structure editing isn't the point of V1. Blank lines split
// paragraphs, periods split sentences, matching the same simple heuristic
// ios/.../MockBackendClient.swift uses so both sides produce comparable trees.
export function bodyTextToParagraphs(bodyText: string): string[][] {
  return bodyText
    .split(/\n\s*\n/)
    .map((block) => block.trim())
    .filter((block) => block.length > 0)
    .map((block) =>
      block
        .split(".")
        .map((s) => s.trim())
        .filter((s) => s.length > 0)
        .map((s) => `${s}.`)
    );
}

export function scriptToBodyText(script: Script): string {
  return script.sections
    .flatMap((section) =>
      section.paragraphs.map((paragraph) => paragraph.sentences.map((s) => s.text).join(" "))
    )
    .join("\n\n");
}
