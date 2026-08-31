import SwiftUI

/// LENS · EV · FOCUS · DEPTH · FORMAT. Each value IS the entry point into
/// its control — tapping "EV -0.3" opens exposure adjustment, no separate
/// row of icon buttons. A parameter only appears when the device/mode
/// actually supports it (DeviceCapabilityService decides that upstream).
struct BottomCameraParamsView: View {
    let configuration: CameraConfiguration
    let activeParameter: CameraParameter?
    let onSelect: (CameraParameter) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Column order/content fixed here; DEPTH is the only one that's
            // conditionally hidden (front-camera aperture isn't simulatable).
            ParamButton(
                title: "LENS",
                value: "\(Int(configuration.focalLengthMillimeters))mm",
                isActive: activeParameter == .lens
            ) { onSelect(.lens) }

            ParamButton(
                title: "EV",
                value: evLabel,
                isActive: activeParameter == .exposure
            ) { onSelect(.exposure) }

            ParamButton(
                title: "FOCUS",
                value: configuration.focusMode == .locked ? "LOCK" : "AUTO",
                isActive: activeParameter == .focus
            ) { onSelect(.focus) }

            if let aperture = configuration.apertureF, configuration.supportsDepth {
                ParamButton(
                    title: "DEPTH",
                    value: String(format: "ƒ%.1f", aperture),
                    isActive: activeParameter == .depth
                ) { onSelect(.depth) }
            }

            ParamButton(
                title: "FORMAT",
                value: "\(configuration.resolution.rawValue)·\(configuration.frameRate.rawValue)",
                isActive: activeParameter == .format
            ) { onSelect(.format) }
        }
    }

    private var evLabel: String {
        let bias = configuration.exposureBiasEV
        return bias == 0 ? "0.0" : String(format: "%+.1f", bias)
    }
}

enum CameraParameter: Equatable {
    case lens, exposure, focus, depth, format
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
