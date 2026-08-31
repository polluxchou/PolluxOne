import Foundation

/// Where the reader currently is, as produced by ScriptAlignmentEngine.
/// `confidence` lets TeleprompterEngine decide whether to trust a jump
/// (e.g. ignore a low-confidence match caused by background noise).
struct ReadingPosition: Codable, Equatable {
    var address: ScriptAddress
    var tokenIndexInSentence: Int
    var confidence: Double
    var updatedAt: Date

    static func start(for script: Script) -> ReadingPosition? {
        guard let section = script.sections.first,
              let paragraph = section.paragraphs.first,
              let sentence = paragraph.sentences.first else { return nil }
        return ReadingPosition(
            address: ScriptAddress(
                scriptId: script.id,
                scriptVersion: script.version,
                sectionId: section.id,
                paragraphId: paragraph.id,
                sentenceId: sentence.id
            ),
            tokenIndexInSentence: 0,
            confidence: 1.0,
            updatedAt: Date()
        )
    }
}

/// Derived, display-ready progress. Kept separate from ReadingPosition so
/// TeleprompterEngine can compute it once and views just read numbers.
struct ReadingProgress: Codable, Equatable {
    var completedSentences: Int
    var totalSentences: Int
    var fractionComplete: Double

    var percentString: String {
        "\(Int((fractionComplete * 100).rounded()))%"
    }

    static let zero = ReadingProgress(completedSentences: 0, totalSentences: 0, fractionComplete: 0)
}

/// One continuous "camera rolling" take. Distinct from ReadingSession because
/// a user may pause the teleprompter without stopping the recording.
struct RecordingSession: Identifiable, Codable, Equatable {
    let id: UUID
    let scriptRevisionId: UUID
    var startedAt: Date
    var endedAt: Date?
    var cameraConfiguration: CameraConfiguration
    var localVideoURL: URL?

    var isActive: Bool { endedAt == nil }
}

/// Tracks the reading-following state machine across one RecordingSession:
/// the running ReadingPosition history and confidence, independent of the
/// video file itself.
struct ReadingSession: Identifiable, Codable, Equatable {
    let id: UUID
    let recordingSessionId: UUID
    var currentPosition: ReadingPosition?
    var progress: ReadingProgress
    var isPaused: Bool
}
