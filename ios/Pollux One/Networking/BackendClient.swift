import Foundation

/// Everything the app needs from a backend. No type in this file mentions
/// Supabase — that's the point. `SupabaseBackendClient` (see
/// SupabaseBackendClient.swift) implements this against Supabase; a future
/// self-hosted API would implement it the same way, and nothing above this
/// layer would change.
protocol BackendClient {
    func signIn(email: String, password: String) async throws -> User
    func currentUser() async -> User?
    func signOut() async

    func fetchScripts() async throws -> [Script]
    func fetchScript(id: UUID) async throws -> Script

    /// Pushes a Safe-Word-driven paragraph edit back to the cloud copy.
    /// Called after a RecordingSession ends, never mid-take.
    func updateParagraph(scriptId: UUID, paragraphId: UUID, newText: String) async throws -> Script

    func reportReadingProgress(scriptId: UUID, progress: ReadingProgress) async throws
}

enum BackendError: Error {
    case notAuthenticated
    case notFound
    case network(Error)
}
