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

## 当前状态

**已完成、可运行：**
- iOS：Xcode 工程可编译运行（已用 `xcodebuild` + Simulator 验证），登录 → Script
  列表 → Recording HUD 的完整视图层已搭好，Camera/Speech/Teleprompter/SafeWord
  各 Engine 均有 V1 实现（用 Mock 数据可跑通，无需 Supabase key）。
- Web：登录 / Script 列表 / Script 编辑（标题 + 正文，空行分段、句号分句）三个
  页面完整可用，`next build` / `next lint` 均通过。
- Backend：11 张表 + RLS + 自动建 profile / 自动加 script 版本号的 trigger，
  已跑过插入测试。

**尚未实现的核心能力：**
- iOS 端真正接入 Supabase（目前是 `MockBackendClient`，接口已就位，换掉
  `AppEnvironment` 里的实现即可）。
- Recording HUD 的视觉细节——目前是本仓库自己设计的一版极简 HUD；后续会对照
  Claude Design 里那份 `Pollux One iOS.dc.html` 设计稿重新实现顶部 HUD /
  提词区 / 底部相机参数条的具体视觉规格（配色、圆角、字重等），这部分正在
  推进中。
- Safe Word 触发后的语音指令解析目前只是关键词匹配（"change this to..." 等
  几个固定短语），不是真正的意图理解。
- Web 端还没有把 `script_reading_progress` 展示出来（后端已经建表）。

## 下一步最合理的开发顺序

1. 建一个真实 Supabase 项目，跑通 Web 的注册/登录/建稿，验证 RLS 策略。
2. 按 Claude Design 设计稿重做 iOS Recording HUD 的视觉层（Engine/ViewModel
   不用大改，主要是 `Features/Recording/*View.swift` 的样式）。
3. 把 iOS `MockBackendClient` 换成真正的 `SupabaseBackendClient`（加
   `supabase-swift` 包），打通 Web → iOS 的 Script Sync。
4. 真机测试 Camera + Speech Recognition 的实际效果，调 `ScriptAlignmentEngine`
   的窗口大小/置信度阈值。
5. Safe Word → Voice Command 的解析逐步做得更鲁棒。

## 当前最大的三个技术风险

1. **Speech-to-Script Alignment 的实际准确率没有真机验证过**——V1 用的是
   简单的 token 重叠打分，真实朗读中的口音、背景噪音、口语化改写会怎样影响
   置信度，需要真机 + 真实录音测试才知道。
2. **Recording Session 冻结版本 + Safe Word 本地编辑 + 事后合并回云端**这条
   链路目前只有 iOS 侧的内存实现，`ScriptSyncService.syncEditsToCloud()` 还
   没有对着真实 Supabase 跑过；Web 同时编辑同一篇稿子时的冲突处理策略还没定。
3. **AVFoundation 并发/线程模型**：`CameraEngine` 把 session 配置放在专用
   `DispatchQueue`，在当前 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 的工程
   设置下会有几处 Sendable 警告（已确认是警告不是错误，编译通过），中期应该
   把 CameraEngine 收敛成一个 actor 或彻底切到 MainActor 上跑 session 配置，
   避免以后升级到 Swift 6 严格并发检查时踩坑。
