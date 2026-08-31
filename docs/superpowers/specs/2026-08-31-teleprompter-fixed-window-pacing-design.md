# 提词器固定行窗 + 实测语速配速 — 设计

日期：2026-08-31
状态：已确认，待实现

## 1 · 问题

提词器现在是**句驱动**的，不是行驱动的。`TeleprompterEngine.update(position:)`
取当前句前 1 句、后 2 句共 4 句，`TeleprompterOverlayView` 里只有当前句允许换行并带
青铜衬底，上下文句一律 `lineLimit(1)` 截断。

由此产生三个各自独立的缺陷：

**1.1 行数浮动，位置每句跳一次。**
当前句排成 1 行还是 3 行取决于它有多长，整块 HUD 的高度就跟着变。读者的视线刚锁定
某个高度，下一句一来整块就重排——这是"不顺滑"的直接来源，跟动画曲线无关。

**1.2 推进粒度是整句的，而细粒度信号被丢掉了。**
`SlidingWindowAlignmentEngine` 每次 `ingest` 都会算出句内 token 位置并放进
`ReadingPosition.tokenIndexInSentence`（`ScriptAlignmentEngine.swift:103`），
但 `TeleprompterEngine` 从来没读过这个字段。现成的、可用于行内插值的信号被完整丢弃。

**1.3 没有"速度"这个概念。**
没有自动滚动，没有语速测量，位置完全等语音识别回调。识别一卡、网络一抖、说话一含糊，
提词器就原地定住，然后在下一次识别回来时跳一大步。

**1.4 两个连带的既有缺陷**（不修就会挡住这次改动）：

- `TeleprompterSettings.textWidthFraction`（默认 0.86）**从未被任何代码读取**。
  `RecordingView` 只用了 `textSize` / `opacity` / `verticalOffset`。滑杆拖动无任何效果。
  固定行窗必须先知道排版宽度，所以这个设置这次必须接通。
- `Paragraph.fullText` 用 `" "` 连接句子（`ScriptModels.swift:39`）。中文会得到
  "…错误的问题。 它们让字…"，句号后多一个半角空格。**这次不改它**：它现有的两个
  调用方（语种检测、安全词替换的提议文案）对一个多余空格不敏感，改它属于无关联动。
  `PromptScriptText` 自己做按语种分流的拼接，不复用 `fullText`。

## 2 · 已确认的产品决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 可见行数 | 中文 5 行 / 英文 6 行，**固定** | 行数不随句长变化，块高恒定 |
| 行角色 | 衬底上方全为已读暗行（中文 1 行 / 英文 2 行），衬底 2 行，下方 2 行未读 | 对称；衬底边界永远落在整行上 |
| 衬底位置 | 中文第 2–3 行 / 英文第 3–4 行，**固定不动** | 视线有一个恒定的落点 |
| 滚动方式 | **整行吸附** + 0.3s easeOut 缓动 | 衬底永远精确盖住 2 整行，不出现半行截断；行内连续感由字级高亮承担 |
| 速度来源 | **实测语速前推 + 语音校正** | 语音对齐仍是真值，但两次识别之间按实测速率匀速滑行 |
| 前推上限 | 真值前方 **1.2 行** | 见 §4.3。这是本设计最关键的一条安全约束 |

### 2.1 两个取默认值的视觉参数

这两个是纯数值，改动成本各为一行，先按推荐值实现：

| 参数 | 取值 | 说明 |
|---|---|---|
| 衬底不透明度 | `bronze.opacity(0.55)`（现为 0.42） | 字面做成 1.0 会挡住脸所在的那条带，与"画面优先"冲突。0.55 比现在更实，仍透画面。 |
| 已读行不透明度 | 0.32（现为 0.45） | 已读内容不需要看清；压更暗能让视线更容易锁住衬底带。未读第一行 0.62、其后 0.42 不变。 |

## 3 · 架构

### 3.1 数据流

```
Script
  │
  ├─► PromptScriptText ──► (canonicalText, 句子字符区间表, 段落断点)
  │        规范化拼接：唯一口径
  │
  └─► PromptLineLayout(width:, measurer:) ──► [PromptLine]
           CoreText 断行                      每行带全局字符区间 + 字符 x 偏移表

ReadingPosition ──► TeleprompterEngine ──► ReadingPacer ──► cursor: Double
   (语音真值)          查表转字偏移            前推 + 校正      全局字符偏移，带小数

cursor ──► currentLineIndex（整数部分定位到行）
       └─► inLineProgress （行内已读比例）
```

**`PromptScriptText` 是唯一的文本拼接口径。** 排行和"句 → 字偏移"查表都必须走它。
两边各拼一次是这类功能最典型的错法：语音说到第 3 句，算出的字偏移和排行时的字偏移
差了几个空格，光标就永久性偏一点，且随脚本长度累积。

### 3.2 新增文件

**`Domain/ScriptLanguage.swift`** — 合并现有两处重复的 CJK 判定

CJK 检测现在在 `TeleprompterOverlayView.swift:30`（按字符占比 > 0.2）和
`TextTokenizer.swift:42`（按 Character 扩展）各写了一份，码点范围还不一致。合成一处：

```swift
enum ScriptLanguage: Equatable {
    case cjk
    case latin

    /// 按 CJK 码点占比判定，阈值 0.2 —— 沿用现有行为。按内容而非 locale 字段
    /// 判定，因为同一篇脚本可以合法地混排两种文字。
    static func detect(_ text: String) -> ScriptLanguage

    /// 句子拼接时的分隔符：中文句号后不加空格，拉丁文加。
    var sentenceJoiner: String { self == .cjk ? "" : " " }
}
```

排行、语速默认值、字号档位、行高倍数共用这一份判定。

**`Domain/PromptScriptText.swift`** — 纯数据，无框架依赖

```swift
struct PromptScriptText: Equatable {
    /// 规范化后的全文。行排版和字偏移查表都基于这一个字符串。
    let text: String
    /// 句子 id → 它在 `text` 里的字符区间（以 Character 计数，非 UTF-16）。
    let sentenceRanges: [UUID: Range<Int>]
    /// 硬换行位置（段落 / section 边界）。断行时不得跨越。
    let hardBreaks: [Int]
    let language: ScriptLanguage

    static func build(_ script: Script) -> PromptScriptText
}
```

**`Domain/PromptLineLayout.swift`** — 断行，测量能力注入

```swift
/// 一行排好的视觉行。
struct PromptLine: Equatable, Identifiable {
    /// 全局行序号，同时充当 SwiftUI 的稳定身份 —— 见 §5.2。
    let id: Int
    let text: String
    /// 该行在 PromptScriptText.text 中的字符区间。
    let characterRange: Range<Int>
    /// 行内每个字符的起始 x（含末尾哨兵，长度 = 字符数 + 1）。
    /// 字级高亮要按像素定位，而"第 n 个字符"到"x 坐标"在拉丁文里不是线性关系。
    let characterXOffsets: [CGFloat]
}

/// 测量单独抽成协议，是为了让断行逻辑能进 scripts/test-engines.sh 那套
/// macOS 离线 harness —— 那里没有 UIKit，也不该依赖真实字体度量。
///
/// 协议只负责**量宽**，不负责断行。断行算法留在 PromptLineLayout 里，
/// 因此它是可断言的纯逻辑；如果把断行也委托给协议，harness 里就只剩窗口逻辑
/// 被测到，而断行恰恰是最容易错的一半。
protocol TextWidthMeasuring {
    func characterWidths(of text: String) -> [CGFloat]
}

enum PromptLineLayout {
    static func lines(
        for source: PromptScriptText,
        width: CGFloat,
        measurer: TextWidthMeasuring
    ) -> [PromptLine]
}
```

#### 3.2.1 断行规则

贪心：逐字符累加宽度，超出 `width` 就在此之前断开，`hardBreaks` 处强制断开。
断点的选择按语种分流：

- **拉丁**：回退到该行最后一个空白处断开；整行一个词都放不下时才硬切。
- **CJK**：原则上任意字符间可断，但要避开两类位置——
  - **行首禁则**：下一行不得以 `。，、；：！？）］｝」』〉》” ’ ·` 开头 → 断点左移一格
  - **行尾禁则**：本行不得以 `（［｛「『〈《“ ‘` 结尾 → 断点左移一格
  - 左移最多 2 格，再不行就照原位断（避免病态输入下死循环）

**`Features/Recording/SystemFontLineMeasurer.swift`** — iOS 侧实测（**不进** harness）

`TeleprompterEngine` 自己**不构造** measurer，而是由视图通过
`setLayout(width:measurer:)` 注入。这样引擎本身也不 import UIKit，可以一并进
harness，窗口逻辑（开头/结尾的空白补齐、行角色、重排后位置保持）因此是可离线断言的。

用 `UIFont.systemFont(ofSize:weight:)`（就是 SwiftUI `Font.system(size:weight:)`
背后的那支字体）逐字符量宽，按字符缓存——一篇脚本只有几百个不同字符，于是几千次
文本布局调用收敛成几百次。**只做这一件事**——断行在 `PromptLineLayout` 里。

代价：逐字符测量忽略字符间的 kerning 与连字，长拉丁行量出来比画出来略宽。这个方向
是安全的（提前断行，而非溢出），视图再留一点余量。

不用 `CTTypesetterSuggestLineBreak`：它确实自带完整的 CJK 换行规则，但那会把断行
从可离线断言的纯逻辑变成对 CoreText 的黑盒调用，harness 里就测不到了。代价是禁则
要自己写，但只需要覆盖一个固定的小集合（§3.2.1），十几行，且可精确断言。

**`Engines/ReadingPacer.swift`** — 配速控制器，纯逻辑，进 harness

```swift
@MainActor
final class ReadingPacer {
    /// 全局字符偏移，带小数。小数部分就是行内进度。
    private(set) var cursor: Double = 0
    /// 实测语速，字符/秒。指数平滑。
    private(set) var rate: Double

    init(language: ScriptLanguage)

    /// 定时 tick：按当前速率前推，并夹在真值前方 lookaheadCap 之内。
    func advance(deltaTime: TimeInterval, lookaheadCap: Double)

    /// 语音真值到达。更新速率，并把偏差滑行吃掉（或大偏差直接 seek）。
    func correct(to truth: Double, confidence: Double, at time: TimeInterval, seekThreshold: Double)

    /// 换脚本 / 重开一条 take。
    func reset(to offset: Double, language: ScriptLanguage)
}
```

### 3.3 改写的文件

**`Engines/TeleprompterEngine.swift`** — 从"取 4 个句子"改成"持有行 + 配速器"

```swift
struct TeleprompterDisplayState: Equatable {
    /// 全脚本的视觉行。重排（改字号 / 宽度）时整体替换。
    var lines: [PromptLine]
    var currentLineIndex: Int
    /// 衬底上方的已读行数：中文 1 / 英文 2。
    var readRowsAbove: Int
    /// 可见行数：中文 5 / 英文 6。
    var visibleRows: Int
    var isVisible: Bool = true
}
```

实现时这两个数改为**由 `language` 派生的计算属性**，`displayState` 只存
`language`：两个并存的存储字段可以和 `language` 互相矛盾，而固定行窗的全部意义
就在于这两个数对给定脚本是常量。视图也需要 `language` 来定字号和行高，与其在视图里
再检测一次（可见行少，混排脚本上会和这里的判定不一致），不如带着走。

引擎上另有**两个独立的** `@Observable` 存储属性，都不在 `displayState` 里：

| 属性 | 变化频率 | 读它的是谁 |
|---|---|---|
| `displayState` | 每推进一行（约每 2–4 秒） | 文字 VStack |
| `inLineProgress: Double` | 30Hz | 当前行的高亮填充 |
| `readingProgress: ReadingProgress` | 30Hz | 右侧进度轨 |

`progress` 必须从 `displayState` 里搬出来：它的 `fractionComplete` 由 cursor 算得，
每 tick 都变。留在 struct 里就等于每秒把整块文字 diff 30 次——正是 §5.3 要避免的事。
`SessionManager.swift:208` 现在读的是 `displayState.progress`，要改成
`teleprompterEngine.readingProgress`。

行角色由视图按 `line.id - currentLineIndex` 现算，不预先切窗口：

| 差值 | 角色 |
|---|---|
| < 0 | 已读（0.32） |
| 0 | 当前行（衬底 + 字级高亮） |
| 1 | 下一行（衬底） |
| 2 | 未读（0.62） |
| ≥ 3 | 未读（0.42） |

**`Features/Recording/TeleprompterOverlayView.swift`** — 见 §5

随之删除的东西：`TeleprompterLine` 及其 `Emphasis` 枚举（角色改为按行序差现算）、
`singleLine(_:opacity:)`、`isFirstUpcoming(_:)`、按行角色画的 `rail(for:isLast:)`
和 `railBar(...)`、`Triangle` 形状、`rowGap` / `railBleed` 常量。视图里的
`isCJK` / `effectiveTextSize` / `lineHeightMultiple` 迁到 `ScriptLanguage`。

## 4 · 配速算法

### 4.1 光标的单位是字符

`ReadingPacer.cursor: Double` = 全局字符偏移。选它而不选"行号 + 像素偏移"的理由：
**改字号或宽度后重排，光标自动存活**，不需要任何位置迁移代码。字符偏移是排版无关量，
重排只改"哪一行装哪些字符"，不改"读到第几个字符"。

### 4.2 推进与校正

| 事件 | 动作 |
|---|---|
| 每 1/30 秒 tick | `cursor += rate × dt`，然后按 §4.3 夹住 |
| 真值到达，`confidence ≥ 0.5` | 由 `Δcursor真值 / Δt` 得瞬时速率，EMA α = 0.25 更新 `rate` |
| 真值到达，`|error| ≤ 2 行` | `cursor += error × 0.25`；约 3–4 次识别（0.5–1s）吃平，全程不跳 |
| 真值到达，`|error| > 2 行` | 判为跳读 / 回读，`cursor = truth` 直接 seek（视觉上仍走 0.3s 缓动，是一次快滑不是传送） |

`error = truth - cursor`。真值由 `ReadingPosition` 换算：

```
denominator = TextTokenizer.tokens(in: sentence.text).count
truth = sentenceRange.lowerBound
      + (tokenIndexInSentence / denominator) × sentenceRange.count
```

**分母必须是 `TextTokenizer.tokens(in:)` 的数量，不能用 `sentence.tokens.count`。**
这两者是不同的切分：`Sentence.tokens` 走 `Token.tokenize`，按空格切
（`ScriptModels.swift:73`）；而 `tokenIndexInSentence` 是
`SlidingWindowAlignmentEngine` 用 `TextTokenizer.tokens(in:)` 算出来的，中文按字切。
中文一整句用 `Token.tokenize` 只得到 **1** 个 token，分母写错会让比例恒 ≥ 1，
真值永远停在句尾——中文提词器会整句都不动，然后在句末瞬移。这是个静默错误，
harness 必须有一条中文场景专门钉住它。

按 token 比例线性插值，而不是精确的 token → 字符映射。近似值足够：句内插值的误差
上限是一个 token 的宽度，而校正环每次识别都会把它拉回来。做精确映射需要
`TextTokenizer` 返回字符区间，成本远大于收益。

速率参数：

| 语种 | 初值 | 下限 | 上限 |
|---|---|---|---|
| 中文 | 5.0 字/秒（300 字/分） | 2.0 | 12.0 |
| 拉丁 | 16.0 字符/秒（≈190 wpm） | 6.0 | 40.0 |

### 4.3 前推上限 —— 本设计最关键的一条约束

```
cursor ≤ lastTruth + 1.2 × (当前行字符数)
```

纯 dead reckoning 遇到读者停下来喝水、被打断、或识别整段失败，就会一路匀速跑飞，
把提词器推到脚本末尾。封在真值前方 1.2 行以内，读者一停，光标最多再走一行多就顶住，
**行内高亮随之停住**——这个"停住"本身就是给读者的反馈，不需要额外的 HUD 提示文案。

选 1.2 行而不是 1.0：识别回调有 0.3–0.8s 延迟，允许略超一行才能让正常朗读时的
换行动作发生在你读到行尾的**同时**，而不是滞后半秒。

不引入"静音超时"计时器：上限约束已经覆盖了同一个失效场景，而且它是位置量、
不受识别回调抖动影响，比时间量更稳。

## 5 · 渲染

### 5.1 几何

```
┌───────── 固定高度 = visibleRows × pitch，clipped ─────────┐
│  已读行                                          0.32     │  中文 1 行 / 英文 2 行
│ ▓▓ 当前行 ── 字级高亮沿 characterXOffsets 推进 ▓▓         │  衬底
│ ▓▓ 下一行                                       ▓▓        │  衬底
│  未读行                                          0.62     │
│  未读行                                          0.42     │
└───────────────────────────────────────────────────────────┘
```

`rowGap: 4` 必须去掉，折进行高倍数（中文 1.6 / 拉丁 1.5 已经含呼吸量）。有额外行间距
就没有统一的吸附步长，衬底也无法精确盖住 2 整行。

`pitch = effectiveTextSize × lineHeightMultiple`：

| 语种 | textSize 20（默认） | 块高 | textSize 28（上限） | 块高 |
|---|---|---|---|---|
| 中文 | 19 × 1.6 = 30.4 | 5 × 30.4 = **152** | 27 × 1.6 = 43.2 | 5 × 43.2 = **216** |
| 拉丁 | 20 × 1.5 = 30.0 | 6 × 30.0 = **180** | 28 × 1.5 = 42.0 | 6 × 42.0 = **252** |

块顶在 y = 60（`Offset.teleprompterTop`）。最坏情况（拉丁 28pt）块底到 312pt，
**超出现有 300pt 的顶部渐变遮罩 12pt**，最后一行会失去衬托直接压在画面上。
所以 `Offset.topScrimHeight` 300 → **330**。改的是一层不可见的渐变高度，零风险。

### 5.2 滚动实现

全脚本的行放进一个 `VStack(spacing: 0)`，容器整体位移：

```swift
.offset(y: -CGFloat(currentLineIndex - readRowsAbove) * pitch)
.animation(.easeOut(duration: 0.3), value: currentLineIndex)
```

每行的 `id` 是全局行序号，因此**每行在推进前后是同一个 SwiftUI 节点**，推进就是纯位移
滑动。

如果改成"只渲染可见的 5 行"，SwiftUI 会把每一步看成一次插入 + 一次删除，动画退化成
交叉淡入淡出——那就不是滑动，看起来跟现在的按句跳没有本质区别。**这是本节唯一不能
妥协的实现细节。**

开头和结尾不需要特殊分支：`currentLineIndex < readRowsAbove` 时 offset 变正数，
VStack 自然下移，clip 出上方空白，衬底位置分毫不动。结尾同理。

**代价**：全脚本的 `Text` 都参与布局。提词脚本以"一条 take 读完"为长度上限，
量级在百行内，可以接受。真出现卡顿再切片渲染 —— 但切片会把"稳定节点身份"这个前提
弄复杂，不预先做。

### 5.3 30Hz 更新不能污染整块文字

`inLineProgress` 每 1/30 秒变一次。如果它在 `displayState` 里，整个 struct 每秒变
30 次，SwiftUI 就要对所有 `Text` 做 30 次 diff。

所以它和 `readingProgress` 都是 `TeleprompterEngine` 上**独立的** `@Observable`
存储属性。`@Observable` 按属性粒度追踪读取，只有读它们的那两层（当前行的高亮填充、
右侧进度轨）会失效重绘。

tick 用 `Timer.scheduledTimer` 1/30s，沿用 `AudioLevelMonitor.startDisplayUpdates()`
已经在用的模式（那里是 1/15s）。

### 5.4 衬底与字级高亮

**衬底不在滚动的 VStack 里。** 它是窗口坐标系里一个固定位置的圆角矩形，画在文字
**下面**；文字从它上方滑过。这正是"衬底固定、文字穿过它"的实现方式——如果衬底跟着
某一行走，它就会跟着动画上下移动，固定行位也就不存在了。

层次自下而上：固定衬底 → 字级高亮填充（也在固定层）→ 滚动的文字 VStack → 进度轨。

衬底是**一个**跨 2 行的连续圆角矩形（`bronze.opacity(0.55)`，圆角 7），不是两个。
当前行的已读部分在它内部再叠一层 `bronze.opacity(0.75)`，宽度由

```
characterXOffsets[floor(inLineProgress × 字符数)]
```

得到，`.animation(.linear)` 跟着 tick 走。文字始终纯白，不做分段变色——变色会让
读者的眼睛去追颜色边界，而这里要的是"底色告诉你读到哪，字始终最清楚"。

换行的那 0.3s 里，高亮填充按**新的**当前行立刻重算（回到行首再往前走），文字还在滑动
中途。两者不同步是可接受的：填充此刻宽度接近 0，视觉上就是"归零后重新出发"。

按 `characterXOffsets` 而不是 `进度 × 行宽`：拉丁文里"第 n 个字符"到 x 坐标不是线性的，
按比例算会让高亮边界在 `i` 和 `W` 之间来回抖。

### 5.5 进度轨必须重做

这是固定行位的连带后果。现在的轨是**按行角色**画的（`TeleprompterOverlayView.swift:125`）：
已读行 3pt 青铜、当前行半粗 + 箭头、未读行 1pt 细线。行角色一旦固定，这根轨就永远长
一个样，原注释里写的 "position is the readout" 直接失效，变成一列死像素。

改成一条贯穿窗口高度的全局进度轨，按 `progress.fractionComplete` 填充青铜，并用一个
青铜方括号标出衬底那两行的高度。信息量比现在更大：现在只能读出"当前句在可见范围内的
位置"（固定后恒为常量），改完能读出"整篇读到哪了"。

## 6 · 重排与位置保持

改 `textSize` 或 `textWidthFraction` → 重新调用 `PromptLineLayout.lines`。
`cursor` 是字符偏移，重排后 `currentLineIndex` 由新的行区间重新查得，**不需要迁移逻辑**。
这是 §4.1 选字符作单位的直接回报，也是要断言的一条不变量。

排版宽度：`RecordingView` 用 `containerRelativeFrame` 把整块收窄到
屏宽 × `textWidthFraction`，进度轨列（22 + 6）由窗口内的 `HStack` 自然扣掉，
视图再减去文字的 7pt 左内缩后报给引擎。原来的 `Offset.teleprompterTrailing`
随之删除——宽度只能有一个主管者。

## 7 · 测试

全部走 `scripts/test-engines.sh` 那套 macOS 离线 harness（新增
`ios/EngineHarness/LayoutScenarios.swift`、`PacingScenarios.swift`、
`FakeTextMeasurer.swift`）。断行、配速、行窗都是纯数据进 / 数据出，连
`TeleprompterEngine` 本身也进——它不 import UIKit，measurer 是注入的。

harness 侧的 `TextWidthMeasuring` 用确定性假测量：CJK 字符 = 1.0em、拉丁字符 = 0.5em、
空格 = 0.5em。断行结果因此可以精确断言，不依赖任何真实字体。

| 场景 | 断言 |
|---|---|
| 断行 | 给定宽度下的换行位置；不跨 `hardBreaks` |
| 拼接口径 | 中文句子间无空格；`sentenceRanges` 与 `canonicalText` 一致 |
| 行角色 · 开头 | `currentLineIndex = 0` 时衬底仍在第 2–3 行（中文），上方 1 行空白 |
| 行角色 · 结尾 | 最后一行时衬底不移，下方补空白 |
| 前推 | 按实测速率匀速推进 |
| **前推上限** | 真值不动时，`cursor` 顶在 `truth + 1.2 行` 不再增长 |
| 小偏差 | 3–4 次校正内收敛，且每一步位移单调、不反向 |
| 大偏差 | 超过 2 行直接 seek 到真值 |
| **中文真值分母** | 中文句子的 `tokenIndexInSentence` 换算出的真值随 token 递增，不恒在句尾 |
| 速率收敛 | 模拟 4 字/秒的读者，EMA 收敛到 4.0 ± 0.3 |
| 速率夹取 | 异常快 / 慢的真值不会把 `rate` 推出上下限 |
| **重排不变量** | 宽度 A 排版下的 `cursor`，换成宽度 B 重排后字偏移不变 |

## 8 · 不做的事

- **不做**手动 WPM 滑杆 / 定速模式。实测语速 + 前推上限已经覆盖了"识别不给力"的场景。
- **不做**连续像素滚动。已确认走整行吸附。
- **不做**识别状态的 HUD 文案（"正在跟随" / "已停止"）。高亮停住就是反馈；
  真正的失效（授权被拒、识别启动失败）已经有 `speechError` 那条现成通路。
- **不做**长脚本的切片渲染。见 §5.2。
- **不改**`SlidingWindowAlignmentEngine`。它的输出已经够用，这次只是第一次真正去读
  `tokenIndexInSentence`。

## 9 · 风险

| 风险 | 缓解 |
|---|---|
| `CTTypesetterSuggestLineBreak` 的断行与 SwiftUI `Text` 的实际渲染不完全一致，行尾可能差一个字符 | 视图侧对每行用 `lineLimit(1)` + `fixedSize(horizontal:)`，排版宽度留 2pt 余量；harness 用假测量断言的是算法而非像素 |
| 全脚本 `Text` 布局在超长脚本上卡顿 | 已知代价，见 §5.2。触发条件明确（百行以上），届时切片 |
| 30Hz tick 与相机录制争 main thread | 单个 `Double` 赋值 + 一层 shape 重绘；`AudioLevelMonitor` 已在 15Hz 上跑同类负载 |
| 前推上限选 1.2 行偏保守 / 偏激进 | 是 harness 里的一个常量，有场景覆盖，调它不动结构 |
