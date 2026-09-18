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

    return (report.pass, report.fail)
}
