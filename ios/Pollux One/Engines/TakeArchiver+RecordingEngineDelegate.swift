import Foundation

/// Kept out of TakeArchiver.swift on purpose: RecordingEngineDelegate's
/// signatures pull in RecordingEngine → CameraEngine → iOS-only AVFoundation,
/// which would stop the archiver compiling in the offline harness that
/// scripts/test-engines.sh builds on macOS.
extension TakeArchiver: RecordingEngineDelegate {
    func recordingEngine(_ engine: RecordingEngine, didFinishRecordingTo url: URL) {
        archive(takeAt: url)
    }

    func recordingEngine(_ engine: RecordingEngine, didFailWithError error: Error) {
        recordingFailed(error.localizedDescription)
    }
}
