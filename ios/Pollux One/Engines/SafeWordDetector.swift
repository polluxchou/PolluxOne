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

    /// Minimum gap between triggers, so a recognizer that re-reports the same
    /// text (or flaps between two guesses) can't wake command mode twice for
    /// one utterance.
    private let retriggerCooldown: TimeInterval = 2.5
    private var lastTriggerAt: Date?

    /// How many times the safe word has appeared in the transcript at the
    /// point we last fired.
    ///
    /// Counting occurrences rather than diffing the text is what makes this
    /// work against real recognizer output. Transcripts are cumulative and
    /// arrive character by character: comparing lengths and searching only
    /// the newly-appended slice means the word is split across slices
    /// ("pol" | "l" | "ux") and never matches — the safe word would
    /// essentially never fire on a device. Occurrence counts are also immune
    /// to mid-string revisions, which shift every character index.
    private var triggeredOccurrences = 0

    func reset() {
        lastTriggerAt = nil
        triggeredOccurrences = 0
    }

    func ingest(transcript: SpeechTranscript) {
        let occurrences = occurrenceCount(of: safeWord, in: transcript.text)

        // A revision can remove an occurrence. Lower the watermark so a later
        // utterance still registers as new.
        if occurrences < triggeredOccurrences {
            triggeredOccurrences = occurrences
            return
        }
        guard occurrences > triggeredOccurrences else { return }

        if let lastTriggerAt,
           transcript.timestamp.timeIntervalSince(lastTriggerAt) < retriggerCooldown {
            // Don't advance the watermark: this occurrence hasn't been acted
            // on, so it can still fire once the cooldown lapses.
            return
        }

        triggeredOccurrences = occurrences
        lastTriggerAt = transcript.timestamp
        delegate?.safeWordDetectorDidDetectSafeWord(self)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        ) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
