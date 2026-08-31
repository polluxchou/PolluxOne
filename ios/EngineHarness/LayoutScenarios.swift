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

    report.section("the tokenizer keeps its old behaviour on the shared predicates")

    report.check(TextTokenizer.tokens(in: "你好世界") == ["你", "好", "世", "界"],
                 "CJK still tokenizes per character")
    report.check(TextTokenizer.tokens(in: "问题。它们") == ["问", "题", "它", "们"],
                 "CJK punctuation is still dropped rather than emitted")
    report.check(TextTokenizer.tokens(in: "Hello, world!") == ["hello", "world"],
                 "Latin still tokenizes per word, lowercased, depunctuated")

    return (report.pass, report.fail)
}
