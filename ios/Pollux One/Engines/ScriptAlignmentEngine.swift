import Foundation

/// Speech-to-Script Alignment Engine.
///
/// Input: a frozen Script plus a stream of (partial and final) speech
/// transcripts. Output: where in the script the reader currently is, with a
/// confidence score. Nothing here knows about UI, AVFoundation, or the HUD —
/// TeleprompterEngine translates ReadingPosition into display state.
///
/// V1 implementation (`SlidingWindowAlignmentEngine`) is deliberately simple:
/// normalized-token overlap scored against a small window of candidate
/// sentences around the current position. It is NOT a state machine that
/// just advances on every word — see the window logic below for how it
/// tolerates repeats, skips, and misreads. The protocol boundary is what
/// lets a future LLM-assisted or on-device-model implementation drop in
/// without changing TeleprompterEngine or RecordingViewModel.
protocol ScriptAlignmentEngine: AnyObject {
    func reset(script: Script, startingAt address: ScriptAddress?)
    /// Feed the latest transcript (partial or final) covering everything
    /// spoken so far in the current take. Returns nil when confidence is too
    /// low to move from the last known-good position.
    func ingest(transcript: SpeechTranscript) -> ReadingPosition?
}

final class SlidingWindowAlignmentEngine: ScriptAlignmentEngine {
    /// How far back/forward from the current sentence we'll consider a match,
    /// so a repeated line or a skipped one is still findable.
    private let lookBehind = 2
    private let lookAhead = 5
    private let minimumConfidence = 0.34

    private var script: Script?
    private var flatSentences: [(address: ScriptAddress, sentence: Sentence)] = []
    private var currentIndex = 0
    private var lastEmittedText = ""

    func reset(script: Script, startingAt address: ScriptAddress?) {
        self.script = script
        flatSentences = script.sections.flatMap { section in
            section.paragraphs.flatMap { paragraph in
                paragraph.sentences.map { sentence in
                    (
                        ScriptAddress(
                            scriptId: script.id,
                            scriptVersion: script.version,
                            sectionId: section.id,
                            paragraphId: paragraph.id,
                            sentenceId: sentence.id
                        ),
                        sentence
                    )
                }
            }
        }
        currentIndex = 0
        if let address, let match = flatSentences.firstIndex(where: { $0.address.sentenceId == address.sentenceId }) {
            currentIndex = match
        }
        lastEmittedText = ""
    }

    func ingest(transcript: SpeechTranscript) -> ReadingPosition? {
        guard !flatSentences.isEmpty, transcript.text != lastEmittedText else { return nil }
        lastEmittedText = transcript.text

        // Speech results are cumulative for the whole take; only the tail is
        // relevant to "where are we right now".
        let spokenTail = normalizedTokens(of: transcript.text).suffix(12)
        guard !spokenTail.isEmpty else { return nil }

        let windowStart = max(0, currentIndex - lookBehind)
        let windowEnd = min(flatSentences.count - 1, currentIndex + lookAhead)

        var bestIndex = currentIndex
        var bestScore = 0.0
        var bestTokenOffset = 0

        for index in windowStart...windowEnd {
            let candidateTokens = normalizedTokens(of: flatSentences[index].sentence.text)
            guard !candidateTokens.isEmpty else { continue }
            let (score, offset) = overlapScore(spoken: Array(spokenTail), candidate: candidateTokens)
            // Ties favor the earliest (least-jumpy) candidate.
            if score > bestScore {
                bestScore = score
                bestIndex = index
                bestTokenOffset = offset
            }
        }

        guard bestScore >= minimumConfidence else {
            return currentPosition(confidence: bestScore)
        }

        currentIndex = bestIndex
        return currentPosition(confidence: bestScore, tokenOffset: bestTokenOffset)
    }

    private func currentPosition(confidence: Double, tokenOffset: Int = 0) -> ReadingPosition {
        let entry = flatSentences[currentIndex]
        return ReadingPosition(
            address: entry.address,
            tokenIndexInSentence: tokenOffset,
            confidence: confidence,
            updatedAt: Date()
        )
    }

    /// Fraction of `spoken` tokens found in `candidate`, in order, allowing
    /// gaps (a cheap longest-common-subsequence ratio). Returns the index in
    /// `candidate` of the last matched token, used as the within-sentence
    /// reading position.
    private func overlapScore(spoken: [String], candidate: [String]) -> (Double, Int) {
        var candidateCursor = 0
        var matched = 0
        var lastMatchIndex = 0
        for token in spoken {
            if let foundOffset = candidate[candidateCursor...].firstIndex(where: { $0 == token }) {
                matched += 1
                candidateCursor = foundOffset + 1
                lastMatchIndex = foundOffset
            }
        }
        guard !spoken.isEmpty else { return (0, 0) }
        return (Double(matched) / Double(spoken.count), lastMatchIndex)
    }

    private func normalizedTokens(of text: String) -> [String] {
        text
            .lowercased()
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
