import Foundation

enum DialAnchor: String, Equatable {
    case casualMinute            // 60s 通俗
    case professionalThreeMinutes // 3min 偏专业
}

struct BriefEstimate: Equatable {
    let tokens: Int
    let costCents: Int
}

struct DialState: Equatable {
    /// 档位，不是连续值。段落感正是"拨盘"手感的来源，
    /// 也让成本预估落在有限的已知点上，而不是插值出来的。
    static let durationSteps = [30, 60, 90, 120, 180, 240, 300, 360]
    static let maxDurationSec = 360

    private(set) var durationSec = 60
    private(set) var register = 0.0
    let remainingTokens: Int

    init(remainingTokens: Int = .max) { self.remainingTokens = remainingTokens }

    mutating func setDuration(seconds: Int) {
        let clamped = min(Self.maxDurationSec, max(Self.durationSteps[0], seconds))
        durationSec = Self.durationSteps.min {
            abs($0 - clamped) < abs($1 - clamped)
        } ?? Self.durationSteps[0]
    }

    mutating func setRegister(_ value: Double) {
        register = min(1.0, max(0.0, value))
    }

    mutating func snap(to anchor: DialAnchor) {
        switch anchor {
        case .casualMinute:
            durationSec = 60
            register = 0.0
        case .professionalThreeMinutes:
            durationSec = 180
            register = 0.7
        }
    }

    /// 与 pipeline 的 ESTIMATE_COEFFICIENTS 是**两套数**，接上管线后必须统一。
    /// 现在只保证单调：时长越长越贵、越专业越贵。
    var estimate: BriefEstimate {
        let base = 20_000
        let perSecond = 380
        let registerMultiplier = 1.0 + register * 0.35
        let tokens = Int(Double(base + perSecond * durationSec) * registerMultiplier)
        return BriefEstimate(tokens: tokens, costCents: Self.costCents(forTokens: tokens))
    }

    /// DeepSeek 的**高峰**价，人民币分 / 每百万 token（官方价目，查证于 2026-09-18）。
    ///
    /// 一律按高峰估，不按空闲：高峰是空闲的两倍，而估低了的后果是用户看着一个
    /// 数字开跑、收到一张两倍的账单。估高只是让他觉得贵。
    private enum PeakRate {
        static let flashInput = 200      // 缓存未命中；命中是 4，但开跑前不知道会不会命中
        static let flashOutput = 800
        static let proOutput = 2_700
    }

    /// token 的去向构成。这三个数是**假设**，不是测量——Task 16 会用真实样本
    /// 回归它们。放在这里而不是揉进一个除数里，是为了让它错的时候看得出错在哪：
    /// 一个 `tokens / 3_400` 没法告诉任何人它凭什么是 3400。
    private enum Mix {
        /// ③ 抽事实点要读十几篇全文，输入占大头
        static let flashInputShare = 0.80
        static let flashOutputShare = 0.15
        /// ⑦ 成稿用 v4-pro，量小但单价贵一个量级
        static let proOutputShare = 0.05
    }

    static func costCents(forTokens tokens: Int) -> Int {
        let perMTok =
            Mix.flashInputShare * Double(PeakRate.flashInput)
            + Mix.flashOutputShare * Double(PeakRate.flashOutput)
            + Mix.proOutputShare * Double(PeakRate.proOutput)
        return max(1, Int((Double(tokens) / 1_000_000 * perMTok).rounded(.up)))
    }

    /// 余额门禁放在这一屏，因为这是**烧 token 之前的最后一屏**。
    /// spec §11 点名：跑完才发现余额不够是不能接受的。
    var canAfford: Bool { estimate.tokens <= remainingTokens }

    var blockReason: String? {
        canAfford ? nil
            : "这一篇大约要 \(estimate.tokens / 1000)K token，你只剩 \(remainingTokens / 1000)K"
    }
}
