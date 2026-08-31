import Foundation

/// Turns the discrete, laggy output of speech alignment into a cursor that
/// moves continuously.
///
/// The cursor is a *fractional character offset* into
/// `PromptScriptText.text`. Characters rather than lines or points because
/// the offset then survives re-layout for free: changing the type size or the
/// column width changes which line holds a character, never which character
/// the reader is on.
///
/// Two halves:
///
/// - **Dead reckoning.** Between recognizer results the cursor advances at the
///   reader's measured rate, so the prompter glides instead of freezing and
///   then lurching when the next result lands. Recognizer results arrive every
///   0.3–0.8s; without this, that interval is dead air on screen.
/// - **Correction.** Each result is the truth. A small disagreement is bled off
///   over the next few results, so no single step is visible. A large one means
///   the reader skipped or went back — that is a seek, not drift.
///
/// Time is a parameter on every method, never read from a clock. The engine
/// passes real time; the offline suite passes synthetic time and gets
/// deterministic behaviour out of a component whose whole job is rates.
@MainActor
final class ReadingPacer {
    /// Fractional character offset. The integer part locates a line, the
    /// fraction is how far along that line the reader is.
    private(set) var cursor: Double = 0
    /// Measured reading speed in characters per second.
    private(set) var rate: Double

    private var language: ScriptLanguage
    private var lastTruth: Double = 0
    private var lastTruthTime: TimeInterval?

    /// Fraction of the disagreement taken out per result. 0.25 closes a gap in
    /// three or four results — roughly half a second of speech — with no
    /// single step large enough to read as a jump.
    private let correctionGain = 0.25
    /// Weight of a new rate sample. Reading speed drifts across a paragraph;
    /// it does not change word to word, so the estimate is deliberately slow.
    private let rateSmoothing = 0.25
    /// Below this, a result is noise rather than a measurement. Position is
    /// still trusted — see `correct(to:confidence:at:seekThreshold:)`.
    private let minimumRateConfidence = 0.5

    init(language: ScriptLanguage) {
        self.language = language
        self.rate = language.defaultCharactersPerSecond
    }

    func reset(to offset: Double, language: ScriptLanguage) {
        self.language = language
        cursor = offset
        rate = language.defaultCharactersPerSecond
        lastTruth = offset
        lastTruthTime = nil
    }

    /// Advance by one display tick.
    ///
    /// `lookaheadCap` is the whole safety story. Uncapped dead reckoning is
    /// not a smoothing trick but a bug: a reader who stops to drink water, is
    /// interrupted, or whose recognizer drops a stretch gets scrolled to the
    /// end of the script at a steady 5 characters a second. Capped a little
    /// past the current line, a pause parks the cursor within a line of the
    /// last thing actually heard — and the highlight visibly stopping *is* the
    /// signal that the prompter is no longer following, so no extra HUD
    /// message is needed.
    ///
    /// A cursor already at or beyond the cap holds rather than rewinding: the
    /// cap tightens whenever the current line is short, and a prompter that
    /// scrolls backwards on its own is worse than one that waits.
    func advance(deltaTime: TimeInterval, lookaheadCap: Double) {
        guard deltaTime > 0 else { return }
        let ceiling = lastTruth + lookaheadCap
        guard cursor < ceiling else { return }
        cursor = min(cursor + rate * deltaTime, ceiling)
    }

    /// Fold in one alignment result.
    ///
    /// Position is trusted at any confidence: `SlidingWindowAlignmentEngine`
    /// returns its last known-good sentence rather than a guess when its own
    /// score is low, so even a weak result carries a real position. Only the
    /// *rate* sample is gated, because a confident-looking gap between two
    /// weak results is a fiction.
    func correct(
        to truth: Double,
        confidence: Double,
        at time: TimeInterval,
        seekThreshold: Double
    ) {
        if confidence >= minimumRateConfidence,
           let previousTime = lastTruthTime,
           time > previousTime {
            let sample = (truth - lastTruth) / (time - previousTime)
            if sample > 0 {
                let blended = rate * (1 - rateSmoothing) + sample * rateSmoothing
                rate = min(max(blended, language.rateBounds.lowerBound), language.rateBounds.upperBound)
            }
        }

        lastTruth = truth
        lastTruthTime = time

        let error = truth - cursor
        if abs(error) > seekThreshold {
            // Not drift: the reader jumped. Land on the truth — the view's
            // 0.3s ease makes it a fast slide, not a teleport.
            cursor = truth
        } else {
            cursor += error * correctionGain
        }
    }
}
