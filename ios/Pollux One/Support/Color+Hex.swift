import SwiftUI

/// HUD colors pulled directly from the Claude Design spec (`Pollux One iOS.dc.html`,
/// frame "04 · Recording — HUD"). Named after what they mean in that spec rather
/// than generic "accent1/accent2" so future edits can check back against it.
enum HUDColor {
    /// #c49a6c — the "九点时光" design system's brand bronze/tan, reused here
    /// for the read-progress rail and the current-line highlight scrim.
    static let bronze = Color(hex: 0xc49a6c)
    /// #ffd60a — iOS Camera's own yellow, for whichever parameter is active.
    static let iosYellow = Color(hex: 0xffd60a)
    static let recRed = Color(hex: 0xff4d4f)
    static let levelGreen = Color(hex: 0x52c41a)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}
