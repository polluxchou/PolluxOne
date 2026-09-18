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
    /// 相机会话是 app 级的，不属于任何一篇稿。
    ///
    /// 之前它在 RecordingView.init 里造：换一篇稿 = 新的 View = 新的
    /// SessionManager = 新的 CameraEngine，用户会看到取景器黑一下重启。
    /// 引擎层本来就支持换稿（prepare(script:) 内部就是 teleprompterEngine.load
    /// + alignmentEngine.reset），错的一直是构造时机，不是能力。
    let sessionManager: SessionManager
    var currentUser: User?

    init(backend: BackendClient) {
        self.backend = backend
        let sync = ScriptSyncService(backend: backend)
        self.syncService = sync
        // One archiver, shared: the session hands takes to the same object the
        // rest of the app watches for archive state.
        let archiver = TakeArchiver(library: PhotoLibraryService())
        self.takeArchiver = archiver
        self.sessionManager = SessionManager(
            syncService: sync,
            alignmentEngine: SlidingWindowAlignmentEngine(),
            takeArchiver: archiver
        )
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
