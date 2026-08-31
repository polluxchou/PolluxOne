# Pollux One

**Camera first. Teleprompter second. AI quietly in the background.**

一台运行在 iPhone 上的 AI-native Camera：先是一台相机，其次才具备智能提词能力。
核心目标——解决传统提词器最大的问题：用户为了看稿，眼神会离开镜头。Pollux One
把提词内容做成贴近前置摄像头 / Dynamic Island 的 Camera HUD，并且**跟随用户实际
朗读位置**，而不是固定速度滚动。

所有工程与设计决策只检查一个问题：

> Does this help the speaker maintain eye contact with the lens?

## 项目结构

```
PolluxOne/
├── ios/          Swift / SwiftUI / AVFoundation — Xcode 工程 (Pollux One.xcodeproj)
├── web/          Next.js 16 + React 19 + Supabase — Script 编写控制台
├── backend/      Supabase schema / RLS migrations
└── docs/         （预留）
```

三端职责边界很清楚：**Web 是主要的 Script Management Console**（长文本编辑），
**iOS 只负责浏览 / 选择 / 同步 / 录制 / Safe Word 小范围修改**，不做完整文本编辑器。

## 技术架构

| 端 | 技术 | 备注 |
|---|---|---|
| iOS | Swift 6 / SwiftUI / AVFoundation / Speech | 最低 iOS 18+，用 Xcode 16+ 的 file-system-synchronized groups（加文件即自动入工程，不用手改 `.pbxproj`） |
| Web | Next.js 16 (App Router, Server Actions) / React 19 | 无重型 UI 组件库，纯 `globals.css` |
| Backend | Supabase (Auth + Postgres + RLS) | 通过 `BackendClient` (iOS) / `lib/backend.ts` (Web) 两层抽象隔离，未来可换自建 API 而不动上层调用点 |

选型原则：**简单、可替换、可验证**，不做过度工程化。

### 关键依赖

- iOS：无第三方 SPM 包依赖（V1 故意如此——`MockBackendClient` 让 App 在没有 Supabase
  key 之前也能跑起来；真正接 Supabase 时在 Xcode 里加 `supabase-swift` 包，实现
  `SupabaseBackendClient: BackendClient` 即可替换，调用点不用改）。
- Web：`@supabase/ssr`、`@supabase/supabase-js`。
- Backend：Supabase CLI（本地开发可选，见 `backend/README.md`）。

## Domain Model

```
Script ─┬─ ScriptSection ─┬─ Paragraph ─── Sentence ─── Token
         │  (version 字段用于并发保护)
         │
RecordingSession（开始时冻结 script_id + script_version）
  └─ ReadingSession（ReadingPosition / ReadingProgress，随语音持续更新）
  └─ VoiceCommand（Safe Word → 修改段落的审计记录）

User / Device / CameraConfiguration
```

冻结版本号是关键设计：Web 端可能在 iOS 正在录制时修改 Script，冻结的
`ScriptRevision`（`ios/Pollux One/Domain/ScriptModels.swift`）保证录制中的
Session 不会被远端更新打断；Safe Word 的编辑先落在本地 revision 上，结束后再
经 `ScriptSyncService.syncEditsToCloud()` 合并回云端。完整字段见
`backend/supabase/migrations/0001_init.sql` 和 `ios/Pollux One/Domain/`。

## iOS 模块划分

```
Domain/            纯数据模型（Script/Session/VoiceCommand/CameraConfiguration/User）
Networking/        BackendClient 协议 + MockBackendClient（V1 默认，内存实现）
Engines/           CameraEngine · RecordingEngine · AudioLevelMonitor
                   SpeechRecognitionService · ScriptAlignmentEngine · TeleprompterEngine
                   SafeWordDetector · VoiceCommandEngine · ScriptSyncService
                   SessionManager（编排以上所有 Engine）· DeviceCapabilityService
Features/
  ScriptList/      浏览 / 选择 Script
  Recording/       Camera HUD（RecordingView 及其子视图）
App/               AppEnvironment（组合根，唯一持有具体 BackendClient 的地方）· 登录
```

每个 Engine 严格单一职责——例如 `CameraEngine` 完全不理解 Script，
`ScriptAlignmentEngine` 完全不理解 UI——这样未来替换算法（比如接 LLM-assisted
alignment）不需要动其他模块。`ScriptAlignmentEngine` 目前的实现
(`SlidingWindowAlignmentEngine`) 用归一化 token 在当前句前后一个滑动窗口内做
重叠度打分，处理正常顺序、停顿、重复、跳读等情况，但接口本身与算法解耦，
可以直接换成更复杂的实现。

## 如何运行

### iOS

```bash
open "ios/Pollux One.xcodeproj"
```

直接在 Xcode 里选设备/模拟器 Run 即可；已验证 `xcodebuild` 编译通过
（iOS 26.5 Simulator），登录页在模拟器里渲染正常。真机上才能看到摄像头
Preview（模拟器没有摄像头，会显示占位提示）。

### Web

```bash
cd web
cp .env.local.example .env.local   # 填入 Supabase 项目 URL + anon key
npm install
npm run dev
```

没有真实 Supabase key 时页面也能正常渲染（登录会报 "fetch failed"，不会
crash），可以先看 UI/交互，跑通完整登录/建稿流程需要先起 Supabase 项目。

### Backend

```bash
cd backend
supabase db push
# 或直接：psql "$DATABASE_URL" -f supabase/migrations/0001_init.sql
```

schema 已经在本地临时 Postgres 17 实例（stub 了 `auth` schema）跑过完整插入
测试，包括 `script_sections` 变更触发 `scripts.version` 自增的 trigger。

## 测试

提词跟随和安全词是产品的命门，而它们的输入输出都是纯数据（Script + 语音
transcript → ReadingPosition / VoiceCommand），所以不需要摄像头和麦克风就能
验证：

```bash
./scripts/test-engines.sh
```

这个脚本直接用 `swiftc` 编译真实的 Domain + 三个引擎源码（不是 mock），跑 51
个场景并打印每一步的置信度；有任何一例失败就返回非零，可以直接当 CI 门禁用。

**提词跟随**（`ScriptAlignmentEngine`）：

| 场景 | 中文 | 英文 |
|---|---|---|
| 顺序朗读 | ✓ | ✓ |
| **只念了半句就要跟上**（产品最核心的行为） | — | ✓ |
| 重复一句（保持不动，不能往前跳） | ✓ | ✓ |
| 跳过一句 | ✓ | ✓ |
| 往回跳两句 | — | ✓ |
| 口语化改写／临时加词 | ✓ | ✓ |
| 念错后重说 | — | ✓ |
| 识别结果完全没有标点（ASR 常态） | ✓ | — |
| 无关说话/噪音（不能乱跑） | — | ✓ |
| 长时间停顿 | — | ✓ |

**安全词 + 语音指令**（`SafeWordDetector` / `VoiceCommandEngine`）：

| 场景 |
|---|
| **安全词逐字增长送达**（`p`→`po`→`pol`…，识别器的真实行为） |
| 安全词整句一次送达 |
| 识别结果被修订变短后仍能检测 |
| 同一次说话被反复上报（冷却期收敛成一次触发） |
| 隔很久说第二次（应该触发两次） |
| 正常念稿时绝不误触发 |
| 大小写不敏感 |
| 只解析安全词**之后**的话（不能抓到稿子里出现过的触发词） |
| 说了安全词但后面没有有效指令 → 不弹确认框 |
| partial 结果不提交指令 |
| 指令一直不来会超时回到 idle |
| 确认只生效一次（防重复点击） |
| 取消后不留残留 |
| 中文指令「把这段改成…」 |

同一批场景也写成了 Swift Testing 版本放在
`ios/Pollux OneTests/ScriptAlignmentEngineTests.swift`，等 Xcode 里加上 test
target（File ▸ New ▸ Target ▸ Unit Testing Bundle）就能在 IDE 里跑。

Web 侧：`cd web && npm run lint && npm run build`。

## 当前状态

**已完成、可验证：**
- **iOS 提词跟随算法**：`ScriptAlignmentEngine` 全部场景通过，中英双语。
  打分由两项组成——`coverage`（这句念了多少）+ `ownership`（刚说的几个词属于
  哪句）。`ownership` 是关键：只用 coverage 的话，一句念完的旧句会压过刚开始
  念的新句，导致高亮永远慢一句，正好是产品要解决问题的反面。
- **安全词 + 语音指令**：`SafeWordDetector` / `VoiceCommandEngine` 全部场景
  通过，含中文指令。检测按「安全词在整段 transcript 里出现了几次」计数，而不是
  去 diff 新增文本——后者会被逐字增长的 partial 切碎（`pol` | `l` | `ux`），
  在真机上等于永不触发。指令只解析安全词**之后**的文本。
- **iOS Recording HUD**：完全按 Claude Design 的 `Pollux One iOS.dc.html`
  「04 · Recording — HUD」实现，位置用设计稿的绝对偏移量。已在 Simulator
  实测中英双稿渲染正确。
- **iOS 工程**：`xcodebuild` 编译通过、Simulator 实跑通登录 → 列表 → 录制页。
- **Web**：登录 / 列表 / 编辑三页可用，`next build`、`next lint` 通过。
- **Backend**：11 张表 + RLS + 两个 trigger，在本地 Postgres 17 跑过插入测试。

**尚未实现／未验证：**
- **真机验证**：算法在离线场景上全过，麦克风链路（AVAudioSession、麦克风权限、
  录像音轨、按稿子语言选识别 locale）也都接好了，但**从来没在真麦克风上跑过**。
  真实 ASR 的口音、噪音、识别延迟会怎样影响，只有真机念稿子才知道。这是目前
  最大的未知。
- iOS 还没接真实 Supabase（`MockBackendClient` → `SupabaseBackendClient`，
  接口已就位，改 `AppEnvironment` 一处即可）。
- Voice Command 是关键词匹配（`change this to…` / `把这段改成…` 等十几个
  固定短语），不是意图理解；V1 也只实现了「替换当前段落」这一个指令。
- 相机翻转是占位（V1 只用前置，符合眼神接触的定位）。
- Web 还没展示 `script_reading_progress`（后端已建表）。
- Xcode 里还没有 test target（测试文件已就位，见「测试」一节）。

## 下一步最合理的开发顺序

1. **真机跑一次完整录制**——这是现在信息量最大的一步：验证 Speech
   framework 的实际识别质量、`ScriptAlignmentEngine` 在真实语音下的表现、
   以及摄像头 HUD 在真实画面上的可读性。
2. 建真实 Supabase 项目，跑通 Web 注册/登录/建稿，验证 RLS。
3. iOS 接 `supabase-swift`，实现 `SupabaseBackendClient`，打通 Web → iOS 同步。
4. 根据真机结果调 `ScriptAlignmentEngine` 的 `lookBehind`/`lookAhead`/
   `recentTokenWindow`/`minimumConfidence`——每改一个参数都先跑
   `./scripts/test-engines.sh` 确认没有回退。
5. Safe Word → Voice Command 的解析做得更鲁棒。

## 当前最大的技术风险

1. **真实 ASR 质量是最大未知**。离线 36 个场景全过说明对齐逻辑本身是对的，
   但那些 transcript 是我写的、干净的。真实的 Speech framework 输出会有识别
   错误、延迟、以及中文分词歧义；口音重或环境吵时置信度会掉到什么程度，
   目前完全没有数据。缓解手段是接口已经解耦（换 ASR provider 或换成
   LLM-assisted alignment 都不用动 TeleprompterEngine）。
2. **Recording Session 冻结版本 + Safe Word 本地编辑 + 事后合并回云端**这条
   链路目前只有 iOS 侧的内存实现，`ScriptSyncService.syncEditsToCloud()` 还
   没有对着真实 Supabase 跑过；Web 同时编辑同一篇稿子时的冲突处理策略还没定。
3. **麦克风被两个消费者争用，只能真机验证**。录像走
   `AVCaptureMovieFileOutput`（含音轨），语音识别走 `AVAudioEngine` 的
   inputNode，两者共用同一个 `AVAudioSession`。这是最简单的接法，但 iOS 上
   AVCaptureSession 的音频输入和 AVAudioEngine 同时取麦克风有可能互相打断——
   模拟器无麦克风，无法验证。如果真机上确实冲突，正解是改成
   `AVAssetWriter` + `AVCaptureVideoDataOutput`/`AVCaptureAudioDataOutput`，
   由采集会话独占麦克风、把同一份音频 buffer 同时喂给写文件和
   `SFSpeechAudioBufferRecognitionRequest.appendAudioSampleBuffer(_:)`。
   现在启动失败会在 HUD 上红条报错，不会静默不动。
4. **AVFoundation 并发/线程模型**：`CameraEngine` 把 session 配置放在专用
   `DispatchQueue`，在当前 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 下有
   几处 Sendable 警告（是警告不是错误，编译通过），中期应把它收敛成 actor，
   避免升到 Swift 6 严格并发检查时踩坑。
