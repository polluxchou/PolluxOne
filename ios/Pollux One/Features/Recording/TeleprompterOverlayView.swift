import SwiftUI

/// The core HUD element (Feature 1 + 2), matching "04 · Recording — HUD" in
/// the Claude Design spec: bare text on the preview (no card), one type size
/// throughout, and a vertical progress rail down the right edge instead of a
/// percentage — "position is the readout."
///
/// Layout mirrors the spec's per-row structure: each line is
/// `[text (flexible) | 6pt gap | 22pt rail column]`, and every row draws its
/// own rail segment (bronze above the anchor, hairline below). Segments bleed
/// 4pt past each row so they join across the row gap into one continuous rail.
struct TeleprompterOverlayView: View {
    let state: TeleprompterDisplayState
    var textSize: CGFloat = 19
    var micLevel: Float = 0
    /// Only used to warn: the prompter's whole premise is that it sits beside
    /// the lens, which stops being true the moment capture moves to the back.
    var cameraFacing: CameraFacing = .front
    var onTap: () -> Void

    private let rowGap: CGFloat = 4
    private let railColumnWidth: CGFloat = 22
    private let railBleed: CGFloat = 4

    /// The spec gives Chinese its own type scale (小/中/大 = 16/18/21 vs the
    /// Latin 17/19/22) and a looser line height: CJK glyphs have a larger
    /// visual body, so matching Latin metrics reads as cramped. Detected from
    /// content rather than a script-level locale field, because a single
    /// script can legitimately mix the two.
    private var isCJK: Bool {
        let sample = state.lines.map(\.text).joined()
        guard !sample.isEmpty else { return false }
        let cjkCount = sample.unicodeScalars.count { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)      // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(scalar.value) // Extension A
                || (0x3000...0x303F).contains(scalar.value) // CJK punctuation
        }
        return Double(cjkCount) / Double(sample.unicodeScalars.count) > 0.2
    }

    private var effectiveTextSize: CGFloat {
        isCJK ? (textSize * 18.0 / 19.0).rounded() : textSize
    }

    private var lineHeightMultiple: CGFloat { isCJK ? 1.6 : 1.5 }

    private var lineHeight: CGFloat { effectiveTextSize * lineHeightMultiple }

    var body: some View {
        if state.isVisible {
            VStack(alignment: .leading, spacing: rowGap) {
                ForEach(Array(state.lines.enumerated()), id: \.element.id) { index, line in
                    // The rail is an overlay, not an HStack sibling: as a
                    // sibling its flexible height made every row greedy and
                    // the four lines spread down the whole screen.
                    text(for: line)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, railColumnWidth + 6)
                        .overlay(alignment: .topTrailing) {
                            rail(for: line, isLast: index == state.lines.count - 1)
                                .frame(width: railColumnWidth)
                        }
                }

                HStack(spacing: 8) {
                    MicLevelBarView(level: micLevel)
                        .containerRelativeFrame(.horizontal) { width, _ in width * 0.45 }

                    if cameraFacing == .back {
                        BackCameraNotice()
                    }
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .animation(.easeInOut(duration: 0.2), value: state.lines)
        }
    }

    // MARK: - Text

    @ViewBuilder
    private func text(for line: TeleprompterLine) -> some View {
        switch line.emphasis {
        case .current:
            // Only the current sentence wraps; it's the one you're reading.
            Text(line.text)
                .font(.system(size: effectiveTextSize, weight: .medium))
                .lineSpacing(effectiveTextSize * (lineHeightMultiple - 1.18))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    HUDColor.bronze.opacity(0.42),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        case .past:
            singleLine(line.text, opacity: 0.45)
        case .upcoming:
            singleLine(line.text, opacity: isFirstUpcoming(line) ? 0.62 : 0.45)
        }
    }

    /// Context lines clip rather than wrap, so the current sentence stays the
    /// only thing that can grow and push itself away from the lens.
    private func singleLine(_ value: String, opacity: Double) -> some View {
        Text(value)
            .font(.system(size: effectiveTextSize))
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: lineHeight, alignment: .center)
            .shadow(color: .black.opacity(0.65), radius: 5, y: 1)
    }

    private func isFirstUpcoming(_ line: TeleprompterLine) -> Bool {
        state.lines.first { $0.emphasis == .upcoming }?.id == line.id
    }

    // MARK: - Progress rail

    @ViewBuilder
    private func rail(for line: TeleprompterLine, isLast: Bool) -> some View {
        switch line.emphasis {
        case .past:
            // Fully read: thick bronze stroke.
            railBar(width: 3, color: HUDColor.bronze, leading: 8)
        case .current:
            // The anchor. Bronze down to the midpoint, hairline after it,
            // and an arrow pointing back at the sentence being read.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(HUDColor.bronze)
                        .frame(width: 3, height: geo.size.height / 2 + railBleed)
                        .offset(x: 8, y: -railBleed)
                    Rectangle()
                        .fill(.white.opacity(0.28))
                        .frame(width: 1, height: geo.size.height / 2 + railBleed)
                        .offset(x: 9, y: geo.size.height / 2)
                    Triangle()
                        .fill(HUDColor.bronze)
                        .frame(width: 5, height: 8)
                        .offset(x: 1, y: geo.size.height / 2 - 4)
                }
            }
        case .upcoming:
            // Still ahead: hairline. The last row stops short instead of
            // bleeding, so the rail ends rather than running off.
            railBar(width: 1, color: .white.opacity(0.28), leading: 9, bleedBottom: !isLast)
        }
    }

    private func railBar(
        width: CGFloat,
        color: Color,
        leading: CGFloat,
        bleedBottom: Bool = true
    ) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .padding(.top, -railBleed)
            .padding(.bottom, bleedBottom ? -railBleed : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, leading)
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

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
