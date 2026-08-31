import Foundation

// Offline exercise of Feature 4: SafeWordDetector -> VoiceCommandEngine.
//
// The thing these scenarios are really testing is the shape of the input.
// Speech recognizers do not hand you discrete utterances — they hand you a
// *cumulative* transcript for the whole take that grows character by
// character and gets revised as it refines. Both engines have to reason about
// "what is new since last time" against that, which is exactly where this
// pipeline is easiest to get wrong.

@MainActor
final class SafeWordSpy: SafeWordDetectorDelegate {
    var triggerCount = 0
    func safeWordDetectorDidDetectSafeWord(_ detector: SafeWordDetector) {
        triggerCount += 1
    }
}

@MainActor
final class VoiceCommandSpy: VoiceCommandEngineDelegate {
    var states: [VoiceCommandEngineState] = []
    var confirmed: [VoiceCommand] = []

    func voiceCommandEngine(_ engine: VoiceCommandEngine, didChangeState state: VoiceCommandEngineState) {
        states.append(state)
    }

    func voiceCommandEngine(_ engine: VoiceCommandEngine, didConfirm command: VoiceCommand) {
        confirmed.append(command)
    }
}

/// Builds the growing transcript a recognizer actually emits for a phrase:
/// every prefix, one character at a time, appended to what came before.
@MainActor
func incrementalTranscripts(prefix: String, phrase: String, from start: Date) -> [SpeechTranscript] {
    var out: [SpeechTranscript] = []
    var seconds = 0.0
    for endIndex in 1...phrase.count {
        let partial = String(phrase.prefix(endIndex))
        seconds += 0.1
        out.append(
            SpeechTranscript(
                text: prefix + partial,
                isFinal: endIndex == phrase.count,
                timestamp: start.addingTimeInterval(seconds)
            )
        )
    }
    return out
}

@MainActor
func runVoiceSuite() -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("SAFE WORD DETECTION")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    // ── The case that matters: partials grow one character at a time ───────
    do {
        report.section("safe word arrives as growing partials (p, po, pol, …)")
        let detector = SafeWordDetector()
        let spy = SafeWordSpy()
        detector.delegate = spy
        detector.reset()

        for transcript in incrementalTranscripts(prefix: "and so we begin ", phrase: "pollux", from: t0) {
            detector.ingest(transcript: transcript)
        }
        report.check(spy.triggerCount == 1,
                     "fires exactly once",
                     detail: "fired \(spy.triggerCount)×")
    }

    do {
        report.section("safe word delivered whole (one final result)")
        let detector = SafeWordDetector()
        let spy = SafeWordSpy()
        detector.delegate = spy
        detector.reset()
        detector.ingest(transcript: SpeechTranscript(text: "and so we begin pollux", isFinal: true, timestamp: t0))
        report.check(spy.triggerCount == 1, "fires exactly once", detail: "fired \(spy.triggerCount)×")
    }

    do {
        report.section("recognizer revises earlier text (transcript shrinks)")
        let detector = SafeWordDetector()
        let spy = SafeWordSpy()
        detector.delegate = spy
        detector.reset()
        detector.ingest(transcript: SpeechTranscript(text: "some longer guess here", isFinal: false, timestamp: t0))
        detector.ingest(transcript: SpeechTranscript(text: "pollux", isFinal: true, timestamp: t0.addingTimeInterval(0.3)))
        report.check(spy.triggerCount == 1,
                     "still detects after a shrink",
                     detail: "fired \(spy.triggerCount)×")
    }

    do {
        report.section("the word appears once but partials keep refining")
        let detector = SafeWordDetector()
        let spy = SafeWordSpy()
        detector.delegate = spy
        detector.reset()
        // Same word, repeatedly re-reported within the cooldown window.
        for step in 0..<8 {
            detector.ingest(
                transcript: SpeechTranscript(
                    text: "pollux change this to hello",
                    isFinal: false,
                    timestamp: t0.addingTimeInterval(Double(step) * 0.2)
                )
            )
        }
        report.check(spy.triggerCount == 1,
                     "cooldown collapses it to one trigger",
                     detail: "fired \(spy.triggerCount)×")
    }

    do {
        report.section("said twice, well apart (should fire twice)")
        let detector = SafeWordDetector()
        let spy = SafeWordSpy()
        detector.delegate = spy
        detector.reset()
        detector.ingest(transcript: SpeechTranscript(text: "pollux", isFinal: true, timestamp: t0))
        detector.ingest(transcript: SpeechTranscript(text: "pollux and later pollux", isFinal: true, timestamp: t0.addingTimeInterval(30)))
        report.check(spy.triggerCount == 2, "fires twice", detail: "fired \(spy.triggerCount)×")
    }

    do {
        report.section("never said (should never fire)")
        let detector = SafeWordDetector()
        let spy = SafeWordSpy()
        detector.delegate = spy
        detector.reset()
        for transcript in incrementalTranscripts(prefix: "", phrase: "most teleprompters solve the wrong problem", from: t0) {
            detector.ingest(transcript: transcript)
        }
        report.check(spy.triggerCount == 0, "does not fire", detail: "fired \(spy.triggerCount)×")
    }

    do {
        report.section("mixed case in the transcript")
        let detector = SafeWordDetector()
        let spy = SafeWordSpy()
        detector.delegate = spy
        detector.reset()
        detector.ingest(transcript: SpeechTranscript(text: "okay Pollux, listen", isFinal: true, timestamp: t0))
        report.check(spy.triggerCount == 1, "case-insensitive", detail: "fired \(spy.triggerCount)×")
    }

    // ── Voice command parsing ─────────────────────────────────────────────
    report.suite("VOICE COMMAND")
    let paragraphId = UUID()

    do {
        report.section("replaces a paragraph after the safe word")
        let engine = VoiceCommandEngine()
        let spy = VoiceCommandSpy()
        engine.delegate = spy
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "we have been reading for a while pollux")
        engine.ingest(
            transcript: SpeechTranscript(
                text: "we have been reading for a while pollux change this to we solve eye contact",
                isFinal: true,
                timestamp: t0
            )
        )
        var proposed: String?
        if case .awaitingConfirmation(let command) = engine.state,
           case .replaceParagraph(_, let newText) = command.kind {
            proposed = newText
        }
        report.check(proposed == "we solve eye contact",
                     "extracts only the replacement text",
                     detail: "got “\(proposed ?? "nil")”")
    }

    do {
        report.section("ignores a trigger phrase spoken earlier in the take")
        let engine = VoiceCommandEngine()
        let spy = VoiceCommandSpy()
        engine.delegate = spy
        // The script itself contains the trigger words; the command comes later.
        let before = "earlier i said change this to something bogus and kept reading pollux"
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: before)
        engine.ingest(
            transcript: SpeechTranscript(text: before + " change this to the real replacement", isFinal: true, timestamp: t0)
        )
        var proposed: String?
        if case .awaitingConfirmation(let command) = engine.state,
           case .replaceParagraph(_, let newText) = command.kind {
            proposed = newText
        }
        report.check(proposed == "the real replacement",
                     "uses the command after the safe word, not the earlier phrase",
                     detail: "got “\(proposed ?? "nil")”")
    }

    do {
        report.section("unparseable speech after the safe word")
        let engine = VoiceCommandEngine()
        let spy = VoiceCommandSpy()
        engine.delegate = spy
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "pollux")
        engine.ingest(transcript: SpeechTranscript(text: "pollux uh never mind sorry", isFinal: true, timestamp: t0))
        var awaiting = false
        if case .awaitingConfirmation = engine.state { awaiting = true }
        report.check(!awaiting,
                     "does not pop a confirmation for garbage",
                     detail: "state \(engine.state)")
    }

    do {
        report.section("partial results should not commit a command")
        let engine = VoiceCommandEngine()
        let spy = VoiceCommandSpy()
        engine.delegate = spy
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "pollux")
        engine.ingest(transcript: SpeechTranscript(text: "pollux change this to we sol", isFinal: false, timestamp: t0))
        var awaiting = false
        if case .awaitingConfirmation = engine.state { awaiting = true }
        report.check(!awaiting, "waits for a final result", detail: "state \(engine.state)")
    }

    do {
        report.section("times out if the command never comes")
        let engine = VoiceCommandEngine()
        let spy = VoiceCommandSpy()
        engine.delegate = spy
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "pollux", now: t0)
        engine.ingest(transcript: SpeechTranscript(text: "pollux and then i kept reading", isFinal: true, timestamp: t0.addingTimeInterval(60)))
        var idle = false
        if case .idle = engine.state { idle = true }
        report.check(idle, "returns to idle", detail: "state \(engine.state)")
    }

    do {
        report.section("confirming applies the command exactly once")
        let engine = VoiceCommandEngine()
        let spy = VoiceCommandSpy()
        engine.delegate = spy
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "pollux")
        engine.ingest(transcript: SpeechTranscript(text: "pollux replace this with a shorter line", isFinal: true, timestamp: t0))
        engine.confirm()
        engine.confirm() // double tap
        report.check(spy.confirmed.count == 1,
                     "delegate sees one confirmation",
                     detail: "saw \(spy.confirmed.count)")
    }

    do {
        report.section("rejecting clears the pending command")
        let engine = VoiceCommandEngine()
        let spy = VoiceCommandSpy()
        engine.delegate = spy
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "pollux")
        engine.ingest(transcript: SpeechTranscript(text: "pollux replace this with something", isFinal: true, timestamp: t0))
        engine.reject()
        var idle = false
        if case .idle = engine.state { idle = true }
        report.check(idle && spy.confirmed.isEmpty, "back to idle, nothing applied")
    }

    do {
        report.section("中文指令")
        let engine = VoiceCommandEngine()
        let spy = VoiceCommandSpy()
        engine.delegate = spy
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "小北")
        engine.ingest(transcript: SpeechTranscript(text: "小北 把这段改成 我们真正解决的是镜头交流", isFinal: true, timestamp: t0))
        var proposed: String?
        if case .awaitingConfirmation(let command) = engine.state,
           case .replaceParagraph(_, let newText) = command.kind {
            proposed = newText
        }
        report.check(proposed == "我们真正解决的是镜头交流",
                     "understands 把这段改成…",
                     detail: "got “\(proposed ?? "nil")”")
    }

    return (report.pass, report.fail)
}
