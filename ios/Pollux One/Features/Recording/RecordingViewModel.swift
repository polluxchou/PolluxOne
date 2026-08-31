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
        activeParameter = (activeParameter == parameter) ? nil : parameter
    }

    func openTeleprompterAdjust() {
        isAdjustingTeleprompter = true
    }

    func closeTeleprompterAdjust() {
        isAdjustingTeleprompter = false
    }

    func selectLens(_ lens: CameraLensPosition) {
        // V1: front camera exposes at most a wide lens on most devices;
        // switching maps to the closest zoom factor for lenses without a
        // dedicated physical element.
        switch lens {
        case .ultraWide: sessionManager.cameraEngine.setZoomFactor(0.5)
        case .wide: sessionManager.cameraEngine.setZoomFactor(1.0)
        case .telephoto: sessionManager.cameraEngine.setZoomFactor(2.0)
        }
    }

    func flipCamera() {
        // V1 is front-camera-only per the product spec (eye-contact use
        // case); this is a placeholder entry point for a future back-camera
        // b-roll mode rather than a functioning flip today.
    }
}
