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
    /// 没有稿时为 false。`SessionManager.startTake()` 开头就是
    /// `guard let revision = scriptRevision else { return }`，所以无稿时的快门
    /// 是「看得见、按得动、什么也不发生」——三种状态里最坏的一种。
    ///
    /// **这是一行可逆的判断。** 将来要做「无稿也能拍」，把这个参数连同它的
    /// 调用点一起去掉即可；真正要改的是 `SessionManager`，让它在没有
    /// scriptRevision 时也能起一条 take。那是产品功能，不在这个做界面的计划里。
    let canRecord: Bool
    let onToggleRecording: () -> Void
    let onFlip: () -> Void

    private let sideWidth: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            SafeWordIndicatorView(level: safeWordLevel, safeWord: safeWord)
                .frame(width: sideWidth)

            Spacer()

            RecordButton(isRecording: isRecording, isEnabled: canRecord, action: onToggleRecording)

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
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 33, style: .continuous)
                    // 不可用时红色也退成灰：一个满红的快门是在邀请你按它。
                    .fill(isEnabled ? HUDColor.recRed : Color.white)
                    .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
                    .animation(.easeInOut(duration: 0.2), value: isRecording)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.3)
        .accessibilityHint(isEnabled ? "" : "先交一条新闻给我，或者换一篇稿")
    }
}
