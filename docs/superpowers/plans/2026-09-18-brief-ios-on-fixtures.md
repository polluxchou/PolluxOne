# 七个界面，喂填充物 — 实施计划（spec 第二段，提前做）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 七个界面在 iOS 上真的能点、能滑、能跳转，全部数据来自本地 fixture。一次模型调用都不发。

**Architecture:** 先把相机变成根视图、把 `SessionManager` 提到 `RecordingView` 之上，再照 mock 逐屏建。所有判断逻辑放在**不含 SwiftUI 的纯类型**里，由 `EngineHarness` 离线验证；View 只负责把它们画出来。

**Tech Stack:** Swift 6 · SwiftUI · 现有 `EngineHarness` 命令行测试台 · 无第三方包

---

## 零、动手之前必须知道的事

### 0.1 测试台是什么，以及它的硬约束

`scripts/test-engines.sh` 用 `swiftc` 直接编译一组源文件成一个命令行二进制。**它不链接 SwiftUI。**

因此：

| 约束 | 后果 |
|---|---|
| 不能 `import SwiftUI` | 所有被测类型只能用 Foundation。颜色是 `enum SentenceAccent`，不是 `Color` |
| 不是 app bundle | `Bundle.main` 读不到 fixture。加载器必须接受**文件路径** |
| 编译参数是 `-swift-version 5 -default-isolation MainActor` | 所有类型默认 MainActor 隔离 |
| **新文件必须手动加进 `scripts/test-engines.sh` 的编译列表** | 漏加 = 类型找不到，而不是测试失败 |

断言 API 不是 `expect`，是这个形状：

```swift
@MainActor
func runBriefSuite() -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("Brief fixtures — the screens' data contract")

    report.section("解码")
    report.check(brief.estimatedSeconds == 83, "时长是 83 秒", detail: "\(brief.estimatedSeconds)")

    return (report.pass, report.fail)
}
```

每个新 suite 还要在 `ios/EngineHarness/main.swift` 里注册并计入总数，否则它永远不会被跑到。

### 0.2 已经核过的既有 API（别照 spec 的描述写，spec 有出入）

| 东西 | 真实签名 | spec §9.2 ②.3 的说法 |
|---|---|---|
| `SessionManager.init` | `init(syncService:alignmentEngine:takeArchiver:)` | 说"按 script 造出来"——**不准确**，它不接受 script |
| 当前稿 | `private(set) var scriptRevision: ScriptRevision?` | 说要"变成可选"——**它本来就是可选的** |
| 装载稿子 | `func prepare(script: Script) async` | 未提它是 async |
| 相机引擎 | `let cameraEngine: CameraEngine`，在 init 里造一次 | — |
| `RecordingView.init` | `init(script: Script, syncService:takeArchiver:)`，**在里面造 SessionManager**（`RecordingView.swift:52`） | 这一条是对的 |

所以真正的毛病是：**`RecordingView` 每次被构造都会造一个新的 `SessionManager`，进而造一个新的 `CameraEngine`**。从列表进不同的稿 = 新 View = 取景器黑一下重启。引擎层本来就支持换稿（`prepare(script:)` 内部就是 `teleprompterEngine.load` + `alignmentEngine.reset`），错的是构造时机。

`ReadingPacer` 同理：它是 `ReadingPacer(language:)`，有 `rate` / `cursor` / `advance(deltaTime:lookaheadCap:)`。

### 0.3 为什么先做界面，代价是什么

spec §12 要求先做后端管线、跑质量关再投界面。**这条被推翻了。**

代价要认：**这一段做完，你仍然不知道稿子好不好。** 质量关只是推迟。管线计划在 `docs/superpowers/plans/2026-09-18-brief-live-pipeline.md`。

好处已经兑现：mock 里藏着三个后端目前产不出来的东西（§0.4）。

### 0.4 mock 要的三样东西，确定性内核产不出来

从 `project/Review.dc.html` / `project/Progress.dc.html` 反推：

| mock 上的 | 现状 | 本计划 |
|---|---|---|
| 句内虚线下划线（`0.5 个百分点`） | `DraftSentence` 只有整句 `claimIds` | fixture 带 `anchors: [{start,length,claimId}]` |
| 「另有 6 篇为上述稿件转载，未计入」 | `independence` 丢了被归并的篇数 | fixture 带 `mergedAwayCount` |
| 「预算 120K · 已用 40%」「本月余额 2.41M」 | 没有模型 | fixture 带 `budget` |

Task 16 把它们写回 spec。

### 0.5 错误方向

界面这一段最危险的不是崩，是**显示一个比真相更乐观的数字**：

| 做错的方向 | 后果 |
|---|---|
| 把"篇数"当"独立源数"显示 | 用户以为 10 个源，其实是 1 篇稿转载 10 次 |
| 证据锚点错位 | 点开看到的信源对不上那个数字 |
| 已删句子的证据没清 | 孤儿证据挂到别的句子上 |
| 未开始的阶段显示 0 | 0 读起来像结果 |

一律宁可少显示。

---

## 一、文件结构

新增的 Domain 文件**全部不含 SwiftUI**，且都要加进 `scripts/test-engines.sh`：

```
ios/Pollux One/Domain/Brief/
  BriefModels.swift       Brief · NewsRef · BriefStatus · BriefSentence · EvidenceAnchor
  Evidence.swift          ClaimEvidence · SourceRef · EvidenceLabel · EvidenceFooter
  BriefStage.swift        BriefStage · StageState · TokenBudget · TokenBar
  BriefFixture.swift      按路径解码
  BriefEdits.swift        删句 + 孤儿证据清理
  SentenceStyle.swift     着色判断 · SentenceCounts
  AnchorRuns.swift        句子按锚点切段
  SwipeActions.swift      左滑按类型分化
  ScriptSlot.swift        相机右下角那格
  DialState.swift         ④ 拨盘
  BriefNavigation.swift   §8.2 返回语义
  HandOffState.swift      ③ 交给我
  InsufficientState.swift ⑥ 不建议播

ios/Pollux One/Features/Brief/        （SwiftUI，不进测试台）
  ReviewView.swift · SentenceRow.swift · EvidenceSheet.swift
  HandOffView.swift · ConfirmView.swift · DialControl.swift
  BriefProgressView.swift · InsufficientView.swift

ios/Pollux One/Resources/brief-fixture.json
ios/EngineHarness/BriefScenarios.swift
```

---

## Task 1: 数据契约与 fixture

**Files:**
- Create: `ios/Pollux One/Domain/Brief/BriefModels.swift`, `Evidence.swift`, `BriefStage.swift`, `BriefFixture.swift`
- Create: `ios/Pollux One/Resources/brief-fixture.json`
- Create: `ios/EngineHarness/BriefScenarios.swift`
- Modify: `scripts/test-engines.sh`, `ios/EngineHarness/main.swift`

字段全部从 mock 上的可见内容反推。**mock 上没有的字段一个都不加**——加了就是在猜产品。

- [ ] **Step 1: 写类型**

```swift
// ios/Pollux One/Domain/Brief/BriefModels.swift
import Foundation

/// 用户给进来的那条新闻，收成一行标签用（spec §8 ②③④ 都是这个形态）。
struct NewsRef: Codable, Equatable {
    let publisher: String
    let title: String
    let url: String?
}

enum BriefStatus: String, Codable {
    case researching   // ⑤ 等待
    case ready         // ② 审稿
    case insufficient  // ⑥ 不建议播
}

enum SentenceKind: String, Codable {
    case fact, opinion, transition
}

/// 句内的证据锚点：mock 上那条虚线下划线。
/// `start` / `length` 以**字符**计（Character，不是 UTF-16 code unit），
/// 中文一个字算一个——用 utf16 会让中文全部错位。
struct EvidenceAnchor: Codable, Equatable {
    let start: Int
    let length: Int
    let claimId: String
}

struct BriefSentence: Codable, Equatable, Identifiable {
    let id: String
    let text: String
    let kind: SentenceKind
    let claimIds: [String]
    let anchors: [EvidenceAnchor]

    /// spec §8.1：事实句左滑露「重查 + 删除」，其余只露「删除」。
    /// 观点句没有信源可重查，给它一个重查按钮就是在骗人。
    var canRecheckSources: Bool { kind == .fact }
}

struct Brief: Codable, Equatable, Identifiable {
    let id: String
    let news: NewsRef
    var status: BriefStatus
    /// 已按语速算过的秒数。mock 上是 83。
    let estimatedSeconds: Int
    /// 这个秒数是否用了该用户自己的语速。false 时界面**不许**写「按你的语速」——
    /// spec §9.2 ① 说新用户的第一篇必然是语种默认值。
    let pacedToUser: Bool
    var sentences: [BriefSentence]
    var claims: [String: ClaimEvidence]
    let stages: [BriefStage]
    let budget: TokenBudget
    /// ⑥ 不建议播时的理由，其余状态为 nil。
    let insufficientReason: String?
}
```

```swift
// ios/Pollux One/Domain/Brief/Evidence.swift
import Foundation

struct SourceRef: Codable, Equatable, Identifiable {
    var id: String { publisher + "@" + time }
    let publisher: String
    /// mock 第二列：逐字引文，或「独立测算，口径一致」这样的说明。
    let note: String
    /// mock 第三列，形如 "15:02"。
    let time: String
}

struct ClaimEvidence: Codable, Equatable {
    let id: String
    /// **互不相关的信源组数**，不是篇数。界面上那个数字就是它。
    let independence: Int
    /// 被判为转载、已归并掉的篇数。mock：「另有 6 篇为上述稿件转载，未计入」。
    /// 与 independence 分开存，是因为把两者相加正是用户最容易犯的误读。
    let mergedAwayCount: Int
    let sources: [SourceRef]

    /// spec §5：3 个以上独立源才算站得住。
    static let strongThreshold = 3
    var isStrong: Bool { independence >= Self.strongThreshold }
}

/// 折叠态那个按钮上的字。
struct EvidenceLabel {
    let text: String
    let isWarning: Bool

    init(_ claim: ClaimEvidence) {
        if claim.independence <= 1 {
            // mock 上是「仅 1 个信源」——「仅」这个字是这里唯一的警告手段。
            text = "仅 \(claim.independence) 个信源"
            isWarning = true
        } else {
            // 永远说「独立信源」。说「篇」会把用户的心算引向加上转载。
            text = "\(claim.independence) 个独立信源"
            isWarning = false
        }
    }
}

/// 展开后最末那行灰字。
struct EvidenceFooter {
    let text: String?

    init(mergedAwayCount: Int) {
        // 没有转载时整行消失。写「另有 0 篇」是噪音。
        text = mergedAwayCount > 0
            ? "另有 \(mergedAwayCount) 篇为上述稿件转载，未计入"
            : nil
    }
}
```

```swift
// ios/Pollux One/Domain/Brief/BriefStage.swift
import Foundation

enum StageState: String, Codable {
    case done, running, pending
}

/// spec §8 ⑤：九个阶段带**计数**而非耗时——计数告诉用户挖到了什么，
/// 那才是他愿意等下去的理由。
struct BriefStage: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let state: StageState
    /// 形如 "14 篇"、"86 条"、"23 点 · 7 独立源"、"9 / 23"。未开始时 nil。
    let count: String?
    /// 进行中那个阶段底下的实时说明。其余为 nil。
    let detail: String?
}

/// spec §10.1：token 是一等产品对象。
struct TokenBudget: Codable, Equatable {
    let used: Int
    let budgeted: Int
    let remainingThisMonth: Int
    let costCents: Int
    /// 阶段名 → token 数。之和必须等于 used，否则进度条在撒谎。
    let byStage: [String: Int]

    var fractionUsed: Double {
        budgeted > 0 ? Double(used) / Double(budgeted) : 0
    }
}

/// mock 上那条分段进度条。每段宽度是「该阶段占预算的比例」，
/// 所以各段之和必然等于 fractionUsed——这一条由测试钉死。
struct TokenBar {
    struct Segment: Equatable {
        let stage: String
        let fraction: Double
    }

    let segments: [Segment]

    init(_ budget: TokenBudget) {
        guard budget.budgeted > 0 else { segments = []; return }
        // 排序是为了让颜色分配稳定：同一份数据每次画出来都一样。
        segments = budget.byStage
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { Segment(stage: $0.key, fraction: Double($0.value) / Double(budget.budgeted)) }
    }
}
```

```swift
// ios/Pollux One/Domain/Brief/BriefFixture.swift
import Foundation

/// 测试台是命令行二进制，没有 app bundle，所以加载器必须接受路径。
/// app 里走 `loadFromBundle()`，harness 走 `load(at:)`。
enum BriefFixture {
    enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        case undecodable(String)

        var description: String {
            switch self {
            case .missing(let path): "读不到 fixture：\(path)"
            case .undecodable(let why): "fixture 解不开：\(why)"
            }
        }
    }

    static func load(at path: String) throws -> Brief {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LoadError.missing(path)
        }
        do {
            return try JSONDecoder().decode(Brief.self, from: data)
        } catch {
            throw LoadError.undecodable(String(describing: error))
        }
    }

    static func loadFromBundle() throws -> Brief {
        guard let url = Bundle.main.url(forResource: "brief-fixture", withExtension: "json") else {
            throw LoadError.missing("brief-fixture.json (bundle)")
        }
        return try JSONDecoder().decode(Brief.self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 2: 照 mock 写 fixture**

`ios/Pollux One/Resources/brief-fixture.json`。数值全部照抄 mock。

**`byStage` 有一个坑**：mock 图例是抽取 38.1K / 成稿 6.2K / 检索 3.9K，加起来 48,200，但总数写的是 48,240。差的 40 补在「抓取原文」上，否则 Step 4 的自洽断言过不了。

```json
{
  "id": "b-fixture-1",
  "news": {
    "publisher": "财新",
    "title": "央行宣布下调存款准备金率 0.5 个百分点",
    "url": "https://example.caixin.com/2026-09-18/rrr-cut.html"
  },
  "status": "ready",
  "estimatedSeconds": 83,
  "pacedToUser": true,
  "sentences": [
    { "id": "s1", "text": "央行今天突然出手了。", "kind": "transition", "claimIds": [], "anchors": [] },
    {
      "id": "s2",
      "text": "下调存款准备金率0.5 个百分点，3 月 15 日正式生效。",
      "kind": "fact",
      "claimIds": ["c1", "c2"],
      "anchors": [
        { "start": 8, "length": 8, "claimId": "c1" },
        { "start": 17, "length": 8, "claimId": "c2" }
      ]
    },
    {
      "id": "s3",
      "text": "这次将释放长期资金约 1 万亿元。",
      "kind": "fact",
      "claimIds": ["c1"],
      "anchors": [{ "start": 8, "length": 6, "claimId": "c1" }]
    },
    {
      "id": "s4",
      "text": "有机构测算，这可能让按揭利率再降10 个基点。",
      "kind": "fact",
      "claimIds": ["c3"],
      "anchors": [{ "start": 16, "length": 6, "claimId": "c3" }]
    },
    { "id": "s5", "text": "我的判断是，这一轮宽松还没到头。", "kind": "opinion", "claimIds": [], "anchors": [] }
  ],
  "claims": {
    "c1": {
      "id": "c1",
      "independence": 3,
      "mergedAwayCount": 6,
      "sources": [
        { "publisher": "中国人民银行", "note": "公告原文", "time": "15:02" },
        { "publisher": "新华社", "note": "「释放长期资金约1万亿」", "time": "15:20" },
        { "publisher": "财新网", "note": "独立测算，口径一致", "time": "16:41" }
      ]
    },
    "c2": {
      "id": "c2",
      "independence": 3,
      "mergedAwayCount": 2,
      "sources": [
        { "publisher": "中国人民银行", "note": "公告原文", "time": "15:02" },
        { "publisher": "新华社", "note": "「自3月15日起执行」", "time": "15:20" },
        { "publisher": "第一财经", "note": "生效日一致", "time": "16:05" }
      ]
    },
    "c3": {
      "id": "c3",
      "independence": 1,
      "mergedAwayCount": 0,
      "sources": [{ "publisher": "某券商研报", "note": "「或再降10个基点」", "time": "17:30" }]
    }
  },
  "stages": [
    { "name": "抓取原文",   "state": "done",    "count": "1 篇",           "detail": null },
    { "name": "扩展检索",   "state": "done",    "count": "14 篇",          "detail": null },
    { "name": "抽取事实点", "state": "done",    "count": "86 条",          "detail": null },
    { "name": "归并去重",   "state": "done",    "count": "23 点 · 7 独立源", "detail": null },
    { "name": "交叉验证",   "state": "running", "count": "9 / 23",
      "detail": "「降准释放长期资金约 1 万亿元」——3 个独立信源对上了" },
    { "name": "选点",       "state": "pending", "count": null, "detail": null },
    { "name": "成稿",       "state": "pending", "count": null, "detail": null },
    { "name": "挂信源",     "state": "pending", "count": null, "detail": null },
    { "name": "时长与气口", "state": "pending", "count": null, "detail": null }
  ],
  "budget": {
    "used": 48240,
    "budgeted": 120000,
    "remainingThisMonth": 2410000,
    "costCents": 14,
    "byStage": { "抓取原文": 40, "扩展检索": 3900, "抽取事实点": 38100, "成稿": 6200 }
  },
  "insufficientReason": null
}
```

- [ ] **Step 3: 写测试**

```swift
// ios/EngineHarness/BriefScenarios.swift
import Foundation

// 离线验证七个界面共用的那份数据契约。
//
// 测试台没有 app bundle，所以 fixture 按路径读——路径相对仓库根，
// scripts/test-engines.sh 就是从那里跑起来的。

let fixturePath = "ios/Pollux One/Resources/brief-fixture.json"

@MainActor
func loadFixtureBrief() -> Brief? {
    try? BriefFixture.load(at: fixturePath)
}

@MainActor
func runBriefSuite() -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("Brief fixture — 七个界面共用的数据契约")

    guard let brief = loadFixtureBrief() else {
        report.check(false, "fixture 读得到", detail: fixturePath)
        return (report.pass, report.fail)
    }

    report.section("解码")
    report.check(brief.news.publisher == "财新", "发布方标签", detail: brief.news.publisher)
    report.check(brief.news.title.contains("存款准备金率"), "标题")
    report.check(brief.estimatedSeconds == 83, "83 秒", detail: "\(brief.estimatedSeconds)")
    report.check(brief.status == .ready, "状态是可审稿")

    report.section("五句，类型齐全")
    report.check(brief.sentences.count == 5, "五句", detail: "\(brief.sentences.count)")
    report.check(brief.sentences.first?.kind == .transition, "第一句是钩子")
    report.check(brief.sentences.last?.kind == .opinion, "最后一句是观点")

    report.section("证据锚点落在句内合法区间")
    for sentence in brief.sentences {
        let count = sentence.text.count
        for anchor in sentence.anchors {
            report.check(anchor.start >= 0 && anchor.start + anchor.length <= count,
                         "\(sentence.id) 的锚点不越界",
                         detail: "start=\(anchor.start) len=\(anchor.length) of \(count)")
            report.check(brief.claims[anchor.claimId] != nil,
                         "\(sentence.id) 的锚点指向存在的 claim", detail: anchor.claimId)
        }
    }

    report.section("观点句不冒充有信源")
    if let opinion = brief.sentences.last {
        report.check(opinion.anchors.isEmpty, "观点句没有锚点")
        report.check(opinion.claimIds.isEmpty, "观点句没有 claim")
        report.check(!opinion.canRecheckSources, "观点句不提供重查")
    }

    report.section("独立源数与被归并的转载数是两个字段")
    if let c1 = brief.claims["c1"] {
        report.check(c1.independence == 3, "3 个独立源", detail: "\(c1.independence)")
        report.check(c1.mergedAwayCount == 6, "另有 6 篇转载未计入", detail: "\(c1.mergedAwayCount)")
        report.check(c1.sources.count == c1.independence,
                     "展开列出的行数等于独立源数，不是总篇数", detail: "\(c1.sources.count)")
        report.check(c1.isStrong, "3 个源算站得住")
    }
    if let c3 = brief.claims["c3"] {
        report.check(c3.independence == 1, "弱信源 claim 只有 1 个源")
        report.check(!c3.isStrong, "1 个源不算站得住")
    }

    report.section("九个阶段")
    report.check(brief.stages.count == 9, "九个", detail: "\(brief.stages.count)")
    report.check(brief.stages.first?.name == "抓取原文", "第一个")
    report.check(brief.stages.last?.name == "时长与气口", "最后一个")
    report.check(brief.stages.filter { $0.state == .running }.count == 1,
                 "同时只有一个阶段在跑")
    for stage in brief.stages {
        switch stage.state {
        case .pending:
            // 显示 0 会被读成「挖到了 0 条」。
            report.check(stage.count == nil, "\(stage.name) 未开始，不显示计数")
            report.check(stage.detail == nil, "\(stage.name) 未开始，没有说明")
        case .running:
            report.check(stage.detail != nil, "\(stage.name) 在跑，要有实时说明")
        case .done:
            report.check(stage.count != nil, "\(stage.name) 跑过了，要有计数")
            report.check(!(stage.count ?? "").contains("秒"),
                         "\(stage.name) 的计数不是耗时", detail: stage.count ?? "")
        }
    }

    report.section("token 预算自洽")
    let budget = brief.budget
    report.check(budget.used == 48_240, "已用", detail: "\(budget.used)")
    report.check(budget.used < budget.budgeted, "已用不超预算")
    report.check(budget.byStage.values.reduce(0, +) == budget.used,
                 "分阶段之和等于总数，否则进度条在撒谎",
                 detail: "\(budget.byStage.values.reduce(0, +)) vs \(budget.used)")

    report.section("进度条分段")
    let bar = TokenBar(budget)
    let total = bar.segments.map(\.fraction).reduce(0, +)
    report.check(abs(total - budget.fractionUsed) < 0.0001,
                 "各段之和等于已用比例", detail: "\(total) vs \(budget.fractionUsed)")

    report.section("信源文案")
    if let c1 = brief.claims["c1"] {
        let label = EvidenceLabel(c1)
        report.check(label.text.contains("独立信源"), "说「独立信源」", detail: label.text)
        report.check(!label.text.contains("篇"), "不说「篇」——会引向把转载加进去")
        report.check(!label.isWarning, "3 个源不是警告")
    }
    if let c3 = brief.claims["c3"] {
        let label = EvidenceLabel(c3)
        report.check(label.text.contains("仅"), "1 个源是警告口吻", detail: label.text)
        report.check(label.isWarning, "标成警告")
    }
    report.check(EvidenceFooter(mergedAwayCount: 6).text != nil, "有转载就说明")
    report.check(EvidenceFooter(mergedAwayCount: 0).text == nil, "没转载就整行消失")

    return (report.pass, report.fail)
}
```

- [ ] **Step 4: 把新文件接进测试台**

在 `scripts/test-engines.sh` 的 `swiftc` 列表里，`$IOS/Domain/TakeArchive.swift` 之后加：

```bash
  "$IOS/Domain/Brief/BriefModels.swift" \
  "$IOS/Domain/Brief/Evidence.swift" \
  "$IOS/Domain/Brief/BriefStage.swift" \
  "$IOS/Domain/Brief/BriefFixture.swift" \
```

在 `ios/EngineHarness/main.swift` 里加：

```swift
let brief = runBriefSuite()
```

并把 `brief.pass` / `brief.fail` 加进那两行求和。同时在 `swiftc` 的 harness 文件列表里 `PacingScenarios.swift` 之后加 `ios/EngineHarness/BriefScenarios.swift \`。

- [ ] **Step 5: 跑到绿**

Run: `bash scripts/test-engines.sh`
Expected: 总数从 235 上升，`0 failed`

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Domain/Brief/" "ios/Pollux One/Resources/brief-fixture.json" ios/EngineHarness/BriefScenarios.swift ios/EngineHarness/main.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
Give the screens a contract before giving them data

Every field is read off the finished mock; nothing is invented, because a
field with no pixel behind it is a product guess. Three of them have no
producer yet and that is the point of building the UI first — the in-
sentence anchors, the count of reposts merged away, and the token budget
all have to come from somewhere later.

Independence and mergedAwayCount stay separate fields: adding them is
exactly the misreading the independence calculation exists to prevent, and
two fields make that sum impossible to write by accident. The same reason
EvidenceLabel says "独立信源" and never "篇".

Anchors index Characters rather than UTF-16 units — the difference is
invisible in Latin and puts every Chinese underline in the wrong place.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 把 `SessionManager` 提到 `RecordingView` 之上

**Files:**
- Modify: `ios/Pollux One/App/AppEnvironment.swift`
- Modify: `ios/Pollux One/Features/Recording/RecordingView.swift:50-58`

spec §12 指名这是第二段的第一件事。**真正的毛病见 §0.2**：`RecordingView.init` 每次构造都造一个新 `SessionManager` → 新 `CameraEngine` → 取景器黑一下。

这个任务没有可离线测的纯逻辑（它全是构造时机），验收靠编译 + 真机。

- [ ] **Step 1: 让 `AppEnvironment` 持有会话**

```swift
// 加进 ios/Pollux One/App/AppEnvironment.swift 的属性区
    /// 相机会话是 app 级的，不属于任何一篇稿。
    ///
    /// 之前它在 RecordingView.init 里造：换一篇稿 = 新的 View = 新的
    /// SessionManager = 新的 CameraEngine，用户会看到取景器黑一下重启。
    /// 引擎层本来就支持换稿（prepare(script:) 内部就是 teleprompterEngine.load
    /// + alignmentEngine.reset），错的一直是构造时机，不是能力。
    let sessionManager: SessionManager
```

在 `init(backend:)` 里，`takeArchiver` 之后加：

```swift
        let archiver = TakeArchiver(library: PhotoLibraryService())
        self.takeArchiver = archiver
        self.sessionManager = SessionManager(
            syncService: self.syncService,
            alignmentEngine: SlidingWindowAlignmentEngine(),
            takeArchiver: archiver
        )
```

（原来那行 `self.takeArchiver = TakeArchiver(library: PhotoLibraryService())` 换成上面三行，因为 `sessionManager` 要用同一个 archiver 实例。）

- [ ] **Step 2: 让 `RecordingView` 订阅而不是构造**

把 `RecordingView.swift:50-58` 的 init 整段替换为：

```swift
    init(script: Script?, sessionManager: SessionManager) {
        self.script = script
        _viewModel = State(initialValue: RecordingViewModel(sessionManager: sessionManager))
    }
```

并把第 14 行 `let script: Script` 改成：

```swift
    /// 可选：相机是根视图，开机时通常没有稿。提词块整块随它隐藏。
    let script: Script?
```

- [ ] **Step 3: 编译**

Run: `cd ios && xcodebuild -project "Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: 报出所有 `script` 被当成非可选用的地方（提词器相关），逐个用 `if let` 或 `??` 收掉，直到 `BUILD SUCCEEDED`

- [ ] **Step 4: 引擎测试不能退步**

Run: `bash scripts/test-engines.sh`
Expected: 与 Task 1 结束时同样的通过数，`0 failed`

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/App/AppEnvironment.swift" "ios/Pollux One/Features/Recording/RecordingView.swift"
git commit -m "$(cat <<'EOF'
Stop rebuilding the camera every time a different script opens

Building SessionManager inside RecordingView.init meant the capture session
was a property of whichever script the view was constructed with: opening
another one made a new manager, which made a new CameraEngine, which
blacked out the viewfinder. The engines already supported swapping scripts
— prepare(script:) just reloads the teleprompter and resets alignment — so
what was wrong was where the object got built, not what it could do.

This lands before any new screen, because a camera that belongs to a script
cannot be the root of an app whose README opens with "camera first".

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 相机变根视图

**Files:**
- Modify: `ios/Pollux One/App/RootView.swift:9-12`

- [ ] **Step 1: 改挂载**

把 `RootView.swift` 第 9–12 行替换为：

```swift
                RecordingView(
                    script: environment.sessionManager.scriptRevision?.script,
                    sessionManager: environment.sessionManager
                )
```

- [ ] **Step 2: 编译并在模拟器上确认相机层出现**

Run: `cd ios && xcodebuild -project "Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: 提交**

```bash
git add "ios/Pollux One/App/RootView.swift"
git commit -m "$(cat <<'EOF'
Put the camera at the root

RootView mounted the script list, which is the opposite of the first line
of the README. With the session lifted out of the view and script made
optional, the camera can now be what opens — including on a fresh launch
where there is no script at all.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 相机右下角那格

**Files:**
- Create: `ios/Pollux One/Domain/Brief/ScriptSlot.swift`
- Create: `ios/Pollux One/Features/Recording/ScriptSlotView.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`, `scripts/test-engines.sh`

spec §9.2 ②：有稿 → 当前稿件详情；无稿 → 直接去「交给我」。这是整个新流程的唯一入口。

- [ ] **Step 1: 写纯判断类型**

```swift
// ios/Pollux One/Domain/Brief/ScriptSlot.swift
import Foundation

enum BriefScreen: String, Equatable {
    case camera, handOff, confirm, progress, review, insufficient, scripts
}

/// 相机右下角那一格。它是整个新流程的唯一入口，所以"去哪"这件事
/// 单独做成纯函数，四个状态各自可测，不必起一个界面。
struct ScriptSlot: Equatable {
    let destination: BriefScreen
    let caption: String

    init(brief: Brief?) {
        guard let brief else {
            destination = .handOff
            caption = "交给我"
            return
        }
        switch brief.status {
        case .researching:
            // 在跑的时候回等待页，不是审稿页：还没有东西可审，
            // 把人送进一个空的审稿页会让五分钟的等待读起来像失败。
            destination = .progress
            caption = "调研中"
        case .insufficient:
            destination = .insufficient
            caption = "信源不足"
        case .ready:
            destination = .review
            caption = "\(brief.estimatedSeconds) 秒"
        }
    }
}
```

- [ ] **Step 2: 写测试**

在 `BriefScenarios.swift` 的 `runBriefSuite()` 里，`return` 之前加：

```swift
    report.section("相机右下角那格")
    report.check(ScriptSlot(brief: nil).destination == .handOff,
                 "无稿直接去「交给我」")
    report.check(ScriptSlot(brief: brief).destination == .review,
                 "有可审的稿去审稿页")
    report.check(ScriptSlot(brief: brief).caption.contains("83"),
                 "有稿时显示秒数", detail: ScriptSlot(brief: brief).caption)

    var running = brief
    running.status = .researching
    report.check(ScriptSlot(brief: running).destination == .progress,
                 "在跑时回等待页，而不是进一个空的审稿页")

    var short = brief
    short.status = .insufficient
    report.check(ScriptSlot(brief: short).destination == .insufficient,
                 "信源不足时去「不建议播」")
```

- [ ] **Step 3: 接进测试台**

`scripts/test-engines.sh` 里加 `"$IOS/Domain/Brief/ScriptSlot.swift" \`

- [ ] **Step 4: 写 View**

```swift
// ios/Pollux One/Features/Recording/ScriptSlotView.swift
import SwiftUI

/// 相机 HUD 右下角那一格。判断全在 ScriptSlot 里，这里只负责画。
struct ScriptSlotView: View {
    let slot: ScriptSlot
    let onTap: (BriefScreen) -> Void

    var body: some View {
        Button {
            onTap(slot.destination)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: slot.destination == .handOff ? "plus" : "doc.text")
                    .font(.system(size: 17, weight: .medium))
                Text(slot.caption)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 13))
        }
        .accessibilityLabel(slot.caption)
    }
}
```

把它挂进 `RecordingView` 的底部控件行。

- [ ] **Step 5: 跑到绿并提交**

Run: `bash scripts/test-engines.sh && cd ios && xcodebuild -project "Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|BUILD"`

```bash
git add "ios/Pollux One/Domain/Brief/ScriptSlot.swift" "ios/Pollux One/Features/Recording/ScriptSlotView.swift" ios/EngineHarness/BriefScenarios.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
Make one corner of the camera the only door into the new flow

Destination is a pure function of brief state, so all four cases are
testable without a screen. A running brief goes back to progress rather
than review: there is nothing to review yet, and landing someone in an
empty review page is how a five-minute wait reads as a failure.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: 删句与孤儿证据清理

**Files:**
- Create: `ios/Pollux One/Domain/Brief/BriefEdits.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`, `scripts/test-engines.sh`

- [ ] **Step 1: 写实现**

```swift
// ios/Pollux One/Domain/Brief/BriefEdits.swift
import Foundation

extension Brief {
    /// 删一句，并清掉因此没人再用的证据。
    ///
    /// 孤儿证据不是无害的：它留在字典里，下一句恰好引到同一个 id 时
    /// 会显示别人的信源。清理是有条件的——两句合法地共用一条 claim 很常见。
    func deletingSentence(_ sentenceId: String) -> Brief {
        var copy = self
        guard let removed = sentences.first(where: { $0.id == sentenceId }) else { return copy }
        copy.sentences.removeAll { $0.id == sentenceId }

        for claimId in removed.claimIds {
            let stillUsed = copy.sentences.contains { $0.claimIds.contains(claimId) }
            if !stillUsed { copy.claims.removeValue(forKey: claimId) }
        }

        // 删光了就降级。留一个空稿却仍标成 ready，是在假装它还能播。
        if copy.sentences.isEmpty {
            copy.status = .insufficient
        }
        return copy
    }
}
```

- [ ] **Step 2: 写测试**

在 `runBriefSuite()` 里加：

```swift
    report.section("删句与孤儿证据")
    // s4 是唯一引用 c3 的句子。
    let afterS4 = brief.deletingSentence("s4")
    report.check(afterS4.sentences.count == brief.sentences.count - 1, "少一句")
    report.check(!afterS4.sentences.contains { $0.id == "s4" }, "那句没了")
    report.check(afterS4.claims["c3"] == nil, "没人用的 claim 被清掉")

    // s2 和 s3 共用 c1。
    let afterS3 = brief.deletingSentence("s3")
    report.check(afterS3.claims["c1"] != nil, "还有别的句子在用，不能清")

    var emptied = brief
    for sentence in brief.sentences { emptied = emptied.deletingSentence(sentence.id) }
    report.check(emptied.sentences.isEmpty, "删光了")
    report.check(emptied.status == .insufficient,
                 "空稿降级为不建议播，而不是留一个看起来还能播的空壳")

    report.check(brief.deletingSentence("no-such-id").sentences.count == brief.sentences.count,
                 "删一个不存在的 id 不改变任何东西")
```

- [ ] **Step 3: 接进测试台、跑绿、提交**

`scripts/test-engines.sh` 加 `"$IOS/Domain/Brief/BriefEdits.swift" \`

```bash
git add "ios/Pollux One/Domain/Brief/BriefEdits.swift" ios/EngineHarness/BriefScenarios.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
Clean up the evidence when a sentence goes away

An orphaned claim is not inert: it stays in the dictionary and the next
sentence that references that id shows someone else's sources. Cleanup is
conditional on nothing else using the claim, because two sentences sharing
one is normal.

Deleting the last sentence drops the brief to insufficient rather than
leaving an empty script still labelled ready.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: ② 句子着色与顶部三个计数

**Files:**
- Create: `ios/Pollux One/Domain/Brief/SentenceStyle.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`, `scripts/test-engines.sh`

mock 的规则（`project/Review.dc.html`）：

| 句子 | 左边线 | 线型 |
|---|---|---|
| transition | `#3A362F` | 实线 |
| fact · 独立源 ≥ 3 | `#6FA292` 绿 | 实线 |
| fact · 独立源 < 3 | `#D9A441` 黄 | 实线 |
| opinion | `#3A362F` | **虚线** |

- [ ] **Step 1: 写实现**

```swift
// ios/Pollux One/Domain/Brief/SentenceStyle.swift
import Foundation

/// 不是 Color——测试台不链接 SwiftUI。View 层把它翻成颜色。
enum SentenceAccent: String, Equatable {
    case strong    // 绿：站得住
    case weak      // 黄：这是警告，不是装饰
    case neutral   // 灰：钩子句和观点句
}

struct SentenceStyle: Equatable {
    let accent: SentenceAccent
    let isDashed: Bool

    init(kind: SentenceKind, independence: Int) {
        switch kind {
        case .fact:
            // 黄色是「只有一个人这么说」的警告。
            accent = independence >= ClaimEvidence.strongThreshold ? .strong : .weak
            isDashed = false
        case .opinion:
            // 观点句永远不着有信源的颜色。把个人判断染成和三源互证同一个绿，
            // 是这一屏唯一不能犯的视觉谎言。
            accent = .neutral
            isDashed = true
        case .transition:
            accent = .neutral
            isDashed = false
        }
    }

    /// 从整条 brief 取该句最弱的那个 claim 来定色——一句话挂多个 claim 时，
    /// 最弱的那个才是这句话真正的强度。
    init(sentence: BriefSentence, claims: [String: ClaimEvidence]) {
        let independences = sentence.claimIds.compactMap { claims[$0]?.independence }
        self.init(kind: sentence.kind, independence: independences.min() ?? 0)
    }
}

/// mock 顶部那三个 pill。
struct SentenceCounts: Equatable {
    let strong: Int
    let weak: Int
    let unsourced: Int

    init(_ sentences: [BriefSentence], claims: [String: ClaimEvidence]) {
        var strong = 0, weak = 0, unsourced = 0
        for sentence in sentences {
            switch SentenceStyle(sentence: sentence, claims: claims).accent {
            case .strong: strong += 1
            case .weak: weak += 1
            case .neutral: unsourced += 1
            }
        }
        self.strong = strong
        self.weak = weak
        self.unsourced = unsourced
    }
}
```

- [ ] **Step 2: 写测试**

```swift
    report.section("句子着色")
    report.check(SentenceStyle(kind: .fact, independence: 4).accent == .strong, "4 个源是绿的")
    report.check(SentenceStyle(kind: .fact, independence: 3).accent == .strong, "3 个源到线")
    report.check(SentenceStyle(kind: .fact, independence: 1).accent == .weak, "1 个源是警告色")
    report.check(!SentenceStyle(kind: .fact, independence: 4).isDashed, "事实句是实线")

    let opinionStyle = SentenceStyle(kind: .opinion, independence: 9)
    report.check(opinionStyle.accent == .neutral,
                 "观点句永远不着有信源的颜色，哪怕传进来一个大数")
    report.check(opinionStyle.isDashed, "观点句是虚线")
    report.check(SentenceStyle(kind: .transition, independence: 0).accent == .neutral,
                 "钩子句中性")
    report.check(!SentenceStyle(kind: .transition, independence: 0).isDashed, "钩子句实线")

    // s2 挂 c1(3) 和 c2(3)，取最弱 = 3 → strong
    report.check(SentenceStyle(sentence: brief.sentences[1], claims: brief.claims).accent == .strong,
                 "多 claim 的句子按最弱的那个定色")

    report.section("顶部三个 pill")
    let counts = SentenceCounts(brief.sentences, claims: brief.claims)
    report.check(counts.strong == 2, "绿：s2 s3", detail: "\(counts.strong)")
    report.check(counts.weak == 1, "黄：s4", detail: "\(counts.weak)")
    report.check(counts.unsourced == 2, "灰：s1 s5", detail: "\(counts.unsourced)")
    report.check(counts.strong + counts.weak + counts.unsourced == brief.sentences.count,
                 "三个数加起来等于句数，不重不漏")
```

- [ ] **Step 3: 接进测试台、跑绿、提交**

`scripts/test-engines.sh` 加 `"$IOS/Domain/Brief/SentenceStyle.swift" \`

```bash
git add "ios/Pollux One/Domain/Brief/SentenceStyle.swift" ios/EngineHarness/BriefScenarios.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
Colour a sentence by how well it is sourced, not by how it reads

The amber on a single-source fact is a warning, so an opinion sentence can
never take a sourced colour no matter what is passed in — dressing a
judgment in the same green as three corroborated outlets is the one visual
lie this screen must not tell.

A sentence carrying several claims takes the colour of its weakest one: the
claim most likely to be wrong is what the sentence actually rests on.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: ② 句内证据锚点

**Files:**
- Create: `ios/Pollux One/Domain/Brief/AnchorRuns.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`, `scripts/test-engines.sh`

锚点错位会让用户点开看到对不上的信源——**比不显示更糟**。

- [ ] **Step 1: 写实现**

```swift
// ios/Pollux One/Domain/Brief/AnchorRuns.swift
import Foundation

/// 把一句话按锚点切成若干段，带标记的段画虚线下划线。
///
/// 越界或重叠一律**整句降级**为一段无标记文本，而不是夹逼成一个看似合理的
/// 区间：两者都说明上游算错了，夹逼会把错误藏起来。
struct AnchorRuns: Equatable {
    struct Segment: Equatable {
        let text: String
        /// nil = 普通文字。
        let claimId: String?
    }

    let segments: [Segment]
    let isDegraded: Bool

    init(_ sentence: BriefSentence) {
        let chars = Array(sentence.text)
        let sorted = sentence.anchors.sorted { $0.start < $1.start }

        var valid = true
        var cursor = 0
        for anchor in sorted {
            if anchor.start < cursor { valid = false; break }          // 重叠
            if anchor.length <= 0 { valid = false; break }             // 空锚点
            if anchor.start + anchor.length > chars.count { valid = false; break } // 越界
            cursor = anchor.start + anchor.length
        }

        guard valid else {
            segments = [Segment(text: sentence.text, claimId: nil)]
            isDegraded = true
            return
        }

        var out: [Segment] = []
        var index = 0
        for anchor in sorted {
            if anchor.start > index {
                out.append(Segment(text: String(chars[index ..< anchor.start]), claimId: nil))
            }
            let end = anchor.start + anchor.length
            out.append(Segment(text: String(chars[anchor.start ..< end]), claimId: anchor.claimId))
            index = end
        }
        if index < chars.count {
            out.append(Segment(text: String(chars[index...]), claimId: nil))
        }

        segments = out.isEmpty ? [Segment(text: sentence.text, claimId: nil)] : out
        isDegraded = false
    }
}
```

- [ ] **Step 2: 写测试**

```swift
    report.section("句内证据锚点")
    let s2 = brief.sentences[1]
    let runs = AnchorRuns(s2)
    report.check(!runs.isDegraded, "正常句子不降级")
    report.check(runs.segments.map(\.text).joined() == s2.text,
                 "拼回去与原句逐字相同——切分不许丢字或重复")
    let marked = runs.segments.compactMap { $0.claimId == nil ? nil : $0.text }
    report.check(marked.contains("0.5 个百分点"), "第一个锚点切出的就是那几个字",
                 detail: marked.joined(separator: " / "))
    report.check(marked.contains("3 月 15 日"), "第二个锚点")

    let tooLong = BriefSentence(id: "x", text: "短句。", kind: .fact,
                                claimIds: ["c1"],
                                anchors: [EvidenceAnchor(start: 2, length: 99, claimId: "c1")])
    report.check(AnchorRuns(tooLong).isDegraded, "越界必须整句降级")
    report.check(AnchorRuns(tooLong).segments.count == 1, "降级后退回一整段无标记文本")

    let overlapping = BriefSentence(id: "y", text: "一二三四五六七八。", kind: .fact,
                                    claimIds: ["c1"],
                                    anchors: [EvidenceAnchor(start: 0, length: 4, claimId: "c1"),
                                              EvidenceAnchor(start: 2, length: 4, claimId: "c1")])
    report.check(AnchorRuns(overlapping).isDegraded, "重叠必须降级——重叠说明上游算错了")

    let noAnchors = BriefSentence(id: "z", text: "没有锚点。", kind: .transition,
                                  claimIds: [], anchors: [])
    report.check(!AnchorRuns(noAnchors).isDegraded, "没有锚点不算降级")
    report.check(AnchorRuns(noAnchors).segments.count == 1, "整句一段")
```

- [ ] **Step 3: 接进测试台、跑绿、提交**

`scripts/test-engines.sh` 加 `"$IOS/Domain/Brief/AnchorRuns.swift" \`

```bash
git add "ios/Pollux One/Domain/Brief/AnchorRuns.swift" ios/EngineHarness/BriefScenarios.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
Underline exactly the characters the evidence covers, or none of them

An anchor landing two characters off points the reader at a number whose
sources say something else — worse than no underline at all. Out-of-range
and overlapping anchors both degrade the whole sentence to plain text
rather than being clamped into something plausible, because both mean the
producer upstream got it wrong and clamping hides that.

The reassembly check is the one that matters: segments joined back together
must equal the original sentence character for character, so no slicing bug
can silently drop or duplicate text.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: ② 审稿页与信源展开

**Files:**
- Create: `ios/Pollux One/Features/Brief/ReviewView.swift`, `SentenceRow.swift`, `EvidenceSheet.swift`

判断逻辑（`SentenceStyle` `AnchorRuns` `EvidenceLabel` `EvidenceFooter`）已在 Task 1/6/7 测过，这里只画。

- [ ] **Step 1: 写 SentenceRow**

```swift
// ios/Pollux One/Features/Brief/SentenceRow.swift
import SwiftUI

extension SentenceAccent {
    var color: Color {
        switch self {
        case .strong: Color(red: 0.435, green: 0.635, blue: 0.573)   // #6FA292
        case .weak:   Color(red: 0.851, green: 0.643, blue: 0.255)   // #D9A441
        case .neutral: Color(red: 0.227, green: 0.212, blue: 0.184)  // #3A362F
        }
    }
}

struct SentenceRow: View {
    let sentence: BriefSentence
    let claims: [String: ClaimEvidence]
    @State private var isExpanded = false

    private var style: SentenceStyle { SentenceStyle(sentence: sentence, claims: claims) }
    private var runs: AnchorRuns { AnchorRuns(sentence) }
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
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 24)
    }

    private var accentBar: some View {
        Rectangle()
            .fill(style.accent.color)
            .frame(width: 2)
            .opacity(style.isDashed ? 0.5 : 1)
    }

    /// 锚点段落拼成一行富文本。降级时 runs 只有一段，于是自然退回纯文本。
    private var text: some View {
        runs.segments.reduce(Text("")) { acc, segment in
            var piece = Text(segment.text)
            if segment.claimId != nil {
                piece = piece.underline(true, pattern: .dot, color: style.accent.color)
            }
            return acc + piece
        }
        .font(.system(size: 16.5))
        .italic(sentence.kind == .opinion)
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
                Text(label.text).font(.system(size: 11.5, design: .monospaced))
            }
            .foregroundStyle(style.accent.color)
        }
    }
}
```

- [ ] **Step 2: 写 EvidenceSheet**

```swift
// ios/Pollux One/Features/Brief/EvidenceSheet.swift
import SwiftUI

/// 展开后每源一行：发布方 · 引文或说明 · 时间。
/// 行数等于独立源数，**不等于**总篇数——被归并的转载只在末行以数字出现。
struct EvidenceSheet: View {
    let claim: ClaimEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(claim.sources) { source in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(source.publisher)
                        .font(.system(size: 12))
                        .frame(minWidth: 62, alignment: .leading)
                    Text(source.note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(source.time)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            if let footer = EvidenceFooter(mergedAwayCount: claim.mergedAwayCount).text {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 3)
    }
}
```

- [ ] **Step 3: 写 ReviewView**

```swift
// ios/Pollux One/Features/Brief/ReviewView.swift
import SwiftUI

/// ② 当前稿件详情 = 审稿。spec §9.2 ②：一个 View 两个入口
/// （相机进 / 调研完成落回），不是两屏。
struct ReviewView: View {
    @State var brief: Brief
    let onRecord: () -> Void
    let onSwitchScript: () -> Void

    private var counts: SentenceCounts { SentenceCounts(brief.sentences, claims: brief.claims) }

    var body: some View {
        VStack(spacing: 0) {
            NewsTag(news: brief.news)
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(brief.sentences) { sentence in
                        SwipeableSentenceRow(
                            sentence: sentence,
                            claims: brief.claims,
                            onDelete: { brief = brief.deletingSentence(sentence.id) },
                            onRecheck: { /* 接管线后再实现 */ }
                        )
                    }
                }
            }
            bottomBar
        }
    }

    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(brief.estimatedSeconds)")
                    .font(.system(size: 29, design: .monospaced))
                // pacedToUser 为假时不许写「按你的语速」——spec §9.2 ① 说新用户
                // 的第一篇必然是语种默认值，文案先于数据到场就是在撒谎。
                Text(brief.pacedToUser ? "秒 · 按你的语速" : "秒")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                CountPill(value: counts.strong, accent: .strong)
                CountPill(value: counts.weak, accent: .weak)
                CountPill(value: counts.unsourced, accent: .neutral)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var bottomBar: some View {
        HStack(spacing: 11) {
            Button(action: onSwitchScript) {
                Image(systemName: "arrow.triangle.2.circlepath").frame(width: 54, height: 56)
            }
            .accessibilityLabel("换一篇稿")
            Button(action: onRecord) {
                Label("开拍", systemImage: "video.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
}

struct CountPill: View {
    let value: Int
    let accent: SentenceAccent

    var body: some View {
        Text("\(value)")
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(accent.color.opacity(0.13), in: Capsule())
            .foregroundStyle(accent.color)
    }
}

// NewsTag 不在这里定义 —— Task 12 已经把它提成了独立文件
// `ios/Pollux One/Features/Brief/NewsTag.swift`（BriefProgressView 也要用它）。
// 在这里再写一遍会重复定义、编译失败。直接用即可。
```

- [ ] **Step 4: 编译、提交**

```bash
git add "ios/Pollux One/Features/Brief/"
git commit -m "$(cat <<'EOF'
Show each sentence with the evidence it actually rests on

A sentence carrying several claims expands to its weakest one — that is the
claim the sentence stands or falls on. The expanded list has one row per
independent source, and the reposts that were merged away appear only as a
number on the last line, phrased as excluded, so there is nothing to add up.

"按你的语速" is conditional on pacedToUser. Saying it before the samples
exist would be copy arriving ahead of the data.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: ② 左滑按句子类型分化

> **执行顺序注意（写计划时没看出来的循环依赖）：** Task 8 的 `ReviewView` 引用
> `SwipeableSentenceRow`，而那是本任务造的；本任务又要改 Task 8 才创建的
> `SentenceRow.swift`。两边互相等。
>
> 拆法：**本任务只做 Domain 那一半**——`SwipeActions.swift` + 断言 + 测试台，
> 不碰任何 View。`SwipeableSentenceRow` 连同手势接线归到 Task 8 一起做，
> 那时 `SwipeActions` 已经在了。所以本任务的 Step 3（"在 View 上接手势"）
> **跳过**，Files 里的 `SentenceRow.swift` 一行也不要动。


**Files:**
- Create: `ios/Pollux One/Domain/Brief/SwipeActions.swift`
- Modify: `ios/Pollux One/Features/Brief/SentenceRow.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`, `scripts/test-engines.sh`

spec §8.1：事实句露 `重查 + 删除`（mock 144pt），钩子/观点句只露 `删除`（72pt）。

- [ ] **Step 1: 写实现**

```swift
// ios/Pollux One/Domain/Brief/SwipeActions.swift
import Foundation

enum SwipeAction: String, Equatable {
    case recheck, delete
}

/// spec §8.1：露出的按钮由句子类型决定。观点句没有信源可重查，
/// 给它一个「重查」按钮就是在承诺一个做不到的动作。
/// 这个分化是从 kind 字段长出来的，不是排版决定。
struct SwipeActions: Equatable {
    static let buttonWidth: CGFloat = 72

    let buttons: [SwipeAction]
    var width: CGFloat { CGFloat(buttons.count) * Self.buttonWidth }

    init(for kind: SentenceKind) {
        buttons = kind == .fact ? [.recheck, .delete] : [.delete]
    }
}

/// 一行的滑动状态。过半才吸附，否则弹回。
struct SwipeState: Equatable {
    let width: CGFloat
    private(set) var offset: CGFloat = 0
    private(set) var isOpen = false

    init(width: CGFloat) { self.width = width }

    mutating func drag(to translation: CGFloat) {
        let base = isOpen ? -width : 0
        offset = min(0, max(-width, base + translation))
    }

    mutating func release() {
        isOpen = offset < -width / 2
        offset = isOpen ? -width : 0
    }
}
```

- [ ] **Step 2: 写测试**

```swift
    report.section("左滑按类型分化")
    let factActions = SwipeActions(for: .fact)
    report.check(factActions.buttons == [.recheck, .delete], "事实句露两个")
    report.check(factActions.width == 144, "两个按钮共 144pt", detail: "\(factActions.width)")

    report.check(SwipeActions(for: .opinion).buttons == [.delete],
                 "观点句只露删除——给它重查是在骗人")
    report.check(SwipeActions(for: .opinion).width == 72, "一个按钮 72pt")
    report.check(SwipeActions(for: .transition).buttons == [.delete], "钩子句同样只露删除")

    report.section("滑动吸附")
    var row = SwipeState(width: 144)
    row.drag(to: -50)
    row.release()
    report.check(!row.isOpen, "没过半，弹回")
    report.check(row.offset == 0, "弹回到 0")

    row.drag(to: -100)
    row.release()
    report.check(row.isOpen, "过半，吸附打开")
    report.check(row.offset == -144, "停在按钮宽度上")

    row.drag(to: -9999)
    report.check(row.offset >= -144, "再怎么拉也不超过按钮宽度", detail: "\(row.offset)")
```

- [ ] **Step 3: 在 View 上接手势**

`SentenceRow` 外面包一层 `SwipeableSentenceRow`，用 `DragGesture` 驱动 `SwipeState`，按 `SwipeActions(for: sentence.kind).buttons` 渲染按钮。

- [ ] **Step 4: 接进测试台、跑绿、提交**

`scripts/test-engines.sh` 加 `"$IOS/Domain/Brief/SwipeActions.swift" \`

```bash
git add "ios/Pollux One/Domain/Brief/SwipeActions.swift" "ios/Pollux One/Features/Brief/SentenceRow.swift" ios/EngineHarness/BriefScenarios.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
Offer "recheck sources" only where sources exist

An opinion sentence has nothing to recheck, so the button would promise an
action that cannot do anything. The split falls out of the kind field the
drafting stage already assigns — a consequence of the data model, not a
layout preference.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: ③ 交给我

**Files:**
- Create: `ios/Pollux One/Domain/Brief/HandOffState.swift`, `ios/Pollux One/Features/Brief/HandOffView.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`, `scripts/test-engines.sh`

spec §8 ③：`打字 / 说给我听` 两档。打字档是**一个**输入框（链接与文本合一）；剪贴板检测是输入框上方的快捷条，**未授权则整条不出现**；`上传截图` 与 `分享进来` 并列在下方。

- [ ] **Step 1: 写实现**

```swift
// ios/Pollux One/Domain/Brief/HandOffState.swift
import Foundation

enum HandOffMode: String, Equatable { case typing, speaking }
enum SecondaryEntry: String, Equatable { case screenshot, shareSheet }

struct HandOffState: Equatable {
    var mode: HandOffMode
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

    var canProceed: Bool {
        switch mode {
        case .typing: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .speaking: true
        }
    }
}
```

- [ ] **Step 2: 写测试**

```swift
    report.section("③ 交给我")
    report.check(HandOffState(mode: .typing).inputFieldCount == 1,
                 "链接和正文共用一个框，不是两个")
    report.check(HandOffState(mode: .speaking).inputFieldCount == 0,
                 "语音档没有文字框")

    report.check(!HandOffState(mode: .typing, clipboardAuthorized: false,
                               clipboardHasContent: true).showsClipboardBar,
                 "未授权时整条快捷条不出现，而不是显示一个禁用按钮")
    report.check(!HandOffState(mode: .typing, clipboardAuthorized: true,
                               clipboardHasContent: false).showsClipboardBar,
                 "剪贴板为空时也不出现")
    report.check(HandOffState(mode: .typing, clipboardAuthorized: true,
                              clipboardHasContent: true).showsClipboardBar,
                 "授权且有内容才出现")
    report.check(!HandOffState(mode: .speaking, clipboardAuthorized: true,
                               clipboardHasContent: true).showsClipboardBar,
                 "语音档没有剪贴板条")

    report.check(HandOffState(mode: .typing).secondaryEntries == [.screenshot, .shareSheet],
                 "截图与分享并列——东西都在别处")

    var handOff = HandOffState(mode: .typing)
    report.check(!handOff.canProceed, "空输入不能往下走")
    handOff.text = "   "
    report.check(!handOff.canProceed, "只有空白也不行")
    handOff.text = "https://example.com/news"
    report.check(handOff.canProceed, "有内容才能走")
```

- [ ] **Step 3: 写 View、接进测试台、跑绿、提交**

`scripts/test-engines.sh` 加 `"$IOS/Domain/Brief/HandOffState.swift" \`

```bash
git add "ios/Pollux One/Domain/Brief/HandOffState.swift" "ios/Pollux One/Features/Brief/HandOffView.swift" ios/EngineHarness/BriefScenarios.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
One input box, and a clipboard bar that is absent rather than disabled

A link and a pasted article are the same thing to the pipeline, so two
boxes would ask the user to classify their input for no reason. When the
clipboard is unauthorised or empty the shortcut bar is gone entirely — a
greyed-out control invites a tap and then explains why it cannot work.

Screenshot upload and the share sheet sit together because they are one
idea: the thing is somewhere else.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: ④ 确认 —— 拨盘

**Files:**
- Create: `ios/Pollux One/Domain/Brief/DialState.swift`, `ios/Pollux One/Features/Brief/ConfirmView.swift`, `DialControl.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`, `scripts/test-engines.sh`

spec §2.2：横轴通俗↔专业，纵轴时长（最长 6min），两个锚点 `60s 通俗` / `3min 偏专业`，要有**调相机拨盘的手感**。

- [ ] **Step 1: 写实现**

```swift
// ios/Pollux One/Domain/Brief/DialState.swift
import Foundation

enum DialAnchor: String, Equatable {
    case casualMinute            // 60s 通俗
    case professionalThreeMinutes // 3min 偏专业
}

struct BriefEstimate: Equatable {
    let tokens: Int
    let costCents: Int
}

struct DialState: Equatable {
    /// 档位，不是连续值。段落感正是"拨盘"手感的来源，
    /// 也让成本预估落在有限的已知点上，而不是插值出来的。
    static let durationSteps = [30, 60, 90, 120, 180, 240, 300, 360]
    static let maxDurationSec = 360

    private(set) var durationSec = 60
    private(set) var register = 0.0
    let remainingTokens: Int

    init(remainingTokens: Int = .max) { self.remainingTokens = remainingTokens }

    mutating func setDuration(seconds: Int) {
        let clamped = min(Self.maxDurationSec, max(Self.durationSteps[0], seconds))
        durationSec = Self.durationSteps.min {
            abs($0 - clamped) < abs($1 - clamped)
        } ?? Self.durationSteps[0]
    }

    mutating func setRegister(_ value: Double) {
        register = min(1.0, max(0.0, value))
    }

    mutating func snap(to anchor: DialAnchor) {
        switch anchor {
        case .casualMinute:
            durationSec = 60
            register = 0.0
        case .professionalThreeMinutes:
            durationSec = 180
            register = 0.7
        }
    }

    /// 与 pipeline 的 ESTIMATE_COEFFICIENTS 是**两套数**，接上管线后必须统一。
    /// 现在只保证单调：时长越长越贵、越专业越贵。
    var estimate: BriefEstimate {
        let base = 20_000
        let perSecond = 380
        let registerMultiplier = 1.0 + register * 0.35
        let tokens = Int(Double(base + perSecond * durationSec) * registerMultiplier)
        return BriefEstimate(tokens: tokens, costCents: max(1, tokens / 3_400))
    }

    /// 余额门禁放在这一屏，因为这是**烧 token 之前的最后一屏**。
    /// spec §11 点名：跑完才发现余额不够是不能接受的。
    var canAfford: Bool { estimate.tokens <= remainingTokens }

    var blockReason: String? {
        canAfford ? nil
            : "这一篇大约要 \(estimate.tokens / 1000)K token，你只剩 \(remainingTokens / 1000)K"
    }
}
```

- [ ] **Step 2: 写测试**

```swift
    report.section("④ 拨盘")
    var dial = DialState()
    dial.setDuration(seconds: 9999)
    report.check(dial.durationSec == 360, "时长封顶 6 分钟", detail: "\(dial.durationSec)")
    dial.setDuration(seconds: 1)
    report.check(dial.durationSec == 30, "下限 30 秒")

    dial.setDuration(seconds: 71)
    report.check(DialState.durationSteps.contains(dial.durationSec),
                 "落在档位上——拨盘要有段落感", detail: "\(dial.durationSec)")
    report.check(dial.durationSec == 60, "71 秒吸到最近的 60")

    dial.setRegister(2.0)
    report.check(dial.register == 1.0, "调性上界")
    dial.setRegister(-1.0)
    report.check(dial.register == 0.0, "调性下界")

    dial.snap(to: .casualMinute)
    report.check(dial.durationSec == 60 && dial.register == 0.0, "锚点一：60s 通俗")
    let cheap = dial.estimate.tokens
    dial.snap(to: .professionalThreeMinutes)
    report.check(dial.durationSec == 180 && dial.register > 0.5, "锚点二：3min 偏专业")
    report.check(dial.estimate.tokens > cheap, "3 分钟比 1 分钟贵",
                 detail: "\(cheap) → \(dial.estimate.tokens)")

    var plain = DialState(); plain.setDuration(seconds: 180); plain.setRegister(0.0)
    var pro = DialState(); pro.setDuration(seconds: 180); pro.setRegister(1.0)
    report.check(pro.estimate.tokens > plain.estimate.tokens, "同样时长，越专业越贵")

    report.section("余额门禁")
    var broke = DialState(remainingTokens: 1000)
    broke.snap(to: .professionalThreeMinutes)
    report.check(!broke.canAfford, "余额不足必须在花钱之前拦住")
    report.check(broke.blockReason != nil, "要说清为什么")
    var rich = DialState(remainingTokens: 10_000_000)
    rich.snap(to: .professionalThreeMinutes)
    report.check(rich.canAfford && rich.blockReason == nil, "余额够就放行")
```

- [ ] **Step 3: 写 DialControl**

一个二维拖拽区：纵轴映射 `setDuration`，横轴映射 `setRegister`，两个锚点做成可点的圆点，拖到档位时给 `UIImpactFeedbackGenerator(style: .light)` 一下——段落感靠触觉落地。

- [ ] **Step 4: 接进测试台、跑绿、提交**

`scripts/test-engines.sh` 加 `"$IOS/Domain/Brief/DialState.swift" \`

```bash
git add "ios/Pollux One/Domain/Brief/DialState.swift" "ios/Pollux One/Features/Brief/ConfirmView.swift" "ios/Pollux One/Features/Brief/DialControl.swift" ios/EngineHarness/BriefScenarios.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
Make the dial notch, and stop a run that cannot be paid for

Duration snaps to steps instead of sliding continuously — that is where the
camera-dial feel comes from, and it keeps the cost estimate on a small set
of known points rather than interpolated between them. The two anchors are
one tap because they are the two settings we intend to judge script quality
at.

The affordability check belongs on this screen because it is the last one
before tokens start burning. Finding out afterwards is the failure the spec
names outright.

The estimate here and the pipeline's coefficients are two separate sets of
numbers today; they have to be reconciled when the pipeline lands.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: ⑤ 等待

**Files:**
- Create: `ios/Pollux One/Features/Brief/BriefProgressView.swift`

`TokenBar` 与阶段断言已在 Task 1 测过，这里画。

- [ ] **Step 1: 写 View**

```swift
// ios/Pollux One/Features/Brief/BriefProgressView.swift
import SwiftUI

/// ⑤ 等待。上半 1/3 是 token 表——spec §10.1 说 token 是一等产品对象，
/// 它在这里第一次对用户可见。
struct BriefProgressView: View {
    let brief: Brief
    let elapsed: String
    let onLeave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NewsTag(news: brief.news)
                Text(elapsed).font(.system(size: 14, design: .monospaced))
            }
            tokenPanel
            stageList
            Spacer(minLength: 0)
            bottomActions
        }
    }

    private var tokenPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(brief.budget.used, format: .number)
                    .font(.system(size: 40, design: .monospaced))
                Text("tokens").font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
                Text("¥\(Double(brief.budget.costCents) / 100, specifier: "%.2f")")
                    .font(.system(size: 17, design: .monospaced))
            }
            segmentedBar
            legend
            Divider()
            HStack {
                Text("预算 \(brief.budget.budgeted / 1000)K · 已用 \(Int(brief.budget.fractionUsed * 100))%")
                Spacer()
                Text("本月余额 \(String(format: "%.2f", Double(brief.budget.remainingThisMonth) / 1_000_000))M")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
    }

    private var segmentedBar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(TokenBar(brief.budget).segments.enumerated()), id: \.offset) { index, segment in
                    Rectangle()
                        .fill(Color.accentColor.opacity(1.0 - Double(index) * 0.25))
                        .frame(width: geo.size.width * segment.fraction)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 11)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
    }

    private var legend: some View {
        HStack(spacing: 13) {
            ForEach(Array(TokenBar(brief.budget).segments.enumerated()), id: \.offset) { index, segment in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(1.0 - Double(index) * 0.25))
                        .frame(width: 7, height: 7)
                    Text(segment.stage).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stageList: some View {
        VStack(spacing: 0) {
            ForEach(brief.stages) { stage in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 13) {
                        stageIcon(stage.state)
                        Text(stage.name)
                            .font(.system(size: 14))
                            .foregroundStyle(stage.state == .pending ? .tertiary : .secondary)
                        Spacer()
                        // 未开始的阶段不显示计数。0 读起来像「挖到了 0 条」。
                        if let count = stage.count {
                            Text(count).font(.system(size: 11.5, design: .monospaced))
                        }
                    }
                    if let detail = stage.detail {
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 29)
                    }
                }
                .padding(.vertical, 9)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    @ViewBuilder
    private func stageIcon(_ state: StageState) -> some View {
        switch state {
        case .done:    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
        case .running: ProgressView().controlSize(.small)
        case .pending: Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 16, height: 16)
        }
    }

    private var bottomActions: some View {
        VStack(spacing: 13) {
            // spec §8.2：②→③ 是不可逆边界，所以这里的返回是「离开」。
            // 随手一按不该毁掉一个已经花了钱的任务。
            Button("退出，好了通知我", action: onLeave)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.tertiary))
            // 真正的取消是另一个动作，很轻，并且明说不退。
            Button("取消调研 · 已消耗的 \(brief.budget.used / 1000)K 不退", action: onCancel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
}
```

- [ ] **Step 2: 编译、提交**

```bash
git add "ios/Pollux One/Features/Brief/BriefProgressView.swift"
git commit -m "$(cat <<'EOF'
Show what the wait has dug up, not how long it has taken

Counts — 14 articles, 86 facts, 23 points across 7 independent sources —
are the reason someone sits through five minutes; a spinner and an elapsed
clock are not. A stage that has not run shows no number at all, because a
zero reads as a result.

Leaving and cancelling are deliberately different weights. Back means leave
and the run continues; cancel is a quiet separate action that states
outright that spent tokens are not refunded, so a reflexive tap cannot
destroy something already paid for.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: ⑥ 不建议播

**Files:**
- Create: `ios/Pollux One/Domain/Brief/InsufficientState.swift`, `ios/Pollux One/Features/Brief/InsufficientView.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`, `scripts/test-engines.sh`

spec §5.1 的可见形态。这一屏是产品敢不敢说真话的地方。

- [ ] **Step 1: 写实现**

```swift
// ios/Pollux One/Domain/Brief/InsufficientState.swift
import Foundation

struct InsufficientAction: Equatable {
    let id: String
    let title: String
}

struct InsufficientState: Equatable {
    let headline: String
    let costNote: String
    let actions: [InsufficientAction]

    init(found: Int, required: Int, tokensUsed: Int) {
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

- [ ] **Step 2: 写测试**

```swift
    report.section("⑥ 不建议播")
    let shortOfSources = InsufficientState(found: 2, required: 3, tokensUsed: 12_400)
    report.check(shortOfSources.headline.contains("2") && shortOfSources.headline.contains("3"),
                 "说清找到几个、需要几个", detail: shortOfSources.headline)
    report.check(shortOfSources.headline.contains("独立信源"), "说的是独立信源，不是篇数")
    report.check(!shortOfSources.actions.contains { $0.id == "forceDraft" },
                 "不提供强行出稿——给一个绕过拒绝的出口，这套承诺就全是装饰")
    report.check(shortOfSources.actions.contains { $0.id == "retry" }, "可以再找一轮")
    report.check(shortOfSources.actions.contains { $0.id == "another" }, "可以换一条")
    report.check(shortOfSources.costNote.contains("12"), "已消耗照实显示", detail: shortOfSources.costNote)
```

- [ ] **Step 3: 写 View、接进测试台、跑绿、提交**

`scripts/test-engines.sh` 加 `"$IOS/Domain/Brief/InsufficientState.swift" \`

```bash
git add "ios/Pollux One/Domain/Brief/InsufficientState.swift" "ios/Pollux One/Features/Brief/InsufficientView.swift" ios/EngineHarness/BriefScenarios.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
Refuse, and offer no way around the refusal

A "draft it anyway" button would make every other guarantee in this product
decorative, so the screen does not have one — and a test asserts it never
grows one. The honest exits are searching again and picking a different
story.

Tokens already spent are shown rather than hidden: the run cost money and
produced nothing, which is the moment a user most deserves to be told.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: ⑦ 换一篇 + 返回语义分层

**Files:**
- Create: `ios/Pollux One/Domain/Brief/BriefNavigation.swift`
- Modify: `ios/Pollux One/Features/ScriptList/ScriptListView.swift`
- Modify: `ios/EngineHarness/BriefScenarios.swift`, `scripts/test-engines.sh`

spec §8.2 的返回语义，以及 §9.2 ②：「换一篇」的数据源是 **Brief + Script 的合并流**——Brief 在跑的时候还不是 Script，`viewModel.scripts` 装不下它。

- [ ] **Step 1: 写实现**

```swift
// ios/Pollux One/Domain/Brief/BriefNavigation.swift
import Foundation

/// spec §8.2：每一屏的「返回」含义不同，这是本设计里最容易做错的交互。
/// 做成纯函数，是为了让第三种情形（审稿回不到等待）不会在某次重构里
/// 悄悄退化成第二种。
enum BriefNavigation {
    static func back(from screen: BriefScreen) -> BriefScreen {
        switch screen {
        // 全部回相机——它是根。
        case .confirm, .progress, .review, .insufficient, .handOff, .scripts: .camera
        case .camera: .camera
        }
    }

    /// 「离开」不销毁任务：③ 等待页的返回之后，调研继续在云上跑。
    /// 真正的取消是另一个动作。
    static func destroysTask(from screen: BriefScreen) -> Bool { false }

    /// 调研已结束的屏，回不到等待页——那一屏不复存在。
    static func canReturnToProgress(from screen: BriefScreen) -> Bool {
        switch screen {
        case .review, .insufficient: false
        default: true
        }
    }
}
```

```swift
// 加进 ios/Pollux One/Domain/Brief/BriefModels.swift
/// 「换一篇」的一行。Brief 在跑的时候还不是 Script，所以列表是两者的合并流。
struct ScriptListRow: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let isResearching: Bool
}

enum ScriptListRows {
    static func build(scriptTitles: [(id: String, title: String, seconds: Int)],
                      briefs: [Brief]) -> [ScriptListRow] {
        let briefRows = briefs.map { brief in
            ScriptListRow(
                id: brief.id,
                title: brief.news.title,
                subtitle: brief.status == .researching ? "调研中" : "\(brief.estimatedSeconds) 秒",
                isResearching: brief.status == .researching
            )
        }
        let scriptRows = scriptTitles.map {
            ScriptListRow(id: $0.id, title: $0.title, subtitle: "\($0.seconds) 秒",
                          isResearching: false)
        }
        // 在跑的排最前：那是用户此刻最想看的东西。
        return briefRows.filter(\.isResearching) + scriptRows
            + briefRows.filter { !$0.isResearching }
    }
}

/// 空状态。原文案 "Write a script on the Pollux One web console, then pull to
/// refresh." 在 iOS 优先之后是错的——它把人支去了一个不再是主入口的地方。
struct ScriptListEmptyState: Equatable {
    let text = "还没有稿子。把一条新闻交给我，我去查。"
    let action = BriefScreen.handOff
}
```

- [ ] **Step 2: 写测试**

```swift
    report.section("§8.2 返回语义")
    report.check(BriefNavigation.back(from: .confirm) == .camera, "确认页退回相机")
    report.check(BriefNavigation.back(from: .progress) == .camera, "等待页退回相机")
    report.check(BriefNavigation.back(from: .review) == .camera, "审稿页退回相机")
    report.check(!BriefNavigation.destroysTask(from: .progress),
                 "离开不等于取消——任务继续在云上跑")
    report.check(!BriefNavigation.canReturnToProgress(from: .review),
                 "审稿页回不到等待页，调研已结束那一屏不复存在")
    report.check(!BriefNavigation.canReturnToProgress(from: .insufficient),
                 "不建议播同样回不去")

    report.section("⑦ 换一篇")
    var researching = brief
    researching.status = .researching
    let rows = ScriptListRows.build(
        scriptTitles: [(id: "sc1", title: "旧稿", seconds: 60)],
        briefs: [researching]
    )
    report.check(rows.count == 2, "在跑的 Brief 也要出现在列表里", detail: "\(rows.count)")
    report.check(rows.first?.isResearching == true, "在跑的排最前")
    report.check(rows.first?.subtitle == "调研中", "显示进度而不是秒数")

    let empty = ScriptListEmptyState()
    report.check(!empty.text.lowercased().contains("web console"),
                 "空状态不再把人支去 web 端")
    report.check(empty.action == .handOff, "空状态把人送去「交给我」")
```

- [ ] **Step 3: 接进测试台、跑绿、提交**

`scripts/test-engines.sh` 加 `"$IOS/Domain/Brief/BriefNavigation.swift" \`

```bash
git add "ios/Pollux One/Domain/Brief/BriefNavigation.swift" "ios/Pollux One/Domain/Brief/BriefModels.swift" "ios/Pollux One/Features/ScriptList/ScriptListView.swift" ios/EngineHarness/BriefScenarios.swift scripts/test-engines.sh
git commit -m "$(cat <<'EOF'
Merge briefs into the list, and give each back button one meaning

A brief that is still researching is not a Script, so viewModel.scripts
cannot hold it and the list would silently omit the very thing the user is
waiting on. Running briefs sort first because that is what someone opening
this list wants to see. The old empty-state copy pointed people at the web
console, which stopped being the primary surface.

Back is a different promise on each screen: a plain step back before money
is spent, leaving a run that continues in the cloud, and returning from
review to a progress screen that no longer exists. Encoding that as a
function rather than per-screen navigation code is what keeps the third
case from quietly decaying into the second.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: 串起来，在真机上走通全程

**Files:**
- Modify: `ios/Pollux One/App/RootView.swift`
- Create: `ios/Pollux One/Features/Brief/BriefFlow.swift`

- [ ] **Step 1: 写流程容器**

`BriefFlow` 持有 `@State var screen: BriefScreen` 和 `@State var brief: Brief?`，按 `ScriptSlot` 决定入口，按 `BriefNavigation.back(from:)` 处理返回。等待页用一个 `Timer` 每 1.5 秒把 `stages` 往前推一格，制造真实观感。

- [ ] **Step 2: 全量测试**

Run: `bash scripts/test-engines.sh`
Expected: `0 failed`

- [ ] **Step 3: 真机构建并安装**

```bash
cd ios && xcodebuild -project "Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS' build
```

- [ ] **Step 4: 逐屏对着 mock 核**

重点核这五处最容易做错的：

1. 左滑：事实句两个按钮、观点句一个
2. 虚线下划线是不是正好落在 `0.5 个百分点` 上
3. 审稿页返回**不能**回到等待页
4. 未开始的阶段**不显示** 0
5. 信源展开的行数 = 独立源数，末行是「另有 N 篇…未计入」

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/Features/Brief/BriefFlow.swift" "ios/Pollux One/App/RootView.swift"
git commit -m "$(cat <<'EOF'
Walk the whole flow on a phone with no network calls

The progress screen advances its stages on a local timer so the five-minute
wait can be judged for feel before there is anything real to wait for.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: 把 fixture 逼出来的三个字段写回 spec

**Files:**
- Modify: `docs/superpowers/specs/2026-09-17-news-brief-pipeline-design.md`

§0.4 那三样东西目前只活在 fixture 里。不写回 spec，管线建成时就会漏掉。

- [ ] **Step 1: 改 §6.2**——⑧ 挂信源除了产出 `sentence_id → claim_ids`，还要产出**字符区间**（`start` / `length`，以 Character 计）。注明这是从 mock 反推出来的要求。

- [ ] **Step 2: 改 §5**——⑤ 交叉验证要保留「被判为转载而归并掉的篇数」。它和 independence 一起构成用户看到的那两个数字，合并成一个就没法显示「另有 N 篇未计入」。

- [ ] **Step 3: 改 §10**——补上「本月余额」的来源，以及 ④ 的余额门禁（`DialState.canAfford`）。

- [ ] **Step 4: 改 §12**——记下顺序被推翻，以及质量关只是推迟没有取消。

- [ ] **Step 5: 改 §9.2 ②**——把那段对 `SessionManager` 的描述改成实测的样子（见本计划 §0.2）：它不接受 script，`scriptRevision` 本来就是可选，真正的毛病是 `RecordingView.init` 每次构造都造一个新的。

- [ ] **Step 6: 提交**

```bash
git add docs/superpowers/specs/2026-09-17-news-brief-pipeline-design.md
git commit -m "$(cat <<'EOF'
Write down the three fields the screens turned out to need

Building the UI first against fixtures surfaced three things the pipeline
has no producer for: character ranges for the in-sentence underlines, the
count of reposts merged away, and a monthly balance the confirm screen
gates on. Leaving them in a fixture would mean rediscovering them once the
pipeline is finished and expensive to change.

Also corrected: the section describing SessionManager did not match the
code. It never took a script and scriptRevision was already optional — the
real fault was that RecordingView.init built a new manager every time.

And recorded: the spec's own build order was overruled in favour of screens
first, so its quality gate is postponed rather than dropped.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## 二、做完之后

- 七个界面在手机上走得通，全程零网络
- 三个新字段进了 spec
- 下一步接 `docs/superpowers/plans/2026-09-18-brief-live-pipeline.md`，把 fixture 换成真实现——**界面一行不用改**
- spec §12 的质量关仍然要过

## 三、明确不在本计划内

- 任何模型调用、任何网络请求
- Share Extension（③ 的「分享进来」先做占位入口）
- 截图输入的视觉理解
- Safe Word 指纹降级（§9.2 ③）——要等 `script_evidence` 真的有数据
- 落库：全部状态在内存里，杀进程就没了
