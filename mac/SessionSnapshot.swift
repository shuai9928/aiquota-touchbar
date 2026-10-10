import Foundation

/// `AIQuota --sessions-json`：给别的机器（Windows 上的小乔）拉的一次性快照，打印到标准输出。
/// 每个还亮着灯的会话一条：状态、灯、标题、时间；在跑、等你、出错的会话再带这一轮的路线图（steps）
/// 和最近三个动作（actions，新的在前，小乔头顶的思维链直接用）。
/// 只读：不整理会话文件、不写任何东西、不联网。内容和触控栏路线图一个口径——工具名、文件名、命令开头和成败，
/// 没有对话内容、没有完整路径（项目只给文件夹名）。
@MainActor
enum SessionSnapshot {
    static let schemaVersion = 1
    static let maxRoads = 4                 // 最多给几条会话算路线图（每条都要读一段记录）
    static let readCap = 2 << 20            // 每条只读这一轮最后 2MB：Windows 每 30 秒拉一次，不能每次都把整轮重新解析

    /// 和触控栏的灯一样的新鲜度（没有 Mac 上「点过就灭」那种交互）；nil 表示已经不亮了，不发
    static func light(_ s: AgentSession, now: Date) -> String? {
        let quiet = now.timeIntervalSince(s.updated)
        switch s.state {
        case .waiting: return quiet < SessionHook.waitingExpiry ? "waiting" : nil
        case .error: return quiet < 2 * 3600 ? "error" : nil
        case .running: return quiet < 3 * 3600 ? "running" : nil
        case .done:
            if now.timeIntervalSince(s.since) < 20 * 60 { return "done" }
            return quiet < 3600 ? "idle" : nil
        case .idle: return quiet < 3600 ? "idle" : nil
        }
    }

    static let urgency = ["waiting": 0, "error": 1, "done": 2, "running": 3, "idle": 4]

    /// 这一轮的记录：Claude / Codex 读 transcript 里这一轮的那段（最多最后 16MB），ZCode 读它的会话库
    static func parse(_ s: AgentSession) -> RoadParse? {
        if s.agent == "zcode" {
            guard let row = s.turnRow else { return nil }
            return ZcodeRoad.read(db: AppModel.zcodeDB, session: s.id, fromRow: row)
        }
        guard let start = s.turnStart, !s.transcript.isEmpty, let file = AppModel.fileIdentity(s.transcript), file.size >= start,
              s.turnInode == nil || s.turnInode == file.inode,
              let read = RoadmapBuilder.read(path: s.transcript, from: start, to: file.size, inode: s.turnInode, cap: readCap) else { return nil }
        return RoadmapBuilder.parse(read.data, cut: read.cut, codex: s.agent == "codex")
    }

    /// 发给别的机器的标题：只用真的标题（Claude 桌面 app 起的、Codex 线程名、ZCode 会话名）或项目文件夹名。
    /// 状态文件里的标题在临时文件夹里会退回成你说的第一句话，那句不发
    static func safeTitle(_ s: AgentSession) -> String {
        switch s.agent {
        case "claude": if let t = SessionHook.claudeTitle(s.transcript) { return t }
        case "codex": if let t = SessionHook.codexTitle(ids: [s.id, SessionHook.codexThreadId(s.transcript)].compactMap { $0 }) { return t }
        case "zcode": if let t = ZcodeRoad.title(db: AppModel.zcodeDB, session: s.id) { return t }
        default: break
        }
        return project(s)
    }

    static func project(_ s: AgentSession) -> String {
        guard !s.cwd.isEmpty, s.cwd != NSHomeDirectory(), !s.cwd.contains("/scratch-workspaces/") else { return "" }
        return (s.cwd as NSString).lastPathComponent
    }

    /// 一步写成一行人话：「改 Watch.swift（进行中）」「跑测试 test.sh · 过了」「等你批准」
    static func line(_ step: RoadStep, session: AgentSession) -> String {
        switch step.state {
        case .waiting: return session.waitingLabel
        default: break
        }
        var sub = step.sub == "—" ? "" : step.sub
        var doing = false
        if sub.hasPrefix("进行中") {
            doing = true
            sub = String(sub.dropFirst("进行中".count)).trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
        }
        return step.title + (sub.isEmpty ? "" : " " + sub) + (doing ? "（进行中）" : "")
    }

    static func state(_ state: RoadStep.State) -> String {
        switch state {
        case .done: return "done"
        case .current: return "current"
        case .todo: return "todo"
        case .failed: return "failed"
        case .waiting: return "waiting"
        }
    }

    static func build(sessions: [AgentSession], now: Date, parse: (AgentSession) -> RoadParse? = SessionSnapshot.parse,
                      title: (AgentSession) -> String = SessionSnapshot.safeTitle) -> [String: Any] {
        var lit: [(session: AgentSession, light: String)] = sessions.compactMap { s in light(s, now: now).map { (s, $0) } }
        lit.sort { (urgency[$0.light] ?? 9, -$0.session.updated.timeIntervalSince1970) < (urgency[$1.light] ?? 9, -$1.session.updated.timeIntervalSince1970) }
        var roads = 0
        let out: [[String: Any]] = lit.map { item in
            let s = item.session
            var o: [String: Any] = ["key": s.key, "agent": s.agent, "id": s.id, "state": s.state.rawValue, "light": item.light,
                                    "title": title(s), "project": project(s),
                                    "updated": s.updated.timeIntervalSince1970, "since": s.since.timeIntervalSince1970]
            if let turnID = s.turnID { o["turnID"] = turnID }
            if s.state == .waiting { o["waitReason"] = s.waitReason }
            if !s.errorType.isEmpty { o["errorType"] = s.errorType }
            if s.interrupted { o["interrupted"] = true }
            if s.background > 0 { o["background"] = s.background }
            if [.running, .waiting, .error].contains(s.state), roads < maxRoads, var parsed = parse(s) {
                roads += 1
                // ZCode 的「想」是它明文的推理，留在本机的触控栏上，不发到别的机器
                parsed.actions.removeAll { $0.kind == .think }
                if s.state == .waiting && s.waitReason == "question" { parsed.actions.removeAll { $0.kind == .ask } }   // 不和「等你回答」说两遍
                let errorText = s.state == .error ? s.briefStatus(.error, now: now) : nil
                if let full = RoadmapBuilder.roadmap(s, parse: parsed, errorText: errorText, now: now) {
                    let road = full.windowed(RoadmapBuilder.visibleSteps)      // Windows 小乔的屏幕小：一直是 8 步一段（触控栏上的更长，可以划）
                    o["steps"] = road.steps.map { ["title": $0.title, "sub": $0.sub == "—" ? "" : $0.sub, "state": state($0.state)] }
                    o["hidden"] = road.hidden
                    o["plan"] = road.plan
                }
                // 思维链用的：实际走过的路里最新的三步，新的在前（有待办清单时也一样，清单里还没做的不算）；「开始了」不算
                let trail = RoadmapBuilder.trail(parsed, state: s.state, open: s.key, errorText: errorText, took: nil, now: now).steps
                let real = trail.filter { !($0.title == "开始了" && $0.sub == "还没动手") }
                o["actions"] = Array(real.reversed().prefix(3)).map { line($0, session: s) }
            }
            return o
        }
        return ["schemaVersion": schemaVersion, "source": "mac", "generated": now.timeIntervalSince1970, "sessions": out]
    }

    static func run() {
        let now = Date()
        let sessions = SessionFiles.records().compactMap { SessionFiles.session($0.rec) }
        let object = build(sessions: sessions, now: now)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { exit(1) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
