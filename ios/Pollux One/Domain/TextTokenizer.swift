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
            if character.isCJK {
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

private extension Character {
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)      // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(scalar.value) // Extension A
                || (0xF900...0xFAFF).contains(scalar.value) // Compatibility Ideographs
                || (0x3040...0x30FF).contains(scalar.value) // Hiragana / Katakana
        }
    }

    var isCJKPunctuation: Bool {
        unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)       // 。、，「」etc.
                || (0xFF00...0xFF0F).contains(scalar.value) // fullwidth ！？（）
                || (0xFF1A...0xFF20).contains(scalar.value) // fullwidth ：；＜＝＞？＠
        }
    }
}
