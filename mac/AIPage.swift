import AppKit

// 触控栏展开后的第一页（AI 页）和它的两个下一级（对话页、额度页）。
// 第一页固定 610pt 一屏、不用划，位置永远不动：额度表、最要紧的两张对话（只有等你和出错整块上色）、
// 「对话」「双机」小猫「工具」四个入口。其余的对话、接力、tb 灯进对话页，每家额度的条和 ZCode 用量进额度页。
// 颜色只表示一件事：橙 = 等你（或额度用得太快）、红 = 出错（或额度快满）、绿字 = 做完了；没事时只有白和灰。

// MARK: - 额度那一行

/// 一家额度在 AI 页上写成什么样：只写「正卡着你的那个窗口」——平时是 5 小时，每周用到 80% 以上就换成每周
struct QuotaLine: Equatable {
    enum Level { case calm, fast, full, dim }

    var name: String
    var pct: String
    var tag: String?          // 不是 5 小时的窗口写它的名字（本周写「每周」），不然 98% 会被读成 5 小时
    var note: String
    var level: Level
    var spoken: String

    static let weeklyThreshold: Double = 80

    /// 严重度：0 正常、1 用得快、2 快满、3 已用完（正被挡着）
    static func severity(_ w: QuotaWindow, now: Date) -> Int {
        if w.used >= 100 { return 3 }
        switch w.pace(at: now) { case .ok: return 0; case .fast: return 1; case .full: return 2 }
    }

    static func make(_ p: Provider, now: Date) -> QuotaLine {
        guard let first = p.windows.first else {
            let note = p.error == nil ? "暂无数据" : "出错"
            return QuotaLine(name: p.name, pct: "–", tag: nil, note: note, level: .dim, spoken: p.name + "：" + note)
        }
        let five = first.effective(at: now)
        let second = p.windows.count > 1 ? p.windows[1].effective(at: now) : nil
        if p.isStale(at: now) {
            // 数据过期了就整行变灰，写多久没更新（只写最大的一级单位）；不配颜色（过期不是警告）
            let note = p.updatedAt.map { "更新于" + Fmt.coarse(now.timeIntervalSince($0)) + "前" } ?? "暂无数据"
            let pct = p.updatedAt == nil ? "–" : Fmt.pct(five.used)
            return QuotaLine(name: p.name, pct: pct, tag: nil, note: note, level: .dim, spoken: p.name + " " + pct + "，" + note)
        }
        // 第二个窗口（每周）只有用到 80% 以上、而且不比 5 小时轻时才顶上来：5 小时已经用完（正挡着你）时它比每周紧，还写 5 小时
        var chosen = five
        if let second, second.used >= weeklyThreshold, severity(second, now: now) >= severity(five, now: now) { chosen = second }
        let rank = severity(chosen, now: now)
        let level: Level = rank == 0 ? .calm : rank == 1 ? .fast : .full
        let long = chosen.label != "5小时"
        let tag: String? = long ? (chosen.label == "本周" ? "每周" : chosen.label) : nil
        let note = long ? longNote(chosen, now: now) : shortNote(chosen, now: now)
        let pct = Fmt.pct(chosen.used)
        let spoken = p.name + (tag.map { " " + $0 } ?? "") + " " + pct + (note.isEmpty ? "" : "，" + note)
        return QuotaLine(name: p.name, pct: pct, tag: tag, note: note, level: level, spoken: spoken)
    }

    /// 5 小时那一行的备注（73pt）：几点用完 / 多久后恢复 / 几点重置。不写「约」：Claude 的 5 小时重置是估算的、误差几分钟，对一句灰字没意义，写了还放不下
    static func shortNote(_ w: QuotaWindow, now: Date) -> String {
        if w.used >= 100, let r = w.resetsAt, r > now { return Fmt.short(r.timeIntervalSince(now)) + "后恢复" }
        if w.pace(at: now) != .ok, let t = w.runsOut(at: now) { return Fmt.shortClock(t, now: now) + "用完" }
        if let r = w.resetsAt { return Fmt.shortClock(r, now: now) + "重置" }
        return w.note ?? ""
    }

    /// 每周（和别的长窗口）那一行的备注：写了标签之后只剩 49pt，所以只写到「天」：周五重置、周三用完、周五恢复；不知道重置时间就不写
    static func longNote(_ w: QuotaWindow, now: Date) -> String {
        if w.used >= 100, let r = w.resetsAt, r > now { return Fmt.dayShort(r, now: now) + "恢复" }
        if w.pace(at: now) != .ok, let t = w.runsOut(at: now) { return Fmt.dayShort(t, now: now) + "用完" }
        if let r = w.resetsAt { return Fmt.dayShort(r, now: now) + "重置" }
        return w.note == "已重置" ? "已重置" : ""
    }
}

extension Fmt {
    /// 只写最大的一级单位的时长：45分、3时、10天
    static func coarse(_ t: TimeInterval) -> String {
        let m = Int(max(0, t) / 60)
        if m < 60 { return "\(max(1, m))分" }
        let h = m / 60
        return h < 24 ? "\(h)时" : "\(h / 24)天"
    }

    /// 只到天的时间：今天写时分，明天、周五、10/23
    static func dayShort(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 99
        if days == 0 {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: d)
        }
        if days == 1 { return "明天" }
        if days > 1 && days < 7 { return weekdays[cal.component(.weekday, from: d) - 1] }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: d)
    }
}

// MARK: - 画

extension TouchBarArt {
    static let tableWidth: CGFloat = 166
    /// 对话卡左右留白：6pt 才放得下 116pt 卡里「云端Claude额度领取」这样的 11 个字的标题
    static let convPad: CGFloat = 6
    static let chipWidth: CGFloat = 44
    /// 入口格（对话、双机、小猫、工具）的底色比内容卡暗一级，看起来是按钮而不是信息
    static let chipFill = NSColor(white: 1, alpha: 0.08)
    static let cardFill = NSColor(white: 1, alpha: 0.11)
    static let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let subFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    static let subColor = NSColor(white: 1, alpha: 0.72)
    static let waitingText = NSColor(red: 1.0, green: 0.70, blue: 0.25, alpha: 1)
    static let errorText = NSColor(red: 1.0, green: 0.41, blue: 0.38, alpha: 1)

    private static func width(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func levelColor(_ level: QuotaLine.Level) -> NSColor {
        switch level {
        case .calm: return .labelColor
        case .fast: return .systemOrange
        case .full: return .systemRed
        case .dim: return .tertiaryLabelColor
        }
    }

    /// 额度表：两家各一行——名字、百分比（右对齐，上下两行对齐）、一句灰字。没有条、没有竖线（收起的小图标里有，点进额度页也有）
    static func quotaTable(_ lines: [QuotaLine], width tableW: CGFloat = tableWidth) -> NSImage {
        image(width: tableW) { rect in
            pill(rect, cardFill)
            guard !lines.isEmpty else {
                let text = "额度 · 暂无数据" as NSString
                let w = width(text as String, nameFont)
                text.draw(at: NSPoint(x: (tableW - w) / 2, y: 8), withAttributes: [.font: nameFont, .foregroundColor: NSColor.tertiaryLabelColor])
                return
            }
            let rowH: CGFloat = 13
            let top = (height - rowH * CGFloat(lines.count)) / 2
            // 七 + 名字 38 + 三 + 百分比 33（「100%」要 31.5）+ 五 + 备注 73 = 166
            let pad: CGFloat = 7, nameW: CGFloat = 38, pctW: CGFloat = 33
            let noteX = pad + nameW + 3 + pctW + 5
            for (i, line) in lines.enumerated() {
                let y = top + CGFloat(i) * rowH
                let dim = line.level == .dim
                let color = levelColor(line.level)
                let name = fit(line.name, width: nameW, font: nameFont)
                (name as NSString).draw(at: NSPoint(x: pad, y: y), withAttributes: [.font: nameFont,
                                                                                    .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor])
                let pw = width(line.pct, numFont)
                (line.pct as NSString).draw(at: NSPoint(x: pad + nameW + 3 + pctW - pw, y: y), withAttributes: [.font: numFont, .foregroundColor: color])
                var x = noteX
                if let tag = line.tag {
                    (tag as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: nameFont, .foregroundColor: color])
                    x += width(tag, nameFont) + 3
                }
                let note = fit(line.note, width: max(0, tableW - pad - x), font: subFont)
                (note as NSString).draw(at: NSPoint(x: x, y: y + 0.5), withAttributes: [.font: subFont, .foregroundColor: dim ? NSColor.tertiaryLabelColor : subColor])
            }
        }
    }

    /// 对话卡：标题一行、状态一行。只有等你（橙）和出错（红）整块上色；做完了不填底色，只把状态写成绿字；在跑的全是灰的
    static func convCard(title: String, subtitle: String, light: Light, width cardW: CGFloat) -> NSImage {
        image(width: cardW) { rect in
            switch light {
            case .waiting: pill(rect, NSColor.systemOrange.withAlphaComponent(0.24))
            case .error: pill(rect, NSColor.systemRed.withAlphaComponent(0.24))
            case .idle: pill(rect, NSColor(white: 1, alpha: 0.07))
            default: pill(rect, cardFill)
            }
            let titleColor: NSColor = light == .idle ? .secondaryLabelColor : .labelColor
            let subColor: NSColor
            switch light {
            case .waiting: subColor = waitingText
            case .error: subColor = errorText
            case .done: subColor = .systemGreen
            case .running: subColor = Self.subColor
            case .idle: subColor = .tertiaryLabelColor
            }
            let heading = fit(title, width: cardW - 2 * convPad, font: titleFont)
            (heading as NSString).draw(at: NSPoint(x: convPad, y: 1), withAttributes: [.font: titleFont, .foregroundColor: titleColor])
            let sub = fit(subtitle, width: cardW - 2 * convPad, font: subFont)
            (sub as NSString).draw(at: NSPoint(x: convPad, y: 16), withAttributes: [.font: subFont, .foregroundColor: subColor])
        }
    }

    /// 没有对话时占着对话区的暗格，右边几格不挪位置
    static func convPlaceholder(width cardW: CGFloat) -> NSImage {
        image(width: cardW) { rect in
            pill(rect, NSColor(white: 1, alpha: 0.05))
            let text = fit("没有进行中的对话", width: cardW - 14, font: nameFont)
            let w = width(text, nameFont)
            (text as NSString).draw(at: NSPoint(x: (cardW - w) / 2, y: 8), withAttributes: [.font: nameFont, .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    /// 入口格：单行居中
    static func chipSingle(_ title: String, width chipW: CGFloat) -> NSImage {
        image(width: chipW) { rect in
            pill(rect, chipFill)
            let t = fit(title, width: chipW - 6, font: titleFont)
            let w = width(t, titleFont)
            (t as NSString).draw(at: NSPoint(x: (chipW - w) / 2, y: 8), withAttributes: [.font: titleFont, .foregroundColor: NSColor.labelColor])
        }
    }

    /// 入口格：上一行名字、下一行一句短话（可以前面带一个 5pt 的点）。dim：整格暗着（省电、没有）
    static func chipDouble(_ title: String, line: String, color: NSColor, dot: NSColor? = nil, dim: Bool = false, width chipW: CGFloat) -> NSImage {
        image(width: chipW) { rect in
            pill(rect, dim ? NSColor(white: 1, alpha: 0.05) : chipFill)
            let t = fit(title, width: chipW - 6, font: titleFont)
            let tw = width(t, titleFont)
            (t as NSString).draw(at: NSPoint(x: (chipW - tw) / 2, y: 1), withAttributes: [.font: titleFont,
                                                                                          .foregroundColor: dim ? NSColor.tertiaryLabelColor : NSColor.labelColor])
            let dotW: CGFloat = dot == nil ? 0 : 8
            let l = fit(line, width: chipW - 6 - dotW, font: subFont)
            let lw = width(l, subFont)
            let x = (chipW - lw - dotW) / 2
            if let dot {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: 19.5, width: 5, height: 5)).fill()
            }
            (l as NSString).draw(at: NSPoint(x: x + dotW, y: 16), withAttributes: [.font: subFont, .foregroundColor: color])
        }
    }
}

// MARK: - 排版

extension TouchBarItem {
    struct Chat {
        enum Source { case task(TaskItem), light(CustomLight) }
        let source: Source
        let light: Light
        let updated: Date
        let key: String
    }

    /// 全部对话（会话和 tb 灯）按轻重排：等你 > 出错 > 刚完成 > 在跑 > 空闲，同级新的在前
    static func chats(tasks: [TaskItem], lights: [CustomLight]) -> [Chat] {
        let all = tasks.map { Chat(source: .task($0), light: $0.light, updated: $0.session.updated, key: "task:" + $0.session.key) }
            + lights.map { Chat(source: .light($0), light: $0.light, updated: $0.updated, key: "light:" + $0.id) }
        return all.sorted {
            if $0.light.rank != $1.light.rank { return $0.light.rank < $1.light.rank }
            if $0.updated != $1.updated { return $0.updated > $1.updated }
            return $0.key < $1.key
        }
    }

    /// 状态那一行：「Claude · 运行中 3分」放不下就去掉 AI 名字，再不行把空格收紧（「被限流 明天08:30恢复」），
    /// 最后去掉「恢复」二字（「被限流 约明天08:30」），都放不下才截短
    static func convSubtitle(_ s: AgentSession, light: Light, now: Date, width: CGFloat) -> String {
        let brief = s.briefStatus(light, now: now).replacingOccurrences(of: " · ", with: " ")
        let tight = brief.replacingOccurrences(of: " 恢复", with: "恢复").replacingOccurrences(of: "约 ", with: "约")
        let bare = tight.replacingOccurrences(of: "恢复", with: "")
        let attrs: [NSAttributedString.Key: Any] = [.font: TouchBarArt.subFont]
        for candidate in [s.agentName + " · " + brief, brief, tight, bare] where (candidate as NSString).size(withAttributes: attrs).width <= width {
            return candidate
        }
        return TouchBarArt.fit(tight, width: width, font: TouchBarArt.subFont)
    }

    static func sessionCard(_ item: TaskItem, now: Date, width: CGFloat) -> Part {
        let s = item.session
        let subtitle = convSubtitle(s, light: item.light, now: now, width: width - 2 * TouchBarArt.convPad)
        return Part(image: TouchBarArt.convCard(title: s.displayTitle, subtitle: subtitle, light: item.light, width: width),
                    action: .select(s.key), id: "task:" + s.key, label: s.displayTitle + "，" + s.agentName + " · " + s.briefStatus(item.light, now: now))
    }

    /// tb 灯：跑着的点一下是「做完叫我」（再点取消），别的状态能关的点了关掉。「做完叫我」开着时状态前写「会叫你」，不用橙色
    static func lightCard(_ light: CustomLight, now: Date, watched: Set<String>, width: CGFloat) -> Part {
        let summary = CustomLights.summary(light, now: now)
        let key = AppModel.watchKey(light: light.name)
        let watching = light.state == .running && watched.contains(key)
        let subtitle = (watching ? "会叫你 · " : "") + summary
        let image = TouchBarArt.convCard(title: light.name, subtitle: subtitle, light: light.light, width: width)
        if light.state == .running {
            return Part(image: image, action: .watch(key), id: "light:" + light.id,
                        label: light.name + " · " + summary + (watching ? "。跑完会叫你，再点取消" : "。点了做完叫我"))
        }
        return Part(image: image, action: light.dismissable ? .lightDismiss(light.name, light.updated) : .none, id: "light:" + light.id,
                    label: light.name + " · " + summary)
    }

    static func chatCard(_ chat: Chat, now: Date, watched: Set<String>, width: CGFloat) -> Part {
        switch chat.source {
        case .task(let item): return sessionCard(item, now: now, width: width)
        case .light(let light): return lightCard(light, now: now, watched: watched, width: width)
        }
    }

    static let chipWidth = TouchBarArt.chipWidth
    static let firstChats = 2

    /// 第一页各块的宽度：额度表 + 对话卡 + 四个入口（没装双机时三个），加上块间距正好 610，对话卡吃剩下的
    static func firstLayerWidths(cards: Int, link: Bool) -> [CGFloat] {
        let count = max(1, min(firstChats, cards))
        let chips = 3 + (link ? 1 : 0)
        let blocks = 1 + count + 1 + (chips - 1)               // 额度表 + 对话卡 + 「对话」+ 其余入口
        let fixed = TouchBarArt.tableWidth + chipWidth * CGFloat(chips)
        let total = detailWidth - fixed - detailSpacing * CGFloat(blocks - 1)
        let each = floor(total / CGFloat(count))
        var widths = [CGFloat](repeating: each, count: count)
        widths[0] += total - each * CGFloat(count)
        return widths
    }

    /// 「对话」入口第二行：没显示出来的等你 / 出错先说（橙、红），再是接力轮到谁（绿），没显示的完成（绿），其余只写还在活动的个数；只剩最近任务写「最近」
    struct ChatsSummary: Equatable {
        var line: String
        var level: Light?          // 决定颜色：waiting 橙、error 红、done 绿、nil 灰
        var hidden: Int
        var spoken: String
    }

    static func chatsSummary(_ ordered: [Chat], shown: Int, relays: [RelayPair], total: Int) -> ChatsSummary {
        let hidden = Array(ordered.dropFirst(shown))
        func count(_ light: Light) -> Int { hidden.filter { $0.light == light }.count }
        let waiting = count(.waiting), failed = count(.error), done = count(.done)
        let turn = relays.contains { $0.tone == .turn }
        func line(_ n: Int, _ word: String) -> String {
            let long = "+\(n) \(word)"
            let attrs: [NSAttributedString.Key: Any] = [.font: TouchBarArt.subFont]
            return (long as NSString).size(withAttributes: attrs).width <= chipWidth - 6 ? long : "+\(n)"
        }
        // 个数只数还在活动的（等你、出错、完成、在跑）；一小时内的「最近任务」是历史，不算「有事」，只剩它们时写「最近」
        let live = hidden.filter { $0.light != .idle }.count
        let recent = hidden.count - live
        func spoken(_ detail: String?) -> String {
            var parts: [String] = []
            if live > 0 { parts.append("还有 \(live) 个对话没显示" + (detail.map { "，其中" + $0 } ?? "")) }
            if recent > 0 { parts.append("另有 \(recent) 个最近的对话") }
            return parts.isEmpty ? (detail ?? "没有更多对话") : parts.joined(separator: "；")
        }
        let rest = hidden.count
        if waiting > 0 { return ChatsSummary(line: line(waiting, "等你"), level: .waiting, hidden: rest, spoken: spoken("\(waiting) 个在等你")) }
        if failed > 0 { return ChatsSummary(line: line(failed, "出错"), level: .error, hidden: rest, spoken: spoken("\(failed) 个出错")) }
        if turn { return ChatsSummary(line: "接力", level: .done, hidden: rest, spoken: (rest > 0 ? spoken(nil) + "；" : "") + "接力轮到你了") }
        if done > 0 { return ChatsSummary(line: line(done, "完成"), level: .done, hidden: rest, spoken: spoken("\(done) 个做完了")) }
        if live > 0 { return ChatsSummary(line: "+\(live)", level: nil, hidden: rest, spoken: spoken(nil)) }
        if recent > 0 { return ChatsSummary(line: "最近", level: nil, hidden: rest, spoken: spoken(nil)) }
        return total == 0 ? ChatsSummary(line: "无", level: nil, hidden: 0, spoken: "还没有对话") : ChatsSummary(line: "全部", level: nil, hidden: 0, spoken: "对话都在这一页上")
    }

    static func chatsChip(_ summary: ChatsSummary) -> Part {
        let color: NSColor
        switch summary.level {
        case .some(.waiting): color = TouchBarArt.waitingText
        case .some(.error): color = TouchBarArt.errorText
        case .some(.done): color = .systemGreen
        default: color = TouchBarArt.subColor
        }
        let dim = summary.line == "无"
        return Part(image: TouchBarArt.chipDouble("对话", line: summary.line, color: dim ? .tertiaryLabelColor : color, width: chipWidth),
                    action: .chats, id: "chats", label: "对话：" + summary.spoken + "。点开看全部")
    }

    /// 额度表放哪两家：第一家，再加其余里最紧的一家（都一样紧就取靠前的）；账号超过两个时读屏提一句
    static func quotaRows(_ rows: [Provider], now: Date) -> [Provider] {
        guard rows.count > 2 else { return rows }
        func rank(_ p: Provider) -> Int {
            switch QuotaLine.make(p, now: now).level { case .full: return 3; case .fast: return 2; case .calm: return 1; case .dim: return 0 }
        }
        var worst = rows[1]
        for p in rows.dropFirst(2) where rank(p) > rank(worst) { worst = p }
        return [rows[0], worst]
    }

    static func quotaPart(_ rows: [Provider], now: Date) -> Part {
        let lines = quotaRows(rows, now: now).map { QuotaLine.make($0, now: now) }
        let more = rows.count > 2 ? "（还有 \(rows.count - 2) 家在额度页）" : ""
        let spoken = lines.isEmpty ? "额度：暂无数据" : "额度：" + lines.map(\.spoken).joined(separator: "；") + more
        return Part(image: TouchBarArt.quotaTable(lines), action: .quota, id: "quota", label: spoken + "。点开看每个窗口")
    }

    /// AI 页（点小图标先看这里）：固定一屏，位置不动。额度表、最要紧的两张对话、「对话」入口、双机、小猫、「工具」
    static func aiPage(rows: [Provider], tasks: [TaskItem], lights: [CustomLight], relays: [RelayPair], watched: Set<String>, now: Date,
                       link: Part?, pet: Part) -> [Part] {
        let ordered = chats(tasks: tasks, lights: lights)
        let live = ordered.filter { $0.light != .idle }
        let top = Array(live.prefix(firstChats))
        let widths = firstLayerWidths(cards: top.count, link: link != nil)
        var out = [quotaPart(rows, now: now)]
        if top.isEmpty {
            out.append(Part(image: TouchBarArt.convPlaceholder(width: widths[0]), action: .none, id: "empty", label: "没有进行中的对话"))
        } else {
            for (chat, width) in zip(top, widths) { out.append(chatCard(chat, now: now, watched: watched, width: width)) }
        }
        // 空闲的排在最后，所以显示出来的那几张就是 ordered 最前面的几张
        out.append(chatsChip(chatsSummary(ordered, shown: top.count, relays: relays, total: ordered.count)))
        if let link { out.append(link) }
        out.append(pet)
        out.append(toolsChip)
        return out
    }

    static let chatCardWidth: CGFloat = 142

    /// 对话页：接力、（关掉路线图后的）路线入口、全部会话和 tb 灯（一起按轻重排）；一屏放不下就左右划
    static func chatsImages(tasks: [TaskItem], lights: [CustomLight], relays: [RelayPair], watched: Set<String>, now: Date, reopen: Part?) -> [Part] {
        var out: [Part] = []
        if !relays.isEmpty { out.append(relayCard(relays)) }
        if let reopen { out.append(reopen) }
        // 会话和 tb 灯一起按轻重排（和第一页同一个顺序：第一页上「+1 出错」的那盏灯在这里也排在前面）
        let all = chats(tasks: tasks, lights: lights)
        if all.isEmpty {
            out.append(Part(image: TouchBarArt.card("还没有 AI 任务", subtitle: "Claude / Codex 有新活动后显示在这里", width: 190), action: .none, id: "empty",
                            label: "还没有 AI 任务。Claude 或 Codex 有新活动后显示在这里"))
        }
        for chat in all { out.append(chatCard(chat, now: now, watched: watched, width: chatCardWidth)) }
        return out
    }

    /// 额度页：每个账号一张带条的卡（5 小时粗条带「时间走到哪」的竖线、每周细条），ZCode 的 token 用量放最后；点卡打开菜单栏面板
    static func quotaImages(rows: [Provider], usage: Provider?, now: Date) -> [Part] {
        var seen: [String: Int] = [:]
        var out = rows.map { p -> Part in
            let base = p.accountId ?? p.name
            seen[base, default: 0] += 1
            return Part(image: TouchBarArt.provider(p, now: now), action: .panel, id: "provider:\(base)#\(seen[base]!)")
        }
        if let usage { out.append(Part(image: TouchBarArt.provider(usage, now: now), action: .panel, id: "provider:ZCode#1")) }
        return out
    }
}

// MARK: - 预览图（--snapshot 用）

extension Snapshot {
    /// 一屏 AI 页要看的几种状态，数据照真实情况摆（Claude 每周快用完、等你、出错、刚完成、tb 灯）
    static func writeAIPage(dir: String, now: Date) {
        func window(_ label: String, _ used: Double, _ length: TimeInterval, left: TimeInterval?) -> QuotaWindow {
            QuotaWindow(label: label, short: "", used: used, resetsAt: left.map { now.addingTimeInterval($0) }, length: length)
        }
        func session(_ agent: String, _ title: String, _ state: SessionState, _ light: Light, minutes: Double, reason: String = "", error: String = "",
                     resume: TimeInterval? = nil) -> TouchBarItem.TaskItem {
            let moment = now.addingTimeInterval(-minutes * 60)
            var s = AgentSession(agent: agent, id: agent == "codex" ? "00000000-0000-4000-8000-0000000002\(title.count % 10)\(Int(minutes) % 10)" : "demo-ai-\(title.count)-\(Int(minutes))",
                                 state: state, since: moment, updated: moment, first: moment, title: title, bundle: "", waitReason: reason)
            s.errorType = error
            s.resumeAt = resume.map { now.addingTimeInterval($0) }
            return (s, light)
        }
        let claude = Provider(name: "Claude", windows: [window("5小时", 38, 5 * 3600, left: 3 * 3600), window("本周", 61, 7 * 86400, left: 4 * 86400)], updatedAt: now)
        var claudeTight = claude
        claudeTight.windows[1] = window("本周", 98, 7 * 86400, left: 2 * 86400)
        let codex = Provider(name: "Codex", windows: [window("5小时", 5, 5 * 3600, left: 6.5 * 3600), window("本周", 18, 7 * 86400, left: 5 * 86400)], updatedAt: now)
        var claudeOld = claude
        claudeOld.updatedAt = now.addingTimeInterval(-3 * 3600)
        var claudeFast = claude
        claudeFast.windows[0] = window("5小时", 62, 5 * 3600, left: 3.5 * 3600)
        var codexFull = codex
        codexFull.windows[0] = window("5小时", 100, 5 * 3600, left: 2 * 3600)

        let running = [session("claude", "Touch Bar 太乱", .running, .running, minutes: 3), session("claude", "Tailscale Windows 连接", .running, .running, minutes: 24)]
        let done = session("claude", "云端Claude额度领取", .done, .done, minutes: 13)
        let waiting = session("codex", "SN61 文档整理", .waiting, .waiting, minutes: 2, reason: "question")
        let failed = session("claude", "依赖升级", .error, .error, minutes: 6, error: "rate_limit", resume: 3 * 3600)
        let recent = session("codex", "两台电脑互联", .idle, .idle, minutes: 40)
        let tbRun = CustomLight(name: "npm test", state: .running, detail: "", started: now.addingTimeInterval(-120), updated: now)
        let tbFail = CustomLight(name: "构建", state: .error, detail: "", started: now.addingTimeInterval(-300), updated: now.addingTimeInterval(-60), code: 2)
        let link = TouchBarItem.linkChip(demoLink(now: now, on: true), now: now)
        let off = TouchBarItem.linkChip(demoLink(now: now, on: false), now: now)
        let pet = TouchBarItem.petChip(.running, elapsed: 10)
        let sleepy = TouchBarItem.petChip(.idle, elapsed: 10)
        func page(_ name: String, rows: [Provider], tasks: [TouchBarItem.TaskItem], lights: [CustomLight] = [], relays: [RelayPair] = [],
                  link: TouchBarItem.Part? = link, pet: TouchBarItem.Part = pet) {
            let parts = TouchBarItem.aiPage(rows: rows, tasks: tasks, lights: lights, relays: relays, watched: [], now: now, link: link, pet: pet)
            touchBar(parts.map(\.image), to: "\(dir)/touchbar-ai-\(name).png")
        }
        page("calm", rows: [claude, codex], tasks: [done] + running + [recent], lights: [tbRun])
        page("busy", rows: [claudeTight, codex], tasks: [waiting, failed, done] + running + [recent], lights: [tbRun, tbFail])
        page("fast", rows: [claudeFast, codexFull], tasks: [waiting] + running)
        page("stale", rows: [claudeOld, codex], tasks: running, link: off, pet: sleepy)
        page("one", rows: [claude, codex], tasks: [waiting], link: nil)
        page("none", rows: [claude, codex], tasks: [recent], lights: [])
        page("empty", rows: [], tasks: [], link: nil, pet: TouchBarItem.relaxChip)
        let lights = demoRelayLights(now: now)
        let pairs = Relay.pairs(lights: lights, notes: [])
        page("relay", rows: [claude, codex], tasks: lights, relays: pairs)
        touchBar(TouchBarItem.chatsImages(tasks: [waiting, failed, done] + running + [recent], lights: [tbRun, tbFail], relays: pairs, watched: [],
                                          now: now, reopen: TouchBarItem.roadChip).map(\.image), to: "\(dir)/touchbar-chats.png")
        touchBar(TouchBarItem.quotaImages(rows: [claudeTight, codex], usage: Provider(name: "ZCode", updatedAt: now, tokens: (0, 110_000_000)), now: now).map(\.image),
                 to: "\(dir)/touchbar-quota.png")
    }
}
