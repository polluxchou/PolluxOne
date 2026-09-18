import SwiftUI

extension SentenceAccent {
    var color: Color {
        switch self {
        case .strong: Color(red: 0.435, green: 0.635, blue: 0.573)   // #6FA292
        case .weak:   Color(red: 0.851, green: 0.643, blue: 0.255)   // #D9A441
        case .neutral: Color(red: 0.227, green: 0.212, blue: 0.184)  // #3A362F
        }
    }
}

/// 一行在重查上的瞬时状态。只活在界面里——查得到查不到由
/// `Brief.recheckOutcome(forSentence:)` 说了算，这里只决定这一秒画什么。
enum RecheckPhase: Equatable {
    case idle
    case running
    /// 查完了，没有新的。要说出口——按下去毫无动静和「没找到」是两回事。
    case foundNothing
}

struct SentenceRow: View {
    let sentence: BriefSentence
    let claims: [String: ClaimEvidence]
    var recheckPhase: RecheckPhase = .idle
    @State private var isExpanded = false

    private var style: SentenceStyle { SentenceStyle(sentence: sentence, claims: claims) }
    private var runs: AnchorRuns { AnchorRuns(sentence) }
    /// 一句挂多个 claim 时，展开面板显示最弱的那个——它才是这句的强度。
    private var weakestClaim: ClaimEvidence? {
        sentence.claimIds.compactMap { claims[$0] }.min { $0.independence < $1.independence }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            accentBar
            VStack(alignment: .leading, spacing: 8) {
                text
                if let claim = weakestClaim {
                    evidenceToggle(claim)
                    if isExpanded { EvidenceSheet(claim: claim) }
                } else if sentence.kind == .opinion {
                    Text("你的判断 · 无信源")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                recheckNote
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 24)
    }

    /// 重查的三种样子。`.idle` 时整行消失，不留一个空位置——
    /// 没有在查的时候不该有任何关于查的字。
    @ViewBuilder
    private var recheckNote: some View {
        switch recheckPhase {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("重查中…").font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        case .foundNothing:
            // 查过了，结果是空的。这句话必须说，否则用户只看到按钮弹回去，
            // 分不清「查了没有」和「这个按钮坏了」。
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                Text("没有找到新的信源").font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var accentBar: some View {
        Rectangle()
            .fill(style.accent.color)
            .frame(width: 2)
            .opacity(style.isDashed ? 0.5 : 1)
    }

    /// 锚点段落拼成一行富文本。降级时 runs 只有一段，于是自然退回纯文本。
    private var text: some View {
        runs.segments.reduce(Text("")) { acc, segment in
            var piece = Text(segment.text)
            if segment.claimId != nil {
                piece = piece.underline(true, pattern: .dot, color: style.accent.color)
            }
            return acc + piece
        }
        .font(.system(size: 16.5))
        .italic(sentence.kind == .opinion)
        .lineSpacing(5)
    }

    private func evidenceToggle(_ claim: ClaimEvidence) -> some View {
        let label = EvidenceLabel(claim)
        return Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: label.isWarning ? "exclamationmark.triangle" : "checkmark")
                    .font(.system(size: 11, weight: .bold))
                Text(label.text).font(.system(size: 11.5, design: .monospaced))
            }
            .foregroundStyle(style.accent.color)
        }
    }
}

/// Task 9 Step 3：手势那一半。露几个按钮、拉到哪里吸附，全部由
/// `SwipeActions` / `SwipeState` 决定——这里只把 DragGesture 的横向位移
/// 原样喂进去，再把 `offset` 画出来。View 里不写第二套判断。
struct SwipeableSentenceRow: View {
    let sentence: BriefSentence
    let claims: [String: ClaimEvidence]
    let recheckPhase: RecheckPhase
    let onDelete: () -> Void
    let onRecheck: () -> Void

    private let actions: SwipeActions
    @State private var swipe: SwipeState

    init(
        sentence: BriefSentence,
        claims: [String: ClaimEvidence],
        recheckPhase: RecheckPhase = .idle,
        onDelete: @escaping () -> Void,
        onRecheck: @escaping () -> Void
    ) {
        self.sentence = sentence
        self.claims = claims
        self.recheckPhase = recheckPhase
        self.onDelete = onDelete
        self.onRecheck = onRecheck
        let actions = SwipeActions(for: sentence.kind)
        self.actions = actions
        _swipe = State(initialValue: SwipeState(width: actions.width))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            buttons
            SentenceRow(sentence: sentence, claims: claims, recheckPhase: recheckPhase)
                .background(Color(.systemBackground))
                .offset(x: swipe.offset)
                .gesture(drag)
        }
        .clipped()
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(actions.buttons, id: \.rawValue) { action in
                Button {
                    perform(action)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: icon(action)).font(.system(size: 15, weight: .semibold))
                        Text(title(action)).font(.system(size: 11))
                    }
                    .frame(width: SwipeActions.buttonWidth)
                    .frame(maxHeight: .infinity)
                    .background(tint(action))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(action))
            }
        }
        .frame(width: actions.width)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // 纵向为主的手势留给外层 ScrollView，不抢。
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                swipe.drag(to: value.translation.width)
            }
            .onEnded { _ in
                withAnimation(.snappy) { swipe.release() }
            }
    }

    private func perform(_ action: SwipeAction) {
        switch action {
        case .delete: onDelete()
        case .recheck: onRecheck()
        }
        // 关回去：重新起一个初态，而不是在这里另算一遍位移。
        withAnimation(.snappy) { swipe = SwipeState(width: actions.width) }
    }

    private func icon(_ action: SwipeAction) -> String {
        switch action {
        case .recheck: "arrow.clockwise"
        case .delete: "trash"
        }
    }

    private func title(_ action: SwipeAction) -> String {
        switch action {
        case .recheck: "重查"
        case .delete: "删除"
        }
    }

    private func tint(_ action: SwipeAction) -> Color {
        switch action {
        case .recheck: Color(red: 0.376, green: 0.376, blue: 0.376)
        case .delete: Color(red: 0.741, green: 0.271, blue: 0.239)
        }
    }
}
