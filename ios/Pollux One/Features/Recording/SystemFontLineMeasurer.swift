import CoreText
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
struct SystemFontLineMeasurer: TextWidthMeasuring {
    private let font: UIFont

    init(font: UIFont) {
        self.font = font
    }

    /// Typesets the whole string once and reads each character's advance out of
    /// the result, rather than measuring characters one at a time.
    ///
    /// Measuring one at a time is what this did first, with a
    /// `[Character: CGFloat]` cache to keep the call count down, and in Chinese
    /// it under-measured every line that contained punctuation. A `，` or `。`
    /// measured alone is 9.6pt at 19pt type, because it is then the last thing
    /// in its run and the text engine squeezes trailing CJK punctuation; the
    /// same character inside a sentence draws its full 19.1pt cell. Two commas
    /// on a line bought the line breaker ~19pt of width that does not exist, so
    /// it fitted one glyph too many and the row's last character was drawn half
    /// outside the column. On the simulator that is a `说` with its right half
    /// sliced off — the clip is doing its job, over text that should never have
    /// been put there.
    ///
    /// Measured against `NSAttributedString.size()` over the app's own sample
    /// scripts, these advances now sum to the drawn width of the whole script
    /// exactly, in both languages, and no line overflows its column at any
    /// width the slider reaches. It also picks up Latin kerning, which the
    /// per-character version could not see and which was making the highlight
    /// edge drift a fraction of a glyph further along every word.
    ///
    /// One `CTLine` over ~400 characters costs about 1ms against 0.33ms for the
    /// cached per-character version. Re-layout only happens when the column
    /// width or the type size changes, i.e. while a slider is being dragged, so
    /// this is affordable — and correct line breaking is not optional.
    func characterWidths(of text: String) -> [CGFloat] {
        guard !text.isEmpty else { return [] }

        // Safe as one line because `PromptScriptText.text` holds no newlines by
        // construction — paragraph boundaries live in `hardBreaks` instead. A
        // `CTLine` stops at the first newline, so a text that grew one would
        // silently report zero-width characters after it.
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )

        var widths: [CGFloat] = []
        widths.reserveCapacity(text.count)
        // Character-by-character, but the offsets are UTF-16: everything above
        // this counts in Characters, and one Character can be several UTF-16
        // units (an emoji in a script, a combining mark).
        var utf16Offset = 0
        var previousX = CTLineGetOffsetForStringIndex(line, 0, nil)
        for character in text {
            utf16Offset += character.utf16.count
            let x = CTLineGetOffsetForStringIndex(line, CFIndex(utf16Offset), nil)
            widths.append(x - previousX)
            previousX = x
        }
        return widths
    }
}
