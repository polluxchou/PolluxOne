import SwiftUI

/// 七屏串起来的那个容器。全程零网络：数据全部来自 bundle 里的
/// `demo-briefs/`（没有那个目录时退回单份 `brief-fixture.json`）。
///
/// 三条规矩，这一层存在的理由就是守住它们：
///
/// 1. **去哪由 `ScriptSlot(brief:)` 决定**，不是由这里的 if。四种状态各自
///    已经在测试台上钉死了，这里再写一遍等于多一处会漂的判断。
/// 2. **返回一律走 `BriefNavigation.back(from:)`**。那个纯函数存在的全部理由
///    是不让「审稿页回不到等待页」这一条在某次重构里悄悄退化——所以这里
///    一行自己的返回逻辑都没有。
/// 3. **相机不卸载**。它是根：Brief 的屏是盖在它上面的一层，不是把它替掉的
///    另一棵树。`SessionManager` 也因此不必在每次盖住时重启取景器。
struct BriefFlow: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var screen: BriefScreen = .camera
    /// bundle 里所有能解开的稿，按 id 排好。⑦「换一篇」画的就是这一份。
    @State private var briefs: [Brief] = []
    /// **当前选中的是哪一篇，只记 id，不记副本。**
    /// 记 id 的理由：稿会被改（删句、重查），副本会立刻过期，而 id 不会。
    /// 于是"当前那一份"永远是 `briefs` 里的活数据，串不到别的稿上去。
    ///
    /// id 指向的稿可以**不在** `briefs` 里——取消调研就是这个状态：那一篇被
    /// 拿走了（右下角那一格因此回到「交给我」），但 id 还留着，④ 再确认一次
    /// 就能把同一篇重放。
    @State private var currentID: String?
    /// 刚从 bundle 读出来的那几份，一直留着。取消调研之后要靠它们把演示重放
    /// 一遍：fixture 是这个 app 目前唯一的"上游"，扔了就再也长不回来。
    @State private var pristine: [String: Brief] = [:]
    @State private var loadError: String?
    /// 用户在 ③ 交给我那一屏打的字。它还变不成一篇 Brief——没有管线——
    /// 所以只用来给 ④ 确认页那条标签，让人看见自己交进来的是什么。
    @State private var handedOff: NewsRef?
    @State private var researchStartedAt: Date?
    @State private var elapsed = "00:00"

    /// 阶段之间的间隔。挑 1.5 秒是因为它要同时装下两件事：慢到能读清刚亮起来
    /// 的那一行，快到九个阶段走完不至于让人放下手机。
    private static let stageInterval = Duration.seconds(1.5)

    // MARK: - 当前那一份

    /// 当前选中的稿，没有选中（或选中的那篇刚被取消掉）时是 nil。
    private var current: Brief? {
        guard let currentID else { return nil }
        return briefs.first { $0.id == currentID }
    }

    /// 写回**对应的那一份**。ReviewView 改的是这个 Binding，所以删句、重查
    /// 落在 `briefs` 里的同一条上，不会溅到别的稿。
    private var currentBinding: Binding<Brief>? {
        guard let id = currentID, let snapshot = current else { return nil }
        return Binding(
            get: { briefs.first { $0.id == id } ?? snapshot },
            set: { updated in
                guard let index = briefs.firstIndex(where: { $0.id == id }) else { return }
                briefs[index] = updated
            }
        )
    }

    /// 有就替换，没有就插回去并保持 id 序——顺序是这一屏唯一的稳定点。
    private func upsert(_ brief: Brief) {
        if let index = briefs.firstIndex(where: { $0.id == brief.id }) {
            briefs[index] = brief
        } else {
            briefs.append(brief)
            briefs.sort { $0.id < $1.id }
        }
    }

    var body: some View {
        ZStack {
            // 相机是根，永远在这里。Brief 的屏盖在它上面。
            RecordingView(
                script: environment.sessionManager.scriptRevision?.script,
                sessionManager: environment.sessionManager,
                brief: current,
                onOpenBrief: { screen = $0 }
            )

            if screen != .camera {
                briefLayer
                    .background(Color(.systemBackground))
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: screen)
        // 审稿时把最后一句也删掉，Brief.deletingSentence 会把 status 降成
        // .insufficient。那一刻这一屏就不该再是审稿页——留在一个空的审稿页
        // 上，等于让一篇播不了的稿继续看起来像能播。
        .onChange(of: current?.status) { _, status in
            if status == .insufficient, screen == .review {
                screen = .insufficient
            }
        }
        .task { loadBriefs() }
        // 定时器挂在屏上而不是挂在对象上：离开等待页，结构化并发自己把它取消，
        // 不必再记得去 invalidate 一个还攥在手里的 Timer。
        .task(id: screen) { await runStageClock() }
    }

    // MARK: - 盖在相机上的那一层

    private var briefLayer: some View {
        VStack(spacing: 0) {
            backBar
            screenContent
        }
    }

    /// 每一屏都只有这一个返回，含义由 `BriefNavigation` 说了算。
    /// 等待页的"返回"是离开而不是取消（`destroysTask(from:) == false`），
    /// 所以它读作「退出」；真正的取消在那一屏自己的底部，很轻，并且明说不退。
    private var backBar: some View {
        HStack(spacing: 6) {
            Button {
                screen = BriefNavigation.back(from: screen)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                Text(backTitle)
                    .font(.system(size: 16))
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var backTitle: String {
        // 说清按下去会到哪，而不是一个光秃秃的「返回」。
        BriefNavigation.back(from: screen) == .camera ? "相机" : "返回"
    }

    @ViewBuilder
    private var screenContent: some View {
        switch screen {
        case .camera:
            EmptyView()

        case .handOff:
            HandOffView(onSubmit: { state in
                handedOff = NewsRef(
                    publisher: "你交给我的",
                    title: state.text.isEmpty ? "口述的一条新闻" : state.text,
                    url: nil
                )
                screen = .confirm
            })

        case .confirm:
            // 余额门禁就在这一屏，因为这是烧 token 之前的最后一屏。
            ConfirmView(
                news: confirmNews,
                dial: DialState(remainingTokens: current?.budget.remainingThisMonth
                                ?? replayBase?.budget.remainingThisMonth ?? .max),
                onStart: { _ in startResearch() }
            )

        case .progress:
            if let brief = current {
                BriefProgressView(
                    brief: brief,
                    elapsed: elapsed,
                    // 离开不毁任务：回相机，调研（在真实实现里）继续跑。
                    onLeave: { screen = BriefNavigation.back(from: .progress) },
                    onCancel: { cancelResearch() }
                )
            } else {
                missing
            }

        case .review:
            // currentBinding 按 id 定位到 briefs 里的那一条，于是删句、重查
            // 写回的是对应的那一份，而不是死在 ReviewView 自己的副本里、
            // 也不会溅到别的稿上。
            if let bound = currentBinding {
                ReviewView(
                    brief: bound,
                    // 开拍就是回相机——它一直在下面开着，这里只是把这一层收掉。
                    // 提词器要等 Brief 真的能变成一篇 Script 才有东西可放，那是
                    // 管线那一段的事；现在按下去得到的是一台干净的相机。
                    onRecord: { screen = .camera },
                    onSwitchScript: { screen = .scripts }
                )
                .id(bound.wrappedValue.id)
            } else {
                missing
            }

        case .insufficient:
            if let brief = current {
                InsufficientView(
                    news: brief.news,
                    state: insufficientState(for: brief),
                    reason: brief.insufficientReason,
                    onAction: { action in
                        switch action.id {
                        case "retry": startResearch()
                        default: screen = .handOff
                        }
                    }
                )
            } else {
                missing
            }

        case .scripts:
            // 列表是 Brief + Script 的合并流，所以在跑的那一条也在里面。
            ScriptListView(
                syncService: environment.syncService,
                briefs: briefs,
                onSelect: { currentID = $0.id },
                onOpen: { screen = $0 }
            )
        }
    }

    private var missing: some View {
        ContentUnavailableView(
            "没有可看的稿",
            systemImage: "doc.text",
            description: Text(loadError ?? "fixture 没读进来")
        )
    }

    private var confirmNews: NewsRef {
        handedOff ?? current?.news ?? NewsRef(publisher: "待查", title: "一条新闻", url: nil)
    }

    /// `found` 取所有事实点里最硬的那一个的独立源数——说"最多也只有这么多"，
    /// 比把各句的数字加起来诚实：加起来会把同一个源数两遍。
    private func insufficientState(for brief: Brief) -> InsufficientState {
        InsufficientState(
            found: brief.claims.values.map(\.independence).max() ?? 0,
            required: ClaimEvidence.strongThreshold,
            tokensUsed: brief.budget.used
        )
    }

    // MARK: - 状态迁移

    private func loadBriefs() {
        guard briefs.isEmpty, pristine.isEmpty else { return }
        let loaded = BriefFixture.loadAllFromBundle()
        guard !loaded.isEmpty else {
            // 读不到就是没有稿，不是崩：相机照常开，右下角那一格显示「交给我」。
            loadError = "demo-briefs/ 和 brief-fixture.json 都没读到"
            return
        }
        briefs = loaded
        pristine = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 进来先站在第一篇上。顺序是 id 序，所以"第一篇"每次启动都是同一篇。
        currentID = loaded.first?.id
    }

    /// 重放用的底稿：优先当前选中那一篇的原样，其次当前这一份，最后退到第一篇。
    /// 不写成 `pristine.values.first`——字典是无序的，那会让 ④ 每次给出不同的余额。
    private var replayBase: Brief? {
        if let currentID, let original = pristine[currentID] { return original }
        return current ?? briefs.first
    }

    /// ④ → ⑤。每次都从 fixture 那一刻重放，否则第二次进来时九个阶段已经全绿，
    /// 等待页会一闪而过——那不是这一屏要给人看的东西。
    private func startResearch() {
        guard var next = replayBase else {
            screen = BriefNavigation.back(from: screen)
            return
        }
        next.status = .researching
        next.stages = (pristine[next.id] ?? next).stages
        upsert(next)
        currentID = next.id
        researchStartedAt = Date()
        elapsed = "00:00"
        screen = .progress
    }

    /// 取消是真的取消：任务没了，这一篇也从列表里没了，花掉的不退（那句话
    /// 写在按钮上）。右下角那一格随之回到「交给我」，整条无稿路径因此可以
    /// 再走一遍。`currentID` 故意留着不清：它是"④ 再确认一次要重放哪一篇"
    /// 的唯一线索，别的稿一根毫毛都没动。
    private func cancelResearch() {
        if let currentID { briefs.removeAll { $0.id == currentID } }
        researchStartedAt = nil
        screen = BriefNavigation.back(from: .progress)
    }

    /// 本地定时器，只在等待页上跑。
    ///
    /// 它推的是 `Brief.advancingStages()`——计数一律沿用 fixture 里已有的值，
    /// 没有的就保持 nil，界面那一行因此什么也不写。**绝不给未开始的阶段补 0**：
    /// 0 读起来像「挖到了 0 条」，比不显示坏得多。
    private func runStageClock() async {
        guard screen == .progress else { return }
        let startedAt = researchStartedAt ?? Date()
        if researchStartedAt == nil { researchStartedAt = startedAt }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.stageInterval)
            } catch {
                return // 离开这一屏了
            }
            guard !Task.isCancelled, screen == .progress, let running = current else { return }

            elapsed = Self.clock(Date().timeIntervalSince(startedAt))
            let advanced = running.advancingStages()
            // 推回它自己那一格，不是推回"第一篇"。
            upsert(advanced)

            if advanced.status != .researching {
                // 跑完落回审稿页。从这里往回按到不了等待页——那一屏不复存在，
                // 这正是 BriefNavigation.canReturnToProgress(from: .review) 说的。
                screen = .review
                return
            }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
