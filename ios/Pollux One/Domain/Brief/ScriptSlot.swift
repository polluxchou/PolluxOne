import Foundation

enum BriefScreen: String, Equatable {
    case camera, handOff, confirm, progress, review, insufficient, scripts
}

/// 相机右下角那一格。它是整个新流程的唯一入口，所以"去哪"这件事
/// 单独做成纯函数，四个状态各自可测，不必起一个界面。
struct ScriptSlot: Equatable {
    let destination: BriefScreen
    let caption: String

    init(brief: Brief?) {
        guard let brief else {
            destination = .handOff
            caption = "交给我"
            return
        }
        switch brief.status {
        case .researching:
            // 在跑的时候回等待页，不是审稿页：还没有东西可审，
            // 把人送进一个空的审稿页会让五分钟的等待读起来像失败。
            destination = .progress
            caption = "调研中"
        case .insufficient:
            destination = .insufficient
            caption = "信源不足"
        case .ready:
            destination = .review
            caption = "\(brief.estimatedSeconds) 秒"
        }
    }
}
