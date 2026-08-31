import SwiftUI

/// The lens pill (`.5 · 1× · 2`), its own centered row above the shutter —
/// Apple's position, untouched. The options come from the active camera's own
/// constituent lenses, so the back camera shows that phone's real multipliers
/// and the single-lens front camera shows no pill at all: the pill's presence
/// and contents are themselves how you tell the two cameras apart.
struct LensSelectorView: View {
    let lenses: [CameraLensOption]
    let currentLens: CameraLensPosition
    let onSelectLens: (CameraLensOption) -> Void

    var body: some View {
        // One lens is not a choice. The front camera gets nothing here rather
        // than a dead single-item control implying a switch that isn't there.
        if lenses.count > 1 {
            HStack(spacing: 6) {
                ForEach(lenses) { lens in
                    LensButton(
                        title: label(for: lens, isSelected: lens.position == currentLens),
                        isSelected: lens.position == currentLens,
                        action: { onSelectLens(lens) }
                    )
                }
            }
            .padding(4)
            .background(.black.opacity(0.35), in: Capsule())
        }
    }

    /// Apple's convention: the selected lens carries the `×`, the rest are
    /// bare numbers, and anything under 1× drops its leading zero (`.5`).
    private func label(for lens: CameraLensOption, isSelected: Bool) -> String {
        let zoom = (lens.displayZoom * 10).rounded() / 10
        var text: String
        if zoom < 1 {
            text = String(format: "%.1f", zoom)
            if text.hasPrefix("0") { text.removeFirst() }
        } else if zoom == zoom.rounded() {
            text = "\(Int(zoom))"
        } else {
            text = String(format: "%.1f", zoom)
        }
        return isSelected ? text + "×" : text
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
