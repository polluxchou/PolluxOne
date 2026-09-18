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

    /// Records what this take was actually read at, into `user_reading_rates`
    /// (`user_id · language · chars_per_second · sample_count`). One row per
    /// language per user: Chinese and English differ by more than a factor of
    /// three, so a single number for a bilingual reader is nobody's rate.
    ///
    /// Called once at the end of a take, and only when `ReadingPacer` judged
    /// the take long enough to have measured anything — see
    /// `ReadingPacer.exportSample()`.
    ///
    /// Until enough of these exist, estimates fall back to the language
    /// default, and `Brief.pacedToUser` is false so the copy doesn't claim a
    /// script is paced to a reader it has never heard.
    func upsertReadingRate(language: ScriptLanguage, charsPerSecond: Double) async throws
}

enum BackendError: Error {
    case notAuthenticated
    case notFound
    case network(Error)
}
