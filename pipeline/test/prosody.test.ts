import { expect, test } from "vitest";
import { breathMarks, DEFAULT_CHARS_PER_SECOND, detectLanguage, estimateSeconds } from "../src/domain/prosody.js";

test("language comes from the share of CJK characters", () => {
  expect(detectLanguage("央行今天突然出手了")).toBe("cjk");
  expect(detectLanguage("The central bank moved today")).toBe("latin");
  expect(detectLanguage("央行 announced 降准")).toBe("cjk");
});

test("seconds come from the injected rate, not a guess", () => {
  expect(estimateSeconds("十个字的一句话", 5)).toBeCloseTo(1.4, 5);
  expect(estimateSeconds("十个字的一句话", 10)).toBeCloseTo(0.7, 5);
});

test("punctuation and spaces do not take time to read", () => {
  expect(estimateSeconds("央行，出手。", 5)).toBeCloseTo(estimateSeconds("央行出手", 5), 5);
});

test("with no rate on file, the language default is used", () => {
  expect(estimateSeconds("央行今天突然出手了", DEFAULT_CHARS_PER_SECOND.cjk)).toBeCloseTo(9 / 5.5, 5);
});

test("a sentence-final stop is a long breath, an internal comma a short one", () => {
  // 「，」在 下0 调1 准2 备3 金4 率5 ，6 —— charOffset 是 6
  expect(breathMarks(["央行今天突然出手了。", "下调准备金率，三月生效。"])).toEqual([
    { sentenceIndex: 0, kind: "long" },
    { sentenceIndex: 1, kind: "short", charOffset: 6 },
    { sentenceIndex: 1, kind: "long" },
  ]);
});

test("a sentence with no terminal punctuation still gets a long breath after it", () => {
  expect(breathMarks(["央行今天突然出手了"])).toEqual([{ sentenceIndex: 0, kind: "long" }]);
});
