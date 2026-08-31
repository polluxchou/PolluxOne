import SwiftUI

/// The bottom row: safe-word meter (left) · shutter (centre) · flip (right),
/// space-between, exactly as the spec lays it out. The safe word and flip
/// containers are equal width so the shutter stays optically centred.
struct ShutterRowView: View {
    let isRecording: Bool
    let safeWordLevel: Float
    let safeWord: String
    let onToggleRecording: () -> Void
    let onFlip: () -> Void

    private let sideWidth: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            SafeWordIndicatorView(level: safeWordLevel, safeWord: safeWord)
                .frame(width: sideWidth)

            Spacer()

            RecordButton(isRecording: isRecording, action: onToggleRecording)

            Spacer()

            Button(action: onFlip) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .frame(width: sideWidth)
        }
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 33, style: .continuous)
                    .fill(HUDColor.recRed)
                    .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
                    .animation(.easeInOut(duration: 0.2), value: isRecording)
            }
        }
        .buttonStyle(.plain)
    }
}
