import AVFoundation
import Foundation

/// Drives the top-HUD waveform (Feature 1) and the Safe Word waveform
/// (Feature 4) from the same audio tap, so both answer "is the mic hearing
/// me" without each owning its own audio session.
@MainActor
@Observable
final class AudioLevelMonitor {
    /// Recent normalized levels (0...1), newest last. Fixed-size so the
    /// waveform view can just map it to bars.
    private(set) var recentLevels: [Float] = Array(repeating: 0, count: 24)

    private var displayTimer: Timer?
    private var currentLevel: Float = 0

    /// Called by SpeechRecognitionService with each audio buffer it taps,
    /// so we don't need a second, competing tap on the mic input node.
    func ingest(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        var sum: Float = 0
        for i in 0..<frameCount { sum += abs(channelData[i]) }
        let average = sum / Float(frameCount)
        // RMS-ish average is tiny; scale so normal speech reads mid-bar.
        currentLevel = min(average * 12, 1.0)
    }

    func startDisplayUpdates() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    func stopDisplayUpdates() {
        displayTimer?.invalidate()
        displayTimer = nil
        recentLevels = Array(repeating: 0, count: recentLevels.count)
        currentLevel = 0
    }

    private func tick() {
        recentLevels.removeFirst()
        recentLevels.append(currentLevel)
        // Exponential decay so silence reads as silence between buffers.
        currentLevel *= 0.6
    }
}
