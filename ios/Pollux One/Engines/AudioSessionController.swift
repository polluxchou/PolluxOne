import AVFoundation
import Foundation

/// Owns the app's AVAudioSession.
///
/// Both features that need the microphone go through one session: the video
/// track being recorded, and the live speech recognition that drives reading
/// position. Without an explicitly configured and activated session,
/// `AVAudioEngine.start()` throws and the recognizer never receives a single
/// buffer — the prompter just sits there, which is indistinguishable from
/// "the alignment algorithm doesn't work".
///
/// `AVCaptureSession` will configure the audio session on its own by default.
/// We turn that off (`automaticallyConfiguresApplicationAudioSession = false`
/// in CameraEngine) and set it here instead, so there is exactly one place
/// that decides category and mode.
enum AudioSessionController {
    /// `.playAndRecord` rather than `.record` so a future playback/review
    /// screen doesn't need to reconfigure mid-session. `.videoRecording` mode
    /// selects the mic processing Apple tunes for camera capture.
    static func activateForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.allowBluetooth, .defaultToSpeaker]
        )
        try session.setActive(true, options: [])
    }

    static func deactivate() {
        // Best effort: a failure here only means another app's audio resumes
        // slightly later, which is not worth surfacing to the speaker.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Microphone access is a separate grant from speech recognition — asking
    /// only for the latter leaves the mic silently unavailable.
    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
