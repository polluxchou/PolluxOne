import SwiftUI

/// Left/right of the Dynamic Island: REC state + elapsed time, and estimated
/// recording time left. Matches the Claude Design spec exactly — no mic
/// waveform up here (that lives under the teleprompter now) and no script
/// progress percentage (the teleprompter's progress rail is the readout).
struct TopHUDView: View {
    let isRecording: Bool
    let elapsedSeconds: TimeInterval
    let remainingRecordingTime: TimeInterval?

    var body: some View {
        HStack {
            HStack(spacing: 7) {
                Circle()
                    .fill(HUDColor.recRed)
                    .frame(width: 7, height: 7)
                Text("REC")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                Text(Self.elapsedFormatter(elapsedSeconds))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
            }

            Spacer()

            HStack(spacing: 5) {
                Text("LEFT")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
                Text(remainingRecordingTime.map { Self.remainingFormatter($0) } ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
            }
        }
        .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    private static func elapsedFormatter(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// "1h42m", or past a day just "31h" — per spec, minutes stop mattering
    /// once you're estimating more than a day of headroom.
    private static func remainingFormatter(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours >= 24 { return "\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}
