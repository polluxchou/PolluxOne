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

    static func build(_ script: Script) -> PromptScriptText {
        let language = ScriptLanguage.detect(script.fullText)
        let joiner = language.sentenceJoiner

        var text = ""
        var offset = 0
        var ranges: [UUID: Range<Int>] = [:]
        var tokenCounts: [UUID: Int] = [:]
        var hardBreaks: [Int] = []

        for section in script.sections.sorted(by: { $0.order < $1.order }) {
            for paragraph in section.paragraphs.sorted(by: { $0.order < $1.order }) {
                if offset > 0 { hardBreaks.append(offset) }

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
            hardBreaks: hardBreaks,
            language: language
        )
    }
}
