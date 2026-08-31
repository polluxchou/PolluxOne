import Foundation

/// A command recognized after the Safe Word wakes VoiceCommandEngine.
/// V1 only implements `.replaceParagraph`; the rest are modeled now so the
/// engine's dispatch surface doesn't need to change shape later.
enum VoiceCommandKind: Codable, Equatable {
    case replaceParagraph(paragraphId: UUID, newText: String)
    case repeatPreviousSentence
    case jumpToSection(sectionId: UUID)
    case pauseTeleprompter
    case resumeTeleprompter
    case hideTeleprompter
    case showTeleprompter
    case changeTextSize(delta: Int)
    case unrecognized(rawText: String)
}

struct VoiceCommand: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: VoiceCommandKind
    var transcript: String
    var recognizedAt: Date
    var state: VoiceCommandState
}

enum VoiceCommandState: String, Codable {
    case listening
    case proposed
    case confirmed
    case rejected
    case applied
}
