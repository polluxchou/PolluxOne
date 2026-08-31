import AVFoundation
import Foundation

/// Orchestrates one script-reading session end to end: freezes a Script
/// version into a local ScriptRevision, wires the engines' delegate callbacks
/// together (speech -> alignment -> teleprompter, speech -> safe word ->
/// voice command), and decides how Safe Word edits get merged back to the
/// cloud. This is the one object that knows about all the engines; each
/// engine still only knows its own narrow job.
@MainActor
@Observable
final class SessionManager {
    private(set) var scriptRevision: ScriptRevision?
    private(set) var readingSession: ReadingSession?
    private(set) var voiceCommandState: VoiceCommandEngineState = .idle
    private(set) var pendingVoiceCommand: VoiceCommand?
    /// Non-nil when listening failed to start. Surfaced on the HUD so a
    /// prompter that isn't following is distinguishable from a mic problem.
    private(set) var speechError: String?

    let cameraEngine: CameraEngine
    let recordingEngine: RecordingEngine
    let teleprompterEngine = TeleprompterEngine()
    let audioLevelMonitor = AudioLevelMonitor()

    private let speechService = SpeechRecognitionService()
    private let alignmentEngine: ScriptAlignmentEngine
    private let safeWordDetector = SafeWordDetector()
    private let voiceCommandEngine = VoiceCommandEngine()
    private let syncService: ScriptSyncService

    private var currentRecordingSession: RecordingSession?
    private var latestTranscriptText = ""

    init(syncService: ScriptSyncService, alignmentEngine: ScriptAlignmentEngine) {
        self.syncService = syncService
        self.alignmentEngine = alignmentEngine
        let camera = CameraEngine()
        self.cameraEngine = camera
        self.recordingEngine = RecordingEngine(cameraEngine: camera)

        speechService.delegate = self
        safeWordDetector.delegate = self
        voiceCommandEngine.delegate = self
    }

    func prepare(script: Script) async {
        let revision = ScriptRevision(id: UUID(), baseScript: script, localSequence: 0, editedAt: Date())
        scriptRevision = revision
        teleprompterEngine.load(script: script)
        alignmentEngine.reset(script: script, startingAt: nil)
        readingSession = nil

        await cameraEngine.requestAuthorizationAndConfigure()
        // Speech + microphone are separate grants; without both, reading
        // position can never update.
        if await speechService.requestAuthorization() {
            speechError = nil
        } else {
            speechError = "Microphone or speech access denied — the prompter can't follow you. Enable both in Settings."
        }
    }

    func startTake() {
        guard let revision = scriptRevision else { return }
        let recordingSession = RecordingSession(
            id: UUID(),
            scriptRevisionId: revision.id,
            startedAt: Date(),
            endedAt: nil,
            cameraConfiguration: cameraEngine.configuration,
            localVideoURL: nil
        )
        currentRecordingSession = recordingSession
        readingSession = ReadingSession(
            id: UUID(),
            recordingSessionId: recordingSession.id,
            currentPosition: ReadingPosition.start(for: revision.script),
            progress: .zero,
            isPaused: false
        )

        // Every take starts from the top of the script, so the engines that
        // carry a position have to be rewound too. Resetting only
        // readingSession left the alignment engine and the prompter showing
        // wherever the previous take ended.
        alignmentEngine.reset(script: revision.script, startingAt: nil)
        teleprompterEngine.load(script: revision.script)
        safeWordDetector.reset()
        latestTranscriptText = ""

        recordingEngine.startRecording()
        audioLevelMonitor.startDisplayUpdates()

        do {
            try speechService.start(
                locale: SpeechRecognitionService.locale(forScriptText: revision.script.fullText)
            )
            speechError = nil
        } catch {
            // Swallowing this is what makes a broken microphone look exactly
            // like a broken alignment algorithm: the prompter simply never
            // moves and nothing says why.
            speechError = error.localizedDescription
        }
    }

    func endTake() {
        recordingEngine.stopRecording()
        speechService.stop()
        audioLevelMonitor.stopDisplayUpdates()
        currentRecordingSession?.endedAt = Date()
    }

    func confirmPendingVoiceCommand() {
        voiceCommandEngine.confirm()
    }

    func rejectPendingVoiceCommand() {
        voiceCommandEngine.reject()
        pendingVoiceCommand = nil
    }

    /// Called after the take ends (or opportunistically between takes) to
    /// push any Safe Word edits made locally back to the Web copy of record.
    func syncEditsToCloud() async {
        guard let revision = scriptRevision, revision.localSequence > 0 else { return }
        for section in revision.script.sections {
            for paragraph in section.paragraphs {
                _ = try? await syncService.pushParagraphEdit(
                    scriptId: revision.script.id,
                    paragraphId: paragraph.id,
                    newText: paragraph.fullText
                )
            }
        }
    }

    private func applyParagraphReplacement(paragraphId: UUID, newText: String) {
        guard var revision = scriptRevision else { return }
        var script = revision.script
        outer: for sectionIndex in script.sections.indices {
            for paragraphIndex in script.sections[sectionIndex].paragraphs.indices
            where script.sections[sectionIndex].paragraphs[paragraphIndex].id == paragraphId {
                let order = script.sections[sectionIndex].paragraphs[paragraphIndex].order
                script.sections[sectionIndex].paragraphs[paragraphIndex] = Paragraph(
                    id: paragraphId,
                    order: order,
                    sentences: SentenceSplitter.sentences(from: newText)
                )
                break outer
            }
        }
        revision.baseScript = script
        revision.localSequence += 1
        revision.editedAt = Date()
        scriptRevision = revision

        teleprompterEngine.load(script: script)
        // Realign from the same address so the reader doesn't visually jump.
        alignmentEngine.reset(script: script, startingAt: readingSession?.currentPosition?.address)
    }
}

extension SessionManager: SpeechRecognitionServiceDelegate {
    nonisolated func speechRecognitionService(_ service: SpeechRecognitionService, didProduce transcript: SpeechTranscript) {
        Task { @MainActor in
            // Recorded before the detector runs: if the safe word fires on
            // this transcript, VoiceCommandEngine needs the text as it stood
            // *before* it, so it parses only what follows the wake word.
            latestTranscriptText = transcript.text
            safeWordDetector.ingest(transcript: transcript)
            voiceCommandEngine.ingest(transcript: transcript)

            guard case .idle = voiceCommandEngine.state else { return }
            guard let position = alignmentEngine.ingest(transcript: transcript) else { return }
            readingSession?.currentPosition = position
            // Update before reading progress back: the engine derives progress
            // from the new position, so reading it first stored the previous
            // sentence's value.
            teleprompterEngine.update(position: position)
            readingSession?.progress = teleprompterEngine.displayState.progress
        }
    }

    nonisolated func speechRecognitionService(_ service: SpeechRecognitionService, didTapAudioBuffer buffer: AVAudioPCMBuffer) {
        Task { @MainActor in
            audioLevelMonitor.ingest(buffer: buffer)
        }
    }
}

extension SessionManager: SafeWordDetectorDelegate {
    nonisolated func safeWordDetectorDidDetectSafeWord(_ detector: SafeWordDetector) {
        Task { @MainActor in
            guard let paragraphId = currentParagraphId() else { return }
            voiceCommandEngine.beginListening(
                currentParagraphId: paragraphId,
                spokenTextSoFar: latestTranscriptText
            )
        }
    }
}

extension SessionManager: VoiceCommandEngineDelegate {
    nonisolated func voiceCommandEngine(_ engine: VoiceCommandEngine, didChangeState state: VoiceCommandEngineState) {
        Task { @MainActor in
            voiceCommandState = state
            if case .awaitingConfirmation(let command) = state {
                pendingVoiceCommand = command
            } else if case .idle = state {
                pendingVoiceCommand = nil
            }
        }
    }

    nonisolated func voiceCommandEngine(_ engine: VoiceCommandEngine, didConfirm command: VoiceCommand) {
        Task { @MainActor in
            if case .replaceParagraph(let paragraphId, let newText) = command.kind {
                applyParagraphReplacement(paragraphId: paragraphId, newText: newText)
            }
            pendingVoiceCommand = nil
        }
    }

    private func currentParagraphId() -> UUID? {
        guard let address = readingSession?.currentPosition?.address else { return nil }
        return address.paragraphId
    }
}
