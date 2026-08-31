import Foundation

// Offline exercise of the prompter's typesetting layer: which script a text
// is, how a Script becomes one canonical string, and where the lines break.
//
// All three are silent-failure territory. A language misdetected by one
// percentage point flips the whole type scale and the visible row count. A
// concatenation that differs from the one used for offsets puts the reading
// cursor a few characters off — permanently, and worse the longer the script.
// A break rule that lets a line open with "。" is not a crash, it just looks
// like a bug to every reader.
//
// Widths come from FakeTextMeasurer, not a real font, so break positions can
// be asserted exactly on a Mac with no font installed.

@MainActor
func runLayoutSuite() -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("Prompter typesetting — language, canonical text, line breaks")

    report.section("language detection")

    report.check(ScriptLanguage.detect("大多数提词器都在解决错误的问题。") == .cjk,
                 "plain Chinese is CJK")
    report.check(ScriptLanguage.detect("Most teleprompters solve the wrong problem.") == .latin,
                 "plain English is Latin")
    report.check(ScriptLanguage.detect("Pollux One 从另一个问题出发。") == .cjk,
                 "Chinese prose carrying a Latin product name is still CJK")
    report.check(ScriptLanguage.detect("") == .latin,
                 "empty text does not crash and falls back to Latin")
    report.check(ScriptLanguage.detect("Shipping 十") == .latin,
                 "one stray ideogram in an English line does not flip it")

    report.section("per-language constants")

    report.check(ScriptLanguage.cjk.visibleRows == 5 && ScriptLanguage.latin.visibleRows == 6,
                 "5 visible rows in Chinese, 6 in Latin")
    report.check(ScriptLanguage.cjk.readRowsAbove == 1 && ScriptLanguage.latin.readRowsAbove == 2,
                 "1 dim history row in Chinese, 2 in Latin")
    report.check(ScriptLanguage.cjk.effectiveTextSize(base: 20) == 19,
                 "Chinese steps 20pt down to 19pt",
                 detail: "\(ScriptLanguage.cjk.effectiveTextSize(base: 20))")
    report.check(ScriptLanguage.latin.effectiveTextSize(base: 20) == 20,
                 "Latin keeps its size")
    report.check(ScriptLanguage.cjk.sentenceJoiner.isEmpty,
                 "Chinese sentences join with nothing — no space after 。")
    report.check(ScriptLanguage.latin.sentenceJoiner == " ",
                 "Latin sentences join with a space")

    report.section("canonical text is the single concatenation everything measures against")

    let chinese = makeLayoutScript([
        "大多数提词器都在解决错误的问题。它们让字变得容易读。",
        "Pollux One 从另一个问题出发。"
    ])
    let chineseText = PromptScriptText.build(chinese)

    report.check(chineseText.language == .cjk, "a Chinese script is built as CJK")
    report.check(!chineseText.text.contains("。 "),
                 "no space is inserted after a Chinese full stop",
                 detail: chineseText.text)
    report.check(chineseText.text.hasPrefix("大多数提词器都在解决错误的问题。它们"),
                 "Chinese sentences butt straight up against each other")
    report.check(chineseText.hardBreaks == [26],
                 "the paragraph boundary is recorded as an offset, not a newline",
                 detail: "\(chineseText.hardBreaks)")
    report.check(!chineseText.text.contains("\n"),
                 "canonical text holds no characters that are never read aloud")

    let chineseSentences = chinese.allSentences
    report.check(chineseText.sentenceRanges.count == chineseSentences.count,
                 "every sentence has a range")

    let firstRange = chineseText.sentenceRanges[chineseSentences[0].id]
    report.check(firstRange == 0..<16,
                 "the first sentence starts at 0",
                 detail: "\(String(describing: firstRange))")

    let rangesAgree = chineseSentences.allSatisfy { sentence in
        guard let range = chineseText.sentenceRanges[sentence.id] else { return false }
        return String(Array(chineseText.text)[range]) == sentence.text
    }
    report.check(rangesAgree,
                 "slicing canonical text by a sentence's range reproduces that sentence")

    let english = makeLayoutScript([
        "Most teleprompters solve the wrong problem. They pull your eyes away.",
        "Pollux One starts elsewhere."
    ])
    let englishText = PromptScriptText.build(english)

    report.check(englishText.language == .latin, "an English script is built as Latin")
    report.check(englishText.text.contains("wrong problem. They"),
                 "Latin sentences are joined by exactly one space",
                 detail: englishText.text)

    let englishSentences = english.allSentences
    let englishAgree = englishSentences.allSatisfy { sentence in
        guard let range = englishText.sentenceRanges[sentence.id] else { return false }
        return String(Array(englishText.text)[range]) == sentence.text
    }
    report.check(englishAgree, "Latin ranges also slice back to their sentences")

    report.check(PromptScriptText.build(makeLayoutScript([])).text.isEmpty,
                 "an empty script builds without crashing")

    report.section("a reading position becomes a character offset — with the right denominator")

    let denominatorScript = makeLayoutScript(["大多数提词器都在解决错误的问题。"])
    let denominatorText = PromptScriptText.build(denominatorScript)

    if let only = denominatorScript.allSentences.first,
       let onlyRange = denominatorText.sentenceRanges[only.id] {

        report.check(only.tokens.count == 1,
                     "Sentence.tokens collapses a whole Chinese sentence to 1 — this is the trap",
                     detail: "\(only.tokens.count)")
        report.check(denominatorText.sentenceTokenCounts[only.id] == 15,
                     "so the denominator is TextTokenizer's 15 per-character tokens instead",
                     detail: "\(String(describing: denominatorText.sentenceTokenCounts[only.id]))")

        let atStart = denominatorText.characterOffset(
            of: makePosition(only, tokenIndex: 0, in: denominatorScript)
        )
        let midway = denominatorText.characterOffset(
            of: makePosition(only, tokenIndex: 7, in: denominatorScript)
        )
        let nearEnd = denominatorText.characterOffset(
            of: makePosition(only, tokenIndex: 14, in: denominatorScript)
        )

        report.check(atStart == 0,
                     "token 0 maps to the sentence's own start offset",
                     detail: "\(String(describing: atStart))")
        report.check((midway ?? 0) > 7 && (midway ?? 0) < 8,
                     "token 7 of 15 lands about halfway through the 16 characters",
                     detail: "\(String(describing: midway))")
        report.check((nearEnd ?? 0) < Double(onlyRange.upperBound),
                     "the last token has not yet reached the end of the sentence — a wrong denominator pins it there",
                     detail: "\(String(describing: nearEnd)) vs \(onlyRange.upperBound)")
    } else {
        report.check(false, "the denominator fixture has a sentence with a range")
    }

    report.section("line breaking — Latin never cuts a word")

    let measurer = FakeTextMeasurer(em: 10)
    let enSource = PromptScriptText.build(
        makeLayoutScript(["Most teleprompters solve the wrong problem."])
    )
    let enLines = PromptLineLayout.lines(for: enSource, width: 100, measurer: measurer)

    report.check(enLines.count == 3, "43 characters at 20 per line is 3 lines",
                 detail: "\(enLines.map(\.text))")
    report.check(enLines.first?.text == "Most teleprompters ",
                 "the break falls back to the last space, and the space stays on the line it ends",
                 detail: "\(String(describing: enLines.first?.text))")
    report.check(enLines.count > 1 && enLines[1].text == "solve the wrong ",
                 "so the next line opens on a word, never on a space")
    report.check(enLines.allSatisfy { !$0.text.hasPrefix(" ") },
                 "no line begins with whitespace")
    report.check(enLines.map(\.text).joined() == enSource.text,
                 "the lines concatenate back to exactly the canonical text")
    report.check(zip(enLines, enLines.dropFirst()).allSatisfy {
                     $0.characterRange.upperBound == $1.characterRange.lowerBound
                 },
                 "character ranges are contiguous with no gap and no overlap")
    report.check(enLines.enumerated().allSatisfy { $0.offset == $0.element.id },
                 "a line's id is its global index — the view relies on this for identity")

    report.section("line breaking — a word longer than the line still has to be cut")

    let longWord = PromptScriptText.build(makeLayoutScript(["Aaaaaaaaaaaaaaaaaaaaaaaaa."]))
    let longWordLines = PromptLineLayout.lines(for: longWord, width: 50, measurer: measurer)

    report.check(longWordLines.count == 3,
                 "26 characters at 10 per line is 3 lines",
                 detail: "\(longWordLines.map(\.text))")
    report.check(longWordLines.allSatisfy { !$0.text.isEmpty },
                 "no empty line — an empty line here means the layout loop cannot terminate")

    report.section("line breaking — CJK avoids opening a line with closing punctuation")

    let cjkSource = PromptScriptText.build(makeLayoutScript(["大多数提词器都在解决。它们让字。"]))
    let cjkLines = PromptLineLayout.lines(for: cjkSource, width: 100, measurer: measurer)

    report.check(cjkLines.count == 2, "16 CJK characters at 10 per line is 2 lines",
                 detail: "\(cjkLines.map(\.text))")
    report.check(cjkLines.first?.text == "大多数提词器都在解",
                 "the break shifted one character left rather than let 。 open a line",
                 detail: "\(String(describing: cjkLines.first?.text))")
    report.check(cjkLines.count > 1 && cjkLines[1].text.hasPrefix("决。"),
                 "the deferred character carries the punctuation with it")
    report.check(cjkLines.allSatisfy { !"。，、；：！？）」".contains($0.text.first ?? "字") },
                 "no line opens on closing punctuation")

    report.section("line breaking — a Latin word inside a CJK script is not cut in half")

    // The app's own sample script opens exactly like this, so this is the
    // common case rather than an edge one.
    let mixed = PromptScriptText.build(makeLayoutScript(["Pollux One 从另一个问题出发。"]))

    report.check(mixed.language == .cjk,
                 "a Chinese paragraph carrying a Latin product name is still CJK")

    // 45pt at em 10: the width-driven break lands on the "e" of "One".
    let mixedLines = PromptLineLayout.lines(for: mixed, width: 45, measurer: measurer)

    report.check(mixedLines.first?.text == "Pollux ",
                 "the break falls back to the start of the Latin word instead of splitting it",
                 detail: "\(mixedLines.map(\.text))")
    report.check(mixedLines.count > 1 && mixedLines[1].text.hasPrefix("One"),
                 "so the next line opens on the whole word")

    // A word wider than the whole column still has to be cut: falling back
    // past the line's start would leave an empty line and cut it anyway.
    let tooNarrow = PromptLineLayout.lines(for: mixed, width: 25, measurer: measurer)

    report.check(tooNarrow.first?.text == "Pollu",
                 "a Latin word wider than the column is still cut",
                 detail: "\(tooNarrow.map(\.text))")

    report.section("line breaking — paragraph boundaries are hard")

    let twoParagraphs = PromptScriptText.build(makeLayoutScript(["短句。", "第二段开始。"]))
    let paragraphLines = PromptLineLayout.lines(for: twoParagraphs, width: 1000, measurer: measurer)

    report.check(paragraphLines.count == 2,
                 "both paragraphs fit on one line by width, and are still two lines",
                 detail: "\(paragraphLines.map(\.text))")
    report.check(paragraphLines.first?.text == "短句。",
                 "the first line stops at the paragraph boundary")

    report.section("character x offsets — the highlight edge lands on a real glyph boundary")

    guard let firstEnLine = enLines.first else {
        report.check(false, "there is a first Latin line to measure")
        return (report.pass, report.fail)
    }

    report.check(firstEnLine.characterXOffsets.count == firstEnLine.text.count + 1,
                 "one offset per character plus an end sentinel",
                 detail: "\(firstEnLine.characterXOffsets.count) for \(firstEnLine.text.count) chars")
    report.check(firstEnLine.characterXOffsets.first == 0,
                 "the first character starts at x = 0")
    report.check(firstEnLine.characterXOffsets.last == 95,
                 "19 Latin characters at 5pt each is 95pt",
                 detail: "\(String(describing: firstEnLine.characterXOffsets.last))")
    report.check(zip(firstEnLine.characterXOffsets, firstEnLine.characterXOffsets.dropFirst())
                    .allSatisfy { $0 <= $1 },
                 "offsets are monotonically non-decreasing")

    report.section("re-layout — the same text at a different width")

    let narrow = PromptLineLayout.lines(for: enSource, width: 60, measurer: measurer)

    report.check(narrow.count > enLines.count,
                 "a narrower column produces more lines",
                 detail: "\(narrow.count) vs \(enLines.count)")
    report.check(narrow.map(\.text).joined() == enSource.text,
                 "and still concatenates back to the same canonical text")
    report.check(narrow.last?.characterRange.upperBound == enLines.last?.characterRange.upperBound,
                 "the total character count is width-independent — this is what lets the cursor survive")

    report.section("the tokenizer keeps its old behaviour on the shared predicates")

    report.check(TextTokenizer.tokens(in: "你好世界") == ["你", "好", "世", "界"],
                 "CJK still tokenizes per character")
    report.check(TextTokenizer.tokens(in: "问题。它们") == ["问", "题", "它", "们"],
                 "CJK punctuation is still dropped rather than emitted")
    report.check(TextTokenizer.tokens(in: "Hello, world!") == ["hello", "world"],
                 "Latin still tokenizes per word, lowercased, depunctuated")

    return (report.pass, report.fail)
}

/// A ReadingPosition aimed at one sentence, as the alignment engine would
/// emit it. `tokenIndex` indexes `TextTokenizer.tokens(in: sentence.text)` —
/// the same tokenization `SlidingWindowAlignmentEngine` counts in.
@MainActor
func makePosition(_ sentence: Sentence, tokenIndex: Int, in script: Script) -> ReadingPosition {
    let section = script.sections[0]
    let paragraph = section.paragraphs.first { paragraph in
        paragraph.sentences.contains { $0.id == sentence.id }
    } ?? section.paragraphs[0]

    return ReadingPosition(
        address: ScriptAddress(
            scriptId: script.id,
            scriptVersion: script.version,
            sectionId: section.id,
            paragraphId: paragraph.id,
            sentenceId: sentence.id
        ),
        tokenIndexInSentence: tokenIndex,
        confidence: 0.9,
        updatedAt: Date()
    )
}

/// Builds a Script the way the mock backend does — one section, one paragraph
/// per string, sentences split by the shared splitter — so the scenarios
/// exercise the same shape the app actually loads.
@MainActor
func makeLayoutScript(_ paragraphs: [String]) -> Script {
    let built = paragraphs.enumerated().map { index, text in
        Paragraph(id: UUID(), order: index, sentences: SentenceSplitter.sentences(from: text))
    }
    return Script(
        id: UUID(),
        title: "Layout fixture",
        version: 1,
        sections: [ScriptSection(id: UUID(), title: nil, order: 0, paragraphs: built)],
        updatedAt: Date(),
        createdAt: Date()
    )
}
