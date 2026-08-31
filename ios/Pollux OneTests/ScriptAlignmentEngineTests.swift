import Testing
@testable import Pollux_One

/// Reading-following is the product. These cases are the behaviours a real
/// speaker produces — pauses, repeats, skipped lines, paraphrase, punctuation
/// the recognizer never emits — checked without a camera or microphone, since
/// alignment is pure data in / data out.
///
/// The same scenarios also run headlessly via `scripts/test-alignment.sh`,
/// which compiles the Domain + engine sources directly. Keep the two in sync
/// when adding cases.
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
