import Foundation

// Offline exercise of the take → photo library archiving path.
//
// The stakes are asymmetric and invisible here: the library is a take's only
// home and the working file is deleted on success, so a save that fails
// silently is a lost take. These scenarios therefore assert against a real
// file on disk — does it still exist after each outcome — rather than a
// mock's call count, and they pin the exact wording the HUD shows, since that
// line is the only thing that tells a user a take did not make it.

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

    return (report.pass, report.fail)
}
