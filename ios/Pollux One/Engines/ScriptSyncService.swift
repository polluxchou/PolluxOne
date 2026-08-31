import Foundation

/// The only thing on iOS that talks to BackendClient for script content.
/// Views and SessionManager go through this so there is one place that
/// decides "do we have a fresh enough copy, or do we fetch". V1 keeps
/// everything in memory; a later version can add on-disk caching here
/// without changing callers.
@MainActor
@Observable
final class ScriptSyncService {
    private(set) var scripts: [Script] = []
    private(set) var isSyncing = false
    private(set) var lastError: String?

    private let backend: BackendClient

    init(backend: BackendClient) {
        self.backend = backend
    }

    func refreshScripts() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            scripts = try await backend.fetchScripts()
            lastError = nil
        } catch {
            lastError = "Couldn't sync scripts: \(error.localizedDescription)"
        }
    }

    func fetchLatest(scriptId: UUID) async throws -> Script {
        try await backend.fetchScript(id: scriptId)
    }

    /// Pushes a Safe Word edit made during recording back to the cloud copy.
    /// Called by SessionManager after a RecordingSession ends.
    func pushParagraphEdit(scriptId: UUID, paragraphId: UUID, newText: String) async throws -> Script {
        let updated = try await backend.updateParagraph(scriptId: scriptId, paragraphId: paragraphId, newText: newText)
        if let index = scripts.firstIndex(where: { $0.id == updated.id }) {
            scripts[index] = updated
        }
        return updated
    }

    func reportProgress(scriptId: UUID, progress: ReadingProgress) {
        Task {
            try? await backend.reportReadingProgress(scriptId: scriptId, progress: progress)
        }
    }
}
