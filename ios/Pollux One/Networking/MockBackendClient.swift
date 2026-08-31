import Foundation

/// In-memory BackendClient so the app is runnable with zero configuration
/// before Supabase project keys exist. Swap for SupabaseBackendClient once
/// `ios/Pollux One/Networking/SupabaseBackendClient.swift` (see its header
/// comment) is wired up — call sites don't change because both conform to
/// BackendClient.
final class MockBackendClient: BackendClient {
    private var user: User?
    private var scripts: [UUID: Script]

    init(startSignedIn: Bool = true) {
        // One EN + one 中文 script, so the teleprompter's CJK typography
        // (larger glyphs, looser line height, 。sentence splitting) is
        // exercised on every run rather than only in review.
        self.scripts = Dictionary(
            uniqueKeysWithValues: MockBackendClient.sampleScripts().map { ($0.id, $0) }
        )
        // The mock exists so the app runs with no backend configured, which
        // includes skipping a login that can't fail. Pass false to exercise
        // the real sign-in screen against it.
        if startSignedIn {
            self.user = User(id: UUID(), email: "demo@pollux.one", displayName: "Demo")
        }
    }

    func signIn(email: String, password: String) async throws -> User {
        let user = User(id: UUID(), email: email, displayName: email.components(separatedBy: "@").first)
        self.user = user
        return user
    }

    func currentUser() async -> User? { user }

    func signOut() async { user = nil }

    func fetchScripts() async throws -> [Script] {
        Array(scripts.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    func fetchScript(id: UUID) async throws -> Script {
        guard let script = scripts[id] else { throw BackendError.notFound }
        return script
    }

    func updateParagraph(scriptId: UUID, paragraphId: UUID, newText: String) async throws -> Script {
        guard var script = scripts[scriptId] else { throw BackendError.notFound }
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
        script.version += 1
        script.updatedAt = Date()
        scripts[scriptId] = script
        return script
    }

    func reportReadingProgress(scriptId: UUID, progress: ReadingProgress) async throws {
        // V1: no-op. A real backend would persist this for the Web console's
        // "last read X%" indicator.
    }

    private static func sampleScripts() -> [Script] {
        [
            script(
                title: "Why Pollux One exists",
                paragraphs: [
                    "Most teleprompters solve the wrong problem. They make the words easy to read, but they pull your eyes away from the lens. The moment your eyes leave the camera, the audience feels it, even if they cannot say why.",
                    "Pollux One starts from a different question. What is the shortest possible distance between your eyes, the words, and the lens? Everything in this app follows from that one constraint.",
                    "So the script sits right next to the camera, and it moves with you instead of against you. You do not chase a fixed scroll speed. You read at your own pace, you repeat a line if you need to, and the words wait for you."
                ]
            ),
            script(
                title: "为什么会有 Pollux One",
                paragraphs: [
                    "大多数提词器都在解决错误的问题。它们让字变得容易读，却把你的眼神从镜头上拉走了。你的目光一离开镜头，观众立刻就能感觉到，哪怕他们说不出为什么。",
                    "Pollux One 从另一个问题出发。你的眼睛、文字和镜头之间，最短的距离是多少？这个 App 里的每一个决定，都是从这一个约束推导出来的。",
                    "所以提词内容就放在镜头旁边，而且它跟着你走，不跟你对着来。你不用去追一个固定的滚动速度。你按自己的节奏念，需要就重复一句，文字会等你。"
                ]
            )
        ]
    }

    private static func script(title: String, paragraphs: [String]) -> Script {
        let builtParagraphs = paragraphs.enumerated().map { index, text in
            Paragraph(id: UUID(), order: index, sentences: SentenceSplitter.sentences(from: text))
        }
        return Script(
            id: UUID(),
            title: title,
            version: 1,
            sections: [ScriptSection(id: UUID(), title: nil, order: 0, paragraphs: builtParagraphs)],
            updatedAt: Date(),
            createdAt: Date()
        )
    }

}
