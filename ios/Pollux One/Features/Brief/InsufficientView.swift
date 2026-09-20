import SwiftUI

/// ⑥ 不建议播。spec §5.1 的可见形态——这一屏是产品敢不敢说真话的地方。
///
/// 这里**没有**「强行出稿」。给一个绕过拒绝的出口，等于这套承诺全是装饰；
/// 按钮从 `InsufficientState.actions` 长出来，那份清单由测试钉死。
struct InsufficientView: View {
    let news: NewsRef
    let state: InsufficientState
    /// 上游给的具体理由（fixture 的 `insufficientReason`），没有就整段不出现。
    let reason: String?
    let onAction: (InsufficientAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NewsTag(news: news)

            VStack(alignment: .leading, spacing: 13) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(.secondary)

                Text(state.headline)
                    .font(.system(size: 21, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)

                if let reason {
                    Text(reason)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 花了就是花了。跑出零结果却仍然收了钱，正是最该说清的时刻。
                Text(state.costNote)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 34)

            Spacer(minLength: 0)

            VStack(spacing: 11) {
                ForEach(Array(state.actions.enumerated()), id: \.element.id) { index, action in
                    Button(action.title) { onAction(action) }
                        .font(.system(size: 16, weight: index == 0 ? .medium : .regular))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background {
                            if index == 0 {
                                RoundedRectangle(cornerRadius: 13).fill(.tint)
                            } else {
                                RoundedRectangle(cornerRadius: 13).stroke(.tertiary)
                            }
                        }
                        .foregroundStyle(index == 0 ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}
