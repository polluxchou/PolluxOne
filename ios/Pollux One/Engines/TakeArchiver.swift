import Foundation

protocol TakeArchiverDelegate: AnyObject {
    func takeArchiver(_ archiver: TakeArchiver, didUpdate state: TakeArchiveState)
}

/// Owns one job: getting a finished take out of the app's temporary directory
/// and into the user's photo library.
///
/// Lives for the whole app session (AppEnvironment holds it), not for the
/// recording screen. Stopping a take and immediately swiping back to the
/// script list tears that screen down before AVCaptureMovieFileOutput's
/// completion callback arrives — if this object died with the screen, the
/// most ordinary gesture in the app would drop the video on the floor.
@MainActor
@Observable
final class TakeArchiver {
    private(set) var state: TakeArchiveState = .idle
    private(set) var permission: PhotoLibraryAddPermission = .notDetermined

    weak var delegate: TakeArchiverDelegate?

    private let library: PhotoLibrarySaving
    private var queue: [URL] = []
    private var drainTask: Task<Void, Never>?

    init(library: PhotoLibrarySaving) {
        self.library = library
        self.permission = library.currentAddPermission()
    }

    /// Hands one finished take to the library. Takes are archived one at a
    /// time: a second take started while the first is still copying queues
    /// behind it rather than racing it.
    func archive(takeAt url: URL) {
        queue.append(url)
        guard drainTask == nil else { return }
        // Unstructured on purpose: this must outlive whatever screen was on
        // display when the take stopped.
        drainTask = Task { [weak self] in await self?.drain() }
    }

    /// Suspends until every queued take has been dealt with. Nothing in the
    /// app needs this yet; the offline scenarios do, and asking the object
    /// whether it is finished beats sleeping and hoping.
    func waitForPendingArchives() async {
        await drainTask?.value
    }

    private func drain() async {
        while !queue.isEmpty {
            let url = queue.removeFirst()
            await archiveNow(url)
        }
        // Cleared here rather than in the Task body: there is no suspension
        // point between the emptiness check and this line, so a take enqueued
        // concurrently cannot be stranded without a drainer.
        drainTask = nil
    }

    private func archiveNow(_ url: URL) async {
        update(.saving)
        do {
            let identifier = try await library.saveVideo(at: url)
            // The library is the take's only home now, so the working copy goes.
            try? FileManager.default.removeItem(at: url)
            update(.saved(assetIdentifier: identifier))
        } catch {
            // Deliberately keep the file: it is the only copy left.
            update(.failed(.saveFailed(error.localizedDescription), retainedFileURL: url))
        }
    }

    private func update(_ newState: TakeArchiveState) {
        state = newState
        delegate?.takeArchiver(self, didUpdate: newState)
    }
}
