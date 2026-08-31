import Testing
@testable import Pollux_One

/// Reading-following is the product. These cases are the behaviours a real
/// speaker produces — pauses, repeats, skipped lines, paraphrase, punctuation
/// the recognizer never emits — checked without a camera or microphone, since
/// alignment is pure data in / data out.
///
/// Every case here also runs headlessly via `scripts/test-engines.sh`, which
/// compiles the Domain + engine sources directly and needs no test target.
/// Keep the two in sync when adding cases.
@MainActor
struct ScriptAlignmentEngineTests {

    // MARK: - Fixtures

    private static let englishParagraphs = [
        "Most teleprompters solve the wrong problem. They make the words easy to read, but they pull your eyes away from the lens. The moment your eyes leave the camera, the audience feels it, even if they cannot say why.",
        "Pollux One starts from a different question. What is the shortest possible distance between your eyes, the words, and the lens? Everything in this app follows from that one constraint."
    ]

    private static let chineseParagraphs = [
        "大多数提词器都在解决错误的问题。它们让字变得容易读，却把你的眼神从镜头上拉走了。你的目光一离开镜头，观众立刻就能感觉到，哪怕他们说不出为什么。",
        "Pollux One 从另一个问题出发。你的眼睛、文字和镜头之间，最短的距离是多少？"
    ]

    private func makeScript(_ paragraphs: [String]) -> Script {
        let built = paragraphs.enumerated().map { index, text in
            Paragraph(id: UUID(), order: index, sentences: SentenceSplitter.sentences(from: text))
        }
        return Script(
            id: UUID(),
            title: "Test",
            version: 1,
            sections: [ScriptSection(id: UUID(), title: nil, order: 0, paragraphs: built)],
            updatedAt: Date(),
            createdAt: Date()
        )
    }

    /// Feeds cumulative transcripts (the shape recognizers actually emit) and
    /// returns the sentence index the engine settled on after each step.
    private func readThrough(_ utterances: [String], of script: Script) -> [Int?] {
        let engine = SlidingWindowAlignmentEngine()
        engine.reset(script: script, startingAt: nil)
        let sentences = script.allSentences

        var cumulative = ""
        return utterances.map { utterance in
            cumulative = cumulative.isEmpty ? utterance : cumulative + " " + utterance
            let position = engine.ingest(transcript: SpeechTranscript(text: cumulative, isFinal: false))
            return position.flatMap { p in sentences.firstIndex { $0.id == p.address.sentenceId } }
        }
    }

    // MARK: - English

    @Test func advancesSentenceBySentence() {
        let script = makeScript(Self.englishParagraphs)
        let landed = readThrough([
            "Most teleprompters solve the wrong problem.",
            "They make the words easy to read, but they pull your eyes away from the lens.",
            "The moment your eyes leave the camera, the audience feels it, even if they cannot say why.",
            "Pollux One starts from a different question."
        ], of: script)
        #expect(landed == [0, 1, 2, 3])
    }

    /// The behaviour that matters most: the highlight has to move as the
    /// reader *starts* a line. Waiting for the line to finish leaves them
    /// looking at a stale highlight, which is the problem this app exists for.
    @Test func advancesPartWayIntoTheNextSentence() {
        let script = makeScript(Self.englishParagraphs)
        let landed = readThrough([
            "Most teleprompters solve the wrong problem.",
            "They make the words easy to read"
        ], of: script)
        #expect(landed == [0, 1])
    }

    @Test func holdsPositionWhenASentenceIsRepeated() {
        let script = makeScript(Self.englishParagraphs)
        let landed = readThrough([
            "Most teleprompters solve the wrong problem.",
            "They make the words easy to read, but they pull your eyes away from the lens.",
            "They make the words easy to read, but they pull your eyes away from the lens."
        ], of: script)
        #expect(landed == [0, 1, 1])
    }

    @Test func followsASkippedSentence() {
        let script = makeScript(Self.englishParagraphs)
        let landed = readThrough([
            "Most teleprompters solve the wrong problem.",
            "The moment your eyes leave the camera, the audience feels it, even if they cannot say why."
        ], of: script)
        #expect(landed == [0, 2])
    }

    @Test func toleratesColloquialDrift() {
        let script = makeScript(Self.englishParagraphs)
        let landed = readThrough([
            "So most teleprompters, they kind of solve the wrong problem really.",
            "They make the words easy to read but they pull your eyes away from the lens you know."
        ], of: script)
        #expect(landed == [0, 1])
    }

    @Test func holdsWhenASentenceIsRestartedAfterAMisread() {
        let script = makeScript(Self.englishParagraphs)
        let landed = readThrough([
            "Most teleprompters solve the—",
            "Most teleprompters solve the wrong problem."
        ], of: script)
        #expect(landed == [0, 0])
    }

    @Test func followsAJumpBackwards() {
        let script = makeScript(Self.englishParagraphs)
        let landed = readThrough([
            "Most teleprompters solve the wrong problem.",
            "They make the words easy to read, but they pull your eyes away from the lens.",
            "The moment your eyes leave the camera, the audience feels it, even if they cannot say why.",
            "Most teleprompters solve the wrong problem."
        ], of: script)
        #expect(landed == [0, 1, 2, 0])
    }

    @Test func doesNotWanderOnUnrelatedSpeech() {
        let script = makeScript(Self.englishParagraphs)
        let landed = readThrough([
            "Most teleprompters solve the wrong problem.",
            "uh hold on let me get some water sorry about that okay"
        ], of: script)
        #expect(landed == [0, 0])
    }

    @Test func holdsThroughAPauseThatEmitsNothingNew() {
        let script = makeScript(Self.englishParagraphs)
        let landed = readThrough([
            "Most teleprompters solve the wrong problem.",
            "",
            ""
        ], of: script)
        #expect(landed == [0, 0, 0])
    }

    // MARK: - 中文
    //
    // Chinese is not a translation of the English cases for its own sake: CJK
    // has no word spaces, so space-splitting collapses a whole sentence into
    // one token and the position never advances. These guard the
    // per-character tokenization in TextTokenizer.

    @Test func advancesThroughChineseSentences() {
        let script = makeScript(Self.chineseParagraphs)
        let landed = readThrough([
            "大多数提词器都在解决错误的问题。",
            "它们让字变得容易读，却把你的眼神从镜头上拉走了。",
            "你的目光一离开镜头，观众立刻就能感觉到，哪怕他们说不出为什么。"
        ], of: script)
        #expect(landed == [0, 1, 2])
    }

    @Test func holdsOnARepeatedChineseSentence() {
        let script = makeScript(Self.chineseParagraphs)
        let landed = readThrough([
            "大多数提词器都在解决错误的问题。",
            "它们让字变得容易读，却把你的眼神从镜头上拉走了。",
            "它们让字变得容易读，却把你的眼神从镜头上拉走了。"
        ], of: script)
        #expect(landed == [0, 1, 1])
    }

    @Test func followsASkippedChineseSentence() {
        let script = makeScript(Self.chineseParagraphs)
        let landed = readThrough([
            "大多数提词器都在解决错误的问题。",
            "你的目光一离开镜头，观众立刻就能感觉到，哪怕他们说不出为什么。"
        ], of: script)
        #expect(landed == [0, 2])
    }

    /// Recognizers routinely return Chinese with no punctuation at all.
    @Test func alignsChineseWithoutPunctuation() {
        let script = makeScript(Self.chineseParagraphs)
        let landed = readThrough([
            "大多数提词器都在解决错误的问题",
            "它们让字变得容易读却把你的眼神从镜头上拉走了"
        ], of: script)
        #expect(landed == [0, 1])
    }

    @Test func toleratesChineseColloquialDrift() {
        let script = makeScript(Self.chineseParagraphs)
        let landed = readThrough([
            "那大多数的提词器其实都在解决一个错误的问题",
            "它们让字变得很容易读但是却把你的眼神从镜头上拉走了"
        ], of: script)
        #expect(landed == [0, 1])
    }
}

@MainActor
struct SentenceSplitterTests {
    @Test func splitsLatinSentencesKeepingTerminators() {
        #expect(SentenceSplitter.split("One. Two! Three?") == ["One.", "Two!", "Three?"])
    }

    @Test func splitsCJKSentences() {
        #expect(SentenceSplitter.split("第一句。第二句！第三句？") == ["第一句。", "第二句！", "第三句？"])
    }

    @Test func keepsTrailingTextWithNoTerminator() {
        #expect(SentenceSplitter.split("No terminator here") == ["No terminator here"])
    }

    @Test func dropsEmptyFragments() {
        #expect(SentenceSplitter.split("   ") == [])
    }
}

@MainActor
struct TextTokenizerTests {
    @Test func splitsLatinOnWhitespaceAndStripsPunctuation() {
        #expect(TextTokenizer.tokens(in: "Hello, world!") == ["hello", "world"])
    }

    /// The bug this file exists to prevent: one token per sentence.
    @Test func emitsOneTokenPerCJKCharacter() {
        #expect(TextTokenizer.tokens(in: "提词器") == ["提", "词", "器"])
    }

    @Test func dropsCJKPunctuationSoTranscriptsMatchEitherWay() {
        #expect(TextTokenizer.tokens(in: "问题。") == TextTokenizer.tokens(in: "问题"))
    }

    @Test func handlesMixedScript() {
        #expect(TextTokenizer.tokens(in: "Pollux One 从这里开始") == ["pollux", "one", "从", "这", "里", "开", "始"])
    }
}

// MARK: - Feature 4: Safe Word -> Voice Command
//
// What these really guard is the *shape* of recognizer output: a cumulative
// transcript that grows character by character and gets revised. Both engines
// reason about "what's new", which is where this pipeline is easiest to break
// in ways a device demo hides.

@MainActor
private final class SafeWordSpy: SafeWordDetectorDelegate {
    var triggerCount = 0
    func safeWordDetectorDidDetectSafeWord(_ detector: SafeWordDetector) { triggerCount += 1 }
}

@MainActor
private final class VoiceCommandSpy: VoiceCommandEngineDelegate {
    var confirmed: [VoiceCommand] = []
    func voiceCommandEngine(_ engine: VoiceCommandEngine, didChangeState state: VoiceCommandEngineState) {}
    func voiceCommandEngine(_ engine: VoiceCommandEngine, didConfirm command: VoiceCommand) {
        confirmed.append(command)
    }
}

@MainActor
struct SafeWordDetectorTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func makeDetector() -> (SafeWordDetector, SafeWordSpy) {
        let detector = SafeWordDetector()
        let spy = SafeWordSpy()
        detector.delegate = spy
        detector.reset()
        return (detector, spy)
    }

    /// The bug this exists to prevent: recognizers deliver partials one
    /// character at a time, so searching only the newly-appended slice splits
    /// the word ("pol" | "l" | "ux") and it never matches at all.
    @Test func firesOnceWhenTheWordArrivesAsGrowingPartials() {
        let (detector, spy) = makeDetector()
        let phrase = "pollux"
        for endIndex in 1...phrase.count {
            detector.ingest(
                transcript: SpeechTranscript(
                    text: "and so we begin " + phrase.prefix(endIndex),
                    isFinal: endIndex == phrase.count,
                    timestamp: start.addingTimeInterval(Double(endIndex) * 0.1)
                )
            )
        }
        #expect(spy.triggerCount == 1)
    }

    @Test func firesOnceWhenDeliveredWhole() {
        let (detector, spy) = makeDetector()
        detector.ingest(transcript: SpeechTranscript(text: "and so we begin pollux", isFinal: true, timestamp: start))
        #expect(spy.triggerCount == 1)
    }

    @Test func stillDetectsAfterTheTranscriptIsRevisedShorter() {
        let (detector, spy) = makeDetector()
        detector.ingest(transcript: SpeechTranscript(text: "some longer guess here", isFinal: false, timestamp: start))
        detector.ingest(transcript: SpeechTranscript(text: "pollux", isFinal: true, timestamp: start.addingTimeInterval(0.3)))
        #expect(spy.triggerCount == 1)
    }

    @Test func collapsesRepeatedReportsOfOneUtterance() {
        let (detector, spy) = makeDetector()
        for step in 0..<8 {
            detector.ingest(
                transcript: SpeechTranscript(
                    text: "pollux change this to hello",
                    isFinal: false,
                    timestamp: start.addingTimeInterval(Double(step) * 0.2)
                )
            )
        }
        #expect(spy.triggerCount == 1)
    }

    @Test func firesTwiceWhenSaidTwiceFarApart() {
        let (detector, spy) = makeDetector()
        detector.ingest(transcript: SpeechTranscript(text: "pollux", isFinal: true, timestamp: start))
        detector.ingest(
            transcript: SpeechTranscript(
                text: "pollux and later pollux",
                isFinal: true,
                timestamp: start.addingTimeInterval(30)
            )
        )
        #expect(spy.triggerCount == 2)
    }

    @Test func neverFiresOnOrdinaryReading() {
        let (detector, spy) = makeDetector()
        detector.ingest(
            transcript: SpeechTranscript(
                text: "most teleprompters solve the wrong problem",
                isFinal: true,
                timestamp: start
            )
        )
        #expect(spy.triggerCount == 0)
    }

    @Test func isCaseInsensitive() {
        let (detector, spy) = makeDetector()
        detector.ingest(transcript: SpeechTranscript(text: "okay Pollux, listen", isFinal: true, timestamp: start))
        #expect(spy.triggerCount == 1)
    }
}

@MainActor
struct VoiceCommandEngineTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let paragraphId = UUID()

    private func makeEngine() -> (VoiceCommandEngine, VoiceCommandSpy) {
        let engine = VoiceCommandEngine()
        let spy = VoiceCommandSpy()
        engine.delegate = spy
        return (engine, spy)
    }

    private func proposedText(of engine: VoiceCommandEngine) -> String? {
        guard case .awaitingConfirmation(let command) = engine.state,
              case .replaceParagraph(_, let newText) = command.kind else { return nil }
        return newText
    }

    @Test func extractsTheReplacementText() {
        let (engine, _) = makeEngine()
        let before = "we have been reading for a while pollux"
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: before)
        engine.ingest(
            transcript: SpeechTranscript(
                text: before + " change this to we solve eye contact",
                isFinal: true,
                timestamp: start
            )
        )
        #expect(proposedText(of: engine) == "we solve eye contact")
    }

    /// Transcripts are cumulative, so parsing the whole thing picks up a
    /// trigger phrase spoken earlier — including one inside the script.
    @Test func ignoresATriggerPhraseSpokenEarlierInTheTake() {
        let (engine, _) = makeEngine()
        let before = "earlier i said change this to something bogus and kept reading pollux"
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: before)
        engine.ingest(
            transcript: SpeechTranscript(
                text: before + " change this to the real replacement",
                isFinal: true,
                timestamp: start
            )
        )
        #expect(proposedText(of: engine) == "the real replacement")
    }

    /// "Pollux… uh, never mind" must not put a confirmation sheet carrying
    /// junk over the camera preview.
    @Test func doesNotProposeAnythingForUnparseableSpeech() {
        let (engine, _) = makeEngine()
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "pollux")
        engine.ingest(transcript: SpeechTranscript(text: "pollux uh never mind sorry", isFinal: true, timestamp: start))
        #expect(engine.state == .idle)
    }

    @Test func waitsForAFinalResult() {
        let (engine, _) = makeEngine()
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "pollux")
        engine.ingest(transcript: SpeechTranscript(text: "pollux change this to we sol", isFinal: false, timestamp: start))
        #expect(engine.state == .listeningForCommand)
    }

    @Test func timesOutWhenNoCommandArrives() {
        let (engine, _) = makeEngine()
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "pollux", now: start)
        engine.ingest(
            transcript: SpeechTranscript(
                text: "pollux and then i kept reading",
                isFinal: true,
                timestamp: start.addingTimeInterval(60)
            )
        )
        #expect(engine.state == .idle)
    }

    @Test func appliesAConfirmedCommandExactlyOnce() {
        let (engine, spy) = makeEngine()
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "pollux")
        engine.ingest(
            transcript: SpeechTranscript(text: "pollux replace this with a shorter line", isFinal: true, timestamp: start)
        )
        engine.confirm()
        engine.confirm()
        #expect(spy.confirmed.count == 1)
    }

    @Test func rejectingClearsThePendingCommand() {
        let (engine, spy) = makeEngine()
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "pollux")
        engine.ingest(
            transcript: SpeechTranscript(text: "pollux replace this with something", isFinal: true, timestamp: start)
        )
        engine.reject()
        #expect(engine.state == .idle)
        #expect(spy.confirmed.isEmpty)
    }

    @Test func understandsChineseReplacementCommands() {
        let (engine, _) = makeEngine()
        engine.beginListening(currentParagraphId: paragraphId, spokenTextSoFar: "小北")
        engine.ingest(
            transcript: SpeechTranscript(
                text: "小北 把这段改成 我们真正解决的是镜头交流",
                isFinal: true,
                timestamp: start
            )
        )
        #expect(proposedText(of: engine) == "我们真正解决的是镜头交流")
    }
}
