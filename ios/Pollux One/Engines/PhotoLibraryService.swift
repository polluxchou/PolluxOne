import Photos
import UIKit

/// The only file in the app that talks to Photos.
///
/// Add-only authorization on purpose: Pollux One writes takes and never reads
/// the library, so this is both the lightest prompt the system offers and the
/// one that a "Limited Access" choice cannot degrade.
@MainActor
final class PhotoLibraryService: PhotoLibrarySaving {
    func currentAddPermission() -> PhotoLibraryAddPermission {
        Self.permission(for: PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestAddPermission() async -> PhotoLibraryAddPermission {
        let status: PHAuthorizationStatus = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        return Self.permission(for: status)
    }

    func saveVideo(at url: URL) async throws -> String {
        // A 4K take is a large copy. Without this, stopping the recording and
        // immediately backgrounding the app can have the write killed
        // mid-flight — and since the library is the take's only home, that is
        // a lost take rather than a retryable one.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SaveTakeToPhotos")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        // performChanges runs its block off the main actor, so the identifier
        // comes back through a reference rather than a captured local.
        let box = CreatedAssetIdentifier()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            box.value = request?.placeholderForCreatedAsset?.localIdentifier
        }

        guard let identifier = box.value else {
            throw PhotoLibraryServiceError.assetIdentifierMissing
        }
        return identifier
    }

    private static func permission(for status: PHAuthorizationStatus) -> PhotoLibraryAddPermission {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        // A limited grant still permits adding, which is all this app asks for.
        case .authorized, .limited: return .granted
        @unknown default: return .denied
        }
    }
}

/// Carries the new asset's identifier back out of the change block.
private final class CreatedAssetIdentifier: @unchecked Sendable {
    var value: String?
}

enum PhotoLibraryServiceError: LocalizedError {
    case assetIdentifierMissing

    var errorDescription: String? {
        switch self {
        case .assetIdentifierMissing:
            return "the photo library accepted the video but returned no asset"
        }
    }
}
