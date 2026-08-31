import Foundation

// Offline exercise of the take → photo library archiving path.
//
// The stakes are asymmetric and invisible here: the library is a take's only
// home and the working file is deleted on success, so a save that fails
// silently is a lost take. These scenarios therefore assert against a real
// file on disk — does it still exist after each outcome — rather than a
// mock's call count, and they pin the exact wording the HUD shows, since that
// line is the only thing that tells a user a take did not make it.

/// Scriptable stand-in for the real Photos wrapper.
@MainActor
final class FakePhotoLibrary: PhotoLibrarySaving {
    var permission: PhotoLibraryAddPermission
    var permissionAfterRequest: PhotoLibraryAddPermission
    var saveResult: Result<String, Error>

    private(set) var requestCount = 0
    private(set) var savedURLs: [URL] = []

    init(
        permission: PhotoLibraryAddPermission = .granted,
        permissionAfterRequest: PhotoLibraryAddPermission = .granted,
        saveResult: Result<String, Error> = .success("asset-1")
    ) {
        self.permission = permission
        self.permissionAfterRequest = permissionAfterRequest
        self.saveResult = saveResult
    }

    func currentAddPermission() -> PhotoLibraryAddPermission { permission }

    func requestAddPermission() async -> PhotoLibraryAddPermission {
        requestCount += 1
        permission = permissionAfterRequest
        return permission
    }

    func saveVideo(at url: URL) async throws -> String {
        savedURLs.append(url)
        return try saveResult.get()
    }
}

struct FakeSaveError: LocalizedError {
    var errorDescription: String? { "disk full" }
}

/// Records the state sequence the delegate is told about, so ordering is
/// assertable and not just the final value.
@MainActor
final class ArchiveObserver: TakeArchiverDelegate {
    private(set) var states: [TakeArchiveState] = []

    func takeArchiver(_ archiver: TakeArchiver, didUpdate state: TakeArchiveState) {
        states.append(state)
    }
}

/// Writes a real, tiny file so "was it deleted?" is a real question rather
/// than a mock assertion.
@MainActor
func makeTakeFile(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pollux-archive-test-\(name)")
        .appendingPathExtension("mov")
    try? FileManager.default.removeItem(at: url)
    FileManager.default.createFile(atPath: url.path, contents: Data("take".utf8))
    return url
}

@MainActor
func takeFileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

@MainActor
func runArchiveSuite() async -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("Take archiving — recorded video → photo library")

    report.section("HUD wording covers every state the user can land in")

    report.check(TakeArchiveMessage.hudText(state: .idle, permission: .granted) == nil,
                 "nothing is shown before the first take")
    report.check(TakeArchiveMessage.hudText(state: .idle, permission: .notDetermined) == nil,
                 "nothing is shown while the grant is still unanswered")
    report.check(TakeArchiveMessage.hudText(state: .idle, permission: .denied)
                    == "Photos access denied — takes won't be saved.",
                 "a refused grant is stated on arrival, not after a wasted take")
    report.check(TakeArchiveMessage.hudText(state: .idle, permission: .restricted)
                    == "Photos access is restricted — takes won't be saved.",
                 "restricted reads as restricted, not as denied")
    report.check(TakeArchiveMessage.hudText(state: .saving, permission: .granted)
                    == "Saving to Photos…",
                 "saving is visible while it happens")
    report.check(TakeArchiveMessage.hudText(state: .saved(assetIdentifier: "x"), permission: .granted)
                    == "Saved to Photos",
                 "success is confirmed rather than silent")
    report.check(TakeArchiveMessage.hudText(
                    state: .failed(.permissionDenied, retainedFileURL: nil), permission: .denied)
                    == "Photos access denied — this take stayed on the device.",
                 "a failed take says where it ended up")
    report.check(TakeArchiveMessage.hudText(
                    state: .failed(.permissionRestricted, retainedFileURL: nil), permission: .restricted)
                    == "Photos access is restricted — this take stayed on the device.",
                 "restricted failure is distinguishable from a refusal")
    report.check(TakeArchiveMessage.hudText(
                    state: .failed(.saveFailed("disk full"), retainedFileURL: nil), permission: .granted)
                    == "Save failed — disk full",
                 "the underlying reason reaches the user verbatim")

    report.section("a saved take leaves no working copy behind")
    do {
        let library = FakePhotoLibrary(saveResult: .success("asset-42"))
        let observer = ArchiveObserver()
        let archiver = TakeArchiver(library: library)
        archiver.delegate = observer
        let url = makeTakeFile("success")

        archiver.archive(takeAt: url)
        await archiver.waitForPendingArchives()

        report.check(archiver.state == .saved(assetIdentifier: "asset-42"),
                     "state carries the identifier the library handed back",
                     detail: "\(archiver.state)")
        report.check(library.savedURLs == [url],
                     "the take was handed over exactly once",
                     detail: "\(library.savedURLs.count) call(s)")
        report.check(!takeFileExists(url),
                     "the temporary file is gone once the library owns the take")
        report.check(observer.states == [.saving, .saved(assetIdentifier: "asset-42")],
                     "the delegate saw saving then saved, in that order",
                     detail: "\(observer.states)")
    }

    report.section("a failed save keeps the only copy that exists")
    do {
        let library = FakePhotoLibrary(saveResult: .failure(FakeSaveError()))
        let observer = ArchiveObserver()
        let archiver = TakeArchiver(library: library)
        archiver.delegate = observer
        let url = makeTakeFile("save-error")

        archiver.archive(takeAt: url)
        await archiver.waitForPendingArchives()

        report.check(archiver.state == .failed(.saveFailed("disk full"), retainedFileURL: url),
                     "the failure names the reason and points at the surviving file",
                     detail: "\(archiver.state)")
        report.check(takeFileExists(url),
                     "the take is NOT deleted when the library refused it")
        report.check(TakeArchiveMessage.hudText(state: archiver.state, permission: .granted)
                        == "Save failed — disk full",
                     "the HUD repeats the library's own reason")

        try? FileManager.default.removeItem(at: url)
    }

    report.section("a refused library is a dead end, not a deleted take")
    do {
        let library = FakePhotoLibrary(permission: .denied, permissionAfterRequest: .denied)
        let archiver = TakeArchiver(library: library)
        let url = makeTakeFile("denied")

        archiver.archive(takeAt: url)
        await archiver.waitForPendingArchives()

        report.check(archiver.state == .failed(.permissionDenied, retainedFileURL: url),
                     "a denied grant is reported as denied, not as a save error",
                     detail: "\(archiver.state)")
        report.check(library.savedURLs.isEmpty,
                     "the library is never called when the answer is already no")
        report.check(library.requestCount == 0,
                     "an already-answered grant is not asked again")
        report.check(takeFileExists(url),
                     "the take survives a refused grant")

        try? FileManager.default.removeItem(at: url)
    }

    report.section("a restricted library reads differently from a refused one")
    do {
        let library = FakePhotoLibrary(permission: .restricted, permissionAfterRequest: .restricted)
        let archiver = TakeArchiver(library: library)
        let url = makeTakeFile("restricted")

        archiver.archive(takeAt: url)
        await archiver.waitForPendingArchives()

        report.check(archiver.state == .failed(.permissionRestricted, retainedFileURL: url),
                     "restricted is its own outcome — the user cannot fix it in Settings",
                     detail: "\(archiver.state)")
        report.check(takeFileExists(url), "the take survives a restricted library")

        try? FileManager.default.removeItem(at: url)
    }

    report.section("an unanswered grant is asked for exactly once")
    do {
        let library = FakePhotoLibrary(permission: .notDetermined, permissionAfterRequest: .granted)
        let archiver = TakeArchiver(library: library)
        let first = makeTakeFile("undetermined-1")
        let second = makeTakeFile("undetermined-2")

        archiver.archive(takeAt: first)
        archiver.archive(takeAt: second)
        await archiver.waitForPendingArchives()

        report.check(library.requestCount == 1,
                     "the second take reuses the answer rather than re-prompting",
                     detail: "\(library.requestCount) request(s)")
        report.check(archiver.permission == .granted,
                     "the archiver remembers what it was told")
        report.check(library.savedURLs == [first, second],
                     "both takes were saved once the grant arrived")
    }

    report.section("prepare() asks up front so a refusal costs no take")
    do {
        let library = FakePhotoLibrary(permission: .notDetermined, permissionAfterRequest: .denied)
        let archiver = TakeArchiver(library: library)

        await archiver.refreshPermission()

        report.check(library.requestCount == 1, "refreshPermission asks once")
        report.check(archiver.permission == .denied, "and records the answer")
        report.check(TakeArchiveMessage.hudText(state: .idle, permission: archiver.permission)
                        == "Photos access denied — takes won't be saved.",
                     "so the HUD can warn before anything is recorded")

        await archiver.refreshPermission()
        report.check(library.requestCount == 1,
                     "an already-answered grant is not re-prompted on the next screen",
                     detail: "\(library.requestCount) request(s)")
    }

    report.section("back-to-back takes are archived one at a time")
    do {
        let library = FakePhotoLibrary(saveResult: .success("asset-seq"))
        let observer = ArchiveObserver()
        let archiver = TakeArchiver(library: library)
        archiver.delegate = observer
        let first = makeTakeFile("serial-1")
        let second = makeTakeFile("serial-2")

        archiver.archive(takeAt: first)
        archiver.archive(takeAt: second)
        await archiver.waitForPendingArchives()

        report.check(library.savedURLs == [first, second],
                     "handed over in the order they were recorded",
                     detail: "\(library.savedURLs.map(\.lastPathComponent))")
        report.check(!takeFileExists(first) && !takeFileExists(second),
                     "both working copies are gone")
        report.check(observer.states == [
                        .saving, .saved(assetIdentifier: "asset-seq"),
                        .saving, .saved(assetIdentifier: "asset-seq")
                     ],
                     "the second take starts only after the first reports saved",
                     detail: "\(observer.states)")
        report.check(archiver.state == .saved(assetIdentifier: "asset-seq"),
                     "the HUD ends up describing the most recent take")
    }

    return (report.pass, report.fail)
}
