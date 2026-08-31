# 将录制的视频保存到 iOS 系统相册 — 设计

日期：2026-08-31
状态：已确认，待实现

## 1 · 问题

今天这个功能不存在，而且比"没做"更糟：**录完的视频是被直接丢掉的。**

`RecordingEngine.startRecording()` 把 movie 写进 `FileManager.default.temporaryDirectory`，
完成后通过 `RecordingEngineDelegate.recordingEngine(_:didFinishRecordingTo:)` 回调。
但 `SessionManager` 在 `init` 里接了 `speechService`、`safeWordDetector`、
`voiceCommandEngine` 三个 delegate，**唯独没有给 `recordingEngine.delegate` 赋值**。
于是完成回调打进空气，`RecordingSession.localVideoURL` 永远是 nil，文件躺在 tmp 里
等系统清理。

同时工程里完全没有引用 Photos 框架，pbxproj 的 `INFOPLIST_KEY_*` 只有 camera /
microphone / speech 三条，没有任何 photo library 的 usage description。

所以这不是"补一段 save 代码"，而是第一次把「拍完 → 落盘 → 入库」这条链路接通。

## 2 · 已确认的产品决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 存储位置 | 系统相机胶卷，**add-only 权限** | 只申请 `NSPhotoLibraryAddUsageDescription`，弹窗最轻，用户几乎不会拒；且不受"仅选中照片"受限访问影响。代价是不能建自定义相簿。 |
| 触发方式 | 停止录制后**自动**保存 | 不加确认步骤 |
| 文件归属 | **相册为唯一归属**，成功后删 tmp | 不占沙盒。失败时保留 tmp 并提示 |
| 结果反馈 | 顶部 HUD **常驻一行**状态 | shutter row 两侧 52pt 已被安全词表和翻转占满，放不下缩略图 |
| 权限时机 | 在 `prepare()` 里和 camera / speech 一起请求 | 见 §5 |

## 3 · 架构

新增两个职责清晰的类型，贴合现有"每个 engine 只管自己一件窄事"的分层：

```
RecordingEngine ──didFinishRecordingTo──▶ TakeArchiver ──▶ PhotoLibrarySaving
   (录制生命周期)                          (归档状态机)        (Photos 薄封装)
                                              │
                                    weak delegate │
                                              ▼
                                        SessionManager ──▶ HUD
```

### 3.1 新增文件

**`ios/Pollux One/Domain/TakeArchive.swift`** — 纯数据，无框架依赖

```swift
enum PhotoLibraryAddPermission: Equatable { case granted, denied, restricted, notDetermined }

enum TakeArchiveFailure: Equatable {
    case permissionDenied
    case permissionRestricted
    case saveFailed(String)
}

enum TakeArchiveState: Equatable {
    case idle
    case saving
    case saved(assetIdentifier: String)
    /// 失败时带上残留文件的位置，将来加重试有路可走。
    case failed(TakeArchiveFailure, retainedFileURL: URL?)
}

@MainActor
protocol PhotoLibrarySaving: AnyObject {
    func currentAddPermission() -> PhotoLibraryAddPermission
    func requestAddPermission() async -> PhotoLibraryAddPermission
    /// 成功时返回新建 asset 的 localIdentifier。
    func saveVideo(at url: URL) async throws -> String
}
```

另有一个纯函数，负责把 (state, permission) 映射成 HUD 文案 —— 这是 harness 直接
断言的单元：

```swift
enum TakeArchiveMessage {
    static func hudText(state: TakeArchiveState, permission: PhotoLibraryAddPermission) -> String?
}
```

文案（沿用 app 现有英文 UI 文案风格）：

| 条件 | 文案 |
|---|---|
| `permission == .denied/.restricted` 且 `state == .idle` | `Photos access denied — takes won't be saved.` |
| `.saving` | `Saving to Photos…` |
| `.saved` | `Saved to Photos` |
| `.failed(.permissionDenied, _)` | `Photos access denied — this take stayed on the device.` |
| `.failed(.permissionRestricted, _)` | `Photos access is restricted — this take stayed on the device.` |
| `.failed(.saveFailed(msg), _)` | `Save failed — <msg>` |
| `.idle` 且 `permission` 为 `.granted` 或 `.notDetermined` | `nil`（不显示，避免第一条 take 之前就占位） |

**`ios/Pollux One/Engines/PhotoLibraryService.swift`** — 唯一 `import Photos` 的文件

- `requestAddPermission()`：`PHPhotoLibrary.requestAuthorization(for: .addOnly)`，
  用 `withCheckedContinuation` 包成 async。
- `saveVideo(at:)`：`PHPhotoLibrary.shared().performChanges { ... }` 的 async throws
  版本，块内用 `PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL:)`，
  捕获 `placeholderForCreatedAsset?.localIdentifier` 返回。
- 写入全程用 `UIApplication.beginBackgroundTask` / `endBackgroundTask` 包住，防止
  "按停止后立刻切后台"导致写入被杀。**背景任务断言放在这里而不是 TakeArchiver
  里**，因为 `UIApplication` 是 iOS-only，会破坏 harness 的 macOS 编译。

**`ios/Pollux One/Engines/TakeArchiver.swift`** — `@MainActor @Observable`，不 import Photos

```swift
protocol TakeArchiverDelegate: AnyObject {
    func takeArchiver(_ archiver: TakeArchiver, didUpdate state: TakeArchiveState)
}

@MainActor
@Observable
final class TakeArchiver {
    private(set) var state: TakeArchiveState = .idle
    private(set) var permission: PhotoLibraryAddPermission = .notDetermined
    weak var delegate: TakeArchiverDelegate?

    init(library: PhotoLibrarySaving)
    func refreshPermission() async          // prepare() 调用
    func archive(takeAt url: URL)           // 入队并驱动
}
```

行为：

1. `archive(takeAt:)` 把 URL 推进队列。**串行处理**，一条存完才开始下一条；
   `state` 反映最近一条。
2. 取出一条 → 若 `permission == .notDetermined` 先请求一次。
3. 权限被拒/受限 → `.failed(.permissionDenied/.permissionRestricted, retainedFileURL: url)`，
   **不删文件**。
4. 权限 OK → `.saving` → `saveVideo(at:)`。
   - 成功 → `try? FileManager.default.removeItem(at: url)` → `.saved(assetIdentifier:)`
   - 抛错 → `.failed(.saveFailed(error.localizedDescription), retainedFileURL: url)`，不删文件
5. 每次 `state` 变更都通知 `delegate`。
6. **不做自动重试**（YAGNI）。`retainedFileURL` 是将来加重试的入口。

**`ios/Pollux One/Engines/TakeArchiver+RecordingEngineDelegate.swift`** — 单独一个文件

`RecordingEngineDelegate` 的方法签名会牵出 `RecordingEngine` → `CameraEngine` →
iOS-only 的 AVFoundation 类型。conformance 隔离在独立文件里，`TakeArchiver.swift`
本体才能干净地进 harness。

```swift
extension TakeArchiver: RecordingEngineDelegate {
    func recordingEngine(_ engine: RecordingEngine, didFinishRecordingTo url: URL) { archive(takeAt: url) }
    func recordingEngine(_ engine: RecordingEngine, didFailWithError error: Error) {
        // 录制本身就失败了，没有文件可归档，也没有残留文件要保留。
        state = .failed(.saveFailed(error.localizedDescription), retainedFileURL: nil)
    }
}
```

### 3.2 所有权与生命周期（关键）

**`TakeArchiver` 由 `AppEnvironment` 持有，走 app 生命周期**，从 environment 注入
`RecordingView` → `SessionManager`，由 `SessionManager.init` 设成
`recordingEngine.delegate`。

理由是一条必须堵住的数据丢失路径：用户按停止后**立刻返回脚本列表**。
`onDisappear` → `teardown()` → `RecordingViewModel`/`SessionManager` 随 `@State`
释放；而 `AVCaptureMovieFileOutput` 的完成回调要几百毫秒后才到，`weak var delegate`
那时已是 nil。既然相册是唯一归属，这条最自然的手势不能丢件。

`SessionManager.init` 里同时做两件事：`recordingEngine.delegate = takeArchiver`，
以及 `takeArchiver.delegate = self`。

反过来，`TakeArchiver.delegate`（指向 `SessionManager`）用 `weak` 正合适：录制页
消失后 archiver 继续把文件存完，只是没人再去记录 assetIdentifier —— 这正是期望
行为，也和 codebase 里其它 engine 的 delegate 写法一致。

保存任务用非结构化 `Task { }` 启动，不随任何 view 的生命周期取消。

## 4 · 数据模型

`RecordingSession.localVideoURL` 在"成功即删 tmp"的策略下语义失效。改为：

```swift
struct RecordingSession: Identifiable, Codable, Equatable {
    ...
    /// 保存成功后 PHAsset 的 localIdentifier —— 这条 take 落在相册里的唯一句柄。
    var photoLibraryAssetIdentifier: String?
    /// 语义收窄：仅在保存失败时指向沙盒/tmp 里的残留文件。
    var localVideoURL: URL?
}
```

`SessionManager` 在 `takeArchiver(_:didUpdate:)` 里按 state 写回这两个字段。

**诚实说明**：`RecordingSession` 目前只是 `SessionManager` 的一个 private 内存变量，
既没有持久化也没有上传后端。`photoLibraryAssetIdentifier` 是为将来的上传功能预留的
句柄，当前只在录制页存活期间有值。加它的理由是：不加的话 app 对"这条 take 去哪了"
零记录。

## 5 · 权限时机

在 `SessionManager.prepare()` 里，跟在 camera / speech 授权之后调
`takeArchiver.refreshPermission()`。

选它而不是"第一条 take 存盘时才请求"，因为后者一旦用户拒绝，第一条素材已经录完
并且直接损失；提前请求还能让 HUD 一进页面就说清"存不了相册"。

pbxproj 的 Debug 和 Release 两个 configuration 各加一行：

```
INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription = "Pollux One saves the takes you record to your photo library.";
```

（工程用 `PBXFileSystemSynchronizedRootGroup`，objectVersion 77，新增 .swift 文件会
自动进 target，**不需要**改 pbxproj 的 sources 段。）

## 6 · HUD

`TopHUDView` 从单行 `HStack` 改成 `VStack`：

- 第一行：维持现状 `● REC 00:12` … `LEFT 1h42m`（灵动岛两侧，位置不动）
- 第二行：居中一行小字（11pt，白 0.85 透明度 + 现有阴影），显示
  `TakeArchiveMessage.hudText(...)`

文案为 `nil` 时该行**完全不参与布局**（不是 opacity 0），否则会把 `top: 60` 的
teleprompter 往下顶 —— 两者之间只有 44pt 空隙。

注意一个现存的坑：`TopHUDView` 内部已经有 `.padding(.horizontal, 18).padding(.top, 16)`，
而 `RecordingView` 又给它套了一层 `.padding(.horizontal, 18)` + `.topAnchored(16)`。
这是既有的重复 padding，本次改动**不要顺手“修”它**，否则整个顶部 HUD 会位移；
新增的第二行沿用同一个容器即可。

`RecordingView` 把 `viewModel.sessionManager.takeArchiveState` /
`.photoLibraryPermission` 传进去；`SessionManager` 上加两个 computed passthrough
读 archiver，`@Observable` 会自动传播变更。

## 7 · 验证

沿用仓库既有的离线 harness（`scripts/test-engines.sh`，纯 swiftc 编译 + 断言，
不需要 simulator）。

新增 `ios/EngineHarness/ArchiveScenarios.swift`，注册进 `main.swift` 的总计数，
并把这两个源文件加进 `scripts/test-engines.sh` 的编译列表：

```
"$IOS/Domain/TakeArchive.swift"
"$IOS/Engines/TakeArchiver.swift"
ios/EngineHarness/ArchiveScenarios.swift
```

用一个 `FakePhotoLibrary`（可编排返回成功 / 抛错 / 各种权限）覆盖：

1. 保存成功 → 源文件被删除，state 为 `.saved` 且带正确的 assetIdentifier
2. 保存抛错 → 源文件**仍然存在**，state 为 `.failed(.saveFailed, retainedFileURL:)`
3. 权限 denied → 根本不调用 `saveVideo`，源文件保留，state 为 `.failed(.permissionDenied, ...)`
4. 权限 notDetermined → 归档时触发一次请求，且只请求一次
5. 连续两条 take → 串行处理，两次 saveVideo 调用顺序正确，delegate 收到的 state 序列正确
6. `TakeArchiveMessage.hudText` 对每种 (state, permission) 组合产出预期文案，
   `.idle` + 正常权限产出 `nil`

真实文件用 `FileManager.default.temporaryDirectory` 里写的小文件，这样"删了没删"
是真断言而不是 mock 计数。

## 8 · 明确不做（YAGNI）

- 自定义相簿「Pollux One」—— 需要完整读写权限，弹窗更重且受"仅选中照片"限制
- 保存失败后的自动重试 / 后台重试队列
- 录制完的缩略图预览、回看、删除
- 上传后端（`photoLibraryAssetIdentifier` 只是给它预留句柄）
- 保存前的确认条 / "这条废了重拍"流程

## 9 · 已知风险

相册是唯一归属 + 成功即删 tmp，意味着**保存失败时残留文件在 tmp 里，可能被系统
清理，这条 take 最终会丢**。这是明确接受的取舍（换来不占沙盒、链路简单）。
`retainedFileURL` 留在 state 里，将来若要改成"失败搬进沙盒"只需动 `TakeArchiver`
一个文件。
