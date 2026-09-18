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
    let stages: [BriefStage]
    let budget: TokenBudget
    /// ⑥ 不建议播时的理由，其余状态为 nil。
    let insufficientReason: String?
}
