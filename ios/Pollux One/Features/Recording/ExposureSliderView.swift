import SwiftUI

/// The inline control that appears above the camera-params row when EV is
/// the active parameter — "current value = control entry point" means
/// tapping "EV −0.3" reveals exactly this, not a sheet. Center notch at 0,
/// yellow fill across whatever offset is dialled in, per the design spec.
struct ExposureSliderView: View {
    let valueEV: Double
    let minEV: Double
    let maxEV: Double
    var label: String = "EV"
    var onChange: (Double) -> Void

    private let width: CGFloat = 150
    private var fraction: CGFloat {
        guard maxEV > minEV else { return 0.5 }
        return CGFloat((valueEV - minEV) / (maxEV - minEV))
    }
    private var centerFraction: CGFloat {
        guard maxEV > minEV else { return 0.5 }
        return CGFloat((0 - minEV) / (maxEV - minEV))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Text(evLabel)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(HUDColor.iosYellow)
                .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                .offset(y: -15)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.white.opacity(0.3))
                    .frame(width: width, height: 2)

                Rectangle()
                    .fill(.white.opacity(0.4))
                    .frame(width: 1, height: 12)
                    .offset(x: width * centerFraction)

                fillSegment

                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.55), radius: 5, y: 1)
                    .offset(x: width * fraction - 6)
            }
            .frame(width: width, height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let clamped = min(max(drag.location.x / width, 0), 1)
                    onChange(minEV + Double(clamped) * (maxEV - minEV))
                }
            )
        }
    }

    private var evLabel: String {
        let sign = valueEV == 0 ? "" : (valueEV > 0 ? "+" : "")
        return "\(label) \(sign)\(String(format: "%.1f", valueEV))"
    }

    @ViewBuilder
    private var fillSegment: some View {
        let lower = min(fraction, centerFraction)
        let upper = max(fraction, centerFraction)
        Rectangle()
            .fill(HUDColor.iosYellow)
            .frame(width: width * (upper - lower), height: 2)
            .offset(x: width * lower)
    }
}
