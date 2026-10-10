import Foundation

/// 本轮小票：Claude 一轮跑完后，从主 transcript 里这一轮的部分数出
/// - 编辑工具（Edit/Write）成功改了几个文件（按路径去重；用 shell 改的、子代理和工作流改的数不到，所以写明「编辑工具」）；
/// - 最后一次测试或构建（按调用顺序）过没过：只有单条、前台、没有管道/重定向/命令替换的白名单命令才判断，其余写「结果不明」。
/// 只看工具名、文件路径、命令开头和成功与否；不看对话内容，也不存到文件里。
struct TurnReceipt: Equatable {
    enum Kind: Equatable { case test, build }
    enum Result: Equatable { case passed, failed, unknown }

    var files = 0
    var check: String?             // 最后一次测试/构建命令的简称，比如 test.sh、swift build
    var kind = Kind.test
    var result = Result.unknown
    var partial = false            // 这一轮太长，只读了最后 8MB

    var failed: Bool { check != nil && result == .failed }

    /// 例：「测试 ✓ test.sh · 编辑工具改了 3 个文件」「构建没过 swift build」「测试结果不明 pytest」。
    /// 过没过放前面：卡片窄，放不下时截掉的是后面的文件数。只读了最后一段时前面一定写明（卡片标题也会标「部分」）
    var summary: String { (partial ? "只读了最后一段：" : "") + detail }

    /// 不带「只读了最后一段」的那部分（卡片标题已经标了「部分」时用）
    var detail: String {
        var parts: [String] = []
        if let check {
            let name = kind == .test ? "测试" : "构建"
            switch result {
            case .passed: parts.append(name + " ✓ " + check)
            case .failed: parts.append(name + "没过 " + check)
            case .unknown: parts.append(name + "结果不明 " + check)
            }
        }
        if files > 0 { parts.append("编辑工具改了 \(files) 个文件") }
        // 没看到不等于没发生：可能用 shell 改的、用了认不出的测试命令，或者在没读到的那一段里
        return parts.isEmpty ? "未观察到可统计的编辑或测试记录" : parts.joined(separator: " · ")
    }
}

/// 一次读取：区间在排队时就定好（不读到执行那一刻的文件末尾，免得混进下一轮）
struct ReceiptRequest: Equatable {
    let key: String
    let turnID: String
    let ended: Date
    let path: String
    let start: Int
    let end: Int
    let inode: UInt64              // 排队时是哪个文件：读的时候打开的必须还是它
    let modified: TimeInterval
    let base: String               // 轮次 + 结束时间 + 文件身份
    /// 文件长度、修改时间也在里面：同一轮后来又追加了结果（Stop 之后才写完的），文件一变就重读
    var tag: String { base + "|\(end)|\(modified)" }
}

/// 一次读取的结果：读到了；排队之后文件改过（丢掉，下次按新版本重读）；读不了
enum ReceiptRead: Equatable {
    case ok(TurnReceipt)
    case changed
    case unreadable
}

/// 任务页和小猫看到的：算好了，或者读不了（不拿上一轮的冒充）
enum ReceiptSlot: Equatable {
    case ready(TurnReceipt)
    case unreadable
}

enum TurnReceipts {
    static let maxBytes = 8 << 20
    static let editTools: Set<String> = ["Edit", "Write"]

    static func modified(_ info: stat) -> TimeInterval {
        TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    /// 路径现在指着的文件：长度、是哪个文件、修改时间（排队和读取用同一种算法，才能严格比较）
    static func identity(_ path: String) -> (size: Int, inode: UInt64, modified: TimeInterval)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (Int(info.st_size), UInt64(info.st_ino), modified(info))
    }

    /// 打开之后核对：还是排队时那个文件、没变短；修改时间和排队时一样（排队之后被追加或原地重写过都算改过）；
    /// 读完再核对一次，读的过程中变了也算改过。改过的丢掉，下次刷新按新版本重读
    static func read(_ request: ReceiptRequest, maxBytes: Int = maxBytes) -> ReceiptRead {
        guard request.start >= 0, request.end >= request.start, let handle = FileHandle(forReadingAtPath: request.path) else { return .unreadable }
        defer { try? handle.close() }
        func version() -> (inode: UInt64, size: Int, modified: TimeInterval)? {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
            return (UInt64(info.st_ino), Int(info.st_size), modified(info))
        }
        guard let before = version(), before.inode == request.inode, before.size >= request.end else { return .unreadable }
        guard before.modified == request.modified else { return .changed }
        let start = max(request.start, request.end - maxBytes)
        guard (try? handle.seek(toOffset: UInt64(start))) != nil else { return .unreadable }
        let data = (try? handle.read(upToCount: request.end - start)) ?? Data()
        guard data.count == request.end - start else { return .unreadable }
        guard let after = version(), after.inode == before.inode, after.size == before.size, after.modified == before.modified else { return .changed }
        var receipt = parse(data)
        receipt.partial = start > request.start
        return .ok(receipt)
    }

    static func parse(_ data: Data) -> TurnReceipt {
        var edits: [String: String] = [:]                                          // 调用 id → 文件路径
        var changed = Set<String>()
        var checks: [(id: String, label: String, kind: TurnReceipt.Kind, trusted: Bool)] = []   // 按调用顺序
        var results: [String: (error: Bool, exit: Bool)] = [:]
        let marker = Data("\"tool_".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, type == "assistant" || type == "user",
                  object["isSidechain"] as? Bool != true,
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in content {
                guard let id = (block["id"] ?? block["tool_use_id"]) as? String else { continue }
                switch block["type"] as? String {
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    if editTools.contains(name), let path = input["file_path"] as? String { edits[id] = path }
                    if name == "Bash", let command = input["command"] as? String, let found = check(command) {
                        // 放到后台跑的：马上就回「在后台跑了」，没有退出码
                        checks.append((id, found.label, found.kind, found.trusted && input["run_in_background"] as? Bool != true))
                    }
                case "tool_result":
                    let error = block["is_error"] as? Bool == true
                    results[id] = (error, error && text(block["content"]).hasPrefix("Exit code"))
                    if !error, let path = edits[id] { changed.insert(path) }
                default:
                    break
                }
            }
        }
        var receipt = TurnReceipt()
        receipt.files = changed.count
        if let last = checks.last {
            receipt.check = last.label
            receipt.kind = last.kind
            if last.trusted, let result = results[last.id] {
                // 只有命令真的非零退出（「Exit code N」开头）才算没过；被拒绝、超时之类的看不出结果
                receipt.result = !result.error ? .passed : result.exit ? .failed : .unknown
            }
        }
        return receipt
    }

    static func text(_ content: Any?) -> String {
        if let string = content as? String { return string }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined()
    }

    /// 一条 shell 命令里最后一个测试/构建命令，以及它的成败能不能从这条命令的退出码看出来：
    /// 只有整条就是这一个前台命令（去掉首尾空白后，末尾最多一个 ;）才算数；剩下的部分里只要出现 ; & | < > ` $( 或换行
    /// （连着别的命令、放到后台、管道、重定向、命令替换），或者引号没配对，一律看不出。宁可说不明，也不猜
    static func check(_ command: String) -> (label: String, kind: TurnReceipt.Kind, trusted: Bool)? {
        guard let split = segments(command) else {
            let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
            return label(words).map { ($0.label, $0.kind, false) }
        }
        guard let index = split.indices.last(where: { label(split[$0].words) != nil }), let found = label(split[index].words) else { return nil }
        var body = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(";") { body.removeLast() }
        let plain = !body.contains(where: { ";&|<>`\n".contains($0) }) && !body.contains("$(")
        return (found.label, found.kind, plain && split.count == 1)
    }

    /// 按 && || ; | & 换行切开（引号里的不切），记下每段后面跟的是什么；引号没配对返回 nil
    static func segments(_ command: String) -> [(words: [String], next: String)]? {
        var out: [(words: [String], next: String)] = []
        var current = ""
        var quote: Character?
        let chars = Array(command)
        var i = 0
        func flush(_ separator: String) {
            let words = current.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // 空段后面的分隔符不覆盖前面已经记下的（「pytest &」后面的换行不能把 & 改成 ;）
            if !words.isEmpty { out.append((words, separator)) }
            else if !out.isEmpty, !separator.isEmpty, out[out.count - 1].next.isEmpty { out[out.count - 1].next = separator }
            current = ""
        }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
                current.append(c)
            } else if c == "'" || c == "\"" {
                quote = c
                current.append(c)
            } else if (c == "&" || c == "|") && i + 1 < chars.count && chars[i + 1] == c {
                flush(String([c, c]))
                i += 1
            } else if c == "|" || c == ";" || c == "&" {
                flush(String(c))
            } else if c == "\n" {
                flush(";")
            } else {
                current.append(c)
            }
            i += 1
        }
        guard quote == nil else { return nil }
        flush("")
        if let last = out.indices.last, out[last].next == ";" { out[last].next = "" }      // 结尾的 ; 或换行不算接了别的命令
        return out
    }

    /// 白名单：认得出是测试还是构建的才算；make clean 这类说不清的不算
    static func label(_ raw: [String]) -> (label: String, kind: TurnReceipt.Kind)? {
        var words = Array(raw.drop { ($0.contains("=") && !$0.hasPrefix("-")) || $0 == "time" || $0 == "nohup" || $0 == "env" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        if words.first == "npx" || words.first == "bunx" { words.removeFirst() }
        guard let first = words.first else { return nil }
        let name = (first as NSString).lastPathComponent
        let second = words.count > 1 ? words[1] : ""
        let third = words.count > 2 ? words[2] : ""
        switch name {
        case "test.sh", "run-tests.sh", "run_tests.sh": return (name, .test)
        case "build.sh": return (name, .build)
        case "swift":
            if second == "test" { return ("swift test", .test) }
            if second == "build" { return ("swift build", .build) }
            return nil
        case "xcodebuild": return words.contains("test") ? ("xcodebuild test", .test) : ("xcodebuild", .build)
        case "pytest", "jest", "vitest": return (name, .test)
        case "tsc", "swiftc": return (name, .build)
        case "python", "python3": return second == "-m" && third == "pytest" ? ("pytest", .test) : nil
        case "npm", "pnpm", "yarn", "bun":
            if second == "test" { return (name + " test", .test) }
            if second == "build" { return (name + " build", .build) }
            if second == "run", third.contains("test") { return (name + " run " + third, .test) }
            if second == "run", third.contains("build") { return (name + " run " + third, .build) }
            return nil
        case "cargo":
            if second == "test" { return ("cargo test", .test) }
            if ["build", "check"].contains(second) { return ("cargo " + second, .build) }
            return nil
        case "go":
            if second == "test" { return ("go test", .test) }
            if ["build", "vet"].contains(second) { return ("go " + second, .build) }
            return nil
        case "make":
            if ["test", "check"].contains(second) { return ("make " + second, .test) }
            if second == "build" { return ("make build", .build) }
            return nil
        case "gradle", "gradlew":
            if ["test", "check"].contains(second) { return (name + " " + second, .test) }
            if ["build", "assemble"].contains(second) { return (name + " " + second, .build) }
            return nil
        case "mvn":
            if ["test", "verify"].contains(second) { return ("mvn " + second, .test) }
            if ["compile", "package"].contains(second) { return ("mvn " + second, .build) }
            return nil
        default:
            return nil
        }
    }
}

extension AppModel {
    nonisolated static func fileIdentity(_ path: String) -> (size: Int, inode: UInt64, modified: TimeInterval)? {
        TurnReceipts.identity(path)
    }

    /// 跑完（完成或出错）的 Claude 会话算一次本轮小票：在后台读固定区间，回来时再核对是不是还是这一轮。
    /// 跟着会话目录的变化和已有的 20 秒 tick 调；读不了的下次再试，算好了的文件不变就不再读
    func updateReceipts() {
        var keep: [String: (turnID: String, slot: ReceiptSlot, tag: String)] = [:]
        for session in sessions where session.agent == "claude" && (session.state == .done || session.state == .error) {
            guard let turnID = session.turnID, let ended = session.turnEndedAt, let start = session.turnStart, !session.transcript.isEmpty else { continue }
            let key = session.key
            if let old = receipts[key], old.turnID == turnID { keep[key] = old }
            guard let file = Self.fileIdentity(session.transcript), file.size >= start,
                  session.turnInode == nil || session.turnInode == file.inode else {
                keep[key] = (turnID, .unreadable, "")                     // 文件没了、变短了或换了一个：这一轮的位置已经对不上
                receiptPending[key] = nil                                   // 在途的那次读取也作废
                continue
            }
            let base = "\(turnID)|\(ended.timeIntervalSince1970)|\(file.inode)"
            let request = ReceiptRequest(key: key, turnID: turnID, ended: ended, path: session.transcript, start: start, end: file.size,
                                         inode: file.inode, modified: file.modified, base: base)
            if let old = keep[key], old.tag == request.tag { continue }                     // 算好了，文件也没变
            if receiptPending[key] == request.tag { continue }                              // 正在读
            receiptPending[key] = request.tag
            receiptRun { [weak self] in
                let result = TurnReceipts.read(request)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.deliverReceipt(request, result) }
                }
            }
        }
        receipts = keep                                                     // 新的一轮开始、会话没了：旧票马上作废
        receiptPending = receiptPending.filter { entry in sessions.contains { $0.key == entry.key } }
    }

    func deliverReceipt(_ request: ReceiptRequest, _ result: ReceiptRead) {
        guard receiptPending[request.key] == request.tag else { return }  // 已经有更新的一次读取，或者这次已经作废
        receiptPending[request.key] = nil
        guard let session = sessions.first(where: { $0.key == request.key }), session.turnID == request.turnID,
              session.turnEndedAt == request.ended, session.state == .done || session.state == .error else { return }   // 迟到了：已经换了一轮
        switch result {
        case .ok(let receipt):
            // 交付前再核对一次：读完之后文件被删、被换、变短了的不交付（下次刷新会显示读不了）
            guard let file = Self.fileIdentity(request.path), file.inode == request.inode, file.size >= request.end else { return }
            receipts[request.key] = (request.turnID, .ready(receipt), request.tag)
        case .changed:
            return                                                          // 排队之后改过：下次刷新按新版本重读
        case .unreadable:
            receipts[request.key] = (request.turnID, .unreadable, "")      // 读失败：显示读不了，下次 tick 再试
        }
        onUpdate?()
    }

    /// 这个会话这一轮的小票（还在跑、换了一轮的不给）
    func receipt(for session: AgentSession) -> ReceiptSlot? {
        guard session.state == .done || session.state == .error, let turnID = session.turnID else { return nil }
        guard let entry = receipts[session.key], entry.turnID == turnID else { return nil }
        return entry.slot
    }

    /// 给触控栏的：已经按轮次核对过的
    var receiptSlots: [String: ReceiptSlot] {
        var out: [String: ReceiptSlot] = [:]
        for session in sessions { if let slot = receipt(for: session) { out[session.key] = slot } }
        return out
    }
}
