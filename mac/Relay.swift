import AppKit

struct HandoffNote: Equatable {
    let file: String
    let from: String
    let to: String
    let project: String
    let modified: Date
}

enum RelayTone: Equatable {
    case quiet, working, turn
}

enum RelayAvailability: Equatable {
    case ready
    case exhausted(Date?)
}

enum RelayCommand: Equatable {
    case hand(String, String)
    case note(String)
}

struct RelayPair {
    let cwd: String
    let claude: TouchBarItem.TaskItem
    let codex: TouchBarItem.TaskItem
    let tone: RelayTone
    let next: String?
    let note: HandoffNote?

    var project: String { (cwd as NSString).lastPathComponent }

    func entry(_ agent: String) -> TouchBarItem.TaskItem { agent == "codex" ? codex : claude }

    var targets: [String] {
        switch tone {
        case .turn: return next.map { [$0] } ?? []
        case .quiet: return ["codex", "claude"]
        case .working: return []
        }
    }

    private func busy(_ entry: TouchBarItem.TaskItem) -> String? {
        switch entry.light {
        case .running: return entry.session.agentName + " 在跑"
        case .waiting: return entry.session.agentName + " 在等你"
        default: return nil
        }
    }

    var summary: String {
        switch tone {
        case .turn:
            guard let next else { return "都停着" }
            let from = Relay.name(Relay.other(next))
            return (note != nil ? from + " 留了交接说明" : from + " 完成了") + " → 轮到 " + Relay.name(next)
        case .working:
            let states = [busy(claude), busy(codex)].compactMap { $0 }
            if let note, let next { return Relay.name(note.from) + " 留了交接说明，" + (states.first ?? Relay.name(next) + " 在忙") }
            return states.isEmpty ? "在忙" : states.joined(separator: "，")
        case .quiet:
            return "都停着"
        }
    }

    var short: String {
        switch tone {
        case .turn: return next.map { "轮到 " + Relay.name($0) } ?? "都停着"
        case .working: return [claude, codex].allSatisfy { busy($0) != nil } ? "两边在忙" : ([busy(claude), busy(codex)].compactMap { $0 }.first ?? "在忙")
        case .quiet: return "都停着"
        }
    }
}

enum Relay {
    static let folder = "~/.ai-handoff"
    static var folderURL: URL { URL(fileURLWithPath: expand(folder)) }

    static func name(_ agent: String) -> String { agent == "codex" ? "Codex" : "Claude" }
    static func other(_ agent: String) -> String { agent == "codex" ? "claude" : "codex" }

    static func parse(_ file: String, modified: Date) -> HandoffNote? {
        let pattern = #"^(\d{8}-\d{4,6})-(claude|codex)-to-(claude|codex)-(.+)\.md$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: file, range: NSRange(file.startIndex..., in: file)) else { return nil }
        let groups = (1..<match.numberOfRanges).map { number in
            Range(match.range(at: number), in: file).map { String(file[$0]) } ?? ""
        }
        guard groups.count == 4, groups[1] != groups[2] else { return nil }
        return HandoffNote(file: file, from: groups[1], to: groups[2], project: groups[3], modified: modified)
    }

    static func notes(in folder: URL) -> [HandoffNote] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return parse(url.lastPathComponent, modified: values.contentModificationDate ?? .distantPast)
        }
        .sorted { ($0.modified, $0.file) < ($1.modified, $1.file) }
    }

    static func root(of cwd: String) -> String {
        let start = (cwd as NSString).standardizingPath
        var path = start
        while path.count > 1 {
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { return path }
            path = (path as NSString).deletingLastPathComponent
        }
        return start
    }

    static func groupRoots(_ roots: [String], home: String) -> [String: String] {
        let home = (home as NSString).standardizingPath
        let candidates = Set(roots).filter { $0 != home && !(home as NSString).hasPrefix($0 + "/") && $0 != "/" }
        var mapping: [String: String] = [:]
        for root in Set(roots) {
            let ancestors = candidates.filter { root == $0 || root.hasPrefix($0 + "/") }
            mapping[root] = ancestors.min { $0.count < $1.count } ?? root
        }
        return mapping
    }

    static func pairs(lights: [TouchBarItem.TaskItem], notes: [HandoffNote], home: String = NSHomeDirectory()) -> [RelayPair] {
        var claude: [String: TouchBarItem.TaskItem] = [:]
        var codex: [String: TouchBarItem.TaskItem] = [:]
        var order: [String] = []
        let usable = lights.filter { !$0.session.cwd.isEmpty }
        let roots = Dictionary(usable.map { ($0.session.cwd, root(of: $0.session.cwd)) }, uniquingKeysWith: { first, _ in first })
        let grouped = groupRoots(Array(roots.values), home: home)
        for entry in usable {
            let own = roots[entry.session.cwd] ?? entry.session.cwd
            let cwd = grouped[own] ?? own
            if cwd == (home as NSString).standardizingPath || cwd == "/" { continue }
            if claude[cwd] == nil && codex[cwd] == nil { order.append(cwd) }
            if entry.session.agent == "codex" {
                if codex[cwd].map({ $0.session.updated < entry.session.updated }) ?? true { codex[cwd] = entry }
            } else if claude[cwd].map({ $0.session.updated < entry.session.updated }) ?? true {
                claude[cwd] = entry
            }
        }
        return order.compactMap { cwd in
            guard let claudeEntry = claude[cwd], let codexEntry = codex[cwd] else { return nil }
            return pair(cwd: cwd, claude: claudeEntry, codex: codexEntry, notes: notes)
        }
    }

    static func pair(cwd: String, claude: TouchBarItem.TaskItem, codex: TouchBarItem.TaskItem, notes: [HandoffNote]) -> RelayPair {
        let project = (cwd as NSString).lastPathComponent
        let entries = ["claude": claude, "codex": codex]
        let busy: (TouchBarItem.TaskItem) -> Bool = { $0.light == .running || $0.light == .waiting }
        let names = Set([project] + [claude, codex].flatMap { item -> [String] in
            let path = (item.session.cwd as NSString).standardizingPath
            guard path.hasPrefix(cwd + "/") else { return [] }
            return path.dropFirst(cwd.count + 1).split(separator: "/").map(String.init)
        })
        let pending = notes.last { note in
            names.contains(note.project) && entries[note.to].map { note.modified > $0.session.updated } == true
        }
        if let pending, let target = entries[pending.to] {
            return RelayPair(cwd: cwd, claude: claude, codex: codex, tone: busy(target) ? .working : .turn, next: pending.to, note: pending)
        }
        let claudeDone = claude.light == .done, codexDone = codex.light == .done
        if claudeDone || codexDone {
            let finisher = claudeDone && codexDone ? (claude.session.since > codex.session.since ? "claude" : "codex") : (claudeDone ? "claude" : "codex")
            let next = other(finisher)
            let target = entries[next] ?? codex
            return RelayPair(cwd: cwd, claude: claude, codex: codex, tone: busy(target) ? .working : .turn,
                             next: busy(target) ? nil : next, note: nil)
        }
        let tone: RelayTone = busy(claude) || busy(codex) ? .working : .quiet
        return RelayPair(cwd: cwd, claude: claude, codex: codex, tone: tone, next: nil, note: nil)
    }

    static func availability(_ provider: Provider?, now: Date) -> RelayAvailability {
        guard let provider else { return .ready }
        let full = provider.windows.map { $0.effective(at: now) }.filter { $0.used >= 100 }
        guard !full.isEmpty else { return .ready }
        return .exhausted(full.compactMap(\.resetsAt).max())
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }

    static func sentence(for pair: RelayPair, to agent: String, now: Date) -> String {
        if let note = pair.note, note.to == agent {
            return "请读交接说明 \(folder)/\(note.file)，按里面的要求继续；开始处理后把它移到 \(folder)/done/。"
        }
        if agent == "codex" {
            return "Claude 刚在 \(pair.cwd) 改完一轮。请审查这里未提交的改动（git status、git diff），"
                + "把审查意见写到 \(folder)/\(stamp(now))-codex-to-claude-\(pair.project).md。"
        }
        return "Codex 刚在 \(pair.cwd) 完成一轮。请按它的结论继续；如果它写了交接说明，"
            + "在 \(folder)/ 里找最新的 *-codex-to-claude-\(pair.project).md，读完移到 \(folder)/done/。"
    }
}

extension TouchBarArt {
    struct GlancePair: Equatable {
        let first: Int
        let second: Int
        let tone: RelayTone
    }

    static func glanceUnits(lights: [Light], pairs: [GlancePair], slots: Int) -> [[Int]] {
        var partner: [Int: Int] = [:]
        for pair in pairs where pair.first != pair.second && lights.indices.contains(pair.first) && lights.indices.contains(pair.second) {
            if partner[pair.first] == nil && partner[pair.second] == nil {
                partner[pair.first] = pair.second
                partner[pair.second] = pair.first
            }
        }
        var chosen: [[Int]] = []
        var taken = Set<Int>()
        var used = 0
        for index in Light.urgentFirst(lights) where !taken.contains(index) {
            if let mate = partner[index], !taken.contains(mate), used + 2 <= slots {
                chosen.append([min(index, mate), max(index, mate)])
                taken.formUnion([index, mate])
                used += 2
            } else if used < slots {
                chosen.append([index])
                taken.insert(index)
                used += 1
            }
        }
        return chosen.sorted { $0[0] < $1[0] }
    }

    static func relayColor(_ tone: RelayTone) -> NSColor {
        tone == .turn ? .systemGreen : NSColor(white: 1, alpha: 0.45)
    }
}

extension TouchBarItem {
    static let relayCardWidth: CGFloat = 92
    static let relayButtonWidth: CGFloat = 128

    static func glancePairs(_ relays: [RelayPair], lights: [TaskItem]) -> [TouchBarArt.GlancePair] {
        relays.compactMap { pair in
            guard let claudeIndex = lights.firstIndex(where: { $0.session.key == pair.claude.session.key }),
                  let codexIndex = lights.firstIndex(where: { $0.session.key == pair.codex.session.key }) else { return nil }
            return TouchBarArt.GlancePair(first: min(claudeIndex, codexIndex), second: max(claudeIndex, codexIndex), tone: pair.tone)
        }
    }

    static func relayCard(_ pairs: [RelayPair]) -> Part {
        let lead = pairs.first { $0.tone == .turn } ?? pairs.first
        return Part(image: TouchBarArt.card(pairs.count > 1 ? "⇄ 接力 \(pairs.count)" : "⇄ 接力", subtitle: lead?.short ?? "",
                                            width: relayCardWidth, color: lead?.tone == .turn ? .systemGreen : nil),
                    action: .relay, id: "relay")
    }

    static func relayImages(_ pairs: [RelayPair], claude: Provider?, codex: Provider?, now: Date) -> [Part] {
        guard !pairs.isEmpty else {
            return [Part(image: TouchBarArt.card("没有接力", subtitle: "同一个项目里 Claude 和 Codex 都有任务时才会出现", width: 300),
                         action: .none, id: "relay:empty")]
        }
        var parts: [Part] = []
        for pair in pairs {
            parts.append(Part(image: TouchBarArt.card(pair.project, subtitle: pair.summary, width: 200, color: pair.tone == .turn ? .systemGreen : nil),
                              action: .none, id: "relay:" + pair.cwd))
            if let note = pair.note {
                parts.append(Part(image: TouchBarArt.card("看交接说明", subtitle: Relay.name(note.from) + " → " + Relay.name(note.to), width: 104),
                                  action: .relayNote(note.file), id: "relay:" + pair.cwd + ":note"))
            }
            for agent in pair.targets {
                let id = "relay:" + pair.cwd + ":to-" + agent
                let title = "交给 " + Relay.name(agent)
                switch Relay.availability(agent == "codex" ? codex : claude, now: now) {
                case .ready:
                    parts.append(Part(image: TouchBarArt.card(title, subtitle: "复制一句话并切过去", width: relayButtonWidth,
                                                              color: pair.next == agent ? .systemGreen : nil),
                                      action: .relayHand(pair.cwd, agent), id: id))
                case .exhausted(let reset):
                    parts.append(Part(image: TouchBarArt.card(title, subtitle: reset.map { "额度用完 · " + Fmt.shortClock($0, now: now) + " 恢复" } ?? "额度用完了",
                                                              width: relayButtonWidth, enabled: false),
                                      action: .none, id: id))
                }
            }
        }
        return parts
    }
}

extension AppModel {
    func reloadHandoffs() {
        let fresh = Relay.notes(in: handoffFolder)
        if fresh != handoffs { handoffs = fresh }
    }

    func relayPairs(at now: Date) -> [RelayPair] {
        Relay.pairs(lights: lights(at: now), notes: handoffs)
    }

    func relayCommand(_ command: RelayCommand) {
        let moment = Date()
        switch command {
        case .hand(let cwd, let agent):
            guard let pair = relayPairs(at: moment).first(where: { $0.cwd == cwd }) else { return }
            let target = pair.entry(agent).session
            if case .exhausted(let reset) = Relay.availability(agent == "codex" ? codex.first : claude, now: moment) {
                feedback(Relay.name(agent) + " 额度用完了" + (reset.map { "，" + Fmt.clock($0, now: moment) + " 恢复" } ?? ""), key: target.key)
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(Relay.sentence(for: pair, to: agent, now: moment), forType: .string)
            feedback("已复制交接的话，切到 \(Relay.name(agent)) 后按 ⌘V 回车发送", key: target.key)
            open(target.key)
        case .note(let file):
            guard handoffs.contains(where: { $0.file == file }) else { return }
            _ = openURL(handoffFolder.appendingPathComponent(file))
        }
    }
}
