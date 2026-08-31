import SwiftUI

/// The core HUD element (Feature 1 + 2): bare text on the preview, one type
/// size throughout, and a progress rail down the right edge instead of a
/// percentage.
///
/// A **fixed window**: 5 rows in Chinese, 6 in Latin, always. The highlight
/// band sits at rows 2–3 (Chinese) or 3–4 (Latin) and never moves; the script
/// scrolls through it a whole row at a time. The previous version sized itself
/// to whatever the current sentence happened to wrap to, so the whole block
/// changed height on every sentence and the reader's eyeline moved with it.
///
/// Three layers, bottom to top: the fixed band (with the read-so-far fill),
/// the scrolling text, the progress rail.
struct TeleprompterOverlayView: View {
    /// The engine itself, not values read off it.
    ///
    /// This used to take `state`, `inLineProgress` and `progressFraction` as
    /// three separate values, and `RecordingView` read all three inside its own
    /// `body`. `@Observable` registers a dependency against whichever body
    /// performed the read, so the two 30Hz properties invalidated the entire
    /// recording screen: measured, 10 changes to `inLineProgress` produced 10
    /// runs of `RecordingView.body` and 10 of this one, which reconstructed the
    /// whole-script `ForEach` each time. (This view carries closures, so
    /// SwiftUI cannot equate it and cannot skip it.) The engine was split into
    /// three properties at three different rates precisely to avoid that, and
    /// reading them one hop too early handed the split straight back.
    ///
    /// Passing the object instead lets each read happen in the smallest view
    /// that needs it: the fill in `HighlightBandView`, the rail in
    /// `ProgressRailView`, and the line window here. Same 10 changes after the
    /// change: 0 parent bodies, 0 overlay bodies, 10 band bodies.
    let engine: TeleprompterEngine
    var textSize: CGFloat = 20
    var micLevel: Float = 0
    /// Only used to warn: the prompter's whole premise is that it sits beside
    /// the lens, which stops being true the moment capture moves to the back.
    var cameraFacing: CameraFacing = .front
    var onTap: () -> Void
    /// Fires whenever the column width or the type size changes, with the
    /// measurer that matches what is now being drawn. The view owns rendering
    /// metrics, so it owns the measurer.
    var onLayoutChange: (CGFloat, TextWidthMeasuring) -> Void

    /// The width the overlay was *offered* — the one width the column can
    /// safely be derived from, because nothing inside the overlay can change
    /// it. Reported by `offeredWidthProbe`.
    ///
    /// This used to be the measured width of the container holding the text,
    /// and that is worth spelling out because the obvious repair to anything
    /// wrong here is to measure the container again. Every row in
    /// `scrollingLines` carries `.fixedSize(horizontal: true, vertical: false)`
    /// so that a line already broken by `PromptLineLayout` can never be
    /// re-wrapped by SwiftUI — which makes that container's width the widest
    /// line's *unwrapped* ideal width, not the column's. Feeding that back
    /// into the line breaker closes a runaway loop: a wider width produces
    /// fewer breaks, fewer breaks produce longer lines, longer lines report a
    /// wider ideal width. It converges on breaking only at
    /// `PromptScriptText.hardBreaks`, i.e. one line per paragraph, each running
    /// off the side of the screen with the band and the mic bar following it
    /// out. That is exactly what the first simulator run showed.
    @State private var offeredWidth: CGFloat = 0

    /// The line window. Changes once per scroll step, so reading it in this
    /// body — rather than in `RecordingView`'s — keeps a line advance from
    /// rebuilding the whole screen alongside the prompter.
    private var state: TeleprompterDisplayState { engine.displayState }

    private let railColumnWidth: CGFloat = 22
    private let railGap: CGFloat = 6
    /// Keeps glyphs off the band's rounded edge. Applied to the text and to
    /// the fill's origin, so the two stay in register.
    private let textInset: CGFloat = 7

    /// The width `PromptLineLayout` breaks against: computed, never measured.
    ///
    /// The rail's column and the gap in front of it are constants, and
    /// `textInset` is spent clearing the band's rounded edge, so what is left
    /// for glyphs follows arithmetically from the offered width and cannot
    /// depend on the text. The other side of that bargain is that the rail's
    /// column has to stay in the `HStack` even when it draws nothing, or the
    /// text would really have 28pt more room than this number claims.
    private var columnWidth: CGFloat {
        max(offeredWidth - railColumnWidth - railGap - textInset, 0)
    }

    private var effectiveTextSize: CGFloat {
        state.language.effectiveTextSize(base: textSize)
    }

    /// One font object, drawn with *and* measured with.
    ///
    /// Every row renders at this exact font and `reportLayout` hands the same
    /// instance to the measurer, so the glyph advances behind
    /// `PromptLine.characterXOffsets` are by construction the advances the text
    /// is drawn at. Two constants — a `Font.Weight` for the rows and a
    /// `UIFont.Weight` for the measurer — could drift apart with nothing
    /// failing to compile, and the symptom would be the highlight edge sliding
    /// along the line instead of landing on a character boundary.
    ///
    /// `Font(rowFont)` is not a change of appearance: measured on the
    /// simulator it renders identical to `.system(size:weight:)` at the same
    /// size and `.medium`, at every size the type slider reaches, and neither
    /// form scales with Dynamic Type.
    private var rowFont: UIFont {
        .systemFont(ofSize: effectiveTextSize, weight: .medium)
    }

    /// Uniform row pitch. There is deliberately no inter-row spacing: an extra
    /// gap means there is no single step to snap to, and the band could not
    /// cover exactly two whole rows.
    private var pitch: CGFloat {
        effectiveTextSize * state.language.lineHeightMultiple
    }

    private var windowHeight: CGFloat {
        CGFloat(state.visibleRows) * pitch
    }

    private var bandTop: CGFloat {
        CGFloat(state.readRowsAbove) * pitch
    }

    var body: some View {
        if state.isVisible {
            VStack(alignment: .leading, spacing: 0) {
                offeredWidthProbe
                window
                footer
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            // The column width changes on its own (the Width slider moves, the
            // device rotates) and the *measurer* changes with the type size and
            // the language, so all three have to reach the engine. The probe
            // covers the first; these two cover the rest.
            .onChange(of: effectiveTextSize) { _, _ in reportLayout() }
            .onChange(of: state.language) { _, _ in reportLayout() }
        }
    }

    /// Reports the width the overlay was offered, and nothing else.
    ///
    /// `Color.clear` hands back exactly the width proposed to it — it has no
    /// content whose size could enter the answer — and a `VStack` passes its
    /// own horizontal proposal across to each child untouched. So this reads
    /// the offer `RecordingView` makes with `containerRelativeFrame`,
    /// `(screenWidth − teleprompterLeading − teleprompterTrailing) ×
    /// textWidthFraction`, no matter what the text is doing. That immunity to
    /// content is the whole requirement; see `offeredWidth`.
    ///
    /// The design note reaches the same width with a `GeometryReader` wrapped
    /// around the block. A `GeometryReader` is greedy on both axes, though, so
    /// the block would claim every point below its 60pt anchor and the
    /// `contentShape` above would start swallowing taps meant for
    /// tap-to-focus. Pinning it to an explicit height means adding up the
    /// window, the footer's padding and the mic bar's own height by hand, and
    /// that sum goes stale the first time the footer gains a row. A zero-height
    /// probe leaves the block's height and position exactly as they were.
    private var offeredWidthProbe: some View {
        Color.clear
            .frame(height: 0)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                offeredWidth = width
                reportLayout()
            }
    }

    // MARK: - Window

    private var window: some View {
        HStack(alignment: .top, spacing: railGap) {
            ZStack(alignment: .topLeading) {
                // No band with nothing on it. There are two ways to have no
                // lines — a script with no text, and the one layout pass that
                // happens before the probe has told the engine how wide the
                // column is — and both used to paint a bare two-row bronze
                // rectangle onto the camera picture.
                if !state.lines.isEmpty {
                    HighlightBandView(
                        engine: engine,
                        line: currentLine,
                        pitch: pitch,
                        bandTop: bandTop,
                        textInset: textInset
                    )
                }
                scrollingLines
            }
            .frame(height: windowHeight, alignment: .top)
            // A backstop, not the mechanism: `scrollingLines` is pinned to
            // `columnWidth`, so reaching this needs a row with no break point
            // in it at all (one very long unbroken token). Such a row is cut
            // at the column's edge, not at the screen's.
            .clipped()

            ProgressRailView(
                engine: engine,
                bandTop: bandTop,
                bandHeight: pitch * 2
            )
            .frame(width: railColumnWidth, height: windowHeight)
            // Faded rather than dropped: `columnWidth` subtracts this column
            // unconditionally, so a rail that took its own space out of the
            // HStack while empty would leave the text 28pt of room the line
            // breaker was never told about.
            .opacity(state.lines.isEmpty ? 0 : 1)
        }
    }

    /// Every line in the script, moved as one block.
    ///
    /// `state.lines` is the whole script, not a 5-row slice, and each row is
    /// identified by its global line index — so a scroll step moves existing
    /// nodes instead of replacing them, and reads as a slide.
    private var scrollingLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.lines) { line in
                Text(line.text)
                    .font(Font(rowFont))
                    .foregroundStyle(.white.opacity(opacity(of: line)))
                    // Never re-wrap: the line was already broken to fit, and a
                    // one-point disagreement with our measurement must not
                    // turn one row into two and desynchronise every row below.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: pitch, alignment: .leading)
                    .shadow(color: .black.opacity(0.65), radius: 5, y: 1)
            }
        }
        // Pinned to the same width the lines were broken against, so a line
        // that overruns the column is structurally impossible to draw past it —
        // the previous `maxWidth: .infinity` let the rows' `fixedSize` widths
        // decide the column's own width, which is the loop described on
        // `offeredWidth`.
        .frame(width: columnWidth, alignment: .leading)
        .padding(.leading, textInset)
        .offset(y: -CGFloat(state.currentLineIndex - state.readRowsAbove) * pitch)
        // Whole-row snapping: the offset changes by exactly one pitch per step.
        // At the start of a script this offset is positive, which drops the
        // block and leaves the top rows blank — the band still does not move,
        // which is why no special case is needed for the first or last lines.
        .animation(.easeOut(duration: 0.3), value: state.currentLineIndex)
        .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // A fraction of the text column, not of the screen: a
            // `containerRelativeFrame` here would resolve against the screen,
            // and the column is narrowed by textWidthFraction, so the bar
            // would stick out past the text it belongs to. It was a fraction
            // of the *measured* column until that measurement turned out to be
            // the widest line's ideal width — which is why the bar ran off the
            // screen alongside the lines.
            MicLevelBarView(level: micLevel)
                .frame(width: columnWidth * 0.45)

            if cameraFacing == .back {
                BackCameraNotice()
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived

    private var currentLine: PromptLine? {
        guard state.lines.indices.contains(state.currentLineIndex) else { return nil }
        return state.lines[state.currentLineIndex]
    }

    /// Roles are a function of distance from the current line, which is what
    /// makes the band's position a constant.
    private func opacity(of line: PromptLine) -> Double {
        switch line.id - state.currentLineIndex {
        case ..<0: 0.32       // read: does not need to be legible any more
        case 0, 1: 1.0        // the band's two rows
        case 2: 0.62          // next up
        default: 0.42
        }
    }

    private func reportLayout() {
        guard columnWidth > 0 else { return }
        onLayoutChange(columnWidth, SystemFontLineMeasurer(font: rowFont))
    }
}

/// The band, drawn *behind* the text and never moved. Its first row also
/// carries the read-so-far fill.
///
/// A separate `View` rather than a computed property on the overlay, and that
/// is the whole reason it exists as a type: it reads `inLineProgress` — which
/// changes 30 times a second — inside its own `body`, so that is the only body
/// the change invalidates. As a computed property its read happened during the
/// overlay's body, which took the whole-script `ForEach` down with it.
///
/// `line` and the metrics come in as values because they are line-rate: the
/// overlay already depends on `displayState` for the row it draws, and passing
/// them keeps this view's own dependency down to the one fast property.
private struct HighlightBandView: View {
    let engine: TeleprompterEngine
    let line: PromptLine?
    let pitch: CGFloat
    let bandTop: CGFloat
    let textInset: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            HUDColor.bronze.opacity(0.55)

            // 0.44 over 0.55 composites to about 0.75 — the spec's figure for
            // the consumed part of the line.
            Rectangle()
                .fill(HUDColor.bronze.opacity(0.44))
                .frame(width: highlightWidth, height: pitch)
                .animation(.linear(duration: 1.0 / 30.0), value: highlightWidth)
        }
        .frame(height: pitch * 2)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .offset(y: bandTop)
        .allowsHitTesting(false)
    }

    /// Where the read/unread boundary sits, in points.
    ///
    /// Read off `characterXOffsets` rather than computed as
    /// `inLineProgress × lineWidth`: in Latin, "i" and "W" are not the same
    /// fraction of a line, so a proportional edge visibly jitters as it
    /// crosses them.
    private var highlightWidth: CGFloat {
        guard let line, line.characterCount > 0 else { return 0 }
        let clamped = min(max(engine.inLineProgress, 0), 1)
        let index = min(
            Int((clamped * Double(line.characterCount)).rounded(.down)),
            line.characterXOffsets.count - 1
        )
        guard index > 0 else { return 0 }
        return textInset + line.characterXOffsets[index]
    }
}

/// Whole-script progress down the right edge, with a bracket marking the two
/// rows the reader is meant to be on.
///
/// Replaces a rail that drew itself from each row's role. With the roles now
/// fixed to row positions, that rail rendered identically forever — the
/// original "position is the readout" idea stopped being true the moment the
/// window stopped moving. Global progress is strictly more information: the
/// old rail could only say where the current sentence sat inside the visible
/// rows, which is now a constant.
///
/// Takes the engine and reads `readingProgress` in its own body, for the same
/// reason as `HighlightBandView`: the fraction changes 30 times a second, and
/// as a value passed down from `RecordingView` it invalidated that whole body
/// instead of this one.
private struct ProgressRailView: View {
    let engine: TeleprompterEngine
    let bandTop: CGFloat
    let bandHeight: CGFloat

    private var fraction: Double { engine.readingProgress.fractionComplete }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: 9)

                Capsule()
                    .fill(HUDColor.bronze)
                    .frame(width: 2, height: geo.size.height * CGFloat(min(max(fraction, 0), 1)))
                    .offset(x: 9)
                    .animation(.easeOut(duration: 0.3), value: fraction)

                BandBracket()
                    .stroke(HUDColor.bronze, lineWidth: 1.5)
                    .frame(width: 5, height: bandHeight)
                    .offset(x: 2, y: bandTop)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Says out loud what the back camera costs. Every other decision in this app
/// is checked against "does this help the speaker hold eye contact with the
/// lens"; shooting from the back is the one state where the answer is no, and
/// a take is easier to fix now than in review.
private struct BackCameraNotice: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash")
                .font(.system(size: 9))
            Text("BACK LENS · NO EYE CONTACT")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.8)
        }
        .fixedSize()
        .foregroundStyle(HUDColor.iosYellow)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

/// A "[" bracketing the band's two rows.
private struct BandBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
