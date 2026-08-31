import Foundation

protocol TakeArchiverDelegate: AnyObject {
    func takeArchiver(_ archiver: TakeArchiver, didUpdate state: TakeArchiveState)
}

/// Owns one job: getting a finished take out of the app's temporary directory
/// and into the user's photo library.
@MainActor
@Observable
final class TakeArchiver {
    private(set) var state: TakeArchiveState = .idle
    private(set) var permission: PhotoLibraryAddPermission = .notDetermined

    weak var delegate: TakeArchiverDelegate?

    private let library: PhotoLibrarySaving

    init(library: PhotoLibrarySaving) {
        self.library = library
        self.permission = library.currentAddPermission()
    }
}
