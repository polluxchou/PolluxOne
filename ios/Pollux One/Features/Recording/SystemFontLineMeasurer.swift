import SwiftUI
import UIKit

/// Real glyph advances for the prompter's line layout.
///
/// The font must be the one the overlay actually renders with, or lines break
/// somewhere other than where they are drawn — and the character-granular
/// highlight edge lands on the wrong glyph. So it is taken as a value rather
/// than rebuilt here from a size and a weight: the overlay draws its rows with
/// `Font(_:)` around this very instance, which makes "drawn with" and
/// "measured with" the same object instead of two descriptions that have to
/// agree.
///
/// Measures only; breaking stays in `PromptLineLayout` (see the note on
/// `TextWidthMeasuring`).
///
/// Per-character measurement ignores kerning and ligatures between characters,
/// so a long Latin line measures a hair wider than it draws. That direction is
/// the safe one — the line breaks slightly early rather than overflowing — and
/// the overlay leaves a small margin on top of it.
struct SystemFontLineMeasurer: TextWidthMeasuring {
    private let font: UIFont

    init(font: UIFont) {
        self.font = font
    }

    func characterWidths(of text: String) -> [CGFloat] {
        // A script draws on a few hundred distinct characters, so measuring
        // each one once turns thousands of text-layout calls into a few
        // hundred. Called on every re-layout (type size, column width), which
        // happens while a slider is being dragged.
        var cache: [Character: CGFloat] = [:]
        return text.map { character in
            if let cached = cache[character] { return cached }
            let width = NSAttributedString(
                string: String(character),
                attributes: [.font: font]
            ).size().width
            cache[character] = width
            return width
        }
    }
}
