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
        return BriefEstimate(tokens: tokens, costCents: max(1, tokens / 3_400))
    }

    /// 余额门禁放在这一屏，因为这是**烧 token 之前的最后一屏**。
    /// spec §11 点名：跑完才发现余额不够是不能接受的。
    var canAfford: Bool { estimate.tokens <= remainingTokens }

    var blockReason: String? {
        canAfford ? nil
            : "这一篇大约要 \(estimate.tokens / 1000)K token，你只剩 \(remainingTokens / 1000)K"
    }
}
