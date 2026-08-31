import Foundation

// Shared reporting for the offline engine suites. Deliberately tiny: the
// point is to exercise the real engines, not to build a test framework.

@MainActor
struct Scenario {
    let name: String
    /// Cumulative transcripts, as a recognizer would emit them.
    let utterances: [String]
    /// Index into script.allSentences expected after each step.
    let expected: [Int]
}

@MainActor
final class Report {
    private(set) var pass = 0
    private(set) var fail = 0

    func check(_ condition: Bool, _ description: String, detail: String = "") {
        if condition { pass += 1 } else { fail += 1 }
        let suffix = detail.isEmpty ? "" : "  (\(detail))"
        print("   \(condition ? "✓" : "✗") \(description)\(suffix)")
    }

    func section(_ title: String) { print("\n── \(title)") }
    func suite(_ title: String) { print("\n══════ \(title) ══════") }

    func absorb(_ other: (pass: Int, fail: Int)) {
        pass += other.pass
        fail += other.fail
    }
}
@MainActor
func run(script: Script, scenarios: [Scenario], label: String) -> (pass: Int, fail: Int) {
    let sentences = script.allSentences
    print("\n══════ \(label) ══════")
    print("script has \(sentences.count) sentences:")
    for (i, s) in sentences.enumerated() { print("  [\(i)] \(s.text)") }

    var pass = 0, fail = 0
    for scenario in scenarios {
        let engine = SlidingWindowAlignmentEngine()
        engine.reset(script: script, startingAt: nil)
        print("\n── \(scenario.name)")
        var cumulative = ""
        for (step, utterance) in scenario.utterances.enumerated() {
            cumulative = cumulative.isEmpty ? utterance : cumulative + " " + utterance
            let position = engine.ingest(
                transcript: SpeechTranscript(text: cumulative, isFinal: false)
            )
            let landedIndex = position.flatMap { p in
                sentences.firstIndex { $0.id == p.address.sentenceId }
            }
            let want = scenario.expected[step]
            let ok = landedIndex == want
            if ok { pass += 1 } else { fail += 1 }
            let conf = position.map { String(format: "%.2f", $0.confidence) } ?? "nil"
            print("   \(ok ? "✓" : "✗") said “\(utterance)”  →  got \(landedIndex.map(String.init) ?? "nil") want \(want)  (conf \(conf))")
        }
    }
    return (pass, fail)
}

