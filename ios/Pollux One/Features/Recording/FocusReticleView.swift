import SwiftUI

/// Tap-to-focus feedback: a bordered square with two opposite corner
/// accents, not full four-corner AF brackets — matches the design spec's
/// minimal reticle. Shown briefly at the tap point, then fades.
struct FocusReticleView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(HUDColor.iosYellow, lineWidth: 1)
            VStack {
                HStack {
                    Rectangle().fill(HUDColor.iosYellow).frame(width: 12, height: 1)
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Rectangle().fill(HUDColor.iosYellow).frame(width: 12, height: 1)
                }
            }
        }
        .frame(width: 74, height: 74)
    }
}
