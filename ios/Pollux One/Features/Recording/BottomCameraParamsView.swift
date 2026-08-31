import SwiftUI

/// The parameter row. Each value IS the entry point into its control —
/// tapping "EV -0.3" opens exposure adjustment, no separate row of icon
/// buttons.
///
/// Which columns appear is the camera's answer, not a per-side constant:
/// `CameraConfiguration.visibleParameters` asks the hardware, so the
/// multi-lens back camera earns five columns (its mm and ƒ both move as you
/// switch lenses) and the single-lens front camera gets three.
struct BottomCameraParamsView: View {
    let configuration: CameraConfiguration
    let activeParameter: CameraParameter?
    let onSelect: (CameraParameter) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(configuration.visibleParameters, id: \.self) { parameter in
                ParamButton(
                    title: title(for: parameter),
                    value: value(for: parameter),
                    isActive: activeParameter == parameter
                ) { onSelect(parameter) }
            }
        }
    }

    private func title(for parameter: CameraParameter) -> String {
        switch parameter {
        case .lens: return "LENS"
        case .exposure: return "EV"
        case .focus: return "FOCUS"
        case .depth: return "DEPTH"
        case .format: return "FORMAT"
        }
    }

    private func value(for parameter: CameraParameter) -> String {
        switch parameter {
        case .lens:
            return "\(Int(configuration.focalLengthMillimeters.rounded()))mm"
        case .exposure:
            let bias = configuration.exposureBiasEV
            return bias == 0 ? "0.0" : String(format: "%+.1f", bias)
        case .focus:
            return configuration.focusMode == .locked ? "LOCK" : "AUTO"
        case .depth:
            return configuration.apertureF.map { String(format: "ƒ%.1f", $0) } ?? "—"
        case .format:
            return "\(configuration.resolution.rawValue)·\(configuration.frameRate.rawValue)"
        }
    }
}

private struct ParamButton: View {
    let title: String
    let value: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 8.5))
                    .tracking(1)
                    .foregroundStyle(isActive ? HUDColor.iosYellow : .white.opacity(0.55))
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? HUDColor.iosYellow : .white)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }
}
