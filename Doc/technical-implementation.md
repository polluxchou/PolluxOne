# Pollux One — 技术实现文档

版本：当前主干 + `teleprompter-fixed-window-pacing`（PR #2）
日期：2026-09-04

本文描述**当前代码的真实状态**。根目录 `README.md` 有若干处已经漂移（见 §12），
以本文为准。

---

## 1 · 三端边界

```
PolluxOne/
├── ios/        Swift / SwiftUI / AVFoundation / Speech — Xcode 工程
├── web/        Next.js 16 + React 19 + Supabase — 稿件编写控制台
├── backend/    Supabase schema / RLS migration
├── scripts/    test-engines.sh — 离线引擎验证
├── docs/       superpowers 工作流产物（设计 spec + 实施计划）
└── Doc/        本文档所在处（产品需求 + 技术实现）
```

职责边界：**Web 负责长文本编辑**，**iOS 负责浏览/选择/同步/录制/安全词小改**。
iOS 不实现完整文本编辑器。

选型原则：简单、可替换、可验证。iOS 侧刻意零第三方 SPM 依赖。

## 2 · 构建事实

| 项 | 实际值 |
|---|---|
| Xcode 工程 | `ios/Pollux One.xcodeproj`，`objectVersion = 77` |
| Scheme / Target | 均为 `Pollux One`，单 target |
| `IPHONEOS_DEPLOYMENT_TARGET` | **26.5** |
| `SWIFT_VERSION` | **5.0**（Swift 5 语言模式） |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | **MainActor** |
| `SWIFT_APPROACHABLE_CONCURRENCY` | YES |
| 第三方依赖 | 无 |

**新增 `.swift` 文件自动入 target。** 工程用 `PBXFileSystemSynchronizedRootGroup`，
所以加文件**不需要**手改 `.pbxproj`。这一点影响所有后续改动的操作方式。

编译验证：

```bash
xcodebuild -project "ios/Pollux One.xcodeproj" -scheme "Pollux One" \
  -destination 'generic/platform=iOS Simulator' build
```

当前有三个既有 warning，均非本版本引入：`AudioSessionController.swift:26`
（`allowBluetooth` 弃用）、`CameraEngine.swift:41`（`nonisolated(unsafe)` 无效果）、
target 级 `UIRequiresFullScreen` 弃用。

## 3 · iOS 分层与依赖方向

```
App/          AppEnvironment（组合根）· RootView · LoginView
   ↓
Features/     ScriptList/ · Recording/（视图层，只渲染状态）
   ↓
Engines/      各引擎 + SessionManager（编排）
   ↓
Domain/       纯数据模型与纯算法（无框架依赖）
   ↑
Networking/   BackendClient 协议 + MockBackendClient
```

**依赖只向下。** `Domain/` 只 `import Foundation`；引擎不认识视图；视图不认识
网络层。

**每个引擎严格单一职责**，例如 `CameraEngine` 完全不理解 Script，
`ScriptAlignmentEngine` 完全不理解 UI。这样将来换算法（比如接 LLM 辅助对齐）
不需要动其他模块。

**`AppEnvironment` 是唯一持有具体 `BackendClient` 的地方**。把
`MockBackendClient` 换成 `SupabaseBackendClient` 只改这一个 initializer，
下游没有任何地方按名字引用具体类型。

`TakeArchiver` 刻意挂在 App 生命周期上而不是录制页上：一条素材在用户划回列表页
之后才写完，仍然要能进相册——它只是没有对象可以汇报 asset identifier 了。

## 4 · 领域模型与版本冻结

```
Script ─┬─ ScriptSection ─┬─ Paragraph ─── Sentence ─── Token
        │  scripts.version 用于并发保护
        │
RecordingSession（开始时冻结 script_id + script_version）
  ├─ ReadingSession（ReadingPosition / ReadingProgress，随语音更新）
  └─ VoiceCommand（安全词改稿的审计记录）
```

**版本冻结是关键设计。** Web 端可能在 iOS 正在录制时改稿，`ScriptRevision`
冻结版本保证录制中的 session 不被远端更新打断。安全词的修改先落在本地 revision，
结束后经 `ScriptSyncService.syncEditsToCloud()` 合并回云端。

两个容易踩的细节：

- **`Sentence.tokens` 和 `TextTokenizer.tokens(in:)` 是两套不同的切分。**
  前者走 `Token.tokenize`，按空格切；后者中文按字切。
  `ReadingPosition.tokenIndexInSentence` 索引的是**后者**。中文一整句用前者只得到
  1 个 token，混用会让句内比例恒 ≥ 1，提词器整句不动然后在句末瞬移——不崩不报错。
- **`Paragraph.fullText` 用空格连接句子**，中文会得到「问题。 它们让」。排版链路
  不复用它（见 §5.2），它现有的两个调用方（语种检测、改稿提议文案）对一个多余
  空格不敏感。

## 5 · 核心链路：语音 → 位置 → 显示

这是产品的命门，也是本版本改动的全部所在。

```
麦克风 ──► SpeechRecognitionService ──► SpeechTranscript（累积文本）
                                            │
                        ┌───────────────────┴───────────────────┐
                        ▼                                       ▼
              ScriptAlignmentEngine                      SafeWordDetector
                   （句级真值）                          （唤醒指令模式）
                        │                                       ▼
                        ▼                                VoiceCommandEngine
                 ReadingPosition
                        │
                        ▼
                TeleprompterEngine ◄──── ReadingPacer（连续光标）
                        │
                        ▼
              TeleprompterDisplayState ──► TeleprompterOverlayView
```

### 5.1 ScriptAlignmentEngine — 句级真值

`SlidingWindowAlignmentEngine`：在当前句前 2 后 5 的滑动窗口内，用归一化 token
做重叠度打分。打分由两项等权组成：

- **coverage** — 这句被念了多少（按顺序、允许跳字）
- **ownership** — 刚说的那几个词属于哪一句

**ownership 是承重的那一半。** 只用 coverage 的话，一句念完的旧句会压过刚开始念
的新句，导致高亮永远慢一句——正好是产品要解决问题的反面。等权加起来意味着念到
新句六个词时新句就赢了，而重复一句仍然守得住（它的 ownership 保持高位），无关
说话则谁都不拥有、当前句以微弱多数留住位置。

coverage 匹配**从后往前**扫，找最晚一次出现：同一句在 tail 里出现两次时，第二遍
才是当下这一遍。

置信度低于 `0.34` 时不移动，返回**上一个已知良好位置**——包括它的句内 token
偏移（本版本修正，见 §11）。

### 5.2 排版管线 — 视觉行从哪来

固定行窗的前提是知道每一行装什么，而原来的代码里没有"视觉行"这个概念。

```
Script ──► PromptScriptText ──► PromptLineLayout(width:, measurer:) ──► [PromptLine]
           规范化拼接               贪心断行                          每行带
           + 句子字偏移表                                            全局字符区间
           + 段落硬断点                                              + 字符 x 偏移表
```

**`PromptScriptText` 是唯一的文本拼接口径。** 排版和"句 → 字偏移"查表都必须走它。
两边各拼一次是这类功能最典型的错法：算出的字偏移和排版时的字偏移差几个空格，
光标就永久性偏一点，且随脚本长度累积。

段落边界记录为 `hardBreaks` 里的**偏移**，而不是在文本里插 `\n`。换行符会占一个
永远不会被念出来的字符位，光标就得跳过它，段落之后的每个偏移都要偏移一——这样
可以整类消掉 off-by-one。

**断行留在纯逻辑里，只把量宽抽成协议注入**（`TextWidthMeasuring`）。这样断行算法
能进 macOS 离线 harness 精确断言；如果把断行也委托给 CoreText，harness 里就只剩
窗口逻辑被测到，而断行恰恰是最容易错的一半。

断行规则按语种分流：

- **拉丁**：回退到最后一个空白；整行放不下一个词时才硬切
- **CJK**：任意字符间可断，但避开三类位置——行首禁则、行尾禁则、
  **内嵌拉丁词不切开**（产品自带示例脚本就是 `"Pollux One 从另一个问题出发。"`）

`SystemFontLineMeasurer` 是 iOS 侧实现：把整串文本 `CTLine` 排版一次，从结果读
每个字符的 advance。字体作为**值**传入，视图用 `Font(_:)` 包同一个实例来画——
"画出来的"和"量出来的"是同一个对象，而不是两份需要互相吻合的描述。

### 5.3 ReadingPacer — 连续光标

`cursor: Double` 是**全局字符偏移**（带小数，小数部分就是行内进度）。

**选字符作单位是整套设计的支点**：改字号或宽度后重排，光标自动存活，不需要任何
位置迁移代码。字符偏移是排版无关量。

| 事件 | 动作 |
|---|---|
| 每 1/30 秒 tick | `cursor += rate × dt`，然后夹在上限内 |
| 真值到达，confidence ≥ 0.5 | 由 `Δ字/Δt` 更新 `rate`，EMA α = 0.25 |
| 偏差 ≤ 2 行 | `cursor += error × 0.25`，3–4 次识别内吃平，不跳 |
| 偏差 > 2 行 | 判为跳读/回读，直接 seek |

语速参数：中文初值 5.0 字/秒，夹在 2.0–12.0；拉丁初值 16.0 字符/秒，夹在 6.0–40.0。

**前推上限是最关键的一行逻辑**：`cursor ≤ lastTruth + 1.2 × 当前行字符数`。纯
dead reckoning 遇到读者停下来就会一路跑飞。选 1.2 行而不是 1.0：识别回调有延迟，
允许略超一行才能让换行发生在读到行尾的**同时**而不是滞后半秒。

刻意不引入静音超时计时器——上限约束已覆盖同一失效场景，而且它是位置量、不受
回调抖动影响，比时间量更稳。

**时间是每个方法的参数，从不读时钟。** 生产代码传
`position.updatedAt.timeIntervalSinceReferenceDate`（单调、绝对），离线场景传
合成时间，于是一个专门处理"速率"的组件行为完全确定。前置条件：调用方必须给单调
递增的时间，并在每条 take 开头 `reset`。

`sample > 0` 那个守卫顺带挡掉了回读产生的负速率样本——它不是冗余的 sanity check。

### 5.4 TeleprompterEngine — 固定行窗

引擎上有**三个独立的可观察属性**，变化频率不同：

| 属性 | 频率 | 读它的是谁 |
|---|---|---|
| `displayState` | 每推进一行（约 2–4 秒） | 文字 VStack |
| `inLineProgress` | 30Hz | 当前行的高亮填充 |
| `readingProgress` | 30Hz | 右侧进度轨 |

**拆开是必需的**：两个 30Hz 属性如果塞进 `displayState`，整个 struct 每秒变 30 次，
SwiftUI 要对所有 `Text` 做 30 次 diff。

`displayState` 只装 `lines`（**全脚本**的视觉行）+ `currentLineIndex` + 语种 +
`isVisible`。行角色由视图按 `line.id - currentLineIndex` 现算，不预切窗口。

实测修正：Swift 6.3.3 的 `@Observable` 对 `Equatable` 载荷**会**在 registrar 层面
去重（相等赋值 0 次通知；非 `Equatable` 载荷则每次都通知）。所以挡住 30Hz
re-diff 的是 `TeleprompterDisplayState: Equatable` 这个 conformance——而且它是更强
的保证：合成的 conformance 意味着加一个非 `Equatable` 字段会直接编译失败。写入点
仍保留一行相等性守卫，但它是**防御性**的（防手写 `==` 出错），不是承重的。

### 5.5 视图层的三条不变量

`TeleprompterOverlayView` 里有三件事必须成立，任何一条错了，效果就退化回它所
替代的那个版本：

1. **衬底不在滚动的 VStack 里。** 它是窗口坐标系里固定位置的圆角矩形，画在文字
   **下面**，文字从它上方滑过，本身不挂任何 animation。衬底跟着某一行走，就会跟
   动画上下移动，固定行位不存在了。
2. **渲染全脚本的行，按 `line.id`（全局行序号）标识。** 只渲染可见的 5 行会让
   SwiftUI 把每一步看成一批插入+删除，动画退化成交叉淡入淡出——那就不是滑动。
   代价是全脚本的 `Text` 都参与布局；提词脚本以"一条 take 读完"为长度上限，
   量级在百行内，可以接受。
3. **列宽必须算出来，不能量出来。**

   ```
   columnWidth = 提供给覆盖层的宽度 − 进度轨列 22 − 轨间距 6 − 文字左内缩 7
   ```

   **不能**把 `onGeometryChange` 挂在装着文字的容器上去量。滚动的每一行都带
   `.fixedSize(horizontal: true, vertical: false)`（为了让已断好的行绝不被 SwiftUI
   再折一次），所以那个容器的宽度是**最宽一行的理想宽度**。于是形成自反馈环：
   量到的宽度越大 → 断行越少 → 行越长 → 理想宽度越大。它收敛在"只在段落边界断"，
   即每段一行、全部冲出屏幕。

   实现用一个 `Color.clear.frame(height: 0)` 探针放在根 `VStack` 首位——
   `Color.clear` 返回被提供给它的宽度，没有内容能进入答案。

几何数值（`textSize` 默认 20）：

| 语种 | pitch | 块高 |
|---|---|---|
| 中文 | 19 × 1.6 = 30.4 | 5 行 = 152pt |
| 拉丁 | 20 × 1.5 = 30.0 | 6 行 = 180pt |

块顶在 y = 60。字号上限 28pt 时拉丁块底到 312pt，所以顶部渐变遮罩从 300 提到
**330**。

## 6 · 安全词与语音指令

刻意拆成两个文件：`SafeWordDetector` 只回答"这个词刚才被说了吗"，
`VoiceCommandEngine` 负责之后发生什么。将来换成端上唤醒词模型只会替换前者。

**检测按"安全词在整段 transcript 里出现了几次"计数**，而不是去 diff 新增文本。
后者会被逐字增长的 partial 切碎（`pol` | `l` | `ux`），在真机上等于永不触发。
出现次数计数也免疫中途修订——修订会让每个字符索引都位移。

识别器修订导致出现次数**变少**时要下调水位线，否则之后的话再也注册不了。冷却期
内的那次出现**不推进水位线**：它还没被处理，冷却期过了还应该能触发。

`VoiceCommandEngine` 是状态机 `idle → listeningForCommand → awaitingConfirmation`，
指令解析刻意是个薄的关键词匹配器而不是 NLU 模型——设计上要活下来的是状态机，不是
解析逻辑。指令只解析安全词**之后**的文本（记下安全词触发时的 transcript 基线）。
8 秒等不到指令回到 idle。

## 7 · 相机与录制

`CameraEngine` 管 AVCaptureSession 的全部配置，完全不认识 Script。

**镜头档位标签由设备上报的构成镜头算出，不硬编码。** AVFoundation 把虚拟多摄
设备的 zoom 锚在**最广**的那颗上，所以 Pro 后摄的 `videoZoomFactor == 1.0` 是超
广角，而用户叫「1×」的那颗是 device zoom 2.0。HUD 上打印的每个数字都骑在这个换算
上，而它错了编译器抓不到——App 照跑，只是标签是错的。硬件数据不自洽时**拒绝**
而不是猜。

录制中禁用前后切换与格式切换：两者都会导致正在写的影片文件被提前结束（切换要
移除并重加视频输入，改格式要重配 active format）。控件同步置灰，而不是静默失败。

## 8 · 归档

```
RecordingEngine ──didFinishRecordingTo──► TakeArchiver ──► PhotoLibrarySaving
  （录制生命周期）                        （归档状态机）      （Photos 薄封装）
```

`TakeArchiver` 不 import Photos / UIKit，因此能进离线 harness。`PhotoLibraryService`
是唯一碰 Photos 的文件。

只申请 add-only 权限（`NSPhotoLibraryAddUsageDescription`），弹窗最轻且不受"仅
选中照片"受限访问影响；代价是不能建自定义相簿。成功后删临时文件（相册是唯一
归属），**失败时保留**并在 HUD 说明。权限在 `prepare()` 里就问——录完才发现被拒
会白费一条素材。

## 9 · 后端

Supabase（Auth + Postgres + RLS）。`backend/supabase/migrations/0001_init.sql`：
**10 张表**、11 条 RLS policy、2 个 function、2 个 trigger。

表：`profiles` `devices` `scripts` `script_sections` `paragraphs` `sentences`
`recording_sessions` `reading_sessions` `script_reading_progress` `voice_commands`

两个 trigger：`on_auth_user_created`（建 profile）、`sections_touch_script`
（`script_sections` 变更时自增 `scripts.version`，支撑 §4 的版本冻结）。

iOS 与 Web 各经一层抽象隔离（`BackendClient` / `lib/backend.ts`），未来换自建 API
不动上层调用点。

## 10 · 验证策略

### 离线 harness 是主力

```bash
./scripts/test-engines.sh
```

用 `swiftc` 在 macOS 上直接编译**真实的** Domain + 纯引擎源码（不是 mock），跑
**235 条场景**，任何一例失败返回非零，可直接当 CI 门禁。无模拟器、无 Xcode test
target。

之所以可行：提词跟随、配速、排版、安全词全都是纯数据进/数据出（Script + 语音
transcript → ReadingPosition / VoiceCommand / [PromptLine]）。

| Suite | 覆盖 |
|---|---|
| 英文 / 中文对齐 | 顺序、重复、跳句、口语化、念错重说、无标点 |
| 对抗对齐 | 无关噪音、往回跳、长停顿重复 partial、半句就要跟上 |
| 弱结果保位置 | 低置信度保住整个已知良好位置（含句内偏移） |
| 安全词 | 逐字增长 partial、整句送达、修订变短、冷却收敛、绝不误触发 |
| 语音指令 | 改段落、稿内触发词不误抓、超时、确认只一次、中文指令 |
| 相机档位 | 三摄/长焦/双广角/无超广角、档位换算、录制中禁用 |
| 素材归档 | 全部失败分支、权限只问一次、连续素材串行 |
| 提词排版 | 语种判定、拼接口径、断行禁则、字符 x 偏移、重排 |
| 配速器 | dead reckoning、前推上限、速率收敛与夹取、小偏差滑行/大偏差 seek |
| 固定行窗 | 衬底不动、30Hz 不污染文字块、重排保位置、改稿不回退、空布局要发布 |

依赖注入是让这一切可测的手段：`TextWidthMeasuring` 让断行不依赖真实字体
（harness 用 CJK = 1em、其余 0.5em 的确定性假测量，断点因此是可精确断言的算术）；
时间是参数而非时钟，让配速收敛可断言。

### 离线 harness 抓不到什么

这是本版本最值得记录的一课。这条分支上**最严重的四个缺陷，没有一个是离线断言能
抓到的**，它们全部通过了 235 条断言和干净编译：

| 缺陷 | 属于哪一层 | 只能怎么发现 |
|---|---|---|
| 列宽自反馈环 | SwiftUI 布局系统 | 跑起来看 |
| CJK 标点单独测量偏窄 | CoreText 文本引擎行为 | 跑起来看 + 数值比对 |
| 改稿把读者踢回开头 | UUID 生命周期 | 场景按真实路径重写 |
| 低置信度拖回光标 | 语音引擎的默认参数值 | 端到端串真引擎 |

其中第三条尤其值得记住：**那条测它的场景是假的**——它重载的是同一个脚本对象，
句 id 还在，于是断言通过。**一条测不到真实路径的场景比没有场景更危险：它把"没
覆盖"伪装成"已验证"。**

所以验证纪律是：纯逻辑进 harness；跨 SwiftUI 布局、CoreText、UUID 生命周期、
`@Observable` 依赖范围的东西，必须在模拟器或真机上看。

### 已在模拟器验证

登录 → 列表 → 录制页全链路；中英双稿提词器渲染（中文 5 行衬底在 2–3、拉丁 6 行
衬底在 3–4、左边缘 20.1pt、无行溢出、衬底两侧圆角、方括号对齐）；拖 Width 滑杆
实时重新断行且收敛。

模拟器没有摄像头（显示占位提示）也没有麦克风。

## 11 · 已知问题与技术债

| 项 | 位置 | 说明 |
|---|---|---|
| **真机语音链路从未跑过** | — | 最大的未知 |
| 三个手感常量未调 | `ReadingPacer` · `TeleprompterEngine` | `rateSmoothing` 0.25 与 `correctionGain` 0.25 在 `ReadingPacer`；`lookaheadInLines` 1.2 在 `TeleprompterEngine`（它才知道当前行有多少字） |
| 日文 locale 错误 | `SpeechRecognitionService.locale(forScriptText:)` | 只查汉字区间，日文被路由到 `en-US`。**不能**直接改用 `ScriptLanguage.detect`——它把假名和汉字归为一类（排版上确实一样），会把日文路由到 `zh-CN`，同样是噪声。需要一个独立于排版的识别语种判定。处理中。 |
| iOS 未接真实 Supabase | `AppEnvironment` | 改一处 initializer |
| 语音指令只实现改段落 | `VoiceCommandEngine` | 其余 kind 已建模未实现 |
| `setVisible` 无调用方 | `TeleprompterEngine` | `displayState.isVisible` 恒为 true |
| 30Hz `Timer` 在 `.default` run loop mode | `TeleprompterEngine` | 录制页没有 scroll view，暂时无害；HUD 以后加了会被手势暂停 |
| `micLevel` 仍在父 body 读 | `RecordingView` | 15Hz 做着 §5.4 要避免的事，早于本版本存在 |
| 无 Xcode test target | `ios/Pollux OneTests/` | Swift Testing 版用例已写好，工程里未加 target |
| 长脚本全量布局 | `TeleprompterOverlayView` | 见 §5.5 不变量 2 的代价 |

## 12 · README 的漂移

根目录 `README.md` 有以下几处与代码不符，以本文为准：

| README 说 | 实际 |
|---|---|
| 最低 iOS 18+ | `IPHONEOS_DEPLOYMENT_TARGET = 26.5` |
| Swift 6 | `SWIFT_VERSION = 5.0` + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` |
| 51 个场景 | **235** 个 |
| Backend 11 张表 | **10** 张表（11 条 RLS policy，可能是这里记混了） |
| `docs/`（预留） | 已装 superpowers 工作流产物；本文档在 `Doc/` |

## 13 · 延伸阅读

- `docs/superpowers/specs/2026-08-31-teleprompter-fixed-window-pacing-design.md`
  — 提词器固定行窗 + 配速的完整设计，含三处被实测证伪的早期决定
- `docs/superpowers/specs/2026-08-31-save-take-to-photos-design.md` — 归档链路设计
- `backend/supabase/migrations/0001_init.sql` — 完整 schema
