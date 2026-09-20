import Foundation

/// 用户给进来的那条新闻，收成一行标签用（spec §8 ②③④ 都是这个形态）。
struct NewsRef: Codable, Equatable {
    let publisher: String
    let title: String
    let url: String?
}

enum BriefStatus: String, Codable {
    case researching   // ⑤ 等待
    case ready         // ② 审稿
    case insufficient  // ⑥ 不建议播
}

enum SentenceKind: String, Codable {
    case fact, opinion, transition
}

/// 句内的证据锚点：mock 上那条虚线下划线。
/// `start` / `length` 以**字符**计（Character，不是 UTF-16 code unit），
/// 中文一个字算一个——用 utf16 会让中文全部错位。
struct EvidenceAnchor: Codable, Equatable {
    let start: Int
    let length: Int
    let claimId: String
}

struct BriefSentence: Codable, Equatable, Identifiable {
    let id: String
    let text: String
    let kind: SentenceKind
    let claimIds: [String]
    let anchors: [EvidenceAnchor]

    /// spec §8.1：事实句左滑露「重查 + 删除」，其余只露「删除」。
    /// 观点句没有信源可重查，给它一个重查按钮就是在骗人。
    var canRecheckSources: Bool { kind == .fact }
}

struct Brief: Codable, Equatable, Identifiable {
    let id: String
    let news: NewsRef
    var status: BriefStatus
    /// 已按语速算过的秒数。mock 上是 83。
    let estimatedSeconds: Int
    /// 这个秒数是否用了该用户自己的语速。false 时界面**不许**写「按你的语速」——
    /// spec §9.2 ① 说新用户的第一篇必然是语种默认值。
    let pacedToUser: Bool
    var sentences: [BriefSentence]
    var claims: [String: ClaimEvidence]
    /// claimId → 「重查之后」的证据。没有条目 = 那一条重查也找不到新的独立源。
    /// 可选，因为真管线接上之前它只存在于 fixture 里；旧数据解出来就是 nil，
    /// 那时每一次重查都诚实地答「没找到」，而不是解码失败。
    let recheckResults: [String: ClaimEvidence]?
    /// `var`，只因为等待页要在本地把它一格一格往前推（`advancingStages()`）。
    /// 阶段是这份数据里唯一随时间变的东西，其余仍然是 `let`。
    var stages: [BriefStage]
    let budget: TokenBudget
    /// ⑥ 不建议播时的理由，其余状态为 nil。
    let insufficientReason: String?
}

/// 「换一篇」的一行。Brief 在跑的时候还不是 Script，所以列表是两者的合并流。
struct ScriptListRow: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let isResearching: Bool
}

enum ScriptListRows {
    static func build(scriptTitles: [(id: String, title: String, seconds: Int)],
                      briefs: [Brief]) -> [ScriptListRow] {
        let briefRows = briefs.map { brief in
            ScriptListRow(
                id: brief.id,
                title: brief.news.title,
                subtitle: brief.status == .researching ? "调研中" : "\(brief.estimatedSeconds) 秒",
                isResearching: brief.status == .researching
            )
        }
        let scriptRows = scriptTitles.map {
            ScriptListRow(id: $0.id, title: $0.title, subtitle: "\($0.seconds) 秒",
                          isResearching: false)
        }
        // 在跑的排最前：那是用户此刻最想看的东西。
        return briefRows.filter(\.isResearching) + scriptRows
            + briefRows.filter { !$0.isResearching }
    }
}

/// 空状态。原文案 "Write a script on the Pollux One web console, then pull to
/// refresh." 在 iOS 优先之后是错的——它把人支去了一个不再是主入口的地方。
struct ScriptListEmptyState: Equatable {
    let text = "还没有稿子。把一条新闻交给我，我去查。"
    let action = BriefScreen.handOff
}
