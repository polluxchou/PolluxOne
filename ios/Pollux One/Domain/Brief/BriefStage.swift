import Foundation

enum StageState: String, Codable {
    case done, running, pending
}

/// spec §8 ⑤：九个阶段带**计数**而非耗时——计数告诉用户挖到了什么，
/// 那才是他愿意等下去的理由。
struct BriefStage: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let state: StageState
    /// 形如 "14 篇"、"86 条"、"23 点 · 7 独立源"、"9 / 23"。未开始时 nil。
    let count: String?
    /// 进行中那个阶段底下的实时说明。其余为 nil。
    let detail: String?
}

/// spec §10.1：token 是一等产品对象。
struct TokenBudget: Codable, Equatable {
    let used: Int
    let budgeted: Int
    let remainingThisMonth: Int
    let costCents: Int
    /// 阶段名 → token 数。之和必须等于 used，否则进度条在撒谎。
    let byStage: [String: Int]

    var fractionUsed: Double {
        budgeted > 0 ? Double(used) / Double(budgeted) : 0
    }
}

/// mock 上那条分段进度条。每段宽度是「该阶段占预算的比例」，
/// 所以各段之和必然等于 fractionUsed——这一条由测试钉死。
struct TokenBar {
    struct Segment: Equatable {
        let stage: String
        let fraction: Double
    }

    let segments: [Segment]

    init(_ budget: TokenBudget) {
        guard budget.budgeted > 0 else { segments = []; return }
        // 排序是为了让颜色分配稳定：同一份数据每次画出来都一样。
        segments = budget.byStage
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { Segment(stage: $0.key, fraction: Double($0.value) / Double(budget.budgeted)) }
    }
}
