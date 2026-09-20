import Foundation

enum HandOffMode: String, Equatable { case typing, speaking }
enum SecondaryEntry: String, Equatable { case screenshot, shareSheet }

struct HandOffState: Equatable {
    var mode: HandOffMode
    var text = ""
    var clipboardAuthorized = false
    var clipboardHasContent = false

    init(mode: HandOffMode = .typing,
         clipboardAuthorized: Bool = false,
         clipboardHasContent: Bool = false) {
        self.mode = mode
        self.clipboardAuthorized = clipboardAuthorized
        self.clipboardHasContent = clipboardHasContent
    }

    /// 一个框。链接和整段正文对管线是同一件事，分成两个框等于让用户
    /// 替我们做分类。
    var inputFieldCount: Int { mode == .typing ? 1 : 0 }

    /// 未授权或剪贴板为空时**整条消失**，不是禁用。
    /// 一个灰掉的按钮会招来一次点击，然后再解释自己为什么不能用。
    var showsClipboardBar: Bool {
        mode == .typing && clipboardAuthorized && clipboardHasContent
    }

    /// 这两个是一类：东西在别处。
    var secondaryEntries: [SecondaryEntry] { [.screenshot, .shareSheet] }

    var canProceed: Bool {
        switch mode {
        case .typing: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .speaking: true
        }
    }
}
