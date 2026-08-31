import AVFoundation
import Foundation
import Speech

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

    /// Both grants are needed and they are separate: speech recognition
    /// authorization alone leaves the microphone unavailable, so the engine
    /// starts and receives nothing.
    func requestAuthorization() async -> Bool {
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        let micGranted = await AudioSessionController.requestMicrophonePermission()
        return speechGranted && micGranted
    }

    /// Picks the recognizer locale from the script's own language: a Chinese
    /// script fed to an en-US recognizer transcribes to noise, and no amount
    /// of alignment tolerance recovers from that.
    static func locale(forScriptText text: String) -> Locale {
        let cjk = text.unicodeScalars.count { (0x4E00...0x9FFF).contains($0.value) }
        let isCJK = !text.isEmpty && Double(cjk) / Double(text.unicodeScalars.count) > 0.2
        return Locale(identifier: isCJK ? "zh-CN" : "en-US")
    }

    func start(locale: Locale = Locale(identifier: "en-US")) throws {
        guard !isRunning else { return }
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechRecognitionError.unavailable
        }
        self.recognizer = recognizer

        // Must come before touching audioEngine.inputNode: without an active
        // session the engine refuses to start and no audio ever arrives.
        do {
            try AudioSessionController.activateForRecording()
        } catch {
            throw SpeechRecognitionError.audioSessionFailed(error)
        }

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
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.request = nil
            throw SpeechRecognitionError.audioEngineFailed(error)
        }
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
        AudioSessionController.deactivate()
    }
}

enum SpeechRecognitionError: LocalizedError {
    case unavailable
    case audioSessionFailed(Error)
    case audioEngineFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Speech recognition isn't available for this language on this device."
        case .audioSessionFailed(let error):
            return "Couldn't start the microphone: \(error.localizedDescription)"
        case .audioEngineFailed(let error):
            return "Couldn't listen for your voice: \(error.localizedDescription)"
        }
    }
}
