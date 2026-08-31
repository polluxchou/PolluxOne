import Foundation

/// What the overlay draws: the whole script's visual lines, plus which one the
/// reader is on.
///
/// Deliberately holds *every* line rather than a pre-cut 5-row window. The
/// overlay renders them all inside a clipped, fixed-height frame and moves the
/// container, so each line stays the same SwiftUI node across a scroll step
/// and the step animates as a slide. Handing the view a 5-element window
/// instead makes every step a batch of inserts and removals, which animates as
/// a cross-fade — visually no better than the per-sentence jumping this
/// replaces.
///
/// Row roles are not in here either: the view derives them from
/// `line.id - currentLineIndex`, which is what makes the highlight band's
/// position a constant rather than something that has to be recomputed.
struct TeleprompterDisplayState: Equatable {
    var lines: [PromptLine]
    var currentLineIndex: Int
    /// Carried rather than re-detected: the overlay needs it for the type
    /// scale and line height, and a second detection from the visible lines
    /// alone would disagree with this one on a mixed-script script.
    var language: ScriptLanguage
    var isVisible: Bool = true

    /// Derived, not stored — two stored fields could drift out of agreement
    /// with `language`, and the whole point of the fixed window is that these
    /// two numbers are constants for a given script.
    var readRowsAbove: Int { language.readRowsAbove }
    var visibleRows: Int { language.visibleRows }

    static let empty = TeleprompterDisplayState(
        lines: [],
        currentLineIndex: 0,
        language: .latin
    )
}

/// Owns the prompter's typesetting and its clock.
///
/// Split across three observable properties on purpose, because they change at
/// wildly different rates:
///
/// | property          | changes                     | read by             |
/// |-------------------|-----------------------------|---------------------|
/// | `displayState`    | once per line (2–4 seconds)  | the text VStack     |
/// | `inLineProgress`  | 30 times a second            | the highlight fill  |
/// | `readingProgress` | 30 times a second            | the progress rail   |
///
/// `@Observable` tracks reads per property, so the two fast ones invalidate
/// only the small views that read them. Folding either into
/// `TeleprompterDisplayState` would re-diff every `Text` in the script 30
/// times a second.
///
/// The measurer is injected rather than constructed here so this stays free of
/// UIKit and can run in `scripts/test-engines.sh`.
@MainActor
@Observable
final class TeleprompterEngine {
    private(set) var displayState = TeleprompterDisplayState.empty
    /// 0...1 along the current line.
    private(set) var inLineProgress: Double = 0
    private(set) var readingProgress: ReadingProgress = .zero

    /// Exposed for the offline scenarios: the invariant that re-layout leaves
    /// the reading position alone is only checkable against this number.
    var cursorOffset: Double { pacer.cursor }

    private var source: PromptScriptText?
    private var sentenceRanges: [Range<Int>] = []
    private var pacer = ReadingPacer(language: .latin)
    private var language: ScriptLanguage = .latin

    private var layoutWidth: CGFloat = 0
    private var measurer: TextWidthMeasuring?

    private var tickTimer: Timer?
    private var lastTickUptime: TimeInterval?

    /// The band is two rows. A disagreement wider than that is a reader who
    /// skipped or went back, not accumulated drift.
    private let seekThresholdInLines = 2.0
    /// How far dead reckoning may run past the last confirmed truth. Slightly
    /// over one line so a normal reader's line change happens as they reach
    /// the line's end rather than half a second later.
    private let lookaheadInLines = 1.2
    /// Used before any line exists, so the cap is never zero (which would
    /// freeze the prompter) on the first frames after load.
    private let assumedCharactersPerLine = 20

    // MARK: - Loading

    /// `address` reloads without rewinding. A Safe Word edit rebuilds the
    /// script mid-take and calls this; starting from 0 there would throw the
    /// reader back to the top of their script for changing one sentence.
    ///
    /// Resolving that address is `PromptScriptText.resumeOffset(for:)`, and it
    /// is deliberately not inlined here any more: it used to be a one-line
    /// `built.sentenceRanges[address.sentenceId]?.lowerBound ?? 0`, which is
    /// exactly the sentence-only lookup a Safe Word edit is guaranteed to
    /// defeat. See that method for why.
    func load(script: Script, startingAt address: ScriptAddress? = nil) {
        let built = PromptScriptText.build(script)
        source = built
        language = built.language
        pacer = ReadingPacer(language: built.language)

        sentenceRanges = script.allSentences.compactMap { built.sentenceRanges[$0.id] }

        let start = address.map { built.resumeOffset(for: $0) } ?? 0
        pacer.reset(to: Double(start), language: built.language)

        rebuildLines()
    }

    /// Called by the view whenever the column width or the type size changes.
    func setLayout(width: CGFloat, measurer: TextWidthMeasuring) {
        layoutWidth = width
        self.measurer = measurer
        rebuildLines()
    }

    func setVisible(_ visible: Bool) {
        guard displayState.isVisible != visible else { return }
        var next = displayState
        next.isVisible = visible
        displayState = next
    }

    // MARK: - Following

    /// Fold in one alignment result.
    func update(position: ReadingPosition) {
        guard let source, let truth = source.characterOffset(of: position) else { return }
        pacer.correct(
            to: truth,
            confidence: position.confidence,
            at: position.updatedAt.timeIntervalSinceReferenceDate,
            seekThreshold: Double(charactersInCurrentLine) * seekThresholdInLines
        )
        refresh()
    }

    /// One display tick. Separate from the timer so the offline scenarios can
    /// drive it with synthetic time.
    func tick(deltaTime: TimeInterval) {
        pacer.advance(
            deltaTime: deltaTime,
            lookaheadCap: Double(charactersInCurrentLine) * lookaheadInLines
        )
        refresh()
    }

    func startPacing() {
        stopPacing()
        lastTickUptime = nil
        // 30Hz: one Double and one shape redraw per tick. AudioLevelMonitor
        // already runs the same shape of work at 15Hz beside the camera.
        // The `guard let self` is not decoration: `weak self` is a mutable
        // binding, and reaching through it from inside the nested Task is a
        // capture of a var in concurrently-executing code — a warning today
        // and an error under the Swift 6 language mode. AudioLevelMonitor's
        // timer is written the same way for the same reason.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tickFromClock() }
        }
    }

    func stopPacing() {
        tickTimer?.invalidate()
        tickTimer = nil
        lastTickUptime = nil
    }

    /// Real elapsed time rather than the timer's nominal interval: a busy run
    /// loop coalesces timer fires, and a prompter that quietly runs slow
    /// whenever the camera is busy is exactly the bug this feature exists to
    /// remove. `systemUptime` is monotonic, so a clock change cannot rewind it.
    private func tickFromClock() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTickUptime = now }
        guard let last = lastTickUptime, now > last else { return }
        tick(deltaTime: now - last)
    }

    // MARK: - Derivation

    private func rebuildLines() {
        guard let source, let measurer, layoutWidth > 0 else {
            assign(lines: [], currentLineIndex: 0)
            return
        }
        let lines = PromptLineLayout.lines(for: source, width: layoutWidth, measurer: measurer)
        assign(lines: lines, currentLineIndex: lineIndex(containing: Int(pacer.cursor), in: lines))
        refresh()
    }

    private func refresh() {
        let lines = displayState.lines
        guard !lines.isEmpty else {
            inLineProgress = 0
            return
        }

        let index = lineIndex(containing: Int(pacer.cursor), in: lines)
        assign(lines: lines, currentLineIndex: index)

        let line = lines[index]
        let within = pacer.cursor - Double(line.characterRange.lowerBound)
        inLineProgress = min(max(within / Double(max(line.characterCount, 1)), 0), 1)

        readingProgress = makeProgress(totalCharacters: lines[lines.count - 1].characterRange.upperBound)
    }

    /// The one place the line window is written. `setVisible` assigns
    /// `displayState` too, but only to flip `isVisible` — which the overlay
    /// reads to decide whether to draw at all, and which no tick touches.
    ///
    /// The equality guard stops a 30Hz tick from telling observers the line
    /// window moved when it did not. That matters more here than usual: the
    /// state carries every line in the script, so a spurious notification
    /// re-diffs every `Text` in it thirty times a second, and rendering the
    /// whole script at once is the premise the fixed window rests on.
    ///
    /// Swift's Observation runtime already suppresses that notification — but
    /// only because `TeleprompterDisplayState` is `Equatable`. Measured on
    /// Swift 6.3.3: assigning an equal value of an `Equatable` type notifies
    /// nobody, while assigning an equal value of a non-`Equatable` type
    /// notifies everybody. So the conformance is load-bearing at a distance —
    /// add one field that isn't `Equatable` and the prompter quietly goes back
    /// to re-diffing at 30Hz with nothing in the diff to show why. The guard
    /// states that invariant where a reader will find it rather than leaving
    /// it to a synthesized conformance and a runtime detail.
    private func assign(lines: [PromptLine], currentLineIndex: Int) {
        let next = TeleprompterDisplayState(
            lines: lines,
            currentLineIndex: currentLineIndex,
            language: language,
            isVisible: displayState.isVisible
        )
        guard next != displayState else { return }
        displayState = next
    }

    private func makeProgress(totalCharacters: Int) -> ReadingProgress {
        let completed = sentenceRanges.count { Double($0.upperBound) <= pacer.cursor }
        let fraction = totalCharacters > 0
            ? min(max(pacer.cursor / Double(totalCharacters), 0), 1)
            : 0
        return ReadingProgress(
            completedSentences: completed,
            totalSentences: sentenceRanges.count,
            fractionComplete: fraction
        )
    }

    private var charactersInCurrentLine: Int {
        let lines = displayState.lines
        guard displayState.currentLineIndex < lines.count else { return assumedCharactersPerLine }
        return max(lines[displayState.currentLineIndex].characterCount, 1)
    }

    /// Binary search: line ranges are contiguous and ordered, and this runs on
    /// every one of the 30 ticks a second.
    private func lineIndex(containing offset: Int, in lines: [PromptLine]) -> Int {
        guard !lines.isEmpty else { return 0 }
        let total = lines[lines.count - 1].characterRange.upperBound
        let clamped = min(max(offset, 0), max(total - 1, 0))

        var low = 0
        var high = lines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = lines[mid].characterRange
            if clamped < range.lowerBound {
                high = mid - 1
            } else if clamped >= range.upperBound {
                low = mid + 1
            } else {
                return mid
            }
        }
        return lines.count - 1
    }
}
