import Foundation

/// Which script the prompter is rendering, and everything that follows from
/// it: type scale, line height, how sentences join, what counts as a normal
/// reading speed, how many rows are visible.
///
/// Detected from content rather than a locale field on Script, because a
/// single script can legitimately mix the two — Chinese prose naming an
/// English product is still Chinese to lay out.
///
/// This consolidates two copies of the CJK test that had drifted apart:
/// `TeleprompterOverlayView` counted three code-point ranges (including CJK
/// punctuation), `TextTokenizer` used a four-range Character extension
/// (including kana and compatibility ideographs, excluding punctuation).
/// One definition now, and the tokenizer keeps its two-predicate split
/// because it treats ideographs and punctuation differently.
enum ScriptLanguage: Equatable {
    case cjk
    case latin

    /// A fifth of the text being CJK is enough. Mixed-script scripts in
    /// practice are Chinese with Latin names sprinkled in, and those must lay
    /// out as Chinese; the reverse — English with one stray ideogram — stays
    /// Latin at this threshold.
    static func detect(_ text: String) -> ScriptLanguage {
        guard !text.unicodeScalars.isEmpty else { return .latin }
        let cjkCount = text.unicodeScalars.count { scalar in
            scalar.isCJKIdeographOrKana || scalar.isCJKPunctuation
        }
        return Double(cjkCount) / Double(text.unicodeScalars.count) > 0.2 ? .cjk : .latin
    }

    /// Chinese takes no space after 。; Latin needs one between sentences.
    var sentenceJoiner: String {
        self == .cjk ? "" : " "
    }

    /// The design spec gives Chinese its own type scale (小/中/大 = 16/18/21
    /// against the Latin 17/19/22): CJK glyphs have a larger visual body, so
    /// matching Latin metrics reads as cramped.
    func effectiveTextSize(base: CGFloat) -> CGFloat {
        self == .cjk ? (base * 18.0 / 19.0).rounded() : base
    }

    /// Looser for CJK for the same reason.
    var lineHeightMultiple: CGFloat {
        self == .cjk ? 1.6 : 1.5
    }

    /// Seed reading speed in characters per second, before anything has been
    /// measured. 5 字/秒 is 300 字/分, an unhurried on-camera delivery;
    /// 16 chars/sec is about 190 wpm.
    var defaultCharactersPerSecond: Double {
        self == .cjk ? 5.0 : 16.0
    }

    /// A measured rate is clamped to this. One misrecognized burst can
    /// otherwise produce a sample an order of magnitude off, and the prompter
    /// would sprint or stall on it.
    var rateBounds: ClosedRange<Double> {
        self == .cjk ? 2.0...12.0 : 6.0...40.0
    }

    /// Dim already-read rows above the highlight band. Two Latin rows hold
    /// about as much text as one Chinese row, so Latin gets two.
    var readRowsAbove: Int {
        self == .cjk ? 1 : 2
    }

    /// Total rows in the fixed window. readRowsAbove + 2 band rows + 2 ahead.
    var visibleRows: Int {
        readRowsAbove + 4
    }
}

extension Unicode.Scalar {
    /// Ideographs and kana — the characters that carry meaning one at a time,
    /// which is why the tokenizer emits them individually.
    var isCJKIdeographOrKana: Bool {
        (0x4E00...0x9FFF).contains(value)        // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(value) // Extension A
            || (0xF900...0xFAFF).contains(value) // Compatibility Ideographs
            || (0x3040...0x30FF).contains(value) // Hiragana / Katakana
    }

    /// Kept separate from the above: recognizers emit these inconsistently,
    /// so the tokenizer drops them, while language detection counts them.
    var isCJKPunctuation: Bool {
        (0x3000...0x303F).contains(value)        // 。、，「」etc.
            || (0xFF00...0xFF0F).contains(value) // fullwidth ！？（）
            || (0xFF1A...0xFF20).contains(value) // fullwidth ：；＜＝＞？＠
    }
}

extension Character {
    var isCJKIdeographOrKana: Bool {
        unicodeScalars.contains(where: \.isCJKIdeographOrKana)
    }

    var isCJKPunctuation: Bool {
        unicodeScalars.contains(where: \.isCJKPunctuation)
    }
}
