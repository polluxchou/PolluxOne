import Foundation

/// Composition root: the one place a concrete BackendClient gets chosen.
/// Swapping MockBackendClient for SupabaseBackendClient later means editing
/// this initializer only — nothing downstream references either type by name.
@MainActor
@Observable
final class AppEnvironment {
    let backend: BackendClient
    let syncService: ScriptSyncService
    /// App-lifetime on purpose: a take that finishes writing after the
    /// recording screen is gone still has to reach the photo library.
    let takeArchiver: TakeArchiver
    var currentUser: User?

    init(backend: BackendClient) {
        self.backend = backend
        self.syncService = ScriptSyncService(backend: backend)
        self.takeArchiver = TakeArchiver(library: PhotoLibraryService())
    }

    func signIn(email: String, password: String) async throws {
        currentUser = try await backend.signIn(email: email, password: password)
    }

    func signOut() async {
        await backend.signOut()
        currentUser = nil
    }

    func restoreSession() async {
        currentUser = await backend.currentUser()
    }
}
