import SwiftUI
import UIKit

/// Real glyph advances for the prompter's line layout.
///
/// The font must be the one the overlay actually renders with, or lines break
/// somewhere other than where they are drawn — and the character-granular
/// highlight edge lands on the wrong glyph. SwiftUI's
/// `Font.system(size:weight:)` is `UIFont.systemFont(ofSize:weight:)`, so that
/// is what gets measured, at the same single weight every row is drawn in.
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

    init(textSize: CGFloat, weight: UIFont.Weight = .medium) {
        self.font = UIFont.systemFont(ofSize: textSize, weight: weight)
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
