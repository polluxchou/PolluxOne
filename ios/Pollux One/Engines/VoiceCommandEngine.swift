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
    /// Transcript text as it stood when the safe word fired. Commands are
    /// parsed from what comes *after* this.
    private var transcriptBaseline: String = ""

    func beginListening(currentParagraphId: UUID, spokenTextSoFar: String, now: Date = Date()) {
        self.currentParagraphId = currentParagraphId
        self.transcriptBaseline = spokenTextSoFar
        listenDeadline = now.addingTimeInterval(listenTimeout)
        state = .listeningForCommand
    }

    func ingest(transcript: SpeechTranscript) {
        guard case .listeningForCommand = state else { return }
        if let deadline = listenDeadline, transcript.timestamp > deadline {
            state = .idle
            return
        }
        guard transcript.isFinal else { return }

        let command = parse(commandText(from: transcript.text))
        switch command.kind {
        case .unrecognized:
            // The speaker woke command mode and then said nothing actionable
            // ("Pollux… uh, never mind"). Drop back to idle rather than
            // putting a confirmation sheet over the camera with junk in it.
            state = .idle
        default:
            state = .awaitingConfirmation(command)
        }
    }

    /// The command is whatever was said *after* the safe word. Transcripts are
    /// cumulative for the whole take, so parsing `transcript.text` wholesale
    /// finds the earliest trigger phrase anywhere in the session — including
    /// one that occurs in the script being read.
    private func commandText(from fullTranscript: String) -> String {
        if fullTranscript.hasPrefix(transcriptBaseline) {
            return String(fullTranscript.dropFirst(transcriptBaseline.count))
        }
        // The recognizer revised something inside the baseline. Fall back to
        // dropping the longest common prefix, which still removes almost all
        // of the already-spoken text.
        var index = fullTranscript.startIndex
        var baselineIndex = transcriptBaseline.startIndex
        while index < fullTranscript.endIndex,
              baselineIndex < transcriptBaseline.endIndex,
              fullTranscript[index] == transcriptBaseline[baselineIndex] {
            index = fullTranscript.index(after: index)
            baselineIndex = transcriptBaseline.index(after: baselineIndex)
        }
        return String(fullTranscript[index...])
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

    /// Phrases that introduce a replacement, longest first so "把这段改成"
    /// wins over the bare "改成" it contains. Not an intent model — V1 only
    /// has to recognise the handful of ways a speaker actually says this, and
    /// the state machine around it is what's built to outlive this parser.
    private static let replacementTriggers = [
        "change this paragraph to",
        "replace this paragraph with",
        "change this to",
        "change it to",
        "replace this with",
        "replace it with",
        "make this say",
        "把这一段改成",
        "把这一段换成",
        "把这段改成",
        "把这段换成",
        "改成",
        "换成"
    ]

    private func parse(_ text: String) -> VoiceCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Search the original string, not a lowercased copy: case folding can
        // change length, and the resulting indices then don't line up with the
        // text we slice the replacement out of.
        let match = Self.replacementTriggers.lazy
            .compactMap { trimmed.range(of: $0, options: [.caseInsensitive]) }
            .first

        guard let range = match, let paragraphId = currentParagraphId else {
            return unrecognized(trimmed)
        }

        let newText = String(trimmed[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。"))
        guard !newText.isEmpty else { return unrecognized(trimmed) }

        return VoiceCommand(
            id: UUID(),
            kind: .replaceParagraph(paragraphId: paragraphId, newText: newText),
            transcript: trimmed,
            recognizedAt: Date(),
            state: .proposed
        )
    }

    private func unrecognized(_ text: String) -> VoiceCommand {
        VoiceCommand(
            id: UUID(),
            kind: .unrecognized(rawText: text),
            transcript: text,
            recognizedAt: Date(),
            state: .rejected
        )
    }
}
