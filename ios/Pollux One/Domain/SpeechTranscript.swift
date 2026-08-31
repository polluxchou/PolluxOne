import Foundation

/// One incremental speech result. `isFinal` mirrors SFSpeechRecognitionResult,
/// but this lives in Domain rather than next to the recognizer on purpose:
/// ScriptAlignmentEngine and SafeWordDetector consume only this value type, so
/// neither has to import Speech.framework, and the alignment algorithm — the
/// core of the product — stays testable without a microphone.
struct SpeechTranscript: Equatable {
    /// Cumulative text for the take so far, as speech recognizers report it.
    let text: String
    let isFinal: Bool
    let timestamp: Date

    init(text: String, isFinal: Bool, timestamp: Date = Date()) {
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
    }
}
