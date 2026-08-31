import SwiftUI

/// The lens pill (`.5 · 1× · 2`), its own centered row above the shutter —
/// Apple's position, untouched. Only lenses the device actually has appear
/// (DeviceCapabilityService decides that upstream).
struct LensSelectorView: View {
    let availableLenses: [CameraLensPosition]
    let currentLens: CameraLensPosition
    let onSelectLens: (CameraLensPosition) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(availableLenses, id: \.self) { lens in
                LensButton(
                    title: label(for: lens),
                    isSelected: currentLens == lens,
                    action: { onSelectLens(lens) }
                )
            }
        }
        .padding(4)
        .background(.black.opacity(0.35), in: Capsule())
    }

    private func label(for lens: CameraLensPosition) -> String {
        switch lens {
        case .ultraWide: return ".5"
        case .wide: return "1×"
        case .telephoto: return "2"
        }
    }
}

private struct LensButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: isSelected ? 13 : 12, weight: isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? HUDColor.iosYellow : Color.white)
                .frame(width: isSelected ? 36 : 32, height: isSelected ? 36 : 32)
                .background(isSelected ? Color.white.opacity(0.16) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
