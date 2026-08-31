import AVFoundation
import Foundation
import Speech

/// One incremental speech result. `isFinal` mirrors SFSpeechRecognitionResult
/// but nothing above this file needs to know that Speech.framework exists —
/// ScriptAlignmentEngine only ever sees this struct, so the recognizer can be
/// replaced (on-device model, different provider) without touching alignment.
struct SpeechTranscript: Equatable {
    let text: String
    let isFinal: Bool
    let timestamp: Date
}

protocol SpeechRecognitionServiceDelegate: AnyObject {
    func speechRecognitionService(_ service: SpeechRecognitionService, didProduce transcript: SpeechTranscript)
    func speechRecognitionService(_ service: SpeechRecognitionService, didTapAudioBuffer buffer: AVAudioPCMBuffer)
}

/// Wraps SFSpeechRecognizer + AVAudioEngine behind a small push interface.
/// Runs continuously during a recording take; both ScriptAlignmentEngine and
/// SafeWordDetector subscribe to the same transcript stream via the delegate
/// rather than each opening their own recognition session.
@MainActor
final class SpeechRecognitionService: NSObject {
    weak var delegate: SpeechRecognitionServiceDelegate?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private(set) var isRunning = false

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func start(locale: Locale = Locale(identifier: "en-US")) throws {
        guard !isRunning else { return }
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechRecognitionError.unavailable
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device first: keeps raw audio off the network by default, per
        // the product's privacy goal, and falls back automatically when a
        // locale doesn't support it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            guard let self else { return }
            Task { @MainActor in
                self.delegate?.speechRecognitionService(self, didTapAudioBuffer: buffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let transcript = SpeechTranscript(
                        text: result.bestTranscription.formattedString,
                        isFinal: result.isFinal,
                        timestamp: Date()
                    )
                    self.delegate?.speechRecognitionService(self, didProduce: transcript)
                }
                if error != nil {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRunning = false
    }
}

enum SpeechRecognitionError: Error {
    case unavailable
}
