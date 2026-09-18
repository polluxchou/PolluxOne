import Foundation

struct InsufficientAction: Equatable {
    let id: String
    let title: String
}

struct InsufficientState: Equatable {
    let headline: String
    let costNote: String
    let actions: [InsufficientAction]

    init(found: Int, required: Int, tokensUsed: Int) {
        // 说清差在哪，而不是一句「失败了」。
        headline = "只找到 \(found) 个独立信源，低于 \(required) 个的下限"
        // 花了就是花了。这恰恰是用户最该被告知的时刻——跑出了零结果，
        // 却仍然收了钱。
        costNote = "这一轮消耗了 \(tokensUsed / 1000)K token"
        // 没有「强行出稿」。给一个绕过拒绝的出口，等于这套承诺全是装饰。
        actions = [
            InsufficientAction(id: "retry", title: "再找一轮"),
            InsufficientAction(id: "another", title: "换一条新闻"),
        ]
    }
}
