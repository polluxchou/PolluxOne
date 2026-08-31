import Foundation

enum VoiceCommandEngineState: Equatable {
    case idle
    /// Safe Word heard, waiting for the command sentence itself.
    case listeningForCommand
    /// Parsed a command and it's waiting for the user to confirm out loud
    /// or via UI before Script mutates.
    case awaitingConfirmation(VoiceCommand)
}

protocol VoiceCommandEngineDelegate: AnyObject {
    func voiceCommandEngine(_ engine: VoiceCommandEngine, didChangeState state: VoiceCommandEngineState)
    func voiceCommandEngine(_ engine: VoiceCommandEngine, didConfirm command: VoiceCommand)
}

/// Dispatches what happens after SafeWordDetector fires. V1 only implements
/// `.replaceParagraph`, matched against a couple of phrasings a speaker would
/// actually use ("change this paragraph to...", "replace it with..."). This
/// is intentionally a thin parser, not an NLU model — the state machine
/// around it (listening -> proposed -> confirmed -> applied) is the part
/// meant to survive a smarter parser replacing this logic later.
@MainActor
final class VoiceCommandEngine {
    weak var delegate: VoiceCommandEngineDelegate?

    private(set) var state: VoiceCommandEngineState = .idle {
        didSet { delegate?.voiceCommandEngine(self, didChangeState: state) }
    }

    /// How long we wait for a command sentence after the Safe Word before
    /// giving up and returning to idle.
    private let listenTimeout: TimeInterval = 8
    private var listenDeadline: Date?
    private var currentParagraphId: UUID?

    func beginListening(currentParagraphId: UUID) {
        self.currentParagraphId = currentParagraphId
        listenDeadline = Date().addingTimeInterval(listenTimeout)
        state = .listeningForCommand
    }

    func ingest(transcript: SpeechTranscript) {
        guard case .listeningForCommand = state else { return }
        if let deadline = listenDeadline, transcript.timestamp > deadline {
            state = .idle
            return
        }
        guard transcript.isFinal, let command = parse(transcript.text) else { return }
        state = .awaitingConfirmation(command)
    }

    func confirm() {
        guard case .awaitingConfirmation(var command) = state else { return }
        command.state = .confirmed
        delegate?.voiceCommandEngine(self, didConfirm: command)
        state = .idle
    }

    func reject() {
        state = .idle
    }

    private func parse(_ text: String) -> VoiceCommand? {
        let lowered = text.lowercased()
        let triggers = ["change this to", "change it to", "replace this with", "replace it with", "make this say"]
        guard let trigger = triggers.first(where: { lowered.contains($0) }),
              let range = lowered.range(of: trigger),
              let paragraphId = currentParagraphId else {
            return VoiceCommand(
                id: UUID(),
                kind: .unrecognized(rawText: text),
                transcript: text,
                recognizedAt: Date(),
                state: .rejected
            )
        }
        let newText = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return nil }
        return VoiceCommand(
            id: UUID(),
            kind: .replaceParagraph(paragraphId: paragraphId, newText: newText),
            transcript: text,
            recognizedAt: Date(),
            state: .proposed
        )
    }
}
