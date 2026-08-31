# 提词器固定行窗 + 实测语速配速 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把提词器从「按句显示、按句跳」改成「固定 5/6 行行窗 + 衬底固定位 + 按实测语速连续配速」。

**Architecture:** 新增一层排版管线 `PromptScriptText`（唯一的文本拼接口径 + 句子字偏移表）→ `PromptLineLayout`（贪心断行，宽度测量经 `TextWidthMeasuring` 协议注入）→ `[PromptLine]`。新增 `ReadingPacer` 把离散、有延迟的语音对齐结果变成连续的字符光标（dead reckoning + 校正 + 前推上限）。`TeleprompterEngine` 改为持有行数组与配速器，按 30Hz tick 输出「当前行号 + 行内进度」；视图渲染整脚本的行并整体位移，衬底作为**固定层**画在文字下面。

**Tech Stack:** Swift 5 语言模式 + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`、SwiftUI、Observation、CoreText/UIKit（仅 `CoreTextLineMeasurer` 一个文件）。工程用 `PBXFileSystemSynchronizedRootGroup`（objectVersion 77），新增 `.swift` 文件自动进 target，**不需要**改 pbxproj。

**Spec:** `docs/superpowers/specs/2026-08-31-teleprompter-fixed-window-pacing-design.md`

**验证命令：**

```bash
./scripts/test-engines.sh
```

离线 harness，macOS 上直接 `swiftc` 编 Domain + 纯引擎源文件，无模拟器。执行本计划前的基线是 **107 passed, 0 failed**；每个 Task 结束时通过数只增不减。

```bash
xcodebuild -project "ios/Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS Simulator' build
```

iOS 侧编译验证。只有 Task 6/7/8 需要它——Task 1–5 全部能在 harness 里跑完。

---

## 背景：为什么这不是"调一下动画曲线"

提词器现在是**句驱动**的。`TeleprompterEngine.update(position:)` 取当前句前 1 后 2 共 4 句，视图里只有当前句允许换行并带衬底，上下文句一律 `lineLimit(1)` 截断。于是当前句排 1 行还是 3 行取决于它有多长，**整块 HUD 的高度每句变一次**，读者刚锁定的视线高度下一句就没了。这跟动画曲线无关，是布局本身在动。

同时 `SlidingWindowAlignmentEngine` 每次 `ingest` 都算出了句内 token 位置放进 `ReadingPosition.tokenIndexInSentence`（`ScriptAlignmentEngine.swift:103`），而 `TeleprompterEngine` **从来没读过这个字段**——唯一的细粒度信号被完整丢弃。也没有任何"速度"概念：位置完全等语音回调，识别一卡就原地定住，回来时跳一大步。

另外 `TeleprompterSettings.textWidthFraction`（默认 0.86）**从未被任何代码读取**，滑杆拖动无任何效果。固定行窗必须先知道排版宽度，所以这次要接通它。

---

## 文件结构

**新建：**

| 文件 | 职责 |
|---|---|
| `ios/Pollux One/Domain/ScriptLanguage.swift` | 语种判定 + 该语种的全部排版/配速常量。合并现有两处重复的 CJK 检测。无框架依赖，进 harness。 |
| `ios/Pollux One/Domain/PromptScriptText.swift` | 唯一的文本拼接口径 + 句子字符区间表 + 硬断点。纯数据，进 harness。 |
| `ios/Pollux One/Domain/PromptLineLayout.swift` | 贪心断行（含中日文禁则）+ `TextWidthMeasuring` 协议 + `PromptLine`。纯逻辑，进 harness。 |
| `ios/Pollux One/Engines/ReadingPacer.swift` | dead reckoning + 语音校正 + 前推上限。纯逻辑，进 harness。 |
| `ios/Pollux One/Features/Recording/CoreTextLineMeasurer.swift` | 唯一碰 UIKit/CoreText 的新文件：逐字符 advance。**不进** harness。 |
| `ios/EngineHarness/FakeTextMeasurer.swift` | 确定性假测量：CJK = 1em，其余 = 0.5em。让断行可精确断言。 |
| `ios/EngineHarness/LayoutScenarios.swift` | 语种判定、拼接口径、断行的离线场景。 |
| `ios/EngineHarness/PacingScenarios.swift` | 配速器与行窗逻辑的离线场景。 |

**修改：**

| 文件 | 改动 |
|---|---|
| `ios/Pollux One/Domain/TextTokenizer.swift` | 删掉私有 `Character` 扩展，改用 `ScriptLanguage.swift` 里的共享判定 |
| `ios/Pollux One/Engines/TeleprompterEngine.swift` | 重写：持有行 + 配速器，输出固定行窗 |
| `ios/Pollux One/Engines/SessionManager.swift:208` | `displayState.progress` → `readingProgress` |
| `ios/Pollux One/Features/Recording/TeleprompterOverlayView.swift` | 重写：固定高度裁剪窗、整体位移、固定衬底层、字级高亮、全局进度轨 |
| `ios/Pollux One/Features/Recording/RecordingView.swift` | 顶部遮罩 300 → 330；接通 `textWidthFraction`；挂 tick 生命周期 |
| `ios/EngineHarness/main.swift` | 挂上两个新 suite |
| `scripts/test-engines.sh` | 编译列表加 5 个源文件 |

**删除**（随 `TeleprompterOverlayView` / `TeleprompterEngine` 重写一并去掉）：`TeleprompterLine` 及其 `Emphasis` 枚举、`singleLine(_:opacity:)`、`isFirstUpcoming(_:)`、`rail(for:isLast:)`、`railBar(...)`、`Triangle`、`rowGap` / `railBleed` 常量、视图里的 `isCJK` / `effectiveTextSize` / `lineHeightMultiple`。

---

## Task 1: `ScriptLanguage` — 一处语种判定

CJK 检测现在有两份且已经漂移：`TeleprompterOverlayView.swift:30` 查 3 个码点区间（含 CJK 标点），`TextTokenizer.swift:42` 查 4 个区间（含兼容汉字和假名，不含标点）。后面每一个决策——字号、行高、句子拼接分隔符、默认语速、可见行数——都要按语种分流，先把这件事收成一处。

**Files:**
- Create: `ios/Pollux One/Domain/ScriptLanguage.swift`
- Create: `ios/EngineHarness/LayoutScenarios.swift`
- Modify: `ios/Pollux One/Domain/TextTokenizer.swift`
- Modify: `ios/EngineHarness/main.swift`
- Modify: `scripts/test-engines.sh`

- [ ] **Step 1: 写会失败的场景文件**

创建 `ios/EngineHarness/LayoutScenarios.swift`：

```swift
import Foundation

// Offline exercise of the prompter's typesetting layer: which script a text
// is, how a Script becomes one canonical string, and where the lines break.
//
// All three are silent-failure territory. A language misdetected by one
// percentage point flips the whole type scale and the visible row count. A
// concatenation that differs from the one used for offsets puts the reading
// cursor a few characters off — permanently, and worse the longer the script.
// A break rule that lets a line open with "。" is not a crash, it just looks
// like a bug to every reader.
//
// Widths come from FakeTextMeasurer, not a real font, so break positions can
// be asserted exactly on a Mac with no font installed.

@MainActor
func runLayoutSuite() -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("Prompter typesetting — language, canonical text, line breaks")

    report.section("language detection")

    report.check(ScriptLanguage.detect("大多数提词器都在解决错误的问题。") == .cjk,
                 "plain Chinese is CJK")
    report.check(ScriptLanguage.detect("Most teleprompters solve the wrong problem.") == .latin,
                 "plain English is Latin")
    report.check(ScriptLanguage.detect("Pollux One 从另一个问题出发。") == .cjk,
                 "Chinese prose carrying a Latin product name is still CJK")
    report.check(ScriptLanguage.detect("") == .latin,
                 "empty text does not crash and falls back to Latin")
    report.check(ScriptLanguage.detect("Shipping 十") == .latin,
                 "one stray ideogram in an English line does not flip it")

    report.section("per-language constants")

    report.check(ScriptLanguage.cjk.visibleRows == 5 && ScriptLanguage.latin.visibleRows == 6,
                 "5 visible rows in Chinese, 6 in Latin")
    report.check(ScriptLanguage.cjk.readRowsAbove == 1 && ScriptLanguage.latin.readRowsAbove == 2,
                 "1 dim history row in Chinese, 2 in Latin")
    report.check(ScriptLanguage.cjk.effectiveTextSize(base: 20) == 19,
                 "Chinese steps 20pt down to 19pt",
                 detail: "\(ScriptLanguage.cjk.effectiveTextSize(base: 20))")
    report.check(ScriptLanguage.latin.effectiveTextSize(base: 20) == 20,
                 "Latin keeps its size")
    report.check(ScriptLanguage.cjk.sentenceJoiner.isEmpty,
                 "Chinese sentences join with nothing — no space after 。")
    report.check(ScriptLanguage.latin.sentenceJoiner == " ",
                 "Latin sentences join with a space")

    report.section("the tokenizer keeps its old behaviour on the shared predicates")

    report.check(TextTokenizer.tokens(in: "你好世界") == ["你", "好", "世", "界"],
                 "CJK still tokenizes per character")
    report.check(TextTokenizer.tokens(in: "问题。它们") == ["问", "题", "它", "们"],
                 "CJK punctuation is still dropped rather than emitted")
    report.check(TextTokenizer.tokens(in: "Hello, world!") == ["hello", "world"],
                 "Latin still tokenizes per word, lowercased, depunctuated")

    return (report.pass, report.fail)
}
```

- [ ] **Step 2: 把 suite 挂进 harness**

修改 `ios/EngineHarness/main.swift`，在 `let archive = await runArchiveSuite()` 之后加一行，并把它算进合计：

```swift
let alignment = runAlignmentSuite()
let voice = runVoiceSuite()
let camera = runCameraSuite()
let archive = await runArchiveSuite()
let layout = runLayoutSuite()

let pass = alignment.pass + voice.pass + camera.pass + archive.pass + layout.pass
let fail = alignment.fail + voice.fail + camera.fail + archive.fail + layout.fail
print("\n══════ TOTAL: \(pass) passed, \(fail) failed ══════")
```

修改 `scripts/test-engines.sh`，在 `"$IOS/Domain/TextTokenizer.swift" \` 之前插入一行，并在 harness 文件里加上新场景文件：

```bash
  "$IOS/Domain/ScriptLanguage.swift" \
```

```bash
  ios/EngineHarness/LayoutScenarios.swift \
```

（`ScriptLanguage.swift` 必须排在 `TextTokenizer.swift` 之前吗？不必——`swiftc` 一次编译整个模块，文件顺序无关。按现有列表的分组习惯放在 Domain 段即可。）

- [ ] **Step 3: 运行，确认因为类型不存在而失败**

```bash
./scripts/test-engines.sh
```

Expected: 编译失败，`cannot find 'ScriptLanguage' in scope`。

- [ ] **Step 4: 写 `ScriptLanguage`**

创建 `ios/Pollux One/Domain/ScriptLanguage.swift`：

```swift
import Foundation

/// Which script the prompter is rendering, and everything that follows from
/// it: type scale, line height, how sentences join, what counts as a normal
/// reading speed, how many rows are visible.
///
/// Detected from content rather than a locale field on Script, because a
/// single script can legitimately mix the two — Chinese prose naming an
/// English product is still Chinese to lay out.
///
/// This consolidates two copies of the CJK test that had drifted apart:
/// `TeleprompterOverlayView` counted three code-point ranges (including CJK
/// punctuation), `TextTokenizer` used a four-range Character extension
/// (including kana and compatibility ideographs, excluding punctuation).
/// One definition now, and the tokenizer keeps its two-predicate split
/// because it treats ideographs and punctuation differently.
enum ScriptLanguage: Equatable {
    case cjk
    case latin

    /// A fifth of the text being CJK is enough. Mixed-script scripts in
    /// practice are Chinese with Latin names sprinkled in, and those must lay
    /// out as Chinese; the reverse — English with one stray ideogram — stays
    /// Latin at this threshold.
    static func detect(_ text: String) -> ScriptLanguage {
        guard !text.unicodeScalars.isEmpty else { return .latin }
        let cjkCount = text.unicodeScalars.count { scalar in
            scalar.isCJKIdeographOrKana || scalar.isCJKPunctuation
        }
        return Double(cjkCount) / Double(text.unicodeScalars.count) > 0.2 ? .cjk : .latin
    }

    /// Chinese takes no space after 。; Latin needs one between sentences.
    var sentenceJoiner: String {
        self == .cjk ? "" : " "
    }

    /// The design spec gives Chinese its own type scale (小/中/大 = 16/18/21
    /// against the Latin 17/19/22): CJK glyphs have a larger visual body, so
    /// matching Latin metrics reads as cramped.
    func effectiveTextSize(base: CGFloat) -> CGFloat {
        self == .cjk ? (base * 18.0 / 19.0).rounded() : base
    }

    /// Looser for CJK for the same reason.
    var lineHeightMultiple: CGFloat {
        self == .cjk ? 1.6 : 1.5
    }

    /// Seed reading speed in characters per second, before anything has been
    /// measured. 5 字/秒 is 300 字/分, an unhurried on-camera delivery;
    /// 16 chars/sec is about 190 wpm.
    var defaultCharactersPerSecond: Double {
        self == .cjk ? 5.0 : 16.0
    }

    /// A measured rate is clamped to this. One misrecognized burst can
    /// otherwise produce a sample an order of magnitude off, and the prompter
    /// would sprint or stall on it.
    var rateBounds: ClosedRange<Double> {
        self == .cjk ? 2.0...12.0 : 6.0...40.0
    }

    /// Dim already-read rows above the highlight band. Two Latin rows hold
    /// about as much text as one Chinese row, so Latin gets two.
    var readRowsAbove: Int {
        self == .cjk ? 1 : 2
    }

    /// Total rows in the fixed window. readRowsAbove + 2 band rows + 2 ahead.
    var visibleRows: Int {
        readRowsAbove + 4
    }
}

extension Unicode.Scalar {
    /// Ideographs and kana — the characters that carry meaning one at a time,
    /// which is why the tokenizer emits them individually.
    var isCJKIdeographOrKana: Bool {
        (0x4E00...0x9FFF).contains(value)        // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(value) // Extension A
            || (0xF900...0xFAFF).contains(value) // Compatibility Ideographs
            || (0x3040...0x30FF).contains(value) // Hiragana / Katakana
    }

    /// Kept separate from the above: recognizers emit these inconsistently,
    /// so the tokenizer drops them, while language detection counts them.
    var isCJKPunctuation: Bool {
        (0x3000...0x303F).contains(value)        // 。、，「」etc.
            || (0xFF00...0xFF0F).contains(value) // fullwidth ！？（）
            || (0xFF1A...0xFF20).contains(value) // fullwidth ：；＜＝＞？＠
    }
}

extension Character {
    var isCJKIdeographOrKana: Bool {
        unicodeScalars.contains(where: \.isCJKIdeographOrKana)
    }

    var isCJKPunctuation: Bool {
        unicodeScalars.contains(where: \.isCJKPunctuation)
    }
}
```

- [ ] **Step 5: 让 `TextTokenizer` 改用共享判定**

修改 `ios/Pollux One/Domain/TextTokenizer.swift`：把 `character.isCJK` 改成 `character.isCJKIdeographOrKana`，并**删除文件末尾整个 `private extension Character { ... }` 块**（第 41–58 行）。

改后的循环体：

```swift
        for character in text.lowercased() {
            if character.isCJKIdeographOrKana {
                flushLatin()
                tokens.append(String(character))
            } else if character.isWhitespace {
                flushLatin()
            } else if character.isCJKPunctuation {
                // Recognizers emit these inconsistently; dropping them keeps
                // "…问题。" and "…问题" scoring the same.
                flushLatin()
            } else {
                latinBuffer.append(character)
            }
        }
```

- [ ] **Step 6: 运行，确认全过**

```bash
./scripts/test-engines.sh
```

Expected: `TOTAL: 121 passed, 0 failed`（原 107 + 新 14）。原有 107 条**一条都不能掉**——尤其对齐引擎那批，它们跑在 `TextTokenizer` 上。

- [ ] **Step 7: 提交**

```bash
git add "ios/Pollux One/Domain/ScriptLanguage.swift" "ios/Pollux One/Domain/TextTokenizer.swift" ios/EngineHarness/LayoutScenarios.swift ios/EngineHarness/main.swift scripts/test-engines.sh
git commit -m "Give the prompter one definition of what script it is reading"
```

---

## Task 2: `PromptScriptText` — 唯一的文本拼接口径

后面所有东西都以"`text` 里的第几个字符"计量：断行、阅读光标、语音真值查表。这只有在**脚本拼接只有一种方式**时才成立。两份独立的拼接会因为各自选的分隔符不同而错开几个字符，光标于是永久偏移，且随脚本长度累积。

**Files:**
- Create: `ios/Pollux One/Domain/PromptScriptText.swift`
- Modify: `ios/EngineHarness/LayoutScenarios.swift`
- Modify: `scripts/test-engines.sh`

- [ ] **Step 1: 写会失败的场景**

在 `ios/EngineHarness/LayoutScenarios.swift` 里，`report.section("the tokenizer keeps its old behaviour on the shared predicates")` 那一段**之前**，插入：

```swift
    report.section("canonical text is the single concatenation everything measures against")

    let chinese = makeLayoutScript([
        "大多数提词器都在解决错误的问题。它们让字变得容易读。",
        "Pollux One 从另一个问题出发。"
    ])
    let chineseText = PromptScriptText.build(chinese)

    report.check(chineseText.language == .cjk, "a Chinese script is built as CJK")
    report.check(!chineseText.text.contains("。 "),
                 "no space is inserted after a Chinese full stop",
                 detail: chineseText.text)
    report.check(chineseText.text.hasPrefix("大多数提词器都在解决错误的问题。它们"),
                 "Chinese sentences butt straight up against each other")
    report.check(chineseText.hardBreaks == [26],
                 "the paragraph boundary is recorded as an offset, not a newline",
                 detail: "\(chineseText.hardBreaks)")
    report.check(!chineseText.text.contains("\n"),
                 "canonical text holds no characters that are never read aloud")

    let chineseSentences = chinese.allSentences
    report.check(chineseText.sentenceRanges.count == chineseSentences.count,
                 "every sentence has a range")

    let firstRange = chineseText.sentenceRanges[chineseSentences[0].id]
    report.check(firstRange == 0..<16,
                 "the first sentence starts at 0",
                 detail: "\(String(describing: firstRange))")

    let rangesAgree = chineseSentences.allSatisfy { sentence in
        guard let range = chineseText.sentenceRanges[sentence.id] else { return false }
        return String(Array(chineseText.text)[range]) == sentence.text
    }
    report.check(rangesAgree,
                 "slicing canonical text by a sentence's range reproduces that sentence")

    let english = makeLayoutScript([
        "Most teleprompters solve the wrong problem. They pull your eyes away.",
        "Pollux One starts elsewhere."
    ])
    let englishText = PromptScriptText.build(english)

    report.check(englishText.language == .latin, "an English script is built as Latin")
    report.check(englishText.text.contains("wrong problem. They"),
                 "Latin sentences are joined by exactly one space",
                 detail: englishText.text)

    let englishSentences = english.allSentences
    let englishAgree = englishSentences.allSatisfy { sentence in
        guard let range = englishText.sentenceRanges[sentence.id] else { return false }
        return String(Array(englishText.text)[range]) == sentence.text
    }
    report.check(englishAgree, "Latin ranges also slice back to their sentences")

    report.check(PromptScriptText.build(makeLayoutScript([])).text.isEmpty,
                 "an empty script builds without crashing")

    report.section("a reading position becomes a character offset — with the right denominator")

    let denominatorScript = makeLayoutScript(["大多数提词器都在解决错误的问题。"])
    let denominatorText = PromptScriptText.build(denominatorScript)

    if let only = denominatorScript.allSentences.first,
       let onlyRange = denominatorText.sentenceRanges[only.id] {

        report.check(only.tokens.count == 1,
                     "Sentence.tokens collapses a whole Chinese sentence to 1 — this is the trap",
                     detail: "\(only.tokens.count)")
        report.check(denominatorText.sentenceTokenCounts[only.id] == 15,
                     "so the denominator is TextTokenizer's 15 per-character tokens instead",
                     detail: "\(String(describing: denominatorText.sentenceTokenCounts[only.id]))")

        let atStart = denominatorText.characterOffset(
            of: makePosition(only, tokenIndex: 0, in: denominatorScript)
        )
        let midway = denominatorText.characterOffset(
            of: makePosition(only, tokenIndex: 7, in: denominatorScript)
        )
        let nearEnd = denominatorText.characterOffset(
            of: makePosition(only, tokenIndex: 14, in: denominatorScript)
        )

        report.check(atStart == 0,
                     "token 0 maps to the sentence's own start offset",
                     detail: "\(String(describing: atStart))")
        report.check((midway ?? 0) > 7 && (midway ?? 0) < 8,
                     "token 7 of 15 lands about halfway through the 16 characters",
                     detail: "\(String(describing: midway))")
        report.check((nearEnd ?? 0) < Double(onlyRange.upperBound),
                     "the last token has not yet reached the end of the sentence — a wrong denominator pins it there",
                     detail: "\(String(describing: nearEnd)) vs \(onlyRange.upperBound)")
    } else {
        report.check(false, "the denominator fixture has a sentence with a range")
    }
```

并在同一文件**末尾**（`runLayoutSuite` 之外）加上这个 fixture：

```swift
/// A ReadingPosition aimed at one sentence, as the alignment engine would
/// emit it. `tokenIndex` indexes `TextTokenizer.tokens(in: sentence.text)` —
/// the same tokenization `SlidingWindowAlignmentEngine` counts in.
@MainActor
func makePosition(_ sentence: Sentence, tokenIndex: Int, in script: Script) -> ReadingPosition {
    let section = script.sections[0]
    let paragraph = section.paragraphs.first { paragraph in
        paragraph.sentences.contains { $0.id == sentence.id }
    } ?? section.paragraphs[0]

    return ReadingPosition(
        address: ScriptAddress(
            scriptId: script.id,
            scriptVersion: script.version,
            sectionId: section.id,
            paragraphId: paragraph.id,
            sentenceId: sentence.id
        ),
        tokenIndexInSentence: tokenIndex,
        confidence: 0.9,
        updatedAt: Date()
    )
}

/// Builds a Script the way the mock backend does — one section, one paragraph
/// per string, sentences split by the shared splitter — so the scenarios
/// exercise the same shape the app actually loads.
@MainActor
func makeLayoutScript(_ paragraphs: [String]) -> Script {
    let built = paragraphs.enumerated().map { index, text in
        Paragraph(id: UUID(), order: index, sentences: SentenceSplitter.sentences(from: text))
    }
    return Script(
        id: UUID(),
        title: "Layout fixture",
        version: 1,
        sections: [ScriptSection(id: UUID(), title: nil, order: 0, paragraphs: built)],
        updatedAt: Date(),
        createdAt: Date()
    )
}
```

- [ ] **Step 2: 把源文件加进编译列表**

修改 `scripts/test-engines.sh`，在 `"$IOS/Domain/ScriptLanguage.swift" \` 之后加：

```bash
  "$IOS/Domain/PromptScriptText.swift" \
```

- [ ] **Step 3: 运行，确认失败**

```bash
./scripts/test-engines.sh
```

Expected: 编译失败，`cannot find 'PromptScriptText' in scope`。

- [ ] **Step 4: 写 `PromptScriptText`**

创建 `ios/Pollux One/Domain/PromptScriptText.swift`：

```swift
import Foundation

/// The one string the prompter lays out, plus the index that maps a sentence
/// back into it.
///
/// Everything downstream measures in *character offsets into `text`*: the
/// line layout, the reading cursor, the speech-truth lookup. That only holds
/// if there is exactly one way a Script becomes a string. Two independent
/// concatenations differ by whatever separators each chose, and the cursor
/// then sits a few characters off — permanently, and worse the longer the
/// script runs.
///
/// Paragraph boundaries are recorded as offsets in `hardBreaks` rather than
/// as "\n" in the text. A newline would occupy a character offset that is
/// never spoken, so the cursor would have to skip it and every offset after a
/// paragraph would be shifted by one. Keeping `text` to exactly the
/// characters a reader says out loud removes that whole class of off-by-one.
struct PromptScriptText: Equatable {
    let text: String
    /// Sentence id -> its range in `text`, counted in Characters (not UTF-16
    /// units: the layout works in Characters, and CJK would disagree).
    let sentenceRanges: [UUID: Range<Int>]
    /// Sentence id -> how many tokens `TextTokenizer` produces for it.
    ///
    /// **Not** `Sentence.tokens.count`. Those are two different tokenizations:
    /// `Token.tokenize` splits on spaces (`ScriptModels.swift:73`), while
    /// `ReadingPosition.tokenIndexInSentence` is an index into
    /// `TextTokenizer.tokens(in:)`, which emits CJK per character. A whole
    /// Chinese sentence is *one* space-delimited token, so using that count as
    /// the denominator makes the ratio permanently >= 1 and pins every truth
    /// at the end of its sentence — the Chinese prompter would sit still for a
    /// whole sentence and then jump. Nothing crashes; it just looks broken.
    let sentenceTokenCounts: [UUID: Int]
    /// Offsets no line may run across — paragraph and section boundaries.
    let hardBreaks: [Int]
    let language: ScriptLanguage

    /// Where an alignment result sits, as a fractional character offset.
    ///
    /// Linear interpolation across the sentence's tokens rather than an exact
    /// token-to-character map: the error is bounded by one token's width, and
    /// the correction loop in `ReadingPacer` pulls it back on every result.
    /// An exact map would mean teaching `TextTokenizer` to return ranges,
    /// which costs far more than it buys here.
    func characterOffset(of position: ReadingPosition) -> Double? {
        let sentenceId = position.address.sentenceId
        guard let range = sentenceRanges[sentenceId],
              let tokenCount = sentenceTokenCounts[sentenceId],
              tokenCount > 0 else { return nil }

        let ratio = min(max(Double(position.tokenIndexInSentence) / Double(tokenCount), 0), 1)
        return Double(range.lowerBound) + ratio * Double(range.count)
    }

    static func build(_ script: Script) -> PromptScriptText {
        let language = ScriptLanguage.detect(script.fullText)
        let joiner = language.sentenceJoiner

        var text = ""
        var offset = 0
        var ranges: [UUID: Range<Int>] = [:]
        var tokenCounts: [UUID: Int] = [:]
        var hardBreaks: [Int] = []

        for section in script.sections.sorted(by: { $0.order < $1.order }) {
            for paragraph in section.paragraphs.sorted(by: { $0.order < $1.order }) {
                if offset > 0 { hardBreaks.append(offset) }

                let sentences = paragraph.sentences.sorted { $0.order < $1.order }
                for (index, sentence) in sentences.enumerated() {
                    if index > 0 {
                        text += joiner
                        offset += joiner.count
                    }
                    let start = offset
                    text += sentence.text
                    offset += sentence.text.count
                    ranges[sentence.id] = start..<offset
                    tokenCounts[sentence.id] = TextTokenizer.tokens(in: sentence.text).count
                }
            }
        }

        return PromptScriptText(
            text: text,
            sentenceRanges: ranges,
            sentenceTokenCounts: tokenCounts,
            hardBreaks: hardBreaks,
            language: language
        )
    }
}
```

- [ ] **Step 5: 运行，确认全过**

```bash
./scripts/test-engines.sh
```

Expected: `TOTAL: 138 passed, 0 failed`（121 + 17）。

如果 `hardBreaks == [26]` 或 `firstRange == 0..<16` 断言失败，**不要改断言去迁就实现**——先把 `detail:` 打出来的实际值和"大多数提词器都在解决错误的问题。"的字符数（16）、加上第二句"它们让字变得容易读。"（10）= 26 对一遍。数不上说明拼接口径错了，那正是这个 Task 要防的东西。

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Domain/PromptScriptText.swift" ios/EngineHarness/LayoutScenarios.swift scripts/test-engines.sh
git commit -m "Concatenate a script one way, so every offset means the same thing"
```

---

## Task 3: `PromptLineLayout` — 断行

固定 5/6 行的前提是知道每一行装什么。断行算法留在纯逻辑里、只把**量宽**抽成协议注入，是为了让它能在 macOS harness 上精确断言——如果把断行也委托给 CoreText，harness 里就只剩窗口逻辑被测到，而断行恰恰是最容易错的一半。

**Files:**
- Create: `ios/Pollux One/Domain/PromptLineLayout.swift`
- Create: `ios/EngineHarness/FakeTextMeasurer.swift`
- Modify: `ios/EngineHarness/LayoutScenarios.swift`
- Modify: `scripts/test-engines.sh`

- [ ] **Step 1: 写假测量器**

创建 `ios/EngineHarness/FakeTextMeasurer.swift`：

```swift
import Foundation

/// Deterministic stand-in for font metrics: one em per CJK character, half an
/// em for everything else (including spaces).
///
/// The point is not realism — it is that break positions become arithmetic.
/// With em = 10 and a 100pt line, Chinese fits exactly 10 characters and
/// Latin exactly 20, so a scenario can assert the break index rather than
/// "roughly wraps somewhere sensible". Real font metrics would make every one
/// of those assertions a guess, and would need a font installed on the
/// machine running the suite.
struct FakeTextMeasurer: TextWidthMeasuring {
    let em: CGFloat

    init(em: CGFloat = 10) {
        self.em = em
    }

    func characterWidths(of text: String) -> [CGFloat] {
        text.map { character in
            character.isCJKIdeographOrKana || character.isCJKPunctuation ? em : em / 2
        }
    }
}
```

- [ ] **Step 2: 写会失败的场景**

在 `ios/EngineHarness/LayoutScenarios.swift` 的 `report.section("the tokenizer keeps its old behaviour...")` 段**之前**插入：

```swift
    report.section("line breaking — Latin never cuts a word")

    let measurer = FakeTextMeasurer(em: 10)
    let enSource = PromptScriptText.build(
        makeLayoutScript(["Most teleprompters solve the wrong problem."])
    )
    let enLines = PromptLineLayout.lines(for: enSource, width: 100, measurer: measurer)

    report.check(enLines.count == 3, "43 characters at 20 per line is 3 lines",
                 detail: "\(enLines.map(\.text))")
    report.check(enLines.first?.text == "Most teleprompters ",
                 "the break falls back to the last space, and the space stays on the line it ends",
                 detail: "\(String(describing: enLines.first?.text))")
    report.check(enLines.count > 1 && enLines[1].text == "solve the wrong ",
                 "so the next line opens on a word, never on a space")
    report.check(enLines.allSatisfy { !$0.text.hasPrefix(" ") },
                 "no line begins with whitespace")
    report.check(enLines.map(\.text).joined() == enSource.text,
                 "the lines concatenate back to exactly the canonical text")
    report.check(zip(enLines, enLines.dropFirst()).allSatisfy {
                     $0.characterRange.upperBound == $1.characterRange.lowerBound
                 },
                 "character ranges are contiguous with no gap and no overlap")
    report.check(enLines.enumerated().allSatisfy { $0.offset == $0.element.id },
                 "a line's id is its global index — the view relies on this for identity")

    report.section("line breaking — a word longer than the line still has to be cut")

    let longWord = PromptScriptText.build(makeLayoutScript(["Aaaaaaaaaaaaaaaaaaaaaaaaa."]))
    let longWordLines = PromptLineLayout.lines(for: longWord, width: 50, measurer: measurer)

    report.check(longWordLines.count == 3,
                 "26 characters at 10 per line is 3 lines",
                 detail: "\(longWordLines.map(\.text))")
    report.check(longWordLines.allSatisfy { !$0.text.isEmpty },
                 "no empty line — an empty line here means the layout loop cannot terminate")

    report.section("line breaking — CJK avoids opening a line with closing punctuation")

    let cjkSource = PromptScriptText.build(makeLayoutScript(["大多数提词器都在解决。它们让字。"]))
    let cjkLines = PromptLineLayout.lines(for: cjkSource, width: 100, measurer: measurer)

    report.check(cjkLines.count == 2, "16 CJK characters at 10 per line is 2 lines",
                 detail: "\(cjkLines.map(\.text))")
    report.check(cjkLines.first?.text == "大多数提词器都在解",
                 "the break shifted one character left rather than let 。 open a line",
                 detail: "\(String(describing: cjkLines.first?.text))")
    report.check(cjkLines.count > 1 && cjkLines[1].text.hasPrefix("决。"),
                 "the deferred character carries the punctuation with it")
    report.check(cjkLines.allSatisfy { !"。，、；：！？）」".contains($0.text.first ?? "字") },
                 "no line opens on closing punctuation")

    report.section("line breaking — paragraph boundaries are hard")

    let twoParagraphs = PromptScriptText.build(makeLayoutScript(["短句。", "第二段开始。"]))
    let paragraphLines = PromptLineLayout.lines(for: twoParagraphs, width: 1000, measurer: measurer)

    report.check(paragraphLines.count == 2,
                 "both paragraphs fit on one line by width, and are still two lines",
                 detail: "\(paragraphLines.map(\.text))")
    report.check(paragraphLines.first?.text == "短句。",
                 "the first line stops at the paragraph boundary")

    report.section("character x offsets — the highlight edge lands on a real glyph boundary")

    guard let firstEnLine = enLines.first else {
        report.check(false, "there is a first Latin line to measure")
        return (report.pass, report.fail)
    }

    report.check(firstEnLine.characterXOffsets.count == firstEnLine.text.count + 1,
                 "one offset per character plus an end sentinel",
                 detail: "\(firstEnLine.characterXOffsets.count) for \(firstEnLine.text.count) chars")
    report.check(firstEnLine.characterXOffsets.first == 0,
                 "the first character starts at x = 0")
    report.check(firstEnLine.characterXOffsets.last == 95,
                 "19 Latin characters at 5pt each is 95pt",
                 detail: "\(String(describing: firstEnLine.characterXOffsets.last))")
    report.check(zip(firstEnLine.characterXOffsets, firstEnLine.characterXOffsets.dropFirst())
                    .allSatisfy { $0 <= $1 },
                 "offsets are monotonically non-decreasing")

    report.section("re-layout — the same text at a different width")

    let narrow = PromptLineLayout.lines(for: enSource, width: 60, measurer: measurer)

    report.check(narrow.count > enLines.count,
                 "a narrower column produces more lines",
                 detail: "\(narrow.count) vs \(enLines.count)")
    report.check(narrow.map(\.text).joined() == enSource.text,
                 "and still concatenates back to the same canonical text")
    report.check(narrow.last?.characterRange.upperBound == enLines.last?.characterRange.upperBound,
                 "the total character count is width-independent — this is what lets the cursor survive")
```

- [ ] **Step 3: 把源文件加进编译列表**

修改 `scripts/test-engines.sh`：在 `"$IOS/Domain/PromptScriptText.swift" \` 之后加一行，并在 harness 文件段加一行：

```bash
  "$IOS/Domain/PromptLineLayout.swift" \
```

```bash
  ios/EngineHarness/FakeTextMeasurer.swift \
```

- [ ] **Step 4: 运行，确认失败**

```bash
./scripts/test-engines.sh
```

Expected: 编译失败，`cannot find 'PromptLineLayout' in scope` / `cannot find type 'TextWidthMeasuring' in scope`。

- [ ] **Step 5: 写 `PromptLineLayout`**

创建 `ios/Pollux One/Domain/PromptLineLayout.swift`：

```swift
import Foundation

/// One laid-out visual line.
struct PromptLine: Equatable, Identifiable {
    /// Global line index. Doubles as the SwiftUI identity: the overlay renders
    /// every line and moves the container, so each line has to stay the *same*
    /// node across a scroll step. Identify them any other way and SwiftUI
    /// treats each step as a batch of inserts and removals, which animates as
    /// a cross-fade instead of a slide.
    let id: Int
    let text: String
    /// This line's range in `PromptScriptText.text`.
    let characterRange: Range<Int>
    /// Leading x of every character, plus an end sentinel — so
    /// `characterXOffsets.count == text.count + 1`.
    ///
    /// Needed because the reading cursor is character-granular but the
    /// highlight edge is drawn in points, and `progress × lineWidth` is wrong
    /// in Latin: "i" and "W" are not the same fraction of a line, so the edge
    /// visibly jitters as it crosses them.
    let characterXOffsets: [CGFloat]

    var characterCount: Int { characterRange.count }
    var width: CGFloat { characterXOffsets.last ?? 0 }
}

/// Supplies glyph advances. **Measures only — it does not break lines.**
///
/// Breaking stays in `PromptLineLayout` so it is assertable offline, on a Mac,
/// with no font installed (see `FakeTextMeasurer`). Delegating the break to
/// CoreText would buy correct Unicode line-breaking and lose the ability to
/// test the half of this that is easiest to get wrong.
protocol TextWidthMeasuring {
    /// One width per Character of `text`, in the same order.
    func characterWidths(of text: String) -> [CGFloat]
}

/// Greedy line breaking over a `PromptScriptText`.
enum PromptLineLayout {
    static func lines(
        for source: PromptScriptText,
        width: CGFloat,
        measurer: TextWidthMeasuring
    ) -> [PromptLine] {
        let characters = Array(source.text)
        guard !characters.isEmpty, width > 0 else { return [] }

        let widths = measurer.characterWidths(of: source.text)
        // A measurer that disagrees with the text it was handed would produce
        // silently wrong offsets everywhere downstream. Refuse instead.
        guard widths.count == characters.count else { return [] }

        let hardBreaks = Set(source.hardBreaks)
        var lines: [PromptLine] = []
        var start = 0

        while start < characters.count {
            var end = start
            var used: CGFloat = 0
            while end < characters.count {
                if end > start, hardBreaks.contains(end) { break }
                let extended = used + widths[end]
                // `end > start` guarantees at least one character per line, so
                // a single character wider than the column cannot loop.
                if end > start, extended > width { break }
                used = extended
                end += 1
            }

            if end < characters.count, !hardBreaks.contains(end) {
                end = adjustedBreak(
                    in: characters,
                    from: start,
                    proposed: end,
                    language: source.language
                )
            }

            lines.append(
                line(id: lines.count, characters: characters, widths: widths, range: start..<end)
            )
            start = end
        }

        return lines
    }

    /// Moves a width-driven break to a place a reader will accept.
    private static func adjustedBreak(
        in characters: [Character],
        from start: Int,
        proposed: Int,
        language: ScriptLanguage
    ) -> Int {
        switch language {
        case .latin:
            // A prompter that cuts words mid-glyph is unreadable, so fall back
            // to the last space on the line. The space stays on the line it
            // terminates, so the next line opens on a word.
            if characters[proposed].isWhitespace { return proposed + 1 }
            var candidate = proposed - 1
            while candidate > start {
                if characters[candidate].isWhitespace { return candidate + 1 }
                candidate -= 1
            }
            // One word longer than the whole column: cut it. Better a hard cut
            // than an empty line.
            return proposed

        case .cjk:
            // Chinese breaks between any two characters, with two exceptions:
            // a line may not open with closing punctuation (行首禁则), and may
            // not close with opening punctuation (行尾禁则). Shift left at most
            // twice — a run of brackets must not loop, and two is enough for
            // every real case.
            var candidate = proposed
            for _ in 0..<2 {
                let opensBadly = noLineStart.contains(characters[candidate])
                let closesBadly = candidate > start && noLineEnd.contains(characters[candidate - 1])
                guard opensBadly || closesBadly, candidate - 1 > start else { break }
                candidate -= 1
            }
            return candidate
        }
    }

    /// 行首禁则 — must not open a line.
    private static let noLineStart: Set<Character> = [
        "。", "，", "、", "；", "：", "！", "？", "）", "］", "｝", "」", "』", "〉", "》", "”", "’", "·",
        ".", ",", ";", ":", "!", "?", ")", "]", "}"
    ]

    /// 行尾禁则 — must not close a line.
    private static let noLineEnd: Set<Character> = [
        "（", "［", "｛", "「", "『", "〈", "《", "“", "‘", "(", "[", "{"
    ]

    private static func line(
        id: Int,
        characters: [Character],
        widths: [CGFloat],
        range: Range<Int>
    ) -> PromptLine {
        var offsets: [CGFloat] = [0]
        offsets.reserveCapacity(range.count + 1)
        var x: CGFloat = 0
        for index in range {
            x += widths[index]
            offsets.append(x)
        }
        // Trailing whitespace is deliberately kept in `text`: trimming it
        // would break the invariant that a line's characters are exactly its
        // characterRange, which every offset lookup downstream depends on.
        return PromptLine(
            id: id,
            text: String(characters[range]),
            characterRange: range,
            characterXOffsets: offsets
        )
    }
}
```

- [ ] **Step 6: 运行，确认全过**

```bash
./scripts/test-engines.sh
```

Expected: `TOTAL: 160 passed, 0 failed`（138 + 22）。

- [ ] **Step 7: 提交**

```bash
git add "ios/Pollux One/Domain/PromptLineLayout.swift" ios/EngineHarness/FakeTextMeasurer.swift ios/EngineHarness/LayoutScenarios.swift scripts/test-engines.sh
git commit -m "Break the script into the visual lines a fixed window can hold"
```

---

## Task 3b: CJK 脚本里的拉丁词不切开

Task 3 的自审提出了这条。落地前确认它**不是**边界情况：`ios/Pollux One/Networking/MockBackendClient.swift:85` 自带的示例脚本就是 `"Pollux One 从另一个问题出发。…"`，`ScriptLanguage.detect` 判它 `.cjk`，而 `.cjk` 分支只做禁则、任意字符间可断。在 `FakeTextMeasurer(em: 10)` + 列宽 45pt 下，第一行是 `"Pollux On"`，第二行以孤立的 `"e"` 开头。

**Files:**
- Modify: `ios/Pollux One/Domain/PromptLineLayout.swift`
- Modify: `ios/EngineHarness/LayoutScenarios.swift`

- [ ] **Step 1: 写会失败的场景**

在 `ios/EngineHarness/LayoutScenarios.swift` 里，紧接在 `report.section("line breaking — CJK avoids opening a line with closing punctuation")` 那一整段**之后**插入：

```swift
    report.section("line breaking — a Latin word inside a CJK script is not cut in half")

    // The app's own sample script opens exactly like this, so this is the
    // common case rather than an edge one.
    let mixed = PromptScriptText.build(makeLayoutScript(["Pollux One 从另一个问题出发。"]))

    report.check(mixed.language == .cjk,
                 "a Chinese paragraph carrying a Latin product name is still CJK")

    // 45pt at em 10: the width-driven break lands on the "e" of "One".
    let mixedLines = PromptLineLayout.lines(for: mixed, width: 45, measurer: measurer)

    report.check(mixedLines.first?.text == "Pollux ",
                 "the break falls back to the start of the Latin word instead of splitting it",
                 detail: "\(mixedLines.map(\.text))")
    report.check(mixedLines.count > 1 && mixedLines[1].text.hasPrefix("One"),
                 "so the next line opens on the whole word")

    // A word wider than the whole column still has to be cut: falling back
    // past the line's start would leave an empty line and cut it anyway.
    let tooNarrow = PromptLineLayout.lines(for: mixed, width: 25, measurer: measurer)

    report.check(tooNarrow.first?.text == "Pollu",
                 "a Latin word wider than the column is still cut",
                 detail: "\(tooNarrow.map(\.text))")
```

- [ ] **Step 2: 运行，确认失败**

```bash
./scripts/test-engines.sh
```

Expected: `162 passed, 2 failed` —— `mixedLines.first?.text` 实际是 `"Pollux On"`，第二行以 `"e "` 开头。`mixed.language` 和 `tooNarrow` 两条本来就过。

- [ ] **Step 3: 在 `.cjk` 分支加这条规则**

修改 `ios/Pollux One/Domain/PromptLineLayout.swift` 的 `adjustedBreak(in:from:proposed:language:)`，把整个 `case .cjk:` 分支替换为：

```swift
        case .cjk:
            // A Chinese script routinely carries Latin names — the app's own
            // sample opens "Pollux One 从另一个问题出发" — and the CJK rule of
            // "break between any two characters" cuts them in half. So a Latin
            // word inside CJK gets the Latin treatment first: fall back to the
            // word's start. Only when that would empty the line is the word
            // cut, for the same reason as the Latin branch.
            var candidate = proposed
            if isLatinWord(characters[proposed]),
               candidate > start,
               isLatinWord(characters[candidate - 1]) {
                var scan = candidate - 1
                while scan > start, isLatinWord(characters[scan - 1]) { scan -= 1 }
                if scan > start { candidate = scan }
            }

            // Chinese breaks between any two characters, with two exceptions:
            // a line may not open with closing punctuation (行首禁则), and may
            // not close with opening punctuation (行尾禁则). Shift left at most
            // twice — a run of brackets must not loop, and two is enough for
            // every real case.
            for _ in 0..<2 {
                let opensBadly = noLineStart.contains(characters[candidate])
                let closesBadly = candidate > start && noLineEnd.contains(characters[candidate - 1])
                guard opensBadly || closesBadly, candidate - 1 > start else { break }
                candidate -= 1
            }
            return candidate
```

并在 `noLineEnd` 的定义之后加：

```swift
    /// What counts as "inside a word" when a Latin run appears in CJK text.
    /// ASCII letters and digits only: breaking after a hyphen or a comma is
    /// correct, and widening this to every non-CJK character would stop the
    /// prompter from ever breaking a long run of punctuation.
    private static func isLatinWord(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
```

- [ ] **Step 4: 运行，确认全过**

```bash
./scripts/test-engines.sh
```

Expected: `TOTAL: 164 passed, 0 failed`（160 + 4）。

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/Domain/PromptLineLayout.swift" ios/EngineHarness/LayoutScenarios.swift
git commit -m "Keep Latin words whole when they appear in a Chinese script"
```

---

## Task 4: `ReadingPacer` — 连续光标

这个 Task 里的 `lookaheadCap` 是整套设计的安全阀。纯 dead reckoning 遇到读者停下来喝水、被打断、或识别整段失败，就会一路匀速把提词器推到脚本末尾。

**Files:**
- Create: `ios/Pollux One/Engines/ReadingPacer.swift`
- Create: `ios/EngineHarness/PacingScenarios.swift`
- Modify: `ios/EngineHarness/main.swift`
- Modify: `scripts/test-engines.sh`

- [ ] **Step 1: 写会失败的场景文件**

创建 `ios/EngineHarness/PacingScenarios.swift`：

```swift
import Foundation

// Offline exercise of the reading pacer: how discrete, laggy recognizer
// results become a cursor that moves continuously.
//
// Time is injected here, never read from a clock, so every one of these is
// deterministic. That matters more than usual: the failure modes are all
// about *rates* and *convergence*, and a suite that sampled real time would
// report them as flakes.
//
// The cap scenario is the important one. Without a lookahead cap, dead
// reckoning is not a smoothing trick, it is a bug: a reader who pauses gets
// scrolled to the end of their script.

@MainActor
func runPacingSuite() -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("Reading pacer — continuous cursor from discrete speech")

    // A 20-character Chinese line; 1.2 lines of lookahead, 2 lines to seek.
    let lineLength = 20.0
    let cap = 1.2 * lineLength
    let seek = 2.0 * lineLength

    report.section("dead reckoning between recognizer results")

    let gliding = ReadingPacer(language: .cjk)
    report.check(gliding.rate == 5.0, "Chinese starts at the seeded 5 字/秒",
                 detail: "\(gliding.rate)")

    for _ in 0..<10 { gliding.advance(deltaTime: 0.1, lookaheadCap: cap) }
    report.check(abs(gliding.cursor - 5.0) < 0.001,
                 "one second at 5 字/秒 moves the cursor 5 characters",
                 detail: "\(gliding.cursor)")

    report.section("the lookahead cap — a reader who stops does not get scrolled away")

    let stalled = ReadingPacer(language: .cjk)
    for _ in 0..<300 { stalled.advance(deltaTime: 0.1, lookaheadCap: cap) }
    report.check(abs(stalled.cursor - cap) < 0.001,
                 "30 seconds of silence parks the cursor 1.2 lines past the last truth, not 150 characters in",
                 detail: "\(stalled.cursor)")

    let tightening = ReadingPacer(language: .cjk)
    tightening.correct(to: 100, confidence: 0.9, at: 0, seekThreshold: seek)
    for _ in 0..<300 { tightening.advance(deltaTime: 0.1, lookaheadCap: cap) }
    let parked = tightening.cursor
    tightening.advance(deltaTime: 0.1, lookaheadCap: 4)
    report.check(tightening.cursor == parked,
                 "a cap that tightens holds the cursor instead of rewinding it",
                 detail: "\(parked) -> \(tightening.cursor)")

    report.section("measured rate converges on the reader")

    let measured = ReadingPacer(language: .cjk)
    let readerRate = 4.0
    for step in 1...30 {
        let time = Double(step) * 0.5
        for _ in 0..<15 { measured.advance(deltaTime: 1.0 / 30.0, lookaheadCap: cap) }
        measured.correct(to: readerRate * time, confidence: 0.9, at: time, seekThreshold: seek)
    }
    report.check(abs(measured.rate - readerRate) < 0.3,
                 "a reader holding 4 字/秒 is measured at 4 字/秒",
                 detail: "\(measured.rate)")
    report.check(abs(measured.cursor - readerRate * 15.0) < 4.0,
                 "and the cursor stays within a few characters of the truth",
                 detail: "\(measured.cursor) vs \(readerRate * 15.0)")

    report.section("rate is clamped — one bad burst must not make the prompter sprint")

    let fast = ReadingPacer(language: .cjk)
    fast.correct(to: 0, confidence: 0.9, at: 0, seekThreshold: seek)
    fast.correct(to: 1000, confidence: 0.9, at: 0.1, seekThreshold: seek)
    report.check(fast.rate <= 12.0,
                 "a 10000 字/秒 sample is clamped to the Chinese ceiling",
                 detail: "\(fast.rate)")

    let slow = ReadingPacer(language: .cjk)
    slow.correct(to: 0, confidence: 0.9, at: 0, seekThreshold: seek)
    for step in 1...40 {
        slow.correct(to: 0.001 * Double(step), confidence: 0.9, at: Double(step), seekThreshold: seek)
    }
    report.check(slow.rate == 2.0,
                 "a near-zero reader is floored at the Chinese minimum",
                 detail: "\(slow.rate)")

    report.section("small disagreement is bled off, never jumped")

    let drifting = ReadingPacer(language: .cjk)
    drifting.reset(to: 100, language: .cjk)
    var positions: [Double] = []
    for step in 1...4 {
        drifting.correct(to: 108, confidence: 0.9, at: Double(step), seekThreshold: seek)
        positions.append(drifting.cursor)
    }
    let deltas = zip([100.0] + positions, positions).map { $1 - $0 }

    report.check(deltas.allSatisfy { $0 > 0 },
                 "every correction moves forward",
                 detail: "\(deltas)")
    report.check(zip(deltas, deltas.dropFirst()).allSatisfy { $0 > $1 },
                 "each step is smaller than the last — an exponential approach, not a ramp")
    report.check(deltas.allSatisfy { $0 <= 2.0 },
                 "no single step exceeds 2 characters, so nothing reads as a jump",
                 detail: "\(deltas.max() ?? 0)")
    report.check(abs((positions.last ?? 0) - 108) < 3.0,
                 "four results close an 8-character gap to under 3",
                 detail: "\(positions.last ?? 0)")

    report.section("large disagreement is a seek, not drift")

    let jumpedAhead = ReadingPacer(language: .cjk)
    jumpedAhead.reset(to: 100, language: .cjk)
    jumpedAhead.correct(to: 400, confidence: 0.9, at: 1, seekThreshold: seek)
    report.check(jumpedAhead.cursor == 400,
                 "a reader who skipped ahead lands on the truth immediately",
                 detail: "\(jumpedAhead.cursor)")

    let wentBack = ReadingPacer(language: .cjk)
    wentBack.reset(to: 400, language: .cjk)
    wentBack.correct(to: 100, confidence: 0.9, at: 1, seekThreshold: seek)
    report.check(wentBack.cursor == 100,
                 "and so does a reader who went back to re-read")

    report.section("a low-confidence result is trusted for position, not for rate")

    let noisy = ReadingPacer(language: .cjk)
    noisy.correct(to: 0, confidence: 0.9, at: 0, seekThreshold: seek)
    let rateBefore = noisy.rate
    noisy.correct(to: 100, confidence: 0.2, at: 1, seekThreshold: seek)
    report.check(noisy.rate == rateBefore,
                 "background noise does not become a speed measurement",
                 detail: "\(rateBefore) -> \(noisy.rate)")
    report.check(noisy.cursor == 100,
                 "but the position still moves: the alignment engine only ever returns its last known-good sentence")

    report.section("Latin gets its own numbers")

    let latin = ReadingPacer(language: .latin)
    report.check(latin.rate == 16.0, "Latin starts at 16 chars/sec (~190 wpm)",
                 detail: "\(latin.rate)")

    return (report.pass, report.fail)
}
```

- [ ] **Step 2: 挂进 harness**

修改 `ios/EngineHarness/main.swift`：

```swift
let alignment = runAlignmentSuite()
let voice = runVoiceSuite()
let camera = runCameraSuite()
let archive = await runArchiveSuite()
let layout = runLayoutSuite()
let pacing = runPacingSuite()

let pass = alignment.pass + voice.pass + camera.pass + archive.pass + layout.pass + pacing.pass
let fail = alignment.fail + voice.fail + camera.fail + archive.fail + layout.fail + pacing.fail
print("\n══════ TOTAL: \(pass) passed, \(fail) failed ══════")
```

修改 `scripts/test-engines.sh`：在 `"$IOS/Engines/ScriptAlignmentEngine.swift" \` 之后加一行，并在 harness 段加一行：

```bash
  "$IOS/Engines/ReadingPacer.swift" \
```

```bash
  ios/EngineHarness/PacingScenarios.swift \
```

- [ ] **Step 3: 运行，确认失败**

```bash
./scripts/test-engines.sh
```

Expected: 编译失败，`cannot find 'ReadingPacer' in scope`。

- [ ] **Step 4: 写 `ReadingPacer`**

创建 `ios/Pollux One/Engines/ReadingPacer.swift`：

```swift
import Foundation

/// Turns the discrete, laggy output of speech alignment into a cursor that
/// moves continuously.
///
/// The cursor is a *fractional character offset* into
/// `PromptScriptText.text`. Characters rather than lines or points because
/// the offset then survives re-layout for free: changing the type size or the
/// column width changes which line holds a character, never which character
/// the reader is on.
///
/// Two halves:
///
/// - **Dead reckoning.** Between recognizer results the cursor advances at the
///   reader's measured rate, so the prompter glides instead of freezing and
///   then lurching when the next result lands. Recognizer results arrive every
///   0.3–0.8s; without this, that interval is dead air on screen.
/// - **Correction.** Each result is the truth. A small disagreement is bled off
///   over the next few results, so no single step is visible. A large one means
///   the reader skipped or went back — that is a seek, not drift.
///
/// Time is a parameter on every method, never read from a clock. The engine
/// passes real time; the offline suite passes synthetic time and gets
/// deterministic behaviour out of a component whose whole job is rates.
@MainActor
final class ReadingPacer {
    /// Fractional character offset. The integer part locates a line, the
    /// fraction is how far along that line the reader is.
    private(set) var cursor: Double = 0
    /// Measured reading speed in characters per second.
    private(set) var rate: Double

    private var language: ScriptLanguage
    private var lastTruth: Double = 0
    private var lastTruthTime: TimeInterval?

    /// Fraction of the disagreement taken out per result. 0.25 closes a gap in
    /// three or four results — roughly half a second of speech — with no
    /// single step large enough to read as a jump.
    private let correctionGain = 0.25
    /// Weight of a new rate sample. Reading speed drifts across a paragraph;
    /// it does not change word to word, so the estimate is deliberately slow.
    private let rateSmoothing = 0.25
    /// Below this, a result is noise rather than a measurement. Position is
    /// still trusted — see `correct(to:confidence:at:seekThreshold:)`.
    private let minimumRateConfidence = 0.5

    init(language: ScriptLanguage) {
        self.language = language
        self.rate = language.defaultCharactersPerSecond
    }

    func reset(to offset: Double, language: ScriptLanguage) {
        self.language = language
        cursor = offset
        rate = language.defaultCharactersPerSecond
        lastTruth = offset
        lastTruthTime = nil
    }

    /// Advance by one display tick.
    ///
    /// `lookaheadCap` is the whole safety story. Uncapped dead reckoning is
    /// not a smoothing trick but a bug: a reader who stops to drink water, is
    /// interrupted, or whose recognizer drops a stretch gets scrolled to the
    /// end of the script at a steady 5 characters a second. Capped a little
    /// past the current line, a pause parks the cursor within a line of the
    /// last thing actually heard — and the highlight visibly stopping *is* the
    /// signal that the prompter is no longer following, so no extra HUD
    /// message is needed.
    ///
    /// A cursor already at or beyond the cap holds rather than rewinding: the
    /// cap tightens whenever the current line is short, and a prompter that
    /// scrolls backwards on its own is worse than one that waits.
    func advance(deltaTime: TimeInterval, lookaheadCap: Double) {
        guard deltaTime > 0 else { return }
        let ceiling = lastTruth + lookaheadCap
        guard cursor < ceiling else { return }
        cursor = min(cursor + rate * deltaTime, ceiling)
    }

    /// Fold in one alignment result.
    ///
    /// Position is trusted at any confidence: `SlidingWindowAlignmentEngine`
    /// returns its last known-good sentence rather than a guess when its own
    /// score is low, so even a weak result carries a real position. Only the
    /// *rate* sample is gated, because a confident-looking gap between two
    /// weak results is a fiction.
    func correct(
        to truth: Double,
        confidence: Double,
        at time: TimeInterval,
        seekThreshold: Double
    ) {
        if confidence >= minimumRateConfidence,
           let previousTime = lastTruthTime,
           time > previousTime {
            let sample = (truth - lastTruth) / (time - previousTime)
            if sample > 0 {
                let blended = rate * (1 - rateSmoothing) + sample * rateSmoothing
                rate = min(max(blended, language.rateBounds.lowerBound), language.rateBounds.upperBound)
            }
        }

        lastTruth = truth
        lastTruthTime = time

        let error = truth - cursor
        if abs(error) > seekThreshold {
            // Not drift: the reader jumped. Land on the truth — the view's
            // 0.3s ease makes it a fast slide, not a teleport.
            cursor = truth
        } else {
            cursor += error * correctionGain
        }
    }
}
```

- [ ] **Step 5: 运行，确认全过**

```bash
./scripts/test-engines.sh
```

Expected: `TOTAL: 181 passed, 0 failed`（164 + 17）。

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Engines/ReadingPacer.swift" ios/EngineHarness/PacingScenarios.swift ios/EngineHarness/main.swift scripts/test-engines.sh
git commit -m "Pace the prompter from measured reading speed, capped ahead of the truth"
```

---

## Task 5: `TeleprompterEngine` — 固定行窗

引擎不再"取 4 个句子"，改为持有整脚本的行 + 配速器，输出「当前行号 + 行内进度」。视图按行序差现算角色，衬底位置因此恒定。

这个 Task 里有两条容易被实现掉的约束：

1. **`displayState` 的赋值必须有相等性守卫。** `@Observable` 不做去重——赋一个相等的值仍然通知观察者。没有守卫，30Hz 的 tick 每秒会把整块文字 diff 30 次，固定行窗的性能前提就没了。
2. **`load(script:startingAt:)` 必须能从指定地址开始。** `SessionManager.applyParagraphReplacement` 在安全词改稿后调 `load`，那里有一条明确的既有承诺——"Realign from the same address so the reader doesn't visually jump"。无参 `load` 会把光标打回 0，改一句话就把读者踢回脚本开头。

**Files:**
- Modify: `ios/Pollux One/Engines/TeleprompterEngine.swift`（整体重写）
- Modify: `ios/Pollux One/Engines/SessionManager.swift`
- Modify: `ios/EngineHarness/PacingScenarios.swift`
- Modify: `scripts/test-engines.sh`

- [ ] **Step 1: 写会失败的场景**

在 `ios/EngineHarness/PacingScenarios.swift` 的 `report.section("Latin gets its own numbers")` 段**之前**插入：

```swift
    report.section("the fixed window — the band never moves")

    let windowScript = makeLayoutScript([
        "大多数提词器都在解决错误的问题。它们让字变得容易读，却把你的眼神从镜头上拉走了。你的目光一离开镜头，观众立刻就能感觉到。",
        "Pollux One 从另一个问题出发。你的眼睛、文字和镜头之间，最短的距离是多少？"
    ])
    let engine = TeleprompterEngine()
    engine.load(script: windowScript)
    engine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))

    report.check(engine.displayState.visibleRows == 5,
                 "a Chinese script shows 5 rows")
    report.check(engine.displayState.readRowsAbove == 1,
                 "with 1 dim history row above the band")
    report.check(engine.displayState.lines.count > 5,
                 "the fixture is longer than one window",
                 detail: "\(engine.displayState.lines.count) lines")
    report.check(engine.displayState.currentLineIndex == 0,
                 "a freshly loaded script starts on line 0")
    report.check(engine.inLineProgress == 0,
                 "and at the very start of that line")

    report.section("displayState changes only when the window does")

    let stateBeforeTick = engine.displayState
    for _ in 0..<3 { engine.tick(deltaTime: 1.0 / 30.0) }

    report.check(engine.displayState == stateBeforeTick,
                 "three ticks inside one line leave the line window untouched — this is what keeps 30Hz off the text",
                 detail: "line \(engine.displayState.currentLineIndex)")
    report.check(engine.inLineProgress > 0,
                 "while the fine cursor did move",
                 detail: "\(engine.inLineProgress)")

    report.section("a large jump seeks, and the window follows")

    if let lastSentence = windowScript.allSentences.last {
        engine.update(position: makePosition(lastSentence, tokenIndex: 0, in: windowScript))
    }

    report.check(engine.displayState.currentLineIndex > 1,
                 "jumping to the last sentence moves the window well past the top",
                 detail: "line \(engine.displayState.currentLineIndex)")
    report.check(engine.displayState.currentLineIndex < engine.displayState.lines.count,
                 "and never past the end of the script")

    report.section("re-layout keeps the reader where they were")

    let offsetBefore = engine.cursorOffset
    let lineBefore = engine.displayState.currentLineIndex
    engine.setLayout(width: 60, measurer: FakeTextMeasurer(em: 10))

    report.check(engine.cursorOffset == offsetBefore,
                 "the character offset is untouched by re-layout — this is the whole reason the cursor is measured in characters",
                 detail: "\(offsetBefore) -> \(engine.cursorOffset)")
    report.check(engine.displayState.currentLineIndex > lineBefore,
                 "a narrower column puts the same character on a later line",
                 detail: "\(lineBefore) -> \(engine.displayState.currentLineIndex)")

    let landedLine = engine.displayState.lines[engine.displayState.currentLineIndex]
    report.check(landedLine.characterRange.contains(Int(engine.cursorOffset)),
                 "and the line the window points at really does contain that character")

    report.section("dead reckoning is capped from the current line's own length")

    let cappedEngine = TeleprompterEngine()
    cappedEngine.load(script: windowScript)
    cappedEngine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))
    for _ in 0..<900 { cappedEngine.tick(deltaTime: 1.0 / 30.0) }

    report.check(cappedEngine.cursorOffset <= 1.2 * 10 + 0.001,
                 "30 seconds of silence from line 0 advances at most 1.2 of that line's 10 characters",
                 detail: "\(cappedEngine.cursorOffset)")
    report.check(cappedEngine.displayState.currentLineIndex <= 1,
                 "so the window sits on line 0 or 1, not at the end of the script",
                 detail: "line \(cappedEngine.displayState.currentLineIndex)")

    report.section("progress is reported outside the line window")

    report.check(engine.readingProgress.totalSentences == windowScript.allSentences.count,
                 "progress counts every sentence in the script",
                 detail: "\(engine.readingProgress.totalSentences)")
    report.check(engine.readingProgress.fractionComplete > 0
                    && engine.readingProgress.fractionComplete <= 1,
                 "and reads as a fraction after the seek",
                 detail: "\(engine.readingProgress.fractionComplete)")

    report.section("a Safe Word reload does not rewind the reader")

    let reloadEngine = TeleprompterEngine()
    reloadEngine.load(script: windowScript)
    reloadEngine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))
    let midSentence = windowScript.allSentences[2]
    let midPosition = makePosition(midSentence, tokenIndex: 0, in: windowScript)
    reloadEngine.update(position: midPosition)
    let lineAfterSeek = reloadEngine.displayState.currentLineIndex

    reloadEngine.load(script: windowScript, startingAt: midPosition.address)

    report.check(reloadEngine.displayState.currentLineIndex == lineAfterSeek,
                 "reloading from the same address leaves the window where it was",
                 detail: "\(lineAfterSeek) -> \(reloadEngine.displayState.currentLineIndex)")
    report.check(reloadEngine.displayState.currentLineIndex > 0,
                 "which is emphatically not the top of the script")

    report.section("Latin gets six rows and two history rows")

    let latinEngine = TeleprompterEngine()
    latinEngine.load(script: makeLayoutScript([
        "Most teleprompters solve the wrong problem. They pull your eyes away from the lens."
    ]))
    latinEngine.setLayout(width: 100, measurer: FakeTextMeasurer(em: 10))

    report.check(latinEngine.displayState.visibleRows == 6,
                 "6 rows in Latin")
    report.check(latinEngine.displayState.readRowsAbove == 2,
                 "with 2 dim history rows above the band")
```

- [ ] **Step 2: 把 `TeleprompterEngine` 加进编译列表**

修改 `scripts/test-engines.sh`，在 `"$IOS/Engines/ReadingPacer.swift" \` 之后加：

```bash
  "$IOS/Engines/TeleprompterEngine.swift" \
```

- [ ] **Step 3: 运行，确认失败**

```bash
./scripts/test-engines.sh
```

Expected: 编译失败。老 `TeleprompterEngine` 没有 `setLayout` / `tick` / `cursorOffset`，`displayState` 也没有 `visibleRows`。

- [ ] **Step 4: 重写 `TeleprompterEngine`**

用以下内容**整体替换** `ios/Pollux One/Engines/TeleprompterEngine.swift`：

```swift
import Foundation

/// What the overlay draws: the whole script's visual lines, plus which one the
/// reader is on.
///
/// Deliberately holds *every* line rather than a pre-cut 5-row window. The
/// overlay renders them all inside a clipped, fixed-height frame and moves the
/// container, so each line stays the same SwiftUI node across a scroll step
/// and the step animates as a slide. Handing the view a 5-element window
/// instead makes every step a batch of inserts and removals, which animates as
/// a cross-fade — visually no better than the per-sentence jumping this
/// replaces.
///
/// Row roles are not in here either: the view derives them from
/// `line.id - currentLineIndex`, which is what makes the highlight band's
/// position a constant rather than something that has to be recomputed.
struct TeleprompterDisplayState: Equatable {
    var lines: [PromptLine]
    var currentLineIndex: Int
    /// Carried rather than re-detected: the overlay needs it for the type
    /// scale and line height, and a second detection from the visible lines
    /// alone would disagree with this one on a mixed-script script.
    var language: ScriptLanguage
    var isVisible: Bool = true

    /// Derived, not stored — two stored fields could drift out of agreement
    /// with `language`, and the whole point of the fixed window is that these
    /// two numbers are constants for a given script.
    var readRowsAbove: Int { language.readRowsAbove }
    var visibleRows: Int { language.visibleRows }

    static let empty = TeleprompterDisplayState(
        lines: [],
        currentLineIndex: 0,
        language: .latin
    )
}

/// Owns the prompter's typesetting and its clock.
///
/// Split across three observable properties on purpose, because they change at
/// wildly different rates:
///
/// | property          | changes                     | read by             |
/// |-------------------|-----------------------------|---------------------|
/// | `displayState`    | once per line (2–4 seconds)  | the text VStack     |
/// | `inLineProgress`  | 30 times a second            | the highlight fill  |
/// | `readingProgress` | 30 times a second            | the progress rail   |
///
/// `@Observable` tracks reads per property, so the two fast ones invalidate
/// only the small views that read them. Folding either into
/// `TeleprompterDisplayState` would re-diff every `Text` in the script 30
/// times a second.
///
/// The measurer is injected rather than constructed here so this stays free of
/// UIKit and can run in `scripts/test-engines.sh`.
@MainActor
@Observable
final class TeleprompterEngine {
    private(set) var displayState = TeleprompterDisplayState.empty
    /// 0...1 along the current line.
    private(set) var inLineProgress: Double = 0
    private(set) var readingProgress: ReadingProgress = .zero

    /// Exposed for the offline scenarios: the invariant that re-layout leaves
    /// the reading position alone is only checkable against this number.
    var cursorOffset: Double { pacer.cursor }

    private var source: PromptScriptText?
    private var sentenceRanges: [Range<Int>] = []
    private var pacer = ReadingPacer(language: .latin)
    private var language: ScriptLanguage = .latin

    private var layoutWidth: CGFloat = 0
    private var measurer: TextWidthMeasuring?

    private var tickTimer: Timer?
    private var lastTickUptime: TimeInterval?

    /// The band is two rows. A disagreement wider than that is a reader who
    /// skipped or went back, not accumulated drift.
    private let seekThresholdInLines = 2.0
    /// How far dead reckoning may run past the last confirmed truth. Slightly
    /// over one line so a normal reader's line change happens as they reach
    /// the line's end rather than half a second later.
    private let lookaheadInLines = 1.2
    /// Used before any line exists, so the cap is never zero (which would
    /// freeze the prompter) on the first frames after load.
    private let assumedCharactersPerLine = 20

    // MARK: - Loading

    /// `address` reloads without rewinding. A Safe Word edit rebuilds the
    /// script mid-take and calls this; starting from 0 there would throw the
    /// reader back to the top of their script for changing one sentence.
    func load(script: Script, startingAt address: ScriptAddress? = nil) {
        let built = PromptScriptText.build(script)
        source = built
        language = built.language
        pacer = ReadingPacer(language: built.language)

        sentenceRanges = script.allSentences.compactMap { built.sentenceRanges[$0.id] }

        let start = address.flatMap { built.sentenceRanges[$0.sentenceId]?.lowerBound } ?? 0
        pacer.reset(to: Double(start), language: built.language)

        rebuildLines()
    }

    /// Called by the view whenever the column width or the type size changes.
    func setLayout(width: CGFloat, measurer: TextWidthMeasuring) {
        layoutWidth = width
        self.measurer = measurer
        rebuildLines()
    }

    func setVisible(_ visible: Bool) {
        guard displayState.isVisible != visible else { return }
        var next = displayState
        next.isVisible = visible
        displayState = next
    }

    // MARK: - Following

    /// Fold in one alignment result.
    func update(position: ReadingPosition) {
        guard let source, let truth = source.characterOffset(of: position) else { return }
        pacer.correct(
            to: truth,
            confidence: position.confidence,
            at: position.updatedAt.timeIntervalSinceReferenceDate,
            seekThreshold: Double(charactersInCurrentLine) * seekThresholdInLines
        )
        refresh()
    }

    /// One display tick. Separate from the timer so the offline scenarios can
    /// drive it with synthetic time.
    func tick(deltaTime: TimeInterval) {
        pacer.advance(
            deltaTime: deltaTime,
            lookaheadCap: Double(charactersInCurrentLine) * lookaheadInLines
        )
        refresh()
    }

    func startPacing() {
        stopPacing()
        lastTickUptime = nil
        // 30Hz: one Double and one shape redraw per tick. AudioLevelMonitor
        // already runs the same shape of work at 15Hz beside the camera.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickFromClock() }
        }
    }

    func stopPacing() {
        tickTimer?.invalidate()
        tickTimer = nil
        lastTickUptime = nil
    }

    /// Real elapsed time rather than the timer's nominal interval: a busy run
    /// loop coalesces timer fires, and a prompter that quietly runs slow
    /// whenever the camera is busy is exactly the bug this feature exists to
    /// remove. `systemUptime` is monotonic, so a clock change cannot rewind it.
    private func tickFromClock() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTickUptime = now }
        guard let last = lastTickUptime, now > last else { return }
        tick(deltaTime: now - last)
    }

    // MARK: - Derivation

    private func rebuildLines() {
        guard let source, let measurer, layoutWidth > 0 else {
            assign(lines: [], currentLineIndex: 0)
            return
        }
        let lines = PromptLineLayout.lines(for: source, width: layoutWidth, measurer: measurer)
        assign(lines: lines, currentLineIndex: lineIndex(containing: Int(pacer.cursor), in: lines))
        refresh()
    }

    private func refresh() {
        let lines = displayState.lines
        guard !lines.isEmpty else {
            inLineProgress = 0
            return
        }

        let index = lineIndex(containing: Int(pacer.cursor), in: lines)
        assign(lines: lines, currentLineIndex: index)

        let line = lines[index]
        let within = pacer.cursor - Double(line.characterRange.lowerBound)
        inLineProgress = min(max(within / Double(max(line.characterCount, 1)), 0), 1)

        readingProgress = makeProgress(totalCharacters: lines[lines.count - 1].characterRange.upperBound)
    }

    /// The one place `displayState` is written. The equality guard is
    /// load-bearing: `@Observable` notifies on every assignment, equal or not,
    /// so writing it from a 30Hz tick without this check re-diffs every `Text`
    /// in the script thirty times a second.
    private func assign(lines: [PromptLine], currentLineIndex: Int) {
        let next = TeleprompterDisplayState(
            lines: lines,
            currentLineIndex: currentLineIndex,
            language: language,
            isVisible: displayState.isVisible
        )
        guard next != displayState else { return }
        displayState = next
    }

    private func makeProgress(totalCharacters: Int) -> ReadingProgress {
        let completed = sentenceRanges.count { Double($0.upperBound) <= pacer.cursor }
        let fraction = totalCharacters > 0
            ? min(max(pacer.cursor / Double(totalCharacters), 0), 1)
            : 0
        return ReadingProgress(
            completedSentences: completed,
            totalSentences: sentenceRanges.count,
            fractionComplete: fraction
        )
    }

    private var charactersInCurrentLine: Int {
        let lines = displayState.lines
        guard displayState.currentLineIndex < lines.count else { return assumedCharactersPerLine }
        return max(lines[displayState.currentLineIndex].characterCount, 1)
    }

    /// Binary search: line ranges are contiguous and ordered, and this runs on
    /// every one of the 30 ticks a second.
    private func lineIndex(containing offset: Int, in lines: [PromptLine]) -> Int {
        guard !lines.isEmpty else { return 0 }
        let total = lines[lines.count - 1].characterRange.upperBound
        let clamped = min(max(offset, 0), max(total - 1, 0))

        var low = 0
        var high = lines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = lines[mid].characterRange
            if clamped < range.lowerBound {
                high = mid - 1
            } else if clamped >= range.upperBound {
                low = mid + 1
            } else {
                return mid
            }
        }
        return lines.count - 1
    }
}
```

- [ ] **Step 5: 改 `SessionManager` 的三处**

修改 `ios/Pollux One/Engines/SessionManager.swift`：

第一处 —— 读进度的来源（原第 208 行附近）：

```swift
            teleprompterEngine.update(position: position)
            readingSession?.progress = teleprompterEngine.readingProgress
```

第二处 —— 安全词改稿后带地址重载：

```swift
        teleprompterEngine.load(script: script, startingAt: readingSession?.currentPosition?.address)
        // Realign from the same address so the reader doesn't visually jump.
        alignmentEngine.reset(script: script, startingAt: readingSession?.currentPosition?.address)
```

第三处 —— tick 的生命周期。在 `startTake()` 里 `audioLevelMonitor.startDisplayUpdates()` 之后加一行：

```swift
        teleprompterEngine.startPacing()
```

在 `endTake()` 里 `audioLevelMonitor.stopDisplayUpdates()` 之后加一行：

```swift
        teleprompterEngine.stopPacing()
```

- [ ] **Step 6: 运行，确认全过**

```bash
./scripts/test-engines.sh
```

Expected: `TOTAL: 201 passed, 0 failed`（181 + 20）。

- [ ] **Step 7: 提交**

```bash
git add "ios/Pollux One/Engines/TeleprompterEngine.swift" "ios/Pollux One/Engines/SessionManager.swift" ios/EngineHarness/PacingScenarios.swift scripts/test-engines.sh
git commit -m "Hold the prompter's band still and move the script through it"
```

---

## Task 6: `SystemFontLineMeasurer` — 真实字体宽度

**Files:**
- Create: `ios/Pollux One/Features/Recording/SystemFontLineMeasurer.swift`

这个文件**不进** harness。它没有可离线断言的逻辑——就是一次字体度量查询——真正要验证的是"断行位置和渲染出来的一致"，那件事只能在模拟器上看，见 Task 8。

- [ ] **Step 1: 写 measurer**

创建 `ios/Pollux One/Features/Recording/SystemFontLineMeasurer.swift`：

```swift
import SwiftUI
import UIKit

/// Real glyph advances for the prompter's line layout.
///
/// The font must be the one the overlay actually renders with, or lines break
/// somewhere other than where they are drawn — and the character-granular
/// highlight edge lands on the wrong glyph. SwiftUI's
/// `Font.system(size:weight:)` is `UIFont.systemFont(ofSize:weight:)`, so that
/// is what gets measured, at the same single weight every row is drawn in.
///
/// Measures only; breaking stays in `PromptLineLayout` (see the note on
/// `TextWidthMeasuring`).
///
/// Per-character measurement ignores kerning and ligatures between characters,
/// so a long Latin line measures a hair wider than it draws. That direction is
/// the safe one — the line breaks slightly early rather than overflowing — and
/// the overlay leaves a small margin on top of it.
struct SystemFontLineMeasurer: TextWidthMeasuring {
    private let font: UIFont

    init(textSize: CGFloat, weight: UIFont.Weight = .medium) {
        self.font = UIFont.systemFont(ofSize: textSize, weight: weight)
    }

    func characterWidths(of text: String) -> [CGFloat] {
        // A script draws on a few hundred distinct characters, so measuring
        // each one once turns thousands of text-layout calls into a few
        // hundred. Called on every re-layout (type size, column width), which
        // happens while a slider is being dragged.
        var cache: [Character: CGFloat] = [:]
        return text.map { character in
            if let cached = cache[character] { return cached }
            let width = NSAttributedString(
                string: String(character),
                attributes: [.font: font]
            ).size().width
            cache[character] = width
            return width
        }
    }
}
```

- [ ] **Step 2: 编译验证**

```bash
xcodebuild -project "ios/Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`。

此时 app 还编不过也可能是**旧的 `TeleprompterOverlayView` 引用了已被删掉的 `TeleprompterLine`** —— 那是预期的，Task 7 修。如果错误只来自 `TeleprompterOverlayView.swift`，继续往下走；其他文件报错要先解决。

- [ ] **Step 3: 提交**

```bash
git add "ios/Pollux One/Features/Recording/SystemFontLineMeasurer.swift"
git commit -m "Measure the prompter's glyphs with the font it draws in"
```

---

## Task 7: `TeleprompterOverlayView` — 固定窗 + 固定衬底 + 字级高亮

三条不能妥协的实现细节：

1. **衬底不在滚动的 `VStack` 里。** 它是窗口坐标系里的固定层，画在文字下面，文字从它上面滑过。跟着某一行走的衬底会随动画上下移动，固定行位就不存在了。
2. **每行的身份是 `line.id`（全局行序号），且渲染全部行。** 只渲染可见 5 行的话，SwiftUI 把每一步看成插入 + 删除，动画退化成交叉淡入淡出。
3. **所有行同一个字重。** 高亮边界按 `characterXOffsets` 定位，而那是用某一个字重量出来的。给当前行单独加粗会让它的实际字形宽度和测量值不符，高亮边界就漂了。

**Files:**
- Modify: `ios/Pollux One/Features/Recording/TeleprompterOverlayView.swift`（整体重写）

- [ ] **Step 1: 重写视图**

用以下内容**整体替换** `ios/Pollux One/Features/Recording/TeleprompterOverlayView.swift`：

```swift
import SwiftUI

/// The core HUD element (Feature 1 + 2): bare text on the preview, one type
/// size throughout, and a progress rail down the right edge instead of a
/// percentage.
///
/// A **fixed window**: 5 rows in Chinese, 6 in Latin, always. The highlight
/// band sits at rows 2–3 (Chinese) or 3–4 (Latin) and never moves; the script
/// scrolls through it a whole row at a time. The previous version sized itself
/// to whatever the current sentence happened to wrap to, so the whole block
/// changed height on every sentence and the reader's eyeline moved with it.
///
/// Three layers, bottom to top: the fixed band (with the read-so-far fill),
/// the scrolling text, the progress rail.
struct TeleprompterOverlayView: View {
    let state: TeleprompterDisplayState
    /// 0...1 along the current line. Separate from `state` so a 30Hz change
    /// invalidates only the fill — see `TeleprompterEngine`.
    var inLineProgress: Double = 0
    var progressFraction: Double = 0
    var textSize: CGFloat = 20
    var micLevel: Float = 0
    /// Only used to warn: the prompter's whole premise is that it sits beside
    /// the lens, which stops being true the moment capture moves to the back.
    var cameraFacing: CameraFacing = .front
    var onTap: () -> Void
    /// Fires whenever the column width or the type size changes, with the
    /// measurer that matches what is now being drawn. The view owns rendering
    /// metrics, so it owns the measurer.
    var onLayoutChange: (CGFloat, TextWidthMeasuring) -> Void

    @State private var measuredWidth: CGFloat = 0

    private let railColumnWidth: CGFloat = 22
    private let railGap: CGFloat = 6
    /// Keeps glyphs off the band's rounded edge. Applied to the text and to
    /// the fill's origin, so the two stay in register.
    private let textInset: CGFloat = 7
    /// One weight for every row — see the note above.
    private let rowWeight: Font.Weight = .medium
    private let uiRowWeight: UIFont.Weight = .medium

    private var effectiveTextSize: CGFloat {
        state.language.effectiveTextSize(base: textSize)
    }

    /// Uniform row pitch. There is deliberately no inter-row spacing: an extra
    /// gap means there is no single step to snap to, and the band could not
    /// cover exactly two whole rows.
    private var pitch: CGFloat {
        effectiveTextSize * state.language.lineHeightMultiple
    }

    private var windowHeight: CGFloat {
        CGFloat(state.visibleRows) * pitch
    }

    private var bandTop: CGFloat {
        CGFloat(state.readRowsAbove) * pitch
    }

    var body: some View {
        if state.isVisible {
            VStack(alignment: .leading, spacing: 0) {
                window
                footer
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }

    // MARK: - Window

    private var window: some View {
        HStack(alignment: .top, spacing: railGap) {
            ZStack(alignment: .topLeading) {
                band
                scrollingLines
            }
            .frame(height: windowHeight, alignment: .top)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                measuredWidth = width
                reportLayout()
            }
            .onChange(of: effectiveTextSize) { _, _ in reportLayout() }
            .onChange(of: state.language) { _, _ in reportLayout() }

            ProgressRailView(
                fraction: progressFraction,
                bandTop: bandTop,
                bandHeight: pitch * 2
            )
            .frame(width: railColumnWidth, height: windowHeight)
        }
    }

    /// The band, drawn *behind* the text and never moved. Its first row also
    /// carries the read-so-far fill.
    private var band: some View {
        ZStack(alignment: .topLeading) {
            HUDColor.bronze.opacity(0.55)

            // 0.44 over 0.55 composites to about 0.75 — the spec's figure for
            // the consumed part of the line.
            Rectangle()
                .fill(HUDColor.bronze.opacity(0.44))
                .frame(width: highlightWidth, height: pitch)
                .animation(.linear(duration: 1.0 / 30.0), value: highlightWidth)
        }
        .frame(height: pitch * 2)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .offset(y: bandTop)
        .allowsHitTesting(false)
    }

    /// Every line in the script, moved as one block.
    ///
    /// `state.lines` is the whole script, not a 5-row slice, and each row is
    /// identified by its global line index — so a scroll step moves existing
    /// nodes instead of replacing them, and reads as a slide.
    private var scrollingLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.lines) { line in
                Text(line.text)
                    .font(.system(size: effectiveTextSize, weight: rowWeight))
                    .foregroundStyle(.white.opacity(opacity(of: line)))
                    // Never re-wrap: the line was already broken to fit, and a
                    // one-point disagreement with our measurement must not
                    // turn one row into two and desynchronise every row below.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: pitch, alignment: .leading)
                    .shadow(color: .black.opacity(0.65), radius: 5, y: 1)
            }
        }
        .padding(.leading, textInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: -CGFloat(state.currentLineIndex - state.readRowsAbove) * pitch)
        // Whole-row snapping: the offset changes by exactly one pitch per step.
        // At the start of a script this offset is positive, which drops the
        // block and leaves the top rows blank — the band still does not move,
        // which is why no special case is needed for the first or last lines.
        .animation(.easeOut(duration: 0.3), value: state.currentLineIndex)
        .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Sized from the measured column, not `containerRelativeFrame`:
            // that resolves against the screen, and the column is now
            // narrowed by textWidthFraction, so a screen-relative bar sticks
            // out past the text it belongs to.
            MicLevelBarView(level: micLevel)
                .frame(width: max(measuredWidth, 0) * 0.45)

            if cameraFacing == .back {
                BackCameraNotice()
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived

    private var currentLine: PromptLine? {
        guard state.lines.indices.contains(state.currentLineIndex) else { return nil }
        return state.lines[state.currentLineIndex]
    }

    /// Where the read/unread boundary sits, in points.
    ///
    /// Read off `characterXOffsets` rather than computed as
    /// `inLineProgress × lineWidth`: in Latin, "i" and "W" are not the same
    /// fraction of a line, so a proportional edge visibly jitters as it
    /// crosses them.
    private var highlightWidth: CGFloat {
        guard let line = currentLine, line.characterCount > 0 else { return 0 }
        let clamped = min(max(inLineProgress, 0), 1)
        let index = min(
            Int((clamped * Double(line.characterCount)).rounded(.down)),
            line.characterXOffsets.count - 1
        )
        guard index > 0 else { return 0 }
        return textInset + line.characterXOffsets[index]
    }

    /// Roles are a function of distance from the current line, which is what
    /// makes the band's position a constant.
    private func opacity(of line: PromptLine) -> Double {
        switch line.id - state.currentLineIndex {
        case ..<0: 0.32       // read: does not need to be legible any more
        case 0, 1: 1.0        // the band's two rows
        case 2: 0.62          // next up
        default: 0.42
        }
    }

    private func reportLayout() {
        guard measuredWidth > textInset else { return }
        onLayoutChange(
            measuredWidth - textInset,
            SystemFontLineMeasurer(textSize: effectiveTextSize, weight: uiRowWeight)
        )
    }
}

/// Whole-script progress down the right edge, with a bracket marking the two
/// rows the reader is meant to be on.
///
/// Replaces a rail that drew itself from each row's role. With the roles now
/// fixed to row positions, that rail rendered identically forever — the
/// original "position is the readout" idea stopped being true the moment the
/// window stopped moving. Global progress is strictly more information: the
/// old rail could only say where the current sentence sat inside the visible
/// rows, which is now a constant.
private struct ProgressRailView: View {
    let fraction: Double
    let bandTop: CGFloat
    let bandHeight: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: 9)

                Capsule()
                    .fill(HUDColor.bronze)
                    .frame(width: 2, height: geo.size.height * CGFloat(min(max(fraction, 0), 1)))
                    .offset(x: 9)
                    .animation(.easeOut(duration: 0.3), value: fraction)

                BandBracket()
                    .stroke(HUDColor.bronze, lineWidth: 1.5)
                    .frame(width: 5, height: bandHeight)
                    .offset(x: 2, y: bandTop)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Says out loud what the back camera costs. Every other decision in this app
/// is checked against "does this help the speaker hold eye contact with the
/// lens"; shooting from the back is the one state where the answer is no, and
/// a take is easier to fix now than in review.
private struct BackCameraNotice: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash")
                .font(.system(size: 9))
            Text("BACK LENS · NO EYE CONTACT")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.8)
        }
        .fixedSize()
        .foregroundStyle(HUDColor.iosYellow)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

/// A "[" bracketing the band's two rows.
private struct BandBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
```

- [ ] **Step 2: 编译，确认只剩 `RecordingView` 的调用点报错**

```bash
xcodebuild -project "ios/Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:" | head -10
```

Expected: 只有 `RecordingView.swift` 报错（缺 `onLayoutChange` 等新参数）。Task 8 修。若 `TeleprompterOverlayView.swift` 自身还有 error，先解决它再往下。

- [ ] **Step 3: 提交**

```bash
git add "ios/Pollux One/Features/Recording/TeleprompterOverlayView.swift"
git commit -m "Draw the prompter as a fixed window with a band that does not move"
```

---

## Task 8: 接线 —— 宽度、遮罩、tick 生命周期

三件事：接通从没被读过的 `textWidthFraction`；把顶部遮罩从 300 抬到 330（最大字号下英文 6 行会到 312pt，超出遮罩的那两行会失去衬托直接压在画面上）；把新参数接上。

**Files:**
- Modify: `ios/Pollux One/Features/Recording/RecordingView.swift`

- [ ] **Step 1: 抬高顶部遮罩**

修改 `ios/Pollux One/Features/Recording/RecordingView.swift` 的 `Offset` 枚举：

```swift
        /// 330, not 300: at the 28pt type-size ceiling a six-row Latin window
        /// reaches 312pt from the top, and the rows past the gradient's end
        /// lose their backing and sit straight on the picture.
        static let topScrimHeight: CGFloat = 330
```

- [ ] **Step 2: 接上新参数与宽度比例**

把 `topGroup` 里的 `TeleprompterOverlayView(...)` 整段替换为：

```swift
            TeleprompterOverlayView(
                state: viewModel.sessionManager.teleprompterEngine.displayState,
                inLineProgress: viewModel.sessionManager.teleprompterEngine.inLineProgress,
                progressFraction: viewModel.sessionManager.teleprompterEngine.readingProgress.fractionComplete,
                textSize: viewModel.teleprompterSettings.textSize,
                micLevel: viewModel.sessionManager.audioLevelMonitor.recentLevels.last ?? 0,
                cameraFacing: viewModel.sessionManager.cameraEngine.configuration.facing,
                onTap: { viewModel.openTeleprompterAdjust() },
                onLayoutChange: { width, measurer in
                    viewModel.sessionManager.teleprompterEngine.setLayout(width: width, measurer: measurer)
                }
            )
            // The Width slider had never been wired to anything: this is the
            // first thing that reads textWidthFraction. It has to be applied
            // here rather than inside the overlay, because the fraction is of
            // the screen, and it is what decides where lines break.
            .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                width * viewModel.teleprompterSettings.textWidthFraction
            }
            .opacity(viewModel.teleprompterSettings.opacity)
            .offset(y: viewModel.teleprompterSettings.verticalOffset)
            .padding(.leading, Offset.teleprompterLeading)
            .topAnchored(Offset.teleprompterTop)
```

（`.padding(.trailing, Offset.teleprompterTrailing)` 去掉：宽度现在由 `textWidthFraction` 决定，右侧再留一道 padding 就等于两个东西同时管同一件事，滑杆的行为会变得不可预期。`Offset.teleprompterTrailing` 随之删除。）

- [ ] **Step 3: 编译**

```bash
xcodebuild -project "ios/Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 4: 离线场景仍然全过**

```bash
./scripts/test-engines.sh
```

Expected: `TOTAL: 201 passed, 0 failed`。

- [ ] **Step 5: 在模拟器上看一眼几何**

模拟器没有摄像头，会落到 `CameraUnavailablePlaceholder`，但 `prepare()` 照样跑，提词器照样排版渲染——所以行窗的几何、衬底位置、暗行梯度都能在模拟器上验证。语音跟随不能，那要真机。

用 iOS Simulator 工具：先 `attach` 开面板，再 build + `launch`，进到脚本列表点一条脚本进录制页，`screenshot`。

逐条对：

- 中文脚本：可见 **5** 行；衬底盖住第 **2–3** 行，且盖的是两**整**行
- 英文脚本：可见 **6** 行；衬底盖住第 **3–4** 行
- 衬底上方的暗行明显比未读行更暗（0.32 vs 0.62/0.42）
- 右侧进度轨有一个方括号，位置和衬底两行对齐
- 没有任何一行被中途截断成"半个字"
- 拖 Width 滑杆（点提词文字进入调整模式）时断行位置跟着变——这是 `textWidthFraction` 第一次真的起作用

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Features/Recording/RecordingView.swift"
git commit -m "Wire the prompter's column width, scrim, and pacing clock together"
```

---

## 完成后的状态

- 提词器块高恒定：中文 5 行、英文 6 行，衬底固定在中文 2–3 / 英文 3–4 行
- 推进按整行吸附 + 0.3s 缓动；行内进度由字级高亮连续体现
- 速度来自实测语速（指数平滑，夹在语种上下限内），两次识别之间 dead reckoning，封在真值前方 1.2 行
- `textWidthFraction` 第一次真的接通
- 离线场景从 107 条增加到 201 条，新增的全部集中在"静默出错"的地方：拼接口径、真值分母、断行禁则、前推上限、重排后位置保持、30Hz 不污染文字块

## 仍需真机验证的部分（不在本计划内）

模拟器没有麦克风与语音识别，所以以下只能上真机看，且属于调参而非改结构：

- 实测语速的收敛观感（`rateSmoothing = 0.25` 是否太慢）
- `lookaheadInLines = 1.2` 在真实识别延迟下是否让换行来得太早或太晚
- `correctionGain = 0.25` 下的校正是否肉眼可见

这三个都是 `ReadingPacer` / `TeleprompterEngine` 里的常量，各有离线场景覆盖，调它们不动结构。
