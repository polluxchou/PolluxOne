import SwiftUI

/// ④ 确认。spec §2.2：横轴通俗↔专业，纵轴时长（最长 6min）。
/// 余额门禁在这一屏，因为这是**烧 token 之前的最后一屏**——
/// 跑完才发现余额不够是不能接受的。
struct ConfirmView: View {
    let news: NewsRef
    @State private var dial: DialState
    let onStart: (DialState) -> Void

    init(news: NewsRef, dial: DialState = DialState(), onStart: @escaping (DialState) -> Void) {
        self.news = news
        _dial = State(initialValue: dial)
        self.onStart = onStart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NewsTag(news: news)
            readout
            DialControl(dial: $dial)
            Spacer(minLength: 0)
            estimateRow
            if let reason = dial.blockReason {
                Text(reason)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 9)
            }
            startButton
        }
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(durationText)
                .font(.system(size: 34, design: .monospaced))
            Text(registerText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var durationText: String {
        dial.durationSec < 60
            ? "\(dial.durationSec)s"
            : dial.durationSec % 60 == 0
                ? "\(dial.durationSec / 60)min"
                : "\(dial.durationSec / 60)min \(dial.durationSec % 60)s"
    }

    private var registerText: String {
        switch dial.register {
        case ..<0.25: "通俗"
        case ..<0.5:  "偏通俗"
        case ..<0.75: "偏专业"
        default:      "专业"
        }
    }

    private var estimateRow: some View {
        HStack {
            Text("预计 \(dial.estimate.tokens / 1000)K token")
            Spacer()
            Text("约 ¥\(String(format: "%.2f", Double(dial.estimate.costCents) / 100))")
        }
        .font(.system(size: 12.5, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.bottom, 13)
    }

    private var startButton: some View {
        Button("开始调研") { onStart(dial) }
            .font(.system(size: 16, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(.tint.opacity(dial.canAfford ? 1 : 0.3),
                        in: RoundedRectangle(cornerRadius: 13))
            .foregroundStyle(.white)
            .disabled(!dial.canAfford)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
    }
}
