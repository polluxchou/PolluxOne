import Foundation

/// Whether the user has let Pollux One add to their photo library.
///
/// Add-only is all this app ever needs: takes go into the camera roll and
/// nothing here reads or manages what is already there. That keeps the
/// permission prompt to its lightest form and sidesteps "Limited Access"
/// entirely — a limited grant still allows adding.
enum PhotoLibraryAddPermission: Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
}

/// Why a take did not make it into the library.
enum TakeArchiveFailure: Equatable {
    case permissionDenied
    case permissionRestricted
    case saveFailed(String)
}

/// Where the most recent take stands on its way to the photo library.
///
/// `failed` carries the file that was deliberately left on disk rather than
/// deleted, so a future retry has somewhere to start. Nothing retries today.
enum TakeArchiveState: Equatable {
    case idle
    case saving
    case saved(assetIdentifier: String)
    case failed(TakeArchiveFailure, retainedFileURL: URL?)
}

/// Everything the archiver needs from the photo library, as a protocol so the
/// state machine can be exercised offline (see scripts/test-engines.sh)
/// without a library, a device, or a simulator.
@MainActor
protocol PhotoLibrarySaving: AnyObject {
    func currentAddPermission() -> PhotoLibraryAddPermission
    func requestAddPermission() async -> PhotoLibraryAddPermission
    /// Returns the created asset's `localIdentifier` on success.
    func saveVideo(at url: URL) async throws -> String
}

/// Maps archive state onto the single line the top HUD shows.
///
/// A pure function rather than logic on the view, because a take that failed
/// to save is gone — the library is its only home — and this wording is the
/// only thing that tells the user so. It is worth asserting.
enum TakeArchiveMessage {
    static func hudText(
        state: TakeArchiveState,
        permission: PhotoLibraryAddPermission
    ) -> String? {
        switch state {
        case .idle:
            switch permission {
            case .denied:
                return "Photos access denied — takes won't be saved."
            case .restricted:
                return "Photos access is restricted — takes won't be saved."
            case .granted, .notDetermined:
                // Nothing has been recorded yet and nothing is wrong: staying
                // silent keeps the line out of the layout entirely.
                return nil
            }
        case .saving:
            return "Saving to Photos…"
        case .saved:
            return "Saved to Photos"
        case .failed(let failure, _):
            switch failure {
            case .permissionDenied:
                return "Photos access denied — this take stayed on the device."
            case .permissionRestricted:
                return "Photos access is restricted — this take stayed on the device."
            case .saveFailed(let message):
                return "Save failed — \(message)"
            }
        }
    }
}
