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
    /// The in-sentence token index last *earned* by a confident match.
    ///
    /// Held because "last known-good position" has to mean the whole position.
    /// The low-confidence branch used to fall through to a `tokenOffset`
    /// defaulting to 0, so a weak result reported the current sentence — true —
    /// paired with its *start* — invented. Nothing read that field until the
    /// fixed-window prompter made it load-bearing, and then one cough was
    /// enough to hurt twice over: `ReadingPacer.correct` pulled the cursor a
    /// quarter of the way back towards the sentence start (or seeked backwards
    /// outright), and it moved `lastTruth` back with it, dropping the lookahead
    /// ceiling so dead reckoning could not climb out again. Measured across
    /// three noisy results while the reader kept reading: 73.6 -> 55.2 -> 37.4.
    private var lastTokenOffset = 0
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
        // A resume address names a sentence, not a token inside it, so the only
        // honest in-sentence offset for a fresh take is its start.
        lastTokenOffset = 0
        lastEmittedText = ""
    }

    func ingest(transcript: SpeechTranscript) -> ReadingPosition? {
        guard !flatSentences.isEmpty, transcript.text != lastEmittedText else { return nil }
        lastEmittedText = transcript.text

        let windowStart = max(0, currentIndex - lookBehind)
        let windowEnd = min(flatSentences.count - 1, currentIndex + lookAhead)

        let candidates: [(index: Int, tokens: [String])] = (windowStart...windowEnd).map {
            ($0, normalizedTokens(of: flatSentences[$0].sentence.text))
        }

        // Speech results are cumulative for the whole take; only the tail is
        // relevant to "where are we right now". The tail has to cover about
        // one sentence, and sentence length in tokens varies wildly between
        // space-delimited and per-character CJK text — so size it from the
        // candidates in play rather than a fixed count.
        let longestCandidate = candidates.map(\.tokens.count).max() ?? 12
        let tailLength = min(64, max(12, longestCandidate + 4))
        let spokenTail = Array(normalizedTokens(of: transcript.text).suffix(tailLength))
        guard !spokenTail.isEmpty else { return nil }

        var bestIndex = currentIndex
        var bestScore = 0.0
        var bestTokenOffset = 0

        for candidate in candidates {
            guard !candidate.tokens.isEmpty else { continue }
            let (score, offset) = overlapScore(spoken: spokenTail, candidate: candidate.tokens)
            // Ties favor the earliest (least-jumpy) candidate.
            if score > bestScore {
                bestScore = score
                bestIndex = candidate.index
                bestTokenOffset = offset
            }
        }

        guard bestScore >= minimumConfidence else {
            // Nothing in the window owns what was just said — an ad-lib, a
            // stumble, a cough, a passing siren. Hold the last position we
            // actually earned, in both of its coordinates.
            return currentPosition(confidence: bestScore, tokenOffset: lastTokenOffset)
        }

        currentIndex = bestIndex
        lastTokenOffset = bestTokenOffset
        return currentPosition(confidence: bestScore, tokenOffset: bestTokenOffset)
    }

    /// `tokenOffset` has no default on purpose: the default of 0 it used to
    /// carry is what let the low-confidence branch quietly report a fabricated
    /// in-sentence position. Both callers now have to say which offset they
    /// mean.
    private func currentPosition(confidence: Double, tokenOffset: Int) -> ReadingPosition {
        let entry = flatSentences[currentIndex]
        return ReadingPosition(
            address: entry.address,
            tokenIndexInSentence: tokenOffset,
            confidence: confidence,
            updatedAt: Date()
        )
    }

    /// How many of the most recent spoken tokens decide which sentence is
    /// being read. Small on purpose: this is the term that lets the prompter
    /// move onto a line as soon as the reader *starts* it.
    private let recentTokenWindow = 6

    /// Scores how likely `candidate` is the sentence being read right now.
    ///
    /// Normalizing by the spoken tail (the obvious approach) is wrong twice
    /// over: the tail deliberately spans more than one sentence, so every
    /// candidate scores low however cleanly it was read. Two terms instead:
    ///
    /// - **coverage** — how much of the candidate has been spoken, in order
    ///   and allowing gaps, so dropped or misrecognized words still match.
    /// - **ownership** — how much of what was *just* said belongs to this
    ///   candidate.
    ///
    /// Ownership is the load-bearing half. With coverage alone, a fully-read
    /// sentence outscores the one being started, so the highlight only
    /// advances after each line is finished — leaving the reader looking at a
    /// stale line, which is the exact problem this product exists to fix.
    /// Weighting them equally means six words into the next sentence, that
    /// sentence already wins, while a repeated line still holds (its
    /// ownership stays high) and unrelated speech moves nothing (no candidate
    /// owns it, so the current line keeps a bare-majority score).
    ///
    /// Coverage matching runs backwards to find the *latest* occurrence: when
    /// a line appears twice in the tail, the second reading is the live one.
    ///
    /// Returns the score plus the furthest candidate token reached, which
    /// becomes `ReadingPosition.tokenIndexInSentence`.
    private func overlapScore(spoken: [String], candidate: [String]) -> (Double, Int) {
        guard !spoken.isEmpty, !candidate.isEmpty else { return (0, 0) }

        var tailCursor = spoken.count - 1
        var matched = 0
        var furthestCandidateIndex = 0
        var sawMatch = false

        for candidateIndex in stride(from: candidate.count - 1, through: 0, by: -1) {
            guard tailCursor >= 0 else { break }
            guard let found = spoken[...tailCursor].lastIndex(of: candidate[candidateIndex]) else { continue }
            matched += 1
            if !sawMatch {
                sawMatch = true
                furthestCandidateIndex = candidateIndex
            }
            tailCursor = found - 1
        }

        let coverage = Double(matched) / Double(candidate.count)
        let ownership = ownershipOfRecentSpeech(spoken: spoken, candidate: candidate)
        guard matched > 0 || ownership > 0 else { return (0, 0) }

        return (0.5 * coverage + 0.5 * ownership, furthestCandidateIndex)
    }

    /// Fraction of the last `recentTokenWindow` spoken tokens that appear, in
    /// order, in `candidate`.
    private func ownershipOfRecentSpeech(spoken: [String], candidate: [String]) -> Double {
        let recent = spoken.suffix(recentTokenWindow)
        guard !recent.isEmpty else { return 0 }

        var candidateCursor = 0
        var owned = 0
        for token in recent {
            guard candidateCursor < candidate.count else { break }
            if let found = candidate[candidateCursor...].firstIndex(of: token) {
                owned += 1
                candidateCursor = found + 1
            }
        }
        return Double(owned) / Double(recent.count)
    }

    private func normalizedTokens(of text: String) -> [String] {
        TextTokenizer.tokens(in: text)
    }
}
