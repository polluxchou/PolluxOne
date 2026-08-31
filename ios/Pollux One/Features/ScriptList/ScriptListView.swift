import SwiftUI

/// Browsing and selecting a script. Deliberately not an editor — long-form
/// writing happens on Web; iOS only needs enough here to pick a script and
/// jump into Recording (Feature 1).
struct ScriptListView: View {
    @State private var viewModel: ScriptListViewModel
    private let syncService: ScriptSyncService

    init(syncService: ScriptSyncService) {
        self.syncService = syncService
        _viewModel = State(wrappedValue: ScriptListViewModel(syncService: syncService))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.scripts.isEmpty {
                    ProgressView("Syncing scripts…")
                } else if viewModel.scripts.isEmpty {
                    ContentUnavailableView(
                        "No scripts yet",
                        systemImage: "doc.text",
                        description: Text("Write a script on the Pollux One web console, then pull to refresh.")
                    )
                } else {
                    List(viewModel.scripts) { script in
                        NavigationLink {
                            RecordingView(script: script, syncService: syncService)
                        } label: {
                            ScriptRow(script: script)
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
}

private struct ScriptRow: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(script.title)
                .font(.headline)
            Text("\(script.allSentences.count) sentences · v\(script.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
