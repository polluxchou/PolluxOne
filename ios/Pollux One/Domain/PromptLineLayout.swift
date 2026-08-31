import Foundation

/// One laid-out visual line.
struct PromptLine: Equatable, Identifiable {
    /// Global line index. Doubles as the SwiftUI identity: the overlay renders
    /// every line and moves the container, so each line has to stay the *same*
    /// node across a scroll step. Identify them any other way and SwiftUI
    /// treats each step as a batch of inserts and removals, which animates as
    /// a cross-fade instead of a slide.
    let id: Int
    let text: String
    /// This line's range in `PromptScriptText.text`.
    let characterRange: Range<Int>
    /// Leading x of every character, plus an end sentinel — so
    /// `characterXOffsets.count == text.count + 1`.
    ///
    /// Needed because the reading cursor is character-granular but the
    /// highlight edge is drawn in points, and `progress × lineWidth` is wrong
    /// in Latin: "i" and "W" are not the same fraction of a line, so the edge
    /// visibly jitters as it crosses them.
    let characterXOffsets: [CGFloat]

    var characterCount: Int { characterRange.count }
    var width: CGFloat { characterXOffsets.last ?? 0 }
}

/// Supplies glyph advances. **Measures only — it does not break lines.**
///
/// Breaking stays in `PromptLineLayout` so it is assertable offline, on a Mac,
/// with no font installed (see `FakeTextMeasurer`). Delegating the break to
/// CoreText would buy correct Unicode line-breaking and lose the ability to
/// test the half of this that is easiest to get wrong.
protocol TextWidthMeasuring {
    /// One width per Character of `text`, in the same order.
    func characterWidths(of text: String) -> [CGFloat]
}

/// Greedy line breaking over a `PromptScriptText`.
enum PromptLineLayout {
    static func lines(
        for source: PromptScriptText,
        width: CGFloat,
        measurer: TextWidthMeasuring
    ) -> [PromptLine] {
        let characters = Array(source.text)
        guard !characters.isEmpty, width > 0 else { return [] }

        let widths = measurer.characterWidths(of: source.text)
        // A measurer that disagrees with the text it was handed would produce
        // silently wrong offsets everywhere downstream. Refuse instead.
        guard widths.count == characters.count else { return [] }

        let hardBreaks = Set(source.hardBreaks)
        var lines: [PromptLine] = []
        var start = 0

        while start < characters.count {
            var end = start
            var used: CGFloat = 0
            while end < characters.count {
                if end > start, hardBreaks.contains(end) { break }
                let extended = used + widths[end]
                // `end > start` guarantees at least one character per line, so
                // a single character wider than the column cannot loop.
                if end > start, extended > width { break }
                used = extended
                end += 1
            }

            if end < characters.count, !hardBreaks.contains(end) {
                end = adjustedBreak(
                    in: characters,
                    from: start,
                    proposed: end,
                    language: source.language
                )
            }

            lines.append(
                line(id: lines.count, characters: characters, widths: widths, range: start..<end)
            )
            start = end
        }

        return lines
    }

    /// Moves a width-driven break to a place a reader will accept.
    private static func adjustedBreak(
        in characters: [Character],
        from start: Int,
        proposed: Int,
        language: ScriptLanguage
    ) -> Int {
        switch language {
        case .latin:
            // A prompter that cuts words mid-glyph is unreadable, so fall back
            // to the last space on the line. The space stays on the line it
            // terminates, so the next line opens on a word.
            if characters[proposed].isWhitespace { return proposed + 1 }
            var candidate = proposed - 1
            while candidate > start {
                if characters[candidate].isWhitespace { return candidate + 1 }
                candidate -= 1
            }
            // One word longer than the whole column: cut it. Better a hard cut
            // than an empty line.
            return proposed

        case .cjk:
            // Chinese breaks between any two characters, with two exceptions:
            // a line may not open with closing punctuation (行首禁则), and may
            // not close with opening punctuation (行尾禁则). Shift left at most
            // twice — a run of brackets must not loop, and two is enough for
            // every real case.
            var candidate = proposed
            for _ in 0..<2 {
                let opensBadly = noLineStart.contains(characters[candidate])
                let closesBadly = candidate > start && noLineEnd.contains(characters[candidate - 1])
                guard opensBadly || closesBadly, candidate - 1 > start else { break }
                candidate -= 1
            }
            return candidate
        }
    }

    /// 行首禁则 — must not open a line.
    private static let noLineStart: Set<Character> = [
        "。", "，", "、", "；", "：", "！", "？", "）", "］", "｝", "」", "』", "〉", "》", "”", "’", "·",
        ".", ",", ";", ":", "!", "?", ")", "]", "}"
    ]

    /// 行尾禁则 — must not close a line.
    private static let noLineEnd: Set<Character> = [
        "（", "［", "｛", "「", "『", "〈", "《", "“", "‘", "(", "[", "{"
    ]

    private static func line(
        id: Int,
        characters: [Character],
        widths: [CGFloat],
        range: Range<Int>
    ) -> PromptLine {
        var offsets: [CGFloat] = [0]
        offsets.reserveCapacity(range.count + 1)
        var x: CGFloat = 0
        for index in range {
            x += widths[index]
            offsets.append(x)
        }
        // Trailing whitespace is deliberately kept in `text`: trimming it
        // would break the invariant that a line's characters are exactly its
        // characterRange, which every offset lookup downstream depends on.
        return PromptLine(
            id: id,
            text: String(characters[range]),
            characterRange: range,
            characterXOffsets: offsets
        )
    }
}
