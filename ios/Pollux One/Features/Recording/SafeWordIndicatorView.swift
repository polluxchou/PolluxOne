import SwiftUI

/// Feature 4's only always-visible UI, sitting to the left of the shutter.
/// A 4-bar mini meter (not a full waveform) plus the safe word itself in
/// quotes — background capability at meter scale, per the design spec.
struct SafeWordIndicatorView: View {
    let level: Float
    let safeWord: String

    /// Relative heights from the spec (4/8/11/6px) scaled by the current
    /// input level so it still reads as "listening", not just decoration.
    private let barHeights: [CGFloat] = [4, 8, 11, 6]

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(HUDColor.levelGreen)
                        .frame(width: 2, height: max(2, height * CGFloat(0.4 + 0.6 * level)))
                }
            }
            .frame(height: 11, alignment: .bottom)

            Text("“\(safeWord.uppercased())”")
                .font(.system(size: 9))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.6))
        }
        .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
        .frame(width: 52)
    }
}
