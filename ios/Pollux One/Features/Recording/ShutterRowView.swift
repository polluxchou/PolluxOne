import SwiftUI

/// The bottom row: safe-word meter (left) · shutter (centre) · camera flip
/// (right), space-between, exactly as the spec lays it out. The safe word and
/// flip containers are equal width so the shutter stays optically centred.
struct ShutterRowView: View {
    let isRecording: Bool
    let safeWordLevel: Float
    let safeWord: String
    let facing: CameraFacing
    let canFlip: Bool
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

            FlipButton(facing: facing, isEnabled: canFlip, action: onFlip)
                .frame(width: sideWidth)
        }
    }
}

/// Names the camera you're on rather than only offering a rotation glyph.
/// Which side is live decides whether the prompter is anywhere near the lens
/// you're looking into, so it's worth a word instead of an inference from a
/// mirrored preview.
private struct FlipButton: View {
    let facing: CameraFacing
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                Text(facing.displayName)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(1)
                    // Yellow is this HUD's "not the default state" colour, and
                    // BACK is exactly that: the prompter has left the lens.
                    .foregroundStyle(facing == .back ? HUDColor.iosYellow : .white.opacity(0.55))
            }
            .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        // Swapping the capture input mid-take ends the movie file early, so
        // the flip is off while rolling rather than silently killing a take.
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
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
