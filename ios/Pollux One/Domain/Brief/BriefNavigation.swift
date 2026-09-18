import Foundation

/// spec §8.2：每一屏的「返回」含义不同，这是本设计里最容易做错的交互。
/// 做成纯函数，是为了让第三种情形（审稿回不到等待）不会在某次重构里
/// 悄悄退化成第二种。
enum BriefNavigation {
    static func back(from screen: BriefScreen) -> BriefScreen {
        switch screen {
        // 全部回相机——它是根。
        case .confirm, .progress, .review, .insufficient, .handOff, .scripts: .camera
        case .camera: .camera
        }
    }

    /// 「离开」不销毁任务：③ 等待页的返回之后，调研继续在云上跑。
    /// 真正的取消是另一个动作。
    static func destroysTask(from screen: BriefScreen) -> Bool { false }

    /// 调研已结束的屏，回不到等待页——那一屏不复存在。
    static func canReturnToProgress(from screen: BriefScreen) -> Bool {
        switch screen {
        case .review, .insufficient: false
        default: true
        }
    }
}
