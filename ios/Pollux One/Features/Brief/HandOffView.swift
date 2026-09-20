import SwiftUI

/// ③ 交给我。spec §8 ③：`打字 / 说给我听` 两档。
/// 打字档是**一个**输入框——链接和整段正文对管线是同一件事，
/// 分成两个框等于让用户替我们做分类。
struct HandOffView: View {
    @State private var state: HandOffState
    let onSubmit: (HandOffState) -> Void
    let onPasteClipboard: () -> String?
    let onScreenshot: () -> Void
    let onShareSheet: () -> Void

    init(state: HandOffState = HandOffState(),
         onSubmit: @escaping (HandOffState) -> Void,
         onPasteClipboard: @escaping () -> String? = { nil },
         onScreenshot: @escaping () -> Void = {},
         onShareSheet: @escaping () -> Void = {}) {
        _state = State(initialValue: state)
        self.onSubmit = onSubmit
        self.onPasteClipboard = onPasteClipboard
        self.onScreenshot = onScreenshot
        self.onShareSheet = onShareSheet
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modePicker
            if state.mode == .typing {
                typingPane
            } else {
                speakingPane
            }
            Spacer(minLength: 0)
            secondaryRow
            submitButton
        }
        .padding(.top, 18)
    }

    private var modePicker: some View {
        Picker("", selection: $state.mode) {
            Text("打字").tag(HandOffMode.typing)
            Text("说给我听").tag(HandOffMode.speaking)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 24)
    }

    private var typingPane: some View {
        VStack(alignment: .leading, spacing: 11) {
            // 未授权或剪贴板为空时整条不出现——一个灰掉的按钮会招来一次点击，
            // 然后再解释自己为什么不能用。
            if state.showsClipboardBar {
                Button {
                    if let pasted = onPasteClipboard() { state.text = pasted }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 12))
                        Text("粘贴剪贴板里的那条").font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            // 一个框，链接与正文合一。
            TextEditor(text: $state.text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 168)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 13))
                .overlay(alignment: .topLeading) {
                    if state.text.isEmpty {
                        Text("贴一条链接，或者直接把整段正文放进来")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15).padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    private var speakingPane: some View {
        VStack(spacing: 13) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("按住说话，讲清楚你想播哪条")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 62)
        .padding(.horizontal, 24)
    }

    /// 截图与分享并列：它们是同一个意思——东西在别处。
    private var secondaryRow: some View {
        HStack(spacing: 11) {
            ForEach(state.secondaryEntries, id: \.rawValue) { entry in
                Button {
                    switch entry {
                    case .screenshot: onScreenshot()
                    case .shareSheet: onShareSheet()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon(entry)).font(.system(size: 13))
                        Text(title(entry)).font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.tertiary))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 13)
    }

    private func icon(_ entry: SecondaryEntry) -> String {
        switch entry {
        case .screenshot: "photo.on.rectangle"
        case .shareSheet: "square.and.arrow.up"
        }
    }

    private func title(_ entry: SecondaryEntry) -> String {
        switch entry {
        case .screenshot: "上传截图"
        case .shareSheet: "分享进来"
        }
    }

    private var submitButton: some View {
        Button("开始调研") { onSubmit(state) }
            .font(.system(size: 16, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(.tint.opacity(state.canProceed ? 1 : 0.3),
                        in: RoundedRectangle(cornerRadius: 13))
            .foregroundStyle(.white)
            .disabled(!state.canProceed)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
    }
}
