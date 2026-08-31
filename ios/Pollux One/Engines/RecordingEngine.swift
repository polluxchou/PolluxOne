import AVFoundation
import Foundation

protocol RecordingEngineDelegate: AnyObject {
    func recordingEngine(_ engine: RecordingEngine, didFinishRecordingTo url: URL)
    func recordingEngine(_ engine: RecordingEngine, didFailWithError error: Error)
}

/// Starts/stops capture to disk using CameraEngine's `movieOutput`.
/// RecordingEngine never touches AVCaptureDevice directly — camera controls
/// stay CameraEngine's job — it only owns the record/stop lifecycle and the
/// resulting file.
@MainActor
@Observable
final class RecordingEngine: NSObject {
    private(set) var isRecording = false
    private(set) var elapsedSeconds: TimeInterval = 0

    weak var delegate: RecordingEngineDelegate?

    private let cameraEngine: CameraEngine
    private var timer: Timer?
    private var startedAt: Date?

    init(cameraEngine: CameraEngine) {
        self.cameraEngine = cameraEngine
    }

    func startRecording() {
        guard !isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        cameraEngine.movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        cameraEngine.movieOutput.stopRecording()
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let startedAt else { return }
        elapsedSeconds = Date().timeIntervalSince(startedAt)
    }
}

extension RecordingEngine: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            isRecording = false
            elapsedSeconds = 0
            if let error {
                delegate?.recordingEngine(self, didFailWithError: error)
            } else {
                delegate?.recordingEngine(self, didFinishRecordingTo: outputFileURL)
            }
        }
    }
}
