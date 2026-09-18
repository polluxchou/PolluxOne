import Foundation

struct SourceRef: Codable, Equatable, Identifiable {
    var id: String { publisher + "@" + time }
    let publisher: String
    /// mock 第二列：逐字引文，或「独立测算，口径一致」这样的说明。
    let note: String
    /// mock 第三列，形如 "15:02"。
    let time: String
}

struct ClaimEvidence: Codable, Equatable {
    let id: String
    /// **互不相关的信源组数**，不是篇数。界面上那个数字就是它。
    let independence: Int
    /// 被判为转载、已归并掉的篇数。mock：「另有 6 篇为上述稿件转载，未计入」。
    /// 与 independence 分开存，是因为把两者相加正是用户最容易犯的误读。
    let mergedAwayCount: Int
    let sources: [SourceRef]

    /// spec §5：3 个以上独立源才算站得住。
    static let strongThreshold = 3
    var isStrong: Bool { independence >= Self.strongThreshold }
}

/// 折叠态那个按钮上的字。
struct EvidenceLabel {
    let text: String
    let isWarning: Bool

    init(_ claim: ClaimEvidence) {
        if claim.independence <= 1 {
            // mock 上是「仅 1 个信源」——「仅」这个字是这里唯一的警告手段。
            text = "仅 \(claim.independence) 个信源"
            isWarning = true
        } else {
            // 永远说「独立信源」。说「篇」会把用户的心算引向加上转载。
            text = "\(claim.independence) 个独立信源"
            isWarning = false
        }
    }
}

/// 展开后最末那行灰字。
struct EvidenceFooter {
    let text: String?

    init(mergedAwayCount: Int) {
        // 没有转载时整行消失。写「另有 0 篇」是噪音。
        text = mergedAwayCount > 0
            ? "另有 \(mergedAwayCount) 篇为上述稿件转载，未计入"
            : nil
    }
}
