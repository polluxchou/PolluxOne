import Foundation

/// Deterministic stand-in for font metrics: one em per CJK character, half an
/// em for everything else (including spaces).
///
/// The point is not realism — it is that break positions become arithmetic.
/// With em = 10 and a 100pt line, Chinese fits exactly 10 characters and
/// Latin exactly 20, so a scenario can assert the break index rather than
/// "roughly wraps somewhere sensible". Real font metrics would make every one
/// of those assertions a guess, and would need a font installed on the
/// machine running the suite.
struct FakeTextMeasurer: TextWidthMeasuring {
    let em: CGFloat

    init(em: CGFloat = 10) {
        self.em = em
    }

    func characterWidths(of text: String) -> [CGFloat] {
        text.map { character in
            character.isCJKIdeographOrKana || character.isCJKPunctuation ? em : em / 2
        }
    }
}
