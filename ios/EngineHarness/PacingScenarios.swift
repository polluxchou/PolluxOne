import Foundation

// Offline exercise of the reading pacer: how discrete, laggy recognizer
// results become a cursor that moves continuously.
//
// Time is injected here, never read from a clock, so every one of these is
// deterministic. That matters more than usual: the failure modes are all
// about *rates* and *convergence*, and a suite that sampled real time would
// report them as flakes.
//
// The cap scenario is the important one. Without a lookahead cap, dead
// reckoning is not a smoothing trick, it is a bug: a reader who pauses gets
// scrolled to the end of their script.

@MainActor
func runPacingSuite() -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("Reading pacer — continuous cursor from discrete speech")

    // A 20-character Chinese line; 1.2 lines of lookahead, 2 lines to seek.
    let lineLength = 20.0
    let cap = 1.2 * lineLength
    let seek = 2.0 * lineLength

    report.section("dead reckoning between recognizer results")

    let gliding = ReadingPacer(language: .cjk)
    report.check(gliding.rate == 5.0, "Chinese starts at the seeded 5 字/秒",
                 detail: "\(gliding.rate)")

    for _ in 0..<10 { gliding.advance(deltaTime: 0.1, lookaheadCap: cap) }
    report.check(abs(gliding.cursor - 5.0) < 0.001,
                 "one second at 5 字/秒 moves the cursor 5 characters",
                 detail: "\(gliding.cursor)")

    report.section("the lookahead cap — a reader who stops does not get scrolled away")

    let stalled = ReadingPacer(language: .cjk)
    for _ in 0..<300 { stalled.advance(deltaTime: 0.1, lookaheadCap: cap) }
    report.check(abs(stalled.cursor - cap) < 0.001,
                 "30 seconds of silence parks the cursor 1.2 lines past the last truth, not 150 characters in",
                 detail: "\(stalled.cursor)")

    let tightening = ReadingPacer(language: .cjk)
    tightening.correct(to: 100, confidence: 0.9, at: 0, seekThreshold: seek)
    for _ in 0..<300 { tightening.advance(deltaTime: 0.1, lookaheadCap: cap) }
    let parked = tightening.cursor
    tightening.advance(deltaTime: 0.1, lookaheadCap: 4)
    report.check(tightening.cursor == parked,
                 "a cap that tightens holds the cursor instead of rewinding it",
                 detail: "\(parked) -> \(tightening.cursor)")

    report.section("measured rate converges on the reader")

    let measured = ReadingPacer(language: .cjk)
    let readerRate = 4.0
    for step in 1...30 {
        let time = Double(step) * 0.5
        for _ in 0..<15 { measured.advance(deltaTime: 1.0 / 30.0, lookaheadCap: cap) }
        measured.correct(to: readerRate * time, confidence: 0.9, at: time, seekThreshold: seek)
    }
    report.check(abs(measured.rate - readerRate) < 0.3,
                 "a reader holding 4 字/秒 is measured at 4 字/秒",
                 detail: "\(measured.rate)")
    report.check(abs(measured.cursor - readerRate * 15.0) < 4.0,
                 "and the cursor stays within a few characters of the truth",
                 detail: "\(measured.cursor) vs \(readerRate * 15.0)")

    report.section("rate is clamped — one bad burst must not make the prompter sprint")

    let fast = ReadingPacer(language: .cjk)
    fast.correct(to: 0, confidence: 0.9, at: 0, seekThreshold: seek)
    fast.correct(to: 1000, confidence: 0.9, at: 0.1, seekThreshold: seek)
    report.check(fast.rate <= 12.0,
                 "a 10000 字/秒 sample is clamped to the Chinese ceiling",
                 detail: "\(fast.rate)")

    let slow = ReadingPacer(language: .cjk)
    slow.correct(to: 0, confidence: 0.9, at: 0, seekThreshold: seek)
    for step in 1...40 {
        slow.correct(to: 0.001 * Double(step), confidence: 0.9, at: Double(step), seekThreshold: seek)
    }
    report.check(slow.rate == 2.0,
                 "a near-zero reader is floored at the Chinese minimum",
                 detail: "\(slow.rate)")

    report.section("small disagreement is bled off, never jumped")

    let drifting = ReadingPacer(language: .cjk)
    drifting.reset(to: 100, language: .cjk)
    var positions: [Double] = []
    for step in 1...4 {
        drifting.correct(to: 108, confidence: 0.9, at: Double(step), seekThreshold: seek)
        positions.append(drifting.cursor)
    }
    let deltas = zip([100.0] + positions, positions).map { $1 - $0 }

    report.check(deltas.allSatisfy { $0 > 0 },
                 "every correction moves forward",
                 detail: "\(deltas)")
    report.check(zip(deltas, deltas.dropFirst()).allSatisfy { $0 > $1 },
                 "each step is smaller than the last — an exponential approach, not a ramp")
    report.check(deltas.allSatisfy { $0 <= 2.0 },
                 "no single step exceeds 2 characters, so nothing reads as a jump",
                 detail: "\(deltas.max() ?? 0)")
    report.check(abs((positions.last ?? 0) - 108) < 3.0,
                 "four results close an 8-character gap to under 3",
                 detail: "\(positions.last ?? 0)")

    report.section("large disagreement is a seek, not drift")

    let jumpedAhead = ReadingPacer(language: .cjk)
    jumpedAhead.reset(to: 100, language: .cjk)
    jumpedAhead.correct(to: 400, confidence: 0.9, at: 1, seekThreshold: seek)
    report.check(jumpedAhead.cursor == 400,
                 "a reader who skipped ahead lands on the truth immediately",
                 detail: "\(jumpedAhead.cursor)")

    let wentBack = ReadingPacer(language: .cjk)
    wentBack.reset(to: 400, language: .cjk)
    wentBack.correct(to: 100, confidence: 0.9, at: 1, seekThreshold: seek)
    report.check(wentBack.cursor == 100,
                 "and so does a reader who went back to re-read")

    report.section("a low-confidence result is trusted for position, not for rate")

    let noisy = ReadingPacer(language: .cjk)
    noisy.correct(to: 0, confidence: 0.9, at: 0, seekThreshold: seek)
    let rateBefore = noisy.rate
    noisy.correct(to: 100, confidence: 0.2, at: 1, seekThreshold: seek)
    report.check(noisy.rate == rateBefore,
                 "background noise does not become a speed measurement",
                 detail: "\(rateBefore) -> \(noisy.rate)")
    report.check(noisy.cursor == 100,
                 "but the position still moves: the alignment engine only ever returns its last known-good sentence")

    report.section("noise does not walk the cursor backwards")

    // The only scenario here that wires the real alignment engine to the real
    // prompter, because that is the only place this defect is visible. A
    // synthetic `ReadingPosition` cannot show it: the fabricated value was the
    // token index the *alignment engine* put in the position, and every other
    // scenario builds positions by hand.
    let noiseScript = makeLayoutScript([
        "大多数提词器都在解决错误的问题。它们让字变得容易读，却把你的眼神从镜头上拉走了。你的目光一离开镜头，观众立刻就能感觉到。"
    ])
    let aligner = SlidingWindowAlignmentEngine()
    aligner.reset(script: noiseScript, startingAt: nil)
    let noiseEngine = TeleprompterEngine()
    noiseEngine.load(script: noiseScript)
    noiseEngine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))

    var heard = ""
    func speak(_ text: String) -> ReadingPosition? {
        // Chinese transcripts are cumulative and unspaced, as the recognizer
        // emits them.
        heard += text
        guard let position = aligner.ingest(transcript: SpeechTranscript(text: heard, isFinal: false)) else {
            return nil
        }
        noiseEngine.update(position: position)
        return position
    }

    _ = speak("大多数提词器都在解决错误的问题。")
    _ = speak("它们让字变得容易读，却把你的眼神从镜头上拉")
    let cursorWhileReading = noiseEngine.cursorOffset

    var noisyCursors: [Double] = []
    var noisyConfidences: [Double] = []
    // Long enough to push the script out of the spoken tail, which is what it
    // takes in Chinese: the tail is sized from the longest candidate sentence,
    // and CJK tokenizes per character, so a two-character cough on its own
    // still leaves the sentence covered and scoring high.
    for noise in ["呃稍等我喝一口水实在抱歉外面有点吵我们重新来一遍", "咳咳", "嗯那个"] {
        let position = speak(noise)
        noisyConfidences.append(position?.confidence ?? -1)
        noisyCursors.append(noiseEngine.cursorOffset)
    }

    report.check(cursorWhileReading > 0,
                 "the reader got somewhere before the noise",
                 detail: "\(cursorWhileReading)")
    report.check(noisyConfidences.allSatisfy { $0 < 0.34 },
                 "all three interruptions score below the confidence floor",
                 detail: "\(noisyConfidences.map { String(format: "%.3f", $0) })")
    report.check(noisyCursors.allSatisfy { $0 >= cursorWhileReading - 0.001 },
                 "and none of them drags the cursor back — it used to lose a line per result and pin itself there",
                 detail: "\(cursorWhileReading) -> \(noisyCursors)")

    report.section("the fixed window — the band never moves")

    let windowScript = makeLayoutScript([
        "大多数提词器都在解决错误的问题。它们让字变得容易读，却把你的眼神从镜头上拉走了。你的目光一离开镜头，观众立刻就能感觉到。",
        "Pollux One 从另一个问题出发。你的眼睛、文字和镜头之间，最短的距离是多少？"
    ])
    let engine = TeleprompterEngine()
    engine.load(script: windowScript)
    engine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))

    report.check(engine.displayState.visibleRows == 5,
                 "a Chinese script shows 5 rows")
    report.check(engine.displayState.readRowsAbove == 1,
                 "with 1 dim history row above the band")
    report.check(engine.displayState.lines.count > 5,
                 "the fixture is longer than one window",
                 detail: "\(engine.displayState.lines.count) lines")
    report.check(engine.displayState.currentLineIndex == 0,
                 "a freshly loaded script starts on line 0")
    report.check(engine.inLineProgress == 0,
                 "and at the very start of that line")

    report.section("displayState changes only when the window does")

    let stateBeforeTick = engine.displayState
    for _ in 0..<3 { engine.tick(deltaTime: 1.0 / 30.0) }

    report.check(engine.displayState == stateBeforeTick,
                 "three ticks inside one line leave the line window untouched — this is what keeps 30Hz off the text",
                 detail: "line \(engine.displayState.currentLineIndex)")
    report.check(engine.inLineProgress > 0,
                 "while the fine cursor did move",
                 detail: "\(engine.inLineProgress)")

    report.section("a large jump seeks, and the window follows")

    if let lastSentence = windowScript.allSentences.last {
        engine.update(position: makePosition(lastSentence, tokenIndex: 0, in: windowScript))
    }

    report.check(engine.displayState.currentLineIndex > 1,
                 "jumping to the last sentence moves the window well past the top",
                 detail: "line \(engine.displayState.currentLineIndex)")
    report.check(engine.displayState.currentLineIndex < engine.displayState.lines.count,
                 "and never past the end of the script")

    report.section("re-layout keeps the reader where they were")

    let offsetBefore = engine.cursorOffset
    let lineBefore = engine.displayState.currentLineIndex
    engine.setLayout(width: 60, measurer: FakeTextMeasurer(em: 10))

    report.check(engine.cursorOffset == offsetBefore,
                 "the character offset is untouched by re-layout — this is the whole reason the cursor is measured in characters",
                 detail: "\(offsetBefore) -> \(engine.cursorOffset)")
    report.check(engine.displayState.currentLineIndex > lineBefore,
                 "a narrower column puts the same character on a later line",
                 detail: "\(lineBefore) -> \(engine.displayState.currentLineIndex)")

    let landedLine = engine.displayState.lines[engine.displayState.currentLineIndex]
    report.check(landedLine.characterRange.contains(Int(engine.cursorOffset)),
                 "and the line the window points at really does contain that character")

    report.section("dead reckoning is capped from the current line's own length")

    let cappedEngine = TeleprompterEngine()
    cappedEngine.load(script: windowScript)
    cappedEngine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))
    for _ in 0..<900 { cappedEngine.tick(deltaTime: 1.0 / 30.0) }

    report.check(cappedEngine.cursorOffset <= 1.2 * 10 + 0.001,
                 "30 seconds of silence from line 0 advances at most 1.2 of that line's 10 characters",
                 detail: "\(cappedEngine.cursorOffset)")
    report.check(cappedEngine.displayState.currentLineIndex <= 1,
                 "so the window sits on line 0 or 1, not at the end of the script",
                 detail: "line \(cappedEngine.displayState.currentLineIndex)")

    report.section("progress is reported outside the line window")

    report.check(engine.readingProgress.totalSentences == windowScript.allSentences.count,
                 "progress counts every sentence in the script",
                 detail: "\(engine.readingProgress.totalSentences)")
    report.check(engine.readingProgress.fractionComplete > 0
                    && engine.readingProgress.fractionComplete <= 1,
                 "and reads as a fraction after the seek",
                 detail: "\(engine.readingProgress.fractionComplete)")

    report.section("a Safe Word edit does not rewind the reader")

    // This section used to reload `windowScript` itself, and that is why the
    // defect shipped past a passing suite: the same Script value carries the
    // same sentence ids, so the resume lookup could not miss and the scenario
    // could not fail. The real path rebuilds the paragraph, which mints new
    // sentence ids for all of it — see `replacingParagraph`.
    let editedParagraphId = windowScript.sections[0].paragraphs[1].id
    // The second sentence of the second paragraph, so that the sentence's own
    // offset, the paragraph's start, and 0 are three distinguishable answers.
    let reader = windowScript.allSentences[4]
    let readerAddress = makePosition(reader, tokenIndex: 0, in: windowScript).address

    let editedEngine = TeleprompterEngine()
    editedEngine.load(script: windowScript)
    editedEngine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))
    editedEngine.update(position: makePosition(reader, tokenIndex: 0, in: windowScript))
    let offsetBeforeEdit = editedEngine.cursorOffset
    let lineBeforeEdit = editedEngine.displayState.currentLineIndex

    let edited = replacingParagraph(
        editedParagraphId,
        in: windowScript,
        with: "Pollux One 从另一个问题出发。你的眼睛和镜头之间，最短的距离是多少？"
    )
    let editedText = PromptScriptText.build(edited)
    let survivingIds = Set(windowScript.allSentences.map(\.id))

    report.check(edited.sections[0].paragraphs[1].sentences.allSatisfy { !survivingIds.contains($0.id) },
                 "the rebuilt paragraph's sentence ids are all new — this is what makes a sentence-only lookup miss")
    report.check(edited.sections[0].paragraphs[1].id == editedParagraphId,
                 "while the paragraph's own id survives the edit, which is what the fallback keys on")

    editedEngine.load(script: edited, startingAt: readerAddress)

    report.check(offsetBeforeEdit > 0,
                 "the reader was well into the script before the edit",
                 detail: "\(offsetBeforeEdit)")
    report.check(editedEngine.cursorOffset == Double(editedText.hardBreaks[0]),
                 "and lands at the top of the edited paragraph, not the top of the script",
                 detail: "\(offsetBeforeEdit) -> \(editedEngine.cursorOffset), paragraph 2 starts at \(editedText.hardBreaks[0])")
    report.check(editedEngine.displayState.currentLineIndex > 0,
                 "so the window is not back on line 0 either",
                 detail: "line \(lineBeforeEdit) -> \(editedEngine.displayState.currentLineIndex)")

    // The paragraph is a fallback, not a replacement: a sentence id that is
    // still there is the finer answer and has to win.
    let intactEngine = TeleprompterEngine()
    intactEngine.load(script: windowScript)
    intactEngine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))
    intactEngine.load(script: windowScript, startingAt: readerAddress)
    let windowText = PromptScriptText.build(windowScript)

    report.check(intactEngine.cursorOffset == Double(windowText.sentenceRanges[reader.id]?.lowerBound ?? -1),
                 "an address whose sentence still exists resolves to that sentence, not to its paragraph",
                 detail: "\(intactEngine.cursorOffset) vs paragraph 2 at \(windowText.hardBreaks[0])")

    // Both halves of the address gone — a script swapped out from under the
    // reader rather than edited. There is nothing left to aim at.
    let strandedAddress = ScriptAddress(
        scriptId: windowScript.id,
        scriptVersion: windowScript.version,
        sectionId: windowScript.sections[0].id,
        paragraphId: UUID(),
        sentenceId: UUID()
    )
    let strandedEngine = TeleprompterEngine()
    strandedEngine.load(script: windowScript)
    strandedEngine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))
    strandedEngine.update(position: makePosition(reader, tokenIndex: 0, in: windowScript))
    strandedEngine.load(script: windowScript, startingAt: strandedAddress)

    report.check(strandedEngine.cursorOffset == 0,
                 "an address matching neither a sentence nor a paragraph is the one case that starts over",
                 detail: "\(strandedEngine.cursorOffset)")

    report.section("an empty layout is published, not left stale")

    // `rebuildLines` hands its lines to `refresh` rather than locating the
    // cursor itself, so the path that used to clear the window explicitly now
    // goes through the same writer. It still has to clear.
    let clearingEngine = TeleprompterEngine()
    clearingEngine.load(script: windowScript)
    clearingEngine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))

    report.check(!clearingEngine.displayState.lines.isEmpty,
                 "the window starts with rows in it",
                 detail: "\(clearingEngine.displayState.lines.count) lines")

    clearingEngine.load(script: makeLayoutScript([]))

    report.check(clearingEngine.displayState.lines.isEmpty,
                 "loading a script with no text leaves no rows behind — a stale row would be drawn over the picture")
    report.check(clearingEngine.displayState.currentLineIndex == 0,
                 "and the window index goes with them")
    report.check(clearingEngine.inLineProgress == 0,
                 "and there is no in-line progress along a line that does not exist")

    report.section("Latin gets six rows and two history rows")

    let latinEngine = TeleprompterEngine()
    latinEngine.load(script: makeLayoutScript([
        "Most teleprompters solve the wrong problem. They pull your eyes away from the lens."
    ]))
    latinEngine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))

    report.check(latinEngine.displayState.visibleRows == 6,
                 "6 rows in Latin")
    report.check(latinEngine.displayState.readRowsAbove == 2,
                 "with 2 dim history rows above the band")

    report.section("Latin gets its own numbers")

    let latin = ReadingPacer(language: .latin)
    report.check(latin.rate == 16.0, "Latin starts at 16 chars/sec (~190 wpm)",
                 detail: "\(latin.rate)")

    return (report.pass, report.fail)
}
