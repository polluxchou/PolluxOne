import Foundation

enum SwipeAction: String, Equatable {
    case recheck, delete
}

/// spec §8.1：露出的按钮由句子类型决定。观点句没有信源可重查，
/// 给它一个「重查」按钮就是在承诺一个做不到的动作。
/// 这个分化是从 kind 字段长出来的，不是排版决定。
struct SwipeActions: Equatable {
    static let buttonWidth: CGFloat = 72

    let buttons: [SwipeAction]
    var width: CGFloat { CGFloat(buttons.count) * Self.buttonWidth }

    init(for kind: SentenceKind) {
        buttons = kind == .fact ? [.recheck, .delete] : [.delete]
    }
}

/// 一行的滑动状态。过半才吸附，否则弹回。
struct SwipeState: Equatable {
    let width: CGFloat
    private(set) var offset: CGFloat = 0
    private(set) var isOpen = false

    init(width: CGFloat) { self.width = width }

    mutating func drag(to translation: CGFloat) {
        let base = isOpen ? -width : 0
        offset = min(0, max(-width, base + translation))
    }

    mutating func release() {
        isOpen = offset < -width / 2
        offset = isOpen ? -width : 0
    }
}
