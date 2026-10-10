import AppKit
import SQLite3

/// SQLite3 模块不暴露这个 C 宏，绑定字符串要用它
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// 工作流路线图：Claude / Codex 这一轮实际走过的路（读了什么、改了什么、跑了什么、成没成），Claude 写过待办清单（TodoWrite）时改画那份计划。
/// 只看工具名、文件名、命令开头和成败，不看对话内容，不落盘。推理的文字不画（转录里大多是空的，Codex 的是加密的）。
struct RoadStep: Equatable {
    enum State: Equatable { case done, current, todo, failed, waiting }
    var title: String
    var sub: String
    var state: State
    var open: String? = nil        // 点了打开哪个会话（当前这步、等你、失败）
}

struct Roadmap: Equatable {
    var key: String                // 会话 key
    var turnID: String
    var steps: [RoadStep]
    var hidden: Int                // 前面折起来的步数
    var finished: Bool             // 这一轮已经做完
    var plan: Bool                 // 画的是 AI 写的待办清单，不是走过的路
    var dismissKey: String { key + "|" + turnID }

    /// 只留 n 步的版本（给 Windows 小乔的快照用：它的屏幕小，一直是最后 8 步；清单则以正在做的那步为中心取一段），前面的算进 hidden
    func windowed(_ n: Int) -> Roadmap {
        guard n > 0, steps.count > n else { return self }
        let start: Int
        if plan {
            let focus = steps.firstIndex { $0.state == .current || $0.state == .waiting } ?? steps.firstIndex { $0.state == .todo } ?? steps.count - 1
            start = max(0, min(focus - 2, steps.count - n))
        } else {
            start = steps.count - n
        }
        var out = self
        out.steps = Array(steps[start..<(start + n)])
        out.hidden = hidden + start
        return out
    }
}

struct RoadAction: Equatable {
    enum Kind: String { case read, edit, write, test, build, command, search, web, agent, skill, tool, ask, think, pc, codex, other }
    var kind: Kind
    var object: String
    var done = false               // 已经有结果了
    var failed = false
    var verified = false           // 测试/构建：是单条前台命令，成功返回才算「过了」（管道、后台跑的看不出）
    var at: Date?
}

struct RoadPlanItem: Equatable {
    enum Status: String { case pending, inProgress = "in_progress", completed }
    var text: String
    var status: Status
}

/// Codex 还没返回的一次工具调用：一段脚本里按顺序要做的几件事，已经做完了几件
struct RoadCall: Equatable {
    var id: String
    var steps: [RoadAction]
    var progress = 0
    var pending: RoadAction? { steps.indices.contains(progress) ? steps[progress] : nil }
}

struct RoadParse: Equatable {
    var actions: [RoadAction] = []
    var plan: [RoadPlanItem]?
    var cut = false                // 这一轮太长，只读了最后一段
    var consumed = 0               // 已经解析了多少字节（只数完整的行）：下次只读后面追加的
    var index: [String: Int] = [:] // tool_use id → actions 里的位置，等结果回来时对上
    var calls: [RoadCall] = []     // Codex：发出去还没返回的调用（它的动作做完才记，正在做的只能从这里看）

    /// 在跑时正在做的那件（Codex 用；Claude 的没返回的动作本身就在 actions 里）
    var pending: RoadAction? { calls.last?.pending }
}

enum RoadmapBuilder {
    static let cap = 16 << 20                        // 一轮特别长时最多从最后 16MB 读起
    static let hugeLine = 32 * 1024                  // 这么大的结果行（截图、长输出）不整段解析，只取 id 和成败
    static let keepSteps = 40                        // 触控栏上的路线图最多留这么多步（再长的前面折成「+N」）；放得下就整条摆，放不下就左右划
    static let visibleSteps = 8                      // 给 Windows 小乔的快照只取这么多步（它的屏幕小），见 Roadmap.windowed
    static let doneKeep: TimeInterval = 12 * 3600    // 做完后一直留着最后一次路线，放了半天以上的旧路线不再留

    /// 从 start 读到 end（太长只读最后 16MB，去掉被截断的第一行）；换了文件、变短了读不了
    static func read(path: String, from start: Int, to end: Int, inode: UInt64?, cap: Int = cap) -> (data: Data, cut: Bool)? {
        guard start >= 0, end >= start, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, inode == nil || UInt64(info.st_ino) == inode, Int(info.st_size) >= end else { return nil }
        let from = max(start, end - cap)
        guard (try? handle.seek(toOffset: UInt64(from))) != nil, let data = try? handle.read(upToCount: end - from), data.count == end - from else { return nil }
        if from > start, let newline = data.firstIndex(of: UInt8(ascii: "\n")) { return (data.subdata(in: data.index(after: newline)..<data.endIndex), true) }
        return (data, from > start)
    }

    static func parse(_ data: Data, cut: Bool = false, codex: Bool = false) -> RoadParse {
        var out = RoadParse()
        out.cut = cut
        out.consumed = feed(&out, data, codex: codex)
        return out
    }

    /// 接着解析新追加的数据：只吃完整的行，返回吃了多少字节（最后没写完的半行留到下次）
    @discardableResult
    static func feed(_ out: inout RoadParse, _ data: Data, codex: Bool = false) -> Int {
        if codex { return CodexRoad.feed(&out, data) }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        let marker = Data("\"tool_".utf8)
        let userMarker = Data("\"type\":\"user\"".utf8)
        for line in complete.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
            if line.count > hugeLine, line.range(of: userMarker) != nil {
                // 截图、长输出这种大结果行：不整段解析，取 id；明确报了非零退出的算失败
                if let id = toolUseID(line), let position = out.index[id] {
                    out.actions[position].done = true
                    if line.range(of: Data("\"is_error\":true".utf8)) != nil, line.range(of: Data("Exit code".utf8)) != nil { out.actions[position].failed = true }
                }
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, type == "assistant" || type == "user",
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let at = (object["timestamp"] as? String).flatMap(SessionFiles.parseStamp)
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
                        out.plan = todos.compactMap { item in
                            guard let text = item["content"] as? String, let status = (item["status"] as? String).flatMap(RoadPlanItem.Status.init(rawValue:)) else { return nil }
                            return RoadPlanItem(text: text, status: status)
                        }
                        continue
                    }
                    var action = classify(name: name, input: input)
                    action.at = at
                    out.index[id] = out.actions.count
                    out.actions.append(action)
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String, let position = out.index[id] else { continue }
                    out.actions[position].done = true
                    if block["is_error"] as? Bool == true, TurnReceipts.text(block["content"]).hasPrefix("Exit code") { out.actions[position].failed = true }
                default:
                    break
                }
            }
        }
        return complete.count
    }

    /// 大结果行里的 "tool_use_id":"…"
    static func toolUseID(_ line: Data) -> String? {
        guard let marker = line.range(of: Data("\"tool_use_id\":\"".utf8)) else { return nil }
        let rest = line[marker.upperBound...]
        guard let quote = rest.prefix(80).firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(data: rest[rest.startIndex..<quote], encoding: .utf8)
    }

    static func base(_ path: Any?) -> String {
        ((path as? String ?? "") as NSString).lastPathComponent
    }

    static func classify(name: String, input: [String: Any]) -> RoadAction {
        switch name {
        case "Read": return RoadAction(kind: .read, object: base(input["file_path"]))
        case "Edit", "MultiEdit": return RoadAction(kind: .edit, object: base(input["file_path"]))
        case "NotebookEdit": return RoadAction(kind: .edit, object: base(input["notebook_path"]))
        case "Write": return RoadAction(kind: .write, object: base(input["file_path"]))
        case "Grep", "Glob": return RoadAction(kind: .search, object: input["pattern"] as? String ?? "")
        case "WebFetch": return RoadAction(kind: .web, object: "读网页")
        case "WebSearch": return RoadAction(kind: .web, object: "搜网页")
        case "Workflow": return RoadAction(kind: .agent, object: input["name"] as? String ?? "工作流")
        case "Agent", "Task": return RoadAction(kind: .agent, object: input["description"] as? String ?? "子代理")
        case "SendMessage", "ListAgents", "TaskStop": return RoadAction(kind: .agent, object: "协调子代理")
        case "Skill": return RoadAction(kind: .skill, object: input["skill"] as? String ?? "")
        case "AskUserQuestion": return RoadAction(kind: .ask, object: "等你回答")
        case "Bash":
            let command = input["command"] as? String ?? ""
            if let found = TurnReceipts.check(command) {
                return RoadAction(kind: found.kind == .test ? .test : .build, object: found.label, verified: found.trusted && input["run_in_background"] as? Bool != true)
            }
            return shellAction(command)
        default:
            return name.hasPrefix("mcp__") ? RoadAction(kind: .tool, object: name.components(separatedBy: "__").last ?? "") : RoadAction(kind: .other, object: name)
        }
    }

    /// 命令开头里有意义的词：跳过 cd、开头的环境变量赋值
    static func leadingWords(_ command: String) -> [String] {
        // 只看第一行：heredoc 的正文里有个单引号（Don't）也不会让整条命令认不出来
        let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let pieces = TurnReceipts.segments(line) ?? []
        let words = ((pieces.first { $0.words.first != "cd" } ?? pieces.first)?.words ?? []).drop { $0.contains("=") && !$0.hasPrefix("-") }
        return Array(words)
    }

    /// 第二个词只在这些「主命令 + 子命令」的程序后面写（git status、npm install）；别的程序后面的词可能是密码、
    /// 连接串、要搜的内容，一律不写
    static let subcommandPrograms: Set<String> = ["git", "npm", "pnpm", "yarn", "bun", "npx", "pip", "pip3", "uv", "poetry", "docker",
                                                  "kubectl", "cargo", "go", "swift", "dotnet", "brew", "apt", "gh", "make",
                                                  "python", "python3", "py", "node", "deno", "ruby", "bash", "sh", "zsh", "xcrun", "launchctl"]

    /// 命令简称：程序名（只要文件名）+ 必要时一个子命令。export、env 这类只写命令名，环境变量赋值、参数、
    /// URL、引号里的内容都不写——路线图会显示到触控栏，也会同步到 Windows 小乔的头顶
    static func brief(_ command: String) -> String {
        let words = leadingWords(command)
        guard let raw = words.first else { return "" }
        let first = base(raw)
        guard first.range(of: #"^[A-Za-z0-9._+-]{1,24}$"#, options: .regularExpression) != nil else { return "" }
        if ["export", "env", "set", "unset", "declare"].contains(first) { return first }
        guard subcommandPrograms.contains(first), let second = words.dropFirst().first,
              second.range(of: #"^[A-Za-z][A-Za-z0-9._-]{0,24}$"#, options: .regularExpression) != nil else { return first }
        return first + " " + second
    }

    /// 命令按第一个词分：读文件、搜索、在 PC 上（ssh 系）、请 Codex；测试构建已经先认过了，其余都算「命令」。
    /// 读文件和搜索大多是 shell 拼的，不分类的话路线图上满屏都是「命令 ×N」
    static func shellKind(_ command: String) -> RoadAction.Kind {
        guard let first = leadingWords(command).first else { return .command }
        // cat > 文件 <<EOF、echo … > 文件、tee 文件：是在写文件，不是读
        if ["cat", "echo", "printf", "tee"].contains(first), first == "tee" || redirectTarget(command) != nil { return .write }
        if ["cat", "head", "tail", "less", "more", "wc", "stat", "file", "ls", "tree", "du", "df"].contains(first) { return .read }
        if ["grep", "egrep", "fgrep", "rg", "ag", "ack", "find", "fd", "locate", "mdfind"].contains(first) { return .search }
        if ["ssh", "scp", "sftp"].contains(first) { return .pc }
        if first == "codex" { return .codex }
        return .command
    }

    /// 一条 shell 命令（不是测试、构建）：按第一个词分类；写文件的写目标文件名，别的取开头两个词
    static func shellAction(_ command: String) -> RoadAction {
        let kind = shellKind(command)
        if kind == .write {
            let target = redirectTarget(command) ?? leadingWords(command).dropFirst().first { !$0.hasPrefix("-") }
            return RoadAction(kind: .write, object: base(target ?? ""))
        }
        return RoadAction(kind: kind, object: brief(command))
    }

    /// 第一行里输出重定向到的文件（> 文件、>> 文件）；2>&1、&> 这类不算
    static func redirectTarget(_ command: String) -> String? {
        // 引号里的 > 不是重定向（echo "=> done"、grep "-> Bool"），先把引号里的内容抹掉
        let line = (command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
            .replacingOccurrences(of: #""[^"]*"|'[^']*'"#, with: "_", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"(?<![0-9&>])>>?\s*([^\s;&|<>'\"]+)"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        let target = (line as NSString).substring(with: match.range(at: 1))
        return target.hasPrefix("&") || target == "/dev/null" ? nil : target
    }

    static func verb(_ kind: RoadAction.Kind) -> String {
        switch kind {
        case .read: return "读"
        case .edit: return "改"
        case .write: return "写"
        case .test: return "跑测试"
        case .build: return "构建"
        case .command: return "命令"
        case .search: return "搜索"
        case .pc: return "在 PC 上"
        case .codex: return "请 Codex"
        case .web: return "查网页"
        case .agent: return "子代理"
        case .skill: return "技能"
        case .tool: return "调用工具"
        case .ask: return "提问"
        case .think: return "想"
        case .other: return "其他"
        }
    }

    /// 连着做的同一种事合成一步（读 ×4）
    static func groups(_ actions: [RoadAction]) -> [(kind: RoadAction.Kind, count: Int, last: RoadAction)] {
        var out: [(kind: RoadAction.Kind, count: Int, last: RoadAction)] = []
        for action in actions {
            // 读、改、命令这些连着的合成一步；测试、构建只在是同一个目标、都没失败时合并；提问和失败的单独一步
            var mergeable = action.kind != .ask && !action.failed
            if mergeable, let last = out.last {
                mergeable = last.kind == action.kind && !last.last.failed && (![.test, .build].contains(action.kind) || last.last.object == action.object)
            }
            if mergeable, let last = out.last {
                out[out.count - 1] = (last.kind, last.count + 1, action)
            } else {
                out.append((action.kind, 1, action))
            }
        }
        return out
    }

    /// 走过的路；state 是会话现在的状态
    static func trail(_ parse: RoadParse, state: SessionState, open key: String, errorText: String? = nil, took: TimeInterval?, now: Date) -> (steps: [RoadStep], hidden: Int) {
        let running = state == .running
        var steps: [RoadStep] = []
        // Codex 正在做的那件还没进记录：在跑时接在最后，画成「进行中」
        let grouped = groups(parse.actions + (running ? parse.pending.map { [$0] } ?? [] : []))
        for (position, group) in grouped.enumerated() {
            let last = position == grouped.count - 1
            let title = verb(group.kind) + (group.count > 1 ? " ×\(group.count)" : "")
            var sub = group.last.object
            if group.count > 1, !sub.isEmpty, [.read, .edit, .write].contains(group.kind) { sub += " 等" }
            var stepState = RoadStep.State.done
            if group.last.failed {
                stepState = .failed
                sub = (sub.isEmpty ? "" : sub + " · ") + (group.kind == .test ? "没过" : "没成")
            } else if [.test, .build].contains(group.kind), group.last.done, group.last.verified {
                sub += " · 过了"
            }
            if last, running {
                stepState = group.last.failed ? .failed : .current
                if !group.last.done { sub = "进行中" + (sub.isEmpty ? "" : " · " + sub) }
            }
            steps.append(RoadStep(title: title, sub: sub.isEmpty ? "—" : sub, state: stepState, open: stepState == .current || stepState == .failed ? key : nil))
        }
        switch state {
        case .waiting: steps.append(RoadStep(title: "等你", sub: "点一下去处理", state: .waiting, open: key))
        case .error: steps.append(RoadStep(title: "出错了", sub: errorText ?? "点一下去看", state: .failed, open: key))
        case .done: steps.append(RoadStep(title: "完成", sub: took.map { "用了 " + Fmt.short($0) } ?? "做完了", state: .done, open: key))
        case .running, .idle: break
        }
        if steps.isEmpty { steps = [RoadStep(title: "开始了", sub: "还没动手", state: .current, open: key)] }
        let hidden = max(0, steps.count - keepSteps)
        return (Array(steps.suffix(keepSteps)), hidden)
    }

    /// 一个会话这一轮的路线图（触控栏和给 Windows 的快照用同一套）：AI 写了还没做完的待办清单就画清单，不然画走过的路
    static func roadmap(_ session: AgentSession, parse: RoadParse, errorText: String?, now: Date) -> Roadmap? {
        guard let turnID = session.turnID else { return nil }
        let took = session.turnAt.flatMap { start in session.turnEndedAt.map { $0.timeIntervalSince(start) } }
        let useful = parse.plan.map { plan in !plan.isEmpty && (session.state != .done || plan.contains { $0.status != .completed }) } ?? false
        let built: (steps: [RoadStep], hidden: Int)
        if useful, let plan = parse.plan {
            built = planSteps(plan, latest: parse.actions.last, state: session.state, open: session.key)
        } else {
            built = trail(parse, state: session.state, open: session.key, errorText: errorText, took: took, now: now)
        }
        return Roadmap(key: session.key, turnID: turnID, steps: built.steps, hidden: built.hidden + (parse.cut ? 1 : 0),
                       finished: session.state == .done, plan: useful)
    }

    /// AI 写的待办清单：做完的、正在做的、还没做的；正在做的那步下面写最近一个动作
    static func planSteps(_ items: [RoadPlanItem], latest: RoadAction?, state: SessionState, open key: String) -> (steps: [RoadStep], hidden: Int) {
        let current = items.firstIndex { $0.status == .inProgress } ?? items.firstIndex { $0.status == .pending } ?? items.count - 1
        let next = items.indices.contains(current) && items[current].status == .pending ? current
            : items.indices.first { $0 > current && items[$0].status == .pending }
        var steps: [RoadStep] = items.enumerated().map { position, item in
            switch item.status {
            case .completed: return RoadStep(title: item.text, sub: "做完了", state: .done)
            case .inProgress:
                let doing = latest.map { verb($0.kind) + ($0.object.isEmpty ? "" : " " + $0.object) } ?? "进行中"
                return RoadStep(title: item.text, sub: state == .waiting ? "等你" : "进行中 · " + doing, state: state == .waiting ? .waiting : .current, open: key)
            case .pending: return RoadStep(title: item.text, sub: position == next ? "下一步" : "还没开始", state: .todo)
            }
        }
        if steps.isEmpty { steps = [RoadStep(title: "开始了", sub: "还没动手", state: .current, open: key)] }
        let start = max(0, min(current - 2, steps.count - keepSteps))
        return (Array(steps[start..<min(steps.count, start + keepSteps)]), start)
    }
}

/// Codex 的对话记录（~/.codex/sessions/…/rollout-*.jsonl）：
/// - 做完的动作是 event_msg 里的 item_completed：命令（带退出码，Codex 自己认出的读文件、搜索）、改文件、搜网页、看图、MCP 工具、子代理；
/// - 正在做的还没有 item，只能看 response_item 里发出去、还没等到 _output 的调用（custom_tool_call 的脚本、function_call）。
/// 推理是加密的，消息内容不看。
enum CodexRoad {
    static let itemMarker = Data("\"type\":\"item_completed\"".utf8)
    static let itemKinds = ["CommandExecution", "FileChange", "McpToolCall", "Extension", "ImageView", "SubAgentActivity", "CollabAgentToolCall"]
        .map { Data("\"type\":\"\($0)\"".utf8) }
    static let callMarkers = [Data("\"type\":\"custom_tool_call\"".utf8), Data("\"type\":\"function_call\"".utf8)]
    static let outputMarkers = [Data("\"type\":\"custom_tool_call_output\"".utf8), Data("\"type\":\"function_call_output\"".utf8)]
    static let keepCalls = 8                       // 被打断留下的没返回的调用，只留最近几个

    static func feed(_ out: inout RoadParse, _ data: Data) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            if outputMarkers.contains(where: { line.range(of: $0) != nil }) {
                // 结果可能很大（截图、长输出）：不整段解析，只取 call_id
                if let id = callID(line) { out.calls.removeAll { $0.id == id } }
                continue
            }
            let isItem = line.range(of: itemMarker) != nil && itemKinds.contains { line.range(of: $0) != nil }
            let isCall = !isItem && callMarkers.contains { line.range(of: $0) != nil }
            guard isItem || isCall, let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            if isCall {
                guard object["type"] as? String == "response_item", let id = payload["call_id"] as? String else { continue }
                let steps = payload["type"] as? String == "custom_tool_call"
                    ? script(name: payload["name"] as? String ?? "", input: payload["input"] as? String ?? "")
                    : function(name: payload["name"] as? String ?? "", namespace: payload["namespace"] as? String, arguments: payload["arguments"] as? String ?? "")
                guard !steps.isEmpty else { continue }
                out.calls.append(RoadCall(id: id, steps: steps))
                if out.calls.count > keepCalls { out.calls.removeFirst(out.calls.count - keepCalls) }
                continue
            }
            guard object["type"] as? String == "event_msg", payload["type"] as? String == "item_completed",
                  let item = payload["item"] as? [String: Any] else { continue }
            let at = (payload["completed_at_ms"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                ?? (object["timestamp"] as? String).flatMap(SessionFiles.parseStamp)
            var found = actions(item)
            guard !found.isEmpty else { continue }
            for index in found.indices { found[index].at = at }
            out.actions += found
            // 最近一个没返回的调用里，又做完了一件
            if !out.calls.isEmpty, item["type"] as? String != "SubAgentActivity" { out.calls[out.calls.count - 1].progress += 1 }
        }
        return complete.count
    }

    /// 结果行里的 "call_id":"…"
    static func callID(_ line: Data.SubSequence) -> String? {
        guard let marker = line.range(of: Data("\"call_id\":\"".utf8)) else { return nil }
        let rest = line[marker.upperBound...]
        guard let quote = rest.prefix(120).firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(data: Data(rest[rest.startIndex..<quote]), encoding: .utf8)
    }

    /// 一个做完的 item 算几个动作（改文件一次可能改好几个）
    static func actions(_ item: [String: Any]) -> [RoadAction] {
        let status = item["status"] as? String
        switch item["type"] as? String {
        case "CommandExecution":
            let command = (item["command"] as? [String])?.last ?? ""
            let exit = (item["exit_code"] as? NSNumber)?.intValue
            var failed = status == "failed" || (exit.map { $0 != 0 } ?? false)
            let parsed = item["parsed_cmd"] as? [[String: Any]] ?? []
            var action: RoadAction
            if !parsed.isEmpty, parsed.allSatisfy({ $0["type"] as? String == "read" }) {
                action = RoadAction(kind: .read, object: parsed.last?["name"] as? String ?? RoadmapBuilder.base(parsed.last?["path"]))
            } else if !parsed.isEmpty, parsed.allSatisfy({ ["search", "list_files"].contains($0["type"] as? String ?? "") }) {
                let last = parsed.last ?? [:]
                action = RoadAction(kind: .search, object: last["query"] as? String ?? last["path"] as? String ?? (last["type"] as? String == "list_files" ? "列文件" : ""))
            } else {
                action = classify(command: command)
                if action.verified { action.verified = exit == 0 && status == "completed" }
            }
            // grep、rg 没搜到东西退出码是 1，不算出错（找不到命令的 127 这种照样算）
            if exit == 1, action.kind == .search || ["grep", "rg", "egrep", "fgrep", "ag"].contains(action.object.split(separator: " ").first.map(String.init) ?? "") { failed = false }
            action.done = true
            action.failed = failed
            return [action]
        case "FileChange":
            let changes = item["changes"] as? [String: Any] ?? [:]
            return changes.keys.sorted().map { path in
                let type = (changes[path] as? [String: Any])?["type"] as? String
                return RoadAction(kind: type == "add" ? .write : .edit, object: RoadmapBuilder.base(path), done: true, failed: status == "failed")
            }
        case "McpToolCall":
            let server = item["server"] as? String ?? ""
            let error = ((item["result"] as? [String: Any])?["isError"] as? Bool) == true
            return [RoadAction(kind: .tool, object: server == "cua_repl" ? "操作电脑" : item["tool"] as? String ?? server, done: true, failed: status == "failed" || error)]
        case "Extension":
            if item["kind"] as? String == "clock.sleep" { return [RoadAction(kind: .other, object: "等一会儿", done: true)] }
            guard item["kind"] as? String == "web.search" else { return [RoadAction(kind: .tool, object: item["kind"] as? String ?? "", done: true)] }
            let action = (item["action"] as? [String: Any])?["type"] as? String
            return [RoadAction(kind: .web, object: action == "search" ? "搜网页" : "读网页", done: true)]
        case "ImageView":
            let path = (item["path"] as? String).flatMap { URL(string: $0)?.path } ?? item["path"] as? String
            return [RoadAction(kind: .read, object: RoadmapBuilder.base(path), done: true)]
        case "SubAgentActivity":
            return [RoadAction(kind: .agent, object: item["kind"] as? String == "started" ? "派出子代理" : "协调子代理", done: true)]
        case "CollabAgentToolCall":
            return [RoadAction(kind: .agent, object: "协调子代理", done: true)]
        default:
            return []
        }
    }

    /// 命令：测试、构建认出简称（单条命令才可能算「过了」），别的按第一个词分类、取开头两个词
    static func classify(command: String) -> RoadAction {
        if let found = TurnReceipts.check(command) {
            return RoadAction(kind: found.kind == .test ? .test : .build, object: found.label, verified: found.trusted)
        }
        return RoadmapBuilder.shellAction(command)
    }

    /// Codex 的 exec 工具是一段 JavaScript：按出现的顺序认出里面调了哪些工具（tools.exec_command({cmd:"…"}) 这种），
    /// 变量拼出来的命令看不出是什么，只写「命令」
    static func script(name: String, input: String) -> [RoadAction] {
        guard name == "exec" else {
            if name == "apply_patch" { return patch(input) }
            return name.isEmpty ? [] : [RoadAction(kind: .tool, object: name)]
        }
        let text = input as NSString
        guard let calls = try? NSRegularExpression(pattern: #"tools\.([A-Za-z0-9_]+)\s*\("#) else { return [] }
        let matches = calls.matches(in: input, range: NSRange(location: 0, length: text.length))
        var out: [RoadAction] = []
        var patches = patch(input)[...]                // 补丁通常先写在变量里，再 tools.apply_patch(patch)：按顺序取整段脚本里的
        for (position, match) in matches.enumerated() {
            let tool = text.substring(with: match.range(at: 1))
            let end = position + 1 < matches.count ? matches[position + 1].range.location : text.length
            let body = text.substring(with: NSRange(location: match.range.upperBound, length: end - match.range.upperBound))
            switch tool {
            case "exec_command":
                out.append(quoted(after: "cmd", in: body).map(classify(command:)) ?? RoadAction(kind: .command, object: ""))
            case "apply_patch":
                if let inline = patch(body).first {
                    out.append(inline)
                    if let used = patches.firstIndex(of: inline) { patches.remove(at: used) }
                } else {
                    out.append(patches.popFirst() ?? RoadAction(kind: .edit, object: ""))
                }
            case "web__run":
                out.append(RoadAction(kind: .web, object: "搜网页"))
            case "view_image":
                out.append(RoadAction(kind: .read, object: quoted(after: "path", in: body).map { RoadmapBuilder.base($0) } ?? ""))
            case "text", "write_stdin", "json", "image", "list_mcp_resources", "list_mcp_resource_templates":
                continue
            default:
                if tool.hasPrefix("clock__") { continue }
                out.append(RoadAction(kind: .tool, object: tool.hasPrefix("mcp__") ? tool.components(separatedBy: "__").last ?? tool : tool))
            }
        }
        return out
    }

    /// function_call：子代理协作、提问、等结果这些
    static func function(name: String, namespace: String?, arguments: String) -> [RoadAction] {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        if namespace == "collaboration" || ["spawn_agent", "wait_agent", "send_message", "followup_task", "list_agents"].contains(name) {
            return [RoadAction(kind: .agent, object: name == "spawn_agent" ? "派出子代理" : "协调子代理")]
        }
        switch name {
        case "request_user_input", "request_user_input_async": return [RoadAction(kind: .ask, object: "等你回答")]
        case "wait": return [RoadAction(kind: .command, object: "等结果")]
        case "sleep": return [RoadAction(kind: .other, object: "等一会儿")]
        case "exec_command", "shell", "local_shell":
            let command = args["cmd"] as? String ?? (args["command"] as? [String])?.last ?? args["command"] as? String ?? ""
            return [classify(command: command)]
        case "apply_patch": return patch(args["input"] as? String ?? arguments).prefix(1).map { $0 }
        case "view_image": return [RoadAction(kind: .read, object: RoadmapBuilder.base(args["path"]))]
        default:
            if let namespace, namespace.hasPrefix("mcp__") {
                return [RoadAction(kind: .tool, object: namespace == "mcp__cua_repl" ? "操作电脑" : name)]
            }
            return [RoadAction(kind: .tool, object: name)]
        }
    }

    /// 补丁里的 *** Update File: / Add File: / Delete File:（脚本里是转义过的字符串，\n 是两个字符）
    static func patch(_ text: String) -> [RoadAction] {
        guard let regex = try? NSRegularExpression(pattern: #"\*\*\* (Update|Add|Delete) File: (.+?)(?:\\n|\n|$)"#) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let kind = source.substring(with: match.range(at: 1))
            return RoadAction(kind: kind == "Add" ? .write : .edit, object: RoadmapBuilder.base(source.substring(with: match.range(at: 2))))
        }
    }

    /// 参数里 name: "…" 或 name: '…' 的字面量（去掉常见转义）；是变量就 nil
    static func quoted(after name: String, in body: String) -> String? {
        let pattern = "\\b" + name + #"\s*:\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) else { return nil }
        let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        guard range.location != NSNotFound else { return nil }
        let raw = (body as NSString).substring(with: range)
        return raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

/// ZCode 的路线图数据源：它的会话不落成记录文件，而是存进 ZCode 自己的会话库（`~/.zcode/cli/db/db.sqlite` 的 part 表）。
/// part 里 `type=tool` 的块带着动作（`state.input` 是参数、`state.status` 是成没成），`type=reasoning` 的块是明文的思考链
///——Claude 的推理块大多是空的、Codex 的是加密的，所以只有 ZCode 画「想」这一步。
/// 只看工具名、参数开头和成败，思考链只取开头一小段，不看对话内容，不落盘。
enum ZcodeRoad {
    static func open(db: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else { return nil }
        return handle
    }

    /// 这一轮从哪一行开始：hook 在新的一轮时记下当时最大的行号。
    /// 会话还没有任何记录时返回 0——新会话的第一轮 hook 可能跑在入库前面，从 0 读起正好把这轮的动作全收进来
    static func maxRow(db: String, session: String) -> Int? {
        guard let handle = open(db: db) else { return nil }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT max(rowid) FROM part WHERE session_id = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, session, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// 这之后的输入+输出 token 总数（turn_usage 是 ZCode 每一轮的记账）。用来算今日 / 近 7 天用量
    static func tokens(db: String, sinceMs: Int64) -> Int? {
        guard let handle = open(db: db) else { return nil }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT total(input_tokens + output_tokens) FROM turn_usage WHERE started_at >= ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sinceMs)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// ZCode 给会话起的标题（会话库 session 表）；读不到就是 nil，让后面用项目文件夹名 / 第一句话
    static func title(db: String, session: String) -> String? {
        guard let handle = open(db: db) else { return nil }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT title FROM session WHERE id = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, session, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        let title = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// 重读这一轮的全部动作。part 是原地更新的（发出去时 running、做完变 completed），按行号增量读会漏掉更新，
    /// 所以每次把这一轮的行整个重读一遍（一轮也就几十到几百行）
    static func read(db: String, session: String, fromRow: Int) -> RoadParse {
        var out = RoadParse()
        guard let handle = open(db: db) else { return out }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT data FROM part WHERE session_id = ? AND rowid > ? ORDER BY rowid LIMIT 4000", -1, &statement, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, session, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(fromRow))
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            feed(&out, Data(String(cString: text).utf8))
        }
        return out
    }

    @discardableResult
    static func feed(_ out: inout RoadParse, _ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let at = (object["time_created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        switch object["type"] as? String {
        case "tool":
            guard let name = object["tool"] as? String else { return false }
            let state = object["state"] as? [String: Any] ?? [:]
            let input = state["input"] as? [String: Any] ?? [:]
            if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
                out.plan = todos.compactMap { item in
                    guard let text = item["content"] as? String, let status = (item["status"] as? String).flatMap(RoadPlanItem.Status.init(rawValue:)) else { return nil }
                    return RoadPlanItem(text: text, status: status)
                }
                return true
            }
            var action = RoadmapBuilder.classify(name: name, input: input)
            action.at = at
            switch state["status"] as? String {
            case "completed": action.done = true
            case "error": action.done = true; action.failed = true
            default: break               // running / 别的：还没做完，画成正在做的那步
            }
            out.actions.append(action)
        case "reasoning":
            guard let text = object["text"] as? String, !text.isEmpty else { return false }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            var action = RoadAction(kind: .think, object: String(line.trimmingCharacters(in: .whitespaces).prefix(24)), done: true)
            action.at = at
            out.actions.append(action)
        default:
            return false                 // text（对话）、step-start/finish 这些不画
        }
        return true
    }
}

// MARK: - 画

enum RoadArt {
    static let teal = NSColor(red: 0.35, green: 0.82, blue: 0.86, alpha: 1)
    static let minWidth: CGFloat = 70
    static let maxWidth: CGFloat = 150
    static let arrowWidth: CGFloat = 16

    static func node(_ step: RoadStep) -> NSImage {
        let title = TouchBarArt.fit(step.title, width: maxWidth - 20, font: TouchBarArt.nameFont)
        let sub = TouchBarArt.fit(step.sub, width: maxWidth - 20, font: TouchBarArt.infoFont)
        let titleWidth = (title as NSString).size(withAttributes: [.font: TouchBarArt.nameFont]).width
        let subWidth = (sub as NSString).size(withAttributes: [.font: TouchBarArt.infoFont]).width
        let mark: CGFloat = 13
        let width = max(minWidth, ceil(max(titleWidth, subWidth)) + 14 + mark)
        return TouchBarArt.image(width: width) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            var titleColor = NSColor.labelColor, subColor = NSColor.secondaryLabelColor
            let glyph: String, glyphColor: NSColor
            switch step.state {
            case .done:
                NSColor(white: 1, alpha: 0.08).setFill(); path.fill()
                titleColor = NSColor(white: 1, alpha: 0.72); glyph = "✓"; glyphColor = .systemGreen
            case .current:
                teal.withAlphaComponent(0.22).setFill(); path.fill()
                teal.setStroke(); path.lineWidth = 1; path.stroke()
                subColor = teal; glyph = "●"; glyphColor = teal
            case .todo:
                NSColor(white: 1, alpha: 0.3).setStroke(); path.lineWidth = 1
                path.setLineDash([3, 2.5], count: 2, phase: 0); path.stroke()
                titleColor = NSColor(white: 1, alpha: 0.5); subColor = NSColor(white: 1, alpha: 0.35)
                glyph = "○"; glyphColor = NSColor(white: 1, alpha: 0.4)
            case .failed:
                NSColor.systemRed.withAlphaComponent(0.25).setFill(); path.fill()
                subColor = .systemRed; glyph = "✕"; glyphColor = .systemRed
            case .waiting:
                NSColor.systemOrange.withAlphaComponent(0.25).setFill(); path.fill()
                NSColor.systemOrange.setStroke(); path.lineWidth = 1; path.stroke()
                subColor = .systemOrange; glyph = "?"; glyphColor = .systemOrange
            }
            (glyph as NSString).draw(at: NSPoint(x: 6, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: glyphColor])
            (title as NSString).draw(at: NSPoint(x: 6 + mark, y: 1), withAttributes: [.font: TouchBarArt.nameFont, .foregroundColor: titleColor])
            (sub as NSString).draw(at: NSPoint(x: 6 + mark, y: 16), withAttributes: [.font: TouchBarArt.infoFont, .foregroundColor: subColor])
        }
    }

    static func arrow(solid: Bool) -> NSImage {
        TouchBarArt.image(width: arrowWidth) { rect in
            let y = rect.height / 2
            let color = NSColor(white: 1, alpha: solid ? 0.55 : 0.25)
            color.setStroke(); color.setFill()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 1.5, y: y)); line.line(to: NSPoint(x: 10, y: y)); line.lineWidth = 1.2
            if !solid { line.setLineDash([2, 2], count: 2, phase: 0) }
            line.stroke()
            let head = NSBezierPath()
            head.move(to: NSPoint(x: 9, y: y - 3.5)); head.line(to: NSPoint(x: 14.5, y: y)); head.line(to: NSPoint(x: 9, y: y + 3.5)); head.close()
            head.fill()
        }
    }

    static func more(_ count: Int) -> NSImage {
        let text = "+\(count)" as NSString
        let font = TouchBarArt.nameFont
        let width = max(30, ceil(text.size(withAttributes: [.font: font]).width) + 14)
        return TouchBarArt.image(width: width) { rect in
            TouchBarArt.pill(rect, NSColor(white: 1, alpha: 0.06))
            text.draw(at: NSPoint(x: (width - text.size(withAttributes: [.font: font]).width) / 2, y: 8), withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }
}

extension TouchBarItem {
    /// 路线图页：一格一步，箭头连着；当前这步、等你、失败的点了打开那条对话。
    /// 不再按屏幕宽度折：步数多、一屏放不下时整条交给触控栏左右划（render 里对路线图页会停在最新的一步，
    /// 手指没划走时新的一步出现也跟着停在最右；划到前面看时位置不动）。前面真被截掉的（超过 keepSteps、记录太长只读了后段）折成「+N」。
    /// id 用步的绝对序号（算上前面折掉的），新增一步或最前面一步被挤掉时，每一步的 id 都不变，划到的位置才对得上。
    static func roadParts(_ road: Roadmap) -> [Part] {
        var out: [Part] = []
        if road.hidden > 0 {
            out.append(Part(image: RoadArt.more(road.hidden), action: .none, id: "road:more", label: "前面还有 \(road.hidden) 步"))
            out.append(Part(image: RoadArt.arrow(solid: true), action: .none, id: "road:arrow:more"))
        }
        for (index, step) in road.steps.enumerated() {
            let position = road.hidden + index + 1
            let say: String
            switch step.state {
            case .done: say = "做完了"
            case .current: say = "正在做"
            case .todo: say = "还没做"
            case .failed: say = "没成"
            case .waiting: say = "在等你"
            }
            out.append(Part(image: RoadArt.node(step), action: step.open.map { .session($0) } ?? .none, id: "road:step:\(position - 1)",
                            label: "第 \(position) 步，\(say)：\(step.title)，\(step.sub)" + (step.open != nil ? "。点了打开这条对话" : "")))
            if index < road.steps.count - 1 {
                out.append(Part(image: RoadArt.arrow(solid: road.steps[index + 1].state != .todo), action: .none, id: "road:arrow:\(position - 1)"))
            }
        }
        return out
    }
}

// MARK: - 模型：挑会话、读记录、盯文件

extension AppModel {
    static let roadQueue = DispatchQueue(label: "local.aiquota.road", qos: .utility)
    /// ZCode 的会话库（路线图按需读它）；测试里指到临时目录的
    static var zcodeDB = expand("~/.zcode/cli/db/db.sqlite")

    /// 这个 AI 现在要画路线图的会话：等你的 > 在跑的（最近的）> 最近一次做完的（留着，不自己消失）
    func roadSession(agent: String, now: Date) -> AgentSession? {
        // 和灯一样的新鲜度：在跑的 3 小时没动静、等你的 12 小时没动静就不算了（卡在「在跑」的旧会话不会让路线图一直弹）
        // Claude/Codex 要有记录文件和轮次里的字节位置；ZCode 没有文件，要的是会话库里的行号
        let candidates = sessions.filter {
            $0.agent == agent && $0.turnID != nil && (agent == "zcode" ? $0.turnRow != nil : !$0.transcript.isEmpty && $0.turnStart != nil)
                && (light(for: $0, now: now) != nil || $0.state == .done)
        }
        if let waiting = candidates.filter({ $0.state == .waiting }).max(by: { $0.updated < $1.updated }) { return waiting }
        if let running = candidates.filter({ $0.state == .running }).max(by: { $0.updated < $1.updated }) { return running }
        return candidates.filter { $0.state == .done && ($0.turnEndedAt.map { now.timeIntervalSince($0) < RoadmapBuilder.doneKeep } ?? false) }
            .max(by: { ($0.turnEndedAt ?? $0.updated) < ($1.turnEndedAt ?? $1.updated) })
    }

    func roadmap(agent: String, now: Date) -> Roadmap? {
        guard let session = roadSession(agent: agent, now: now), let turnID = session.turnID else { return nil }
        // 新的一轮还没读到记录时先画个「开始了」的空路线，不要空一下（条会收起再弹出来）；旧一轮的内容不拿来冒充
        let parse = roadParses[session.key].flatMap { $0.turnID == turnID ? $0.parse : nil } ?? RoadParse()
        let errorText = session.state == .error ? annotated(session, now: now).briefStatus(.error, now: now) : nil
        return RoadmapBuilder.roadmap(session, parse: parse, errorText: errorText, now: now)
    }

    /// 给触控栏的：按 AI 分
    func roadmaps(at now: Date) -> [String: Roadmap] {
        var out: [String: Roadmap] = [:]
        for agent in ["claude", "codex"] { if let road = roadmap(agent: agent, now: now) { out[agent] = road } }
        return out
    }

    /// 要画路线图时才读：第一次从这一轮开始的位置读起，以后只读后面追加的（解析结果按字节位置接着攒），在后台解析，回来再核对还是不是这一轮
    func refreshRoadmaps() {
        guard let agent = roadWanted else { return }
        let now = Date()
        guard let session = roadSession(agent: agent, now: now), let turnID = session.turnID else { return }
        if agent == "zcode" { refreshZcodeRoad(session: session, turnID: turnID); return }
        guard let start = session.turnStart,
              let file = Self.fileIdentity(session.transcript), file.size >= start, session.turnInode == nil || session.turnInode == file.inode else { return }
        let tag = "\(turnID)|\(file.size)|\(file.modified)"
        if roadParses[session.key]?.tag == tag || roadPending[session.key] == tag { return }
        roadPending[session.key] = tag
        let key = session.key, path = session.transcript, inode = session.turnInode, end = file.size, codex = session.agent == "codex"
        // 同一轮、同一个文件、没变短：接着上次读到的地方往下读
        let previous = roadParses[session.key].flatMap { $0.turnID == turnID && start + $0.parse.consumed <= end ? $0.parse : nil }
        roadRun { [weak self] in
            var parse = previous ?? RoadParse()
            let from = start + parse.consumed
            if let read = RoadmapBuilder.read(path: path, from: from, to: end, inode: inode) {
                if previous == nil { parse.cut = read.cut }
                parse.consumed += RoadmapBuilder.feed(&parse, read.data, codex: codex) + (read.cut ? max(0, end - from - read.data.count) : 0)
            }
            let result = parse
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliverRoad(key: key, turnID: turnID, tag: tag, parse: result) }
            }
        }
    }

    /// ZCode 的路线图：记录在它的会话库里，没有文件可盯。每次把这一轮的行整个重读一遍（part 是原地更新的），
    /// 刷新节奏靠 hook 事件（会话状态文件一变 reloadSessions 就会走到这里）和 20 秒一次的定时刷新
    func refreshZcodeRoad(session: AgentSession, turnID: String) {
        guard let from = session.turnRow else { return }
        let tag = "\(turnID)|\(session.updated.timeIntervalSince1970)"
        if roadParses[session.key]?.tag == tag || roadPending[session.key] == tag { return }
        roadPending[session.key] = tag
        let key = session.key, id = session.id, db = Self.zcodeDB
        roadRun { [weak self] in
            let result = ZcodeRoad.read(db: db, session: id, fromRow: from)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliverRoad(key: key, turnID: turnID, tag: tag, parse: result) }
            }
        }
    }

    func deliverRoad(key: String, turnID: String, tag: String, parse: RoadParse) {
        guard roadPending[key] == tag else { return }
        roadPending[key] = nil
        guard sessions.contains(where: { $0.key == key && $0.turnID == turnID }) else { return }
        roadParses[key] = (turnID, tag, parse)
        onUpdate?()
    }

    /// 触控栏说现在要画哪个 AI 的（前台是谁）：要画时盯着那条对话记录的文件变化（事件驱动，最多一秒一次），nil 就停
    func setRoadWanted(_ agent: String?) {
        guard agent != roadWanted else { return }
        roadWanted = agent
        stopRoadWatch()
        if agent != nil { refreshRoadmaps(); startRoadWatch() }
    }

    func startRoadWatch() {
        guard roadWatch == nil, let agent = roadWanted, agent != "zcode", let session = roadSession(agent: agent, now: Date()) else { return }
        let descriptor = Darwin.open(session.transcript, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.roadFileChanged() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        roadWatch = source
        roadWatchedPath = session.transcript
    }

    func stopRoadWatch() {
        roadWatch?.cancel()
        roadWatch = nil
        roadWatchedPath = nil
        roadThrottle?.cancel()
        roadThrottle = nil
    }

    private func roadFileChanged() {
        guard roadThrottle == nil else { return }
        let wait = max(0, 1.0 - Date().timeIntervalSince(roadLastRun))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.roadThrottle = nil
                self.roadLastRun = Date()
                self.refreshRoadmaps()
            }
        }
        roadThrottle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// 会话换了（新的一轮、换了文件）：换着盯。ZCode 没有记录文件可盯（靠 hook 事件和定时刷新），不盯
    func syncRoadWatch() {
        guard let agent = roadWanted else { return }
        let path = agent == "zcode" ? nil : roadSession(agent: agent, now: Date())?.transcript
        if path != roadWatchedPath { stopRoadWatch(); startRoadWatch() }
    }
}

extension Snapshot {
    /// 路线图的预览：走过的路、AI 写的计划、测试没过
    static func writeRoad(dir: String) {
        let trail = Roadmap(key: "claude-a", turnID: "T", steps: [
            RoadStep(title: "读 ×4", sub: "Pet.swift 等", state: .done),
            RoadStep(title: "改 ×3", sub: "AIQuota.swift", state: .done),
            RoadStep(title: "跑测试 ×2", sub: "test.sh · 过了", state: .done),
            RoadStep(title: "改", sub: "进行中 · Watch.swift", state: .current, open: "claude-a"),
        ], hidden: 7, finished: false, plan: false)
        let plan = Roadmap(key: "claude-a", turnID: "T", steps: [
            RoadStep(title: "读现有代码", sub: "做完了", state: .done),
            RoadStep(title: "设计接口", sub: "做完了", state: .done),
            RoadStep(title: "写实现", sub: "进行中 · 改 Watch.swift", state: .current, open: "claude-a"),
            RoadStep(title: "补测试", sub: "下一步", state: .todo),
            RoadStep(title: "装上并验证", sub: "还没开始", state: .todo),
        ], hidden: 0, finished: false, plan: true)
        let failed = Roadmap(key: "claude-a", turnID: "T", steps: [
            RoadStep(title: "读 ×2", sub: "Receipt.swift 等", state: .done),
            RoadStep(title: "改", sub: "Pet.swift", state: .done),
            RoadStep(title: "跑测试", sub: "test.sh · 没过", state: .failed, open: "claude-a"),
            RoadStep(title: "改", sub: "进行中 · Pet.swift", state: .current, open: "claude-a"),
        ], hidden: 0, finished: false, plan: false)
        let waiting = Roadmap(key: "claude-a", turnID: "T", steps: [
            RoadStep(title: "读 ×3", sub: "A.swift 等", state: .done),
            RoadStep(title: "命令", sub: "rm -rf build", state: .done),
            RoadStep(title: "等你", sub: "点一下去处理", state: .waiting, open: "claude-a"),
        ], hidden: 0, finished: false, plan: false)
        // 长的路线：一屏放不下，触控栏上整条交给左右划（这张图是整条拉直了看的；真机上停在最右、最新的一步）
        let kinds = [("读 ×3", "Pet.swift 等"), ("改", "AIQuota.swift"), ("跑测试", "test.sh · 过了"), ("搜索", "touchbar"), ("命令", "git"), ("改 ×2", "Roadmap.swift 等")]
        let longSteps: [RoadStep] = (0..<24).map { index in
            let kind = kinds[index % kinds.count]
            return RoadStep(title: kind.0, sub: kind.1, state: index == 23 ? .current : .done, open: index == 23 ? "claude-a" : nil)
        }
        let long = Roadmap(key: "claude-a", turnID: "T", steps: longSteps, hidden: 0, finished: false, plan: false)
        for (name, road) in [("trail", trail), ("plan", plan), ("failed", failed), ("waiting", waiting), ("long", long)] {
            touchBar(TouchBarItem.roadParts(road).map(\.image), to: "\(dir)/touchbar-road-\(name).png")
        }
    }
}
