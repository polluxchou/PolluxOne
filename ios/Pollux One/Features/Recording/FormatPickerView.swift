import SwiftUI

/// The control behind the FORMAT readout: tapping `4K·60` opens this, per the
/// HUD's "current value is the control entry point" rule.
///
/// Only combinations the active camera actually reports are offered. That's
/// the whole reason it takes `availableResolutions`/`availableFrameRates`
/// rather than iterating the enums: the front camera on most phones can't do
/// 4K60, and offering it would be a control that silently does nothing —
/// which the spec rules out ("绝对不要显示设备实际不支持的 Camera Parameter").
struct FormatPickerView: View {
    let resolution: RecordingResolution
    let frameRate: RecordingFrameRate
    let availableResolutions: [RecordingResolution]
    let availableFrameRates: [RecordingFrameRate]
    /// Disabled mid-take: changing `activeFormat` while `movieOutput` is
    /// recording ends the file early.
    let isEnabled: Bool
    let onSelect: (RecordingResolution, RecordingFrameRate) -> Void

    var body: some View {
        VStack(spacing: 8) {
            row(
                options: availableResolutions,
                isSelected: { $0 == resolution },
                label: \.rawValue,
                select: { onSelect($0, frameRate) }
            )
            row(
                options: availableFrameRates,
                isSelected: { $0 == frameRate },
                label: { "\($0.rawValue)" },
                select: { onSelect(resolution, $0) }
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
    }

    private func row<Option: Hashable>(
        options: [Option],
        isSelected: @escaping (Option) -> Bool,
        label: @escaping (Option) -> String,
        select: @escaping (Option) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = isSelected(option)
                Button {
                    select(option)
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: selected ? .bold : .semibold))
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            selected ? HUDColor.iosYellow : Color.white.opacity(0.14),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
