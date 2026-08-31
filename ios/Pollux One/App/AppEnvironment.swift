import Foundation

/// Composition root: the one place a concrete BackendClient gets chosen.
/// Swapping MockBackendClient for SupabaseBackendClient later means editing
/// this initializer only — nothing downstream references either type by name.
@MainActor
@Observable
final class AppEnvironment {
    let backend: BackendClient
    let syncService: ScriptSyncService
    var currentUser: User?

    init(backend: BackendClient) {
        self.backend = backend
        self.syncService = ScriptSyncService(backend: backend)
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
