import SwiftUI

/// Section 5: adjusting teleprompter position/size/width/opacity is a
/// temporary mode entered by tapping the teleprompter text, not a
/// permanently docked slider — a docked vertical slider would sit exactly
/// where the exposure slider does and the two would get confused.
struct TeleprompterSettings: Equatable {
    var verticalOffset: CGFloat = 0
    var textSize: CGFloat = 20
    var textWidthFraction: CGFloat = 0.86
    var opacity: Double = 1.0
}

struct TeleprompterAdjustView: View {
    @Binding var settings: TeleprompterSettings
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Adjust Teleprompter")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))

            AdjustRow(title: "Position", value: settings.verticalOffset, range: -60...60) {
                settings.verticalOffset = $0
            }
            AdjustRow(title: "Text Size", value: settings.textSize, range: 15...28) {
                settings.textSize = $0
            }
            AdjustRow(title: "Width", value: settings.textWidthFraction, range: 0.5...1.0) {
                settings.textWidthFraction = $0
            }
            AdjustRow(title: "Opacity", value: settings.opacity, range: 0.3...1.0) {
                settings.opacity = $0
            }

            Button("Done", action: onDone)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.yellow)
        }
        .padding(20)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 24)
    }
}

private struct AdjustRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void

    init(title: String, value: CGFloat, range: ClosedRange<Double>, onChange: @escaping (CGFloat) -> Void) {
        self.title = title
        self.value = Double(value)
        self.range = range
        self.onChange = { onChange(CGFloat($0)) }
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .tint(.yellow)
        }
    }
}
