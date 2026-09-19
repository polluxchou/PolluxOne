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

    // s3 的锚点修过一次：8/6 切出的是「金约 1 万」——跨在词尾、还劈开了数字。
    // 把它和 s4 一起钉死，免得下次错位又绿着过去。
    let s3Runs = AnchorRuns(brief.sentences[2])
    let s3Marked = s3Runs.segments.compactMap { $0.claimId == nil ? nil : $0.text }
    report.check(s3Runs.segments.map(\.text).joined() == brief.sentences[2].text,
                 "s3 拼回去逐字相同")
    report.check(s3Marked == ["约 1 万亿元"], "s3 的锚点切出整个数字，不劈开",
                 detail: s3Marked.joined(separator: " / "))

    let s4Runs = AnchorRuns(brief.sentences[3])
    let s4Marked = s4Runs.segments.compactMap { $0.claimId == nil ? nil : $0.text }
    report.check(s4Runs.segments.map(\.text).joined() == brief.sentences[3].text,
                 "s4 拼回去逐字相同")
    report.check(s4Marked == ["10 个基点"], "s4 的锚点",
                 detail: s4Marked.joined(separator: " / "))

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

    report.section("§8.1 重查")
    // s4 挂的 c3 只有 1 个源，fixture 的 recheckResults 里有它 → 查得到新的。
    let improvedOutcome = brief.recheckOutcome(forSentence: "s4")
    report.check(improvedOutcome != .unchanged && improvedOutcome != .notApplicable,
                 "弱信源那句重查得到新信源", detail: "\(improvedOutcome)")
    if case .improved(let found) = improvedOutcome {
        report.check(found.id == "c3", "换回来的是同一条 claim", detail: found.id)
        report.check(found.independence == 2, "独立源从 1 变 2", detail: "\(found.independence)")
        report.check(found.sources.count == found.independence,
                     "列出的行数仍等于独立源数")
    }

    let afterRecheck = brief.applyingRecheck(forSentence: "s4")
    report.check(afterRecheck.claims["c3"]?.independence == 2,
                 "applyingRecheck 把新证据写了回去",
                 detail: "\(afterRecheck.claims["c3"]?.independence ?? -1)")
    report.check(afterRecheck.sentences == brief.sentences, "重查不动句子，只动证据")
    report.check(afterRecheck.claims["c1"] == brief.claims["c1"], "没重查的 claim 原样不动")
    report.check(EvidenceLabel(brief.claims["c3"]!).text == "仅 1 个信源",
                 "重查之前标签是「仅 1 个信源」")
    report.check(EvidenceLabel(afterRecheck.claims["c3"]!).text == "2 个独立信源",
                 "重查之后标签改口，并且说的是独立信源")
    report.check(!EvidenceLabel(afterRecheck.claims["c3"]!).isWarning,
                 "不再是「仅」那个警告")
    // 2 个源还不到 3，颜色留在黄——绿是 3 个独立源才配有的，
    // 重查有收获不等于这句话已经站得住。
    report.check(SentenceStyle(sentence: brief.sentences[3], claims: afterRecheck.claims).accent == .weak,
                 "2 个源还没到 3，颜色仍是黄")

    // s3 挂的 c1 不在 recheckResults 里 → 另一条路径：查了，没有新的。
    report.check(brief.recheckOutcome(forSentence: "s3") == .unchanged,
                 "recheckResults 里没有条目 = 没找到新信源")
    report.check(brief.applyingRecheck(forSentence: "s3") == brief,
                 "没找到新信源就原样返回，不假装动过")

    // 观点句/钩子句没有事实点可查。SwipeActions 本来就不给它们露按钮，
    // 但绕过按钮问到这里也只能是一个没反应。
    report.check(brief.recheckOutcome(forSentence: "s5") == .notApplicable,
                 "观点句没有可重查的事实点")
    report.check(brief.recheckOutcome(forSentence: "s1") == .notApplicable,
                 "钩子句同样没有")
    report.check(brief.recheckOutcome(forSentence: "不存在的句子") == .notApplicable,
                 "句子已经被删掉也不崩")
    report.check(brief.applyingRecheck(forSentence: "s5") == brief,
                 "无事实点时原样返回")

    // 重查只能让信源变多。上游给回一个更小的 independence 是数据错误，
    // 界面绝不能因此显示「重查之后信源反而变少了」。
    if let downgraded = briefWithRecheckResult(brief,
                                               claimId: "c3",
                                               independence: 0,
                                               sources: []) {
        report.check(downgraded.recheckResults?["c3"]?.independence == 0,
                     "构造出了一份「重查后变少」的坏数据")
        report.check(downgraded.recheckOutcome(forSentence: "s4") == .unchanged,
                     "重查只能让信源变多——更小的独立源数一律拒收")
        report.check(downgraded.applyingRecheck(forSentence: "s4").claims["c3"]?.independence == 1,
                     "被拒收之后 claim 保持原样，不会被改小",
                     detail: "\(downgraded.applyingRecheck(forSentence: "s4").claims["c3"]?.independence ?? -1)")
    } else {
        report.check(false, "构造「重查后变少」的坏数据")
    }
    // 持平不是变少，仍然算查到了（同一条证据被再次确认）。
    if let flat = briefWithRecheckResult(brief,
                                         claimId: "c3",
                                         independence: 1,
                                         sources: brief.claims["c3"]!.sources) {
        report.check(flat.recheckOutcome(forSentence: "s4") != .unchanged,
                     "独立源数持平不算变少")
    }

    report.section("④ 成本估算按高峰价，只会高不会低")
    report.check(DialState.costCents(forTokens: 1_000_000) == 415,
                 "每百万 token 415 分 = 0.80×200 + 0.15×800 + 0.05×2700",
                 detail: "\(DialState.costCents(forTokens: 1_000_000))")
    report.check(DialState.costCents(forTokens: 1) == 1,
                 "再小也不报 0 —— 跑一次就是要花钱的")
    report.check(DialState.costCents(forTokens: 1_000_000) >= 415 / 2,
                 "按高峰估，覆盖得住空闲时段的实际花费")

    var cheapDial = DialState()
    cheapDial.snap(to: .casualMinute)
    var proDial = DialState()
    proDial.snap(to: .professionalThreeMinutes)
    report.check(proDial.estimate.costCents > cheapDial.estimate.costCents,
                 "3 分钟偏专业比 1 分钟通俗贵",
                 detail: "\(cheapDial.estimate.costCents) → \(proDial.estimate.costCents)")

    return (report.pass, report.fail)
}

/// 把 brief 编码回 JSON、换掉 `recheckResults`、再解回来。
/// `recheckResults` 是 `let`，构造坏数据只能走这条路——而这恰好也是真管线
/// 将来把数据递进来的那条路，所以这份坏数据是可能真的出现的那一种。
@MainActor
func briefWithRecheckResult(_ base: Brief,
                            claimId: String,
                            independence: Int,
                            sources: [SourceRef]) -> Brief? {
    guard let encoded = try? JSONEncoder().encode(base),
          var raw = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    else { return nil }
    raw["recheckResults"] = [
        claimId: [
            "id": claimId,
            "independence": independence,
            "mergedAwayCount": 0,
            "sources": sources.map { ["publisher": $0.publisher, "note": $0.note, "time": $0.time] }
        ]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
    return try? JSONDecoder().decode(Brief.self, from: data)
}
