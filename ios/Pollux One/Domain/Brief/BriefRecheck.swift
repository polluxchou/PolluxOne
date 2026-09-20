import Foundation

/// 左滑那个「重查」按钮按下去之后发生什么。
///
/// 判断全部在这里，View 只负责把结果画出来——按钮本身在 `SwipeActions`
/// 里已经只对事实句露出，所以这一层不重复那条规则，只是不被它之外的
/// 输入弄崩。
extension Brief {
    enum RecheckOutcome: Equatable {
        /// 找到了更多互不相关的信源，带回替换用的那条证据。
        case improved(ClaimEvidence)
        /// 查了，没有新的。这不是失败，是一个要如实说出口的结果。
        case unchanged
        /// 这句话压根没有可查的事实点（钩子句、观点句，或者句子已经被删了）。
        /// `SwipeActions(for:)` 不给它们露重查按钮，所以正常路径走不到这里；
        /// 留着是为了让走到这里的那天是一个没反应，而不是一次崩溃。
        case notApplicable
    }

    /// 重查这句话最弱的那条 claim——和 `SentenceStyle(sentence:claims:)`、
    /// 审稿页展开面板同一个口径：一句挂多个事实点时，最弱的那个才是这句的强度，
    /// 也就是唯一值得再查一轮的那个。
    func recheckOutcome(forSentence sentenceId: String) -> RecheckOutcome {
        guard let sentence = sentences.first(where: { $0.id == sentenceId }) else {
            return .notApplicable
        }
        guard let weakest = sentence.claimIds
            .compactMap({ claims[$0] })
            .min(by: { $0.independence < $1.independence })
        else {
            return .notApplicable
        }
        guard let found = recheckResults?[weakest.id] else { return .unchanged }

        // 重查只能让信源变多。一次「再查一轮」把 3 个独立源查成 1 个，
        // 在现实里没有对应的事件——信源不会因为被重新数一遍而消失，
        // 那只可能是上游给错了数据。界面上显示「重查之后信源变少了」
        // 会让用户据此删掉一句本来站得住的话，所以这里宁可当作没查到：
        // 说「没找到新的」最多是少给了一点信息，说少了几个源是在撒谎。
        guard found.independence >= weakest.independence else {
            assertionFailure(
                "重查把 \(weakest.id) 的独立源从 \(weakest.independence) 减到 "
                + "\(found.independence)——重查只能让信源变多，这份数据是错的"
            )
            return .unchanged
        }
        return .improved(found)
    }

    /// `.improved` 时换掉那条 claim，其余原样返回。
    /// 只动 `claims`，不动句子：重查换的是这句话背后的证据，不是这句话。
    func applyingRecheck(forSentence sentenceId: String) -> Brief {
        guard case .improved(let claim) = recheckOutcome(forSentence: sentenceId) else {
            return self
        }
        var copy = self
        copy.claims[claim.id] = claim
        return copy
    }
}
