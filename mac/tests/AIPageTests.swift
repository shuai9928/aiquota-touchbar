import AppKit

/// AI 页（触控栏展开后的第一页）和它的对话页、额度页：额度表写什么、对话区放谁、「对话」入口说什么、位置固定、页面往返
enum AIPageTests {
    @MainActor
    static func run(now: Date, check: (Bool, String) -> Void) {
        func window(_ label: String, _ used: Double, _ length: TimeInterval, left: TimeInterval?, at: Date = now) -> QuotaWindow {
            QuotaWindow(label: label, short: "", used: used, resetsAt: left.map { at.addingTimeInterval($0) }, length: length)
        }
        func provider(_ name: String, five: Double, week: Double?, fiveLeft: TimeInterval = 3 * 3600, weekLeft: TimeInterval = 4 * 86400,
                      updated: Date? = nil) -> Provider {
            var windows = [window("5小时", five, 5 * 3600, left: fiveLeft)]
            if let week { windows.append(window("本周", week, 7 * 86400, left: weekLeft)) }
            return Provider(name: name, windows: windows, updatedAt: updated ?? now)
        }
        let nameFont = TouchBarArt.nameFont, numFont = TouchBarArt.numFont, subFont = TouchBarArt.subFont
        func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }

        // ---------- 额度表：只写正卡着你的那个窗口 ----------
        let calm = QuotaLine.make(provider("Claude", five: 38, week: 61), now: now)
        check(calm.tag == nil && calm.pct == "38%" && calm.level == .calm && calm.note.hasSuffix("重置") && !calm.note.contains("约"), "平时写 5 小时：百分比、重置时间，白色，不写「约」")
        let tight = QuotaLine.make(provider("Claude", five: 38, week: 98, weekLeft: 2 * 86400), now: now)
        check(tight.tag == "每周" && tight.pct == "98%" && tight.level == .full, "每周 ≥80% 就换成每周，写「每周」，红色")
        // 临界值：80 换、79 不换；90 红、89 不红
        check(QuotaLine.make(provider("Claude", five: 38, week: 80), now: now).tag == "每周" && QuotaLine.make(provider("Claude", five: 38, week: 79), now: now).tag == nil,
              "每周恰好 80% 换成每周，79% 不换")
        check(QuotaLine.make(provider("Claude", five: 38, week: 90, weekLeft: 6 * 86400), now: now).level == .full
              && QuotaLine.make(provider("Claude", five: 38, week: 82, weekLeft: 1 * 86400), now: now).level != .full, "每周 90% 起红色，82% 还不红")
        // 5 小时已经用完（正挡着你）时它比每周紧：只有每周也用完了才写每周
        check(QuotaLine.make(provider("Claude", five: 100, week: 92), now: now).tag == nil && QuotaLine.make(provider("Claude", five: 100, week: 99), now: now).pct == "100%",
              "5 小时用完而每周 92%/99%：还写 5 小时 100%，看得出正被挡着")
        let bothFull = QuotaLine.make(provider("Claude", five: 100, week: 100), now: now)
        check(bothFull.tag == "每周" && bothFull.level == .full && bothFull.note.hasSuffix("恢复"), "5 小时和每周都用完了：写每周（等得更久）")
        let fiveFull = QuotaLine.make(provider("Claude", five: 100, week: 61), now: now)
        check(fiveFull.tag == nil && fiveFull.pct == "100%" && fiveFull.note.hasSuffix("后恢复") && fiveFull.level == .full, "5 小时用完而每周有余量：写 5 小时和多久后恢复")
        let quick = QuotaLine.make(provider("Codex", five: 62, week: 18, fiveLeft: 3.5 * 3600), now: now)
        check(quick.level == .fast && quick.note.hasSuffix("用完"), "5 小时用得比时间快：橙色，写照这速度几点用完")
        check(QuotaLine.make(provider("Claude", five: 38, week: 85, weekLeft: 6 * 86400), now: now).tag == nil
              || QuotaLine.make(provider("Claude", five: 38, week: 85, weekLeft: 6 * 86400), now: now).level != .calm, "每周 85% 且用得比时间快：不会还是平静的白色")
        // 没有每周的重置时间（用户没填 claudeWeeklyReset）：不写备注，不写「未设置重置时间」
        var weekNoReset = provider("Claude", five: 38, week: 98)
        weekNoReset.windows[1].resetsAt = nil
        weekNoReset.windows[1].note = "未设置重置时间"
        let noReset = QuotaLine.make(weekNoReset, now: now)
        check(noReset.tag == "每周" && noReset.note.isEmpty, "每周不知道重置时间：只写「每周 98%」，不写放不下的长句")
        // 标签看窗口自己的名字，不看它排第几：Codex 只返回一个每周窗口时，写「每周」而不是被读成 5 小时
        let onlyWeek = QuotaLine.make(Provider(name: "Codex", windows: [window("本周", 98, 7 * 86400, left: 2 * 86400)], updatedAt: now), now: now)
        check(onlyWeek.tag == "每周" && onlyWeek.pct == "98%", "只有一个「本周」窗口：也写「每周」")
        let onlyToday = QuotaLine.make(Provider(name: "Codex", windows: [window("今天", 50, 86400, left: 6 * 3600)], updatedAt: now), now: now)
        check(onlyToday.tag == "今天", "别的长窗口（今天、30天）写它自己的名字")
        // 过期、没数据、出错
        let stale = QuotaLine.make(provider("Claude", five: 38, week: 61, updated: now.addingTimeInterval(-80 * 60)), now: now)
        check(stale.level == .dim && stale.note == "更新于1时前" && stale.tag == nil, "数据过期：整行变灰，写多久没更新（只写最大一级），不配颜色")
        check(QuotaLine.make(provider("Claude", five: 38, week: nil, updated: now.addingTimeInterval(-40 * 3600)), now: now).note == "更新于1天前", "过期一天以上写天")
        check(QuotaLine.make(provider("Claude", five: 38, week: nil, updated: now.addingTimeInterval(-8 * 60)), now: now).note == "更新于8分前", "过期不到一小时写分钟")
        var noStamp = provider("Claude", five: 38, week: nil)
        noStamp.updatedAt = nil
        check(QuotaLine.make(noStamp, now: now).pct == "–" && QuotaLine.make(noStamp, now: now).note == "暂无数据", "有窗口但没有更新时间：当作没数据")
        let none = QuotaLine.make(Provider(name: "Claude"), now: now)
        check(none.pct == "–" && none.note == "暂无数据" && none.level == .dim, "没有数据：横线加「暂无数据」，不再写 0%")
        check(QuotaLine.make(Provider(name: "Codex", error: "登录失效"), now: now).note == "出错", "出错：写出错")
        // 星期从重置时间算出来，不写死：2026-10-09 是周五，前面 2~6 天不管哪天看都是「周五」
        var friday = DateComponents()
        friday.year = 2026; friday.month = 10; friday.day = 9; friday.hour = 5
        let reset = Calendar.current.date(from: friday)!
        check((2...6).allSatisfy { Fmt.dayShort(reset, now: reset.addingTimeInterval(-Double($0) * 86400 - 3 * 3600)) == "周五" }, "前 2~6 天看，都写「周五」")
        check(Fmt.dayShort(reset, now: reset.addingTimeInterval(-3600)) == "05:00" && Fmt.dayShort(reset, now: reset.addingTimeInterval(-86400)) == "明天"
              && Fmt.dayShort(reset, now: reset.addingTimeInterval(-86400 * 9)) == "10/9", "今天写时分、明天、超过一周写日期")
        let near = QuotaWindow(label: "本周", short: "", used: 40, resetsAt: reset, length: 7 * 86400)
        check(QuotaLine.longNote(near, now: reset.addingTimeInterval(-2 * 86400 - 3600)) == "周五重置", "每周的备注：周五重置")
        let full = QuotaWindow(label: "本周", short: "", used: 100, resetsAt: reset, length: 7 * 86400)
        check(QuotaLine.longNote(full, now: reset.addingTimeInterval(-3 * 86400)) == "周五恢复", "每周用完：周五恢复")
        var approxWeek = near
        approxWeek.approx = true
        check(QuotaLine.longNote(approxWeek, now: reset.addingTimeInterval(-2 * 86400 - 3600)) == "周五重置", "每周的备注不带「约」")
        check(Fmt.coarse(30) == "1分" && Fmt.coarse(45 * 60) == "45分" && Fmt.coarse(3 * 3600 + 1200) == "3时" && Fmt.coarse(50 * 3600) == "2天", "只写最大一级单位的时长")

        // 文字放得下：三栏宽度（名字 38、百分比 33、备注 73，带标签时 49）。不手写字符串，把真实产出的备注逐个量
        check(width("Claude", nameFont) <= 38 && width("Codex", nameFont) <= 38 && width("100%", numFont) <= 33, "名字和 100% 都放得进自己的栏（38 / 33）")
        var overflow: [String] = []
        let tagWidth = ceil(width("每周", nameFont)) + 3
        for approx in [false, true] {
            let fiveUsedSamples: [Double] = [0, 12, 38, 62, 90, 100]
            for fiveUsed in fiveUsedSamples {
                let fiveLeftSamples: [TimeInterval] = [90, 1_200, 3_600, 3 * 3600 + 1_740, 4.99 * 3600]
                for fiveLeft in fiveLeftSamples {
                    let weekUsedSamples: [Double] = [10, 61, 80, 85, 98, 100]
                    for weekUsed in weekUsedSamples {
                        let weekLeftSamples: [TimeInterval] = [3_000, 20 * 3600, 86400 + 60, 2 * 86400, 6.9 * 86400, 8 * 86400]
                        for weekLeft in weekLeftSamples {
                            var p = provider("Claude", five: fiveUsed, week: weekUsed, fiveLeft: fiveLeft, weekLeft: weekLeft)
                            p.windows[0].approx = approx
                            p.windows[1].approx = approx
                            let line = QuotaLine.make(p, now: now)
                            let room = 73 - (line.tag == nil ? 0 : tagWidth)
                            if TouchBarArt.fit(line.note, width: room, font: subFont) != line.note { overflow.append("\(line.note)@\(room)") }
                        }
                    }
                }
            }
        }
        check(overflow.isEmpty, "额度表的备注在各种用量、重置时间、有无「约」的组合下都放得下：" + Set(overflow).sorted().prefix(5).joined(separator: " "))
        let staleAges: [TimeInterval] = [600, 59 * 60, 3600, 80 * 60, 23 * 3600 + 59 * 60, 40 * 3600, 11 * 86400]
        let staleLooks = staleAges.map { age -> String in
            QuotaLine.make(provider("Claude", five: 38, week: nil, updated: now.addingTimeInterval(-age)), now: now).note
        }
        check(staleLooks.allSatisfy { TouchBarArt.fit($0, width: 73, font: subFont) == $0 }, "过期的备注放得下：" + staleLooks.joined(separator: " "))
        let table = QuotaLine.make(provider("Claude", five: 38, week: 98), now: now)
        check(TouchBarArt.quotaTable([table, calm]).size == NSSize(width: TouchBarArt.tableWidth, height: TouchBarArt.height)
              && TouchBarArt.quotaTable([]).size.width == TouchBarArt.tableWidth, "额度表宽度固定，没有账号时也画得出来")
        // 账号超过两个：第二行放其余里最紧的，读屏提一句
        let three = [provider("Claude", five: 20, week: 20), provider("Codex", five: 5, week: 18), Provider(name: "Codex 2", windows: [window("5小时", 98, 5 * 3600, left: 3600)], updatedAt: now)]
        check(TouchBarItem.quotaRows(three, now: now).map(\.name) == ["Claude", "Codex 2"] && TouchBarItem.quotaPart(three, now: now).label?.contains("还有 1 家在额度页") == true,
              "三个账号：第二行换成最紧的那家，读屏说还有 1 家在额度页")
        check(TouchBarItem.quotaRows(Array(three.prefix(2)), now: now).map(\.name) == ["Claude", "Codex"] && TouchBarItem.quotaRows([], now: now).isEmpty, "两个及以下原样")

        // ---------- 第一页的宽度 ----------
        for link in [true, false] {
            for cards in 0...3 {
                let widths = TouchBarItem.firstLayerWidths(cards: cards, link: link)
                let chips = 3 + (link ? 1 : 0)
                let blocks = 1 + widths.count + chips
                let span = TouchBarArt.tableWidth + widths.reduce(0, +) + TouchBarItem.chipWidth * CGFloat(chips) + TouchBarItem.detailSpacing * CGFloat(blocks - 1)
                check(span == TouchBarItem.detailWidth && widths.count == max(1, min(2, cards)) && widths.allSatisfy { $0 >= 104 },
                      "对话卡 \(cards) 张、双机 \(link)：正好 610pt，每张至少 104pt（放得下 11 个字的标题）")
            }
        }

        // ---------- 对话区放谁、「对话」入口说什么 ----------
        func task(_ agent: String, _ id: String, _ light: Light, minutes: Double = 1, title: String? = nil) -> TouchBarItem.TaskItem {
            let state: SessionState = { switch light { case .running: return .running; case .waiting: return .waiting; case .done: return .done; case .error: return .error; case .idle: return .idle } }()
            let moment = now.addingTimeInterval(-minutes * 60)
            let uuid = agent == "codex" ? "00000000-0000-4000-8000-0000000003" + String(format: "%02d", id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 100) : id
            return (AgentSession(agent: agent, id: uuid, state: state, since: moment, updated: moment, first: moment, title: title ?? id, bundle: "",
                                 waitReason: light == .waiting ? "question" : ""), light)
        }
        func layer(_ tasks: [TouchBarItem.TaskItem], lights: [CustomLight] = [], relays: [RelayPair] = [], link: Bool = true) -> [TouchBarItem.Part] {
            let chip = link ? TouchBarItem.linkChip(Snapshot.demoLink(now: now, on: true), now: now) : nil
            return TouchBarItem.aiPage(rows: [provider("Claude", five: 38, week: 61), provider("Codex", five: 5, week: 18)], tasks: tasks, lights: lights, relays: relays,
                                       watched: [], now: now, link: chip, pet: TouchBarItem.relaxChip)
        }
        let w1 = task("codex", "w1", .waiting), w2 = task("claude", "w2", .waiting, minutes: 2), w3 = task("claude", "w3", .waiting, minutes: 3)
        let e1 = task("claude", "e1", .error), d1 = task("claude", "d1", .done), r1 = task("claude", "r1", .running), r2 = task("claude", "r2", .running, minutes: 5)
        let i1 = task("codex", "i1", .idle)
        func cards(_ parts: [TouchBarItem.Part]) -> [String] { parts.map(\.id).filter { $0.hasPrefix("task:") || $0.hasPrefix("light:") } }
        check(cards(layer([r1, d1, e1, w1, i1, r2])) == ["task:" + w1.session.key, "task:" + e1.session.key], "对话区只放最要紧的两张：等你 > 出错 > 完成 > 在跑，空闲的不上第一页")
        check(cards(layer([r1, d1])) == ["task:" + d1.session.key, "task:" + r1.session.key], "没有等你和出错时：刚完成的在前，在跑的在后")
        let failedLight = CustomLight(name: "构建", state: .error, started: now.addingTimeInterval(-300), updated: now.addingTimeInterval(-10), code: 2)
        let runLight = CustomLight(name: "npm test", state: .running, started: now.addingTimeInterval(-120), updated: now)
        check(cards(layer([w1, r1], lights: [failedLight, runLight])) == ["task:" + w1.session.key, "light:" + failedLight.id], "tb 灯和会话一起排：失败的灯排在在跑的会话前面")
        check(cards(layer([i1])).isEmpty && layer([i1]).contains { $0.id == "empty" }, "只有空闲的对话：对话区放暗的占位，位置不变")
        check(layer([i1]).first(where: { $0.id == "chats" })?.label?.hasPrefix("对话：另有 1 个最近的对话") == true, "只有最近任务时，「对话」入口写「最近」，读屏说另有 1 个最近的对话")
        check(cards(layer([])).isEmpty && layer([]).map(\.id).contains("empty"), "一个对话都没有：也是暗的占位")

        func summary(_ tasks: [TouchBarItem.TaskItem], lights: [CustomLight] = [], relays: [RelayPair] = []) -> TouchBarItem.ChatsSummary {
            let ordered = TouchBarItem.chats(tasks: tasks, lights: lights)
            return TouchBarItem.chatsSummary(ordered, shown: min(2, ordered.filter { $0.light != .idle }.count), relays: relays, total: ordered.count)
        }
        let waitingHidden = summary([w1, w2, w3, r1])
        check(waitingHidden.line == "+1 等你" && waitingHidden.level == .waiting && waitingHidden.hidden == 2, "没显示出来的有等你：橙色「+N 等你」")
        let errorHidden = summary([w1, e1, task("claude", "e2", .error, minutes: 4), r1])
        check(errorHidden.line == "+1 出错" && errorHidden.level == .error, "没显示出来的有出错：红色「+N 出错」")
        let doneHidden = summary([w1, w2, d1])
        check(doneHidden.line == "+1 完成" && doneHidden.level == .done && doneHidden.hidden == 1, "没显示出来的是刚完成：绿色「+N 完成」")
        let runningHidden = summary([r1, r2, task("claude", "r3", .running, minutes: 9)])
        check(runningHidden.line == "+1" && runningHidden.level == nil && runningHidden.hidden == 1, "没显示出来的只是在跑的：灰色个数")
        check(summary([r1, r2, i1]).line == "最近" && summary([r1, r2, i1]).level == nil && summary([r1, r2, i1]).spoken == "另有 1 个最近的对话",
              "没显示出来的只有一小时内的最近任务：灰色「最近」，不当成有事")
        let manyRecent = summary([r1, r2] + (0..<12).map { task("codex", "old\($0)", .idle, minutes: Double(20 + $0)) })
        check(manyRecent.line == "最近" && manyRecent.hidden == 12, "十几个最近任务不会变成「+12」")
        let liveAndRecent = summary([r1, r2, task("claude", "r9", .running, minutes: 8), i1, task("codex", "old9", .idle, minutes: 50)])
        check(liveAndRecent.line == "+1" && liveAndRecent.spoken == "还有 1 个对话没显示；另有 2 个最近的对话", "个数只数还在活动的，读屏另说有几个最近的")
        check(summary([]).line == "无" && summary([r1]).line == "全部" && summary([r1, r2]).line == "全部", "没有对话写「无」，全显示了写「全部」")
        let repoPair = RelayPair(cwd: "/tmp/demo", claude: d1, codex: task("codex", "x", .idle), tone: .turn, next: "codex", note: nil)
        check(summary([r1], relays: [repoPair]).line == "接力" && summary([r1], relays: [repoPair]).level == .done, "接力轮到你：「对话」入口写绿色「接力」，不从第一页消失")
        check(summary([w1, w2, w3], relays: [repoPair]).line == "+1 等你", "等你比接力优先")
        check(["+9 等你", "+9 出错", "+9 完成"].allSatisfy { width($0, subFont) <= TouchBarItem.chipWidth - 6 }, "入口第二行放得下 +N 加两个字")
        check(TouchBarItem.chatsSummary(TouchBarItem.chats(tasks: (0..<14).map { task("claude", "x\($0)", .waiting, minutes: Double($0)) }, lights: []), shown: 2,
                                        relays: [], total: 14).line == "+12", "个数到两位数时只写「+12」，不截断")

        // 位置固定：入口四格永远在最后，id 不变
        for sample in [[w1, w2, r1], [r1], [i1], []] {
            let ids = layer(sample).map(\.id)
            check(ids.first == "quota" && ids.suffix(4) == ["chats", "link", "relax", "tools"], "不管有几个对话，后四格是「对话」双机小猫「工具」")
        }
        check(layer([w1], link: false).map(\.id).suffix(3) == ["chats", "relax", "tools"], "没装双机：三格，对话卡把宽度吃满")

        // 读屏文字
        let spoken = layer([w1, e1, r1])
        check(spoken.first?.label?.hasPrefix("额度：Claude 38%") == true && spoken.first(where: { $0.id == "chats" })?.label?.hasPrefix("对话：还有 1 个对话没显示") == true,
              "读屏：额度表读两家，「对话」入口读还有几个没显示")

        // 颜色只表示一件事：采样对话卡中心偏上的像素（标题那一行的左边空白处），看底色是橙、红、还是没有填充
        func fill(_ light: Light) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let image = TouchBarArt.convCard(title: "T", subtitle: "S", light: light, width: 116)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 116, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: 116, height: 30).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: 116, height: 30))
            NSGraphicsContext.restoreGraphicsState()
            let c = rep.colorAt(x: 100, y: 12)?.usingColorSpace(.deviceRGB) ?? .black
            return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        }
        let orangeFill = fill(.waiting), redFill = fill(.error), plainFill = fill(.running), doneFill = fill(.done)
        check(orangeFill.r > 0.2 && orangeFill.r > orangeFill.b * 3 && orangeFill.g > 0.1, "等你：整块橙底")
        check(redFill.r > 0.2 && redFill.g < redFill.r / 2 && redFill.b < redFill.r / 2, "出错：整块红底")
        check(abs(plainFill.r - plainFill.g) < 0.02 && abs(plainFill.g - plainFill.b) < 0.02 && abs(doneFill.r - doneFill.b) < 0.02
              && abs(doneFill.g - plainFill.g) < 0.02, "在跑和做完了：底色都是中性的灰，做完了只靠绿字")
        // 小猫入口格里没有橙色的「?」：waiting 的 chip 画面里找不到橙色像素
        let waitingChip = PetArt.image(.waiting, time: 0, animated: false, chip: true)
        let chipRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: chipRep)
        waitingChip.draw(in: NSRect(x: 0, y: 0, width: 44, height: 30))
        NSGraphicsContext.restoreGraphicsState()
        var orangePixels = 0
        for x in 0..<44 { for y in 0..<30 {
            if let c = chipRep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5, c.redComponent > 0.8, c.greenComponent > 0.4, c.greenComponent < 0.75, c.blueComponent < 0.3 { orangePixels += 1 }
        } }
        check(orangePixels == 0, "AI 页上的小猫（等你）没有橙色的「?」气泡")

        // 状态那一行放得下：限流恢复时间在明天（带或不带「约」）也不被截成半个词
        func rateLimited(_ resume: TimeInterval, approx: Bool) -> TouchBarItem.TaskItem {
            var item = task("claude", "rl", .error)
            item.session.errorType = "rate_limit"
            item.session.resumeAt = now.addingTimeInterval(resume)
            item.session.resumeApprox = approx
            return item
        }
        for approx in [false, true] {
            let resumes: [TimeInterval] = [1_800, 3 * 3600, 20 * 3600, 30 * 3600, 3 * 86400]
            for resume in resumes {
                let item = rateLimited(resume, approx: approx)
                let line = TouchBarItem.convSubtitle(item.session, light: .error, now: now, width: 104)
                check(width(line, subFont) <= 104 && !line.hasSuffix("…") && line.contains("限流"), "限流卡片的状态行放得下，不带省略号：" + line)
            }
        }
        check(TouchBarItem.convSubtitle(r1.session, light: .running, now: now, width: 104).hasPrefix("Claude · 运行中"), "放得下时写 AI 名字")
        var longRun = r1
        longRun.session.since = now.addingTimeInterval(-24 * 3600)
        check(!TouchBarItem.convSubtitle(longRun.session, light: .running, now: now, width: 104).contains("Claude"), "放不下时先去掉 AI 名字")

        // 对话页和第一页同一个顺序：失败的灯排在做完的会话前面，等你的灯排在出错的会话前面；.info 灯只在对话页
        let infoLight = CustomLight(name: "Staging 正常", state: .info, started: now, updated: now, keep: true)
        let mixed = TouchBarItem.chatsImages(tasks: [d1, r1], lights: [failedLight, infoLight], relays: [], watched: [], now: now, reopen: nil).map(\.id)
        check(mixed == ["light:" + failedLight.id, "task:" + d1.session.key, "task:" + r1.session.key, "light:" + infoLight.id], "对话页：失败的灯 > 做完的会话 > 在跑的会话 > 空闲的灯")
        let waitingLight = CustomLight(name: "部署", state: .waiting, detail: "等人确认", started: now, updated: now)
        check(TouchBarItem.chatsImages(tasks: [e1], lights: [waitingLight], relays: [], watched: [], now: now, reopen: nil).map(\.id).first == "light:" + waitingLight.id, "等你的灯排在出错的会话前面")
        check(cards(layer([], lights: [infoLight])).isEmpty && layer([], lights: [infoLight]).first(where: { $0.id == "chats" })?.label?.contains("另有 1 个最近的对话") == true,
              ".info 灯不上第一页，算作最近的对话")
        check(layer([i1]).first(where: { $0.id == "empty" })?.label == "没有进行中的对话" && TouchBarItem.chatsImages(tasks: [], lights: [], relays: [], watched: [], now: now, reopen: nil).first?.label != nil,
              "占位格有读屏文字")

        // ---------- 双机小格：短状态，只有出问题才有橙点 ----------
        var linkState = LinkState()
        linkState.available = true
        let off = TouchBarItem.linkChip(linkState, now: now)
        linkState.on = true
        linkState.pcOnline = true
        let online = TouchBarItem.linkChip(linkState, now: now)
        linkState.pcOnline = false
        let offline = TouchBarItem.linkChip(linkState, now: now)
        linkState.error = "Tailscale 连接失败"
        let broken = TouchBarItem.linkChip(linkState, now: now)
        check(off.image.size.width == TouchBarItem.chipWidth && [off, online, offline, broken].allSatisfy { $0.image.size == off.image.size }, "双机小格 44pt，四种状态一样大")
        check(Set([off, online, offline, broken].map { $0.image.tiffRepresentation ?? Data() }).count == 4, "省电、在线、离线、出错四种画法不同")

        // ---------- 页面往返 ----------
        let bar = TouchBarItem()
        bar.pretendShownForTesting()
        bar.update(rows: [provider("Claude", five: 38, week: 61)], lights: [w1, r1], tasks: [w1, r1], now: now)
        func pageName(_ page: TouchBarItem.Page) -> String {
            switch page { case .overview: return "overview"; case .chats: return "chats"; case .quota: return "quota"; case .task: return "task"; default: return "other" }
        }
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "chats" } ?? 0)
        check(pageName(bar.page) == "chats" && bar.shown.first?.id == "task:" + w1.session.key, "点「对话」进对话页")
        bar.tapForTesting(0)
        check(pageName(bar.page) == "task", "对话页里点一张进任务页")
        bar.backForTesting()
        check(pageName(bar.page) == "chats", "任务页返回对话页（不是 AI 页）")
        bar.backForTesting()
        check(pageName(bar.page) == "overview", "对话页返回 AI 页")
        bar.tapForTesting(0)
        check(pageName(bar.page) == "quota" && bar.shown.first?.id.hasPrefix("provider:") == true, "点额度表进额度页，第一张是带条的额度卡")
        bar.backForTesting()
        check(pageName(bar.page) == "overview", "额度页返回 AI 页")
        // 对话页 → 接力页 → 返回：回对话页
        let pairBar = TouchBarItem()
        pairBar.pretendShownForTesting()
        pairBar.update(rows: [provider("Claude", five: 38, week: 61)], lights: [d1, r1], tasks: [d1, r1], now: now, relays: [repoPair])
        pairBar.open(.chats)
        check(pairBar.shown.first?.id == "relay", "对话页最前面是接力卡")
        pairBar.tapForTesting(0)
        if case .relay = pairBar.page {} else { check(false, "点接力卡进接力页") }
        pairBar.backForTesting()
        check(pageName(pairBar.page) == "chats", "接力页返回对话页（不是 AI 页）")
        bar.openPage(named: "chats")
        check(pageName(bar.page) == "chats", "广播 chats 直接打开对话页")
        bar.openPage(named: "quota")
        check(pageName(bar.page) == "quota", "广播 quota 直接打开额度页")
        bar.openPage(named: "overview")
        check(pageName(bar.page) == "overview", "广播 overview 回到 AI 页")
    }
}
