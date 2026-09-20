import Foundation

/// 不是 Color——测试台不链接 SwiftUI。View 层把它翻成颜色。
enum SentenceAccent: String, Equatable {
    case strong    // 绿：站得住
    case weak      // 黄：这是警告，不是装饰
    case neutral   // 灰：钩子句和观点句
}

struct SentenceStyle: Equatable {
    let accent: SentenceAccent
    let isDashed: Bool

    init(kind: SentenceKind, independence: Int) {
        switch kind {
        case .fact:
            // 黄色是「只有一个人这么说」的警告。
            accent = independence >= ClaimEvidence.strongThreshold ? .strong : .weak
            isDashed = false
        case .opinion:
            // 观点句永远不着有信源的颜色。把个人判断染成和三源互证同一个绿，
            // 是这一屏唯一不能犯的视觉谎言。
            accent = .neutral
            isDashed = true
        case .transition:
            accent = .neutral
            isDashed = false
        }
    }

    /// 从整条 brief 取该句最弱的那个 claim 来定色——一句话挂多个 claim 时，
    /// 最弱的那个才是这句话真正的强度。
    init(sentence: BriefSentence, claims: [String: ClaimEvidence]) {
        let independences = sentence.claimIds.compactMap { claims[$0]?.independence }
        self.init(kind: sentence.kind, independence: independences.min() ?? 0)
    }
}

/// mock 顶部那三个 pill。
struct SentenceCounts: Equatable {
    let strong: Int
    let weak: Int
    let unsourced: Int

    init(_ sentences: [BriefSentence], claims: [String: ClaimEvidence]) {
        var strong = 0, weak = 0, unsourced = 0
        for sentence in sentences {
            switch SentenceStyle(sentence: sentence, claims: claims).accent {
            case .strong: strong += 1
            case .weak: weak += 1
            case .neutral: unsourced += 1
            }
        }
        self.strong = strong
        self.weak = weak
        self.unsourced = unsourced
    }
}
