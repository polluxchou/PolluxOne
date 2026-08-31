import Foundation

/// Turns a paragraph of prose into the sentences the teleprompter advances
/// through. One shared implementation because every path that builds a
/// Paragraph — the mock backend, a Safe Word replacement, a Web sync — has to
/// agree on sentence boundaries, or the same text would produce different
/// reading positions depending on where it entered the app.
///
/// Handles CJK terminators (。！？) alongside ASCII ones: a Chinese script split
/// only on "." comes back as a single giant sentence, leaving the prompter
/// nothing to advance through.
enum SentenceSplitter {
    private static let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]

    static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if terminators.contains(character) {
                append(current, to: &sentences)
                current = ""
            }
        }
        append(current, to: &sentences)
        return sentences
    }

    /// Convenience for the common "text -> ordered Sentence values" step.
    static func sentences(from text: String) -> [Sentence] {
        split(text).enumerated().map { Sentence(order: $0.offset, text: $0.element) }
    }

    private static func append(_ candidate: String, to sentences: inout [String]) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
    }
}
