import SwiftUI

/// ② 当前稿件详情 = 审稿。spec §9.2 ②：一个 View 两个入口
/// （相机进 / 调研完成落回），不是两屏。
struct ReviewView: View {
    /// 绑定而不是 @State：删句要传回 BriefFlow。持一份局部副本的话，
    /// 删除会在离开这一屏时无声丢失，而且把整篇删空时算出的
    /// `status = .insufficient` 没有人读得到——空稿仍旧标着「可播」，
    /// 正是 Brief.deletingSentence 那条断言要防的状态。
    @Binding var brief: Brief
    let onRecord: () -> Void
    let onSwitchScript: () -> Void

    /// 哪几行正在重查 / 刚查完没找到。按句 id 存，因为重查是一行一行的，
    /// 一次查 s4 不该让 s3 也转起来。
    @State private var recheckPhases: [String: RecheckPhase] = [:]

    /// 假装一次上游查询要用掉的时间。真管线接上之后这个数字会被真正的
    /// 往返替掉，但那一行「重查中…」和它两头的状态不用重写。
    private static let recheckDuration = Duration.milliseconds(1200)
    /// 「没有找到新的信源」停留多久。够看清，又不至于赖在那里。
    private static let foundNothingDuration = Duration.milliseconds(1800)

    private var counts: SentenceCounts { SentenceCounts(brief.sentences, claims: brief.claims) }

    var body: some View {
        VStack(spacing: 0) {
            NewsTag(news: brief.news)
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(brief.sentences) { sentence in
                        SwipeableSentenceRow(
                            sentence: sentence,
                            claims: brief.claims,
                            recheckPhase: recheckPhases[sentence.id] ?? .idle,
                            onDelete: { brief = brief.deletingSentence(sentence.id) },
                            onRecheck: { recheck(sentence.id) }
                        )
                    }
                }
            }
            bottomBar
        }
    }

    /// 重查一行。结果由 `Brief.recheckOutcome(forSentence:)` 定，这里只负责
    /// 让它在时间上看得见：先转一会儿，再落到两个结果之一。
    ///
    /// 两条路径都必须在界面上留下痕迹。查到了就换证据、标签当场改口；
    /// 没查到就明说「没有找到新的信源」——它和一个按下去什么也不发生的按钮
    /// 在像素上一度是同一个样子，而那正是这个按钮之前的毛病。
    private func recheck(_ sentenceId: String) {
        guard recheckPhases[sentenceId] != .running else { return }  // 别叠着查
        withAnimation(.easeInOut(duration: 0.18)) { recheckPhases[sentenceId] = .running }

        Task {
            try? await Task.sleep(for: Self.recheckDuration)
            switch brief.recheckOutcome(forSentence: sentenceId) {
            case .improved:
                withAnimation(.snappy) {
                    // 写回 @Binding：新的证据要留在 BriefFlow 手里，
                    // 否则离开这一屏，刚查到的信源就没了。
                    brief = brief.applyingRecheck(forSentence: sentenceId)
                    recheckPhases[sentenceId] = .idle
                }
            case .unchanged:
                withAnimation(.easeInOut(duration: 0.18)) {
                    recheckPhases[sentenceId] = .foundNothing
                }
                try? await Task.sleep(for: Self.foundNothingDuration)
                withAnimation(.easeInOut(duration: 0.18)) { recheckPhases[sentenceId] = .idle }
            case .notApplicable:
                // 按钮根本没在这种句子上露出来（`SwipeActions(for:)`）。
                // 真走到这里就安静收场，不要编一句「没找到」——它没查过。
                recheckPhases[sentenceId] = .idle
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(brief.estimatedSeconds)")
                    .font(.system(size: 29, design: .monospaced))
                // pacedToUser 为假时不许写「按你的语速」——spec §9.2 ① 说新用户
                // 的第一篇必然是语种默认值，文案先于数据到场就是在撒谎。
                Text(brief.pacedToUser ? "秒 · 按你的语速" : "秒")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                CountPill(value: counts.strong, accent: .strong)
                CountPill(value: counts.weak, accent: .weak)
                CountPill(value: counts.unsourced, accent: .neutral)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var bottomBar: some View {
        HStack(spacing: 11) {
            Button(action: onSwitchScript) {
                Image(systemName: "arrow.triangle.2.circlepath").frame(width: 54, height: 56)
            }
            .accessibilityLabel("换一篇稿")
            Button(action: onRecord) {
                Label("开拍", systemImage: "video.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
}

struct CountPill: View {
    let value: Int
    let accent: SentenceAccent

    var body: some View {
        Text("\(value)")
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(accent.color.opacity(0.13), in: Capsule())
            .foregroundStyle(accent.color)
    }
}

// NewsTag 不在这里定义 —— Task 12 已经把它提成了独立文件
// `ios/Pollux One/Features/Brief/NewsTag.swift`（BriefProgressView 也要用它）。
// 在这里再写一遍会重复定义、编译失败。直接用即可。
