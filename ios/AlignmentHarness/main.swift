import Foundation

// Offline harness for ScriptAlignmentEngine, run by scripts/test-alignment.sh.
//
// Alignment is the product's core: speech in, reading position out, pure data
// either way. This compiles the real Domain + engine sources (no shims, no
// UIKit) against scripted reading behaviours, so the algorithm can be judged
// on a Mac before any device testing — and so a regression shows up as a
// failing case rather than as "the prompter felt laggy on my phone".
//
// Mirrors ios/Pollux OneTests/ScriptAlignmentEngineTests.swift; this version
// exists because the Xcode project has no test target yet, and it prints the
// confidence for every step, which is what you actually want when tuning
// thresholds. Keep the two in sync when adding cases.

@MainActor
func makeScript(_ paragraphs: [String], title: String) -> Script {
    let built = paragraphs.enumerated().map { index, text in
        Paragraph(id: UUID(), order: index, sentences: SentenceSplitter.sentences(from: text))
    }
    return Script(
        id: UUID(),
        title: title,
        version: 1,
        sections: [ScriptSection(id: UUID(), title: nil, order: 0, paragraphs: built)],
        updatedAt: Date(),
        createdAt: Date()
    )
}

@MainActor
struct Scenario {
    let name: String
    /// Cumulative transcripts, as a recognizer would emit them.
    let utterances: [String]
    /// Index into script.allSentences we expect to land on after each step.
    let expected: [Int]
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

@MainActor
func runAll() {
    var totalPass = 0, totalFail = 0

    // ── English ────────────────────────────────────────────────────────────
    let en = makeScript([
        "Most teleprompters solve the wrong problem. They make the words easy to read, but they pull your eyes away from the lens. The moment your eyes leave the camera, the audience feels it, even if they cannot say why.",
        "Pollux One starts from a different question. What is the shortest possible distance between your eyes, the words, and the lens? Everything in this app follows from that one constraint."
    ], title: "EN")

    let enScenarios: [Scenario] = [
        Scenario(
            name: "reads straight through, one sentence at a time",
            utterances: [
                "Most teleprompters solve the wrong problem.",
                "They make the words easy to read, but they pull your eyes away from the lens.",
                "The moment your eyes leave the camera, the audience feels it, even if they cannot say why.",
                "Pollux One starts from a different question."
            ],
            expected: [0, 1, 2, 3]
        ),
        Scenario(
            name: "repeats a sentence (should hold, not jump ahead)",
            utterances: [
                "Most teleprompters solve the wrong problem.",
                "They make the words easy to read, but they pull your eyes away from the lens.",
                "They make the words easy to read, but they pull your eyes away from the lens.",
            ],
            expected: [0, 1, 1]
        ),
        Scenario(
            name: "skips a sentence entirely",
            utterances: [
                "Most teleprompters solve the wrong problem.",
                "The moment your eyes leave the camera, the audience feels it, even if they cannot say why."
            ],
            expected: [0, 2]
        ),
        Scenario(
            name: "paraphrases loosely (colloquial drift)",
            utterances: [
                "So most teleprompters, they kind of solve the wrong problem really.",
                "They make the words easy to read but they pull your eyes away from the lens you know."
            ],
            expected: [0, 1]
        ),
        Scenario(
            name: "misreads then restarts the same sentence",
            utterances: [
                "Most teleprompters solve the—",
                "Most teleprompters solve the wrong problem."
            ],
            expected: [0, 0]
        )
    ]
    let enResult = run(script: en, scenarios: enScenarios, label: "ENGLISH")
    totalPass += enResult.pass; totalFail += enResult.fail

    // ── 中文 ───────────────────────────────────────────────────────────────
    let cn = makeScript([
        "大多数提词器都在解决错误的问题。它们让字变得容易读，却把你的眼神从镜头上拉走了。你的目光一离开镜头，观众立刻就能感觉到，哪怕他们说不出为什么。",
        "Pollux One 从另一个问题出发。你的眼睛、文字和镜头之间，最短的距离是多少？"
    ], title: "CN")

    let cnScenarios: [Scenario] = [
        Scenario(
            name: "顺序朗读",
            utterances: [
                "大多数提词器都在解决错误的问题。",
                "它们让字变得容易读，却把你的眼神从镜头上拉走了。",
                "你的目光一离开镜头，观众立刻就能感觉到，哪怕他们说不出为什么。"
            ],
            expected: [0, 1, 2]
        ),
        Scenario(
            name: "重复一句",
            utterances: [
                "大多数提词器都在解决错误的问题。",
                "它们让字变得容易读，却把你的眼神从镜头上拉走了。",
                "它们让字变得容易读，却把你的眼神从镜头上拉走了。"
            ],
            expected: [0, 1, 1]
        ),
        Scenario(
            name: "跳过一句",
            utterances: [
                "大多数提词器都在解决错误的问题。",
                "你的目光一离开镜头，观众立刻就能感觉到，哪怕他们说不出为什么。"
            ],
            expected: [0, 2]
        ),
        Scenario(
            name: "识别结果没有标点（ASR 常见）",
            utterances: [
                "大多数提词器都在解决错误的问题",
                "它们让字变得容易读却把你的眼神从镜头上拉走了"
            ],
            expected: [0, 1]
        ),
        Scenario(
            name: "口语化偏差",
            utterances: [
                "那大多数的提词器其实都在解决一个错误的问题",
                "它们让字变得很容易读但是却把你的眼神从镜头上拉走了"
            ],
            expected: [0, 1]
        )
    ]
    let cnResult = run(script: cn, scenarios: cnScenarios, label: "中文")
    totalPass += cnResult.pass; totalFail += cnResult.fail

    // ── Adversarial: where does it break? ──────────────────────────────────
    let adversarial: [Scenario] = [
        Scenario(
            name: "unrelated speech / noise (should hold, not wander)",
            utterances: [
                "Most teleprompters solve the wrong problem.",
                "uh hold on let me get some water sorry about that okay"
            ],
            expected: [0, 0]
        ),
        Scenario(
            name: "jumps backwards two sentences (within look-behind)",
            utterances: [
                "Most teleprompters solve the wrong problem.",
                "They make the words easy to read, but they pull your eyes away from the lens.",
                "The moment your eyes leave the camera, the audience feels it, even if they cannot say why.",
                "Most teleprompters solve the wrong problem."
            ],
            expected: [0, 1, 2, 0]
        ),
        Scenario(
            name: "long pause emits the same partial repeatedly",
            utterances: [
                "Most teleprompters solve the wrong problem.",
                "",
                ""
            ],
            expected: [0, 0, 0]
        ),
        Scenario(
            name: "half a sentence in progress (should already move onto it)",
            utterances: [
                "Most teleprompters solve the wrong problem.",
                "They make the words easy to read"
            ],
            expected: [0, 1]
        )
    ]
    let advResult = run(script: en, scenarios: adversarial, label: "ADVERSARIAL (EN)")
    totalPass += advResult.pass; totalFail += advResult.fail

    print("\n══════ TOTAL: \(totalPass) passed, \(totalFail) failed ══════")
}

MainActor.assumeIsolated { runAll() }
