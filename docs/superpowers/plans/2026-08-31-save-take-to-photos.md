# 录制视频保存到 iOS 系统相册 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「停止录制 → 视频进入系统相册 → 删除临时文件」这条链路第一次接通，并在顶部 HUD 常驻显示保存结果。

**Architecture:** 新增 `TakeArchiver`（`@Observable` 归档状态机，由 `AppEnvironment` 持有，走 app 生命周期）作为 `RecordingEngine` 的 delegate，通过 `PhotoLibrarySaving` protocol 调用 `PhotoLibraryService`（唯一 `import Photos` 的文件，add-only 权限）。archiver 不 import Photos / UIKit，因此能进 `scripts/test-engines.sh` 那套 macOS 离线 harness。

**Tech Stack:** Swift 5 语言模式 + `-default-isolation MainActor`、SwiftUI、Observation、AVFoundation、Photos、UIKit（仅 background task）。工程用 `PBXFileSystemSynchronizedRootGroup`（objectVersion 77），新增 `.swift` 文件自动进 target，**不需要**改 pbxproj 的 sources 段。

**Spec:** `docs/superpowers/specs/2026-08-31-save-take-to-photos-design.md`

---

## 背景：为什么这不是"补一段 save 代码"

`RecordingEngine.startRecording()` 把 movie 写进 `FileManager.default.temporaryDirectory`，完成后通过 `RecordingEngineDelegate` 回调。但 `SessionManager.init` 接了 `speechService`、`safeWordDetector`、`voiceCommandEngine` 三个 delegate，**唯独没给 `recordingEngine.delegate` 赋值**。完成回调打进空气，`RecordingSession.localVideoURL` 永远是 nil，文件躺在 tmp 里等系统清理。当前每一条录制都是被直接丢掉的。

---

## 文件结构

**新建：**

| 文件 | 职责 |
|---|---|
| `ios/Pollux One/Domain/TakeArchive.swift` | 纯数据：权限枚举、状态枚举、`PhotoLibrarySaving` protocol、HUD 文案映射纯函数。无框架依赖，进 harness。 |
| `ios/Pollux One/Engines/TakeArchiver.swift` | 归档状态机：队列、权限门、成功删文件 / 失败留文件。不 import Photos / UIKit，进 harness。 |
| `ios/Pollux One/Engines/PhotoLibraryService.swift` | 唯一碰 Photos 的文件：add-only 授权 + `performChanges` 写入 + background task 保活。**不进** harness。 |
| `ios/Pollux One/Engines/TakeArchiver+RecordingEngineDelegate.swift` | 单独隔离 delegate conformance——签名会牵出 `RecordingEngine → CameraEngine → ` iOS-only 类型。**不进** harness。 |
| `ios/EngineHarness/ArchiveScenarios.swift` | 离线场景：FakePhotoLibrary + 真实临时文件断言。 |

**修改：**

| 文件 | 改动 |
|---|---|
| `ios/EngineHarness/main.swift` | 去掉 `MainActor.assumeIsolated`，改用 async top-level，挂上 archive suite |
| `scripts/test-engines.sh` | 编译列表加三个源文件 |
| `ios/Pollux One/Domain/SessionModels.swift` | `RecordingSession` 加 `photoLibraryAssetIdentifier`，收窄 `localVideoURL` 语义 |
| `ios/Pollux One/App/AppEnvironment.swift` | 持有 `takeArchiver` |
| `ios/Pollux One/Engines/SessionManager.swift` | 接 delegate、`prepare()` 请求权限、passthrough、写回 RecordingSession |
| `ios/Pollux One/App/RootView.swift` | 往下传 `takeArchiver` |
| `ios/Pollux One/Features/ScriptList/ScriptListView.swift` | 往下传 `takeArchiver` |
| `ios/Pollux One/Features/Recording/RecordingView.swift` | init 收 `takeArchiver`，把文案传给 TopHUD |
| `ios/Pollux One/Features/Recording/RecordingViewModel.swift` | `archiveMessage` computed |
| `ios/Pollux One/Features/Recording/TopHUDView.swift` | 单行 HStack → VStack，加第二行状态 |
| `ios/Pollux One.xcodeproj/project.pbxproj` | 两个 configuration 各加 `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` |

---

## Task 1: Domain 类型与 HUD 文案映射

保存失败是这个功能最坏的结果，而那行文案是用户唯一的知情渠道，所以文案本身要被断言。

**Files:**
- Create: `ios/Pollux One/Domain/TakeArchive.swift`
- Create: `ios/EngineHarness/ArchiveScenarios.swift`
- Modify: `ios/EngineHarness/main.swift`
- Modify: `scripts/test-engines.sh`

- [ ] **Step 1: 写会失败的场景文件**

创建 `ios/EngineHarness/ArchiveScenarios.swift`：

```swift
import Foundation

// Offline exercise of the take → photo library archiving path.
//
// The stakes are asymmetric and invisible here: the library is a take's only
// home and the working file is deleted on success, so a save that fails
// silently is a lost take. These scenarios therefore assert against a real
// file on disk — does it still exist after each outcome — rather than a
// mock's call count, and they pin the exact wording the HUD shows, since that
// line is the only thing that tells a user a take did not make it.

@MainActor
func runArchiveSuite() async -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("Take archiving — recorded video → photo library")

    report.section("HUD wording covers every state the user can land in")

    report.check(TakeArchiveMessage.hudText(state: .idle, permission: .granted) == nil,
                 "nothing is shown before the first take")
    report.check(TakeArchiveMessage.hudText(state: .idle, permission: .notDetermined) == nil,
                 "nothing is shown while the grant is still unanswered")
    report.check(TakeArchiveMessage.hudText(state: .idle, permission: .denied)
                    == "Photos access denied — takes won't be saved.",
                 "a refused grant is stated on arrival, not after a wasted take")
    report.check(TakeArchiveMessage.hudText(state: .idle, permission: .restricted)
                    == "Photos access is restricted — takes won't be saved.",
                 "restricted reads as restricted, not as denied")
    report.check(TakeArchiveMessage.hudText(state: .saving, permission: .granted)
                    == "Saving to Photos…",
                 "saving is visible while it happens")
    report.check(TakeArchiveMessage.hudText(state: .saved(assetIdentifier: "x"), permission: .granted)
                    == "Saved to Photos",
                 "success is confirmed rather than silent")
    report.check(TakeArchiveMessage.hudText(
                    state: .failed(.permissionDenied, retainedFileURL: nil), permission: .denied)
                    == "Photos access denied — this take stayed on the device.",
                 "a failed take says where it ended up")
    report.check(TakeArchiveMessage.hudText(
                    state: .failed(.permissionRestricted, retainedFileURL: nil), permission: .restricted)
                    == "Photos access is restricted — this take stayed on the device.",
                 "restricted failure is distinguishable from a refusal")
    report.check(TakeArchiveMessage.hudText(
                    state: .failed(.saveFailed("disk full"), retainedFileURL: nil), permission: .granted)
                    == "Save failed — disk full",
                 "the underlying reason reaches the user verbatim")

    return (report.pass, report.fail)
}
```

- [ ] **Step 2: 把 suite 挂进 harness 入口**

`ios/EngineHarness/main.swift` 整体替换为：

```swift
import Foundation

// Entry point for the offline engine suites — see scripts/test-engines.sh.
//
// Top-level code here is async (the archiving suite awaits), which also makes
// it MainActor-isolated under -default-isolation MainActor — so the synchronous
// suites are called directly. MainActor.assumeIsolated is unavailable from an
// async context and is a hard error under the Swift 6 language mode.

let alignment = runAlignmentSuite()
let voice = runVoiceSuite()
let camera = runCameraSuite()
let archive = await runArchiveSuite()

let pass = alignment.pass + voice.pass + camera.pass + archive.pass
let fail = alignment.fail + voice.fail + camera.fail + archive.fail
print("\n══════ TOTAL: \(pass) passed, \(fail) failed ══════")
```

`scripts/test-engines.sh` 的 `swiftc` 编译列表里，在 `"$IOS/Domain/VoiceCommand.swift" \` 之后加一行：

```
  "$IOS/Domain/TakeArchive.swift" \
```

在 `"$IOS/Engines/VoiceCommandEngine.swift" \` 之后加一行：

```
  "$IOS/Engines/TakeArchiver.swift" \
```

在 `ios/EngineHarness/CameraScenarios.swift \` 之后加一行：

```
  ios/EngineHarness/ArchiveScenarios.swift \
```

> 注意：`TakeArchiver.swift` 这一行现在指向一个还不存在的文件，Task 1 结束时它已经存在（Task 2 才写内容）——所以 Step 3 的红色状态会同时报"文件不存在"和"找不到 TakeArchiveMessage"。这是预期的。为避免 Task 1 卡在文件缺失上，**Step 4 会同时创建一个最小的 `TakeArchiver.swift` 占位**（只有类型声明，Task 2 填行为）。

- [ ] **Step 3: 运行，确认失败**

```bash
./scripts/test-engines.sh
```

Expected: 非零退出，`swiftc` 报错 —— `error: no such file or directory: 'ios/Pollux One/Domain/TakeArchive.swift'`（以及 `TakeArchiver.swift` 同样的报错）。

- [ ] **Step 4: 写实现**

创建 `ios/Pollux One/Domain/TakeArchive.swift`：

```swift
import Foundation

/// Whether the user has let Pollux One add to their photo library.
///
/// Add-only is all this app ever needs: takes go into the camera roll and
/// nothing here reads or manages what is already there. That keeps the
/// permission prompt to its lightest form and sidesteps "Limited Access"
/// entirely — a limited grant still allows adding.
enum PhotoLibraryAddPermission: Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
}

/// Why a take did not make it into the library.
enum TakeArchiveFailure: Equatable {
    case permissionDenied
    case permissionRestricted
    case saveFailed(String)
}

/// Where the most recent take stands on its way to the photo library.
///
/// `failed` carries the file that was deliberately left on disk rather than
/// deleted, so a future retry has somewhere to start. Nothing retries today.
enum TakeArchiveState: Equatable {
    case idle
    case saving
    case saved(assetIdentifier: String)
    case failed(TakeArchiveFailure, retainedFileURL: URL?)
}

/// Everything the archiver needs from the photo library, as a protocol so the
/// state machine can be exercised offline (see scripts/test-engines.sh)
/// without a library, a device, or a simulator.
@MainActor
protocol PhotoLibrarySaving: AnyObject {
    func currentAddPermission() -> PhotoLibraryAddPermission
    func requestAddPermission() async -> PhotoLibraryAddPermission
    /// Returns the created asset's `localIdentifier` on success.
    func saveVideo(at url: URL) async throws -> String
}

/// Maps archive state onto the single line the top HUD shows.
///
/// A pure function rather than logic on the view, because a take that failed
/// to save is gone — the library is its only home — and this wording is the
/// only thing that tells the user so. It is worth asserting.
enum TakeArchiveMessage {
    static func hudText(
        state: TakeArchiveState,
        permission: PhotoLibraryAddPermission
    ) -> String? {
        switch state {
        case .idle:
            switch permission {
            case .denied:
                return "Photos access denied — takes won't be saved."
            case .restricted:
                return "Photos access is restricted — takes won't be saved."
            case .granted, .notDetermined:
                // Nothing has been recorded yet and nothing is wrong: staying
                // silent keeps the line out of the layout entirely.
                return nil
            }
        case .saving:
            return "Saving to Photos…"
        case .saved:
            return "Saved to Photos"
        case .failed(let failure, _):
            switch failure {
            case .permissionDenied:
                return "Photos access denied — this take stayed on the device."
            case .permissionRestricted:
                return "Photos access is restricted — this take stayed on the device."
            case .saveFailed(let message):
                return "Save failed — \(message)"
            }
        }
    }
}
```

创建占位 `ios/Pollux One/Engines/TakeArchiver.swift`（Task 2 填实现）：

```swift
import Foundation

protocol TakeArchiverDelegate: AnyObject {
    func takeArchiver(_ archiver: TakeArchiver, didUpdate state: TakeArchiveState)
}

/// Owns one job: getting a finished take out of the app's temporary directory
/// and into the user's photo library.
@MainActor
@Observable
final class TakeArchiver {
    private(set) var state: TakeArchiveState = .idle
    private(set) var permission: PhotoLibraryAddPermission = .notDetermined

    weak var delegate: TakeArchiverDelegate?

    private let library: PhotoLibrarySaving

    init(library: PhotoLibrarySaving) {
        self.library = library
        self.permission = library.currentAddPermission()
    }
}
```

- [ ] **Step 5: 运行，确认通过**

```bash
./scripts/test-engines.sh
```

Expected: 退出码 0，输出里出现 `══════ Take archiving — recorded video → photo library ══════` 且 9 条 `✓`，末行 `TOTAL: N passed, 0 failed`（N 比改动前多 9）。

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Domain/TakeArchive.swift" "ios/Pollux One/Engines/TakeArchiver.swift" ios/EngineHarness/ArchiveScenarios.swift ios/EngineHarness/main.swift scripts/test-engines.sh
git commit -m "Add take-archive domain types and assert the HUD wording offline"
```

---

## Task 2: 保存成功——相册接手后删掉工作副本

**Files:**
- Modify: `ios/Pollux One/Engines/TakeArchiver.swift`
- Modify: `ios/EngineHarness/ArchiveScenarios.swift`

- [ ] **Step 1: 写会失败的场景**

在 `ArchiveScenarios.swift` 顶部（`runArchiveSuite` 之前）加入测试替身与工具：

```swift
/// Scriptable stand-in for the real Photos wrapper.
@MainActor
final class FakePhotoLibrary: PhotoLibrarySaving {
    var permission: PhotoLibraryAddPermission
    var permissionAfterRequest: PhotoLibraryAddPermission
    var saveResult: Result<String, Error>

    private(set) var requestCount = 0
    private(set) var savedURLs: [URL] = []

    init(
        permission: PhotoLibraryAddPermission = .granted,
        permissionAfterRequest: PhotoLibraryAddPermission = .granted,
        saveResult: Result<String, Error> = .success("asset-1")
    ) {
        self.permission = permission
        self.permissionAfterRequest = permissionAfterRequest
        self.saveResult = saveResult
    }

    func currentAddPermission() -> PhotoLibraryAddPermission { permission }

    func requestAddPermission() async -> PhotoLibraryAddPermission {
        requestCount += 1
        permission = permissionAfterRequest
        return permission
    }

    func saveVideo(at url: URL) async throws -> String {
        savedURLs.append(url)
        return try saveResult.get()
    }
}

struct FakeSaveError: LocalizedError {
    var errorDescription: String? { "disk full" }
}

/// Records the state sequence the delegate is told about, so ordering is
/// assertable and not just the final value.
@MainActor
final class ArchiveObserver: TakeArchiverDelegate {
    private(set) var states: [TakeArchiveState] = []

    func takeArchiver(_ archiver: TakeArchiver, didUpdate state: TakeArchiveState) {
        states.append(state)
    }
}

/// Writes a real, tiny file so "was it deleted?" is a real question rather
/// than a mock assertion.
@MainActor
func makeTakeFile(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pollux-archive-test-\(name)")
        .appendingPathExtension("mov")
    try? FileManager.default.removeItem(at: url)
    FileManager.default.createFile(atPath: url.path, contents: Data("take".utf8))
    return url
}

@MainActor
func takeFileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}
```

在 `runArchiveSuite` 里，`report.section("HUD wording...")` 那一整段之后、`return` 之前插入：

```swift
    report.section("a saved take leaves no working copy behind")
    do {
        let library = FakePhotoLibrary(saveResult: .success("asset-42"))
        let observer = ArchiveObserver()
        let archiver = TakeArchiver(library: library)
        archiver.delegate = observer
        let url = makeTakeFile("success")

        archiver.archive(takeAt: url)
        await archiver.waitForPendingArchives()

        report.check(archiver.state == .saved(assetIdentifier: "asset-42"),
                     "state carries the identifier the library handed back",
                     detail: "\(archiver.state)")
        report.check(library.savedURLs == [url],
                     "the take was handed over exactly once",
                     detail: "\(library.savedURLs.count) call(s)")
        report.check(!takeFileExists(url),
                     "the temporary file is gone once the library owns the take")
        report.check(observer.states == [.saving, .saved(assetIdentifier: "asset-42")],
                     "the delegate saw saving then saved, in that order",
                     detail: "\(observer.states)")
    }
```

- [ ] **Step 2: 运行，确认失败**

```bash
./scripts/test-engines.sh
```

Expected: 编译失败，`error: value of type 'TakeArchiver' has no member 'archive'` 和 `... has no member 'waitForPendingArchives'`。

- [ ] **Step 3: 写实现**

把 `ios/Pollux One/Engines/TakeArchiver.swift` 整体替换为：

```swift
import Foundation

protocol TakeArchiverDelegate: AnyObject {
    func takeArchiver(_ archiver: TakeArchiver, didUpdate state: TakeArchiveState)
}

/// Owns one job: getting a finished take out of the app's temporary directory
/// and into the user's photo library.
///
/// Lives for the whole app session (AppEnvironment holds it), not for the
/// recording screen. Stopping a take and immediately swiping back to the
/// script list tears that screen down before AVCaptureMovieFileOutput's
/// completion callback arrives — if this object died with the screen, the
/// most ordinary gesture in the app would drop the video on the floor.
@MainActor
@Observable
final class TakeArchiver {
    private(set) var state: TakeArchiveState = .idle
    private(set) var permission: PhotoLibraryAddPermission = .notDetermined

    weak var delegate: TakeArchiverDelegate?

    private let library: PhotoLibrarySaving
    private var queue: [URL] = []
    private var drainTask: Task<Void, Never>?

    init(library: PhotoLibrarySaving) {
        self.library = library
        self.permission = library.currentAddPermission()
    }

    /// Hands one finished take to the library. Takes are archived one at a
    /// time: a second take started while the first is still copying queues
    /// behind it rather than racing it.
    func archive(takeAt url: URL) {
        queue.append(url)
        guard drainTask == nil else { return }
        // Unstructured on purpose: this must outlive whatever screen was on
        // display when the take stopped.
        drainTask = Task { [weak self] in await self?.drain() }
    }

    /// Suspends until every queued take has been dealt with. Nothing in the
    /// app needs this yet; the offline scenarios do, and asking the object
    /// whether it is finished beats sleeping and hoping.
    func waitForPendingArchives() async {
        await drainTask?.value
    }

    private func drain() async {
        while !queue.isEmpty {
            let url = queue.removeFirst()
            await archiveNow(url)
        }
        // Cleared here rather than in the Task body: there is no suspension
        // point between the emptiness check and this line, so a take enqueued
        // concurrently cannot be stranded without a drainer.
        drainTask = nil
    }

    private func archiveNow(_ url: URL) async {
        update(.saving)
        do {
            let identifier = try await library.saveVideo(at: url)
            // The library is the take's only home now, so the working copy goes.
            try? FileManager.default.removeItem(at: url)
            update(.saved(assetIdentifier: identifier))
        } catch {
            // Deliberately keep the file: it is the only copy left.
            update(.failed(.saveFailed(error.localizedDescription), retainedFileURL: url))
        }
    }

    private func update(_ newState: TakeArchiveState) {
        state = newState
        delegate?.takeArchiver(self, didUpdate: newState)
    }
}
```

- [ ] **Step 4: 运行，确认通过**

```bash
./scripts/test-engines.sh
```

Expected: 退出码 0，新增 4 条 `✓`，`0 failed`。

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/Engines/TakeArchiver.swift" ios/EngineHarness/ArchiveScenarios.swift
git commit -m "Archive a finished take into the photo library and drop the working copy"
```

---

## Task 3: 保存失败——文件必须留下

成功路径删文件，所以失败路径**不删**是这个功能唯一的兜底。这条必须有独立断言。

**Files:**
- Modify: `ios/EngineHarness/ArchiveScenarios.swift`

- [ ] **Step 1: 写会失败的场景**

在 `runArchiveSuite` 里，Task 2 那个 `do { }` 块之后插入：

```swift
    report.section("a failed save keeps the only copy that exists")
    do {
        let library = FakePhotoLibrary(saveResult: .failure(FakeSaveError()))
        let observer = ArchiveObserver()
        let archiver = TakeArchiver(library: library)
        archiver.delegate = observer
        let url = makeTakeFile("save-error")

        archiver.archive(takeAt: url)
        await archiver.waitForPendingArchives()

        report.check(archiver.state == .failed(.saveFailed("disk full"), retainedFileURL: url),
                     "the failure names the reason and points at the surviving file",
                     detail: "\(archiver.state)")
        report.check(takeFileExists(url),
                     "the take is NOT deleted when the library refused it")
        report.check(TakeArchiveMessage.hudText(state: archiver.state, permission: .granted)
                        == "Save failed — disk full",
                     "the HUD repeats the library's own reason")

        try? FileManager.default.removeItem(at: url)
    }
```

> 这个 task 没有"先红后绿"：Task 2 的 `archiveNow` catch 分支已经实现了保留行为。
> 它是一个刻意的**回归锁**——删文件的那行和保留文件的那行只隔几行，是最容易被一起
> 改坏的地方，而改坏的后果（用户丢素材）在真机上要等到失败才发现。断言存在本身就是
> 这个 task 的产出。

- [ ] **Step 2: 运行，确认三条断言都通过**

```bash
./scripts/test-engines.sh
```

Expected: 退出码 0，新增 3 条 `✓`。

若 `the take is NOT deleted when the library refused it` 这条是 `✗`，说明
`TakeArchiver.archiveNow` 的 `removeItem` 跑到了 `catch` 之外或之前——把它移回
`do` 块里 `library.saveVideo` 成功返回之后。

若 `the failure names the reason and points at the surviving file` 是 `✗`，
对比 `detail:` 打印出的实际 state：`retainedFileURL` 为 nil 说明 catch 分支漏传了 `url`。

- [ ] **Step 3: 提交**

```bash
git add ios/EngineHarness/ArchiveScenarios.swift
git commit -m "Pin that a failed save keeps the take instead of deleting it"
```

---

## Task 4: 权限门——拒绝时不碰相册，也不删文件

**Files:**
- Modify: `ios/Pollux One/Engines/TakeArchiver.swift`
- Modify: `ios/EngineHarness/ArchiveScenarios.swift`

- [ ] **Step 1: 写会失败的场景**

在 `runArchiveSuite` 里，Task 3 的块之后插入：

```swift
    report.section("a refused library is a dead end, not a deleted take")
    do {
        let library = FakePhotoLibrary(permission: .denied, permissionAfterRequest: .denied)
        let archiver = TakeArchiver(library: library)
        let url = makeTakeFile("denied")

        archiver.archive(takeAt: url)
        await archiver.waitForPendingArchives()

        report.check(archiver.state == .failed(.permissionDenied, retainedFileURL: url),
                     "a denied grant is reported as denied, not as a save error",
                     detail: "\(archiver.state)")
        report.check(library.savedURLs.isEmpty,
                     "the library is never called when the answer is already no")
        report.check(library.requestCount == 0,
                     "an already-answered grant is not asked again")
        report.check(takeFileExists(url),
                     "the take survives a refused grant")

        try? FileManager.default.removeItem(at: url)
    }

    report.section("a restricted library reads differently from a refused one")
    do {
        let library = FakePhotoLibrary(permission: .restricted, permissionAfterRequest: .restricted)
        let archiver = TakeArchiver(library: library)
        let url = makeTakeFile("restricted")

        archiver.archive(takeAt: url)
        await archiver.waitForPendingArchives()

        report.check(archiver.state == .failed(.permissionRestricted, retainedFileURL: url),
                     "restricted is its own outcome — the user cannot fix it in Settings",
                     detail: "\(archiver.state)")
        report.check(takeFileExists(url), "the take survives a restricted library")

        try? FileManager.default.removeItem(at: url)
    }

    report.section("an unanswered grant is asked for exactly once")
    do {
        let library = FakePhotoLibrary(permission: .notDetermined, permissionAfterRequest: .granted)
        let archiver = TakeArchiver(library: library)
        let first = makeTakeFile("undetermined-1")
        let second = makeTakeFile("undetermined-2")

        archiver.archive(takeAt: first)
        archiver.archive(takeAt: second)
        await archiver.waitForPendingArchives()

        report.check(library.requestCount == 1,
                     "the second take reuses the answer rather than re-prompting",
                     detail: "\(library.requestCount) request(s)")
        report.check(archiver.permission == .granted,
                     "the archiver remembers what it was told")
        report.check(library.savedURLs == [first, second],
                     "both takes were saved once the grant arrived")
    }

    report.section("prepare() asks up front so a refusal costs no take")
    do {
        let library = FakePhotoLibrary(permission: .notDetermined, permissionAfterRequest: .denied)
        let archiver = TakeArchiver(library: library)

        await archiver.refreshPermission()

        report.check(library.requestCount == 1, "refreshPermission asks once")
        report.check(archiver.permission == .denied, "and records the answer")
        report.check(TakeArchiveMessage.hudText(state: .idle, permission: archiver.permission)
                        == "Photos access denied — takes won't be saved.",
                     "so the HUD can warn before anything is recorded")

        await archiver.refreshPermission()
        report.check(library.requestCount == 1,
                     "an already-answered grant is not re-prompted on the next screen",
                     detail: "\(library.requestCount) request(s)")
    }
```

- [ ] **Step 2: 运行，确认失败**

```bash
./scripts/test-engines.sh
```

Expected: 编译失败，`error: value of type 'TakeArchiver' has no member 'refreshPermission'`。

- [ ] **Step 3: 写实现**

在 `ios/Pollux One/Engines/TakeArchiver.swift` 里，`waitForPendingArchives()` 之后加入：

```swift
    /// Called from SessionManager.prepare(), alongside the camera and speech
    /// grants, so a user who says no finds out on arrival rather than after
    /// burning a take.
    func refreshPermission() async {
        permission = library.currentAddPermission()
        guard permission == .notDetermined else { return }
        permission = await library.requestAddPermission()
    }
```

并把 `archiveNow(_:)` 替换为（在写入之前加权限门）：

```swift
    private func archiveNow(_ url: URL) async {
        if permission == .notDetermined {
            permission = await library.requestAddPermission()
        }

        switch permission {
        case .denied:
            update(.failed(.permissionDenied, retainedFileURL: url))
            return
        case .restricted:
            update(.failed(.permissionRestricted, retainedFileURL: url))
            return
        case .granted:
            break
        case .notDetermined:
            // The system never leaves a request unanswered; if it somehow did,
            // attempting the write is better than silently discarding a take.
            break
        }

        update(.saving)
        do {
            let identifier = try await library.saveVideo(at: url)
            // The library is the take's only home now, so the working copy goes.
            try? FileManager.default.removeItem(at: url)
            update(.saved(assetIdentifier: identifier))
        } catch {
            // Deliberately keep the file: it is the only copy left.
            update(.failed(.saveFailed(error.localizedDescription), retainedFileURL: url))
        }
    }
```

- [ ] **Step 4: 运行，确认通过**

```bash
./scripts/test-engines.sh
```

Expected: 退出码 0，新增 13 条 `✓`。

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/Engines/TakeArchiver.swift" ios/EngineHarness/ArchiveScenarios.swift
git commit -m "Gate archiving on the add-only grant and ask for it exactly once"
```

---

## Task 5: 连拍串行——第二条排队而不是抢跑

**Files:**
- Modify: `ios/EngineHarness/ArchiveScenarios.swift`

- [ ] **Step 1: 写会失败的场景**

在 `runArchiveSuite` 里，Task 4 最后一个块之后插入：

```swift
    report.section("back-to-back takes are archived one at a time")
    do {
        let library = FakePhotoLibrary(saveResult: .success("asset-seq"))
        let observer = ArchiveObserver()
        let archiver = TakeArchiver(library: library)
        archiver.delegate = observer
        let first = makeTakeFile("serial-1")
        let second = makeTakeFile("serial-2")

        archiver.archive(takeAt: first)
        archiver.archive(takeAt: second)
        await archiver.waitForPendingArchives()

        report.check(library.savedURLs == [first, second],
                     "handed over in the order they were recorded",
                     detail: "\(library.savedURLs.map(\.lastPathComponent))")
        report.check(!takeFileExists(first) && !takeFileExists(second),
                     "both working copies are gone")
        report.check(observer.states == [
                        .saving, .saved(assetIdentifier: "asset-seq"),
                        .saving, .saved(assetIdentifier: "asset-seq")
                     ],
                     "the second take starts only after the first reports saved",
                     detail: "\(observer.states)")
        report.check(archiver.state == .saved(assetIdentifier: "asset-seq"),
                     "the HUD ends up describing the most recent take")
    }
```

- [ ] **Step 2: 运行**

```bash
./scripts/test-engines.sh
```

Expected: 退出码 0，新增 4 条 `✓`。Task 2 的 `drainTask` 队列实现已经保证串行；这里是把它钉住。若 `observer.states` 出现 `.saving, .saving` 交错，说明 `drain()` 的 `drainTask = nil` 被挪出了 `drain` 本体，回去按 Task 2 Step 3 的注释修。

- [ ] **Step 3: 提交**

```bash
git add ios/EngineHarness/ArchiveScenarios.swift
git commit -m "Pin that concurrent takes queue rather than race into the library"
```

---

## Task 6: 真实的 Photos 封装

无 harness 覆盖（`import Photos` / `UIKit` 编不进 macOS 离线套件），靠编译 + Task 11 的设备验证。

**Files:**
- Create: `ios/Pollux One/Engines/PhotoLibraryService.swift`

- [ ] **Step 1: 写实现**

```swift
import Photos
import UIKit

/// The only file in the app that talks to Photos.
///
/// Add-only authorization on purpose: Pollux One writes takes and never reads
/// the library, so this is both the lightest prompt the system offers and the
/// one that a "Limited Access" choice cannot degrade.
@MainActor
final class PhotoLibraryService: PhotoLibrarySaving {
    func currentAddPermission() -> PhotoLibraryAddPermission {
        Self.permission(for: PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestAddPermission() async -> PhotoLibraryAddPermission {
        let status: PHAuthorizationStatus = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        return Self.permission(for: status)
    }

    func saveVideo(at url: URL) async throws -> String {
        // A 4K take is a large copy. Without this, stopping the recording and
        // immediately backgrounding the app can have the write killed
        // mid-flight — and since the library is the take's only home, that is
        // a lost take rather than a retryable one.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SaveTakeToPhotos")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        // performChanges runs its block off the main actor, so the identifier
        // comes back through a reference rather than a captured local.
        let box = CreatedAssetIdentifier()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            box.value = request?.placeholderForCreatedAsset?.localIdentifier
        }

        guard let identifier = box.value else {
            throw PhotoLibraryServiceError.assetIdentifierMissing
        }
        return identifier
    }

    private static func permission(for status: PHAuthorizationStatus) -> PhotoLibraryAddPermission {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        // A limited grant still permits adding, which is all this app asks for.
        case .authorized, .limited: return .granted
        @unknown default: return .denied
        }
    }
}

/// Carries the new asset's identifier back out of the change block.
private final class CreatedAssetIdentifier: @unchecked Sendable {
    var value: String?
}

enum PhotoLibraryServiceError: LocalizedError {
    case assetIdentifierMissing

    var errorDescription: String? {
        switch self {
        case .assetIdentifierMissing:
            return "the photo library accepted the video but returned no asset"
        }
    }
}
```

- [ ] **Step 2: 确认离线套件没被这个文件影响**

```bash
./scripts/test-engines.sh
```

Expected: 退出码 0，通过数与 Task 5 结束时相同（这个文件不在编译列表里）。

- [ ] **Step 3: 提交**

```bash
git add "ios/Pollux One/Engines/PhotoLibraryService.swift"
git commit -m "Add the add-only Photos wrapper, kept behind a background task assertion"
```

---

## Task 7: 接上 RecordingEngine 的完成回调

**Files:**
- Create: `ios/Pollux One/Engines/TakeArchiver+RecordingEngineDelegate.swift`
- Modify: `ios/Pollux One/Engines/TakeArchiver.swift`

- [ ] **Step 1: 给 archiver 加"录制本身失败"的入口**

在 `ios/Pollux One/Engines/TakeArchiver.swift` 的 `refreshPermission()` 之后加入：

```swift
    /// Recording itself failed, so there is no file to archive and nothing
    /// left on disk worth preserving.
    func recordingFailed(_ message: String) {
        update(.failed(.saveFailed(message), retainedFileURL: nil))
    }
```

- [ ] **Step 2: 写 conformance 文件**

创建 `ios/Pollux One/Engines/TakeArchiver+RecordingEngineDelegate.swift`：

```swift
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
```

- [ ] **Step 3: 确认离线套件仍然通过**

```bash
./scripts/test-engines.sh
```

Expected: 退出码 0，通过数不变。

- [ ] **Step 4: 提交**

```bash
git add "ios/Pollux One/Engines/TakeArchiver.swift" "ios/Pollux One/Engines/TakeArchiver+RecordingEngineDelegate.swift"
git commit -m "Make TakeArchiver the recording engine's delegate"
```

---

## Task 8: RecordingSession 记录去向

**Files:**
- Modify: `ios/Pollux One/Domain/SessionModels.swift`

- [ ] **Step 1: 改模型**

把 `SessionModels.swift` 里的 `RecordingSession` 替换为：

```swift
/// One continuous "camera rolling" take. Distinct from ReadingSession because
/// a user may pause the teleprompter without stopping the recording.
struct RecordingSession: Identifiable, Codable, Equatable {
    let id: UUID
    let scriptRevisionId: UUID
    var startedAt: Date
    var endedAt: Date?
    var cameraConfiguration: CameraConfiguration
    /// Set only when archiving failed: the file deliberately left on disk. A
    /// take that reached the photo library has no local file — the library
    /// owns it and the working copy is deleted.
    var localVideoURL: URL?
    /// The take's PHAsset `localIdentifier` once it is in the photo library —
    /// the only durable handle to where a take actually went.
    var photoLibraryAssetIdentifier: String?

    var isActive: Bool { endedAt == nil }
}
```

- [ ] **Step 2: 运行离线套件**

`SessionModels.swift` 在 harness 的编译列表里，所以这是一次真实的编译检查。

```bash
./scripts/test-engines.sh
```

Expected: 退出码 0。若报 `missing argument for parameter 'photoLibraryAssetIdentifier'`，说明有构造点没更新——`SessionManager.startTake()` 是唯一一处，下一个 task 会改到它；此处若已报错，先在 `startTake()` 的 `RecordingSession(...)` 里补 `photoLibraryAssetIdentifier: nil`。

- [ ] **Step 3: 提交**

```bash
git add "ios/Pollux One/Domain/SessionModels.swift"
git commit -m "Record where a take ended up, not just that it was recorded"
```

---

## Task 9: 接线——AppEnvironment 持有，SessionManager 接 delegate

这一步堵住 spec §3.2 那条数据丢失路径：停止后立刻返回，`SessionManager` 随 `@State` 释放，而 movie 完成回调几百毫秒后才到。

**Files:**
- Modify: `ios/Pollux One/App/AppEnvironment.swift`
- Modify: `ios/Pollux One/Engines/SessionManager.swift`

- [ ] **Step 1: AppEnvironment 持有 archiver**

`AppEnvironment.swift` 里，在 `let syncService: ScriptSyncService` 之后加一行属性，并在 `init` 里构造：

```swift
    let syncService: ScriptSyncService
    /// App-lifetime on purpose: a take that finishes writing after the
    /// recording screen is gone still has to reach the photo library.
    let takeArchiver: TakeArchiver
    var currentUser: User?

    init(backend: BackendClient) {
        self.backend = backend
        self.syncService = ScriptSyncService(backend: backend)
        self.takeArchiver = TakeArchiver(library: PhotoLibraryService())
    }
```

- [ ] **Step 2: SessionManager 收下并接线**

`SessionManager.swift` 里：

把 `private let syncService: ScriptSyncService` 之后加一行：

```swift
    private let takeArchiver: TakeArchiver
```

把 `init` 替换为：

```swift
    init(syncService: ScriptSyncService, alignmentEngine: ScriptAlignmentEngine, takeArchiver: TakeArchiver) {
        self.syncService = syncService
        self.alignmentEngine = alignmentEngine
        self.takeArchiver = takeArchiver
        let camera = CameraEngine()
        self.cameraEngine = camera
        self.recordingEngine = RecordingEngine(cameraEngine: camera)

        speechService.delegate = self
        safeWordDetector.delegate = self
        voiceCommandEngine.delegate = self
        // The archiver outlives this screen; this object does not. That is
        // exactly the right way round — a take stopped just before the user
        // swipes back still gets saved, it just has nobody left to report the
        // asset identifier to.
        recordingEngine.delegate = takeArchiver
        takeArchiver.delegate = self
    }
```

在 `speechError` 属性之后加两个 passthrough：

```swift
    /// Read by the HUD. @Observable propagates through the passthrough.
    var takeArchiveState: TakeArchiveState { takeArchiver.state }
    var photoLibraryPermission: PhotoLibraryAddPermission { takeArchiver.permission }
```

在 `prepare(script:)` 末尾、`speechError` 那段之后加：

```swift
        // Asked here rather than at the first save: a refusal discovered after
        // a take is recorded costs the user that take.
        await takeArchiver.refreshPermission()
```

`startTake()` 里构造 `RecordingSession` 的地方补上新字段：

```swift
        let recordingSession = RecordingSession(
            id: UUID(),
            scriptRevisionId: revision.id,
            startedAt: Date(),
            endedAt: nil,
            cameraConfiguration: cameraEngine.configuration,
            localVideoURL: nil,
            photoLibraryAssetIdentifier: nil
        )
```

在文件末尾加 conformance：

```swift
extension SessionManager: TakeArchiverDelegate {
    func takeArchiver(_ archiver: TakeArchiver, didUpdate state: TakeArchiveState) {
        switch state {
        case .saved(let identifier):
            currentRecordingSession?.photoLibraryAssetIdentifier = identifier
            // The working copy is gone; only the library handle is real now.
            currentRecordingSession?.localVideoURL = nil
        case .failed(_, let retainedFileURL):
            currentRecordingSession?.localVideoURL = retainedFileURL
        case .idle, .saving:
            break
        }
    }
}
```

- [ ] **Step 3: 运行离线套件**

```bash
./scripts/test-engines.sh
```

Expected: 退出码 0，通过数不变（`SessionManager.swift` 不在编译列表里，这一步只确认没碰坏 Domain）。

- [ ] **Step 4: 提交**

```bash
git add "ios/Pollux One/App/AppEnvironment.swift" "ios/Pollux One/Engines/SessionManager.swift"
git commit -m "Wire the recording engine's completion callback to an app-lifetime archiver"
```

---

## Task 10: 权限文案进 Info.plist

没有这条 key，`requestAuthorization` 会直接让 app crash。

**Files:**
- Modify: `ios/Pollux One.xcodeproj/project.pbxproj`

- [ ] **Step 1: 两个 configuration 各插一行**

```bash
python3 - <<'EOF'
import pathlib
p = pathlib.Path("ios/Pollux One.xcodeproj/project.pbxproj")
s = p.read_text()
needle = '\t\t\t\tINFOPLIST_KEY_NSMicrophoneUsageDescription = "Pollux One uses the microphone to record your video\'s audio and to follow along as you read.";\n'
added = needle + '\t\t\t\tINFOPLIST_KEY_NSPhotoLibraryAddUsageDescription = "Pollux One saves the takes you record to your photo library.";\n'
assert s.count(needle) == 2, f"expected 2 configurations, found {s.count(needle)}"
p.write_text(s.replace(needle, added))
print("patched both configurations")
EOF
```

Expected: 打印 `patched both configurations`。

- [ ] **Step 2: 验证**

```bash
grep -c "INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription" "ios/Pollux One.xcodeproj/project.pbxproj"
```

Expected: `2`

- [ ] **Step 3: 提交**

```bash
git add "ios/Pollux One.xcodeproj/project.pbxproj"
git commit -m "Declare the add-only photo library usage description"
```

---

## Task 11: HUD 第二行 + 视图接线

**Files:**
- Modify: `ios/Pollux One/Features/Recording/TopHUDView.swift`
- Modify: `ios/Pollux One/Features/Recording/RecordingViewModel.swift`
- Modify: `ios/Pollux One/Features/Recording/RecordingView.swift`
- Modify: `ios/Pollux One/Features/ScriptList/ScriptListView.swift`
- Modify: `ios/Pollux One/App/RootView.swift`

- [ ] **Step 1: TopHUDView 加第二行**

把 `TopHUDView` 的属性和 `body` 替换为（`elapsedFormatter` / `remainingFormatter` 两个静态方法保持原样不动）：

```swift
struct TopHUDView: View {
    let isRecording: Bool
    let elapsedSeconds: TimeInterval
    let remainingRecordingTime: TimeInterval?
    /// nil when there is nothing to say — see TakeArchiveMessage.hudText.
    let archiveMessage: String?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                HStack(spacing: 7) {
                    Circle()
                        .fill(HUDColor.recRed)
                        .frame(width: 7, height: 7)
                    Text("REC")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                    Text(Self.elapsedFormatter(elapsedSeconds))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                }

                Spacer()

                HStack(spacing: 5) {
                    Text("LEFT")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(remainingRecordingTime.map { Self.remainingFormatter($0) } ?? "—")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                }
            }

            // `if let` rather than opacity: with only 44pt between this row
            // and the teleprompter at top:60, a zero-opacity line would still
            // push the prompter down.
            if let archiveMessage {
                Text(archiveMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }
```

> **执行阶段作废：Step 1 的顶部方案实测不成立，见下方「Task 11 实测修正」。**
> `TopHUDView` 保持原样不动，状态行改放底部簇。

- [ ] **Step 2: RecordingViewModel 暴露文案**

在 `RecordingViewModel` 的 `remainingRecordingTime` 之后加：

```swift
    /// The single line the top HUD shows about where the last take went.
    var archiveMessage: String? {
        TakeArchiveMessage.hudText(
            state: sessionManager.takeArchiveState,
            permission: sessionManager.photoLibraryPermission
        )
    }
```

- [ ] **Step 3: RecordingView 接住 archiver 并传文案**

`RecordingView` 的 `init` 替换为：

```swift
    init(script: Script, syncService: ScriptSyncService, takeArchiver: TakeArchiver) {
        self.script = script
        let sessionManager = SessionManager(
            syncService: syncService,
            alignmentEngine: SlidingWindowAlignmentEngine(),
            takeArchiver: takeArchiver
        )
        _viewModel = State(initialValue: RecordingViewModel(sessionManager: sessionManager))
    }
```

`topGroup` 里的 `TopHUDView(...)` 调用加一个参数：

```swift
            TopHUDView(
                isRecording: viewModel.sessionManager.recordingEngine.isRecording,
                elapsedSeconds: viewModel.sessionManager.recordingEngine.elapsedSeconds,
                remainingRecordingTime: viewModel.remainingRecordingTime,
                archiveMessage: viewModel.archiveMessage
            )
            .padding(.horizontal, 18)
            .topAnchored(Offset.statusRowTop)
```

- [ ] **Step 4: 把 archiver 从 RootView 串下来**

`RootView.swift`：

```swift
                ScriptListView(
                    syncService: environment.syncService,
                    takeArchiver: environment.takeArchiver
                )
```

`ScriptListView.swift` 的属性与 init：

```swift
    @State private var viewModel: ScriptListViewModel
    private let syncService: ScriptSyncService
    private let takeArchiver: TakeArchiver

    init(syncService: ScriptSyncService, takeArchiver: TakeArchiver) {
        self.syncService = syncService
        self.takeArchiver = takeArchiver
        _viewModel = State(wrappedValue: ScriptListViewModel(syncService: syncService))
    }
```

以及 `NavigationLink` 里的调用：

```swift
                            RecordingView(
                                script: script,
                                syncService: syncService,
                                takeArchiver: takeArchiver
                            )
```

- [ ] **Step 5: 整体编译**

```bash
xcodebuild -project "ios/Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -30
```

Expected: 末尾出现 `** BUILD SUCCEEDED **`。若报签名相关错误而非编译错误，改用 simulator destination：

```bash
xcodebuild -project "ios/Pollux One.xcodeproj" -scheme "Pollux One" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build 2>&1 | tail -30
```

- [ ] **Step 6: 离线套件仍然通过**

```bash
./scripts/test-engines.sh
```

Expected: 退出码 0，`0 failed`。

- [ ] **Step 7: 提交**

```bash
git add "ios/Pollux One/Features/Recording/TopHUDView.swift" "ios/Pollux One/Features/Recording/RecordingViewModel.swift" "ios/Pollux One/Features/Recording/RecordingView.swift" "ios/Pollux One/Features/ScriptList/ScriptListView.swift" "ios/Pollux One/App/RootView.swift"
git commit -m "Show where the last take went on the recording HUD"
```

### Task 11 实测修正

顶部方案在模拟器上连撞两次，已作废：

1. 第二行盖住 `top: 60` 的提词器。两者是 ZStack 里各自绝对定位的兄弟节点，提词器
   不会被推下去——计划里「`if let` 避免顶下提词器」的推理假设了流式布局，是错的。
2. 去掉重复 padding 把 REC 行还原到规范的 16pt 后，第二行落在 ~43pt 正中灵动岛，
   截图里中段整体不可见。REC 行本就是设计成分列灵动岛两侧的。

**已实现的替代方案：** 状态行移到底部簇，新增
`RecordingView.Offset.archiveStatusBottom = 245`（参数行 162 之上、底部渐变 270 之内），
`TopHUDView` 完整还原为原来的单行 `HStack`。已在模拟器验证：拒绝态文案完整可读、
不与任何元素相撞；授权态该行完全不参与布局，其余控件位置零位移。

---

## Task 12: 设备验证

离线套件覆盖状态机，但 add-only 授权弹窗、`performChanges` 的真实行为、background task 保活都只有真机能证。**这一步必须在真机上做，模拟器的相册行为与真机不同（且模拟器没有相机）。**

**Files:** 无（纯验证）

- [ ] **Step 1: 装到真机并走一遍首次授权**

删掉设备上已装的 app（重置权限状态），重新安装运行，进入任意脚本的录制页。

Expected:
- 依次弹出相机、麦克风/语音、**相册"添加照片"**三个授权弹窗
- 相册弹窗文案是 `Pollux One saves the takes you record to your photo library.`
- 全部允许后，HUD 第二行**不显示**任何内容

- [ ] **Step 2: 录一条并确认落地**

按下快门录 5 秒，再按停止。

Expected:
- HUD 第二行短暂出现 `Saving to Photos…`，随后变为 `Saved to Photos`
- 打开系统「照片」app，最近项目里出现这条视频，时长与画幅正确、有声音

- [ ] **Step 3: 验证那条曾经会丢件的路径**

再录一条，**按下停止后立刻**（1 秒内）从屏幕左缘右划返回脚本列表。

Expected: 系统「照片」里仍然多出这条视频。这是 `TakeArchiver` 挂在 `AppEnvironment` 而不是 `SessionManager` 的全部理由——若这条丢了，说明接线退回了 per-screen 所有权。

- [ ] **Step 4: 验证后台保活**

再录一条，按下停止后立刻按 Home 键回桌面，等 10 秒再回到 app。

Expected: 视频仍在相册里。

- [ ] **Step 5: 验证拒绝路径**

系统「设置 → Pollux One → 照片」改为「无」，回到 app 的录制页。

Expected:
- HUD 第二行显示 `Photos access denied — takes won't be saved.`
- 录一条并停止后，第二行变为 `Photos access denied — this take stayed on the device.`
- app 不崩溃

改回「添加照片」后重进录制页，第二行恢复空白。

- [ ] **Step 6: 提交验证记录**

在本文件的 Task 12 下把每个 Step 的实际结果补成一行备注，然后：

```bash
git add docs/superpowers/plans/2026-08-31-save-take-to-photos.md
git commit -m "Record on-device verification of the photo library save path"
```

---

## 自查：spec 覆盖对照

| Spec 章节 | 由哪个 task 实现 |
|---|---|
| §3.1 `TakeArchive.swift` 类型与文案 | Task 1 |
| §3.1 `TakeArchiver` 队列 / 删文件 / 保留文件 | Task 2、3、5 |
| §3.1 `TakeArchiver` 权限门 | Task 4 |
| §3.1 `PhotoLibraryService` + background task | Task 6 |
| §3.1 delegate conformance 隔离文件 | Task 7 |
| §3.2 AppEnvironment 所有权 / 生命周期 | Task 9，真机验证在 Task 12 Step 3 |
| §4 `RecordingSession` 字段 | Task 8、Task 9（写回） |
| §5 权限时机 + Info.plist | Task 9 Step 2、Task 10 |
| §6 TopHUDView 第二行 | Task 11 |
| §7 离线 harness 六类场景 | Task 1–5 |

**与 spec 的一处细化：** spec §3.1 的文案表把 `.idle` 下的 denied 与 restricted 合并成一条 `Photos access denied`。实现里拆成两条独立文案，因为 restricted（受设备管理策略限制）用户在设置里改不动，而 denied 改得动——告诉用户去设置里打开一个改不了的开关是误导。失败态本来就区分这两者，`.idle` 态跟着区分才一致。
