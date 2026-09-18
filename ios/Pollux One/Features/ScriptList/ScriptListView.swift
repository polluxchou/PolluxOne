import SwiftUI

/// Browsing and selecting a script. Deliberately not an editor — long-form
/// writing happens on Web; iOS only needs enough here to pick a script and
/// jump into Recording (Feature 1).
///
/// spec §9.2 ②：列表是 **Brief + Script 的合并流**。一篇还在调研的 Brief 还不是
/// Script，`viewModel.scripts` 装不下它——只画 scripts 就会悄悄漏掉用户此刻
/// 最想看的那一条。合并与排序都在 `ScriptListRows` 里，这里只负责画。
struct ScriptListView: View {
    // The capture session is app-lifetime now, so this screen hands the one
    // that already exists to RecordingView rather than letting it build its
    // own.
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: ScriptListViewModel
    private let syncService: ScriptSyncService
    /// 还没有变成 Script 的那些——在跑的、可审的、信源不足的。
    private let briefs: [Brief]
    /// 跳去 Brief 那一侧的屏（空状态的「交给我」，以及点一条 Brief）。
    private let onOpen: (BriefScreen) -> Void

    init(syncService: ScriptSyncService,
         briefs: [Brief] = [],
         onOpen: @escaping (BriefScreen) -> Void = { _ in }) {
        self.syncService = syncService
        self.briefs = briefs
        self.onOpen = onOpen
        _viewModel = State(wrappedValue: ScriptListViewModel(syncService: syncService))
    }

    private var briefsByID: [String: Brief] {
        Dictionary(uniqueKeysWithValues: briefs.map { ($0.id, $0) })
    }

    private var scriptsByID: [String: Script] {
        Dictionary(uniqueKeysWithValues: viewModel.scripts.map { ($0.id.uuidString, $0) })
    }

    private var rows: [ScriptListRow] {
        ScriptListRows.build(
            scriptTitles: viewModel.scripts.map {
                (id: $0.id.uuidString, title: $0.title, seconds: Self.estimatedSeconds($0))
            },
            briefs: briefs
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && rows.isEmpty {
                    ProgressView("Syncing scripts…")
                } else if rows.isEmpty {
                    emptyState
                } else {
                    List(rows) { row in
                        if let brief = briefsByID[row.id] {
                            Button {
                                onOpen(ScriptSlot(brief: brief).destination)
                            } label: {
                                ScriptListRowView(row: row)
                            }
                            .buttonStyle(.plain)
                        } else if let script = scriptsByID[row.id] {
                            NavigationLink {
                                RecordingView(
                                    script: script,
                                    sessionManager: environment.sessionManager
                                )
                            } label: {
                                ScriptListRowView(row: row)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await viewModel.refresh() }
                }
            }
            .navigationTitle("Pollux One")
            .task { await viewModel.onAppear() }
        }
    }

    private var emptyState: some View {
        let empty = ScriptListEmptyState()
        return ContentUnavailableView {
            Label("还没有稿子", systemImage: "doc.text")
        } description: {
            Text(empty.text)
        } actions: {
            Button("交给我") { onOpen(empty.action) }
                .buttonStyle(.borderedProminent)
        }
    }

    /// 列表上的秒数按语种的默认语速估，不是按这个用户自己的语速——
    /// 后者要等他真的读过一遍才有（spec §9.2 ①）。
    private static func estimatedSeconds(_ script: Script) -> Int {
        let text = script.fullText
        let rate = ScriptLanguage.detect(text).defaultCharactersPerSecond
        return max(1, Int((Double(text.count) / rate).rounded()))
    }
}

private struct ScriptListRowView: View {
    let row: ScriptListRow

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.headline)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if row.isResearching {
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
