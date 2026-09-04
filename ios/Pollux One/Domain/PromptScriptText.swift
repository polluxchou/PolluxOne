import Foundation

/// The one string the prompter lays out, plus the index that maps a sentence
/// back into it.
///
/// Everything downstream measures in *character offsets into `text`*: the
/// line layout, the reading cursor, the speech-truth lookup. That only holds
/// if there is exactly one way a Script becomes a string. Two independent
/// concatenations differ by whatever separators each chose, and the cursor
/// then sits a few characters off — permanently, and worse the longer the
/// script runs.
///
/// Paragraph boundaries are recorded as offsets in `hardBreaks` rather than
/// as "\n" in the text. A newline would occupy a character offset that is
/// never spoken, so the cursor would have to skip it and every offset after a
/// paragraph would be shifted by one. Keeping `text` to exactly the
/// characters a reader says out loud removes that whole class of off-by-one.
struct PromptScriptText: Equatable {
    let text: String
    /// Sentence id -> its range in `text`, counted in Characters (not UTF-16
    /// units: the layout works in Characters, and CJK would disagree).
    let sentenceRanges: [UUID: Range<Int>]
    /// Sentence id -> how many tokens `TextTokenizer` produces for it.
    ///
    /// **Not** `Sentence.tokens.count`. Those are two different tokenizations:
    /// `Token.tokenize` splits on spaces (`ScriptModels.swift:73`), while
    /// `ReadingPosition.tokenIndexInSentence` is an index into
    /// `TextTokenizer.tokens(in:)`, which emits CJK per character. A whole
    /// Chinese sentence is *one* space-delimited token, so using that count as
    /// the denominator makes the ratio permanently >= 1 and pins every truth
    /// at the end of its sentence — the Chinese prompter would sit still for a
    /// whole sentence and then jump. Nothing crashes; it just looks broken.
    let sentenceTokenCounts: [UUID: Int]
    /// Paragraph id -> the offset in `text` where that paragraph begins.
    ///
    /// Exists for `resumeOffset(for:)` and nothing else: a Safe Word edit
    /// destroys the sentence ids inside the paragraph it rewrites, and the
    /// paragraph id is then the only part of the reader's address still
    /// present in the rebuilt script.
    let paragraphOffsets: [UUID: Int]
    /// Offsets no line may run across — paragraph and section boundaries.
    let hardBreaks: [Int]
    let language: ScriptLanguage

    /// Where an alignment result sits, as a fractional character offset.
    ///
    /// Linear interpolation across the sentence's tokens rather than an exact
    /// token-to-character map: the error is bounded by one token's width, and
    /// the correction loop in `ReadingPacer` pulls it back on every result.
    /// An exact map would mean teaching `TextTokenizer` to return ranges,
    /// which costs far more than it buys here.
    func characterOffset(of position: ReadingPosition) -> Double? {
        let sentenceId = position.address.sentenceId
        guard let range = sentenceRanges[sentenceId],
              let tokenCount = sentenceTokenCounts[sentenceId],
              tokenCount > 0 else { return nil }

        let ratio = min(max(Double(position.tokenIndexInSentence) / Double(tokenCount), 0), 1)
        return Double(range.lowerBound) + ratio * Double(range.count)
    }

    /// Where a reload should put the reader, given the address they were last
    /// known to be at.
    ///
    /// Three answers in decreasing precision: the sentence's own offset, the
    /// offset the sentence's paragraph begins at, then the top of the script.
    ///
    /// The middle one is the whole reason this method exists. `load` used to
    /// resolve only the sentence — `sentenceRanges[address.sentenceId]` with a
    /// bare `?? 0` behind it — which reads as a safe default and is in fact the
    /// opposite. The one caller that passes an address is a Safe Word edit, and
    /// it rebuilds the edited paragraph with `SentenceSplitter.sentences(from:)`,
    /// whose `Sentence.init(order:text:)` mints a fresh `UUID` for every
    /// sentence. `SessionManager.currentParagraphId()` then guarantees the
    /// rewritten paragraph is the one the reader is standing in — so the
    /// sentence lookup missed *every single time*, and correcting one sentence
    /// mid-take threw the reader back to the top of their script (measured:
    /// cursor 80.0 -> 0.0). The parameter existed precisely to stop that and
    /// failed in the only case it was written for.
    ///
    /// Landing at the top of the edited paragraph is the honest answer: the
    /// text the old character offset pointed into no longer exists, so there is
    /// nothing to preserve it against. The paragraph the reader is in is the
    /// finest granularity that survives the edit, and it is a few seconds of
    /// re-reading rather than the whole script.
    func resumeOffset(for address: ScriptAddress) -> Int {
        sentenceRanges[address.sentenceId]?.lowerBound
            ?? paragraphOffsets[address.paragraphId]
            ?? 0
    }

    static func build(_ script: Script) -> PromptScriptText {
        let language = ScriptLanguage.detect(script.fullText)
        let joiner = language.sentenceJoiner

        var text = ""
        var offset = 0
        var ranges: [UUID: Range<Int>] = [:]
        var tokenCounts: [UUID: Int] = [:]
        var paragraphOffsets: [UUID: Int] = [:]
        var hardBreaks: [Int] = []

        for section in script.sections.sorted(by: { $0.order < $1.order }) {
            for paragraph in section.paragraphs.sorted(by: { $0.order < $1.order }) {
                if offset > 0 { hardBreaks.append(offset) }
                // Recorded before the sentences are walked, so a paragraph
                // that ends up with no text still resolves to where it would
                // have started rather than dropping out of the index.
                paragraphOffsets[paragraph.id] = offset

                let sentences = paragraph.sentences.sorted { $0.order < $1.order }
                for (index, sentence) in sentences.enumerated() {
                    if index > 0 {
                        text += joiner
                        offset += joiner.count
                    }
                    let start = offset
                    text += sentence.text
                    offset += sentence.text.count
                    ranges[sentence.id] = start..<offset
                    tokenCounts[sentence.id] = TextTokenizer.tokens(in: sentence.text).count
                }
            }
        }

        return PromptScriptText(
            text: text,
            sentenceRanges: ranges,
            sentenceTokenCounts: tokenCounts,
            paragraphOffsets: paragraphOffsets,
            hardBreaks: hardBreaks,
            language: language
        )
    }
}
