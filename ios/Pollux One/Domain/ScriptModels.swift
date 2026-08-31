import Foundation

/// A script as authored on the Web console. iOS treats scripts as read-mostly:
/// small in-session edits happen via voice command, but long-form editing lives on Web.
struct Script: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var version: Int
    var sections: [ScriptSection]
    var updatedAt: Date
    var createdAt: Date

    var fullText: String {
        sections.map(\.fullText).joined(separator: "\n\n")
    }

    var allSentences: [Sentence] {
        sections.flatMap { $0.paragraphs.flatMap(\.sentences) }
    }
}

struct ScriptSection: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String?
    var order: Int
    var paragraphs: [Paragraph]

    var fullText: String {
        paragraphs.map(\.fullText).joined(separator: "\n")
    }
}

struct Paragraph: Identifiable, Codable, Equatable {
    let id: UUID
    var order: Int
    var sentences: [Sentence]

    var fullText: String {
        sentences.map(\.text).joined(separator: " ")
    }
}

struct Sentence: Identifiable, Codable, Equatable {
    let id: UUID
    var order: Int
    var text: String
    var tokens: [Token]

    init(id: UUID = UUID(), order: Int, text: String) {
        self.id = id
        self.order = order
        self.text = text
        self.tokens = Token.tokenize(text)
    }

    init(id: UUID, order: Int, text: String, tokens: [Token]) {
        self.id = id
        self.order = order
        self.text = text
        self.tokens = tokens
    }
}

/// The unit the alignment engine matches speech against. Roughly a word,
/// normalized for case/punctuation so fuzzy matching is cheap.
struct Token: Identifiable, Codable, Equatable {
    let id: UUID
    var index: Int
    var raw: String
    var normalized: String

    static func tokenize(_ text: String) -> [Token] {
        text
            .split(separator: " ")
            .enumerated()
            .map { index, word in
                Token(
                    id: UUID(),
                    index: index,
                    raw: String(word),
                    normalized: word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                )
            }
    }
}

/// Points at one sentence/paragraph inside a specific frozen script version.
/// Recording sessions address positions by this, never by raw offsets, so a
/// script revision mid-session can't silently invalidate a stored position.
struct ScriptAddress: Codable, Equatable {
    let scriptId: UUID
    let scriptVersion: Int
    let sectionId: UUID
    let paragraphId: UUID
    let sentenceId: UUID
}

/// A local, in-session copy of a Script frozen at RecordingSession start
/// (see SessionManager). Safe Word edits mutate this, not the Web original.
struct ScriptRevision: Identifiable, Codable, Equatable {
    let id: UUID
    var baseScript: Script
    var localSequence: Int
    var editedAt: Date

    var script: Script { baseScript }
}
