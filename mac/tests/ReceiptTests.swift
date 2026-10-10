import Foundation

/// 本轮小票：判定（只信有证据的结论）、后台读取、按轮次隔离、迟到的结果
enum ReceiptTests {
    static func line(_ object: [String: Any]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? ""
    }
    static func use(_ id: String, _ name: String, _ input: [String: Any], sidechain: Bool = false) -> String {
        line(["type": "assistant", "isSidechain": sidechain, "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }
    static func result(_ id: String, error: Bool = false, text: String = "ok") -> String {
        line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": error, "content": text]]]])
    }
    static func parse(_ lines: [String]) -> TurnReceipt {
        TurnReceipts.parse(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    @MainActor
    static func run(check: (Bool, String) -> Void) async {
        facts(check: check)
        await model(check: check)
    }

    static func facts(check: (Bool, String) -> Void) {
        var r = parse([use("e1", "Edit", ["file_path": "/p/a.swift"]), result("e1"),
                       use("e2", "Write", ["file_path": "/p/a.swift"]), result("e2"),
                       use("e3", "Edit", ["file_path": "/p/b.swift"]), result("e3", error: true, text: "String to replace not found"),
                       use("e4", "Edit", ["file_path": "/p/c.swift"], sidechain: true), result("e4"),
                       use("e5", "MultiEdit", ["file_path": "/p/e.swift"]), result("e5"),
                       use("e6", "Edit", ["file_path": "/p/d.swift"])])
        check(r.files == 1, "同一个文件成功两次算 1；失败的、子代理的、别的工具的、还没返回的都不算")
        check(r.summary == "编辑工具改了 1 个文件", "写明是编辑工具改的，不说成一共改了几个")
        check(parse([]).summary == "未观察到可统计的编辑或测试记录", "什么都没看到时不说成「没发生」")

        r = parse([use("t1", "Bash", ["command": "pytest"]), use("t2", "Bash", ["command": "swift test"]),
                   result("t2", error: true, text: "Exit code 1\n失败"), result("t1")])
        check(r.check == "swift test" && r.result == .failed && r.failed, "按调用顺序取最后一次：后调的先返回也选它")
        r = parse([use("t1", "Bash", ["command": "pytest"]), result("t1"), use("t2", "Bash", ["command": "swift test"])])
        check(r.check == "swift test" && r.result == .unknown && r.summary == "测试结果不明 swift test", "最后一次还没返回：结果不明")
        r = parse([use("t1", "Bash", ["command": "pytest"]), result("t1")])
        check(r.result == .passed && r.summary == "测试 ✓ pytest", "单条 pytest 成功：通过")
        r = parse([use("t1", "Bash", ["command": "pytest -q tests/"]), result("t1", error: true, text: "Exit code 2\nFAILED")])
        check(r.result == .failed && r.summary == "测试没过 pytest", "明确非零退出：没过")
        r = parse([use("t1", "Bash", ["command": "pytest"]), result("t1", error: true, text: "<tool_use_error>用户拒绝了</tool_use_error>")])
        check(r.result == .unknown, "被拒绝、超时之类的报错：结果不明")
        for command in ["false && pytest", "pytest && false", "./test.sh 2>&1 | tail -5", "pytest || true", "pytest &", "pytest; echo done",
                        "cd x && ./test.sh", "pytest > log.txt", "pytest $(cat args)", "pytest `cat args`", "pytest '没配对",
                        "pytest &\n", "pytest & \n\n", "pytest;;", "pytest\nls", "pytest |\n tail"] {
            for failed in [false, true] {
                let parsed = parse([use("c", "Bash", ["command": command]), result("c", error: failed, text: failed ? "Exit code 1" : "ok")])
                check(parsed.result == .unknown && parsed.check != nil, "连着别的命令、重定向、命令替换、引号没配对：不判断成败（\(command)）")
            }
        }
        r = parse([use("b", "Bash", ["command": "./test.sh", "run_in_background": true]), result("b")])
        check(r.result == .unknown, "放到后台跑的：结果不明")
        r = parse([use("b", "Bash", ["command": "pytest;"]), result("b")])
        check(r.result == .passed, "末尾一个分号不算接了别的命令")
        r = parse([use("b", "Bash", ["command": "  pytest;\n"]), result("b")])
        check(r.result == .passed, "末尾一个分号再加换行也可以")
        r = parse([use("b", "Bash", ["command": "swift build"]), result("b", error: true, text: "Exit code 1")])
        check(r.summary == "构建没过 swift build" && r.kind == .build && r.failed, "构建没过不说成测试没过")
        r = parse([use("b", "Bash", ["command": "ls -la"]), result("b", error: true, text: "Exit code 1")])
        check(r.check == nil && !r.failed, "不是测试/构建的命令不管")
        check(TurnReceipts.label(["make", "clean"]) == nil && TurnReceipts.label(["make"]) == nil && TurnReceipts.label(["python", "script.py"]) == nil
              && TurnReceipts.label(["python3", "-m", "pytest"])?.label == "pytest" && TurnReceipts.label(["npm", "run", "build:prod"])?.kind == .build
              && TurnReceipts.label(["FOO=1", "./test.sh"])?.label == "test.sh" && TurnReceipts.label(["xcodebuild", "test"])?.kind == .test,
              "说不清是测试还是构建的不算；环境变量开头的照认")
        check(parse(["{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\""]).files == 0, "半行 JSON 不崩溃")

        // 太长只读最后一段：标出来
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-receipt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("long.jsonl").path
        let filler = String(repeating: line(["type": "progress", "tool_": "x"]) + "\n", count: 50)
        let tail = [use("e1", "Edit", ["file_path": "/p/a.swift"]), result("e1")].joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: path, contents: Data((filler + tail).utf8))
        let size = (filler + tail).utf8.count
        let identity = AppModel.fileIdentity(path)
        let inode = identity?.inode ?? 0
        let modified = identity?.modified ?? 0
        func request(end: Int, inode: UInt64, modified: TimeInterval) -> ReceiptRequest {
            ReceiptRequest(key: "k", turnID: "T", ended: Date(), path: path, start: 0, end: end, inode: inode, modified: modified, base: "b")
        }
        if case .ok(let receipt) = TurnReceipts.read(request(end: size, inode: inode, modified: modified), maxBytes: tail.utf8.count + 40) {
            check(receipt.partial && receipt.files == 1 && receipt.summary.hasPrefix("只读了最后一段："), "超过上限只读最后一段，并说明只读了部分")
        } else {
            check(false, "超过上限只读最后一段，并说明只读了部分")
        }
        var onlyCheck = TurnReceipt()
        onlyCheck.partial = true
        onlyCheck.check = "pytest"
        check(onlyCheck.summary.hasPrefix("只读了最后一段：") && onlyCheck.detail == "测试结果不明 pytest", "没有文件数时也保留「只读了最后一段」")
        onlyCheck.check = nil
        check(onlyCheck.summary == "只读了最后一段：未观察到可统计的编辑或测试记录", "只读了一段、什么都没看到：照实说")
        check(TurnReceipts.read(request(end: size + 100, inode: inode, modified: modified)) == .unreadable, "文件比要读的区间短（变短了）：读不了，不假装读完")
        check(TurnReceipts.read(request(end: size, inode: inode + 1, modified: modified)) == .unreadable, "打开的不是排队时那个文件：读不了")
        check(TurnReceipts.read(request(end: size, inode: inode, modified: modified - 1)) == .changed, "排队之后改过（修改时间对不上）：丢掉，按新版本重读")
    }

    @MainActor
    static func model(check: (Bool, String) -> Void) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-receipt-model-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.jsonl").path
        let turnText = [use("e1", "Edit", ["file_path": "/p/a.swift"]), result("e1"), use("t1", "Bash", ["command": "./test.sh"]), result("t1")]
            .joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: path, contents: Data(("前一轮\n" + turnText).utf8))
        let start = "前一轮\n".utf8.count
        let ended = Date()
        let model = AppModel()
        var queued: [() -> Void] = []
        model.receiptRun = { queued.append($0) }
        func settle() async { try? await Task.sleep(nanoseconds: 80_000_000) }
        var session = AgentSession(agent: "claude", id: "r1", state: .done, since: ended, updated: ended, first: ended, title: "修登录", bundle: "",
                                   transcript: path, turnID: "T1", turnStart: start, turnAt: ended.addingTimeInterval(-720), turnEndedAt: ended)
        model.sessions = [session]
        model.updateReceipts()
        check(queued.count == 1 && model.receipt(for: session) == nil, "在后台读，读完之前不显示")

        // 旧一轮的结果在新一轮开始后才回来：丢掉
        let stale = queued.removeFirst()
        var next = session
        next.state = .running
        next.turnID = "T2"
        next.turnEndedAt = nil
        model.sessions = [next]
        model.updateReceipts()
        stale()
        await settle()
        check(model.receipts[session.key] == nil && model.receipt(for: next) == nil, "旧一轮的结果迟到了：丢掉")

        next.state = .done
        next.turnEndedAt = ended.addingTimeInterval(60)
        model.sessions = [next]
        model.updateReceipts()
        check(model.receipt(for: next) == nil && queued.count == 1, "新一轮做完了还没读完：不拿旧票冒充")
        queued.removeFirst()()
        await settle()
        if case .ready(let receipt)? = model.receipt(for: next) {
            check(receipt.files == 1 && receipt.result == .passed && receipt.check == "test.sh", "读完显示这一轮的小票")
        } else {
            check(false, "读完显示这一轮的小票")
        }
        model.updateReceipts()
        check(queued.isEmpty, "文件没变不再读")
        // 第一次读到的正好是完整的行，之后同一轮又追加了一次测试（Stop 之后才写完）：文件一变就重读
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(([use("t2", "Bash", ["command": "swift test"]), result("t2", error: true, text: "Exit code 1")]
                .joined(separator: "\n") + "\n").utf8))
            try? handle.close()
        }
        model.updateReceipts()
        check(queued.count == 1, "同一轮后来又追加了结果：重读")
        queued.removeFirst()()
        await settle()
        if case .ready(let receipt)? = model.receipt(for: next) {
            check(receipt.check == "swift test" && receipt.result == .failed, "重读后换成最后一次测试的结果")
        } else {
            check(false, "重读后换成最后一次测试的结果")
        }
        // 排队之后、读之前 transcript 被换成另一个文件：不拿别的文件的内容
        let replaced = AgentSession(agent: "claude", id: "r3", state: .done, since: ended, updated: ended, first: ended, title: "换文件", bundle: "",
                                    transcript: path, turnID: "X1", turnStart: start, turnAt: ended.addingTimeInterval(-60), turnEndedAt: ended)
        model.sessions = [replaced]
        model.updateReceipts()
        check(queued.count == 1, "排队读")
        let other = dir.appendingPathComponent("other.jsonl").path
        FileManager.default.createFile(atPath: other, contents: Data((String(repeating: " ", count: start) + turnText + turnText).utf8))
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.moveItem(atPath: other, toPath: path)
        queued.removeFirst()()
        await settle()
        check(model.receipt(for: replaced) == .unreadable, "读的时候已经换了一个文件：本轮记录暂不可读")

        // 读完了还没交付，文件被删：刷新时显示读不了，旧结果到了也不覆盖
        let racePath = dir.appendingPathComponent("race.jsonl").path
        FileManager.default.createFile(atPath: racePath, contents: Data(turnText.utf8))
        let race = AgentSession(agent: "claude", id: "r4", state: .done, since: ended, updated: ended, first: ended, title: "竞态", bundle: "",
                                transcript: racePath, turnID: "R1", turnStart: 0, turnAt: ended.addingTimeInterval(-60), turnEndedAt: ended)
        model.sessions = [race]
        model.updateReceipts()
        queued.removeFirst()()                                  // 读完了，交付排在主线程上
        try? FileManager.default.removeItem(atPath: racePath)
        model.updateReceipts()                                  // 刷新：文件没了
        await settle()                                          // 旧结果这时才到
        check(model.receipt(for: race) == .unreadable, "读完后文件没了：旧结果到了也不覆盖「读不了」")

        // 排队之后原地重写（同一个文件、一样长）：不收旧请求读到的新内容，下次按新版本重读
        let rewritePath = dir.appendingPathComponent("rewrite.jsonl").path
        let passing = [use("t1", "Bash", ["command": "pytest"]), result("t1", text: "okay")].joined(separator: "\n") + "\n"
        let failing = [use("t1", "Bash", ["command": "pytest"]), result("t1", error: true, text: "Exit code 1")].joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: rewritePath, contents: Data(passing.utf8))
        let rewrite = AgentSession(agent: "claude", id: "r5", state: .done, since: ended, updated: ended, first: ended, title: "重写", bundle: "",
                                   transcript: rewritePath, turnID: "W1", turnStart: 0, turnAt: ended.addingTimeInterval(-60), turnEndedAt: ended)
        model.sessions = [rewrite]
        model.updateReceipts()
        let inodeBefore = AppModel.fileIdentity(rewritePath)?.inode
        if let handle = FileHandle(forWritingAtPath: rewritePath) {
            let padded = failing.utf8.count <= passing.utf8.count ? failing + String(repeating: " ", count: passing.utf8.count - failing.utf8.count) : failing
            try? handle.write(contentsOf: Data(String(padded.prefix(passing.count)).utf8))
            try? handle.close()
        }
        check(AppModel.fileIdentity(rewritePath)?.inode == inodeBefore, "同一个文件原地重写")
        queued.removeFirst()()
        await settle()
        check(model.receipt(for: rewrite) == nil, "排队之后原地重写：这次读的不收")
        model.updateReceipts()
        check(queued.count == 1, "按新版本重读")
        queued.removeFirst()()
        await settle()
        check(model.receipt(for: rewrite) != nil, "新版本读到了")

        model.sessions = [next]
        var restarted = next
        restarted.state = .running
        restarted.turnID = "T3"
        restarted.turnEndedAt = nil
        model.sessions = [restarted]
        model.updateReceipts()
        check(model.receipt(for: restarted) == nil && model.receipts[next.key] == nil, "新的一轮开始：旧票马上作废")

        // 末尾一行还没写完：先按能读的算；补全后再读一次
        let partialPath = dir.appendingPathComponent("p.jsonl").path
        let editLine = use("e9", "Edit", ["file_path": "/p/z.swift"])
        let resultLine = result("e9")
        FileManager.default.createFile(atPath: partialPath, contents: Data((editLine + "\n" + String(resultLine.prefix(20))).utf8))
        session = AgentSession(agent: "claude", id: "r2", state: .done, since: ended, updated: ended, first: ended, title: "半行", bundle: "",
                               transcript: partialPath, turnID: "P1", turnStart: 0, turnAt: ended.addingTimeInterval(-60), turnEndedAt: ended)
        model.sessions = [session]
        model.updateReceipts()
        queued.removeFirst()()
        await settle()
        if case .ready(let receipt)? = model.receipt(for: session) { check(receipt.files == 0, "末尾不完整的 JSON 不崩溃，先不算那一条") }
        else { check(false, "末尾不完整的 JSON 不崩溃，先不算那一条") }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: partialPath)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((String(resultLine.dropFirst(20)) + "\n").utf8))
            try? handle.close()
        }
        model.updateReceipts()
        check(queued.count == 1, "补全之后再读一次")
        queued.removeFirst()()
        await settle()
        if case .ready(let receipt)? = model.receipt(for: session) { check(receipt.files == 1, "补全后更新") }
        else { check(false, "补全后更新") }

        // 读不了：显示读不了；文件回来后下一次 tick 再试
        let movedPath = partialPath + ".moved"
        try? FileManager.default.moveItem(atPath: partialPath, toPath: movedPath)
        session.turnID = "P2"
        session.turnEndedAt = ended.addingTimeInterval(1)
        model.sessions = [session]
        model.updateReceipts()
        check(model.receipt(for: session) == .unreadable && queued.isEmpty, "文件没了：本轮记录暂不可读")
        try? FileManager.default.moveItem(atPath: movedPath, toPath: partialPath)
        model.updateReceipts()
        check(queued.count == 1, "文件回来了：下一次再读")
        queued.removeFirst()()
        await settle()
        if case .ready? = model.receipt(for: session) { check(true, "读到了") } else { check(false, "文件回来后读到了") }

        // 文件被换掉（不是同一个文件了）：这一轮的位置对不上，不假装读完
        session.turnID = "P3"
        session.turnEndedAt = ended.addingTimeInterval(2)
        session.turnInode = 1
        model.sessions = [session]
        model.updateReceipts()
        check(model.receipt(for: session) == .unreadable, "transcript 换了一个文件：本轮记录暂不可读")
        // 变短了
        session.turnInode = nil
        session.turnStart = 1_000_000
        session.turnID = "P4"
        model.sessions = [session]
        model.updateReceipts()
        check(model.receipt(for: session) == .unreadable, "transcript 变短了：本轮记录暂不可读")
    }
}
