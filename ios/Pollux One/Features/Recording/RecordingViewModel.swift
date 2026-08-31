import Foundation

/// UI-only state for the Recording screen (which parameter is being
/// adjusted, whether the teleprompter adjust sheet is open). Everything
/// about cameras, speech, or scripts stays in SessionManager/CameraEngine —
/// this view model just mediates between those engines and the HUD.
@MainActor
@Observable
final class RecordingViewModel {
    var activeParameter: CameraParameter?
    var isAdjustingTeleprompter = false
    var teleprompterSettings = TeleprompterSettings()

    let sessionManager: SessionManager
    private let capabilityService = DeviceCapabilityService()

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    var remainingRecordingTime: TimeInterval? {
        capabilityService.estimatedRecordingTimeRemaining(for: sessionManager.cameraEngine.configuration)
    }

    /// The single line the top HUD shows about where the last take went.
    var archiveMessage: String? {
        TakeArchiveMessage.hudText(
            state: sessionManager.takeArchiveState,
            permission: sessionManager.photoLibraryPermission
        )
    }

    func start(script: Script) async {
        await sessionManager.prepare(script: script)
    }

    func toggleRecording() {
        if sessionManager.recordingEngine.isRecording {
            sessionManager.endTake()
        } else {
            sessionManager.startTake()
        }
    }

    func selectParameter(_ parameter: CameraParameter) {
        // FOCUS has no slider to open: AUTO and LOCK are the whole control, so
        // tapping the value toggles it. Without this the column was inert —
        // it read AUTO forever and nothing happened when you pressed it.
        if parameter == .focus {
            let engine = sessionManager.cameraEngine
            engine.setFocusLocked(engine.configuration.focusMode != .locked)
            activeParameter = nil
            return
        }
        activeParameter = (activeParameter == parameter) ? nil : parameter
    }

    func openTeleprompterAdjust() {
        isAdjustingTeleprompter = true
    }

    func closeTeleprompterAdjust() {
        isAdjustingTeleprompter = false
    }

    func selectLens(_ lens: CameraLensOption) {
        sessionManager.cameraEngine.setLens(lens)
    }

    /// Off while rolling, for the same reason as the flip: reconfiguring the
    /// device's active format ends the movie file that's being written.
    var canChangeFormat: Bool {
        !sessionManager.recordingEngine.isRecording
    }

    func selectFormat(resolution: RecordingResolution, frameRate: RecordingFrameRate) {
        guard canChangeFormat else { return }
        sessionManager.cameraEngine.setFormat(resolution: resolution, frameRate: frameRate)
    }

    /// Flipping removes and re-adds the session's video input, which ends a
    /// running movie file early — so it's only offered while stopped, and the
    /// control is disabled to match rather than failing silently.
    var canFlipCamera: Bool {
        !sessionManager.recordingEngine.isRecording
            && !sessionManager.cameraEngine.isSwitchingCamera
            && sessionManager.cameraEngine.configuration.availableFacings.count > 1
    }

    func flipCamera() {
        guard canFlipCamera else { return }
        Task { await sessionManager.cameraEngine.flipCamera() }
    }
}
