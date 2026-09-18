import Foundation

extension Brief {
    /// 删一句，并清掉因此没人再用的证据。
    ///
    /// 孤儿证据不是无害的：它留在字典里，下一句恰好引到同一个 id 时
    /// 会显示别人的信源。清理是有条件的——两句合法地共用一条 claim 很常见。
    func deletingSentence(_ sentenceId: String) -> Brief {
        var copy = self
        guard let removed = sentences.first(where: { $0.id == sentenceId }) else { return copy }
        copy.sentences.removeAll { $0.id == sentenceId }

        for claimId in removed.claimIds {
            let stillUsed = copy.sentences.contains { $0.claimIds.contains(claimId) }
            if !stillUsed { copy.claims.removeValue(forKey: claimId) }
        }

        // 删光了就降级。留一个空稿却仍标成 ready，是在假装它还能播。
        if copy.sentences.isEmpty {
            copy.status = .insufficient
        }
        return copy
    }
}
