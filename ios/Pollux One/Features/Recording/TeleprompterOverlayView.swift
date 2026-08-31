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
    let state: TeleprompterDisplayState
    /// 0...1 along the current line. Separate from `state` so a 30Hz change
    /// invalidates only the fill — see `TeleprompterEngine`.
    var inLineProgress: Double = 0
    var progressFraction: Double = 0
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

    @State private var measuredWidth: CGFloat = 0

    private let railColumnWidth: CGFloat = 22
    private let railGap: CGFloat = 6
    /// Keeps glyphs off the band's rounded edge. Applied to the text and to
    /// the fill's origin, so the two stay in register.
    private let textInset: CGFloat = 7
    /// One weight for every row — see the note above.
    private let rowWeight: Font.Weight = .medium
    private let uiRowWeight: UIFont.Weight = .medium

    private var effectiveTextSize: CGFloat {
        state.language.effectiveTextSize(base: textSize)
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
                window
                footer
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }

    // MARK: - Window

    private var window: some View {
        HStack(alignment: .top, spacing: railGap) {
            ZStack(alignment: .topLeading) {
                band
                scrollingLines
            }
            .frame(height: windowHeight, alignment: .top)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                measuredWidth = width
                reportLayout()
            }
            .onChange(of: effectiveTextSize) { _, _ in reportLayout() }
            .onChange(of: state.language) { _, _ in reportLayout() }

            ProgressRailView(
                fraction: progressFraction,
                bandTop: bandTop,
                bandHeight: pitch * 2
            )
            .frame(width: railColumnWidth, height: windowHeight)
        }
    }

    /// The band, drawn *behind* the text and never moved. Its first row also
    /// carries the read-so-far fill.
    private var band: some View {
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

    /// Every line in the script, moved as one block.
    ///
    /// `state.lines` is the whole script, not a 5-row slice, and each row is
    /// identified by its global line index — so a scroll step moves existing
    /// nodes instead of replacing them, and reads as a slide.
    private var scrollingLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.lines) { line in
                Text(line.text)
                    .font(.system(size: effectiveTextSize, weight: rowWeight))
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
        .padding(.leading, textInset)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // Sized from the measured column, not `containerRelativeFrame`:
            // that resolves against the screen, and the column is now
            // narrowed by textWidthFraction, so a screen-relative bar sticks
            // out past the text it belongs to.
            MicLevelBarView(level: micLevel)
                .frame(width: max(measuredWidth, 0) * 0.45)

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

    /// Where the read/unread boundary sits, in points.
    ///
    /// Read off `characterXOffsets` rather than computed as
    /// `inLineProgress × lineWidth`: in Latin, "i" and "W" are not the same
    /// fraction of a line, so a proportional edge visibly jitters as it
    /// crosses them.
    private var highlightWidth: CGFloat {
        guard let line = currentLine, line.characterCount > 0 else { return 0 }
        let clamped = min(max(inLineProgress, 0), 1)
        let index = min(
            Int((clamped * Double(line.characterCount)).rounded(.down)),
            line.characterXOffsets.count - 1
        )
        guard index > 0 else { return 0 }
        return textInset + line.characterXOffsets[index]
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
        guard measuredWidth > textInset else { return }
        onLayoutChange(
            measuredWidth - textInset,
            SystemFontLineMeasurer(textSize: effectiveTextSize, weight: uiRowWeight)
        )
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
private struct ProgressRailView: View {
    let fraction: Double
    let bandTop: CGFloat
    let bandHeight: CGFloat

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
