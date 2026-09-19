# Brief 六屏视觉对齐 — 设计

> 对应 mock：Claude Design 画布 https://claude.ai/artifact/X3Jiga6RWyGyEhkstrPBEn
> （七块 390×844 画板，源文件在画布的 `project/*.dc.html`）。
> 前置 spec：`2026-09-17-news-brief-pipeline-design.md` §8、§9.2、§10.1。
> 前置计划：`../plans/2026-09-18-brief-ios-on-fixtures.md`。

## 1 · 问题

2026-09-18 的 review 结论：Brief 那七屏**从来没有按 mock 的视觉做过**。差别大不是回归，也不是设计稿理解错了。

原因链在实施计划里能全部找到：

| 事实 | 后果 |
|---|---|
| 计划把 View 定位成「只负责画」，但没给它画什么——全文没有字体、主题、AccentColor，也没有 mock 任何一个底色 hex | View 代码用 `.secondary` / `.quaternary` / `.borderedProminent` 当占位 |
| 从 mock 反推的只有三条：句子左边线三色、左滑按钮 72pt、fixture 数字 | 结构对了，皮全是系统的 |
| 十六个任务的验收全是「测试 0 failed + BUILD SUCCEEDED」；Task 15「逐屏对着 mock 核」的五条全是行为 | 没有任何一条看外观 |
| 实施会话只完整读过 Review 和 Progress 两块画板 | 其余五块按 spec §8 的文字凭空画 |

已在 `a329acc` 修掉的两条不在本 spec 范围内：`AccentColor` 填成 #C49A6C；`CountPill` 中性档拆出 `labelColor` / `labelBackground`。

## 2 · 范围

**做**：② 审稿、③ 交给我、④ 确认、⑤ 等待、⑥ 不建议播、⑦ 换一篇，以及它们共用的顶行 / 按钮 / 卡片。另加一条相机主屏的点击冲突修复（§8）。

**不做**：

- ① 相机 HUD 的重排。它按更早那份设计做的，和 mock 只差两处小的（右下角那格的位置、「说『改这句』」提示胶囊），而且牵涉相机层。
- 口述的真实语音抓取（③ 的 done 态 / 转写）。那是接 `SpeechRecognitionService` 的功能工作，不是视觉。
- ⑥ 的「仍然按现有材料出一稿」。产品决策，`BriefScenarios.swift` 有断言钉着它长不出来。
- 任何 mock 上有、数据里没有的数字（§6 逐屏列出）。**宁可少显示**——这是前一份计划 §0.5 的规矩，这里沿用。

## 3 · 裁决规则

三条，冲突时按顺序：

1. **Domain 的判定不动，配色随便换。** `SentenceStyle` 的映射（观点句永远 neutral、2 个独立源仍是 weak）、`SwipeActions` 的按钮清单与 72pt 宽、`InsufficientState.actions` 的两项、`BriefNavigation` 的返回语义，各有断言。View 层只翻译，不重判。
2. **mock 是视觉的唯一依据**，尺寸、颜色、字号以 `.dc.html` 里的内联 style 为准，不凭印象。
3. **没有数据来源的元素不画。** 不为一个像素去猜产品。要补数据的，写进 §7 作为 Domain 变更，带断言。

## 4 · 主题层

### 4.1 两个文件，一份数值

| 文件 | 依赖 | 内容 |
|---|---|---|
| `ios/Pollux One/Domain/Brief/BriefPalette.swift` | 仅 Foundation | 全部颜色的 `UInt32` hex 与透明度常量。进 `scripts/test-engines.sh`，测试台断言关键值等于 mock |
| `ios/Pollux One/Support/BriefTheme.swift` | SwiftUI | `Color` / `Font` / 圆角 / 间距 token，全部从 `BriefPalette` 派生。六屏的 View 只引用这里，**不出现裸 hex** |

`HUDColor.bronze` 改为 `Color(hex: BriefPalette.accent)`，与 `AccentColor` asset 同源。`SentenceAccent.color` 的三个 hex 从 `SentenceRow.swift` 搬进 palette。

### 4.2 颜色

| 组 | 名 | 值 | 用在 |
|---|---|---|---|
| 底 | canvas | #0D0D0C | 六屏背景、左滑行的遮底 |
| 面 | surface | #161512 | 卡片、新闻卡、按钮面 |
| | surfaceDeep | #131210 | ⑤ token 卡 |
| | input | #0F0E0C | ③ 输入框、④ 拨盘底 |
| | chip | #232019 | 新闻卡里的发布方小标签 |
| | tabActive | #2E2A24 | ③ 选中的 tab |
| | clipboardRow | #1E1C18 | ③ 剪贴板条 |
| 线 | border | #2B2823 | 返回方块、卡片、次级按钮、⑥ 描边 |
| | borderSoft | #262320 | 新闻卡、⑦ 稿卡 |
| | borderDeep | #26231E | ④ 拨盘、⑤ token 卡 |
| | borderInput | #333029 | ③ 输入框 |
| | divider | #1A1917 | ② 底栏上沿 |
| | dividerSoft | #201E1A | ⑤ 卡内分隔、⑦ 进度槽 |
| | rule | #24221F | ③「或者」、⑥ 分隔线 |
| 字 | text1 | #F0EDE7 | 主文字、大数字 |
| | text2 | #C4C0B8 | 次级、信源发布方、观点句正文 |
| | text3 | #9B958B | 三级、说明、图例名 |
| | text4 | #8A847A | 更弱、单位、阶段名（已完成） |
| | text5 | #5A554D | 最弱、时间戳、计数（已完成） |
| | text6 | #4F4A43 | 未开始阶段 |
| | textDisabled | #6E6961 | 禁用按钮文字、⑥「问题在哪」组名 |
| | placeholder | #5E5951 | 输入框占位 |
| 杂 | clipboardBorder | #38332B | ③ 剪贴板条的边 |
| | barTrack | #1F1D19 | ⑤ token 条的槽 |
| | noteBg | #141311 | ⑦ 底部提示条 |
| | pillNeutral | #1E1C19 | ② 中性计数 pill 的底 |
| 主色 | accent | #C49A6C | 主按钮、¥、计时、旋钮、旋转环、字标 |
| | onAccent | #14120F | 主按钮文字 |
| | accentMid | #8A6A45 | token 条第二段 |
| | accentDeep | #574636 | token 条第三段 |
| | accent @ 0.09 / 0.26 | — | 进行中阶段卡的底 / 边 |
| | accent @ 0.13 / 0.20 | — | 旋钮底 / 十字准线 |
| 语义 | strong | #6FA292 | 绿：≥3 独立源；已完成阶段的勾 |
| | weak | #D9A441 | 黄：<3 独立源 |
| | neutralLine | #3A362F | 中性左边线、⑦ 卡内小圆点 |
| | danger | #C4614F | ⑥ 图标、④ 买不起时的读数与斜纹 |
| | deleteBg / onDelete | #6E2F26 / #F5E8E4 | 左滑「删除」 |
| | recheckBg / onRecheck | #2B2823 / #C4C0B8 | 左滑「重查」 |
| | brokeBg / brokeText | #3A2A26 / #E3A99B | ④「余额不够，去充值」 |
| | cancelText | #7A6058 | ⑤「取消调研」 |
| 拨盘 | dialGrid | #1A1815 | 三分网格 |
| | dialBracket | #34302A | 四角括号 |
| | dialScale | #423D36 | 6:00 / 0:30 |
| | dialAxis | #4E4841 | 八卦 / 专业 |
| | presetOff / presetLabel | #6B655C / #857F75 | 推荐档位空心圆 / 文字 |
| | pendingRing | #2E2B26 | ⑤ 未开始阶段的空心圆 |

### 4.3 字体

| 用途 | 字体 | 落地 |
|---|---|---|
| 中文正文、标题、标签 | 系统 PingFang SC（`.system`） | 不打包。mock 的 Noto Sans SC 三个字重约 25–30MB，手机上与苹方几乎分不出 |
| **所有数字**：时长、token、¥、时间戳、计数、时钟 | IBM Plex Mono 400 / 500 | 打包 `Resources/Fonts/IBMPlexMono-Regular.ttf`、`IBMPlexMono-Medium.ttf`、`OFL.txt`；启动时 `CTFontManagerRegisterFontsForURL` 注册；不碰 Info.plist |

`BriefTheme.mono(size, weight)` 在注册失败时退回 `.system(size:, design: .monospaced)`，界面永不因为字体崩。`monospacedDigit()` 不再用于这六屏——数字整体换字体，不只是等宽数字。

### 4.4 尺寸

| token | 值 |
|---|---|
| 页边 | 24 |
| 顶行 | 贴安全区顶部（mock 56 ≈ Dynamic Island 机型的 59） |
| 底部动作区 | 距物理底边 40，忽略 home indicator 的安全区 |
| 卡片圆角 | 14；次级 13 / 12 / 11 / 10 / 9 按 mock 逐处标 |
| 主按钮 | 圆角 14，内边距 19，17pt 700，accent 底 onAccent 字 |
| 次级按钮 | 圆角 13，内边距 16，15pt，border 描边，text3 字 |
| 返回方块 | 36×36，圆角 9，border 描边，chevron 17pt / 2.2 描边 text3 |
| 新闻卡 | 圆角 9，surface 底 borderSoft 边，内边距 8 / 10；chip 10.5pt text3；标题 13pt text2 单行截断；有 url 才有 chevron |
| 标签 chip | 圆角 4 |
| 胶囊 | 999 |

## 5 · 共用组件

放 `ios/Pollux One/Features/Brief/Chrome/`：

| 组件 | 职责 |
|---|---|
| `BriefTopRow(onBack:) { trailing }` | 返回方块 + 任意尾部内容（新闻卡 / 标题 / 计时 / 字标）。每屏自己放一个，`BriefFlow.backBar` 删掉。返回**去哪**仍由 `BriefNavigation.back(from:)` 定，这里只负责画 |
| `NewsTagCard(news:)` | 替换 `NewsTag`。有 `url` 才显示 chevron，点了 `openURL`；没有就只是一张静态卡 |
| `PrimaryButton(title, icon?, tone, size, isEnabled, action)` | 青铜主按钮；`isEnabled == false` 时 border 色（#2B2823）底 + textDisabled 字（③ 的空输入态）；`tone: .broke` 时 brokeBg / brokeText（④ 余额不够）；`size: .compact` 是 ③ 卡片内那枚（15pt / 内边距 15 / 圆角 11） |
| `SecondaryButton(title, action)` | 描边次级按钮 |
| `TextLinkButton(title, tint, action)` | ⑤ 取消那种一行灰字 |
| `StageSpinner(size, stroke)` | 青铜旋转环，替换系统 `ProgressView`（⑤、⑦） |

`BriefFlow.briefLayer` 背景改 `BriefTheme.canvas`，不再是 `Color(.systemBackground)`。

## 6 · 逐屏

每屏三段：结构、只在这一屏出现的 token、不画的与原因。

### ② 审稿 `ReviewView`

结构已对，只换皮。

- 顶行：返回 + `NewsTagCard`。
- 读数行：29pt mono text1「83」+ 13pt text4「秒 · 按你的语速」（`pacedToUser` 为假时仍只写「秒」）；右侧三枚胶囊 11.5pt mono，strong / weak 各自 13% 底，neutral 用 `labelBackground`（a329acc 已定）。
- 句子行：左边线 2pt，`margin-left 22` + `padding-left 12`，正文 16.5pt、行框约 27pt（`lineSpacing` 5）。观点句：**虚线**左边线（画 dash，不是 50% 透明的实线）、斜体、text2；脚注「你的判断 · 无信源」11pt mono text4。锚点下划线保持 `.dot`，色随 accent。
- 展开证据的行：整行底色 `accent.opacity(0.05)`（绿句绿底、黄句黄底）；证据行 publisher 12pt text2 最小宽 62、note 11.5pt text3、time 10.5pt mono text5；末行「另有 N 篇…」11pt text5。
- 左滑：重查 recheckBg / onRecheck，删除 deleteBg / onDelete，图标 16 + 文字 11.5。宽度不动。
- 底栏：上沿 1pt divider；54pt 宽描边方块（交换图标 18pt text3）+ 主按钮「开拍」带 19pt 摄像机图标。
- 重查三态的文案与位置不动，只换字体色值。

不画：无。

### ③ 交给我 `HandOffView`

- 顶行：返回 + 居中字标「POLLUX ONE」14pt 700、字距 0.04em、accent；右侧留空对称。
- 标题「今天播什么？」30pt 700，行高 1.3，字距 -0.015em；顶行下 36。
- 卡片（surface 底 border 边圆角 14）：
  - tab 条：底 `black.opacity(0.22)`，内边距 5，间距 4；tab 圆角 9、13pt 500；选中 tabActive 底 text1 字，未选中透明 text4。**替换系统 segmented picker。**
  - 打字档：剪贴板条（clipboardRow 底、clipboardBorder 边、圆角 9；图标 14 + 剪贴板内容单行截断 13.5pt text2 + 右侧「用」13pt 500 accent）→ 输入框（input 底 borderInput 边圆角 10，14.5pt 行高 1.6，占位 placeholder 色「贴链接，或写一句『某某公司又裁员了』」，最小高约 110）→ **主按钮「开始调研」在卡片内**，空输入时禁用态。
  - 口述档：见下。
- 「或者」分隔：两条 1pt rule 夹 11.5pt text4，卡片下 22。
- 并列两枚描边按钮「上传截图 / 分享进来」：surface 底 border 边圆角 12，图标 19 + 14.5pt 500 text1，内边距 16 / 14。
- 底部不再有单独的「开始调研」——它进了卡片，而且**只在打字档出现**。

口述档只有两个视觉态，由 `HandOffState.voicePhase`（§7）驱动：

| 态 | 画什么 |
|---|---|
| idle | 68pt accent 圆 + 27pt 麦克风图标（onAccent 描边）；下方 13.5pt text3 示例「『央行降准那条，我想从房贷角度切』」 |
| listening | 同一个圆，外圈 `accent.opacity(0.35)` 呼吸光晕；圆内五根 3pt 宽的 onAccent 竖条按 mock 的相位起伏；点圆回到 idle |

不画：done 态（转写 + 「重说 / 就查这个」）。没有语音抓取就没有转写，一行占位文案都不编。

**口述档在本 spec 里没有提交出口。** 现状是口述档底下也有「开始调研」，按下去用「口述的一条新闻」这个假标题往下走——那条路的终点本来就是假的。mock 的出口「就查这个」只在 done 态出现，而 done 态要等语音抓取。所以 `canProceed` 在 `.speaking` 档一律为假（§7），用户要往下走就切回打字档。这是一个诚实的死路，比一个假的活路好。

### ④ 确认 `ConfirmView` + `DialControl`

- 顶行：返回 + `NewsTagCard`。读数行**删掉**——读数进盘内。
- 拨盘 pad：高 372，圆角 14，input 底 borderDeep 边，页边 24。内部全部绝对定位：
  - 三分网格 dialGrid 1pt；四角括号 13×13、1.5pt dialBracket、内缩 10。
  - 左上 32pt「6:00」、左下 32pt「0:30」，10.5pt mono dialScale；左下 12pt「八卦」、右下 12pt「专业」，10.5pt dialAxis。
  - 十字准线过旋钮，1pt `accent.opacity(0.20)`。
  - 旋钮 46×46，圆角 4，1.5pt 描边，`accent.opacity(0.13)` 底，中心 5pt 圆点。买不起时描边、圆点、读数全部换 danger。
  - 右上 13 / 12：时钟 21pt mono 字距 -0.01em「1:00」+ 12.5pt 档位名。
  - 两个推荐档位：9pt 圆（选中时 accent 实心，否则 presetOff 空心），44×44 命中区；文字 10.5pt presetLabel「1:00 通俗」在圆右、「3:00 偏专业」在圆左。
  - **买不起的斜纹带**：对每一档时长，从 `DialState.maxAffordableRegister(durationSec:)`（§7）算出最右可达位置，其右侧一整条画 135° 斜纹 `repeating-linear-gradient(rgba(196,97,79,0.13) 0–4, rgba(13,13,12,0.55) 4–9)`。整行都买得起的档不画。
- 拨盘下 12pt 一行：右侧 11.5pt mono「≈120K · ¥0.35」text4；买不起时「超出余额 ≈120K · ¥0.35」danger。左侧留空。
- 差额一句「这一篇大约要 120K，你只剩 80K」保留在按钮上方，12.5pt mono danger，只在买不起时出现。
- 主按钮：买得起「开始调研」；买不起「余额不够，去充值」brokeBg / brokeText，`disabled`。

档位：时长保持 `DialState.durationSteps` 八档；调性五档名「八卦 / 通俗 / 平实 / 偏专业 / 专业」（§7）。

不画：「N 源 · N 事实点」。`DialState.estimate` 只有 token 与成本，源数和事实点数没有来源。

### ⑤ 等待 `BriefProgressView`

- 顶行：返回 + `NewsTagCard` + 右侧计时 14pt mono accent。
- token 卡：surfaceDeep 底 borderDeep 边圆角 14，内边距 20 / 18 / 18，间距 16。
  - 首行：40pt mono text1 字距 -0.03em 行高 1 + 12.5pt text4「tokens」；右侧 ¥ 17pt mono accent。
  - 条：高 11 圆角 3，槽 #1F1D19；三段按 `TokenBar` 排序依次 accent / accentMid / accentDeep；25% / 50% / 75% 处 1pt canvas 刻度线。
  - 图例：7pt 方点圆角 2 + 阶段名 11.5pt text3 + **数值** 11.5pt mono text2。只列 token 最多的前三段——第四段起在 11.5pt 上排不下，条本身把所有段都画了。数值 ≥1000 写 `38.1K`（千为单位一位小数），否则写原数。
  - 1pt dividerSoft。
  - 「预算 120K · 已用 40%」「本月余额 2.41M」11.5pt text4，数字部分 mono text3。
- 阶段列表，每行内边距 9 / 0，间距 13：
  - done：16pt 勾 strong 2.5 描边；名 14pt text4；计数 11.5pt mono text5。
  - running：整行升成卡片——`accent.opacity(0.09)` 底、`accent.opacity(0.26)` 边、圆角 11、内边距 13 / 15、外边距 5 / 0；`StageSpinner` 16pt 2.5 描边 accent；名 14pt 500 text1；计数 11.5pt mono accent；下方 detail 12.5pt text3 行高 1.55 左缩 29。
  - pending：16pt 空心圆 1.5pt pendingRing；名 14pt text6；无计数。
- 底部：`SecondaryButton`「退出，好了通知我」；`TextLinkButton`「取消调研 · 已消耗的 48K 不退」12pt cancelText。

不画：无。

### ⑥ 不建议播 `InsufficientView`

- 顶行：只有返回。
- 正文区间距 24：26pt 警告图标 danger 2pt 描边 → 标题 25pt 700 行高 1.4，文字是 `InsufficientState.title`「这条我不建议你现在播」（mock 原话；spec §5.1 说产品必须敢说这句）→ 14.5pt text3 行高 1.68（`insufficientReason`，nil 则整段不出现）。
- 1pt rule。
- 「问题在哪」12pt textDisabled 字距 0.08em 500；一张卡（surface 圆角 11 内边距 15 / 16）：首行 15pt mono danger「`state.found` / `state.required`」+ 13.5pt 500 text1 现有 `headline`；次行 12.5pt text3 `costNote`。
- 底部：第一个 action 走 `PrimaryButton`，第二个走 `SecondaryButton`。按钮清单仍从 `InsufficientState.actions` 长出来。

不画：「14 → 2」的归并卡（没有总篇数）、两家互相打架的引文卡（`ClaimEvidence` 没有冲突表示）、「官方通报通常 2–6 小时内落地」提示条与「帮我盯着」按钮（没有这个动作）。这三样等 `2026-09-18-brief-live-pipeline.md` 把 `conflicted` claim 送到 iOS 之后另开 spec。

### ⑦ 换一篇 `ScriptListView`

- **拆掉** `NavigationStack`、`.navigationTitle("Pollux One")`、`.toolbar`。屏由 `BriefFlow` 盖上来，导航只有一层。`.refreshable` 保留，挂在外层 `ScrollView` 上。
- 顶行：返回 + 19pt 700「换一篇」。
- 顶行下 22：`PrimaryButton`「从一条新闻开始」带 18pt 加号 → `.handOff`。替代原工具栏「+ 交给我」。
- 「正在调研」组（组名 11.5pt text4 字距 0.06em，组内间距 11）：卡 surface 底 `accent.opacity(0.26)` 边圆角 12 内边距 15 / 16——`StageSpinner` 14pt + 标题 14.5pt text1 单行截断；次行左「交叉验证 9 / 23」11.5pt mono text3，右「48K · 04:12」11.5pt mono text4；底 3pt 进度槽 dividerSoft、已完成阶段比例 accent。点击 → `ScriptSlot(brief:).destination`。
- 「可以拍了」组：卡 surface 底 borderSoft 边圆角 12 内边距 14 / 15——标题 15pt text1 单行截断；次行 11.5pt mono：秒数 text2（只有 `.ready` 的 Brief 和 Web 稿有秒数）· 3pt neutralLine 圆点 · 「5 绿」strong · 「1 黄」weak（为 0 的不写）。Brief 卡点击 → `ScriptSlot(brief:).destination`；Web 稿卡点击 → `onSelectScript(script)`，`BriefFlow` 把它记成 `selectedScript` 交给根上的 `RecordingView`，后者的 `.task(id: script?.id)` 走一次 `prepare(script:)`，屏回相机。**不再 push 第二个 `RecordingView`**。
- 信源不足的 Brief 单列第三组「信源不足」，同稿卡样式、danger 边，点击 → `.insufficient`。mock 没画这一态（画布上没有信源不足的稿），样式是从稿卡沿用的，不是新设计。
- 底部提示条：#141311 底圆角 10，14pt chevron + 12pt text4「点一篇直接载入提词器，相机已经在等着了。」
- 空状态：`PrimaryButton` + 同款提示条写 `ScriptListEmptyState.text`。

不画：「2 小时前」相对时间（`Brief` 没有时间戳）、Web 稿旁的独立编辑方块（Web 稿在 Web 编辑，Brief 卡点进去就是审稿）。

## 7 · Domain 变更

全部纯 Foundation，全部进 `scripts/test-engines.sh` 与 `BriefScenarios.swift`：

| 变更 | 断言 |
|---|---|
| 新建 `BriefPalette`：§4.2 全部 hex 为 `UInt32` | accent == 0xC49A6C、strong == 0x6FA292、weak == 0xD9A441、neutralLine == 0x3A362F、canvas == 0x0D0D0C；三个语义色与 `SentenceAccent` 一一对应 |
| `DialState.maxAffordableRegister(durationSec:) -> Double?`：该档时长下余额能买到的最大 register；整行买得起返回 nil；register 0 也买不起返回 0 | 单调：时长越长返回值不增；边界处 `estimate.tokens <= remaining`，再加 0.01 则超过；`remainingTokens == .max` 时全部 nil |
| `DialState.registerName`：`Int((register * 4).rounded())` → 「八卦 / 通俗 / 平实 / 偏专业 / 专业」 | 0 → 八卦、0.25 → 通俗、0.5 → 平实、0.7 → 偏专业、1 → 专业 |
| `snap(.casualMinute)` 的 register **0.0 → 0.25** | 两个锚点的 `registerName` 分别是「通俗」「偏专业」（spec §2.2 的原话） |
| `HandOffState.voicePhase: HandOffVoicePhase = .idle`（`idle / listening`）、`mutating toggleListening()`；`mode` 切到 `.typing` 时 `voicePhase` 自动回 idle；`canProceed` 在 `.speaking` 档**一律为假**（直到语音抓取接上） | 切到打字档自动回 idle；打字档没有「听」；speaking 档 idle 与 listening 都不能开始；打字档有非空文字才能开始 |
| `InsufficientState` 增 `found` / `required` 存储属性，与 `static let title = "这条我不建议你现在播"` | found 2、required 3；title 与 mock 一字不差 |
| `ScriptListRow` 去掉 `subtitle`，增 `seconds: Int?`、`strong: Int`、`weak: Int`、`stageLine: String?`、`tokensUsedK: Int?`、`progress: Double?`、`status: BriefStatus?`、`group: ScriptListGroup`；`build` 用 `SentenceCounts` 算绿黄 | fixture 那篇：seconds 83、strong 2、weak 1、group `.ready`；调研中那篇 seconds nil、stageLine「交叉验证 9 / 23」、tokensUsedK 48、progress 4/9、group `.researching`；Web 稿 group `.ready`、strong 0 |

`HandOffView` 的 `onSubmit` 只会从打字档、带非空文字被调用。`BriefFlow` 里给空文字兜底的「口述的一条新闻」随之成为死代码，一并删掉。

**不动**：`SentenceStyle`、`SwipeActions`、`InsufficientState.actions`、`BriefNavigation`、`ScriptSlot`、`durationSteps`。

## 8 · 相机主屏：控件必须拥有自己的点击

已确认的症状：录制中翻转键被 `.disabled` 之后，点它会穿透到相机预览的 `onTapGesture`，触发对焦并弹对焦框。

规则一句话：**HUD 上的每个控件，在任何状态下都吞掉落在自己身上的点击。** 对焦只响应落在裸画面上的点。

| 处 | 改法 |
|---|---|
| `FlipButton` | 命中区放大到 ≥44×44（`contentShape`）；禁用态外层 `.contentShape(Rectangle()).onTapGesture {}` 吞掉点击，视觉仍是 35% 透明 |
| `SafeWordIndicatorView` | 它是仪表不是按钮，但也是控件带——同样 ≥44×44 命中区并吞掉点击 |
| `ScriptSlotView`（60×60）、`RecordButton`（74） | 已 ≥44，不改 |
| 参数行、镜头药丸 | 不改。命中区略小于 44，但没有误触报告，放大它们要动 HUD 尺寸，超出本 spec |
| `RecordingView` | 不动。不做整片禁焦区——画面下三分之一仍然可以对焦 |

验收只能真机 / 模拟器：录制中点翻转键，不出对焦框；点电平表，不出对焦框；点两者旁边 8pt 以外的画面，正常对焦。

## 9 · 测试与验收

| 层 | 怎么验 | 门 |
|---|---|---|
| Domain（§7） | `bash scripts/test-engines.sh` | `0 failed`，且总数比现在多 |
| 编译 | `xcodebuild -destination 'generic/platform=iOS' build` | `BUILD SUCCEEDED` |
| 字体 | 构建产物里有两个 `.ttf`；`UIFont(name: "IBMPlexMono", size: 12) != nil` 在启动日志打一行 | 两条都真 |
| 视觉 | 模拟器逐屏截图与画布并排，按下表勾 | 每屏每条 |

视觉清单（每屏都核的四条 + 各屏特有的）：

- 通用：背景 #0D0D0C 不是纯黑；没有系统蓝；返回是 36×36 描边方块没有文字；所有数字是 Plex Mono。
- ②：观点句是虚线边；展开行有 5% 底；「开拍」青铜；底栏有分隔线。
- ③：字标 + 大标题 + 卡片 + 「或者」；tab 是胶囊不是系统 segmented；「开始调研」在卡片里且空输入时是禁用态；口述 idle / listening 两态切换。
- ④：372pt 方盘；十字准线随旋钮；两个推荐档位文字正确；把 `remainingTokens` 调到 60K 后右下出现斜纹且按钮变暗红不可点。
- ⑤：三段青铜条 + 刻度；进行中阶段是卡片；勾是绿的；计时青铜。
- ⑥：图标红；「问题在哪」一张卡；两个按钮一主一次。
- ⑦：没有「Pollux One」大标题；两组卡片；点 Web 稿回到相机且提词块出现，不出现第二个相机。
- §8 三条。

**验收数据**：先用 `brief-fixture.json`；`Resources/demo-briefs/` 落地后（另一个 worktree 在产 5 篇）再跑一遍清单——七屏有真内容时对得更准。

## 10 · 实施顺序

1. 主题层 + 字体 + `BriefPalette` 断言（其余一切的地基）。
2. 共用组件 + `BriefFlow` 去掉 `backBar`、换背景。
3. ② → ⑤ → ⑥（结构已对，换皮为主）。
4. ④ 拨盘（含 Domain 两条）。
5. ③ 交给我（含 `voicePhase`）。
6. ⑦ 换一篇（含 `ScriptListRow` 扩字段、拆导航、`onSelectScript`）。
7. §8 相机点击冲突。
8. 逐屏清单。

前置条件：模拟器运行时缺失（Xcode 27 下 `simctl list runtimes` 为空），步骤 8 之前需要 `xcodebuild -downloadPlatform iOS`；pollux 的手机当前 unavailable。1–7 不依赖它们。

## 11 · 明确不做

- 浅色模式（app 强制深色，`BriefTheme` 不做 Environment 注入）
- Noto Sans SC 打包
- ① 相机 HUD 重排
- 口述的转写、done 态，以及口述档的提交出口（等语音抓取接上）
- ⑥ 的冲突卡、归并卡、「帮我盯着」
- 任何 `SentenceStyle` / `SwipeActions` / `InsufficientState.actions` 的判定改动
