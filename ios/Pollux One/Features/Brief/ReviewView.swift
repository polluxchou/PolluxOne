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
                            onDelete: { brief = brief.deletingSentence(sentence.id) },
                            onRecheck: { /* 接管线后再实现 */ }
                        )
                    }
                }
            }
            bottomBar
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
