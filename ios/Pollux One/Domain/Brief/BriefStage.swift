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

extension BriefStage {
    /// 换状态，**不动计数**。计数只能来自上游真的数出来的东西；
    /// 一个 nil 的 count 推进到 running 之后仍然是 nil，界面因此什么也不写——
    /// 这正是 §0.5 要的：宁可少显示，也不要一个读起来像结果的 0。
    func with(state newState: StageState, detail newDetail: String?) -> BriefStage {
        BriefStage(name: name, state: newState, count: count, detail: newDetail)
    }
}

extension Brief {
    /// 把管线往前推一格：进行中的那个收尾，下一个开跑。
    ///
    /// 它存在是为了让等待页在**还没有管线**的时候也能被判断手感——
    /// 五分钟的等待读起来是「在挖东西」还是「卡住了」，是这一屏唯一要回答的
    /// 问题，而那个问题不必等到有真东西可等才能回答。接上真管线之后，
    /// 调用方换成推送来的阶段即可，这个方法连同它的定时器一起删掉。
    ///
    /// 全部跑完时顺手把状态从 `.researching` 翻成 `.ready`：等待页的出口
    /// 是审稿页，而「能不能审」是 status 说了算的，不是界面说了算。
    func advancingStages() -> Brief {
        var copy = self
        guard let index = stages.firstIndex(where: { $0.state != .done }) else {
            if copy.status == .researching { copy.status = .ready }
            return copy
        }

        var next = stages
        if stages[index].state == .running {
            // detail 是「进行中那一阶段」底下的实时说明，阶段收尾时它也就过期了。
            next[index] = stages[index].with(state: .done, detail: nil)
            if index + 1 < next.count {
                next[index + 1] = next[index + 1].with(state: .running, detail: next[index + 1].detail)
            } else if copy.status == .researching {
                copy.status = .ready
            }
        } else {
            next[index] = stages[index].with(state: .running, detail: stages[index].detail)
        }
        copy.stages = next
        return copy
    }
}
