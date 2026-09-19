# Brief 六屏视觉对齐 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 ② 审稿、③ 交给我、④ 确认、⑤ 等待、⑥ 不建议播、⑦ 换一篇六屏在 iPhone 上长得和 mock 一样，并修掉相机主屏「录制中点灰掉的翻转键会触发对焦」这一处点击穿透。

**Architecture:** 先把 mock 的颜色、字体、尺寸收成一层 token（`BriefPalette` 纯 Foundation 进测试台，`BriefTheme` 派生成 SwiftUI），再建六屏共用的顶行 / 按钮 / 卡片组件，然后逐屏换皮。需要新数据的地方一律先在 Domain 加纯函数并写断言，View 只翻译不重判。`SentenceStyle` / `SwipeActions` / `InsufficientState.actions` / `BriefNavigation` 的判定一行不动。

**Tech Stack:** Swift 6 · SwiftUI（iOS 18+）· CoreText 运行时注册字体 · 现有 `EngineHarness` 命令行测试台 · 无第三方包

**Spec:** `docs/superpowers/specs/2026-09-18-brief-visual-alignment-design.md`（下文写「spec §n」都指它）

---

## 零、动手之前必须知道的事

### 0.1 mock 在哪、怎么读

mock 是一个 Claude Design 画布：https://claude.ai/artifact/X3Jiga6RWyGyEhkstrPBEn 。七块画板各是一个 390×844 的 `.dc.html`，内联 style，颜色和尺寸直接抄：

| 画板 | 屏 |
|---|---|
| `project/Review.dc.html` | ② 审稿 |
| `project/Main.dc.html` | ③ 交给我 |
| `project/Confirm.dc.html` | ④ 确认（拨盘） |
| `project/Progress.dc.html` | ⑤ 等待 |
| `project/Insufficient.dc.html` | ⑥ 不建议播 |
| `project/Scripts.dc.html` | ⑦ 换一篇 |
| `project/Recording.dc.html` | ① 相机（本计划不动） |

用 Artifact 工具读：`action: "read"`, `url` 是上面那个链接, `paths: ["project/Review.dc.html"]`。**每个视觉任务动手前读对应那一块**，不要凭 spec 的文字画。spec §4.2 的色表就是从这些文件里抄出来的，两边对不上以 `.dc.html` 为准并回头改 spec。

### 0.2 测试台的硬约束

`scripts/test-engines.sh` 用 `swiftc -swift-version 5 -default-isolation MainActor` 直接编一组源文件成命令行二进制。**它不链接 SwiftUI。**

| 约束 | 后果 |
|---|---|
| 不能 `import SwiftUI` | Domain 新文件只能用 Foundation。颜色是 `UInt32`，不是 `Color` |
| 新文件必须手动加进 `scripts/test-engines.sh` 的编译列表 | 漏加 = 类型找不到（编译错误），不是测试失败 |
| 断言 API 是 `report.check(Bool, "描述", detail: "")` | 见 `ios/EngineHarness/Harness.swift` |
| Brief 的断言全在 `ios/EngineHarness/BriefScenarios.swift` 的 `runBriefSuite()` 里 | 新断言追加在该函数末尾 `return (report.pass, report.fail)` 之前，除非任务另有指明 |

跑法与门：

```bash
bash scripts/test-engines.sh 2>&1 | tail -3
```

Expected 末行形如 `══════ TOTAL: 438 passed, 0 failed ══════`。**动手前先跑一次记下 passed 数**——别的会话可能同时在加断言，所以下文只写「比上一步多 N」，不写绝对值。

### 0.3 编译的门

```bash
cd ios && xcodebuild -project "Pollux One.xcodeproj" -scheme "Pollux One" \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`（2026-09-18 在 HEAD `031e8c5` 上验证过，Xcode 27.0）。

**模拟器目前跑不起来**：`xcrun simctl list runtimes` 为空。视觉验收（Task 15）之前要 pollux 跑 `xcodebuild -downloadPlatform iOS`。Task 1–14 不依赖它。

### 0.4 工程怎么收文件

`Pollux One.xcodeproj` 用的是 file-system-synchronized group：**放进 `ios/Pollux One/` 下任何子目录的文件自动进 target**，不用碰 `.pbxproj`。非源码文件（`.ttf`、`.txt`、`.json`）当资源，默认**摊平**拷进 bundle 根——所以 `Bundle.main.url(forResource: "IBMPlexMono-Regular", withExtension: "ttf")` 能找到 `Resources/Fonts/` 里的文件。

### 0.5 已经做掉的、以及不许动的

已在 `a329acc` 做掉、本计划不再碰：`AccentColor.colorset` 已是 #C49A6C；`SentenceAccent` 已拆出 `labelColor` / `labelBackground`。

`Resources/demo-briefs/` 里已有 5 篇真稿（另一个会话产的，2026-09-18）；`BriefFixture.loadAllFromBundle()` 优先读它们。测试台的断言仍然读 `brief-fixture.json`（`fixturePath`），两边互不影响。

**不许动**（各有断言钉着）：

- `SentenceStyle` 的映射：观点句永远 `.neutral`；2 个独立源仍是 `.weak`
- `SwipeActions`：事实句 `[.recheck, .delete]`，其余 `[.delete]`，`buttonWidth == 72`
- `InsufficientState.actions`：只有 `retry` / `another`，没有 `forceDraft`
- `BriefNavigation.back(from:)`：全部回相机
- `DialState.durationSteps`：八档不变

### 0.6 一条纪律

View 文件里**不出现裸 hex、不出现 `.secondary` / `.tertiary` / `.quaternary` / `.borderedProminent` / `.systemBackground`**。颜色来自 `BriefTheme`，字体来自 `BriefTheme.sans(_:_:)` / `BriefTheme.mono(_:_:)`。每个视觉任务收尾都 grep 一次：

```bash
grep -nE '\.secondary|\.tertiary|\.quaternary|\.borderedProminent|systemBackground|Color\(red:|0x[0-9A-Fa-f]{6}' "ios/Pollux One/Features/Brief/<改的文件>.swift"
```

Expected: 无输出。

---

## 一、文件结构

```
ios/Pollux One/
  Domain/Brief/
    BriefPalette.swift            新建 · 全部 hex（纯 Foundation，进测试台）
    DialState.swift               改 · registerName · maxAffordableRegister · snap 0.25
    HandOffState.swift            改 · voicePhase · canProceed
    InsufficientState.swift       改 · found / required / title
    BriefModels.swift             改 · ScriptListRow 字段 · ScriptListGroup
  Support/
    BriefFonts.swift              新建 · CoreText 注册 IBM Plex Mono
    BriefTheme.swift              新建 · Color / Font / Metric token
    Color+Hex.swift               改 · HUDColor.bronze 指向 BriefPalette.accent
  Resources/Fonts/
    IBMPlexMono-Regular.ttf       新建
    IBMPlexMono-Medium.ttf        新建
    OFL.txt                       新建（许可证，随字体一起进 bundle）
  Features/Brief/
    Chrome/BriefTopRow.swift      新建 · BriefTopRow · BackSquare
    Chrome/NewsTagCard.swift      新建 · 替换 NewsTag
    Chrome/BriefButtons.swift     新建 · PrimaryButton · SecondaryButton · TextLinkButton
    Chrome/StageSpinner.swift     新建 · 青铜旋转环
    NewsTag.swift                 删除
    BriefFlow.swift               改 · 去 backBar · 底色 · onBack · selectedScript
    ReviewView.swift              改
    SentenceRow.swift             改
    EvidenceSheet.swift           改
    BriefProgressView.swift       改
    InsufficientView.swift        改
    ConfirmView.swift             改
    DialControl.swift             重写
    HandOffView.swift             重写
  Features/ScriptList/
    ScriptListView.swift          重写
  Features/Recording/
    ShutterRowView.swift          改 · 翻转键吞点击
    （SafeWordIndicatorView 不改：电平表的吞点击在 ShutterRowView 里套一层）
  Pollux_OneApp.swift             改 · 启动注册字体
ios/EngineHarness/BriefScenarios.swift   改 · 新断言
scripts/test-engines.sh                  改 · 加 BriefPalette.swift
README.md                                改 · 当前状态一行
```

---

## Task 1: `BriefPalette` — 颜色契约进测试台

**Files:**
- Create: `ios/Pollux One/Domain/Brief/BriefPalette.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`
- Modify: `scripts/test-engines.sh`

- [ ] **Step 1: 记下基线**

Run: `bash scripts/test-engines.sh 2>&1 | tail -1`
Expected: `══════ TOTAL: N passed, 0 failed ══════`，记下 N。

- [ ] **Step 2: 写断言（先于实现）**

在 `ios/EngineHarness/BriefScenarios.swift` 的 `runBriefSuite()` 里，`return (report.pass, report.fail)` 之前插入：

```swift
    report.section("BriefPalette：界面画的颜色就是 mock 上的颜色")
    report.check(BriefPalette.accent == 0xC49A6C, "主色是 mock 的青铜")
    report.check(BriefPalette.onAccent == 0x14120F, "主按钮上的字是近黑，不是白")
    report.check(BriefPalette.canvas == 0x0D0D0C, "底色是暖黑，不是纯黑")
    report.check(BriefPalette.surface == 0x161512, "抬升面")
    report.check(BriefPalette.border == 0x2B2823, "描边")
    report.check(BriefPalette.hex(for: .strong) == 0x6FA292, "绿：站得住")
    report.check(BriefPalette.hex(for: .weak) == 0xD9A441, "黄：只有一个人这么说")
    report.check(BriefPalette.hex(for: .neutral) == 0x3A362F, "中性线")
    report.check(BriefPalette.danger == 0xC4614F, "警示红")
    report.check(BriefPalette.deleteBg == 0x6E2F26 && BriefPalette.onDelete == 0xF5E8E4, "左滑删除")
    report.check(BriefPalette.recheckBg == 0x2B2823 && BriefPalette.onRecheck == 0xC4C0B8, "左滑重查")
    report.check(BriefPalette.text1 != BriefPalette.text6, "六级文字灰两端不同")
```

- [ ] **Step 3: 跑，确认编译失败**

Run: `bash scripts/test-engines.sh 2>&1 | grep -m1 -E "error:"`
Expected: `error: cannot find 'BriefPalette' in scope`

- [ ] **Step 4: 写实现**

```swift
// ios/Pollux One/Domain/Brief/BriefPalette.swift
import Foundation

/// mock 上的全部颜色，以 hex 存。
///
/// 不含 SwiftUI，所以测试台读得到它——它是「界面画的颜色就是 mock 上的颜色」
/// 这条契约的可断言形态。View 层一律经 `BriefTheme` 取用，不直接写 hex。
/// 每个值后面标了它在 mock 上出现的位置，改之前先去那里核。
enum BriefPalette {
    // MARK: 底与面
    static let canvas: UInt32 = 0x0D0D0C        // 六屏 body 背景
    static let surface: UInt32 = 0x161512       // 卡片、新闻卡、按钮面
    static let surfaceDeep: UInt32 = 0x131210   // ⑤ token 卡
    static let input: UInt32 = 0x0F0E0C         // ③ 输入框、④ 拨盘底
    static let chip: UInt32 = 0x232019          // 新闻卡里的发布方小标签
    static let tabActive: UInt32 = 0x2E2A24     // ③ 选中的 tab
    static let clipboardRow: UInt32 = 0x1E1C18  // ③ 剪贴板条
    static let noteBg: UInt32 = 0x141311        // ⑦ 底部提示条
    static let pillNeutral: UInt32 = 0x1E1C19   // ② 中性计数 pill 的底

    // MARK: 线
    static let border: UInt32 = 0x2B2823        // 返回方块、卡片、次级按钮
    static let borderSoft: UInt32 = 0x262320    // 新闻卡、⑦ 稿卡
    static let borderDeep: UInt32 = 0x26231E    // ④ 拨盘、⑤ token 卡
    static let borderInput: UInt32 = 0x333029   // ③ 输入框
    static let clipboardBorder: UInt32 = 0x38332B
    static let divider: UInt32 = 0x1A1917       // ② 底栏上沿
    static let dividerSoft: UInt32 = 0x201E1A   // ⑤ 卡内分隔、⑦ 进度槽
    static let rule: UInt32 = 0x24221F          // ③「或者」、⑥ 分隔线
    static let barTrack: UInt32 = 0x1F1D19      // ⑤ token 条的槽

    // MARK: 字（六级）
    static let text1: UInt32 = 0xF0EDE7
    static let text2: UInt32 = 0xC4C0B8
    static let text3: UInt32 = 0x9B958B
    static let text4: UInt32 = 0x8A847A
    static let text5: UInt32 = 0x5A554D
    static let text6: UInt32 = 0x4F4A43
    static let textDisabled: UInt32 = 0x6E6961
    static let placeholder: UInt32 = 0x5E5951

    // MARK: 主色
    static let accent: UInt32 = 0xC49A6C        // 与 AccentColor.colorset、HUDColor.bronze 同值
    static let onAccent: UInt32 = 0x14120F
    static let accentMid: UInt32 = 0x8A6A45     // ⑤ token 条第二段
    static let accentDeep: UInt32 = 0x574636    // ⑤ token 条第三段

    // MARK: 语义
    static let strong: UInt32 = 0x6FA292
    static let weak: UInt32 = 0xD9A441
    static let neutralLine: UInt32 = 0x3A362F
    static let danger: UInt32 = 0xC4614F
    static let deleteBg: UInt32 = 0x6E2F26
    static let onDelete: UInt32 = 0xF5E8E4
    static let recheckBg: UInt32 = 0x2B2823
    static let onRecheck: UInt32 = 0xC4C0B8
    static let brokeBg: UInt32 = 0x3A2A26       // ④ 余额不够的按钮
    static let brokeText: UInt32 = 0xE3A99B
    static let cancelText: UInt32 = 0x7A6058    // ⑤ 取消调研

    // MARK: 拨盘与等待
    static let dialGrid: UInt32 = 0x1A1815
    static let dialBracket: UInt32 = 0x34302A
    static let dialScale: UInt32 = 0x423D36
    static let dialAxis: UInt32 = 0x4E4841
    static let presetOff: UInt32 = 0x6B655C
    static let presetLabel: UInt32 = 0x857F75
    static let pendingRing: UInt32 = 0x2E2B26

    /// 语义色 → hex。`SentenceAccent` 的三个颜色只能从这里来。
    static func hex(for accent: SentenceAccent) -> UInt32 {
        switch accent {
        case .strong: strong
        case .weak: weak
        case .neutral: neutralLine
        }
    }
}
```

- [ ] **Step 5: 加进测试台编译列表**

`scripts/test-engines.sh` 里 `"$IOS/Domain/Brief/BriefModels.swift" \` 那一行之后加一行：

```bash
  "$IOS/Domain/Brief/BriefPalette.swift" \
```

- [ ] **Step 6: 跑绿**

Run: `bash scripts/test-engines.sh 2>&1 | tail -1`
Expected: `0 failed`，passed 比 Step 1 多 12。

- [ ] **Step 7: 提交**

```bash
git add "ios/Pollux One/Domain/Brief/BriefPalette.swift" ios/EngineHarness/BriefScenarios.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
Write the mock's colours down where a test can read them

The brief screens were drawn in system placeholder styles because the
plan that built them never named a colour. This puts every hex from the
mock boards into one Foundation-only table the harness compiles, so the
theme layer has a single source and a drift is a failed assertion, not a
screenshot someone has to notice.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 字体与 `BriefTheme`

**Files:**
- Create: `ios/Pollux One/Resources/Fonts/IBMPlexMono-Regular.ttf`、`IBMPlexMono-Medium.ttf`、`OFL.txt`
- Create: `ios/Pollux One/Support/BriefFonts.swift`
- Create: `ios/Pollux One/Support/BriefTheme.swift`
- Modify: `ios/Pollux One/Support/Color+Hex.swift`
- Modify: `ios/Pollux One/Features/Brief/SentenceRow.swift:1-29`
- Modify: `ios/Pollux One/Pollux_OneApp.swift`

- [ ] **Step 1: 拉字体文件**

npm 上的 `@ibm/plex-mono` 只有 woff/woff2，iOS 的 CTFontManager 不认。用 Google Fonts 仓库里的 TTF（同一份 OFL 许可，2026-09-18 验证过可下、PostScript 名正确）：

```bash
mkdir -p "ios/Pollux One/Resources/Fonts"
for f in IBMPlexMono-Regular.ttf IBMPlexMono-Medium.ttf OFL.txt; do
  curl -sSfL -o "ios/Pollux One/Resources/Fonts/$f" \
    "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/$f"
done
ls -la "ios/Pollux One/Resources/Fonts"
fc-scan --format '%{postscriptname}\n' "ios/Pollux One/Resources/Fonts/"*.ttf
```

Expected: 两个 ttf 各约 135KB，`OFL.txt` 约 4.4KB；fc-scan 打出 `IBMPlexMono-Medium` 和 `IBMPlexMono-Regular`。没有 `fc-scan` 就 `brew install fontconfig`，或者用 `file` 看到 "IBM Plex Mono" 也算过。

- [ ] **Step 2: 写字体注册**

```swift
// ios/Pollux One/Support/BriefFonts.swift
import CoreText
import Foundation
import UIKit

/// IBM Plex Mono，mock 上所有数字用的字体。
///
/// 运行时注册，不碰 Info.plist：同步文件夹把 ttf 摊平拷进 bundle 根，
/// 这里只要找得到就注册。注册失败不是崩——`BriefTheme.mono` 会退回 SF Mono。
enum BriefFonts {
    /// PostScript 名，`Font.custom` 认的就是它。
    static let regular = "IBMPlexMono-Regular"
    static let medium = "IBMPlexMono-Medium"

    /// 两个字重都注册成功了才算可用。
    private(set) static var isAvailable = false

    static func register() {
        for name in [regular, medium] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                print("BriefFonts: \(name).ttf 不在 bundle 里")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
               let error = error?.takeRetainedValue() {
                // 重复注册也走这里，不是失败；下面按能不能实例化来判。
                print("BriefFonts: \(name) 注册返回 \(error.localizedDescription)")
            }
        }
        isAvailable = UIFont(name: regular, size: 12) != nil && UIFont(name: medium, size: 12) != nil
        // Task 15 的验收清单要看这一行。
        print("BriefFonts: Plex Mono \(isAvailable ? "可用" : "不可用，退回 SF Mono")")
    }
}
```

- [ ] **Step 3: 写主题层**

```swift
// ios/Pollux One/Support/BriefTheme.swift
import SwiftUI

/// mock 的视觉 token。六屏的 View 只认这里，不认 hex、不认 `.secondary`。
/// 每个颜色都是 `BriefPalette` 里同名那一项——数值只有一份。
enum BriefTheme {
    // MARK: 底与面
    static let canvas = Color(hex: BriefPalette.canvas)
    static let surface = Color(hex: BriefPalette.surface)
    static let surfaceDeep = Color(hex: BriefPalette.surfaceDeep)
    static let input = Color(hex: BriefPalette.input)
    static let chip = Color(hex: BriefPalette.chip)
    static let tabActive = Color(hex: BriefPalette.tabActive)
    static let clipboardRow = Color(hex: BriefPalette.clipboardRow)
    static let noteBg = Color(hex: BriefPalette.noteBg)
    static let pillNeutral = Color(hex: BriefPalette.pillNeutral)

    // MARK: 线
    static let border = Color(hex: BriefPalette.border)
    static let borderSoft = Color(hex: BriefPalette.borderSoft)
    static let borderDeep = Color(hex: BriefPalette.borderDeep)
    static let borderInput = Color(hex: BriefPalette.borderInput)
    static let clipboardBorder = Color(hex: BriefPalette.clipboardBorder)
    static let divider = Color(hex: BriefPalette.divider)
    static let dividerSoft = Color(hex: BriefPalette.dividerSoft)
    static let rule = Color(hex: BriefPalette.rule)
    static let barTrack = Color(hex: BriefPalette.barTrack)

    // MARK: 字
    static let text1 = Color(hex: BriefPalette.text1)
    static let text2 = Color(hex: BriefPalette.text2)
    static let text3 = Color(hex: BriefPalette.text3)
    static let text4 = Color(hex: BriefPalette.text4)
    static let text5 = Color(hex: BriefPalette.text5)
    static let text6 = Color(hex: BriefPalette.text6)
    static let textDisabled = Color(hex: BriefPalette.textDisabled)
    static let placeholder = Color(hex: BriefPalette.placeholder)

    // MARK: 主色
    static let accent = Color(hex: BriefPalette.accent)
    static let onAccent = Color(hex: BriefPalette.onAccent)
    static let accentMid = Color(hex: BriefPalette.accentMid)
    static let accentDeep = Color(hex: BriefPalette.accentDeep)

    // MARK: 语义
    static let strong = Color(hex: BriefPalette.strong)
    static let weak = Color(hex: BriefPalette.weak)
    static let neutralLine = Color(hex: BriefPalette.neutralLine)
    static let danger = Color(hex: BriefPalette.danger)
    static let deleteBg = Color(hex: BriefPalette.deleteBg)
    static let onDelete = Color(hex: BriefPalette.onDelete)
    static let recheckBg = Color(hex: BriefPalette.recheckBg)
    static let onRecheck = Color(hex: BriefPalette.onRecheck)
    static let brokeBg = Color(hex: BriefPalette.brokeBg)
    static let brokeText = Color(hex: BriefPalette.brokeText)
    static let cancelText = Color(hex: BriefPalette.cancelText)

    // MARK: 拨盘与等待
    static let dialGrid = Color(hex: BriefPalette.dialGrid)
    static let dialBracket = Color(hex: BriefPalette.dialBracket)
    static let dialScale = Color(hex: BriefPalette.dialScale)
    static let dialAxis = Color(hex: BriefPalette.dialAxis)
    static let presetOff = Color(hex: BriefPalette.presetOff)
    static let presetLabel = Color(hex: BriefPalette.presetLabel)
    static let pendingRing = Color(hex: BriefPalette.pendingRing)

    /// 语义色。判定在 `SentenceStyle`，这里只翻译。
    static func color(_ accent: SentenceAccent) -> Color {
        Color(hex: BriefPalette.hex(for: accent))
    }

    // MARK: 字体

    enum MonoWeight { case regular, medium }

    /// 所有数字：时长、token、¥、时间戳、计数、时钟。
    /// Plex 没注册上就退回 SF Mono，界面永不因为字体崩。
    static func mono(_ size: CGFloat, _ weight: MonoWeight = .regular) -> Font {
        guard BriefFonts.isAvailable else {
            return .system(size: size, weight: weight == .medium ? .medium : .regular, design: .monospaced)
        }
        return .custom(weight == .medium ? BriefFonts.medium : BriefFonts.regular, size: size)
    }

    /// 中文正文、标题、标签：系统苹方。mock 的 Noto Sans SC 不打包（spec §4.3）。
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: 尺寸（spec §4.4）

    enum Metric {
        static let pagePadding: CGFloat = 24
        static let bottomInset: CGFloat = 40
        static let cardRadius: CGFloat = 14
        static let backButtonSize: CGFloat = 36
        static let backButtonRadius: CGFloat = 9
        static let primaryButtonRadius: CGFloat = 14
        static let primaryButtonPadding: CGFloat = 19
        static let secondaryButtonRadius: CGFloat = 13
        static let secondaryButtonPadding: CGFloat = 16
    }
}
```

- [ ] **Step 4: `HUDColor.bronze` 改为同源**

`ios/Pollux One/Support/Color+Hex.swift` 里：

```swift
    /// #c49a6c — the "九点时光" design system's brand bronze/tan, reused here
    /// for the read-progress rail and the current-line highlight scrim.
    static let bronze = Color(hex: 0xc49a6c)
```

改成：

```swift
    /// mock 的主色，与 `BriefPalette.accent` 和 `AccentColor.colorset` 同一个值。
    /// 相机 HUD 的进度轨和当前行衬底也用它——整个 app 只有这一个青铜。
    static let bronze = Color(hex: BriefPalette.accent)
```

- [ ] **Step 5: `SentenceAccent` 的颜色改从主题取**

`ios/Pollux One/Features/Brief/SentenceRow.swift` 开头那个 `extension SentenceAccent { ... }`（到 `labelBackground` 结束的右花括号）整段替换为：

```swift
extension SentenceAccent {
    /// 句子左边那条线的颜色。neutral 是一条**深色细线**，它只在这个位置成立。
    var color: Color { BriefTheme.color(self) }

    /// 同一个语义用作**文字**时的颜色。
    ///
    /// 和 `color` 分开，是因为 neutral 的 #3A362F 是画线用的深色——拿它写字，
    /// 字和底几乎分不开。strong / weak 是中间调，当线当字都成立。
    var labelColor: Color {
        self == .neutral ? BriefTheme.text3 : color
    }

    /// 文字底衬。neutral 用 mock 上那个 #1E1C19，不是自身的 13%。
    var labelBackground: Color {
        self == .neutral ? BriefTheme.pillNeutral : color.opacity(0.13)
    }
}
```

- [ ] **Step 6: 启动时注册**

`ios/Pollux One/Pollux_OneApp.swift` 整个文件改为：

```swift
//
//  Pollux_OneApp.swift
//  Pollux One
//

import SwiftUI

@main
struct Pollux_OneApp: App {
    @State private var environment = AppEnvironment(backend: MockBackendClient())

    init() {
        // 在任何 View 求值之前。BriefTheme.mono 读的是注册结果。
        BriefFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .preferredColorScheme(.dark)
        }
    }
}
```

- [ ] **Step 7: 编译，并确认字体进了 bundle**

Run（见 §0.3）。Expected: `** BUILD SUCCEEDED **`。然后：

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -type d -name "Pollux One.app" -path "*Build/Products/Debug-iphoneos*" | head -1)
ls "$APP" | grep -E 'IBMPlexMono|OFL'
```

Expected:

```
IBMPlexMono-Medium.ttf
IBMPlexMono-Regular.ttf
OFL.txt
```

没有这三行 = 同步文件夹没把它们当资源。那就打开 Xcode，选中 `Resources/Fonts`，在 File Inspector 里确认 Target Membership 勾了 Pollux One；仍不行就把三个文件移到 `Resources/` 根（`BriefFonts` 用 `Bundle.main.url` 找，不关心子目录）。

- [ ] **Step 8: 测试台仍绿**

Run: `bash scripts/test-engines.sh 2>&1 | tail -1`
Expected: `0 failed`，passed 数与 Task 1 结束时相同（本任务没加 Domain 断言）。

- [ ] **Step 9: 提交**

```bash
git add "ios/Pollux One/Resources/Fonts" "ios/Pollux One/Support/BriefFonts.swift" "ios/Pollux One/Support/BriefTheme.swift" "ios/Pollux One/Support/Color+Hex.swift" "ios/Pollux One/Features/Brief/SentenceRow.swift" "ios/Pollux One/Pollux_OneApp.swift"
git commit -m "$(cat <<'EOF'
Give the brief screens a theme to draw from, and the numbers a typeface

BriefTheme turns the palette into SwiftUI colours and two font
functions; every brief view will read from it instead of naming a hex or
a system semantic colour. IBM Plex Mono ships in the bundle under the
OFL and is registered at launch through CoreText, so nothing in
Info.plist changes and a missing file degrades to SF Mono rather than a
crash. The recording HUD's bronze now points at the same constant.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 共用组件（顶行 · 新闻卡 · 三种按钮 · 旋转环）

**Files:**
- Create: `ios/Pollux One/Features/Brief/Chrome/BriefTopRow.swift`
- Create: `ios/Pollux One/Features/Brief/Chrome/NewsTagCard.swift`
- Create: `ios/Pollux One/Features/Brief/Chrome/BriefButtons.swift`
- Create: `ios/Pollux One/Features/Brief/Chrome/StageSpinner.swift`

这一任务只建组件，没有调用点；Task 4 再接线。先读 mock 里任意一块的顶部两行和底部按钮，对着写。

- [ ] **Step 1: 顶行与返回方块**

```swift
// ios/Pollux One/Features/Brief/Chrome/BriefTopRow.swift
import SwiftUI

/// 每一屏顶上的那一行：36×36 描边返回方块 + 这一屏自己的尾部内容。
///
/// 返回**去哪**不归它管——`BriefFlow` 用 `BriefNavigation.back(from:)` 算好
/// 再把动作传进来，这里只负责画。mock 上每块画板的这一行都是这个形状，
/// 只有尾部不同：新闻卡、标题、计时、字标。
struct BriefTopRow<Trailing: View>: View {
    let onBack: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 11) {
            BackSquare(action: onBack)
            trailing()
        }
        .padding(.horizontal, BriefTheme.Metric.pagePadding)
    }
}

/// mock：36×36，圆角 9，#2B2823 描边，chevron 17pt / 2.2 描边，#9B958B。
/// 没有文字——「相机 / 返回」那两个字是旧返回条的，spec §5 明确去掉。
struct BackSquare: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(BriefTheme.text3)
                .frame(width: BriefTheme.Metric.backButtonSize,
                       height: BriefTheme.Metric.backButtonSize)
                .overlay(
                    RoundedRectangle(cornerRadius: BriefTheme.Metric.backButtonRadius)
                        .stroke(BriefTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回")
    }
}
```

- [ ] **Step 2: 新闻卡**

```swift
// ios/Pollux One/Features/Brief/Chrome/NewsTagCard.swift
import SwiftUI

/// 用户给进来的那条新闻，收成一张卡。②④⑤ 的顶行都靠它。
///
/// mock：surface 底、#262320 边、圆角 9；发布方是 10.5pt 的小 chip；
/// 标题 13pt 单行截断；右侧 chevron。有 `url` 才有 chevron，点了打开——
/// 没有 url 就是一张静态卡，不是一个按下去什么也不发生的按钮。
struct NewsTagCard: View {
    let news: NewsRef
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = news.url.flatMap(URL.init(string:)) {
            Button { openURL(url) } label: { content(showsChevron: true) }
                .buttonStyle(.plain)
                .accessibilityLabel("打开这条新闻：\(news.title)")
        } else {
            content(showsChevron: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func content(showsChevron: Bool) -> some View {
        HStack(spacing: 8) {
            Text(news.publisher)
                .font(BriefTheme.sans(10.5))
                .foregroundStyle(BriefTheme.text3)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(BriefTheme.chip, in: RoundedRectangle(cornerRadius: 4))
            Text(news.title)
                .font(BriefTheme.sans(13))
                .foregroundStyle(BriefTheme.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(BriefTheme.text5)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(BriefTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BriefTheme.borderSoft, lineWidth: 1))
    }
}
```

- [ ] **Step 3: 三种按钮**

```swift
// ios/Pollux One/Features/Brief/Chrome/BriefButtons.swift
import SwiftUI

/// 青铜主按钮。mock：#C49A6C 底、#14120F 字、17pt 700、内边距 19、圆角 14。
///
/// 三个变体都来自 mock 上真的出现过的样子，不多不少：
/// - 禁用（③ 空输入）：#2B2823 底、#6E6961 字
/// - `.broke`（④ 余额不够）：#3A2A26 底、#E3A99B 字，且不可点
/// - `.compact`（③ 卡片里那枚）：15pt、内边距 15、圆角 11
struct PrimaryButton: View {
    enum Tone { case accent, broke }
    enum Size { case regular, compact }

    let title: String
    var icon: String? = nil
    var tone: Tone = .accent
    var size: Size = .regular
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: size == .regular ? 19 : 17, weight: .semibold))
                }
                Text(title)
                    .font(BriefTheme.sans(size == .regular ? 17 : 15, .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, size == .regular ? BriefTheme.Metric.primaryButtonPadding : 15)
            .background(background, in: RoundedRectangle(
                cornerRadius: size == .regular ? BriefTheme.Metric.primaryButtonRadius : 11))
            .foregroundStyle(foreground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || tone == .broke)
    }

    private var background: Color {
        switch tone {
        case .broke: BriefTheme.brokeBg
        case .accent: isEnabled ? BriefTheme.accent : BriefTheme.border
        }
    }

    private var foreground: Color {
        switch tone {
        case .broke: BriefTheme.brokeText
        case .accent: isEnabled ? BriefTheme.onAccent : BriefTheme.textDisabled
        }
    }
}

/// 描边次级按钮。mock：#2B2823 边、#9B958B 字、15pt、内边距 16、圆角 13。
struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BriefTheme.sans(15))
                .foregroundStyle(BriefTheme.text3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BriefTheme.Metric.secondaryButtonPadding)
                .overlay(
                    RoundedRectangle(cornerRadius: BriefTheme.Metric.secondaryButtonRadius)
                        .stroke(BriefTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 一行灰字当按钮。⑤「取消调研 · 已消耗的 48K 不退」是它。
struct TextLinkButton: View {
    let title: String
    var tint: Color = BriefTheme.text5
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BriefTheme.sans(12))
                .foregroundStyle(tint)
                .frame(minHeight: 44)   // 触达面积，不是视觉高度
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 4: 旋转环**

```swift
// ios/Pollux One/Features/Brief/Chrome/StageSpinner.swift
import SwiftUI

/// mock 上那个缺一角的青铜圆环，1.1 秒一圈。替换系统 `ProgressView`：
/// 系统那个是白的、有自己的尺寸，放在青铜卡片里像借来的。
struct StageSpinner: View {
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.5
    var tint: Color = BriefTheme.accent

    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.25, to: 1)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .onDisappear { spinning = false }
            .accessibilityLabel("进行中")
    }
}
```

- [ ] **Step 5: 编译**

Run（§0.3）。Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Features/Brief/Chrome"
git commit -m "$(cat <<'EOF'
Build the pieces every brief screen shares

A bordered back square with no caption, a news card that is only a
button when there is somewhere to go, three button shapes lifted from
the mock and a bronze spinner. No screen uses them yet; the next change
wires them in so each screen's own rewrite has something to stand on.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 接线 —— `BriefFlow` 去掉返回条，六屏各自长出顶行，⑦ 拆掉自带导航

**Files:**
- Modify: `ios/Pollux One/Features/Brief/BriefFlow.swift`（整文件替换）
- Modify: `ios/Pollux One/Features/ScriptList/ScriptListView.swift`（整文件替换）
- Modify: `ios/Pollux One/Features/Brief/ReviewView.swift`、`ConfirmView.swift`、`BriefProgressView.swift`、`HandOffView.swift`、`InsufficientView.swift`（各两处小改）
- Delete: `ios/Pollux One/Features/Brief/NewsTag.swift`

这一步只改结构，不换皮：每屏拿到一个 `onBack`，用 `BriefTopRow` 顶替旧的 `NewsTag`；`BriefFlow` 的 `backBar` 删掉、底色换成 canvas；⑦ 不再自带 `NavigationStack`，选 Web 稿不再 push 第二个相机。

**返回语义**：每屏拿到的 `onBack` 只能是 `BriefFlow.back(from:)` 产出的闭包。屏没有 `screen` 状态、也不在 NavigationStack 里，`dismiss()` 在这里什么也不做，所以屏自己没有办法「回上一屏」。`BriefFlow.screenContent` 里六处 `back(from:)` 是这条规矩现在的全部——**不要在那里手写 `screen = …` 当返回**（spec §5）。Task 5–13 逐屏重写时会再次给出完整文件，这里的小改是为了让每一步都能编译。

- [ ] **Step 1: 替换 `BriefFlow.swift`**

```swift
import SwiftUI

/// 七屏串起来的那个容器。全程零网络：数据全部来自 bundle 里的
/// `demo-briefs/`（没有那个目录时退回单份 `brief-fixture.json`）。
///
/// 三条规矩，这一层存在的理由就是守住它们：
///
/// 1. **去哪由 `ScriptSlot(brief:)` 决定**，不是由这里的 if。四种状态各自
///    已经在测试台上钉死了，这里再写一遍等于多一处会漂的判断。
/// 2. **返回一律走 `BriefNavigation.back(from:)`**。那个纯函数存在的全部理由
///    是不让「审稿页回不到等待页」这一条在某次重构里悄悄退化——所以这里
///    一行自己的返回逻辑都没有。每屏的返回方块拿到的动作都从 `back(from:)` 来。
/// 3. **相机不卸载**。它是根：Brief 的屏是盖在它上面的一层，不是把它替掉的
///    另一棵树。`SessionManager` 也因此不必在每次盖住时重启取景器。
struct BriefFlow: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var screen: BriefScreen = .camera
    /// bundle 里所有能解开的稿，按 id 排好。⑦「换一篇」画的就是这一份。
    @State private var briefs: [Brief] = []
    /// **当前选中的是哪一篇，只记 id，不记副本。**
    /// 记 id 的理由：稿会被改（删句、重查），副本会立刻过期，而 id 不会。
    /// 于是"当前那一份"永远是 `briefs` 里的活数据，串不到别的稿上去。
    ///
    /// id 指向的稿可以**不在** `briefs` 里——取消调研就是这个状态：那一篇被
    /// 拿走了（右下角那一格因此回到「交给我」），但 id 还留着，④ 再确认一次
    /// 就能把同一篇重放。
    @State private var currentID: String?
    /// 刚从 bundle 读出来的那几份，一直留着。取消调研之后要靠它们把演示重放
    /// 一遍：fixture 是这个 app 目前唯一的"上游"，扔了就再也长不回来。
    @State private var pristine: [String: Brief] = [:]
    @State private var loadError: String?
    /// 用户在 ③ 交给我那一屏打的字。它还变不成一篇 Brief——没有管线——
    /// 所以只用来给 ④ 确认页那条标签，让人看见自己交进来的是什么。
    @State private var handedOff: NewsRef?
    @State private var researchStartedAt: Date?
    @State private var elapsed = "00:00"
    /// ⑦ 里点中的 Web 稿。交给根上的相机，由 `RecordingView` 的
    /// `.task(id: script?.id)` 走一次 `prepare(script:)`。这里**不**自己调
    /// prepare——那会让同一篇稿被装两遍。
    @State private var selectedScript: Script?

    /// 阶段之间的间隔。挑 1.5 秒是因为它要同时装下两件事：慢到能读清刚亮起来
    /// 的那一行，快到九个阶段走完不至于让人放下手机。
    private static let stageInterval = Duration.seconds(1.5)

    // MARK: - 当前那一份

    /// 当前选中的稿，没有选中（或选中的那篇刚被取消掉）时是 nil。
    private var current: Brief? {
        guard let currentID else { return nil }
        return briefs.first { $0.id == currentID }
    }

    /// 写回**对应的那一份**。ReviewView 改的是这个 Binding，所以删句、重查
    /// 落在 `briefs` 里的同一条上，不会溅到别的稿。
    private var currentBinding: Binding<Brief>? {
        guard let id = currentID, let snapshot = current else { return nil }
        return Binding(
            get: { briefs.first { $0.id == id } ?? snapshot },
            set: { updated in
                guard let index = briefs.firstIndex(where: { $0.id == id }) else { return }
                briefs[index] = updated
            }
        )
    }

    /// 有就替换，没有就插回去并保持 id 序——顺序是这一屏唯一的稳定点。
    private func upsert(_ brief: Brief) {
        if let index = briefs.firstIndex(where: { $0.id == brief.id }) {
            briefs[index] = brief
        } else {
            briefs.append(brief)
            briefs.sort { $0.id < $1.id }
        }
    }

    var body: some View {
        ZStack {
            // 相机是根，永远在这里。Brief 的屏盖在它上面。
            RecordingView(
                script: selectedScript ?? environment.sessionManager.scriptRevision?.script,
                sessionManager: environment.sessionManager,
                brief: current,
                onOpenBrief: { screen = $0 }
            )

            if screen != .camera {
                screenContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(BriefTheme.canvas)
                    // 底部动作区距物理底边 40（spec §4.4），不再叠 home indicator
                    // 的安全区；顶部仍贴安全区——mock 的 56 就是 Dynamic Island
                    // 机型那一段的高度。
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: screen)
        // 审稿时把最后一句也删掉，Brief.deletingSentence 会把 status 降成
        // .insufficient。那一刻这一屏就不该再是审稿页——留在一个空的审稿页
        // 上，等于让一篇播不了的稿继续看起来像能播。
        .onChange(of: current?.status) { _, status in
            if status == .insufficient, screen == .review {
                screen = .insufficient
            }
        }
        .task { loadBriefs() }
        // 定时器挂在屏上而不是挂在对象上：离开等待页，结构化并发自己把它取消，
        // 不必再记得去 invalidate 一个还攥在手里的 Timer。
        .task(id: screen) { await runStageClock() }
    }

    // MARK: - 盖在相机上的那一层

    /// 每一屏的返回方块拿到的动作。含义由 `BriefNavigation` 说了算，
    /// 这里一行自己的返回逻辑都没有。
    private func back(from origin: BriefScreen) -> () -> Void {
        { screen = BriefNavigation.back(from: origin) }
    }

    @ViewBuilder
    private var screenContent: some View {
        switch screen {
        case .camera:
            EmptyView()

        case .handOff:
            HandOffView(
                onBack: back(from: .handOff),
                onSubmit: { state in
                    handedOff = NewsRef(
                        publisher: "你交给我的",
                        title: state.text.isEmpty ? "口述的一条新闻" : state.text,
                        url: nil
                    )
                    screen = .confirm
                }
            )

        case .confirm:
            // 余额门禁就在这一屏，因为这是烧 token 之前的最后一屏。
            ConfirmView(
                news: confirmNews,
                dial: DialState(remainingTokens: current?.budget.remainingThisMonth
                                ?? replayBase?.budget.remainingThisMonth ?? .max),
                onBack: back(from: .confirm),
                onStart: { _ in startResearch() }
            )

        case .progress:
            if let brief = current {
                BriefProgressView(
                    brief: brief,
                    elapsed: elapsed,
                    onBack: back(from: .progress),
                    // 离开不毁任务：回相机，调研（在真实实现里）继续跑。
                    onLeave: back(from: .progress),
                    onCancel: { cancelResearch() }
                )
            } else {
                missing
            }

        case .review:
            // currentBinding 按 id 定位到 briefs 里的那一条，于是删句、重查
            // 写回的是对应的那一份，而不是死在 ReviewView 自己的副本里、
            // 也不会溅到别的稿上。
            if let bound = currentBinding {
                ReviewView(
                    brief: bound,
                    onBack: back(from: .review),
                    // 开拍就是回相机——它一直在下面开着，这里只是把这一层收掉。
                    // 提词器要等 Brief 真的能变成一篇 Script 才有东西可放，那是
                    // 管线那一段的事；现在按下去得到的是一台干净的相机。
                    onRecord: { screen = .camera },
                    onSwitchScript: { screen = .scripts }
                )
                .id(bound.wrappedValue.id)
            } else {
                missing
            }

        case .insufficient:
            if let brief = current {
                InsufficientView(
                    news: brief.news,
                    state: insufficientState(for: brief),
                    reason: brief.insufficientReason,
                    onBack: back(from: .insufficient),
                    onAction: { action in
                        switch action.id {
                        case "retry": startResearch()
                        default: screen = .handOff
                        }
                    }
                )
            } else {
                missing
            }

        case .scripts:
            // 列表是 Brief + Script 的合并流，所以在跑的那一条也在里面。
            ScriptListView(
                syncService: environment.syncService,
                briefs: briefs,
                elapsed: elapsed,
                onBack: back(from: .scripts),
                onSelect: { currentID = $0.id },
                onOpen: { screen = $0 },
                // 选一篇 Web 稿 = 把它交给根上的相机并收掉这一层。相机的
                // `.task(id:)` 看见 script 变了，自己去装。
                onSelectScript: { script in
                    selectedScript = script
                    screen = .camera
                }
            )
        }
    }

    private var missing: some View {
        ContentUnavailableView(
            "没有可看的稿",
            systemImage: "doc.text",
            description: Text(loadError ?? "fixture 没读进来")
        )
    }

    private var confirmNews: NewsRef {
        handedOff ?? current?.news ?? NewsRef(publisher: "待查", title: "一条新闻", url: nil)
    }

    /// `found` 取所有事实点里最硬的那一个的独立源数——说"最多也只有这么多"，
    /// 比把各句的数字加起来诚实：加起来会把同一个源数两遍。
    private func insufficientState(for brief: Brief) -> InsufficientState {
        InsufficientState(
            found: brief.claims.values.map(\.independence).max() ?? 0,
            required: ClaimEvidence.strongThreshold,
            tokensUsed: brief.budget.used
        )
    }

    // MARK: - 状态迁移

    private func loadBriefs() {
        guard briefs.isEmpty, pristine.isEmpty else { return }
        let loaded = BriefFixture.loadAllFromBundle()
        guard !loaded.isEmpty else {
            // 读不到就是没有稿，不是崩：相机照常开，右下角那一格显示「交给我」。
            loadError = "demo-briefs/ 和 brief-fixture.json 都没读到"
            return
        }
        briefs = loaded
        pristine = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 进来先站在第一篇上。顺序是 id 序，所以"第一篇"每次启动都是同一篇。
        currentID = loaded.first?.id
    }

    /// 重放用的底稿：优先当前选中那一篇的原样，其次当前这一份，最后退到第一篇。
    /// 不写成 `pristine.values.first`——字典是无序的，那会让 ④ 每次给出不同的余额。
    private var replayBase: Brief? {
        if let currentID, let original = pristine[currentID] { return original }
        return current ?? briefs.first
    }

    /// ④ → ⑤。每次都从 fixture 那一刻重放，否则第二次进来时九个阶段已经全绿，
    /// 等待页会一闪而过——那不是这一屏要给人看的东西。
    private func startResearch() {
        guard var next = replayBase else {
            screen = BriefNavigation.back(from: screen)
            return
        }
        next.status = .researching
        next.stages = (pristine[next.id] ?? next).stages
        upsert(next)
        currentID = next.id
        researchStartedAt = Date()
        elapsed = "00:00"
        screen = .progress
    }

    /// 取消是真的取消：任务没了，这一篇也从列表里没了，花掉的不退（那句话
    /// 写在按钮上）。右下角那一格随之回到「交给我」，整条无稿路径因此可以
    /// 再走一遍。`currentID` 故意留着不清：它是"④ 再确认一次要重放哪一篇"
    /// 的唯一线索，别的稿一根毫毛都没动。
    private func cancelResearch() {
        if let currentID { briefs.removeAll { $0.id == currentID } }
        researchStartedAt = nil
        screen = BriefNavigation.back(from: .progress)
    }

    /// 本地定时器，只在等待页上跑。
    ///
    /// 它推的是 `Brief.advancingStages()`——计数一律沿用 fixture 里已有的值，
    /// 没有的就保持 nil，界面那一行因此什么也不写。**绝不给未开始的阶段补 0**：
    /// 0 读起来像「挖到了 0 条」，比不显示坏得多。
    private func runStageClock() async {
        guard screen == .progress else { return }
        let startedAt = researchStartedAt ?? Date()
        if researchStartedAt == nil { researchStartedAt = startedAt }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.stageInterval)
            } catch {
                return // 离开这一屏了
            }
            guard !Task.isCancelled, screen == .progress, let running = current else { return }

            elapsed = Self.clock(Date().timeIntervalSince(startedAt))
            let advanced = running.advancingStages()
            // 推回它自己那一格，不是推回"第一篇"。
            upsert(advanced)

            if advanced.status != .researching {
                // 跑完落回审稿页。从这里往回按到不了等待页——那一屏不复存在，
                // 这正是 BriefNavigation.canReturnToProgress(from: .review) 说的。
                screen = .review
                return
            }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
```

- [ ] **Step 2: 替换 `ScriptListView.swift`（拆导航；卡片样式留给 Task 13）**

```swift
import SwiftUI

/// ⑦ 换一篇。只从 ② 的「换一篇」进，不在主路径上——低频的东西不该挡高频的路。
///
/// spec §9.2 ②：列表是 **Brief + Script 的合并流**。一篇还在调研的 Brief 还不是
/// Script，`viewModel.scripts` 装不下它——只画 scripts 就会悄悄漏掉用户此刻
/// 最想看的那一条。合并与排序都在 `ScriptListRows` 里，这里只负责画。
///
/// 这一屏由 `BriefFlow` 盖在相机上，所以**没有自己的 NavigationStack**：
/// 返回是顶行那个方块，标题写在它旁边。选一篇 Web 稿不再 push 第二个相机，
/// 而是把稿交回去（`onSelectScript`），根上的那台相机自己装。
struct ScriptListView: View {
    @State private var viewModel: ScriptListViewModel
    private let syncService: ScriptSyncService
    /// 还没有变成 Script 的那些——在跑的、可审的、信源不足的。
    private let briefs: [Brief]
    /// 在跑的那一篇已经跑了多久，`BriefFlow` 的时钟。
    private let elapsed: String
    private let onBack: () -> Void
    /// 点中了哪一条 Brief。列表里不止一条，所以"去哪一屏"之外还得说清
    /// "看的是哪一篇"——容器靠这一下把当前选中切过去。
    private let onSelect: (Brief) -> Void
    /// 跳去 Brief 那一侧的屏（「从一条新闻开始」，以及点一条 Brief）。
    private let onOpen: (BriefScreen) -> Void
    /// 点中了一篇 Web 稿：交给根上的相机去装。
    private let onSelectScript: (Script) -> Void

    init(syncService: ScriptSyncService,
         briefs: [Brief] = [],
         elapsed: String = "00:00",
         onBack: @escaping () -> Void = {},
         onSelect: @escaping (Brief) -> Void = { _ in },
         onOpen: @escaping (BriefScreen) -> Void = { _ in },
         onSelectScript: @escaping (Script) -> Void = { _ in }) {
        self.syncService = syncService
        self.briefs = briefs
        self.elapsed = elapsed
        self.onBack = onBack
        self.onSelect = onSelect
        self.onOpen = onOpen
        self.onSelectScript = onSelectScript
        _viewModel = State(wrappedValue: ScriptListViewModel(syncService: syncService))
    }

    /// 同 id 的两份只留先到的那一份。加载器已经去过重，这里再挡一道，
    /// 是因为 `uniqueKeysWithValues` 撞键会直接崩——列表不该有这种雷。
    private var briefsByID: [String: Brief] {
        Dictionary(briefs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var scriptsByID: [String: Script] {
        Dictionary(uniqueKeysWithValues: viewModel.scripts.map { ($0.id.uuidString, $0) })
    }

    private var rows: [ScriptListRow] {
        ScriptListRows.build(
            scriptTitles: viewModel.scripts.map {
                (id: $0.id.uuidString, title: $0.title, seconds: Self.estimatedSeconds($0))
            },
            briefs: briefs
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            BriefTopRow(onBack: onBack) {
                Text("换一篇")
                    .font(BriefTheme.sans(19, .bold))
                    .foregroundStyle(BriefTheme.text1)
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 创建是低频动作，但它得有入口。原先只在空状态和工具栏里露面，
                    // 有稿的人就再起不了一篇。
                    PrimaryButton(title: "从一条新闻开始", icon: "plus") { onOpen(.handOff) }
                        .padding(.horizontal, BriefTheme.Metric.pagePadding)
                        .padding(.top, 22)

                    if viewModel.isLoading && rows.isEmpty {
                        loading
                    } else if rows.isEmpty {
                        note(ScriptListEmptyState().text)
                    } else {
                        list
                    }
                }
            }
            .refreshable { await viewModel.refresh() }
        }
        .task { await viewModel.onAppear() }
    }

    /// Task 13 会把这一段换成「正在调研 / 可以拍了 / 信源不足」三组卡片。
    /// 这一步先让列表在新的导航结构里活着。
    private var list: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(rows) { row in
                Button { open(row) } label: { ScriptListRowView(row: row) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, BriefTheme.Metric.pagePadding)
        .padding(.top, 28)
    }

    private func open(_ row: ScriptListRow) {
        if let brief = briefsByID[row.id] {
            // 先切当前，再跳屏：跳过去那一屏读的就是这一篇。
            onSelect(brief)
            onOpen(ScriptSlot(brief: brief).destination)
        } else if let script = scriptsByID[row.id] {
            onSelectScript(script)
        }
    }

    private var loading: some View {
        HStack(spacing: 10) {
            StageSpinner(size: 14, lineWidth: 2.2)
            Text("正在同步稿子…")
                .font(BriefTheme.sans(13))
                .foregroundStyle(BriefTheme.text3)
        }
        .padding(BriefTheme.Metric.pagePadding)
    }

    /// 底部那条提示。mock：#141311 底、圆角 10、chevron + 12pt 灰字。
    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BriefTheme.text4)
                .padding(.top, 2)
            Text(text)
                .font(BriefTheme.sans(12))
                .foregroundStyle(BriefTheme.text4)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(BriefTheme.noteBg, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, BriefTheme.Metric.pagePadding)
        .padding(.top, 28)
        .padding(.bottom, BriefTheme.Metric.bottomInset)
    }

    /// 列表上的秒数按语种的默认语速估，不是按这个用户自己的语速——
    /// 后者要等他真的读过一遍才有（spec §9.2 ①）。
    private static func estimatedSeconds(_ script: Script) -> Int {
        let text = script.fullText
        let rate = ScriptLanguage.detect(text).defaultCharactersPerSecond
        return max(1, Int((Double(text.count) / rate).rounded()))
    }
}

private struct ScriptListRowView: View {
    let row: ScriptListRow

    var body: some View {
        HStack(spacing: 10) {
            if row.isResearching { StageSpinner(size: 14, lineWidth: 2.2) }
            VStack(alignment: .leading, spacing: 7) {
                Text(row.title)
                    .font(BriefTheme.sans(15))
                    .foregroundStyle(BriefTheme.text1)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(BriefTheme.mono(11.5))
                    .foregroundStyle(BriefTheme.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15))
        .background(BriefTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BriefTheme.borderSoft, lineWidth: 1))
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 3: 五个 View 各加 `onBack`、换顶行**

`ReviewView.swift`：`@Binding var brief: Brief` 之后加一行 `let onBack: () -> Void`；body 里 `NewsTag(news: brief.news)` 换成

```swift
            BriefTopRow(onBack: onBack) { NewsTagCard(news: brief.news) }
```

`ConfirmView.swift`：`let news: NewsRef` 之后加 `let onBack: () -> Void`；init 改成

```swift
    init(news: NewsRef, dial: DialState = DialState(),
         onBack: @escaping () -> Void, onStart: @escaping (DialState) -> Void) {
        self.news = news
        _dial = State(initialValue: dial)
        self.onBack = onBack
        self.onStart = onStart
    }
```

body 里 `NewsTag(news: news)` 换成 `BriefTopRow(onBack: onBack) { NewsTagCard(news: news) }`。

`BriefProgressView.swift`：`let elapsed: String` 之后加 `let onBack: () -> Void`；body 开头那个 `HStack { NewsTag(...); Text(elapsed)... }` 整个换成

```swift
            BriefTopRow(onBack: onBack) {
                NewsTagCard(news: brief.news)
                Text(elapsed)
                    .font(BriefTheme.mono(14))
                    .foregroundStyle(BriefTheme.accent)
            }
```

`HandOffView.swift`：`@State private var state: HandOffState` 之后加 `let onBack: () -> Void`；init 签名改成 `init(state: HandOffState = HandOffState(), onBack: @escaping () -> Void, onSubmit: ..., onPasteClipboard: ..., onScreenshot: ..., onShareSheet: ...)` 并在体内加 `self.onBack = onBack`；body 的 VStack 里 `modePicker` 之前插一行

```swift
            BriefTopRow(onBack: onBack) { Spacer(minLength: 0) }
```

`InsufficientView.swift`：`let reason: String?` 之后加 `let onBack: () -> Void`（放在 `reason` 之后、`onAction` 之前——memberwise init 的参数顺序要和 `BriefFlow` 的调用一致）；body 里 `NewsTag(news: news)` 换成 `BriefTopRow(onBack: onBack) { Spacer(minLength: 0) }`。

- [ ] **Step 4: 删掉 `NewsTag`**

```bash
git rm "ios/Pollux One/Features/Brief/NewsTag.swift"
grep -rn "NewsTag(" "ios/Pollux One" --include='*.swift'
```

Expected: grep 无输出（`NewsTagCard(` 不匹配 `NewsTag(`）。

- [ ] **Step 5: 编译、测试台**

Run（§0.3）。Expected: `** BUILD SUCCEEDED **`。
Run: `bash scripts/test-engines.sh 2>&1 | tail -1`。Expected: `0 failed`，passed 数不变。

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Features/Brief" "ios/Pollux One/Features/ScriptList/ScriptListView.swift"
git commit -m "$(cat <<'EOF'
Give each brief screen its own top row, and the list one less navigator

The flow used to draw one caption-bearing back bar over every screen;
now each screen owns a bordered back square and whatever the mock puts
beside it. 换一篇 loses its NavigationStack, large title and toolbar,
which had stacked a second header under the flow's own, and choosing a
web script hands it back to the root camera instead of pushing a second
one on top.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: ② 审稿页换皮

**Files:**
- Modify: `ios/Pollux One/Features/Brief/ReviewView.swift`（整文件替换）
- Modify: `ios/Pollux One/Features/Brief/SentenceRow.swift`（整文件替换）
- Modify: `ios/Pollux One/Features/Brief/EvidenceSheet.swift`（整文件替换）

- [ ] **Step 1: 读 mock**

Artifact 工具读 `project/Review.dc.html`。对照下面三处再动手：句子行的 `margin-left: 22px` / `border-left: 2px` / `padding-left: 12px`；观点句 `border-left: 2px dashed #3A362F` + `font-style: italic` + `color: #C4C0B8`；展开那一行的 `background: rgba(111,162,146,0.05)`。

- [ ] **Step 2: 替换 `ReviewView.swift`**

```swift
import SwiftUI

/// ② 当前稿件详情 = 审稿。spec §9.2 ②：一个 View 两个入口
/// （相机进 / 调研完成落回），不是两屏。
struct ReviewView: View {
    /// 绑定而不是 @State：删句要传回 BriefFlow。持一份局部副本的话，
    /// 删除会在离开这一屏时无声丢失，而且把整篇删空时算出的
    /// `status = .insufficient` 没有人读得到——空稿仍旧标着「可播」，
    /// 正是 Brief.deletingSentence 那条断言要防的状态。
    @Binding var brief: Brief
    let onBack: () -> Void
    let onRecord: () -> Void
    let onSwitchScript: () -> Void

    /// 哪几行正在重查 / 刚查完没找到。按句 id 存，因为重查是一行一行的，
    /// 一次查 s4 不该让 s3 也转起来。
    @State private var recheckPhases: [String: RecheckPhase] = [:]

    /// 假装一次上游查询要用掉的时间。真管线接上之后这个数字会被真正的
    /// 往返替掉，但那一行「重查中…」和它两头的状态不用重写。
    private static let recheckDuration = Duration.milliseconds(1200)
    /// 「没有找到新的信源」停留多久。够看清，又不至于赖在那里。
    private static let foundNothingDuration = Duration.milliseconds(1800)

    private var counts: SentenceCounts { SentenceCounts(brief.sentences, claims: brief.claims) }

    var body: some View {
        VStack(spacing: 0) {
            BriefTopRow(onBack: onBack) { NewsTagCard(news: brief.news) }
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(brief.sentences) { sentence in
                        SwipeableSentenceRow(
                            sentence: sentence,
                            claims: brief.claims,
                            recheckPhase: recheckPhases[sentence.id] ?? .idle,
                            onDelete: { brief = brief.deletingSentence(sentence.id) },
                            onRecheck: { recheck(sentence.id) }
                        )
                    }
                }
            }
            bottomBar
        }
    }

    /// 重查一行。结果由 `Brief.recheckOutcome(forSentence:)` 定，这里只负责
    /// 让它在时间上看得见：先转一会儿，再落到两个结果之一。
    ///
    /// 两条路径都必须在界面上留下痕迹。查到了就换证据、标签当场改口；
    /// 没查到就明说「没有找到新的信源」——它和一个按下去什么也不发生的按钮
    /// 在像素上一度是同一个样子，而那正是这个按钮之前的毛病。
    private func recheck(_ sentenceId: String) {
        guard recheckPhases[sentenceId] != .running else { return }  // 别叠着查
        withAnimation(.easeInOut(duration: 0.18)) { recheckPhases[sentenceId] = .running }

        Task {
            try? await Task.sleep(for: Self.recheckDuration)
            switch brief.recheckOutcome(forSentence: sentenceId) {
            case .improved:
                withAnimation(.snappy) {
                    // 写回 @Binding：新的证据要留在 BriefFlow 手里，
                    // 否则离开这一屏，刚查到的信源就没了。
                    brief = brief.applyingRecheck(forSentence: sentenceId)
                    recheckPhases[sentenceId] = .idle
                }
            case .unchanged:
                withAnimation(.easeInOut(duration: 0.18)) {
                    recheckPhases[sentenceId] = .foundNothing
                }
                try? await Task.sleep(for: Self.foundNothingDuration)
                withAnimation(.easeInOut(duration: 0.18)) { recheckPhases[sentenceId] = .idle }
            case .notApplicable:
                // 按钮根本没在这种句子上露出来（`SwipeActions(for:)`）。
                // 真走到这里就安静收场，不要编一句「没找到」——它没查过。
                recheckPhases[sentenceId] = .idle
            }
        }
    }

    /// mock：29pt mono「83」+ 13pt「秒 · 按你的语速」；右侧三枚胶囊。
    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(brief.estimatedSeconds)")
                    .font(BriefTheme.mono(29))
                    .kerning(-0.6)
                    .foregroundStyle(BriefTheme.text1)
                // pacedToUser 为假时不许写「按你的语速」——spec §9.2 ① 说新用户
                // 的第一篇必然是语种默认值，文案先于数据到场就是在撒谎。
                Text(brief.pacedToUser ? "秒 · 按你的语速" : "秒")
                    .font(BriefTheme.sans(13))
                    .foregroundStyle(BriefTheme.text4)
            }
            Spacer()
            HStack(spacing: 7) {
                CountPill(value: counts.strong, accent: .strong)
                CountPill(value: counts.weak, accent: .weak)
                CountPill(value: counts.unsourced, accent: .neutral)
            }
        }
        .padding(.horizontal, BriefTheme.Metric.pagePadding)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// mock：上沿 1pt 分隔线；54pt 宽描边方块「换一篇」；青铜「开拍」带摄像机图标。
    private var bottomBar: some View {
        HStack(spacing: 11) {
            Button(action: onSwitchScript) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(BriefTheme.text3)
                    .frame(width: 54)
                    .frame(maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(BriefTheme.border, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("换一篇稿")
            PrimaryButton(title: "开拍", icon: "video", action: onRecord)
        }
        // 让 54pt 那块跟着主按钮的高度长，而不是各自为政。
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, BriefTheme.Metric.pagePadding)
        .padding(.top, 14)
        .padding(.bottom, BriefTheme.Metric.bottomInset)
        .overlay(alignment: .top) {
            Rectangle().fill(BriefTheme.divider).frame(height: 1)
        }
    }
}

/// 顶部那三枚计数胶囊。颜色语义与句子左边线同源；neutral 的字色和底
/// 走 `labelColor` / `labelBackground`——那条线的深色写成字读不出来。
struct CountPill: View {
    let value: Int
    let accent: SentenceAccent

    var body: some View {
        Text("\(value)")
            .font(BriefTheme.mono(11.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(accent.labelBackground, in: Capsule())
            .foregroundStyle(accent.labelColor)
    }
}
```

- [ ] **Step 3: 替换 `SentenceRow.swift`**

```swift
import SwiftUI

extension SentenceAccent {
    /// 句子左边那条线的颜色。neutral 是一条**深色细线**，它只在这个位置成立。
    var color: Color { BriefTheme.color(self) }

    /// 同一个语义用作**文字**时的颜色。
    ///
    /// 和 `color` 分开，是因为 neutral 的 #3A362F 是画线用的深色——拿它写字，
    /// 字和底几乎分不开。strong / weak 是中间调，当线当字都成立。
    var labelColor: Color {
        self == .neutral ? BriefTheme.text3 : color
    }

    /// 文字底衬。neutral 用 mock 上那个 #1E1C19，不是自身的 13%。
    var labelBackground: Color {
        self == .neutral ? BriefTheme.pillNeutral : color.opacity(0.13)
    }
}

/// 一行在重查上的瞬时状态。只活在界面里——查得到查不到由
/// `Brief.recheckOutcome(forSentence:)` 说了算，这里只决定这一秒画什么。
enum RecheckPhase: Equatable {
    case idle
    case running
    /// 查完了，没有新的。要说出口——按下去毫无动静和「没找到」是两回事。
    case foundNothing
}

/// 一根竖线，可虚可实。CSS 的 `border-left: 2px dashed` 在 SwiftUI 里没有现成物，
/// 观点句那条虚线边靠它画。之前用「实线 50% 透明」代替，那不是 mock 上的东西。
struct VerticalRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

struct SentenceRow: View {
    let sentence: BriefSentence
    let claims: [String: ClaimEvidence]
    var recheckPhase: RecheckPhase = .idle
    @State private var isExpanded = false

    private var style: SentenceStyle { SentenceStyle(sentence: sentence, claims: claims) }
    private var runs: AnchorRuns { AnchorRuns(sentence) }
    private var accentColor: Color { style.accent.color }
    /// 一句挂多个 claim 时，展开面板显示最弱的那个——它才是这句的强度。
    private var weakestClaim: ClaimEvidence? {
        sentence.claimIds.compactMap { claims[$0] }.min { $0.independence < $1.independence }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            accentBar
            VStack(alignment: .leading, spacing: 8) {
                text
                if let claim = weakestClaim {
                    evidenceToggle(claim)
                    if isExpanded { EvidenceSheet(claim: claim) }
                } else if sentence.kind == .opinion {
                    Text("你的判断 · 无信源")
                        .font(BriefTheme.mono(11))
                        .foregroundStyle(BriefTheme.text4)
                }
                recheckNote
            }
        }
        // mock：margin-left 22 + border 2 + padding-left 12；右侧页边 24。
        .padding(.leading, 22)
        .padding(.trailing, BriefTheme.Metric.pagePadding)
        .padding(.vertical, 12)
        // 展开证据的那一行整行罩一层该句自己的颜色（5%）——绿句绿底、黄句黄底。
        .background(isExpanded && weakestClaim != nil ? accentColor.opacity(0.05) : Color.clear)
    }

    /// 重查的三种样子。`.idle` 时整行消失，不留一个空位置——
    /// 没有在查的时候不该有任何关于查的字。
    @ViewBuilder
    private var recheckNote: some View {
        switch recheckPhase {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                StageSpinner(size: 10, lineWidth: 1.5, tint: BriefTheme.text3)
                Text("重查中…").font(BriefTheme.mono(11))
            }
            .foregroundStyle(BriefTheme.text3)
        case .foundNothing:
            // 查过了，结果是空的。这句话必须说，否则用户只看到按钮弹回去，
            // 分不清「查了没有」和「这个按钮坏了」。
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                Text("没有找到新的信源").font(BriefTheme.mono(11))
            }
            .foregroundStyle(BriefTheme.text3)
        }
    }

    /// 2pt 左边线。观点句是虚线——不是半透明的实线。虚实由 `SentenceStyle` 定。
    private var accentBar: some View {
        VerticalRule()
            .stroke(accentColor, style: StrokeStyle(lineWidth: 2, dash: style.isDashed ? [5, 4] : []))
            .frame(width: 2)
    }

    /// 锚点段落拼成一行富文本。降级时 runs 只有一段，于是自然退回纯文本。
    /// 观点句：斜体、次级字色（mock：italic + #C4C0B8）。
    private var text: some View {
        runs.segments.reduce(Text("")) { acc, segment in
            var piece = Text(segment.text)
            if segment.claimId != nil {
                piece = piece.underline(true, pattern: .dot, color: accentColor)
            }
            return acc + piece
        }
        .font(BriefTheme.sans(16.5))
        .italic(sentence.kind == .opinion)
        .foregroundStyle(sentence.kind == .opinion ? BriefTheme.text2 : BriefTheme.text1)
        .lineSpacing(5)
    }

    private func evidenceToggle(_ claim: ClaimEvidence) -> some View {
        let label = EvidenceLabel(claim)
        return Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: label.isWarning ? "exclamationmark.triangle" : "checkmark")
                    .font(.system(size: 11, weight: .bold))
                Text(label.text).font(BriefTheme.mono(11.5))
            }
            .foregroundStyle(style.accent.labelColor)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Task 9 Step 3：手势那一半。露几个按钮、拉到哪里吸附，全部由
/// `SwipeActions` / `SwipeState` 决定——这里只把 DragGesture 的横向位移
/// 原样喂进去，再把 `offset` 画出来。View 里不写第二套判断。
struct SwipeableSentenceRow: View {
    let sentence: BriefSentence
    let claims: [String: ClaimEvidence]
    let recheckPhase: RecheckPhase
    let onDelete: () -> Void
    let onRecheck: () -> Void

    private let actions: SwipeActions
    @State private var swipe: SwipeState

    init(
        sentence: BriefSentence,
        claims: [String: ClaimEvidence],
        recheckPhase: RecheckPhase = .idle,
        onDelete: @escaping () -> Void,
        onRecheck: @escaping () -> Void
    ) {
        self.sentence = sentence
        self.claims = claims
        self.recheckPhase = recheckPhase
        self.onDelete = onDelete
        self.onRecheck = onRecheck
        let actions = SwipeActions(for: sentence.kind)
        self.actions = actions
        _swipe = State(initialValue: SwipeState(width: actions.width))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            buttons
            SentenceRow(sentence: sentence, claims: claims, recheckPhase: recheckPhase)
                // 滑开时盖住按钮的那一层，必须和页面底色一样。
                .background(BriefTheme.canvas)
                .offset(x: swipe.offset)
                .gesture(drag)
        }
        .clipped()
    }

    /// mock：每个 72pt；重查 #2B2823 / #C4C0B8，删除 #6E2F26 / #F5E8E4；图标 16 + 11.5pt 字。
    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(actions.buttons, id: \.rawValue) { action in
                Button {
                    perform(action)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: icon(action)).font(.system(size: 16, weight: .semibold))
                        Text(title(action)).font(BriefTheme.sans(11.5))
                    }
                    .frame(width: SwipeActions.buttonWidth)
                    .frame(maxHeight: .infinity)
                    .background(background(action))
                    .foregroundStyle(foreground(action))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(action))
            }
        }
        .frame(width: actions.width)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // 纵向为主的手势留给外层 ScrollView，不抢。
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                swipe.drag(to: value.translation.width)
            }
            .onEnded { _ in
                withAnimation(.snappy) { swipe.release() }
            }
    }

    private func perform(_ action: SwipeAction) {
        switch action {
        case .delete: onDelete()
        case .recheck: onRecheck()
        }
        // 关回去：重新起一个初态，而不是在这里另算一遍位移。
        withAnimation(.snappy) { swipe = SwipeState(width: actions.width) }
    }

    private func icon(_ action: SwipeAction) -> String {
        switch action {
        case .recheck: "arrow.clockwise"
        case .delete: "trash"
        }
    }

    private func title(_ action: SwipeAction) -> String {
        switch action {
        case .recheck: "重查"
        case .delete: "删除"
        }
    }

    private func background(_ action: SwipeAction) -> Color {
        switch action {
        case .recheck: BriefTheme.recheckBg
        case .delete: BriefTheme.deleteBg
        }
    }

    private func foreground(_ action: SwipeAction) -> Color {
        switch action {
        case .recheck: BriefTheme.onRecheck
        case .delete: BriefTheme.onDelete
        }
    }
}
```

- [ ] **Step 4: 替换 `EvidenceSheet.swift`**

```swift
import SwiftUI

/// 展开后每源一行：发布方 · 引文或说明 · 时间。
/// 行数等于独立源数，**不等于**总篇数——被归并的转载只在末行以数字出现。
///
/// mock：发布方 12pt #C4C0B8 最小宽 62；说明 11.5pt #8A847A；时间 10.5pt mono #5A554D；
/// 末行 11pt #5A554D。
struct EvidenceSheet: View {
    let claim: ClaimEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(claim.sources) { source in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(source.publisher)
                        .font(BriefTheme.sans(12))
                        .foregroundStyle(BriefTheme.text2)
                        .frame(minWidth: 62, alignment: .leading)
                    Text(source.note)
                        .font(BriefTheme.sans(11.5))
                        .foregroundStyle(BriefTheme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(source.time)
                        .font(BriefTheme.mono(10.5))
                        .foregroundStyle(BriefTheme.text5)
                }
            }
            if let footer = EvidenceFooter(mergedAwayCount: claim.mergedAwayCount).text {
                Text(footer)
                    .font(BriefTheme.sans(11))
                    .foregroundStyle(BriefTheme.text5)
                    .padding(.top, 1)
            }
        }
        .padding(.top, 2)
    }
}
```

- [ ] **Step 5: 纪律 grep、编译、测试台**

```bash
grep -nE '\.secondary|\.tertiary|\.quaternary|\.borderedProminent|systemBackground|Color\(red:|0x[0-9A-Fa-f]{6}' "ios/Pollux One/Features/Brief/ReviewView.swift" "ios/Pollux One/Features/Brief/SentenceRow.swift" "ios/Pollux One/Features/Brief/EvidenceSheet.swift"
```

Expected: 无输出。然后 §0.3 编译 → `** BUILD SUCCEEDED **`；`bash scripts/test-engines.sh 2>&1 | tail -1` → `0 failed`。

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Features/Brief/ReviewView.swift" "ios/Pollux One/Features/Brief/SentenceRow.swift" "ios/Pollux One/Features/Brief/EvidenceSheet.swift"
git commit -m "$(cat <<'EOF'
Dress the review screen in the mock's colours

The structure was already right; the skin was the system's. Opinion
sentences get a real dashed rule instead of a faded solid one, an
expanded sentence sits on a five-percent wash of its own colour, the
swipe buttons take the mock's two tones, and the bottom bar grows its
divider, its bordered swap square and a bronze 开拍. Every number is in
Plex Mono.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: ⑤ 等待页换皮（含 token 数写法进 Domain）

**Files:**
- Modify: `ios/Pollux One/Domain/Brief/BriefStage.swift`（末尾追加 `TokenFormat`）
- Modify: `ios/EngineHarness/BriefScenarios.swift`
- Modify: `ios/Pollux One/Features/Brief/BriefProgressView.swift`（整文件替换）

- [ ] **Step 1: 读 mock**

Artifact 工具读 `project/Progress.dc.html`。注意 token 条三段的三个颜色（#C49A6C / #8A6A45 / #574636）、25 / 50 / 75% 处的刻度线，以及进行中那一行是一张带边的卡。

- [ ] **Step 2: 写断言**

`runBriefSuite()` 末尾 `return` 之前插入：

```swift
    report.section("⑤ token 数的写法")
    report.check(TokenFormat.kilo(38_100) == "38.1K", "38100 → 38.1K", detail: TokenFormat.kilo(38_100))
    report.check(TokenFormat.kilo(6_200) == "6.2K", "6200 → 6.2K", detail: TokenFormat.kilo(6_200))
    report.check(TokenFormat.kilo(40) == "40", "不到一千写原数，不写 0.0K", detail: TokenFormat.kilo(40))
    report.check(TokenFormat.millions(2_410_000) == "2.41M", "本月余额 2.41M",
                 detail: TokenFormat.millions(2_410_000))
```

- [ ] **Step 3: 跑，确认编译失败**

Run: `bash scripts/test-engines.sh 2>&1 | grep -m1 "error:"`
Expected: `error: cannot find 'TokenFormat' in scope`

- [ ] **Step 4: 写实现**

`ios/Pollux One/Domain/Brief/BriefStage.swift` 末尾追加：

```swift

/// ⑤ 与 ⑦ 上 token 数的写法。放在 Domain 是为了能在测试台钉死：
/// 「38.1K」和「40」的分界、「2.41M」的位数，都不该由某个 View 自己决定。
enum TokenFormat {
    /// 38100 → "38.1K"，6200 → "6.2K"，40 → "40"。不到一千写原数——
    /// 「0.0K」读起来像没有，而它有。
    static func kilo(_ tokens: Int) -> String {
        tokens >= 1000 ? String(format: "%.1fK", Double(tokens) / 1000) : "\(tokens)"
    }

    /// 2_410_000 → "2.41M"。
    static func millions(_ tokens: Int) -> String {
        String(format: "%.2fM", Double(tokens) / 1_000_000)
    }
}
```

- [ ] **Step 5: 跑绿**

Run: `bash scripts/test-engines.sh 2>&1 | tail -1`
Expected: `0 failed`，passed 比 Task 5 结束时多 4。

- [ ] **Step 6: 替换 `BriefProgressView.swift`**

```swift
import SwiftUI

/// ⑤ 等待。上半 1/3 是 token 表——spec §10.1 说 token 是一等产品对象，
/// 它在这里第一次对用户可见。
struct BriefProgressView: View {
    let brief: Brief
    let elapsed: String
    let onBack: () -> Void
    let onLeave: () -> Void
    let onCancel: () -> Void

    /// token 条三段的青铜明度，按 `TokenBar` 排好的顺序（多的在前）。
    /// 第四段起沿用最深的一档——mock 只有三段。
    private static let segmentColors = [BriefTheme.accent, BriefTheme.accentMid, BriefTheme.accentDeep]

    private var bar: TokenBar { TokenBar(brief.budget) }

    var body: some View {
        VStack(spacing: 0) {
            BriefTopRow(onBack: onBack) {
                NewsTagCard(news: brief.news)
                Text(elapsed)
                    .font(BriefTheme.mono(14))
                    .foregroundStyle(BriefTheme.accent)
            }
            ScrollView {
                VStack(spacing: 0) {
                    tokenPanel
                        .padding(.horizontal, BriefTheme.Metric.pagePadding)
                        .padding(.top, 20)
                    stageList
                        .padding(.horizontal, BriefTheme.Metric.pagePadding)
                        .padding(.top, 22)
                }
            }
            bottomActions
        }
    }

    // MARK: token 表

    /// mock：#131210 底、#26231E 边、圆角 14、内边距 20 / 18 / 18。
    private var tokenPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(brief.budget.used, format: .number)
                        .font(BriefTheme.mono(40))
                        .kerning(-1.2)
                        .foregroundStyle(BriefTheme.text1)
                    Text("tokens")
                        .font(BriefTheme.sans(12.5))
                        .foregroundStyle(BriefTheme.text4)
                }
                Spacer()
                Text("¥" + String(format: "%.2f", Double(brief.budget.costCents) / 100))
                    .font(BriefTheme.mono(17))
                    .foregroundStyle(BriefTheme.accent)
            }
            segmentedBar
            legend
            Rectangle().fill(BriefTheme.dividerSoft).frame(height: 1)
            HStack {
                (Text("预算 ").foregroundStyle(BriefTheme.text4)
                    + Text("\(brief.budget.budgeted / 1000)K")
                        .font(BriefTheme.mono(11.5))
                        .foregroundStyle(BriefTheme.text3)
                    + Text(" · 已用 \(Int(brief.budget.fractionUsed * 100))%")
                        .foregroundStyle(BriefTheme.text4))
                    .font(BriefTheme.sans(11.5))
                Spacer()
                (Text("本月余额 ").foregroundStyle(BriefTheme.text4)
                    + Text(TokenFormat.millions(brief.budget.remainingThisMonth))
                        .font(BriefTheme.mono(11.5))
                        .foregroundStyle(BriefTheme.text3))
                    .font(BriefTheme.sans(11.5))
            }
        }
        .padding(EdgeInsets(top: 20, leading: 18, bottom: 18, trailing: 18))
        .background(BriefTheme.surfaceDeep, in: RoundedRectangle(cornerRadius: BriefTheme.Metric.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BriefTheme.Metric.cardRadius)
                .stroke(BriefTheme.borderDeep, lineWidth: 1)
        )
    }

    /// mock：高 11、圆角 3、槽 #1F1D19；三段青铜；25 / 50 / 75% 处 1pt 底色刻度线。
    /// 每段宽度是「该阶段占预算的比例」（`TokenBar`），各段之和等于已用比例。
    private var segmentedBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(BriefTheme.barTrack)
                HStack(spacing: 0) {
                    ForEach(Array(bar.segments.enumerated()), id: \.offset) { index, segment in
                        Rectangle()
                            .fill(Self.segmentColor(index))
                            .frame(width: geo.size.width * segment.fraction)
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                ForEach([0.25, 0.5, 0.75], id: \.self) { tick in
                    Rectangle()
                        .fill(BriefTheme.canvas)
                        .frame(width: 1)
                        .offset(x: geo.size.width * tick)
                }
            }
        }
        .frame(height: 11)
    }

    private static func segmentColor(_ index: Int) -> Color {
        segmentColors[min(index, segmentColors.count - 1)]
    }

    /// 图例只列 token 最多的前三段——第四段起在 11.5pt 上排不下，条本身把所有段都画了。
    private var legend: some View {
        HStack(spacing: 13) {
            ForEach(Array(bar.segments.prefix(3).enumerated()), id: \.offset) { index, segment in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.segmentColor(index))
                        .frame(width: 7, height: 7)
                    Text(segment.stage)
                        .font(BriefTheme.sans(11.5))
                        .foregroundStyle(BriefTheme.text3)
                    Text(TokenFormat.kilo(brief.budget.byStage[segment.stage] ?? 0))
                        .font(BriefTheme.mono(11.5))
                        .foregroundStyle(BriefTheme.text2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 阶段

    private var stageList: some View {
        VStack(spacing: 0) {
            ForEach(brief.stages) { stage in
                stageRow(stage)
            }
        }
    }

    @ViewBuilder
    private func stageRow(_ stage: BriefStage) -> some View {
        switch stage.state {
        case .done:
            HStack(spacing: 13) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(BriefTheme.strong)
                    .frame(width: 16, height: 16)
                Text(stage.name)
                    .font(BriefTheme.sans(14))
                    .foregroundStyle(BriefTheme.text4)
                Spacer()
                if let count = stage.count {
                    Text(count)
                        .font(BriefTheme.mono(11.5))
                        .foregroundStyle(BriefTheme.text5)
                }
            }
            .padding(.vertical, 9)

        case .running:
            // 进行中的那一行升成一张卡：青铜 9% 底、26% 边。它是这一屏唯一在动的东西。
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 13) {
                    StageSpinner(size: 16, lineWidth: 2.5)
                    Text(stage.name)
                        .font(BriefTheme.sans(14, .medium))
                        .foregroundStyle(BriefTheme.text1)
                    Spacer()
                    // 计数一律沿用上游给的；没有就不写，不补 0。
                    if let count = stage.count {
                        Text(count)
                            .font(BriefTheme.mono(11.5))
                            .foregroundStyle(BriefTheme.accent)
                    }
                }
                if let detail = stage.detail {
                    Text(detail)
                        .font(BriefTheme.sans(12.5))
                        .foregroundStyle(BriefTheme.text3)
                        .lineSpacing(3)
                        .padding(.leading, 29)
                }
            }
            .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
            .background(BriefTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(BriefTheme.accent.opacity(0.26), lineWidth: 1))
            .padding(.vertical, 5)

        case .pending:
            // 未开始的阶段不显示计数。0 读起来像「挖到了 0 条」。
            HStack(spacing: 13) {
                Circle()
                    .strokeBorder(BriefTheme.pendingRing, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                Text(stage.name)
                    .font(BriefTheme.sans(14))
                    .foregroundStyle(BriefTheme.text6)
                Spacer()
            }
            .padding(.vertical, 9)
        }
    }

    // MARK: 底部

    private var bottomActions: some View {
        VStack(spacing: 13) {
            // spec §8.2：②→③ 是不可逆边界，所以这里的返回是「离开」。
            // 随手一按不该毁掉一个已经花了钱的任务。
            SecondaryButton(title: "退出，好了通知我", action: onLeave)
            // 真正的取消是另一个动作，很轻，并且明说不退。
            TextLinkButton(title: "取消调研 · 已消耗的 \(brief.budget.used / 1000)K 不退",
                           tint: BriefTheme.cancelText,
                           action: onCancel)
        }
        .padding(.horizontal, BriefTheme.Metric.pagePadding)
        .padding(.top, 10)
        .padding(.bottom, BriefTheme.Metric.bottomInset)
    }
}
```

- [ ] **Step 7: 纪律 grep、编译**

```bash
grep -nE '\.secondary|\.tertiary|\.quaternary|\.borderedProminent|systemBackground|Color\(red:|0x[0-9A-Fa-f]{6}|accentColor' "ios/Pollux One/Features/Brief/BriefProgressView.swift"
```

Expected: 无输出。§0.3 编译 → `** BUILD SUCCEEDED **`。

- [ ] **Step 8: 提交**

```bash
git add "ios/Pollux One/Domain/Brief/BriefStage.swift" ios/EngineHarness/BriefScenarios.swift "ios/Pollux One/Features/Brief/BriefProgressView.swift"
git commit -m "$(cat <<'EOF'
Make the wait screen's token meter look like a meter

The card gets its border, the bar its three bronze shades and quarter
ticks, the legend its numbers, and the stage that is running rises into
a tinted card with a bronze ring instead of a white system spinner.
How a token count is written — 38.1K, 40, 2.41M — moves into the
Domain so the harness can hold it still.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: ⑥ 不建议播（Domain 露出 found / required / title，换皮）

**Files:**
- Modify: `ios/Pollux One/Domain/Brief/InsufficientState.swift`（整文件替换）
- Modify: `ios/EngineHarness/BriefScenarios.swift`
- Modify: `ios/Pollux One/Features/Brief/InsufficientView.swift`（整文件替换）
- Modify: `ios/Pollux One/Features/Brief/BriefFlow.swift`（调用点去掉 `news:`）

- [ ] **Step 1: 读 mock**

Artifact 工具读 `project/Insufficient.dc.html`。mock 上的归并卡（14 → 2）、两家打架的引文、绿色提示条和「帮我盯着」按钮**不画**——数据里没有（spec §6 ⑥）。只做：红图标、大标题、理由、分隔线、「问题在哪」一张卡、两个按钮。

- [ ] **Step 2: 写断言**

`BriefScenarios.swift` 里 `report.section("⑥ 不建议播")` 那一节，`report.check(shortOfSources.costNote.contains("12"), ...)` 之后插入：

```swift
    report.check(shortOfSources.found == 2 && shortOfSources.required == 3,
                 "找到几个、需要几个各自可读——⑥ 那张卡要分开画它们")
    report.check(InsufficientState.title == "这条我不建议你现在播",
                 "大标题是 mock 上那句，一字不差")
```

- [ ] **Step 3: 跑，确认编译失败**

Run: `bash scripts/test-engines.sh 2>&1 | grep -m1 "error:"`
Expected: `error: value of type 'InsufficientState' has no member 'found'`

- [ ] **Step 4: 替换 `InsufficientState.swift`**

```swift
import Foundation

struct InsufficientAction: Equatable {
    let id: String
    let title: String
}

struct InsufficientState: Equatable {
    /// mock 上的大标题，一字不差。spec §5.1：产品必须敢说这句。
    static let title = "这条我不建议你现在播"

    /// 找到的独立源数（取全篇最硬那个事实点的）与下限。分开存，
    /// 因为 ⑥ 那张卡要把它们并排写成「2 / 3」。
    let found: Int
    let required: Int
    let headline: String
    let costNote: String
    let actions: [InsufficientAction]

    init(found: Int, required: Int, tokensUsed: Int) {
        self.found = found
        self.required = required
        // 说清差在哪，而不是一句「失败了」。
        headline = "只找到 \(found) 个独立信源，低于 \(required) 个的下限"
        // 花了就是花了。这恰恰是用户最该被告知的时刻——跑出了零结果，
        // 却仍然收了钱。
        costNote = "这一轮消耗了 \(tokensUsed / 1000)K token"
        // 没有「强行出稿」。给一个绕过拒绝的出口，等于这套承诺全是装饰。
        actions = [
            InsufficientAction(id: "retry", title: "再找一轮"),
            InsufficientAction(id: "another", title: "换一条新闻"),
        ]
    }
}
```

- [ ] **Step 5: 跑绿**

Run: `bash scripts/test-engines.sh 2>&1 | tail -1`
Expected: `0 failed`，passed 比 Task 6 结束时多 2。

- [ ] **Step 6: 替换 `InsufficientView.swift`**

```swift
import SwiftUI

/// ⑥ 不建议播。spec §5.1 的可见形态——这一屏是产品敢不敢说真话的地方。
///
/// 这里**没有**「强行出稿」。给一个绕过拒绝的出口，等于这套承诺全是装饰；
/// 按钮从 `InsufficientState.actions` 长出来，那份清单由测试钉死。
///
/// mock 上还有归并卡、两家互相打架的引文、「帮我盯着」——数据里没有这些
/// （spec §6 ⑥），所以没画。等管线把 conflicted claim 送到 iOS 再说。
struct InsufficientView: View {
    let state: InsufficientState
    /// 上游给的具体理由（fixture 的 `insufficientReason`），没有就整段不出现。
    let reason: String?
    let onBack: () -> Void
    let onAction: (InsufficientAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BriefTopRow(onBack: onBack) { Spacer(minLength: 0) }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading
                    Rectangle().fill(BriefTheme.rule).frame(height: 1)
                    problems
                }
                .padding(.horizontal, BriefTheme.Metric.pagePadding)
                .padding(.top, 24)
            }
            actions
        }
    }

    /// mock：26pt 红色警告图标 → 25pt 700 标题 → 14.5pt 灰理由。
    private var heading: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(BriefTheme.danger)
            Text(InsufficientState.title)
                .font(BriefTheme.sans(25, .bold))
                .foregroundStyle(BriefTheme.text1)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            if let reason {
                Text(reason)
                    .font(BriefTheme.sans(14.5))
                    .foregroundStyle(BriefTheme.text3)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 「问题在哪」只有一张卡：数据里只有「找到几个 / 需要几个 / 花了多少」。
    private var problems: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("问题在哪")
                .font(BriefTheme.sans(12, .medium))
                .kerning(1)
                .foregroundStyle(BriefTheme.textDisabled)
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("\(state.found) / \(state.required)")
                        .font(BriefTheme.mono(15))
                        .foregroundStyle(BriefTheme.danger)
                    Text(state.headline)
                        .font(BriefTheme.sans(13.5, .medium))
                        .foregroundStyle(BriefTheme.text1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 花了就是花了。跑出零结果却仍然收了钱，正是最该说清的时刻。
                Text(state.costNote)
                    .font(BriefTheme.sans(12.5))
                    .foregroundStyle(BriefTheme.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16))
            .background(BriefTheme.surface, in: RoundedRectangle(cornerRadius: 11))
        }
    }

    /// 第一个动作是主按钮，其余是次级。清单本身从 `state.actions` 来，这里不加不减。
    private var actions: some View {
        VStack(spacing: 14) {
            ForEach(Array(state.actions.enumerated()), id: \.element.id) { index, action in
                if index == 0 {
                    PrimaryButton(title: action.title) { onAction(action) }
                } else {
                    SecondaryButton(title: action.title) { onAction(action) }
                }
            }
        }
        .padding(.horizontal, BriefTheme.Metric.pagePadding)
        .padding(.top, 16)
        .padding(.bottom, BriefTheme.Metric.bottomInset)
    }
}
```

- [ ] **Step 7: 改 `BriefFlow` 的调用点**

`BriefFlow.swift` 里 `InsufficientView(` 那一处，删掉 `news: brief.news,` 这一行，其余参数不动：

```swift
                InsufficientView(
                    state: insufficientState(for: brief),
                    reason: brief.insufficientReason,
                    onBack: back(from: .insufficient),
                    onAction: { action in
                        switch action.id {
                        case "retry": startResearch()
                        default: screen = .handOff
                        }
                    }
                )
```

- [ ] **Step 8: 纪律 grep、编译**

```bash
grep -nE '\.secondary|\.tertiary|\.quaternary|\.borderedProminent|systemBackground|Color\(red:|0x[0-9A-Fa-f]{6}|AnyShapeStyle' "ios/Pollux One/Features/Brief/InsufficientView.swift"
```

Expected: 无输出。§0.3 编译 → `** BUILD SUCCEEDED **`。

- [ ] **Step 9: 提交**

```bash
git add "ios/Pollux One/Domain/Brief/InsufficientState.swift" ios/EngineHarness/BriefScenarios.swift "ios/Pollux One/Features/Brief/InsufficientView.swift" "ios/Pollux One/Features/Brief/BriefFlow.swift"
git commit -m "$(cat <<'EOF'
Say "don't broadcast this" in the mock's voice

The refusal screen gets the mock's red mark, its headline and one card
that shows found against required. The state now exposes those two
numbers separately so the card can draw them, and carries the headline
as a constant so no view invents its own. The conflict cards and the
"watch it for me" offer stay out: nothing upstream produces them yet.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: ④ Domain —— 五档调性名、买不起的边界、锚点读作「通俗」

**Files:**
- Modify: `ios/Pollux One/Domain/Brief/DialState.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`

- [ ] **Step 1: 改一条旧断言（先于实现）**

`BriefScenarios.swift` 里 `report.section("④ 拨盘")` 那一节有这一行：

```swift
    report.check(dial.durationSec == 60 && dial.register == 0.0, "锚点一：60s 通俗")
```

改成：

```swift
    report.check(dial.durationSec == 60 && dial.register == 0.25,
                 "锚点一：60s 通俗——五档名里 0.0 是「八卦」，通俗在 0.25")
```

- [ ] **Step 2: 写新断言**

`runBriefSuite()` 末尾 `return` 之前插入：

```swift
    report.section("④ 调性五档名")
    report.check(DialState.registerName(for: 0) == "八卦", "0 → 八卦")
    report.check(DialState.registerName(for: 0.25) == "通俗", "0.25 → 通俗")
    report.check(DialState.registerName(for: 0.5) == "平实", "0.5 → 平实")
    report.check(DialState.registerName(for: 0.7) == "偏专业", "0.7 → 偏专业")
    report.check(DialState.registerName(for: 1) == "专业", "1 → 专业")
    report.check(DialState.registerName(for: 7) == "专业", "越界夹到两端，不崩")
    var anchorA = DialState(); anchorA.snap(to: .casualMinute)
    report.check(anchorA.registerName == "通俗", "锚点一读作「通俗」——spec §2.2 的原话")
    var anchorB = DialState(); anchorB.snap(to: .professionalThreeMinutes)
    report.check(anchorB.registerName == "偏专业", "锚点二读作「偏专业」")

    report.section("④ 买不起的边界")
    let boundless = DialState(remainingTokens: .max)
    report.check(DialState.durationSteps.allSatisfy { boundless.maxAffordableRegister(durationSec: $0) == nil },
                 "余额无限时没有一档需要画斜纹")
    let penniless = DialState(remainingTokens: 1)
    report.check(DialState.durationSteps.allSatisfy { penniless.maxAffordableRegister(durationSec: $0) == 0 },
                 "一分钱没有时整盘都是斜纹")
    // 余额正好等于「6 分钟 · 平实」的价：360s 这一档只买得起左半边，30s 整行买得起。
    var half = DialState(); half.setDuration(seconds: 360); half.setRegister(0.5)
    let tight = DialState(remainingTokens: half.estimate.tokens)
    report.check(tight.maxAffordableRegister(durationSec: 30) == nil, "30s 整行买得起")
    let limit360 = tight.maxAffordableRegister(durationSec: 360)
    report.check(limit360.map { abs($0 - 0.5) < 0.001 } == true,
                 "360s 的边界落在 0.5", detail: "\(limit360 ?? -1)")
    if let limit360 {
        var edge = DialState(remainingTokens: half.estimate.tokens)
        edge.setDuration(seconds: 360); edge.setRegister(limit360)
        report.check(edge.canAfford, "边界上买得起")
        edge.setRegister(min(1, limit360 + 0.02))
        report.check(!edge.canAfford, "边界右边 0.02 就买不起")
    } else {
        report.check(false, "360s 应当有一个边界")
    }
    let limits = DialState.durationSteps.map { tight.maxAffordableRegister(durationSec: $0) ?? 1.0 }
    report.check(zip(limits, limits.dropFirst()).allSatisfy { $0 >= $1 },
                 "时长越长，能买到的调性越窄——边界是锯齿的",
                 detail: limits.map { String(format: "%.2f", $0) }.joined(separator: " "))
```

- [ ] **Step 3: 跑，确认编译失败**

Run: `bash scripts/test-engines.sh 2>&1 | grep -m1 "error:"`
Expected: `error: type 'DialState' has no member 'registerName'`

- [ ] **Step 4: 改 `DialState.swift`**

`snap(to:)` 里 `.casualMinute` 那一支改为：

```swift
        case .casualMinute:
            durationSec = 60
            // 0.25，不是 0.0：五档名里 0.0 是「八卦」，而 spec §2.2 说这个锚点叫「通俗」。
            register = 0.25
```

然后在 `var canAfford: Bool { ... }` 之前插入两段：

```swift
    // MARK: 调性五档名（spec §6 ④）

    /// mock 横轴两端写的是「八卦」和「专业」，中间三档等分。
    static let registerNames = ["八卦", "通俗", "平实", "偏专业", "专业"]

    static func registerName(for register: Double) -> String {
        let clamped = min(1.0, max(0.0, register))
        let index = Int((clamped * Double(registerNames.count - 1)).rounded())
        return registerNames[index]
    }

    var registerName: String { Self.registerName(for: register) }

    // MARK: 买不起的边界（spec §6 ④ 的斜纹带）

    /// 某一档时长上，余额能买到的最右 register。
    /// - 整行都买得起 → nil（那一档不画斜纹）
    /// - 连 register 0 都买不起 → 0（整行斜纹）
    /// - 否则 → (0, 1) 之间的那个边界，斜纹从它画到右边缘
    ///
    /// 用二分而不是解 `estimate` 的公式：公式的系数要被真实样本回归改掉
    /// （前一份计划 Task 16），这里只依赖「越专业越贵」这一条单调性。
    func maxAffordableRegister(durationSec seconds: Int) -> Double? {
        var probe = self
        probe.setDuration(seconds: seconds)
        probe.setRegister(1.0)
        if probe.estimate.tokens <= remainingTokens { return nil }
        probe.setRegister(0.0)
        if probe.estimate.tokens > remainingTokens { return 0 }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            probe.setRegister(mid)
            if probe.estimate.tokens <= remainingTokens { low = mid } else { high = mid }
        }
        return low
    }
```

- [ ] **Step 5: 跑绿**

Run: `bash scripts/test-engines.sh 2>&1 | tail -1`
Expected: `0 failed`，passed 比 Task 7 结束时多 15。

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Domain/Brief/DialState.swift" ios/EngineHarness/BriefScenarios.swift
git commit -m "$(cat <<'EOF'
Teach the dial its five names and where the money runs out

The register axis reads 八卦 to 专业 in five steps, so the casual anchor
moves from 0 to 0.25 and finally says 通俗 as the spec always claimed.
The old 0.0 was a wrong value, not a product decision this change
reverses: spec §2.2 has said "1:00 通俗" since the day it was written.
For each duration step the dial can now answer how far right the balance
reaches, by bisection over the estimate rather than by inverting a
formula that is due to be recalibrated. The confirm screen will draw
those boundaries as the mock's hatched region.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: ④ 确认页 —— 取景框式拨盘

**Files:**
- Modify: `ios/Pollux One/Features/Brief/DialControl.swift`（整文件替换）
- Modify: `ios/Pollux One/Features/Brief/ConfirmView.swift`（整文件替换）

- [ ] **Step 1: 读 mock**

Artifact 工具读 `project/Confirm.dc.html`，重点看 `renderVals()` 里 `bands`（斜纹带怎么按档算）、`knobStyle`（46×46 方块 + 5pt 圆点）、`presetAWrap / presetBWrap`（推荐档位的位置与文字方向）、`crossHStyle / crossVStyle`（十字准线）。

- [ ] **Step 2: 替换 `DialControl.swift`**

```swift
import SwiftUI
import UIKit

/// ④ 的拨盘本体：mock 上那个取景框式的方盘（`project/Confirm.dc.html`）。
///
/// 纵轴是时长（往上更长，八档等距排列），横轴是调性（往右更专业，连续）。
/// 时长**吸在档位上**，每落进一档给一次轻触感——段落感靠触觉落地。
///
/// 判断全在 `DialState`：落在哪一档、买不买得起、边界在哪、叫什么名。
/// 这里只把它们画出来，一处自己的判断都没有。
struct DialControl: View {
    @Binding var dial: DialState

    private let haptics = UIImpactFeedbackGenerator(style: .light)
    /// mock：372pt 高。
    static let height: CGFloat = 372
    private static let steps = DialState.durationSteps
    private static let knobSize: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                grid(size)
                hatch(size)
                brackets(size)
                scaleLabels
                crosshair(size)
                readout
                presetDot(.casualMinute, size)
                presetDot(.professionalThreeMinutes, size)
                knob(size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { move(to: $0.location, in: size) }
            )
        }
        .frame(height: Self.height)
        .background(BriefTheme.input, in: RoundedRectangle(cornerRadius: BriefTheme.Metric.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BriefTheme.Metric.cardRadius)
                .stroke(BriefTheme.borderDeep, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: BriefTheme.Metric.cardRadius))
        .onAppear { haptics.prepare() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("时长与调性拨盘，现在是 \(Self.clock(dial.durationSec)) \(dial.registerName)")
    }

    // MARK: 坐标

    /// 八档等距：档位 i 的 y 是 (1 − i / (n−1)) × 高。和 mock 一样按序号排，不按秒数——
    /// 30→60 和 180→240 在盘上一样高。
    private static func rowFraction(_ index: Int) -> CGFloat {
        1 - CGFloat(index) / CGFloat(steps.count - 1)
    }

    private func stepIndex(_ seconds: Int) -> Int {
        Self.steps.firstIndex(of: seconds) ?? 0
    }

    private func knobCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(dial.register) * size.width,
                y: Self.rowFraction(stepIndex(dial.durationSec)) * size.height)
    }

    private func move(to point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let before = dial.durationSec
        dial.setRegister(Double(min(1, max(0, point.x / size.width))))
        let fraction = 1 - min(1, max(0, point.y / size.height))
        let index = Int((fraction * CGFloat(Self.steps.count - 1)).rounded())
        dial.setDuration(seconds: Self.steps[index])
        // 只在真的跨过一档时响，不然拖动全程都在震。
        if dial.durationSec != before { haptics.impactOccurred() }
    }

    /// 60 → "1:00"，90 → "1:30"，360 → "6:00"。
    static func clock(_ seconds: Int) -> String {
        "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    /// 买得起是青铜，买不起整套换成警示红：旋钮、圆点、读数。
    private var tone: Color { dial.canAfford ? BriefTheme.accent : BriefTheme.danger }

    // MARK: 画面

    /// 三分网格，1pt。
    private func grid(_ size: CGSize) -> some View {
        Path { path in
            for f in [1.0 / 3.0, 2.0 / 3.0] {
                path.move(to: CGPoint(x: size.width * f, y: 0))
                path.addLine(to: CGPoint(x: size.width * f, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * f))
                path.addLine(to: CGPoint(x: size.width, y: size.height * f))
            }
        }
        .stroke(BriefTheme.dialGrid, lineWidth: 1)
        .allowsHitTesting(false)
    }

    /// 买不起的区域：每一档时长上，从 `maxAffordableRegister` 到右边缘画 135° 斜纹。
    /// 边界按档分别算，所以是锯齿的——如实反映「时长越长，能承受的专业度越低」。
    /// mock：`repeating-linear-gradient(135deg, rgba(196,97,79,0.13) 0 4px, rgba(13,13,12,0.55) 4px 9px)`。
    private func hatch(_ size: CGSize) -> some View {
        Canvas { context, _ in
            let rows = CGFloat(Self.steps.count - 1)
            let rowHeight = size.height / rows
            for (index, step) in Self.steps.enumerated() {
                guard let limit = dial.maxAffordableRegister(durationSec: step) else { continue }
                let top = max(0, (1 - (CGFloat(index) + 0.5) / rows) * size.height)
                let band = CGRect(x: CGFloat(limit) * size.width,
                                  y: top,
                                  width: size.width * (1 - CGFloat(limit)),
                                  height: min(rowHeight, size.height - top))
                guard band.width > 0, band.height > 0 else { continue }
                var clipped = context
                clipped.clip(to: Path(band))
                clipped.fill(Path(band), with: .color(BriefTheme.canvas.opacity(0.55)))
                var stripes = Path()
                var x = band.minX - band.height
                while x < band.maxX {
                    stripes.move(to: CGPoint(x: x, y: band.maxY))
                    stripes.addLine(to: CGPoint(x: x + band.height, y: band.minY))
                    x += 9
                }
                clipped.stroke(stripes, with: .color(BriefTheme.danger.opacity(0.13)), lineWidth: 4)
            }
        }
        .allowsHitTesting(false)
    }

    /// 四角括号：13×13，1.5pt，内缩 10。取景框的意思。
    private func brackets(_ size: CGSize) -> some View {
        Path { path in
            let inset: CGFloat = 10
            let arm: CGFloat = 13
            let w = size.width
            let h = size.height
            path.move(to: CGPoint(x: inset, y: inset + arm))
            path.addLine(to: CGPoint(x: inset, y: inset))
            path.addLine(to: CGPoint(x: inset + arm, y: inset))
            path.move(to: CGPoint(x: w - inset - arm, y: inset))
            path.addLine(to: CGPoint(x: w - inset, y: inset))
            path.addLine(to: CGPoint(x: w - inset, y: inset + arm))
            path.move(to: CGPoint(x: inset, y: h - inset - arm))
            path.addLine(to: CGPoint(x: inset, y: h - inset))
            path.addLine(to: CGPoint(x: inset + arm, y: h - inset))
            path.move(to: CGPoint(x: w - inset - arm, y: h - inset))
            path.addLine(to: CGPoint(x: w - inset, y: h - inset))
            path.addLine(to: CGPoint(x: w - inset, y: h - inset - arm))
        }
        .stroke(BriefTheme.dialBracket, lineWidth: 1.5)
        .allowsHitTesting(false)
    }

    /// 盘内刻度：左上 6:00、左下 0:30（mono，#423D36）；左下「八卦」、右下「专业」（#4E4841）。
    private var scaleLabels: some View {
        ZStack {
            Text(Self.clock(DialState.maxDurationSec))
                .font(BriefTheme.mono(10.5))
                .foregroundStyle(BriefTheme.dialScale)
                .padding(.leading, 14)
                .padding(.top, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(Self.clock(DialState.durationSteps[0]))
                .font(BriefTheme.mono(10.5))
                .foregroundStyle(BriefTheme.dialScale)
                .padding(.leading, 14)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            Text(DialState.registerNames.first ?? "")
                .font(BriefTheme.sans(10.5))
                .foregroundStyle(BriefTheme.dialAxis)
                .padding(.leading, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            Text(DialState.registerNames.last ?? "")
                .font(BriefTheme.sans(10.5))
                .foregroundStyle(BriefTheme.dialAxis)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .allowsHitTesting(false)
    }

    /// 十字准线过旋钮中心，1pt，青铜 20%。
    private func crosshair(_ size: CGSize) -> some View {
        let c = knobCenter(in: size)
        return Path { path in
            path.move(to: CGPoint(x: 0, y: c.y))
            path.addLine(to: CGPoint(x: size.width, y: c.y))
            path.move(to: CGPoint(x: c.x, y: 0))
            path.addLine(to: CGPoint(x: c.x, y: size.height))
        }
        .stroke(BriefTheme.accent.opacity(0.20), lineWidth: 1)
        .allowsHitTesting(false)
    }

    /// 右上角读数：21pt mono 时钟 + 12.5pt 档位名。买不起时整组变红。
    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(Self.clock(dial.durationSec))
                .font(BriefTheme.mono(21))
                .kerning(-0.2)
            Text(dial.registerName)
                .font(BriefTheme.sans(12.5))
        }
        .foregroundStyle(tone)
        .padding(.top, 12)
        .padding(.trailing, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    /// 两个推荐档位（spec §2.2 的锚点）。位置从 `DialState.snap` 探出来，不另写坐标。
    /// 9pt 圆：选中时青铜实心，否则空心；44×44 命中区；文字在 A 的右边、B 的左边。
    private func presetDot(_ anchor: DialAnchor, _ size: CGSize) -> some View {
        var probe = DialState()
        probe.snap(to: anchor)
        let center = CGPoint(x: CGFloat(probe.register) * size.width,
                             y: Self.rowFraction(stepIndex(probe.durationSec)) * size.height)
        let isOn = dial.durationSec == probe.durationSec && dial.registerName == probe.registerName
        let label = "\(Self.clock(probe.durationSec)) \(probe.registerName)"
        let labelOnRight = anchor == .casualMinute
        // 一个 200pt 宽的容器，圆点那一端对齐；容器中心相对锚点偏移 (100 − 22)。
        let width: CGFloat = 200

        let dot = Button {
            dial.snap(to: anchor)
            haptics.impactOccurred()
        } label: {
            Circle()
                .strokeBorder(isOn ? BriefTheme.accent : BriefTheme.presetOff, lineWidth: 1.5)
                .background(Circle().fill(isOn ? BriefTheme.accent : Color.clear))
                .frame(width: 9, height: 9)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("用推荐设定：\(label)")

        let text = Text(label)
            .font(BriefTheme.sans(10.5))
            .foregroundStyle(BriefTheme.presetLabel)
            .fixedSize()

        return Group {
            if labelOnRight {
                HStack(spacing: 0) { dot; text }
                    .frame(width: width, alignment: .leading)
                    .position(x: center.x - 22 + width / 2, y: center.y)
            } else {
                HStack(spacing: 0) { text; dot }
                    .frame(width: width, alignment: .trailing)
                    .position(x: center.x + 22 - width / 2, y: center.y)
            }
        }
    }

    /// 46×46 方旋钮：1.5pt 描边、青铜 13% 底、中心 5pt 圆点。跟着 `dial` 吸到档位上。
    private func knob(_ size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(tone, lineWidth: 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(BriefTheme.accent.opacity(0.13)))
            .overlay(Circle().fill(tone).frame(width: 5, height: 5))
            .frame(width: Self.knobSize, height: Self.knobSize)
            .position(knobCenter(in: size))
            .animation(.snappy(duration: 0.14), value: dial)
            .allowsHitTesting(false)
    }
}
```

- [ ] **Step 3: 替换 `ConfirmView.swift`**

```swift
import SwiftUI

/// ④ 确认。spec §2.2：横轴八卦↔专业，纵轴时长（最长 6min）。
/// 余额门禁在这一屏，因为这是**烧 token 之前的最后一屏**——
/// 跑完才发现余额不够是不能接受的。判定在 `DialState.canAfford`，这里只画。
struct ConfirmView: View {
    let news: NewsRef
    @State private var dial: DialState
    let onBack: () -> Void
    let onStart: (DialState) -> Void

    init(news: NewsRef, dial: DialState = DialState(),
         onBack: @escaping () -> Void, onStart: @escaping (DialState) -> Void) {
        self.news = news
        _dial = State(initialValue: dial)
        self.onBack = onBack
        self.onStart = onStart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BriefTopRow(onBack: onBack) { NewsTagCard(news: news) }

            VStack(spacing: 0) {
                DialControl(dial: $dial)
                // mock：盘下一行，右侧「≈120K · ¥0.35」。左侧 mock 上是「N 源 · N 事实点」，
                // 没有数据来源，不画（spec §6 ④）。
                HStack {
                    Spacer()
                    Text(costText)
                        .font(BriefTheme.mono(11.5))
                        .foregroundStyle(dial.canAfford ? BriefTheme.text4 : BriefTheme.danger)
                }
                .padding(.horizontal, 2)
                .padding(.top, 12)
            }
            .padding(.horizontal, BriefTheme.Metric.pagePadding)
            .padding(.top, 24)

            Spacer(minLength: 0)

            if let reason = dial.blockReason {
                // spec §10.1：拒绝时给出差额，不是一句「余额不够」。
                Text(reason)
                    .font(BriefTheme.mono(12.5))
                    .foregroundStyle(BriefTheme.danger)
                    .padding(.horizontal, BriefTheme.Metric.pagePadding)
                    .padding(.bottom, 12)
            }
            PrimaryButton(
                title: dial.canAfford ? "开始调研" : "余额不够，去充值",
                tone: dial.canAfford ? .accent : .broke,
                isEnabled: dial.canAfford
            ) { onStart(dial) }
            .padding(.horizontal, BriefTheme.Metric.pagePadding)
            .padding(.bottom, BriefTheme.Metric.bottomInset)
        }
    }

    /// 「≈120K · ¥0.35」；买不起时前缀「超出余额」。
    private var costText: String {
        let body = "≈\(dial.estimate.tokens / 1000)K · ¥"
            + String(format: "%.2f", Double(dial.estimate.costCents) / 100)
        return dial.canAfford ? body : "超出余额 " + body
    }
}
```

- [ ] **Step 4: 纪律 grep、编译、测试台**

```bash
grep -nE '\.secondary|\.tertiary|\.quaternary|\.borderedProminent|systemBackground|Color\(red:|0x[0-9A-Fa-f]{6}|\.tint\b' "ios/Pollux One/Features/Brief/DialControl.swift" "ios/Pollux One/Features/Brief/ConfirmView.swift"
```

Expected: 无输出。§0.3 编译 → `** BUILD SUCCEEDED **`；`bash scripts/test-engines.sh 2>&1 | tail -1` → `0 failed`。

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/Features/Brief/DialControl.swift" "ios/Pollux One/Features/Brief/ConfirmView.swift"
git commit -m "$(cat <<'EOF'
Make the dial a viewfinder, and hatch the part you cannot pay for

The confirm screen's pad becomes the mock's 372pt square: thirds grid,
corner brackets, a crosshair through a square knob, the clock and the
register name inside the frame, and a hatched band on every duration row
past the point the balance reaches. When the balance falls short the
knob, the readout and the cost line turn red and the button becomes the
dark "余额不够，去充值" that cannot be pressed.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: ③ Domain —— 口述档的两个视觉态，没有出口

**Files:**
- Modify: `ios/Pollux One/Domain/Brief/HandOffState.swift`（整文件替换）
- Modify: `ios/EngineHarness/BriefScenarios.swift`

- [ ] **Step 1: 写断言**

`runBriefSuite()` 末尾 `return` 之前插入：

```swift
    report.section("③ 口述档：两个视觉态，没有出口")
    var voice = HandOffState(mode: .speaking)
    report.check(voice.voicePhase == .idle, "一进来是 idle")
    report.check(!voice.canProceed, "口述档 idle 不能开始——没有语音抓取就没有可交的东西")
    voice.toggleListening()
    report.check(voice.voicePhase == .listening, "点一下开始听")
    report.check(!voice.canProceed, "听的时候也不能开始")
    voice.toggleListening()
    report.check(voice.voicePhase == .idle, "再点一下停")
    var switched = HandOffState(mode: .speaking)
    switched.toggleListening()
    switched.mode = .typing
    report.check(switched.voicePhase == .idle, "切回打字档自动停止听")
    var typed = HandOffState(mode: .typing)
    typed.toggleListening()
    report.check(typed.voicePhase == .idle, "打字档没有「听」这回事")
    typed.text = "https://example.com/news"
    report.check(typed.canProceed, "打字档有字就能走，不受口述档影响")
```

- [ ] **Step 2: 跑，确认编译失败**

Run: `bash scripts/test-engines.sh 2>&1 | grep -m1 "error:"`
Expected: `error: value of type 'HandOffState' has no member 'voicePhase'`

- [ ] **Step 3: 替换 `HandOffState.swift`**

```swift
import Foundation

enum HandOffMode: String, Equatable { case typing, speaking }
enum SecondaryEntry: String, Equatable { case screenshot, shareSheet }

/// 口述档的两个视觉态。没有 done：没有语音抓取就没有转写可以落成 done
/// （spec §6 ③）。真接上语音之后再加，连同「就查这个」那个出口。
enum HandOffVoicePhase: String, Equatable { case idle, listening }

struct HandOffState: Equatable {
    var mode: HandOffMode {
        // 切回打字档就停止听：听着听着换了档，麦克风不该还亮着。
        didSet { if mode == .typing { voicePhase = .idle } }
    }
    var voicePhase: HandOffVoicePhase = .idle
    var text = ""
    var clipboardAuthorized = false
    var clipboardHasContent = false

    init(mode: HandOffMode = .typing,
         clipboardAuthorized: Bool = false,
         clipboardHasContent: Bool = false) {
        self.mode = mode
        self.clipboardAuthorized = clipboardAuthorized
        self.clipboardHasContent = clipboardHasContent
    }

    /// 一个框。链接和整段正文对管线是同一件事，分成两个框等于让用户
    /// 替我们做分类。
    var inputFieldCount: Int { mode == .typing ? 1 : 0 }

    /// 未授权或剪贴板为空时**整条消失**，不是禁用。
    /// 一个灰掉的按钮会招来一次点击，然后再解释自己为什么不能用。
    var showsClipboardBar: Bool {
        mode == .typing && clipboardAuthorized && clipboardHasContent
    }

    /// 这两个是一类：东西在别处。
    var secondaryEntries: [SecondaryEntry] { [.screenshot, .shareSheet] }

    /// 只在口述档有意义：idle ↔ listening。打字档没有「听」这回事。
    mutating func toggleListening() {
        guard mode == .speaking else { return }
        voicePhase = voicePhase == .idle ? .listening : .idle
    }

    /// 打字档：有非空文字。口述档：**一律不能**——没有语音抓取就没有可交的东西，
    /// 这是一个诚实的死路，比一个假的活路好（spec §6 ③）。
    var canProceed: Bool {
        switch mode {
        case .typing: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .speaking: false
        }
    }
}
```

- [ ] **Step 4: 跑绿**

Run: `bash scripts/test-engines.sh 2>&1 | tail -1`
Expected: `0 failed`，passed 比 Task 9 结束时多 8。

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/Domain/Brief/HandOffState.swift" ios/EngineHarness/BriefScenarios.swift
git commit -m "$(cat <<'EOF'
Give the spoken hand-off two honest states and no false exit

Idle and listening are the only things the screen can truthfully show
until speech capture exists, so those are the only phases the state
has. Proceeding from the spoken tab is refused outright: the old path
went forward under an invented title, and a dead end that says so beats
a live one that lies.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: ③ 交给我 —— 重写

**Files:**
- Modify: `ios/Pollux One/Features/Brief/HandOffView.swift`（整文件替换）
- Modify: `ios/Pollux One/Features/Brief/BriefFlow.swift`（`.handOff` 那一支）

- [ ] **Step 1: 读 mock**

Artifact 工具读 `project/Main.dc.html`。注意：「开始调研」在卡片**里**，只在打字档；口述档三态里只做前两态；`isDone` 那一段不画。

- [ ] **Step 2: 替换 `HandOffView.swift`**

```swift
import SwiftUI
import UIKit

/// ③ 交给我。spec §8 ③：`打字 / 说给我听` 两档。
/// 打字档是**一个**输入框——链接和整段正文对管线是同一件事，
/// 分成两个框等于让用户替我们做分类。
///
/// mock（`project/Main.dc.html`）：字标、「今天播什么？」、一张卡装着 tab 和输入，
/// 「或者」分隔，两枚并列的「上传截图 / 分享进来」。口述档只画 idle 和 listening
/// 两个态；done 态要等语音抓取，本 spec 不接（spec §6 ③）。
struct HandOffView: View {
    @State private var state: HandOffState
    let onBack: () -> Void
    let onSubmit: (HandOffState) -> Void
    let onPasteClipboard: () -> String?
    /// 剪贴板里那条的预览，给快捷条显示。nil 就写一句通用的。
    let clipboardPreview: String?
    let onScreenshot: () -> Void
    let onShareSheet: () -> Void

    /// listening 态的两处动画：外圈呼吸、五根竖条起伏。只是视觉，不代表任何数据。
    @State private var halo = false
    @State private var wave = false
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    init(state: HandOffState = HandOffState(),
         onBack: @escaping () -> Void,
         onSubmit: @escaping (HandOffState) -> Void,
         onPasteClipboard: @escaping () -> String? = { nil },
         clipboardPreview: String? = nil,
         onScreenshot: @escaping () -> Void = {},
         onShareSheet: @escaping () -> Void = {}) {
        _state = State(initialValue: state)
        self.onBack = onBack
        self.onSubmit = onSubmit
        self.onPasteClipboard = onPasteClipboard
        self.clipboardPreview = clipboardPreview
        self.onScreenshot = onScreenshot
        self.onShareSheet = onShareSheet
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BriefTopRow(onBack: onBack) {
                    Spacer(minLength: 0)
                    Text("POLLUX ONE")
                        .font(BriefTheme.sans(14, .bold))
                        .kerning(0.56)
                        .foregroundStyle(BriefTheme.accent)
                    Spacer(minLength: 0)
                    // 与左边的返回方块等宽，字标才真正居中。
                    Color.clear.frame(width: BriefTheme.Metric.backButtonSize,
                                      height: BriefTheme.Metric.backButtonSize)
                }
                Text("今天播什么？")
                    .font(BriefTheme.sans(30, .bold))
                    .kerning(-0.45)
                    .foregroundStyle(BriefTheme.text1)
                    .padding(.horizontal, BriefTheme.Metric.pagePadding)
                    .padding(.top, 36)
                card
                    .padding(.horizontal, BriefTheme.Metric.pagePadding)
                    .padding(.top, 26)
                orDivider
                    .padding(.horizontal, BriefTheme.Metric.pagePadding)
                    .padding(.top, 22)
                secondaryRow
                    .padding(.horizontal, BriefTheme.Metric.pagePadding)
                    .padding(.top, 16)
                    .padding(.bottom, BriefTheme.Metric.bottomInset)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { haptics.prepare() }
    }

    // MARK: 卡片

    private var card: some View {
        VStack(spacing: 0) {
            tabBar
            if state.mode == .typing {
                typingPane
            } else {
                speakingPane
            }
        }
        .background(BriefTheme.surface, in: RoundedRectangle(cornerRadius: BriefTheme.Metric.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BriefTheme.Metric.cardRadius)
                .stroke(BriefTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: BriefTheme.Metric.cardRadius))
    }

    /// mock：底 rgba(0,0,0,0.22)、内边距 5、间距 4；tab 圆角 9、13pt 500；
    /// 选中 #2E2A24 底 text1 字，未选中透明 text4 字。替换系统 segmented picker。
    private var tabBar: some View {
        HStack(spacing: 4) {
            tab("打字", .typing)
            tab("说给我听", .speaking)
        }
        .padding(5)
        .background(Color.black.opacity(0.22))
    }

    private func tab(_ title: String, _ mode: HandOffMode) -> some View {
        let selected = state.mode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { state.mode = mode }
        } label: {
            Text(title)
                .font(BriefTheme.sans(13, .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? BriefTheme.tabActive : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(selected ? BriefTheme.text1 : BriefTheme.text4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: 打字档

    private var typingPane: some View {
        VStack(spacing: 11) {
            // 未授权或剪贴板为空时整条不出现——一个灰掉的按钮会招来一次点击，
            // 然后再解释自己为什么不能用。判定在 HandOffState.showsClipboardBar。
            if state.showsClipboardBar {
                clipboardBar
            }
            // 一个框，链接与正文合一。mock：#0F0E0C 底、#333029 边、圆角 10、14.5pt。
            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.text)
                    .font(BriefTheme.sans(14.5))
                    .foregroundStyle(BriefTheme.text1)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 110)
                if state.text.isEmpty {
                    Text("贴链接，或写一句「某某公司又裁员了」")
                        .font(BriefTheme.sans(14.5))
                        .foregroundStyle(BriefTheme.placeholder)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(BriefTheme.input, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BriefTheme.borderInput, lineWidth: 1))

            // 「开始调研」在卡片里，且只在打字档出现（spec §6 ③）。
            PrimaryButton(title: "开始调研", size: .compact, isEnabled: state.canProceed) {
                onSubmit(state)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 15, bottom: 15, trailing: 15))
    }

    /// mock：#1E1C18 底、#38332B 边、圆角 9；图标 + 剪贴板内容单行截断 + 右侧「用」。
    private var clipboardBar: some View {
        Button {
            if let pasted = onPasteClipboard() { state.text = pasted }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 13))
                    .foregroundStyle(BriefTheme.text3)
                Text(clipboardPreview ?? "剪贴板里的那条")
                    .font(BriefTheme.sans(13.5))
                    .foregroundStyle(BriefTheme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("用")
                    .font(BriefTheme.sans(13, .medium))
                    .foregroundStyle(BriefTheme.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(BriefTheme.clipboardRow, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BriefTheme.clipboardBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("用剪贴板里的那条")
    }

    // MARK: 口述档

    private var isListening: Bool { state.voicePhase == .listening }

    /// idle：68pt 青铜圆 + 麦克风 + 一句示例。listening：外圈呼吸光晕 + 五根竖条。
    /// 没有转写那一行——没有语音抓取就没有字可写，一行占位都不编。
    private var speakingPane: some View {
        VStack(spacing: 16) {
            ZStack {
                if isListening {
                    Circle()
                        .fill(BriefTheme.accent.opacity(0.35))
                        .frame(width: 68, height: 68)
                        .scaleEffect(halo ? 1.09 : 1)
                        .opacity(halo ? 0.6 : 0.25)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: halo)
                        .onAppear { halo = true }
                        .onDisappear { halo = false }
                }
                Button {
                    state.toggleListening()
                    haptics.impactOccurred()
                } label: {
                    ZStack {
                        Circle().fill(BriefTheme.accent).frame(width: 68, height: 68)
                        if isListening {
                            waveBars
                        } else {
                            Image(systemName: "mic")
                                .font(.system(size: 27, weight: .regular))
                                .foregroundStyle(BriefTheme.onAccent)
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isListening ? "说完了" : "开始口述")
            }
            .frame(width: 68, height: 68)

            if !isListening {
                Text("「央行降准那条，我想从房贷角度切」")
                    .font(BriefTheme.sans(13.5))
                    .foregroundStyle(BriefTheme.text3)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 18)
    }

    /// mock：五根 3pt 宽的竖条，高 13 / 23 / 17 / 25 / 12，相位各差 0.15s，0.22 ↔ 1 起伏。
    private var waveBars: some View {
        HStack(spacing: 3) {
            ForEach(Array([13, 23, 17, 25, 12].enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(BriefTheme.onAccent)
                    .frame(width: 3, height: CGFloat(height))
                    .scaleEffect(y: wave ? 1 : 0.22, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: wave
                    )
            }
        }
        .onAppear { wave = true }
        .onDisappear { wave = false }
    }

    // MARK: 或者 · 并列两枚

    private var orDivider: some View {
        HStack(spacing: 13) {
            Rectangle().fill(BriefTheme.rule).frame(height: 1)
            Text("或者")
                .font(BriefTheme.sans(11.5))
                .foregroundStyle(BriefTheme.text4)
            Rectangle().fill(BriefTheme.rule).frame(height: 1)
        }
    }

    /// 截图与分享并列：它们是同一个意思——东西在别处。
    /// mock：surface 底 border 边圆角 12；图标 19 + 14.5pt 500；内边距 16 / 14。
    private var secondaryRow: some View {
        HStack(spacing: 10) {
            ForEach(state.secondaryEntries, id: \.rawValue) { entry in
                Button {
                    switch entry {
                    case .screenshot: onScreenshot()
                    case .shareSheet: onShareSheet()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon(entry))
                            .font(.system(size: 17))
                            .foregroundStyle(BriefTheme.text2)
                        Text(title(entry))
                            .font(BriefTheme.sans(14.5, .medium))
                            .foregroundStyle(BriefTheme.text1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                    .background(BriefTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(BriefTheme.border, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(_ entry: SecondaryEntry) -> String {
        switch entry {
        case .screenshot: "photo.on.rectangle"
        case .shareSheet: "square.and.arrow.up"
        }
    }

    private func title(_ entry: SecondaryEntry) -> String {
        switch entry {
        case .screenshot: "上传截图"
        case .shareSheet: "分享进来"
        }
    }
}
```

- [ ] **Step 3: `BriefFlow` 去掉假标题的兜底**

`BriefFlow.swift` 里 `case .handOff:` 那一支改成：

```swift
        case .handOff:
            HandOffView(
                onBack: back(from: .handOff),
                // 只会从打字档、带非空文字被调用（HandOffState.canProceed）。
                // 口述档没有提交出口，所以「口述的一条新闻」那个兜底成了死代码，删掉。
                onSubmit: { state in
                    handedOff = NewsRef(
                        publisher: "你交给我的",
                        title: state.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        url: nil
                    )
                    screen = .confirm
                }
            )
```

- [ ] **Step 4: 纪律 grep、编译、测试台**

```bash
grep -nE '\.secondary|\.tertiary|\.quaternary|\.borderedProminent|systemBackground|Color\(red:|0x[0-9A-Fa-f]{6}|\.tint\b|segmented|口述的一条新闻' "ios/Pollux One/Features/Brief/HandOffView.swift" "ios/Pollux One/Features/Brief/BriefFlow.swift"
```

Expected: 无输出。§0.3 编译 → `** BUILD SUCCEEDED **`；`bash scripts/test-engines.sh 2>&1 | tail -1` → `0 failed`。

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/Features/Brief/HandOffView.swift" "ios/Pollux One/Features/Brief/BriefFlow.swift"
git commit -m "$(cat <<'EOF'
Ask "今天播什么？" the way the mock asks it

The hand-off screen gains the wordmark, the headline, a card that holds
the tab strip, the clipboard shortcut, the single input and its own
开始调研, then the "或者" rule and the two side-by-side entries. The
spoken tab shows a bronze microphone and, while listening, a breathing
halo with five moving bars — and no transcript line, because there is
no transcript. The flow drops its invented "口述的一条新闻" title.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: ⑦ Domain —— 列表行长出卡片要的字段，并分组

**Files:**
- Modify: `ios/Pollux One/Domain/Brief/BriefModels.swift`（`ScriptListRow` / `ScriptListRows` 两段替换）
- Modify: `ios/EngineHarness/BriefScenarios.swift`
- Modify: `ios/Pollux One/Features/ScriptList/ScriptListView.swift`（一行，让 app 在 Task 13 之前仍能编译）

- [ ] **Step 1: 改旧断言、加新断言**

`BriefScenarios.swift` 里 `report.section("⑦ 换一篇")` 那一节，这一行：

```swift
    report.check(rows.first?.subtitle == "调研中", "显示进度而不是秒数")
```

替换为：

```swift
    report.check(rows.first?.stageLine == "交叉验证 9 / 23",
                 "在跑的那条显示当前阶段而不是秒数", detail: rows.first?.stageLine ?? "nil")
    report.check(rows.first?.seconds == nil, "在跑的没有秒数可报")
    report.check(rows.first?.tokensUsedK == 48, "已消耗 48K", detail: "\(rows.first?.tokensUsedK ?? -1)")
    report.check(rows.first?.progress.map { abs($0 - 4.0 / 9.0) < 0.001 } == true,
                 "九个阶段完成了四个", detail: "\(rows.first?.progress ?? -1)")
    report.check(rows.first?.group == .researching, "分到「正在调研」组")
    let readyRow = ScriptListRows.build(scriptTitles: [], briefs: [brief]).first
    report.check(readyRow?.seconds == 83 && readyRow?.strong == 2 && readyRow?.weak == 1,
                 "可审的那篇：83 秒、2 绿 1 黄",
                 detail: "\(readyRow?.seconds ?? -1) \(readyRow?.strong ?? -1) \(readyRow?.weak ?? -1)")
    report.check(readyRow?.stageLine == nil && readyRow?.progress == nil && readyRow?.tokensUsedK == nil,
                 "可审的不报阶段、进度、token")
    report.check(readyRow?.group == .ready, "分到「可以拍了」组")
    report.check(rows[1].group == .ready && rows[1].strong == 0 && rows[1].weak == 0 && rows[1].seconds == 60,
                 "Web 稿一律「可以拍了」，有秒数，没有绿黄计数")
    var starved = brief
    starved.status = .insufficient
    let starvedRow = ScriptListRows.build(scriptTitles: [], briefs: [starved]).first
    report.check(starvedRow?.group == .insufficient && starvedRow?.seconds == nil,
                 "信源不足的单列一组，不报秒数——播不了的稿不该标着秒数")
```

- [ ] **Step 2: 跑，确认编译失败**

Run: `bash scripts/test-engines.sh 2>&1 | grep -m1 "error:"`
Expected: `error: value of type 'ScriptListRow' has no member 'stageLine'`

- [ ] **Step 3: 替换 `BriefModels.swift` 里 `ScriptListRow` 与 `ScriptListRows` 两段**

从 `/// 「换一篇」的一行。` 那行注释开始，到 `enum ScriptListRows { ... }` 的右花括号为止，整段替换为：

```swift
/// 「换一篇」里的分组。mock 上只有前两组；信源不足的那组 mock 没画（画布上
/// 没有这种稿），样式沿用稿卡，spec §6 ⑦ 有说明。
enum ScriptListGroup: String, Equatable, CaseIterable {
    case researching = "正在调研"
    case ready = "可以拍了"
    case insufficient = "信源不足"
}

/// 「换一篇」的一行。Brief 在跑的时候还不是 Script，所以列表是两者的合并流。
/// 字段全部从 mock 上的可见内容反推（`project/Scripts.dc.html`）：mock 上没有的不加。
struct ScriptListRow: Equatable, Identifiable {
    let id: String
    let title: String
    /// 只有 `.ready` 的 Brief 和 Web 稿有秒数。在跑的还没有；信源不足的不报——
    /// 一篇播不了的稿标着秒数，读起来像能播。
    let seconds: Int?
    /// 绿 / 黄句数（`SentenceCounts`）。Web 稿没有信源这一说，一律 0。
    let strong: Int
    let weak: Int
    /// 在跑的那一篇当前阶段：「交叉验证 9 / 23」。其余 nil。
    let stageLine: String?
    /// 已消耗的 token，千为单位。只有在跑的才报。
    let tokensUsedK: Int?
    /// 已完成阶段 / 总阶段。只有在跑的才有。
    let progress: Double?
    /// Brief 的状态；Web 稿是 nil。
    let status: BriefStatus?

    var isResearching: Bool { status == .researching }

    var group: ScriptListGroup {
        switch status {
        case .researching: .researching
        case .insufficient: .insufficient
        case .ready, nil: .ready
        }
    }
}

enum ScriptListRows {
    static func build(scriptTitles: [(id: String, title: String, seconds: Int)],
                      briefs: [Brief]) -> [ScriptListRow] {
        let briefRows = briefs.map { brief -> ScriptListRow in
            let counts = SentenceCounts(brief.sentences, claims: brief.claims)
            let researching = brief.status == .researching
            let running = brief.stages.first { $0.state == .running }
            let done = brief.stages.filter { $0.state == .done }.count
            return ScriptListRow(
                id: brief.id,
                title: brief.news.title,
                seconds: brief.status == .ready ? brief.estimatedSeconds : nil,
                strong: counts.strong,
                weak: counts.weak,
                stageLine: researching
                    ? running.map { [$0.name, $0.count].compactMap { $0 }.joined(separator: " ") }
                    : nil,
                tokensUsedK: researching ? brief.budget.used / 1000 : nil,
                progress: researching && !brief.stages.isEmpty
                    ? Double(done) / Double(brief.stages.count)
                    : nil,
                status: brief.status
            )
        }
        let scriptRows = scriptTitles.map {
            ScriptListRow(id: $0.id, title: $0.title, seconds: $0.seconds,
                          strong: 0, weak: 0, stageLine: nil, tokensUsedK: nil,
                          progress: nil, status: nil)
        }
        // 在跑的排最前：那是用户此刻最想看的东西。
        return briefRows.filter(\.isResearching) + scriptRows
            + briefRows.filter { !$0.isResearching }
    }
}
```

- [ ] **Step 4: 跑绿**

Run: `bash scripts/test-engines.sh 2>&1 | tail -1`
Expected: `0 failed`，passed 比 Task 11 结束时多 9（换掉 1 条，新加 10 条）。

- [ ] **Step 5: 让 app 仍能编译**

`ScriptListView.swift` 里 `ScriptListRowView` 的 `Text(row.subtitle)` 改为：

```swift
                Text(row.stageLine ?? row.seconds.map { "\($0) 秒" } ?? "")
```

Run（§0.3）。Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Domain/Brief/BriefModels.swift" ios/EngineHarness/BriefScenarios.swift "ios/Pollux One/Features/ScriptList/ScriptListView.swift"
git commit -m "$(cat <<'EOF'
Let a list row carry what the mock's cards show

Seconds, green and yellow counts, the running stage with its count, the
tokens burned so far, and a done-over-total progress — each computed in
the Domain from the brief and asserted in the harness, so the card view
only has to lay them out. Rows also know which of the three groups they
belong to; an insufficient brief reports no seconds, because a script
that cannot be broadcast should not look timed.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: ⑦ 换一篇 —— 三组卡片

**Files:**
- Modify: `ios/Pollux One/Features/ScriptList/ScriptListView.swift`（整文件替换）

- [ ] **Step 1: 读 mock**

Artifact 工具读 `project/Scripts.dc.html`。「2 小时前」那个相对时间和 Web 稿旁的独立编辑方块不画（spec §6 ⑦）。

- [ ] **Step 2: 替换 `ScriptListView.swift`**

```swift
import SwiftUI

/// ⑦ 换一篇。只从 ② 的「换一篇」进，不在主路径上——低频的东西不该挡高频的路。
///
/// spec §9.2 ②：列表是 **Brief + Script 的合并流**。一篇还在调研的 Brief 还不是
/// Script，`viewModel.scripts` 装不下它——只画 scripts 就会悄悄漏掉用户此刻
/// 最想看的那一条。合并、排序、分组、每张卡上的数字都在 `ScriptListRows` /
/// `ScriptListRow` 里，这里只负责画。
///
/// 这一屏由 `BriefFlow` 盖在相机上，所以**没有自己的 NavigationStack**：
/// 返回是顶行那个方块，标题写在它旁边。选一篇 Web 稿不再 push 第二个相机，
/// 而是把稿交回去（`onSelectScript`），根上的那台相机自己装。
struct ScriptListView: View {
    @State private var viewModel: ScriptListViewModel
    private let syncService: ScriptSyncService
    /// 还没有变成 Script 的那些——在跑的、可审的、信源不足的。
    private let briefs: [Brief]
    /// 在跑的那一篇已经跑了多久，`BriefFlow` 的时钟。
    private let elapsed: String
    private let onBack: () -> Void
    /// 点中了哪一条 Brief。列表里不止一条，所以"去哪一屏"之外还得说清
    /// "看的是哪一篇"——容器靠这一下把当前选中切过去。
    private let onSelect: (Brief) -> Void
    /// 跳去 Brief 那一侧的屏（「从一条新闻开始」，以及点一条 Brief）。
    private let onOpen: (BriefScreen) -> Void
    /// 点中了一篇 Web 稿：交给根上的相机去装。
    private let onSelectScript: (Script) -> Void

    init(syncService: ScriptSyncService,
         briefs: [Brief] = [],
         elapsed: String = "00:00",
         onBack: @escaping () -> Void = {},
         onSelect: @escaping (Brief) -> Void = { _ in },
         onOpen: @escaping (BriefScreen) -> Void = { _ in },
         onSelectScript: @escaping (Script) -> Void = { _ in }) {
        self.syncService = syncService
        self.briefs = briefs
        self.elapsed = elapsed
        self.onBack = onBack
        self.onSelect = onSelect
        self.onOpen = onOpen
        self.onSelectScript = onSelectScript
        _viewModel = State(wrappedValue: ScriptListViewModel(syncService: syncService))
    }

    /// 同 id 的两份只留先到的那一份。加载器已经去过重，这里再挡一道，
    /// 是因为 `uniqueKeysWithValues` 撞键会直接崩——列表不该有这种雷。
    private var briefsByID: [String: Brief] {
        Dictionary(briefs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var scriptsByID: [String: Script] {
        Dictionary(uniqueKeysWithValues: viewModel.scripts.map { ($0.id.uuidString, $0) })
    }

    private var rows: [ScriptListRow] {
        ScriptListRows.build(
            scriptTitles: viewModel.scripts.map {
                (id: $0.id.uuidString, title: $0.title, seconds: Self.estimatedSeconds($0))
            },
            briefs: briefs
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            BriefTopRow(onBack: onBack) {
                Text("换一篇")
                    .font(BriefTheme.sans(19, .bold))
                    .foregroundStyle(BriefTheme.text1)
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 创建是低频动作，但它得有入口。原先只在空状态和工具栏里露面，
                    // 有稿的人就再起不了一篇。
                    PrimaryButton(title: "从一条新闻开始", icon: "plus") { onOpen(.handOff) }
                        .padding(.horizontal, BriefTheme.Metric.pagePadding)
                        .padding(.top, 22)

                    if viewModel.isLoading && rows.isEmpty {
                        loading
                    }
                    ForEach(ScriptListGroup.allCases, id: \.self) { group in
                        section(group)
                    }
                    if rows.isEmpty && !viewModel.isLoading {
                        note(ScriptListEmptyState().text)
                    } else if !rows.isEmpty {
                        note("点一篇直接载入提词器，相机已经在等着了。")
                    }
                }
            }
            .refreshable { await viewModel.refresh() }
        }
        .task { await viewModel.onAppear() }
    }

    /// 一组：组名 + 卡片。没有这一组的稿就整组不出现。
    /// mock：组名 11.5pt #8A847A 字距 0.06em；组内间距 11；组间 28。
    @ViewBuilder
    private func section(_ group: ScriptListGroup) -> some View {
        let items = rows.filter { $0.group == group }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Text(group.rawValue)
                    .font(BriefTheme.sans(11.5))
                    .kerning(0.7)
                    .foregroundStyle(BriefTheme.text4)
                ForEach(items) { row in
                    Button { open(row) } label: {
                        if row.isResearching {
                            ResearchingCard(row: row, elapsed: elapsed)
                        } else {
                            ScriptCard(row: row)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, BriefTheme.Metric.pagePadding)
            .padding(.top, 28)
        }
    }

    private func open(_ row: ScriptListRow) {
        if let brief = briefsByID[row.id] {
            // 先切当前，再跳屏：跳过去那一屏读的就是这一篇。去哪由 ScriptSlot 定。
            onSelect(brief)
            onOpen(ScriptSlot(brief: brief).destination)
        } else if let script = scriptsByID[row.id] {
            onSelectScript(script)
        }
    }

    private var loading: some View {
        HStack(spacing: 10) {
            StageSpinner(size: 14, lineWidth: 2.2)
            Text("正在同步稿子…")
                .font(BriefTheme.sans(13))
                .foregroundStyle(BriefTheme.text3)
        }
        .padding(BriefTheme.Metric.pagePadding)
    }

    /// 底部那条提示。mock：#141311 底、圆角 10、chevron + 12pt 灰字。
    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BriefTheme.text4)
                .padding(.top, 2)
            Text(text)
                .font(BriefTheme.sans(12))
                .foregroundStyle(BriefTheme.text4)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(BriefTheme.noteBg, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, BriefTheme.Metric.pagePadding)
        .padding(.top, 28)
        .padding(.bottom, BriefTheme.Metric.bottomInset)
    }

    /// 列表上的秒数按语种的默认语速估，不是按这个用户自己的语速——
    /// 后者要等他真的读过一遍才有（spec §9.2 ①）。
    private static func estimatedSeconds(_ script: Script) -> Int {
        let text = script.fullText
        let rate = ScriptLanguage.detect(text).defaultCharactersPerSecond
        return max(1, Int((Double(text.count) / rate).rounded()))
    }
}

/// 在跑的那一篇。mock：surface 底、青铜 26% 边、圆角 12；旋转环 + 标题；
/// 「交叉验证 9 / 23」与「48K · 04:12」两头；底下 3pt 进度槽。
private struct ResearchingCard: View {
    let row: ScriptListRow
    let elapsed: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                StageSpinner(size: 14, lineWidth: 2.2)
                Text(row.title)
                    .font(BriefTheme.sans(14.5))
                    .foregroundStyle(BriefTheme.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            HStack {
                if let stageLine = row.stageLine {
                    Text(stageLine)
                        .font(BriefTheme.mono(11.5))
                        .foregroundStyle(BriefTheme.text3)
                }
                Spacer(minLength: 0)
                if let tokens = row.tokensUsedK {
                    Text("\(tokens)K · \(elapsed)")
                        .font(BriefTheme.mono(11.5))
                        .foregroundStyle(BriefTheme.text4)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(BriefTheme.dividerSoft)
                    Capsule()
                        .fill(BriefTheme.accent)
                        .frame(width: geo.size.width * CGFloat(row.progress ?? 0))
                }
            }
            .frame(height: 3)
        }
        .padding(EdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16))
        .background(BriefTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BriefTheme.accent.opacity(0.26), lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// 可以拍的（Brief 或 Web 稿）与信源不足的。mock：surface 底、#262320 边、圆角 12；
/// 标题 15pt；次行 mono 11.5：秒数 · 圆点 · 「5 绿」「1 黄」（为 0 不写）。
/// 信源不足的换 danger 边；它没有秒数（`ScriptListRow.seconds` 已经是 nil）。
private struct ScriptCard: View {
    let row: ScriptListRow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(row.title)
                .font(BriefTheme.sans(15))
                .foregroundStyle(BriefTheme.text1)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 9) {
                if let seconds = row.seconds {
                    Text("\(seconds)秒")
                        .font(BriefTheme.mono(11.5))
                        .foregroundStyle(BriefTheme.text2)
                }
                if row.seconds != nil && row.strong + row.weak > 0 {
                    Circle().fill(BriefTheme.neutralLine).frame(width: 3, height: 3)
                }
                if row.strong > 0 {
                    Text("\(row.strong) 绿")
                        .font(BriefTheme.mono(11.5))
                        .foregroundStyle(BriefTheme.strong)
                }
                if row.weak > 0 {
                    Text("\(row.weak) 黄")
                        .font(BriefTheme.mono(11.5))
                        .foregroundStyle(BriefTheme.weak)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15))
        .background(BriefTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(row.group == .insufficient ? BriefTheme.danger : BriefTheme.borderSoft, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 3: 纪律 grep、编译、测试台**

```bash
grep -nE '\.secondary|\.tertiary|\.quaternary|\.borderedProminent|systemBackground|Color\(red:|0x[0-9A-Fa-f]{6}|NavigationStack|navigationTitle|\.toolbar|NavigationLink|\.headline|\.caption' "ios/Pollux One/Features/ScriptList/ScriptListView.swift"
```

Expected: 无输出。§0.3 编译 → `** BUILD SUCCEEDED **`；`bash scripts/test-engines.sh 2>&1 | tail -1` → `0 failed`。

- [ ] **Step 4: 提交**

```bash
git add "ios/Pollux One/Features/ScriptList/ScriptListView.swift"
git commit -m "$(cat <<'EOF'
Lay 换一篇 out as the mock's three groups of cards

A running brief gets a bronze-edged card with its stage, tokens, clock
and a thin progress bar; a ready one shows seconds and its green and
yellow counts; an insufficient one sits in its own group behind a red
edge with no seconds to its name. Nothing here computes: every number
comes off ScriptListRow.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: 相机主屏 —— 控件在任何状态下都拥有自己的点击

**Files:**
- Modify: `ios/Pollux One/Features/Recording/ShutterRowView.swift`（整文件替换）

已确认的症状（pollux 实测）：录制中翻转键被 `.disabled` 之后，点它会穿到相机预览的
`onTapGesture`，触发对焦并弹对焦框。规则一句话（spec §8）：**HUD 上的每个控件，在任何
状态下都吞掉落在自己身上的点击。** 对焦只响应落在裸画面上的点。

参数行与镜头药丸不改（spec §8）：命中区略小于 44，但没有误触报告，放大它们要动 HUD 尺寸。
`RecordingView` 不改：不做整片禁焦区，画面下三分之一仍然可以对焦。

- [ ] **Step 1: 替换 `ShutterRowView.swift`**

```swift
import SwiftUI

/// The bottom row: safe-word meter (left) · shutter (centre) · camera flip
/// (right), space-between, exactly as the spec lays it out. The safe word and
/// flip containers are equal width so the shutter stays optically centred.
///
/// 每个控件在任何状态下都拥有自己的点击（视觉对齐 spec §8）：两侧那两格各套
/// 一层 52×44 的 contentShape 并吞掉点击。否则翻转键在录制中被 `.disabled`
/// 之后，点它会穿到底下的相机预览、触发对焦并弹出对焦框——这是实测到的。
/// 电平表本来就不是按钮，同样吞掉：它是控件带的一部分，不是画面。
struct ShutterRowView: View {
    let isRecording: Bool
    let safeWordLevel: Float
    let safeWord: String
    let facing: CameraFacing
    let canFlip: Bool
    let onToggleRecording: () -> Void
    let onFlip: () -> Void

    private let sideWidth: CGFloat = 52
    /// 触达高度。视觉高度由内容决定，这是命中区的下限。
    private let sideHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            SafeWordIndicatorView(level: safeWordLevel, safeWord: safeWord)
                .frame(width: sideWidth, height: sideHeight)
                .contentShape(Rectangle())
                // 吞掉，不对焦。
                .onTapGesture { }

            Spacer()

            RecordButton(isRecording: isRecording, action: onToggleRecording)

            Spacer()

            FlipButton(facing: facing, isEnabled: canFlip, action: onFlip)
                .frame(width: sideWidth, height: sideHeight)
                .contentShape(Rectangle())
                // 启用时里面的 Button 先拿到点击；禁用时 Button 不再拦，
                // 这一层把点击吞掉，不让它穿到相机预览。
                .onTapGesture { }
        }
    }
}

/// Names the camera you're on rather than only offering a rotation glyph.
/// Which side is live decides whether the prompter is anywhere near the lens
/// you're looking into, so it's worth a word instead of an inference from a
/// mirrored preview.
private struct FlipButton: View {
    let facing: CameraFacing
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                Text(facing.displayName)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(1)
                    // Yellow is this HUD's "not the default state" colour, and
                    // BACK is exactly that: the prompter has left the lens.
                    .foregroundStyle(facing == .back ? HUDColor.iosYellow : .white.opacity(0.55))
            }
            .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
            // 命中区撑满外面给的 52×44，不只是图标和字那一小块。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Swapping the capture input mid-take ends the movie file early, so
        // the flip is off while rolling rather than silently killing a take.
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 33, style: .continuous)
                    .fill(HUDColor.recRed)
                    .frame(width: isRecording ? 30 : 62, height: isRecording ? 30 : 62)
                    .animation(.easeInOut(duration: 0.2), value: isRecording)
            }
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: 编译、测试台**

Run（§0.3）。Expected: `** BUILD SUCCEEDED **`。`bash scripts/test-engines.sh 2>&1 | tail -1` → `0 failed`。

- [ ] **Step 3: 真机 / 模拟器验收（能跑起来时）**

这一步只能在真机上完整做（模拟器没有摄像头，录不了）。三条：

1. 开始录制 → 点右下角灰掉的翻转键 → **不出**对焦框，也不改变对焦点。
2. 点左下角 POLLUX 电平表 → **不出**对焦框。
3. 点两者旁边 8pt 以外的画面 → 正常出对焦框。

做不了就在提交信息里写明「待真机验证」，别写「已验证」。

- [ ] **Step 4: 提交**

```bash
git add "ios/Pollux One/Features/Recording/ShutterRowView.swift"
git commit -m "$(cat <<'EOF'
Let a disabled flip button keep its own tap

While recording, the flip control is disabled and SwiftUI stops routing
taps to it — so they fell through to the camera preview and refocused
the lens with a reticle where the user meant to press a button. Both
side slots of the shutter row now claim a 52×44 hit area and swallow the
tap in every state; the safe-word meter gets the same treatment because
it sits in the control band, not in the picture.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: 逐屏清单与 README

**Files:**
- Modify: `README.md`

前置：模拟器运行时。这一条要 pollux 亲自跑（大下载，需要登录 Xcode）：

```bash
xcodebuild -downloadPlatform iOS
xcrun simctl list runtimes            # 应看到 iOS 26.x
xcrun simctl list devices available | grep "Pollux One iPhone"
```

`Resources/demo-briefs/` 已经有 5 篇真稿（app 启动时优先读它们，`brief-fixture.json` 只是兜底），清单就用它们跑——七屏有真内容时对得更准。

- [ ] **Step 1: 起模拟器、装 app、看字体日志**

```bash
xcrun simctl boot "Pollux One iPhone" 2>/dev/null || true
cd ios && xcodebuild -project "Pollux One.xcodeproj" -scheme "Pollux One" \
  -destination 'platform=iOS Simulator,name=Pollux One iPhone' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
APP=$(find ~/Library/Developer/Xcode/DerivedData -type d -name "Pollux One.app" -path "*Build/Products/Debug-iphonesimulator*" | head -1)
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl install booted "$APP"
xcrun simctl launch --console booted "$BUNDLE" 2>&1 | grep -m1 "BriefFonts"
```

Expected: `BriefFonts: Plex Mono 可用`。看到「不可用」就回 Task 2 Step 7 查 bundle。

- [ ] **Step 2: 把 mock 摆在旁边**

浏览器打开 https://claude.ai/artifact/X3Jiga6RWyGyEhkstrPBEn ，七块画板并排。每屏截图：

```bash
xcrun simctl io booted screenshot ~/Desktop/brief-<屏号>.png
```

- [ ] **Step 3: 逐屏勾**

登录页随便填一组邮箱密码（Mock 后端不校验）→ 相机根屏 → 右下角那格进 ②。每屏都核的四条：

- [ ] 背景是 #0D0D0C 暖黑，不是纯黑（和相机根屏的纯黑对照一眼能分）
- [ ] 全屏没有一处系统蓝
- [ ] 返回是 36×36 描边方块，没有「相机 / 返回」文字
- [ ] 所有数字是 Plex Mono（与 mock 并排看 `83`、`48,240`、`1:00` 的字形）

各屏特有：

- [ ] ②：观点句是虚线边；点开一条证据，整行有 5% 底；「开拍」青铜；底栏上沿有分隔线；左滑事实句露两个按钮（重查 / 删除）、观点句一个
- [ ] ③：字标 + 「今天播什么？」 + 卡片 + 「或者」；tab 是胶囊不是系统 segmented；「开始调研」在卡片里，空输入时是 #2B2823 底的禁用态；切到「说给我听」没有「开始调研」；点麦克风进 listening（光晕 + 五根竖条），再点回 idle
- [ ] ④：372pt 方盘；拖动时十字准线跟着旋钮；两个推荐档位文字是「1:00 通俗」「3:00 偏专业」，点了旋钮吸过去；把 `Resources/demo-briefs/` 里 id 序最小那一篇的 `budget.remainingThisMonth` 临时改成 60000（app 读的是 demo 稿，不是 fixture）再跑一遍——右下出现斜纹、读数变红、按钮变暗红「余额不够，去充值」不可点，改回来
- [ ] ⑤：token 条三段青铜 + 三条刻度；图例带数值；进行中阶段是青铜底卡片、旋转环在转；完成的勾是绿的；顶行计时青铜色
- [ ] ⑥：图标红；「问题在哪」一张卡，首行 `2 / 3`；两个按钮一主一次；**没有**「仍然按现有材料出一稿」
- [ ] ⑦：没有「Pollux One」大标题；顶部青铜「从一条新闻开始」；分组卡片；点一篇 Web 稿回到相机且提词块出现、不出现第二个相机（Mock 后端的 scripts 列表里有稿才试得了这一条）

§8 那三条只能真机（Task 14 Step 3）。

- [ ] **Step 4: 改 README**

`README.md`「当前状态」下「已完成、可验证」那一组，`- **Backend**：...` 那一条之后加：

```markdown
- **iOS Brief 六屏视觉**：② 审稿 / ③ 交给我 / ④ 确认 / ⑤ 等待 / ⑥ 不建议播 / ⑦ 换一篇
  按 Claude Design mock 对齐（spec：`docs/superpowers/specs/2026-09-18-brief-visual-alignment-design.md`）。
  颜色一份 `BriefPalette`（测试台钉着）派生 `BriefTheme`，数字用打包的 IBM Plex Mono，
  中文用系统苹方。mock 上有、数据里没有的元素（⑥ 冲突卡、④「N 源 · N 事实点」、
  ⑦ 相对时间、③ 口述转写）故意没画。
```

- [ ] **Step 5: 最终门**

```bash
bash scripts/test-engines.sh 2>&1 | tail -1
cd ios && xcodebuild -project "Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
grep -rnE '\.secondary|\.tertiary|\.quaternary|\.borderedProminent|systemBackground|Color\(red:' "ios/Pollux One/Features/Brief" "ios/Pollux One/Features/ScriptList" || echo "clean"
```

Expected: `0 failed`（passed 比 Task 1 Step 1 记下的基线多 50）；`** BUILD SUCCEEDED **`；`clean`。

- [ ] **Step 6: 提交**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
Record that the six brief screens now match the mock

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## 收尾

实施完成后走 `superpowers:finishing-a-development-branch`。分支目前是 `pipeline-deterministic-core`，
上面还有管线的提交；视觉这一串是否单独开分支，动手前和 pollux 确认一句。
