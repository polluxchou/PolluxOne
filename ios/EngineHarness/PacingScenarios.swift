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

    report.section("Latin gets its own numbers")

    let latin = ReadingPacer(language: .latin)
    report.check(latin.rate == 16.0, "Latin starts at 16 chars/sec (~190 wpm)",
                 detail: "\(latin.rate)")

    return (report.pass, report.fail)
}
