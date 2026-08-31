import SwiftUI

/// A single horizontal audio level bar with a peak marker and a marked
/// clip zone in the last 22% — "audio is alive and not clipping" at a
/// glance, per the design spec, instead of an editing-style waveform.
struct MicLevelBarView: View {
    let level: Float
    var peak: Float = 0

    private let clipZoneStart: CGFloat = 0.78

    var body: some View {
        HStack(spacing: 6) {
            Text("🎤")
                .font(.system(size: 9))
                .opacity(0.55)

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.2))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(HUDColor.levelGreen)
                        .frame(width: width * CGFloat(min(max(level, 0), 1)))

                    Rectangle()
                        .fill(.white.opacity(0.14))
                        .frame(width: width * (1 - clipZoneStart))
                        .offset(x: width * clipZoneStart)

                    Rectangle()
                        .fill(.white.opacity(0.5))
                        .frame(width: 1)
                        .offset(x: width * clipZoneStart)

                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white)
                        .frame(width: 1.5, height: 8)
                        .offset(x: width * CGFloat(min(max(peak, 0), 1)) - 0.75, y: -2)
                }
            }
            .frame(height: 4)
        }
    }
}
