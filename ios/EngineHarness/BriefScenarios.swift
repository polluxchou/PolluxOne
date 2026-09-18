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

    return (report.pass, report.fail)
}
