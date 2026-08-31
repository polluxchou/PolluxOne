import Foundation

protocol SafeWordDetectorDelegate: AnyObject {
    func safeWordDetectorDidDetectSafeWord(_ detector: SafeWordDetector)
}

/// Listens to the same transcript stream ScriptAlignmentEngine reads and
/// watches for the configured Safe Word ("Pollux" by default). Kept separate
/// from VoiceCommandEngine on purpose: this file only ever answers "was the
/// word just said", and has no idea what happens after — that dispatch logic
/// lives in VoiceCommandEngine so the two can evolve independently (e.g. a
/// future on-device wake-word model would only replace this file).
final class SafeWordDetector {
    weak var delegate: SafeWordDetectorDelegate?

    var safeWord: String = "pollux" {
        didSet { safeWord = safeWord.lowercased() }
    }

    /// Minimum gap between triggers so one utterance of the word doesn't fire
    /// twice as partial results keep refining.
    private let retriggerCooldown: TimeInterval = 2.5
    private var lastTriggerAt: Date?
    private var lastConsumedLength = 0

    func reset() {
        lastTriggerAt = nil
        lastConsumedLength = 0
    }

    func ingest(transcript: SpeechTranscript) {
        let normalized = transcript.text.lowercased()
        guard normalized.count >= lastConsumedLength else {
            // Recognizer restarted / transcript shrank; don't misread old state.
            lastConsumedLength = 0
            return
        }

        let newSuffix = String(normalized.suffix(normalized.count - lastConsumedLength))
        lastConsumedLength = normalized.count

        guard newSuffix.contains(safeWord) else { return }

        if let lastTriggerAt, transcript.timestamp.timeIntervalSince(lastTriggerAt) < retriggerCooldown {
            return
        }
        lastTriggerAt = transcript.timestamp
        delegate?.safeWordDetectorDidDetectSafeWord(self)
    }
}
