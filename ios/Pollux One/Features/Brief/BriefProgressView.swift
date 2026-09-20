import SwiftUI

/// ⑤ 等待。上半 1/3 是 token 表——spec §10.1 说 token 是一等产品对象，
/// 它在这里第一次对用户可见。
struct BriefProgressView: View {
    let brief: Brief
    let elapsed: String
    let onLeave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NewsTag(news: brief.news)
                Text(elapsed).font(.system(size: 14, design: .monospaced))
            }
            tokenPanel
            stageList
            Spacer(minLength: 0)
            bottomActions
        }
    }

    private var tokenPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(brief.budget.used, format: .number)
                    .font(.system(size: 40, design: .monospaced))
                Text("tokens").font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
                Text("¥\(Double(brief.budget.costCents) / 100, specifier: "%.2f")")
                    .font(.system(size: 17, design: .monospaced))
            }
            segmentedBar
            legend
            Divider()
            HStack {
                Text("预算 \(brief.budget.budgeted / 1000)K · 已用 \(Int(brief.budget.fractionUsed * 100))%")
                Spacer()
                Text("本月余额 \(String(format: "%.2f", Double(brief.budget.remainingThisMonth) / 1_000_000))M")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
    }

    private var segmentedBar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(TokenBar(brief.budget).segments.enumerated()), id: \.offset) { index, segment in
                    Rectangle()
                        .fill(Color.accentColor.opacity(1.0 - Double(index) * 0.25))
                        .frame(width: geo.size.width * segment.fraction)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 11)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
    }

    private var legend: some View {
        HStack(spacing: 13) {
            ForEach(Array(TokenBar(brief.budget).segments.enumerated()), id: \.offset) { index, segment in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(1.0 - Double(index) * 0.25))
                        .frame(width: 7, height: 7)
                    Text(segment.stage).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stageList: some View {
        VStack(spacing: 0) {
            ForEach(brief.stages) { stage in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 13) {
                        stageIcon(stage.state)
                        Text(stage.name)
                            .font(.system(size: 14))
                            .foregroundStyle(stage.state == .pending ? .tertiary : .secondary)
                        Spacer()
                        // 未开始的阶段不显示计数。0 读起来像「挖到了 0 条」。
                        if let count = stage.count {
                            Text(count).font(.system(size: 11.5, design: .monospaced))
                        }
                    }
                    if let detail = stage.detail {
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 29)
                    }
                }
                .padding(.vertical, 9)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    @ViewBuilder
    private func stageIcon(_ state: StageState) -> some View {
        switch state {
        case .done:    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
        case .running: ProgressView().controlSize(.small)
        case .pending: Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 16, height: 16)
        }
    }

    private var bottomActions: some View {
        VStack(spacing: 13) {
            // spec §8.2：②→③ 是不可逆边界，所以这里的返回是「离开」。
            // 随手一按不该毁掉一个已经花了钱的任务。
            Button("退出，好了通知我", action: onLeave)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.tertiary))
            // 真正的取消是另一个动作，很轻，并且明说不退。
            Button("取消调研 · 已消耗的 \(brief.budget.used / 1000)K 不退", action: onCancel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
}
