import Foundation

/// One line of teleprompter text with the visual weight it should render at.
/// Deliberately has no font size — per the product spec, current/past/future
/// lines are the same size and differ only by emphasis, so the reader can
/// see context around the current line without a size jump.
struct TeleprompterLine: Identifiable, Equatable {
    enum Emphasis: Equatable {
        case past       // low opacity
        case current    // full opacity + highlight background
        case upcoming   // slightly reduced opacity
    }

    let id: UUID
    let text: String
    let emphasis: Emphasis
}

struct TeleprompterDisplayState: Equatable {
    var lines: [TeleprompterLine]
    var progress: ReadingProgress
    var isVisible: Bool = true
}

/// Converts ReadingPosition -> what the overlay shows. This is the only
/// place that knows "2 lines of context before, 2 after" — a UI decision —
/// so RecordingView stays a dumb renderer of TeleprompterDisplayState.
@MainActor
@Observable
final class TeleprompterEngine {
    private(set) var displayState = TeleprompterDisplayState(lines: [], progress: .zero)

    private let contextLinesBefore = 1
    private let contextLinesAfter = 2
    private var script: Script?

    func load(script: Script) {
        self.script = script
        if let start = ReadingPosition.start(for: script) {
            update(position: start)
        }
    }

    func update(position: ReadingPosition) {
        guard let script else { return }
        let flat = script.allSentences
        guard let currentIndex = flat.firstIndex(where: { $0.id == position.address.sentenceId }) else { return }

        let startIndex = max(0, currentIndex - contextLinesBefore)
        let endIndex = min(flat.count - 1, currentIndex + contextLinesAfter)

        var lines: [TeleprompterLine] = []
        for index in startIndex...endIndex {
            let emphasis: TeleprompterLine.Emphasis
            if index < currentIndex { emphasis = .past }
            else if index == currentIndex { emphasis = .current }
            else { emphasis = .upcoming }
            lines.append(TeleprompterLine(id: flat[index].id, text: flat[index].text, emphasis: emphasis))
        }

        let progress = ReadingProgress(
            completedSentences: currentIndex,
            totalSentences: flat.count,
            fractionComplete: flat.isEmpty ? 0 : Double(currentIndex) / Double(flat.count)
        )

        displayState = TeleprompterDisplayState(lines: lines, progress: progress, isVisible: displayState.isVisible)
    }

    func setVisible(_ visible: Bool) {
        displayState.isVisible = visible
    }
}
