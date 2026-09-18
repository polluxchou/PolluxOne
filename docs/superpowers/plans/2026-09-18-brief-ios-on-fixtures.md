# 七个界面，喂填充物 — 实施计划（spec 第二段，提前做）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 七个界面在 iOS 上真的能点、能滑、能跳转，全部数据来自本地 fixture。一次模型调用都不发。

**Architecture:** 先把相机变成根视图、把 `SessionManager` 从 `RecordingView.init` 里提出来（这是 spec §12 点名的第一件事），再照 mock 逐屏建。所有界面只认一个 `BriefFixture` 协议，等管线建成后换掉数据源即可，界面不用改。

**Tech Stack:** SwiftUI · Swift 6 · 现有 `EngineHarness` 测试台 · 无第三方包

---

## 零、读这个计划之前必须知道的事

### 0.1 为什么先做界面

spec §12 原本要求先做后端管线、跑质量关再投界面。**这条被推翻了**：先用填充物文档把界面立起来，再回头接真实管线。

代价要认：**这一段做完，你仍然不知道稿子好不好。** 质量关只是推迟，没有取消。管线计划已经写好并搁在 `docs/superpowers/plans/2026-09-18-brief-live-pipeline.md`，接上之后那道门还要过。

好处是真的：mock 里藏着三个后端目前产不出来的东西（§0.2），界面先行把它们提前暴露了出来——否则会等到管线全建完、接界面时才发现。

### 0.2 mock 要的三样东西，确定性内核目前产不出来

从 `project/Review.dc.html` 和 `project/Progress.dc.html` 反推出来的：

| mock 上的东西 | 现状 | 本计划怎么办 |
|---|---|---|
| 句内虚线下划线（`0.5 个百分点`、`3 月 15 日`） | `DraftSentence` 只有整句 `claimIds`，没有字符区间 | fixture 里显式带 `anchors: [{start, length, claimId}]`；**管线将来必须补产这个字段** |
| 「另有 6 篇为上述稿件转载，未计入」 | `independence` 只留了结果，丢了被归并掉的篇数 | fixture 里带 `mergedAwayCount`；管线将来要在 ⑤ 保留这个差值 |
| 「预算 120K · 已用 40%」「本月余额 2.41M」 | 完全没有模型 | fixture 里带 `budget`；将来归入计费 |

**这三条要记进 spec**，不能只活在 fixture 里。Task 16 做这件事。

### 0.3 顺序不能改

Task 1–4 是结构，Task 5–15 是界面。**结构不先理顺，后面每一屏都会被它拖着**——这是 spec §12 的原话。尤其 Task 2：`SessionManager` 现在绑在某一篇稿上，换稿会让取景器黑一下重启。

### 0.4 错误方向

界面这一段最危险的不是崩，是**显示一个比真相更乐观的数字**：

| 做错的方向 | 后果 |
|---|---|
| 信源数显示成"篇数"而不是"独立源数" | 用户以为有 10 个源，其实是 1 篇稿的 10 次转载 |
| 证据锚点错位，下划线划在别的字上 | 用户点开看到的信源对不上那个数字 |
| 已删句子的证据没清掉 | 孤儿证据，下一次展开时挂在错的句子上 |

一律宁可少显示。

---

## 一、文件结构

```
ios/Pollux One/
  Domain/Brief/
    Brief.swift              Brief · BriefStatus · NewsRef
    BriefSentence.swift      句子 + kind + 证据锚点
    Evidence.swift           ClaimEvidence · SourceRef
    BriefStage.swift         九个阶段 + 计数
    TokenBudget.swift        用量 / 预算 / 余额
  Services/
    BriefStore.swift         协议：界面只认它
    FixtureBriefStore.swift  从 bundle 里的 JSON 读
  Features/Brief/
    ReviewView.swift         ② 审稿（= 稿件详情）
    SentenceRow.swift        一行句子 + 左滑
    EvidenceSheet.swift      信源展开
    HandOffView.swift        ③ 交给我
    ConfirmView.swift        ④ 确认（拨盘）
    DialControl.swift        拨盘本体
    ProgressView.swift       ⑤ 等待
    InsufficientView.swift   ⑥ 不建议播
  Features/ScriptList/
    ScriptListView.swift     ⑦ 换一篇（改造）
  Resources/
    brief-fixture.json       填充物
```

---

## Task 1: 填充物的数据契约

**Files:**
- Create: `ios/Pollux One/Domain/Brief/Brief.swift`, `BriefSentence.swift`, `Evidence.swift`, `BriefStage.swift`, `TokenBudget.swift`
- Create: `ios/Pollux One/Resources/brief-fixture.json`
- Test: `ios/EngineHarness/BriefFixtureScenarios.swift`

字段全部从 mock 上的可见内容反推。**mock 上没有的字段一个都不加**——加了就是在猜产品。

- [ ] **Step 1: 写失败的测试**

```swift
// ios/EngineHarness/BriefFixtureScenarios.swift
scenario("fixture 能解码成 Brief") {
    let brief = try! BriefFixture.load()
    expect(brief.news.publisher == "财新", "发布方标签")
    expect(brief.news.title.contains("存款准备金率"), "标题")
    expect(brief.estimatedSeconds == 83, "时长 83 秒")
}

scenario("句子按 mock 的五行还原，类型齐全") {
    let brief = try! BriefFixture.load()
    expect(brief.sentences.count == 5, "五句")
    expect(brief.sentences[0].kind == .transition, "第一句是钩子")
    expect(brief.sentences[1].kind == .fact, "第二句是事实")
    expect(brief.sentences[4].kind == .opinion, "最后一句是观点")
}

scenario("事实句带证据锚点，锚点落在句内合法区间") {
    let brief = try! BriefFixture.load()
    let s = brief.sentences[1]
    expect(!s.anchors.isEmpty, "事实句必须有锚点")
    for anchor in s.anchors {
        expect(anchor.start >= 0, "起点非负")
        expect(anchor.start + anchor.length <= s.text.count, "锚点不能越出句子")
    }
}

scenario("观点句没有锚点也没有 claim——它不该冒充有信源") {
    let brief = try! BriefFixture.load()
    let s = brief.sentences[4]
    expect(s.anchors.isEmpty, "观点句不该有锚点")
    expect(s.claimIds.isEmpty, "观点句不该有 claim")
}

scenario("独立源数与被归并掉的转载数是两个字段") {
    let brief = try! BriefFixture.load()
    let claim = brief.claims["c1"]!
    expect(claim.independence == 3, "3 个独立源")
    expect(claim.mergedAwayCount == 6, "另有 6 篇转载未计入")
    expect(claim.sources.count == 3, "展开时列出 3 行，不是 9 行")
}

scenario("弱信源的 claim 被标出来") {
    let brief = try! BriefFixture.load()
    expect(brief.claims["c3"]!.independence == 1, "只有 1 个信源")
}

scenario("九个阶段都在，且顺序固定") {
    let brief = try! BriefFixture.load()
    expect(brief.stages.count == 9, "九个阶段")
    expect(brief.stages[0].name == "抓取原文", "第一个")
    expect(brief.stages[8].name == "时长与气口", "最后一个")
}

scenario("进行中的阶段只有一个") {
    let brief = try! BriefFixture.load()
    let running = brief.stages.filter { $0.state == .running }
    expect(running.count == 1, "同时只能有一个阶段在跑")
}

scenario("token 预算三个数自洽") {
    let brief = try! BriefFixture.load()
    let b = brief.budget
    expect(b.used == 48_240, "已用")
    expect(b.budgeted == 120_000, "预算")
    expect(b.used < b.budgeted, "已用不该超预算")
    expect(b.byStage.values.reduce(0, +) == b.used, "分阶段之和必须等于总数")
}
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `bash scripts/test-engines.sh`
Expected: FAIL — `BriefFixture` 不存在

- [ ] **Step 3: 写类型**

```swift
// ios/Pollux One/Domain/Brief/Brief.swift
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

struct Brief: Codable, Identifiable, Equatable {
    let id: String
    let news: NewsRef
    let status: BriefStatus
    /// 已经按用户语速算过的秒数。mock 上是 83。
    let estimatedSeconds: Int
    /// 这个秒数是不是用了这个用户自己的语速。false 时界面不许写「按你的语速」。
    let pacedToUser: Bool
    let sentences: [BriefSentence]
    let claims: [String: ClaimEvidence]
    let stages: [BriefStage]
    let budget: TokenBudget
    /// ⑥ 不建议播时的理由。其他状态为 nil。
    let insufficientReason: String?
}
```

```swift
// ios/Pollux One/Domain/Brief/BriefSentence.swift
import Foundation

enum SentenceKind: String, Codable {
    case fact, opinion, transition
}

/// 句内的证据锚点：mock 上那条虚线下划线。
/// `start` / `length` 以**字符**计（不是 UTF-16 code unit），中文一个字算一个。
struct EvidenceAnchor: Codable, Equatable {
    let start: Int
    let length: Int
    let claimId: String
}

struct BriefSentence: Codable, Identifiable, Equatable {
    let id: String
    let text: String
    let kind: SentenceKind
    let claimIds: [String]
    let anchors: [EvidenceAnchor]

    /// spec §8.1：事实句左滑露出「重查 + 删除」，其余只露「删除」。
    /// 观点句没有信源可重查，给它一个重查按钮就是在骗人。
    var canRecheckSources: Bool { kind == .fact }
}
```

```swift
// ios/Pollux One/Domain/Brief/Evidence.swift
import Foundation

struct SourceRef: Codable, Equatable, Identifiable {
    var id: String { publisher + time }
    let publisher: String
    /// mock 上第二列：逐字引文，或「独立测算，口径一致」这样的说明。
    let note: String
    /// mock 上第三列，形如 "15:02"。
    let time: String
}

struct ClaimEvidence: Codable, Equatable {
    let id: String
    /// **互不相关的信源组数**，不是篇数。界面上那个数字就是它。
    let independence: Int
    /// 被判定为转载、已归并掉的篇数。mock：「另有 6 篇为上述稿件转载，未计入」。
    /// 和 independence 分开存，是因为把它们加起来正是用户最容易误会的那个数。
    let mergedAwayCount: Int
    let sources: [SourceRef]
}
```

```swift
// ios/Pollux One/Domain/Brief/BriefStage.swift
import Foundation

enum StageState: String, Codable {
    case done, running, pending
}

/// spec §8 ⑤：九个阶段带**计数**而非耗时——计数告诉用户挖到了什么。
struct BriefStage: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let state: StageState
    /// 形如 "14 篇"、"86 条"、"23 点 · 7 独立源"、"9 / 23"。未开始时 nil。
    let count: String?
    /// 进行中的阶段底下那一行实时说明。其余为 nil。
    let detail: String?
}
```

```swift
// ios/Pollux One/Domain/Brief/TokenBudget.swift
import Foundation

/// spec §10.1：token 是一等产品对象。
struct TokenBudget: Codable, Equatable {
    let used: Int
    let budgeted: Int
    /// 本月剩余额度。
    let remainingThisMonth: Int
    let costCents: Int
    /// 阶段名 → token 数。之和必须等于 used，否则进度条会撒谎。
    let byStage: [String: Int]

    var fractionUsed: Double {
        budgeted > 0 ? Double(used) / Double(budgeted) : 0
    }
}
```

- [ ] **Step 4: 照 mock 写 fixture**

`ios/Pollux One/Resources/brief-fixture.json`，数值全部照抄 mock：`estimatedSeconds` 83、五句、`c1` 的 independence 3 / mergedAwayCount 6、三行信源（中国人民银行 15:02、新华社 15:20、财新网 16:41）、九个阶段（1 篇 / 14 篇 / 86 条 / 23 点 · 7 独立源 / 9 / 23 / 其余 pending）、budget used 48240 budgeted 120000 remainingThisMonth 2410000 costCents 14。

`byStage` 照 mock 的图例：抽取 38100、成稿 6200、检索 3900——注意这三个加起来是 48200，不是 48240。**差的 40 要补进去**，否则 Step 1 最后那个断言过不了。补在「抓取原文」上。

- [ ] **Step 5: 跑到绿**

Run: `bash scripts/test-engines.sh`
Expected: `TOTAL: 244 passed, 0 failed`

- [ ] **Step 6: 提交**

```bash
git add "ios/Pollux One/Domain/Brief/" "ios/Pollux One/Resources/brief-fixture.json" ios/EngineHarness/BriefFixtureScenarios.swift
git commit -m "$(cat <<'EOF'
Give the screens a contract before giving them data

Every field is read off the finished mock; nothing is invented, because a
field with no pixel behind it is a product guess. Three of them have no
producer yet and that is the point of building the UI first — the in-
sentence evidence anchors, the count of reposts merged away, and the token
budget all have to come from somewhere later.

Independence and mergedAwayCount are separate fields on purpose: adding
them together is exactly the number a reader would misread as "how many
outlets reported this", and keeping them apart makes that sum impossible
to write by accident.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 把 `SessionManager` 从 `RecordingView.init` 里提出来

**Files:**
- Modify: `ios/Pollux One/Features/Recording/RecordingView.swift:50`
- Modify: `ios/Pollux One/App/AppEnvironment.swift`
- Test: `ios/EngineHarness/CameraScenarios.swift`

spec §12 指名这是第二段的第一件事。现在相机会话的生命周期绑在某一篇稿上，换稿等于重建 `SessionManager`，`CameraEngine` 跟着重建，取景器会黑一下。

引擎层**已经支持**换稿（`SessionManager.prepare(script:)` 内部就是 `teleprompterEngine.load` + `alignmentEngine.reset`）。错的是构造时机，不是能力。

- [ ] **Step 1: 写失败的测试**

```swift
// 加进 ios/EngineHarness/CameraScenarios.swift
scenario("换稿不重建会话——取景器不该黑一下") {
    let manager = SessionManager()
    manager.prepare(script: makeScript(id: "a", text: "第一篇。"))
    let sessionBefore = ObjectIdentifier(manager.cameraEngine)

    manager.prepare(script: makeScript(id: "b", text: "第二篇。"))
    let sessionAfter = ObjectIdentifier(manager.cameraEngine)

    expect(sessionBefore == sessionAfter, "换稿必须复用同一个 CameraEngine")
}

scenario("没有稿也能有会话——相机是根视图，开机时通常没有稿") {
    let manager = SessionManager()
    expect(manager.cameraEngine != nil, "无稿时相机引擎也要在")
    expect(manager.script == nil, "此时没有稿")
}

scenario("从有稿切到无稿，提词器状态被清干净") {
    let manager = SessionManager()
    manager.prepare(script: makeScript(id: "a", text: "第一篇。"))
    manager.clearScript()
    expect(manager.script == nil, "稿没了")
    expect(manager.teleprompterEngine.rows.isEmpty, "提词行也要清掉，否则会画在画面上")
}
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `bash scripts/test-engines.sh`
Expected: FAIL — `SessionManager()` 无参构造不存在

- [ ] **Step 3: 改实现**

`SessionManager` 加无参 `init()`，`script` 变 `Script?`，新增 `clearScript()`。把它挪到 `AppEnvironment` 持有，`RecordingView` 改为 `@Environment` 订阅而不是在 `init` 里造。

- [ ] **Step 4: 跑到绿 + 真机构建**

```bash
bash scripts/test-engines.sh
```
Expected: `TOTAL: 247 passed, 0 failed`

```bash
cd ios && xcodebuild -project "Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS' build
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/Features/Recording/RecordingView.swift" "ios/Pollux One/App/AppEnvironment.swift" ios/EngineHarness/CameraScenarios.swift
git commit -m "$(cat <<'EOF'
Stop tying the camera's life to whichever script is open

Building SessionManager inside RecordingView.init made the capture session
a property of one script: switching scripts rebuilt the manager, which
rebuilt CameraEngine, which blacked out the viewfinder. The engines already
supported swapping scripts — prepare(script:) just reloads the teleprompter
and resets alignment — so what was wrong was the construction site, not the
capability.

This has to land before any of the new screens, because a camera that
belongs to a script cannot be the root of an app whose first line is
"camera first".

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 相机变根视图

**Files:**
- Modify: `ios/Pollux One/App/RootView.swift:9`
- Modify: `ios/Pollux One/Features/Recording/RecordingView.swift:14`

`RootView` 现在挂的是 `ScriptListView`，与 README 第一句「Camera first」相反。`RecordingView.script` 是 `let script: Script`，不可选——相机作为根必须能在无稿时运行。

- [ ] **Step 1: 写失败的测试**

```swift
scenario("无稿时提词块整块隐藏，而不是显示一个空框") {
    let state = RecordingViewState(script: nil)
    expect(!state.showsTeleprompter, "没有稿就不该有提词区")
    expect(state.showsShutter, "但快门必须还在——无稿也能拍")
}

scenario("有稿时提词块出现") {
    let state = RecordingViewState(script: makeScript(id: "a", text: "一句话。"))
    expect(state.showsTeleprompter, "有稿就该有提词区")
}
```

- [ ] **Step 2: 跑一遍确认它失败**

Run: `bash scripts/test-engines.sh`
Expected: FAIL — `RecordingViewState` 不存在

- [ ] **Step 3: 改实现**

`RecordingView.script` 改成 `Script?`；抽出 `RecordingViewState` 承载"显示什么"的判断，让它可被 harness 测；`RootView` 改挂 `RecordingView`。

- [ ] **Step 4: 跑到绿**

Run: `bash scripts/test-engines.sh && cd ios && xcodebuild -project "Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS' build`
Expected: 全绿 + `BUILD SUCCEEDED`

- [ ] **Step 5: 提交**

```bash
git add "ios/Pollux One/App/RootView.swift" "ios/Pollux One/Features/Recording/RecordingView.swift"
git commit -m "$(cat <<'EOF'
Put the camera at the root and let it run with no script

RootView mounted the script list, which is the opposite of the first line
of the README. Making script optional is what lets the camera be the root
at all: on a fresh launch there is no script, and the teleprompter block
hides rather than rendering an empty frame over the picture. The shutter
stays — recording without a script was always allowed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 相机右下角那格随 `hasScript` 变

**Files:**
- Create: `ios/Pollux One/Features/Recording/ScriptSlotView.swift`
- Test: `ios/EngineHarness/CameraScenarios.swift`

spec §9.2 ②：有稿 → 去当前稿件详情；无稿 → 直接去「交给我」。这是整个新流程的唯一入口。

- [ ] **Step 1: 写失败的测试**

```swift
scenario("有稿时那格是「当前稿件」") {
    let slot = ScriptSlot(brief: sampleBrief())
    expect(slot.destination == .review, "有稿进审稿页")
    expect(slot.caption.contains("83"), "显示秒数")
}

scenario("无稿时那格是「交给我」") {
    let slot = ScriptSlot(brief: nil)
    expect(slot.destination == .handOff, "无稿直接去交给我")
}

scenario("调研中时那格是「进度」，不是审稿") {
    let slot = ScriptSlot(brief: researchingBrief())
    expect(slot.destination == .progress, "在跑就回到等待页")
}

scenario("信源不足时那格去「不建议播」") {
    let slot = ScriptSlot(brief: insufficientBrief())
    expect(slot.destination == .insufficient, "")
}
```

- [ ] **Step 2–5**：实现 `ScriptSlot`（一个纯判断结构 + 一个 View），跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
Make one corner of the camera the only door into the new flow

The slot's destination is a pure function of brief state, so the four cases
— none, running, ready, insufficient — are testable without a screen. A
running brief goes back to the progress screen rather than to review:
there is nothing to review yet, and sending someone to an empty review page
is how a five-minute wait feels like a failure.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `BriefStore` 协议 + fixture 实现

**Files:**
- Create: `ios/Pollux One/Services/BriefStore.swift`, `FixtureBriefStore.swift`
- Test: `ios/EngineHarness/BriefFixtureScenarios.swift`

界面只认这个协议。管线建成后换一个实现，界面一行不改。

- [ ] **Step 1: 写失败的测试**

```swift
scenario("fixture store 取得到当前 brief") {
    let store = FixtureBriefStore()
    expect(store.currentBrief() != nil, "有当前稿")
}

scenario("删句之后那句就不在了，且它的证据也清掉了") {
    let store = FixtureBriefStore()
    let brief = store.currentBrief()!
    let target = brief.sentences[1]
    let after = store.deleteSentence(target.id, from: brief)

    expect(after.sentences.count == brief.sentences.count - 1, "少一句")
    expect(!after.sentences.contains { $0.id == target.id }, "那句没了")
    for claimId in target.claimIds {
        let stillUsed = after.sentences.contains { $0.claimIds.contains(claimId) }
        if !stillUsed {
            expect(after.claims[claimId] == nil, "没人用的 claim 必须清掉，否则是孤儿证据")
        }
    }
}

scenario("被别的句子共用的 claim 不能因为删一句就清掉") {
    let store = FixtureBriefStore()
    var brief = store.currentBrief()!
    // 造一个两句共用 c1 的局面
    brief = store.duplicateSentenceForTest(brief.sentences[1].id, in: brief)
    let after = store.deleteSentence(brief.sentences[1].id, from: brief)
    expect(after.claims["c1"] != nil, "还有人在用，不能清")
}

scenario("删光了会落到 insufficient，而不是留一个空稿") {
    let store = FixtureBriefStore()
    var brief = store.currentBrief()!
    for sentence in brief.sentences {
        brief = store.deleteSentence(sentence.id, from: brief)
    }
    expect(brief.status == .insufficient, "空稿必须降级，不能假装还能播")
}
```

- [ ] **Step 2–5**：实现，跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
Clean up the evidence when a sentence goes away

An orphaned claim is not inert: it stays in the dictionary and the next
sentence that happens to reference that id shows someone else's sources.
Cleanup is conditional on nothing else using the claim, because two
sentences can legitimately share one.

Deleting the last sentence drops the brief to insufficient rather than
leaving an empty script that still looks readable.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: ② 审稿页 —— 句子行与类型着色

**Files:**
- Create: `ios/Pollux One/Features/Brief/ReviewView.swift`, `SentenceRow.swift`

mock 的着色规则（`project/Review.dc.html`）：

| 句子 | 左边线 | 背景 |
|---|---|---|
| transition | `#3A362F` 实线 | 无 |
| fact · 强 | `#6FA292` 实线 | 展开时 `rgba(111,162,146,0.05)` |
| fact · 弱（仅 1 源） | `#D9A441` 实线 | 无 |
| opinion | `#3A362F` **虚线** | 无，文字斜体 |

- [ ] **Step 1: 写失败的测试**

```swift
scenario("强信源事实句是绿色实线") {
    let style = SentenceStyle(kind: .fact, independence: 4)
    expect(style.accent == .strong, "")
    expect(!style.isDashed, "实线")
}

scenario("只有 1 个信源的事实句是黄色——这是个警告，不是装饰") {
    let style = SentenceStyle(kind: .fact, independence: 1)
    expect(style.accent == .weak, "")
}

scenario("观点句是虚线，且永远不着强色") {
    let style = SentenceStyle(kind: .opinion, independence: 0)
    expect(style.isDashed, "虚线")
    expect(style.accent == .neutral, "观点句不许染成有信源的颜色")
}

scenario("钩子句是中性实线") {
    let style = SentenceStyle(kind: .transition, independence: 0)
    expect(style.accent == .neutral, "")
    expect(!style.isDashed, "")
}

scenario("顶部三个计数 pill 与句子分类一致") {
    let brief = try! BriefFixture.load()
    let counts = SentenceCounts(brief.sentences, claims: brief.claims)
    expect(counts.strong == 4, "mock 上绿色 pill 是 4")
    expect(counts.weak == 1, "黄色 pill 是 1")
    expect(counts.unsourced == 1, "灰色 pill 是 1")
}
```

- [ ] **Step 2–5**：实现，跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
Colour a sentence by how well it is sourced, not by how it reads

The amber on a single-source fact is a warning, so an opinion sentence can
never take a sourced colour no matter what it says — dressing a judgment in
the same green as three corroborated outlets is the one visual lie this
screen must not tell.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: ② 句内证据锚点（虚线下划线）

**Files:**
- Modify: `ios/Pollux One/Features/Brief/SentenceRow.swift`

mock 上 `0.5 个百分点`、`3 月 15 日`、`约 1 万亿元`、`10 个基点` 都带虚线下划线。锚点错位会让用户点开看到对不上的信源——比不显示更糟。

- [ ] **Step 1: 写失败的测试**

```swift
scenario("锚点切出的子串就是 mock 上带下划线的那几个字") {
    let brief = try! BriefFixture.load()
    let s = brief.sentences[1]  // 「下调存款准备金率0.5 个百分点，3 月 15 日正式生效。」
    let pieces = s.anchors.map { anchor -> String in
        let chars = Array(s.text)
        return String(chars[anchor.start ..< (anchor.start + anchor.length)])
    }
    expect(pieces.contains("0.5 个百分点"), "第一个锚点")
    expect(pieces.contains("3 月 15 日"), "第二个锚点")
}

scenario("锚点越界时整句降级为无锚点，而不是崩或者划错地方") {
    let bad = BriefSentence(id: "x", text: "短句。", kind: .fact,
                            claimIds: ["c1"], anchors: [.init(start: 2, length: 99, claimId: "c1")])
    let runs = AnchorRuns(bad)
    expect(runs.isDegraded, "越界必须降级")
    expect(runs.segments.count == 1, "退回一整段无标记文本")
}

scenario("锚点重叠时也降级——重叠说明上游算错了") {
    let bad = BriefSentence(id: "x", text: "一二三四五六七八。", kind: .fact, claimIds: ["c1"],
                            anchors: [.init(start: 0, length: 4, claimId: "c1"),
                                      .init(start: 2, length: 4, claimId: "c1")])
    expect(AnchorRuns(bad).isDegraded, "重叠必须降级")
}

scenario("锚点之间的普通文字原样保留，一个字不丢") {
    let brief = try! BriefFixture.load()
    let runs = AnchorRuns(brief.sentences[1])
    let rebuilt = runs.segments.map(\.text).joined()
    expect(rebuilt == brief.sentences[1].text, "拼回去必须与原句逐字相同")
}
```

- [ ] **Step 2–5**：实现 `AnchorRuns`（把句子按锚点切成 segment 序列），跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
Underline the exact characters the evidence covers, or none of them

An anchor that lands two characters off points the reader at a number whose
sources say something else — worse than no underline at all. Out-of-range
and overlapping anchors both degrade the whole sentence to plain text
rather than being clamped into something plausible, because both mean the
producer upstream got it wrong and a clamped anchor hides that.

The reassembly test is the one that matters: segments joined back together
must equal the original sentence character for character, so no slicing
bug can silently drop or duplicate text.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: ② 信源展开

**Files:**
- Create: `ios/Pollux One/Features/Brief/EvidenceSheet.swift`

mock 折叠态是一个按钮（`4 个独立信源` / `仅 1 个信源`），展开后是每源一行：`发布方` · `引文或说明` · `时间`，末尾一行灰字 `另有 6 篇为上述稿件转载，未计入`。

- [ ] **Step 1: 写失败的测试**

```swift
scenario("折叠态的文案用「独立信源」而不是「篇」") {
    let label = EvidenceLabel(ClaimEvidence(id: "c1", independence: 4, mergedAwayCount: 6, sources: []))
    expect(label.text.contains("独立信源"), "必须说清是独立源")
    expect(!label.text.contains("篇"), "说「篇」会让用户把转载算进去")
}

scenario("只有 1 个信源时文案是警告口吻") {
    let label = EvidenceLabel(ClaimEvidence(id: "c3", independence: 1, mergedAwayCount: 0, sources: []))
    expect(label.text.contains("仅"), "mock 上是「仅 1 个信源」")
    expect(label.isWarning, "")
}

scenario("展开的行数等于独立源数，不等于总篇数") {
    let brief = try! BriefFixture.load()
    let claim = brief.claims["c1"]!
    expect(claim.sources.count == claim.independence, "列出几行就是几个独立源")
}

scenario("有转载被归并时才显示那行灰字") {
    let with = EvidenceFooter(mergedAwayCount: 6)
    expect(with.text != nil, "有转载就要说明")
    let without = EvidenceFooter(mergedAwayCount: 0)
    expect(without.text == nil, "没有转载就不该出现这行")
}

scenario("观点句不提供展开——它没有信源可展开") {
    let brief = try! BriefFixture.load()
    expect(brief.sentences[4].claimIds.isEmpty, "")
}
```

- [ ] **Step 2–5**：实现，跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
Say "independent sources", and show the reposts as a number you cannot add

Writing "4 篇" invites the reader to count the reposts too, which is the
exact misreading the whole independence calculation exists to prevent. The
merged-away count appears as its own grey line, phrased as excluded rather
than as a total, and disappears entirely when nothing was merged — a line
saying "0 reposts" is noise on most claims.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: ② 左滑按句子类型分化

**Files:**
- Modify: `ios/Pollux One/Features/Brief/SentenceRow.swift`

spec §8.1：事实句露 `重查信源` + `删除`（mock 上 144px），钩子/观点句只露 `删除`（72px）。

- [ ] **Step 1: 写失败的测试**

```swift
scenario("事实句露两个按钮") {
    let actions = SwipeActions(for: .fact)
    expect(actions.buttons.count == 2, "")
    expect(actions.buttons.contains(.recheck), "")
    expect(actions.width == 144, "mock 上两个按钮共 144pt")
}

scenario("观点句只露删除——给它「重查」是在骗人") {
    let actions = SwipeActions(for: .opinion)
    expect(actions.buttons == [.delete], "")
    expect(actions.width == 72, "")
}

scenario("钩子句同样只露删除") {
    expect(SwipeActions(for: .transition).buttons == [.delete], "")
}

scenario("滑过一半才吸附打开，否则弹回") {
    var row = SwipeState(width: 144)
    row.drag(to: -50)
    row.release()
    expect(!row.isOpen, "没过半，弹回")

    row.drag(to: -100)
    row.release()
    expect(row.isOpen, "过半，吸附")
}

scenario("同时只能有一行是打开的") {
    var list = SwipeList(rowIds: ["a", "b"])
    list.open("a")
    list.open("b")
    expect(list.openId == "b", "")
}
```

- [ ] **Step 2–5**：实现，跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
Offer "recheck sources" only where sources exist

An opinion sentence has nothing to recheck, so showing the button would
promise an action that cannot do anything. The split comes from the kind
field the drafting stage already assigns — it is a consequence of the data
model, not a layout preference.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: ③ 交给我

**Files:**
- Create: `ios/Pollux One/Features/Brief/HandOffView.swift`

spec §8 ③：`打字 / 说给我听` 两档。打字档是**一个**输入框（链接与文本合一）；剪贴板检测是输入框上方的快捷条，**未授权则整条不出现**；`上传截图` 与 `分享进来` 并列在下方。

- [ ] **Step 1: 写失败的测试**

```swift
scenario("链接和文本共用一个输入框，不是两个") {
    let state = HandOffState(mode: .typing)
    expect(state.inputFields.count == 1, "一个框，别做成两个")
}

scenario("剪贴板未授权时整条快捷条不出现，而不是显示一个禁用的按钮") {
    let state = HandOffState(mode: .typing, clipboardAuthorized: false)
    expect(!state.showsClipboardBar, "未授权就整条消失")
}

scenario("剪贴板里没有可用内容时也不出现") {
    let state = HandOffState(mode: .typing, clipboardAuthorized: true, clipboardHasContent: false)
    expect(!state.showsClipboardBar, "")
}

scenario("说给我听档没有输入框") {
    let state = HandOffState(mode: .speaking)
    expect(state.inputFields.isEmpty, "语音档不该有文字框")
}

scenario("上传截图和分享进来是并列的一类——东西都在别处") {
    let state = HandOffState(mode: .typing)
    expect(state.secondaryEntries == [.screenshot, .shareSheet], "")
}

scenario("输入为空时不能往下走") {
    var state = HandOffState(mode: .typing)
    expect(!state.canProceed, "")
    state.text = "https://example.com/news"
    expect(state.canProceed, "")
}
```

- [ ] **Step 2–5**：实现，跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
One input box, and a clipboard bar that is absent rather than disabled

A link and a pasted article are the same thing to the pipeline, so two
boxes would ask the user to classify their input for no reason. When the
clipboard is unauthorised or empty the shortcut bar is gone entirely: a
greyed-out button asks to be tapped and then explains why it cannot work.

Screenshot upload and the share sheet sit together because they are one
idea — the thing is somewhere else.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: ④ 确认 —— 拨盘

**Files:**
- Create: `ios/Pollux One/Features/Brief/ConfirmView.swift`, `DialControl.swift`

spec §2.2：横轴通俗↔专业，纵轴时长（最长 6min），两个锚点 `60s 通俗` 和 `3min 偏专业`，**要有调相机拨盘的手感**。§8 ④：新闻收成一行标签。

- [ ] **Step 1: 写失败的测试**

```swift
scenario("时长封顶 6 分钟") {
    var dial = DialState()
    dial.setDuration(seconds: 999)
    expect(dial.durationSec == 360, "最长 6min")
}

scenario("调性夹在 0 和 1 之间") {
    var dial = DialState()
    dial.setRegister(2.0)
    expect(dial.register == 1.0, "")
    dial.setRegister(-1.0)
    expect(dial.register == 0.0, "")
}

scenario("两个锚点一点就位") {
    var dial = DialState()
    dial.snap(to: .casualMinute)
    expect(dial.durationSec == 60, "")
    expect(dial.register == 0.0, "")

    dial.snap(to: .professionalThreeMinutes)
    expect(dial.durationSec == 180, "")
    expect(dial.register > 0.5, "偏专业")
}

scenario("时长按档位吸附，不是连续的——拨盘要有段落感") {
    var dial = DialState()
    dial.setDuration(seconds: 71)
    expect(DialState.durationSteps.contains(dial.durationSec), "必须落在档位上")
}

scenario("成本预估随拨盘变，时长越长越贵") {
    var dial = DialState()
    dial.snap(to: .casualMinute)
    let cheap = dial.estimate.tokens
    dial.snap(to: .professionalThreeMinutes)
    expect(dial.estimate.tokens > cheap, "3 分钟必须比 1 分钟贵")
}

scenario("余额不够时挡在这里，不许开跑") {
    var dial = DialState(remainingTokens: 1000)
    dial.snap(to: .professionalThreeMinutes)
    expect(!dial.canAfford, "余额不足必须在花钱之前拦住")
    expect(dial.blockReason != nil, "要说清为什么")
}
```

- [ ] **Step 2–5**：实现，跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
Make the dial notch, and stop the run before it spends what isn't there

Duration snaps to steps rather than sliding continuously — that is where
the camera-dial feel comes from, and it also means the cost estimate is
drawn from a small set of known points instead of interpolated. The two
anchors are one tap because they are the two settings we intend to evaluate
quality at.

The affordability check lives on this screen because this is the last one
before tokens start burning; finding out afterwards is the failure the
spec calls out by name.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: ⑤ 等待 —— token 表与九阶段计数

**Files:**
- Create: `ios/Pollux One/Features/Brief/BriefProgressView.swift`

mock 上半 1/3 是 token 表：`48,240 tokens` / `¥0.14` / 分段进度条 / 图例 / `预算 120K · 已用 40%` / `本月余额 2.41M`。下面九个阶段带计数。

- [ ] **Step 1: 写失败的测试**

```swift
scenario("进度条分段宽度等于各阶段占预算的比例") {
    let brief = try! BriefFixture.load()
    let bar = TokenBar(brief.budget)
    let total = bar.segments.map(\.fraction).reduce(0, +)
    expect(abs(total - brief.budget.fractionUsed) < 0.001, "分段之和必须等于已用比例")
}

scenario("阶段计数显示的是挖到了什么，不是耗时") {
    let brief = try! BriefFixture.load()
    let extract = brief.stages.first { $0.name == "抽取事实点" }!
    expect(extract.count == "86 条", "")
    for stage in brief.stages where stage.state != .pending {
        expect(stage.count != nil, "跑过的阶段必须有计数")
        expect(!(stage.count!.contains("秒")), "计数不该是耗时")
    }
}

scenario("未开始的阶段不显示计数，也不显示 0") {
    let brief = try! BriefFixture.load()
    for stage in brief.stages where stage.state == .pending {
        expect(stage.count == nil, "还没跑就不该有数字，显示 0 是在撒谎")
    }
}

scenario("只有进行中的阶段带实时说明") {
    let brief = try! BriefFixture.load()
    for stage in brief.stages {
        if stage.state == .running { expect(stage.detail != nil, "跑着的要有一行说明") }
        else { expect(stage.detail == nil, "") }
    }
}

scenario("返回是「离开」不是「取消」——任务继续在云上跑") {
    let actions = ProgressActions()
    expect(actions.back == .leave, "随手一按不该毁掉已经花了钱的任务")
    expect(actions.cancel.isDestructive, "真正的取消是另一个动作")
    expect(actions.cancel.warning.contains("不退"), "必须明说已消耗的不退")
}
```

- [ ] **Step 2–5**：实现，跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
Show what the wait has dug up, not how long it has taken

Counts — 14 articles, 86 facts, 23 points across 7 independent sources —
are the reason someone is willing to sit through five minutes; a spinner
with an elapsed clock is not. A stage that has not run shows no number at
all, because a zero reads as a result.

Back means leave, and the run continues in the cloud. Cancel is a separate,
deliberately quiet action that states outright that spent tokens are not
refunded — a reflexive back-tap must not destroy something already paid for.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: ⑥ 不建议播

**Files:**
- Create: `ios/Pollux One/Features/Brief/InsufficientView.swift`

spec §5.1 的可见形态。这一屏是产品敢不敢说真话的地方。

- [ ] **Step 1: 写失败的测试**

```swift
scenario("说清差在哪，而不是一句「失败了」") {
    let view = InsufficientState(found: 2, required: 3)
    expect(view.headline.contains("2"), "说清找到几个")
    expect(view.headline.contains("3"), "说清需要几个")
}

scenario("不提供「强行出稿」这个出口") {
    let view = InsufficientState(found: 2, required: 3)
    expect(!view.actions.contains { $0.id == "forceDraft" },
           "给一个强行出稿的按钮，等于这整套承诺没有意义")
}

scenario("提供换一篇和重试，这两个是诚实的出口") {
    let view = InsufficientState(found: 2, required: 3)
    expect(view.actions.contains { $0.id == "retry" }, "")
    expect(view.actions.contains { $0.id == "another" }, "")
}

scenario("已消耗的 token 照实显示") {
    let view = InsufficientState(found: 2, required: 3, tokensUsed: 12_400)
    expect(view.costNote.contains("12"), "花了就是花了，不能藏")
}
```

- [ ] **Step 2–5**：实现，跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
Refuse, and don't offer a way around the refusal

A "draft it anyway" button would make every other guarantee in this product
decorative, so the screen doesn't have one. The honest exits are retrying
and picking a different story. Tokens already spent are shown rather than
hidden — the run cost money even though it produced nothing, and that is
the moment a user most deserves to be told.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: ⑦ 换一篇 + 返回语义分层

**Files:**
- Modify: `ios/Pollux One/Features/ScriptList/ScriptListView.swift`
- Create: `ios/Pollux One/Features/Brief/BriefNavigation.swift`

spec §9.2 ②：「换一篇」的数据源是 **Brief + Script 的合并流**——Brief 在跑的时候还不是 Script，`viewModel.scripts` 装不下它。空状态文案 `"Write a script on the Pollux One web console..."` 在 iOS 优先之后是错的。

spec §8.2 的返回语义：

| 屏 | 返回去哪 | 语义 |
|---|---|---|
| ④ 确认 | ① 相机 | 还没花钱，纯后退 |
| ⑤ 等待 | ① 相机 | **离开**，不是取消 |
| ② 审稿 | ① 相机 | **回不到 ⑤** |
| ⑥ 不足 | ① 相机 | 同上 |

- [ ] **Step 1: 写失败的测试**

```swift
scenario("列表是 Brief 和 Script 的合并流") {
    let rows = ScriptListRows(scripts: [sampleScript()], briefs: [researchingBrief()])
    expect(rows.count == 2, "在跑的 Brief 也要出现在列表里")
}

scenario("在跑的 Brief 显示进度而不是秒数") {
    let rows = ScriptListRows(scripts: [], briefs: [researchingBrief()])
    expect(rows[0].subtitle.contains("调研中"), "")
}

scenario("空状态文案不再让用户去 web 端") {
    let empty = ScriptListEmptyState()
    expect(!empty.text.lowercased().contains("web console"), "iOS 优先之后这句是错的")
    expect(empty.action == .handOff, "空状态该把人送去「交给我」")
}

scenario("审稿页回不到等待页——调研已结束，那一屏不复存在") {
    expect(BriefNavigation.back(from: .review) == .camera, "")
    expect(BriefNavigation.back(from: .review) != .progress, "")
}

scenario("等待页的返回是离开，不销毁任务") {
    let back = BriefNavigation.back(from: .progress)
    expect(back == .camera, "")
    expect(!BriefNavigation.destroysTask(from: .progress), "离开不等于取消")
}

scenario("确认页的返回是纯后退——还没花钱") {
    expect(BriefNavigation.back(from: .confirm) == .camera, "")
    expect(!BriefNavigation.destroysTask(from: .confirm), "")
}
```

- [ ] **Step 2–5**：实现，跑绿，提交。

```bash
git commit -m "$(cat <<'EOF'
Merge briefs into the list, and make every back button mean one thing

A brief that is still researching is not a Script yet, so viewModel.scripts
cannot hold it and the list would silently omit the thing the user is
waiting on. The empty-state copy sending people to the web console was
written before iOS became the primary surface.

Back is a different promise on each screen — a plain step back before any
money is spent, leaving a run that continues in the cloud, and returning
from review to a progress screen that no longer exists. Encoding that as a
function rather than per-screen navigation code is what keeps the third
case from quietly becoming the second.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: 串起来，在真机上走通全程

**Files:**
- Modify: `ios/Pollux One/App/RootView.swift`

- [ ] **Step 1: 接上全部跳转**

相机 →（有稿）审稿 →开拍→ 录制；相机 →（无稿）交给我 → 确认 → 等待 → 审稿。等待页用一个本地定时器推进 fixture 里的阶段，制造出真实的观感。

- [ ] **Step 2: 跑全量测试**

Run: `bash scripts/test-engines.sh`
Expected: 全绿

- [ ] **Step 3: 真机构建并安装**

```bash
cd ios && xcodebuild -project "Pollux One.xcodeproj" -scheme "Pollux One" -destination 'generic/platform=iOS' build
```

- [ ] **Step 4: 逐屏走一遍，对着 mock 核**

七屏都点到，尤其核这四处最容易做错的：左滑按类型分化、虚线下划线的位置、返回语义、未开始阶段不显示 0。

- [ ] **Step 5: 提交**

```bash
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

§0.2 那三样东西目前只活在 fixture 里。不写回 spec，管线建成时就会漏掉。

- [ ] **Step 1: 改 §6.2**，加上证据锚点：⑧ 挂信源除了产出 `sentence_id → claim_ids`，还要产出**字符区间**。同时说明这是从 mock 反推出来的要求。

- [ ] **Step 2: 改 §5**，加上 `mergedAwayCount`：⑤ 交叉验证要保留"被判为转载而归并掉的篇数"，它和 independence 一起构成用户看到的那两个数字。

- [ ] **Step 3: 改 §10**，加上预算模型：`tokens_budget` 已在表里，补上「本月余额」的来源与 ④ 的余额门禁。

- [ ] **Step 4: 改 §12**，记下顺序被推翻这件事，以及质量关只是推迟没有取消。

- [ ] **Step 5: 提交**

```bash
git add docs/superpowers/specs/2026-09-17-news-brief-pipeline-design.md
git commit -m "$(cat <<'EOF'
Write down the three fields the screens turned out to need

Building the UI first against fixtures surfaced three things the pipeline
has no producer for: character ranges for the in-sentence evidence
underlines, the count of reposts merged away, and a monthly budget the
confirm screen gates on. Leaving them in a fixture would mean discovering
them again when the pipeline is finished and it is expensive to change.

Also recorded: the spec's own build order was overruled in favour of
screens first, and the quality gate it describes is postponed rather than
dropped.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## 二、做完之后

- 七个界面在手机上能走通，全程零网络
- 三个新字段已进 spec
- 下一步是接 `docs/superpowers/plans/2026-09-18-brief-live-pipeline.md`，把 `FixtureBriefStore` 换成真实现——**界面一行不用改**，这是 Task 5 那个协议存在的理由
- 接上之后，spec §12 的质量关仍然要过

## 三、明确不在本计划内

- 任何模型调用、任何网络请求
- Share Extension（③ 的「分享进来」先做成一个占位入口）
- 截图输入的视觉理解
- Safe Word 指纹降级（§9.2 ③）——它要等 `script_evidence` 真的有数据
- 落库：全部状态在内存里，杀进程就没了
