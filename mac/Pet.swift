import AppKit

enum PetMood: Equatable {
    case running, waiting, done, error, idle

    /// 按最要紧的任务：等你 > 出错 > 完成 > 在跑；没有任务也在（睡觉），总览里的小猫一直是进它家的入口
    static func from(_ lights: [Light]) -> PetMood {
        if lights.contains(.waiting) { return .waiting }
        if lights.contains(.error) { return .error }
        if lights.contains(.done) { return .done }
        if lights.contains(.running) { return .running }
        return .idle
    }
}

/// 小猫现在的样子。等你、出错、刚完成总是先说；没这些事时，专注陪你看书、休息伸懒腰、放歌时听歌
enum PetPose: Equatable {
    case running, waiting, done, error, idle, focus, rest, music, happy

    static func of(mood: PetMood, calm: CalmState, music: Bool, patted: Bool) -> PetPose {
        if patted { return .happy }
        switch mood {
        case .waiting: return .waiting
        case .error: return .error
        case .done: return .done
        case .running, .idle: break
        }
        if case .focus = calm { return .focus }
        if case .rest = calm { return .rest }
        if mood == .running { return .running }
        return music ? .music : .idle
    }

    var label: String {
        switch self {
        case .running: return "小猫：AI 在跑"
        case .waiting: return "小猫：有任务在等你"
        case .done: return "小猫：有任务刚完成"
        case .error: return "小猫：有任务出错了"
        case .idle: return "小猫：都没事，在睡觉"
        case .focus: return "小猫：陪你专注，在看书"
        case .rest: return "小猫：休息时间，在伸懒腰"
        case .music: return "小猫：在听歌"
        case .happy: return "小猫：被摸了，很开心"
        }
    }
}

enum PetArt {
    static let walkA = [
        "................",
        "............#.#.",
        "............###.",
        "...........#####",
        "#..........##o##",
        "#..........####p",
        ".#..###########.",
        "..############..",
        "...##########...",
        "...#.#....#.#...",
        "...#.#....#.#...",
        "................",
    ]
    static let walkB = Array(walkA.prefix(9)) + [
        "....#.#..#.#....",
        "....#.#..#.#....",
        "................",
    ]
    static let jump = [
        "............#.#.",
        "............###.",
        "...........#####",
        "#..........##o##",
        "#..........####p",
        ".#..###########.",
        "..############..",
        "...##########...",
        "..#..........#..",
        ".#............#.",
        "................",
        "................",
    ]
    static let sit = [
        "................",
        "....#......#....",
        "....##....##....",
        "....########....",
        "....#o####o#....",
        "....###pp###....",
        ".....######.....",
        "....########....",
        "...##########.#.",
        "...##########.#.",
        "...###....####..",
        "................",
    ]
    static let startled = [
        "....#......#....",
        "....##....##....",
        "....########....",
        "....#x####x#....",
        "....###pp###....",
        ".....######.....",
        "...##########...",
        "..############..",
        "..###########.#.",
        "..###.....###.#.",
        "..#.#.....#.#...",
        "................",
    ]
    static let sleep = [
        "................",
        "................",
        "................",
        "................",
        "................",
        "..........#.#...",
        ".........#####..",
        "....#########-#.",
        "...############.",
        "..#############.",
        "..##############",
        "................",
    ]
    /// 伸懒腰：屁股翘高、前腿往前伸平、头低下来，眯着眼
    static let stretch = [
        ".#..............",
        ".#..............",
        "..#.............",
        "..####..........",
        "..######........",
        "..########..#.#.",
        "..#.#######.###.",
        "..#.#..#########",
        "..#.#....####-##",
        "..#.#.....#####p",
        "..#.#...########",
        "................",
    ]
    /// 叠在坐着的小猫身上：捧着一本打开的书
    static let book = [
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        "....cwwccwwc....",
        "....cwwccwwc....",
        "....cccccccc....",
        "................",
        "................",
    ]
    /// 眯眼（看书、听歌、被摸）
    static func closed(_ sprite: [String]) -> [String] { sprite.map { $0.replacingOccurrences(of: "o", with: "-") } }
    static let content = closed(sit).enumerated().map { $0.offset == 5 ? "....#r#pp#r#...." : $0.element }   // 被摸：眯眼、脸红

    static let body = NSColor(white: 0.92, alpha: 1)
    static let pink = NSColor(red: 1, green: 0.55, blue: 0.65, alpha: 1)
    static let width: CGFloat = 40
    static let pixel: CGFloat = 1.5
    static let homeWidth: CGFloat = 56                    // 小猫的家里大一号
    static let homePixel: CGFloat = 2
    static let animationLength: TimeInterval = 4
    static let patLength: TimeInterval = 2.5

    /// 换了样子后动 4 秒；等你的问号一直闪，被摸的爱心一直飘（摸完 2.5 秒就停）
    static func animating(_ pose: PetPose, elapsed: TimeInterval) -> Bool {
        elapsed < animationLength || pose == .waiting || pose == .happy
    }

    static func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    static func draw(_ sprite: [String], at raw: NSPoint, pixel: CGFloat = pixel) {
        let origin = NSPoint(x: snap(raw.x), y: snap(raw.y))
        for (row, line) in sprite.enumerated() {
            for (column, mark) in line.enumerated() where mark != "." {
                let color: NSColor
                switch mark {
                case "o": color = .black
                case "p": color = pink
                case "-": color = NSColor(white: 0.25, alpha: 1)
                case "x": color = .systemRed
                case "r": color = pink.withAlphaComponent(0.8)
                case "c": color = NSColor(red: 0.93, green: 0.55, blue: 0.2, alpha: 1)
                case "w": color = NSColor(red: 1, green: 0.97, blue: 0.85, alpha: 1)
                default: color = body
                }
                color.setFill()
                let cell = NSRect(x: origin.x + CGFloat(column) * pixel, y: origin.y + CGFloat(row) * pixel, width: pixel, height: pixel)
                // 眯着的眼睛只画下半格，看起来是一条线
                (mark == "-" ? NSRect(x: cell.minX, y: cell.midY, width: cell.width, height: cell.height / 2) : cell).fill()
            }
        }
    }

    static func bubble(_ text: String, color: NSColor, at point: NSPoint) {
        let font = NSFont.systemFont(ofSize: 10, weight: .heavy)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let rect = NSRect(x: point.x, y: point.y, width: size.width + 7, height: 13)
        color.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6.5, yRadius: 6.5).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 3.5, y: rect.minY - 0.5), withAttributes: [.font: font, .foregroundColor: NSColor.black])
    }

    static func spark(at point: NSPoint, size: CGFloat) {
        NSColor.systemGreen.setFill()
        let path = NSBezierPath()
        let points: [(CGFloat, CGFloat)] = [(0, -1), (0.3, -0.3), (1, 0), (0.3, 0.3), (0, 1), (-0.3, 0.3), (-1, 0), (-0.3, -0.3)]
        for (index, offset) in points.enumerated() {
            let target = NSPoint(x: point.x + offset.0 * size, y: point.y + offset.1 * size)
            if index == 0 { path.move(to: target) } else { path.line(to: target) }
        }
        path.close()
        path.fill()
    }

    /// 小爱心（图是上下翻过来画的：y 往下）
    static func heart(at center: NSPoint, size: CGFloat, alpha: CGFloat) {
        pink.withAlphaComponent(alpha).setFill()
        let r = size / 4
        NSBezierPath(ovalIn: NSRect(x: center.x - 2 * r, y: center.y - 2 * r, width: 2 * r, height: 2 * r)).fill()
        NSBezierPath(ovalIn: NSRect(x: center.x, y: center.y - 2 * r, width: 2 * r, height: 2 * r)).fill()
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: center.x - 2 * r + 0.2, y: center.y - r * 0.8))
        tip.line(to: NSPoint(x: center.x + 2 * r - 0.2, y: center.y - r * 0.8))
        tip.line(to: NSPoint(x: center.x, y: center.y + 2 * r))
        tip.close()
        tip.fill()
    }

    static func mark(_ text: String, at point: NSPoint, size: CGFloat, alpha: CGFloat) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor(white: 1, alpha: alpha)])
    }

    /// chip：AI 页上的入口格（44pt，底色和别的入口一样暗，不带「?」「!」气泡和闪光——有事等你由对话卡的颜色说）
    static func image(_ pose: PetPose, time: Double, animated: Bool, home: Bool = false, chip: Bool = false) -> NSImage {
        let px = home ? homePixel : pixel
        let boxWidth = chip ? TouchBarArt.chipWidth : home ? homeWidth : width
        let unit = px / pixel
        return TouchBarArt.image(width: boxWidth) { rect in
            TouchBarArt.pill(rect, chip ? TouchBarArt.chipFill : NSColor(white: 1, alpha: 0.1))
            let spriteWidth = 16 * px
            let base = (TouchBarArt.height - 12 * px) / 2
            let center = (boxWidth - spriteWidth) / 2
            switch pose {
            case .running:
                let step = animated && Int(time * 6) % 2 == 1
                draw(step ? walkB : walkA, at: NSPoint(x: center, y: base + (step ? -1 : 0)), pixel: px)
            case .waiting:
                draw(sit, at: NSPoint(x: center - 2 * unit, y: base), pixel: px)
                if !chip && (!animated || Int(time * 2) % 2 == 0) { bubble("?", color: .systemOrange, at: NSPoint(x: center + spriteWidth - 8 * unit, y: 1)) }
            case .done:
                let hop = animated ? abs(sin(time * 5)) * 4 * unit : 0
                draw(hop > 2 * unit ? jump : walkA, at: NSPoint(x: center, y: base - hop), pixel: px)
                if !chip { spark(at: NSPoint(x: center + spriteWidth + 1 * unit, y: 6 * unit), size: (animated ? 2.5 + 1.5 * abs(sin(time * 7)) : 3) * unit) }
            case .error:
                let shake = animated ? CGFloat(sin(time * 40)) : 0
                draw(startled, at: NSPoint(x: center - 2 * unit + shake, y: base), pixel: px)
                if !chip { bubble("!", color: .systemRed, at: NSPoint(x: center + spriteWidth - 8 * unit, y: 1)) }
            case .idle:
                draw(sleep, at: NSPoint(x: center - 1 * unit, y: base), pixel: px)
                let rise = animated ? CGFloat(time.truncatingRemainder(dividingBy: 2)) * 1.5 : 0
                mark("z", at: NSPoint(x: center + spriteWidth - 3 * unit, y: 4 * unit - rise), size: 8 * unit, alpha: 0.45)
            case .focus:
                // 看书：隔一会儿翻一页（书页那两块亮一下）
                let flip = animated && Int(time * 2) % 4 == 3
                draw(closed(sit), at: NSPoint(x: center, y: base), pixel: px)
                draw(flip ? book.map { $0.replacingOccurrences(of: "w", with: "c") } : book, at: NSPoint(x: center, y: base), pixel: px)
            case .rest:
                let reach = animated && Int(time * 2) % 2 == 1 ? 1 * unit : 0
                draw(stretch, at: NSPoint(x: center + reach, y: base), pixel: px)
            case .music:
                let bob = animated ? CGFloat(sin(time * 6)) * 1.5 * unit : 0
                draw(closed(sit), at: NSPoint(x: center - 3 * unit, y: base), pixel: px)
                mark("♪", at: NSPoint(x: center + spriteWidth - 6 * unit, y: 1 + bob), size: 9 * unit, alpha: 0.8)
            case .happy:
                draw(content, at: NSPoint(x: center - 3 * unit, y: base), pixel: px)
                // 两颗爱心错开往上飘
                for phase in [0.0, 0.5] {
                    let t = (time / 1.2 + phase).truncatingRemainder(dividingBy: 1)
                    let y = (TouchBarArt.height - 6) - CGFloat(t) * (TouchBarArt.height - 10)
                    let x = center + spriteWidth - (phase == 0 ? 3 : 8) * unit
                    heart(at: NSPoint(x: x, y: y), size: (phase == 0 ? 6 : 5) * unit, alpha: animated ? 1 - CGFloat(t) * 0.6 : 1)
                }
            }
        }
    }

    /// 小猫说的话：左边带个小尖角的气泡，上面一句、下面一行小字
    static func say(_ title: String, subtitle: String, color: NSColor?, width: CGFloat) -> NSImage {
        TouchBarArt.image(width: width) { rect in
            let tail: CGFloat = 5
            let middle = rect.height / 2
            let path = NSBezierPath(roundedRect: NSRect(x: tail, y: 0, width: width - tail, height: rect.height), xRadius: 6, yRadius: 6)
            path.move(to: NSPoint(x: 0, y: middle))
            path.line(to: NSPoint(x: tail, y: middle - 4))
            path.line(to: NSPoint(x: tail, y: middle + 4))
            path.close()
            (color?.withAlphaComponent(0.24) ?? NSColor(white: 1, alpha: 0.11)).setFill()
            path.fill()
            let heading = TouchBarArt.fit(title, width: width - tail - 14, font: TouchBarArt.nameFont)
            let sub = TouchBarArt.fit(subtitle, width: width - tail - 14, font: TouchBarArt.infoFont)
            (heading as NSString).draw(at: NSPoint(x: tail + 7, y: 1), withAttributes: [.font: TouchBarArt.nameFont, .foregroundColor: NSColor.labelColor])
            (sub as NSString).draw(at: NSPoint(x: tail + 7, y: 16), withAttributes: [.font: TouchBarArt.infoFont, .foregroundColor: color ?? NSColor.secondaryLabelColor])
        }
    }
}

// MARK: - 小猫的家（总览里点小猫进来）：它说的一句话（点了直接去那件事）、番茄钟、呼吸、待处理、摸摸

struct PetLine {
    let title: String
    let subtitle: String
    let color: NSColor?
    let action: TouchBarItem.DetailAction
}

/// 小猫说话要看的东西
struct PetContext {
    var lights: [TouchBarItem.TaskItem] = []
    var calm: CalmState = .none
    var rows: [Provider] = []
    var song: String?
    var pats = 0
    var receipts: [String: ReceiptSlot] = [:]      // 已经按轮次核对过的本轮小票
    var customLights: [CustomLight] = []           // 全部的灯（被挤出显示的也在）：叫过你的那盏要能找到
    var news: PetNews?                             // 刚「做完叫我」叫过你的那件
    var now = Date()
}

extension TouchBarItem {
    static let petSayWidth: CGFloat = 176
    static let petFocusWidth: CGFloat = 96
    static let petBreathWidth: CGFloat = 64
    static let petAttentionWidth: CGFloat = 84
    static let petPatWidth: CGFloat = 52
    static let petPhrases = ["喵～", "呼噜呼噜…", "蹭蹭你", "开心！"]
    static let petQuotaWarning: Double = 80

    static func petPart(_ pose: PetPose, elapsed: TimeInterval) -> Part {
        Part(image: PetArt.image(pose, time: elapsed, animated: PetArt.animating(pose, elapsed: elapsed)), action: .pet, id: "pet",
             label: pose.label + "。点开小猫的家：番茄钟、呼吸、歌词")
    }

    /// AI 页上的小猫：44pt 入口格，没有气泡和闪光
    static func petChip(_ pose: PetPose, elapsed: TimeInterval) -> Part {
        Part(image: PetArt.image(pose, time: elapsed, animated: PetArt.animating(pose, elapsed: elapsed), chip: true), action: .pet, id: "pet",
             label: pose.label + "。点开小猫的家：番茄钟、呼吸、歌词")
    }

    /// 小猫说什么：刚「做完叫我」叫过你的那件（三分钟内）先说；然后是等你、出错、刚完成的那件（点了直接去），
    /// 再是专注、休息、在跑的任务、在听的歌；都没事时看额度，哪家用过 80% 提一句，不然就睡觉
    static func petLine(_ pose: PetPose, _ context: PetContext) -> PetLine {
        let now = context.now
        if pose != .happy, let news = context.news, news.fresh(at: now), let line = newsLine(news, context) { return line }
        let items = Attention.items(from: context.lights)
        func first(_ light: Light) -> PetLine? {
            items.first { $0.light == light }.map { sessionLine((session: $0.session, light: $0.light), context) }
        }
        switch pose {
        case .waiting:
            if let line = first(.waiting) { return line }
        case .error:
            if let line = first(.error) { return line }
        case .done:
            if let line = first(.done) { return line }
        case .focus:
            if case .focus(_, let ends) = context.calm {
                return PetLine(title: "陪你专注", subtitle: "还剩 " + Focus.clock(ends.timeIntervalSince(now)) + " · 我在看书", color: nil, action: .calm)
            }
        case .rest:
            return PetLine(title: "休息一下", subtitle: "起来走走，伸个懒腰", color: .systemGreen, action: .calm)
        case .happy:
            return PetLine(title: petPhrases[max(0, context.pats - 1) % petPhrases.count], subtitle: "再摸摸？", color: PetArt.pink, action: .petPat)
        case .running:
            let running = context.lights.filter { $0.light == .running }
            if running.count == 1, let one = running.first { return sessionLine(one, context) }
            if running.count > 1 {
                return PetLine(title: "\(running.count) 个任务在跑", subtitle: running.map(\.session.displayTitle).joined(separator: " · "), color: nil, action: .chats)
            }
        case .music:
            if let song = context.song { return PetLine(title: "在听歌", subtitle: song, color: Breath.teal, action: .lyrics) }
        case .idle:
            break
        }
        // 都没事：哪家额度用得最多、过了 80% 就提一句（点了看额度详情）
        var worst: (name: String, window: QuotaWindow)?
        for provider in context.rows where !provider.isStale(at: now) {
            for window in provider.windows.map({ $0.effective(at: now) }) where window.used >= petQuotaWarning && window.used > (worst?.window.used ?? 0) {
                worst = (provider.name, window)
            }
        }
        if let worst {
            let reset = worst.window.resetsAt.map { Fmt.countdown($0.timeIntervalSince(now)) + "后重置" } ?? "省着点用"
            return PetLine(title: worst.name + " " + worst.window.label + "已用 " + Fmt.pct(worst.window.used), subtitle: reset,
                           color: worst.window.used >= 95 ? .systemRed : .systemOrange, action: .panel)
        }
        return PetLine(title: "都没事", subtitle: "我先睡会儿 · 摸摸我", color: nil, action: .petPat)
    }

    /// 一件 AI 任务怎么说：等你（等了多久）、出错、做完（有本轮小票就带上；测试或构建明确没过用橙色说出来）、在跑
    static func sessionLine(_ item: TaskItem, _ context: PetContext) -> PetLine {
        let session = item.session
        let seconds = context.now.timeIntervalSince(session.since)
        let age = seconds < 60 ? "刚刚" : Fmt.countdown(seconds)
        switch item.light {
        case .waiting:
            return PetLine(title: session.agentName + " " + session.waitingLabel, subtitle: "已等 " + age + " · " + session.displayTitle,
                           color: Light.waiting.color, action: .session(session.key))
        case .error:
            if session.errorType == "rate_limit" {
                if let resumeAt = session.resumeAt, resumeAt <= context.now {
                    return PetLine(title: session.agentName + " 额度应已恢复", subtitle: "可以接着做了 · " + session.displayTitle, color: Light.done.color,
                                   action: .session(session.key))
                }
                let when = session.resumeAt.map { (session.resumeApprox ? "约 " : "") + Fmt.shortClock($0, now: context.now) + " 恢复" } ?? "稍后再试"
                return PetLine(title: session.agentName + " 被限流了", subtitle: when + " · " + session.displayTitle, color: Light.error.color,
                               action: .session(session.key))
            }
            return PetLine(title: session.agentName + " 出错了", subtitle: session.displayTitle, color: Light.error.color, action: .session(session.key))
        case .done:
            guard case .ready(let receipt)? = context.receipts[session.key] else {
                return PetLine(title: session.agentName + " 做完了", subtitle: session.displayTitle, color: Light.done.color, action: .session(session.key))
            }
            let title = session.agentName + (receipt.failed ? (receipt.kind == .test ? " 做完了，但测试没过" : " 做完了，但构建没过") : " 做完了")
            return PetLine(title: title, subtitle: receipt.summary + " · " + session.displayTitle,
                           color: receipt.failed ? .systemOrange : Light.done.color, action: .session(session.key))
        case .running, .idle:
            return PetLine(title: session.agentName + " 在干活", subtitle: session.displayTitle + " · " + age, color: nil, action: .select(session.key))
        }
    }

    /// 刚叫过你的那件：会话按现在的样子说（小票晚到也能补上）；已经换了一轮、接着跑了，就不再说
    static func newsLine(_ news: PetNews, _ context: PetContext) -> PetLine? {
        if news.target.hasPrefix("session:") {
            let key = String(news.target.dropFirst("session:".count))
            guard let item = context.lights.first(where: { $0.session.key == key && $0.session.turnID == news.identity }),
                  [.done, .error, .waiting].contains(item.light) else { return nil }
            return sessionLine(item, context)
        }
        let name = String(news.target.dropFirst("light:".count))
        guard let light = context.customLights.first(where: { $0.name == name && AppModel.lightIdentity($0) == news.identity }),
              light.state != .running else { return nil }
        return PetLine(title: news.title, subtitle: CustomLights.summary(light, now: context.now),
                       color: light.light.loud ? light.light.color : nil, action: .none)
    }

    /// 读屏：它说的话，再说清楚点了去哪
    static func petLabel(_ line: PetLine) -> String {
        let hint: String
        switch line.action {
        case .session: hint = "点了打开这条对话"
        case .select: hint = "点了看这个任务"
        case .calm: hint = "点了去番茄钟"
        case .lyrics: hint = "点了看歌词"
        case .panel: hint = "点了看额度详情"
        case .petPat: hint = "点了摸摸它"
        case .chats: hint = "点了看全部对话"
        default: hint = ""
        }
        let said = line.title + "，" + line.subtitle
        guard !hint.isEmpty else { return said }
        return said + ("？！。…".contains(said.last ?? " ") ? "" : "。") + hint
    }

    /// 小猫的家（放松的）：小猫和它说的话、番茄钟和呼吸、歌词卡（tools，在放时）、摸摸。
    /// showPet 为 false（菜单栏里关掉了小猫）时只放番茄钟、呼吸和歌词卡
    static func petHomeImages(pose: PetPose, elapsed: TimeInterval, _ context: PetContext, tools: [Part] = [], showPet: Bool = true) -> [Part] {
        let now = context.now
        var parts: [Part] = []
        if showPet {
            let line = petLine(pose, context)
            parts.append(Part(image: PetArt.image(pose, time: elapsed, animated: PetArt.animating(pose, elapsed: elapsed), home: true),
                              action: .petPat, id: "pet:cat", label: pose.label + "。点它摸摸"))
            parts.append(Part(image: PetArt.say(line.title, subtitle: line.subtitle, color: line.color, width: petSayWidth), action: line.action,
                              id: "pet:say", label: petLabel(line)))
        }
        // 番茄钟：没开始时点了就开始；开始了只显示剩多少、点了去番茄钟页（那里能停），不会重新开始
        switch context.calm {
        case .none:
            parts.append(Part(image: TouchBarArt.card("专注", subtitle: "番茄钟 25 分钟", width: petFocusWidth), action: .startFocus, id: "pet:focus",
                              label: "开始专注 25 分钟"))
            parts.append(Part(image: TouchBarArt.card("呼吸", subtitle: "1 分钟", width: petBreathWidth, color: Breath.teal), action: .startBreath,
                              id: "pet:breath", label: "开始 4-7-8 呼吸，约 1 分钟"))
        case .focus(_, let ends):
            let remaining = ends.timeIntervalSince(now)
            parts.append(Part(image: TouchBarArt.card("专注中", subtitle: "还剩 " + Focus.clock(remaining), width: petFocusWidth,
                                                      color: remaining < Focus.lateAt ? .systemOrange : nil),
                              action: .calm, id: "pet:focus", label: "专注中，还剩 " + Focus.clock(remaining) + "。点开可以停止"))
        case .rest:
            parts.append(Part(image: TouchBarArt.card("休息中", subtitle: "点开结束", width: petFocusWidth, color: .systemGreen),
                              action: .calm, id: "pet:focus", label: "专注结束，在休息。点开结束"))
        case .breath(let started, _):
            parts.append(Part(image: TouchBarArt.card("呼吸中", subtitle: Breath.state(at: now.timeIntervalSince(started)).name, width: petFocusWidth,
                                                      color: Breath.teal), action: .calm, id: "pet:focus", label: "呼吸中"))
        }
        parts += tools
        if showPet { parts.append(Part(image: TouchBarArt.card("摸摸", width: petPatWidth), action: .petPat, id: "pet:pat", label: "摸摸小猫")) }
        return parts
    }
}

extension Snapshot {
    /// 小猫的家：有任务等你时、专注时、都没事但额度快满时、刚摸过
    static func writePetHome(dir: String, rows: [Provider], now: Date) {
        let lights: [TouchBarItem.TaskItem] = demoSessions(now: now).map { session in
            (session, session.state == .waiting ? .waiting : session.state == .done ? .done : .running)
        }
        let back = TouchBarArt.card("‹", width: TouchBarItem.backWidth)
        func home(_ pose: PetPose, _ lights: [TouchBarItem.TaskItem], calm: CalmState = .none, song: String? = nil, pats: Int = 0, file: String) {
            let parts = TouchBarItem.petHomeImages(pose: pose, elapsed: 10,
                                                   PetContext(lights: lights, calm: calm, rows: rows, song: song, pats: pats, now: now),
                                                   tools: [TouchBarItem.lyricCard(song.map {
                                                       NowLyric(site: "bilibili", title: $0, line: "刮风这天", next: "", kind: "lyrics", playing: true, received: now)
                                                   }, now: now), TouchBarItem.pianoCard].compactMap { $0 })
            touchBar([back] + parts.map(\.image), to: "\(dir)/\(file).png")
        }
        home(.waiting, lights, file: "touchbar-pet-home")
        home(.focus, lights.filter { $0.light == .running }, calm: .focus(started: now.addingTimeInterval(-600), ends: now.addingTimeInterval(900)),
             file: "touchbar-pet-home-focus")
        home(.idle, [], file: "touchbar-pet-home-idle")
        home(.happy, [], pats: 1, file: "touchbar-pet-home-happy")
        home(.music, [], song: "晴天", file: "touchbar-pet-home-music")
    }
}
