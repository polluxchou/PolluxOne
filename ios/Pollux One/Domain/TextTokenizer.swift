import Foundation

/// Turns text into the comparison units ScriptAlignmentEngine matches on.
///
/// Space-splitting alone silently breaks CJK: Chinese has no word spaces, so a
/// whole sentence collapses into one token and matching degenerates to string
/// equality — the reading position then never advances. So CJK characters are
/// emitted individually (each Han character carries meaning on its own, and
/// per-character matching is what makes partial//misrecognized Chinese still
/// align), while space-delimited words stay whole.
enum TextTokenizer {
    static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var latinBuffer = ""

        func flushLatin() {
            let trimmed = latinBuffer.trimmingCharacters(in: .punctuationCharacters)
            if !trimmed.isEmpty { tokens.append(trimmed) }
            latinBuffer = ""
        }

        for character in text.lowercased() {
            if character.isCJKIdeographOrKana {
                flushLatin()
                tokens.append(String(character))
            } else if character.isWhitespace {
                flushLatin()
            } else if character.isCJKPunctuation {
                // Recognizers emit these inconsistently; dropping them keeps
                // "…问题。" and "…问题" scoring the same.
                flushLatin()
            } else {
                latinBuffer.append(character)
            }
        }
        flushLatin()
        return tokens
    }
}
