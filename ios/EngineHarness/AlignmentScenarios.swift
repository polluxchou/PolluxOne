import Foundation

// Offline harness for ScriptAlignmentEngine, run by scripts/test-engines.sh.
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
func runAlignmentSuite() -> (pass: Int, fail: Int) {
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

    // The scenarios above assert sentence indices, which is all that mattered
    // while nothing read `tokenIndexInSentence`. The fixed-window prompter
    // interpolates the reading cursor across a sentence from that index, so it
    // is now load-bearing and needs its own coverage.
    let offset = runTokenOffsetSuite(script: en)
    totalPass += offset.pass; totalFail += offset.fail

    return (totalPass, totalFail)
}

/// A weak result must report the last position the engine actually earned —
/// the sentence *and* the token inside it.
///
/// Reporting the sentence with a token index of 0 is worse than reporting
/// nothing: `PromptScriptText.characterOffset(of:)` reads it as "back at the
/// start of this sentence", so `ReadingPacer` corrects the cursor backwards
/// while the reader is still moving forwards, and drops its lookahead ceiling
/// at the same time.
@MainActor
func runTokenOffsetSuite(script: Script) -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("Alignment — a weak result holds the whole last known-good position")

    let sentences = script.allSentences
    let engine = SlidingWindowAlignmentEngine()
    engine.reset(script: script, startingAt: nil)

    func index(of position: ReadingPosition?) -> Int? {
        position.flatMap { p in sentences.firstIndex { $0.id == p.address.sentenceId } }
    }

    // Recognizer transcripts are cumulative for the whole take, so the noise
    // arrives appended to everything read so far — exactly as it does live.
    var spoken = "Most teleprompters solve the wrong problem."
    _ = engine.ingest(transcript: SpeechTranscript(text: spoken, isFinal: false))

    spoken += " They make the words easy to read, but they pull"
    let good = engine.ingest(transcript: SpeechTranscript(text: spoken, isFinal: false))

    report.check(index(of: good) == 1,
                 "reading into the second sentence lands on it",
                 detail: "sentence \(index(of: good).map(String.init) ?? "nil")")
    report.check((good?.confidence ?? 0) >= 0.34,
                 "with a score above the confidence floor",
                 detail: String(format: "%.3f", good?.confidence ?? 0))
    report.check((good?.tokenIndexInSentence ?? 0) > 0,
                 "and a real in-sentence token offset — without one there is nothing here to preserve",
                 detail: "token \(good?.tokenIndexInSentence ?? -1)")

    let earned = good?.tokenIndexInSentence ?? -1

    // An ad-lib, a stumble, a cough, a siren: no candidate in the window owns
    // any of it, so every one of these takes the low-confidence branch.
    for noise in ["uh hold on sorry about that okay", "cough cough", "zzz qqq xxx yyy www vvv"] {
        spoken += " " + noise
        let weak = engine.ingest(transcript: SpeechTranscript(text: spoken, isFinal: false))

        report.check((weak?.confidence ?? 1) < 0.34,
                     "“\(noise)” scores below the floor, so this is the low-confidence branch",
                     detail: String(format: "%.3f", weak?.confidence ?? -1))
        report.check(index(of: weak) == 1,
                     "and holds the sentence the reader is on")
        report.check(weak?.tokenIndexInSentence == earned,
                     "and holds the token offset too, rather than reporting the sentence's start",
                     detail: "token \(weak?.tokenIndexInSentence ?? -1), earned \(earned)")
    }

    report.section("reading on from noise picks the offset back up")

    spoken += " your eyes away from the lens"
    let recovered = engine.ingest(transcript: SpeechTranscript(text: spoken, isFinal: false))

    report.check(index(of: recovered) == 1,
                 "still the same sentence")
    report.check((recovered?.tokenIndexInSentence ?? 0) > earned,
                 "and the offset advances past where the noise interrupted",
                 detail: "token \(recovered?.tokenIndexInSentence ?? -1) vs \(earned)")

    report.section("a reset clears the remembered offset")

    engine.reset(script: script, startingAt: nil)
    let afterReset = engine.ingest(transcript: SpeechTranscript(text: "qqq zzz xxx", isFinal: false))

    report.check(afterReset?.tokenIndexInSentence == 0,
                 "a new take starts at the top of its first sentence, not wherever the last one stopped",
                 detail: "token \(afterReset?.tokenIndexInSentence ?? -1)")

    return (report.pass, report.fail)
}

