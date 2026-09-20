import Foundation

/// 把一句话按锚点切成若干段，带标记的段画虚线下划线。
///
/// 越界或重叠一律**整句降级**为一段无标记文本，而不是夹逼成一个看似合理的
/// 区间：两者都说明上游算错了，夹逼会把错误藏起来。
struct AnchorRuns: Equatable {
    struct Segment: Equatable {
        let text: String
        /// nil = 普通文字。
        let claimId: String?
    }

    let segments: [Segment]
    let isDegraded: Bool

    init(_ sentence: BriefSentence) {
        let chars = Array(sentence.text)
        let sorted = sentence.anchors.sorted { $0.start < $1.start }

        var valid = true
        var cursor = 0
        for anchor in sorted {
            if anchor.start < cursor { valid = false; break }          // 重叠
            if anchor.length <= 0 { valid = false; break }             // 空锚点
            if anchor.start + anchor.length > chars.count { valid = false; break } // 越界
            cursor = anchor.start + anchor.length
        }

        guard valid else {
            segments = [Segment(text: sentence.text, claimId: nil)]
            isDegraded = true
            return
        }

        var out: [Segment] = []
        var index = 0
        for anchor in sorted {
            if anchor.start > index {
                out.append(Segment(text: String(chars[index ..< anchor.start]), claimId: nil))
            }
            let end = anchor.start + anchor.length
            out.append(Segment(text: String(chars[anchor.start ..< end]), claimId: anchor.claimId))
            index = end
        }
        if index < chars.count {
            out.append(Segment(text: String(chars[index...]), claimId: nil))
        }

        segments = out.isEmpty ? [Segment(text: sentence.text, claimId: nil)] : out
        isDegraded = false
    }
}
