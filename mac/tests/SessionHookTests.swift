import Foundation
import SQLite3

/// hook 的状态和轮次：全部用合成事件，状态文件、锁、日志都在临时目录里
enum SessionHookTests {
    /// 给 ZCode 会话库塞测试数据（测试里的假记录）：part 是动作块，sessions 是会话标题，usage 是每轮的 token 记账
    @discardableResult
    static func seedZcodeParts(_ db: String, _ rows: [(String, String)],
                               sessions: [(String, String)] = [], usage: [(String, Int64, Int64, Int64)] = []) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open(db, &handle) == SQLITE_OK, let handle else { return false }
        defer { sqlite3_close(handle) }
        sqlite3_exec(handle, "CREATE TABLE IF NOT EXISTS part (id text primary key, session_id text, data text)", nil, nil, nil)
        sqlite3_exec(handle, "CREATE TABLE IF NOT EXISTS session (id text primary key, title text)", nil, nil, nil)
        sqlite3_exec(handle, "CREATE TABLE IF NOT EXISTS turn_usage (session_id text, started_at integer, input_tokens integer, output_tokens integer)", nil, nil, nil)
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        func bind(_ sql: String, _ values: [String]) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
            return sqlite3_step(statement) == SQLITE_DONE
        }
        for (session, data) in rows where bind("INSERT INTO part (session_id, data) VALUES (?, ?)", [session, data]) == false { return false }
        for (id, title) in sessions where bind("INSERT INTO session (id, title) VALUES (?, ?)", [id, title]) == false { return false }
        for (session, started, input, output) in usage {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO turn_usage (session_id, started_at, input_tokens, output_tokens) VALUES (?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { return false }
            sqlite3_bind_text(statement, 1, session, -1, transient)
            sqlite3_bind_int64(statement, 2, started)
            sqlite3_bind_int64(statement, 3, input)
            sqlite3_bind_int64(statement, 4, output)
            guard sqlite3_step(statement) == SQLITE_DONE else { return false }
            sqlite3_finalize(statement)
        }
        return true
    }

    @MainActor
    static func run(check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-hook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: transcript.path, contents: Data("{}\n".utf8))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func fire(_ event: String, _ extra: [String: Any] = [:], at offset: TimeInterval, session: String = "s1") {
            var o: [String: Any] = ["session_id": session, "hook_event_name": event, "transcript_path": transcript.path, "cwd": dir.path]
            for (key, value) in extra { o[key] = value }
            let data = (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
            SessionHook.run(agentArg: "claude", input: data,
                            env: SessionHook.Environment(dir: dir, now: t0.addingTimeInterval(offset), bundle: nil, title: { _, _, _, _, _, _ in nil }))
        }
        func rec(_ session: String = "s1") -> [String: Any] {
            (try? Data(contentsOf: SessionFiles.url("claude-" + session, in: dir)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        func state() -> String { rec()["state"] as? String ?? "" }
        func number(_ key: String) -> Double? { (rec()[key] as? NSNumber)?.doubleValue }
        func turn() -> String? { rec()["turnID"] as? String }
        let start = t0.timeIntervalSince1970

        // 第一次事件就记下 first；之后怎么变都不改
        fire("UserPromptSubmit", ["prompt": "修一下登录"], at: 0)
        let turn1 = turn()
        check(number("first") == start && state() == "running", "第一次事件就记下 first")
        check(turn1 != nil && number("turnStart") == 3 && number("turnAt") == start, "新的一轮：身份、开始时间、transcript 当时的长度")
        fire("Stop", ["background_tasks": [[String: Any]]()], at: 10)
        check(number("first") == start && state() == "done" && number("turnEndedAt") == start + 10, "停下后 first 不变，记下这一轮结束的时间")

        if let handle = try? FileHandle(forWritingTo: transcript) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("0123456789".utf8))
            try? handle.close()
        }
        fire("UserPromptSubmit", ["prompt": "再来"], at: 20)
        let turn2 = turn()
        check(turn2 != nil && turn2 != turn1 && number("turnStart") == 13 && number("turnEndedAt") == nil, "再提交是新的一轮：换身份、更新开始位置、清掉结束时间")
        fire("UserPromptSubmit", ["prompt": "跑着的时候又说一句"], at: 25)
        let turn3 = turn()
        check(turn3 != nil && turn3 != turn2, "跑着的时候再提交也是新的一轮")
        fire("UserPromptSubmit", ["prompt": "<task-notification>\n<task-id>x</task-id>"], at: 26)
        let turn4 = turn()
        check(turn4 == turn3 && number("turnStart") == 13, "这一轮还在跑时来了任务通知：接着算这一轮，起点不挪")
        fire("Notification", ["notification_type": "permission_prompt"], at: 30)
        check(state() == "waiting", "等你批准")
        fire("PostToolUse", ["tool_name": "Bash"], at: 35)
        check(state() == "running" && turn() == turn4, "批准后接着跑，不换轮")

        // 动作记录（新会话 s2）：给 Windows 小乔的思维链。新的在前、最多 3 条、TodoWrite 不记、新的一轮清空
        fire("UserPromptSubmit", ["prompt": "干一件"], at: 36, session: "s2")
        fire("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "git status"]], at: 37, session: "s2")
        fire("PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/p/Pet.swift"]], at: 38, session: "s2")
        fire("PostToolUse", ["tool_name": "TodoWrite", "tool_input": ["todos": []]], at: 39, session: "s2")
        check((rec("s2")["actions"] as? [String]) == ["读 Pet.swift", "命令 git status"], "动作记录：分类成短句、新的在前、TodoWrite 不记")
        fire("PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/p/A.swift"]], at: 40, session: "s2")
        fire("PostToolUse", ["tool_name": "Write", "tool_input": ["file_path": "/p/B.swift"]], at: 41, session: "s2")
        fire("PostToolUse", ["tool_name": "Write", "tool_input": ["file_path": "/p/C.swift"]], at: 41.5, session: "s2")
        check((rec("s2")["actions"] as? [String])?.count == 3, "动作记录最多 3 条")
        fire("UserPromptSubmit", ["prompt": "新的一轮"], at: 42, session: "s2")
        check(rec("s2")["actions"] == nil, "新的一轮动作清空")

        // 旧版本写的记录：没有轮次字段，照样读，只是没有小票、不能订阅
        let old = SessionFiles.session(["agent": "claude", "id": "old", "state": "done", "updated": start, "since": start])
        check(old != nil && old?.turnID == nil && old?.turnStart == nil && old?.background == 0, "旧记录缺字段照样读")
        let model = AppModel()
        if let old {
            model.sessions = [old]
            check(model.receipt(for: old) == nil && model.watchCard(session: old) == nil, "旧记录没有小票，也不能订阅")
        }

        // 后台还在跑的只数工作流、子代理（还在排队或在跑的）
        let snapshot: [[String: Any]] = [["type": "workflow", "status": "running"], ["type": "subagent", "status": "pending"],
                                         ["type": "shell", "status": "running"], ["type": "monitor", "status": "running"],
                                         ["type": "subagent", "status": "completed"]]
        check(SessionHook.backgroundWork(snapshot) == 2 && SessionHook.backgroundWork(nil) == nil && SessionHook.backgroundWork("坏的") == nil,
              "只数还在跑的工作流和子代理；没带或格式不对是 nil")

        // 19:15 那次：主对话停了，工作流还在后台跑
        fire("Stop", ["background_tasks": [["type": "workflow", "status": "running"], ["type": "subagent", "status": "running"]]], at: 40)
        check(state() == "running" && number("background") == 2 && number("turnEndedAt") == nil, "主对话停了但后台还有两个在跑：还算在跑")
        let session = SessionFiles.session(rec())
        check(session?.briefStatus(.running, now: t0.addingTimeInterval(40)).hasPrefix("后台 2 个在跑") == true, "卡片上写后台还有几个在跑")
        fire("Notification", ["notification_type": "permission_prompt"], at: 41)
        fire("PostToolUse", ["tool_name": "Bash"], at: 42)
        check(state() == "running" && number("background") == 2, "等你、批准之后，后台的数还在")

        // 19:18 那次：五个子代理被限流
        let since = number("since")
        for index in 0..<5 { fire("StopFailure", ["agent_id": "sub\(index)", "error": "rate_limit"], at: 43 + Double(index)) }
        check(state() == "running" && number("since") == since, "五个子代理被限流：主会话的状态和开始时间都不变")
        fire("Stop", ["agent_id": "sub9"], at: 49)
        check(state() == "running", "子代理的 Stop 不结束主会话")
        fire("Stop", [:], at: 50)
        check(state() == "running" && number("background") == 2, "没带快照的 Stop：不当成后台已经清空")
        fire("Stop", ["background_tasks": "坏的"], at: 51)
        check(state() == "running", "快照格式不对也不提前算完成")
        fire("Stop", ["background_tasks": [["type": "workflow"]]], at: 51.5)
        check(state() == "running" && number("background") == 2, "清单里的条目缺字段：看不出还在不在跑，沿用已知的两个")
        check(SessionHook.backgroundWork([["type": "workflow"]]) == nil && SessionHook.backgroundWork([["status": "running"]]) == nil
              && SessionHook.backgroundWork([[String: Any]]()) == 0, "缺 type 或 status 的清单算坏的；空清单是 0")
        fire("UserPromptSubmit", ["prompt": "<task-notification>done</task-notification>"], at: 52)
        let turn5 = turn()
        check(turn5 == turn4 && number("background") == 2, "后台干完把主对话叫醒：接着算这一轮，后台的数还在")
        fire("Stop", ["background_tasks": [[String: Any]]()], at: 53)
        check(state() == "done" && number("turnEndedAt") == start + 53 && turn() == turn5, "主对话再停一次、后台清空：完成")
        fire("Notification", ["notification_type": "permission_prompt"], at: 53.5)
        fire("UserPromptSubmit", ["prompt": "<task-notification>等你时来的通知</task-notification>"], at: 53.7)
        check(state() == "running" && rec()["waitAgent"] == nil && rec()["waitReason"] == nil && turn() == turn5, "主代理在等你批准时来了任务通知：不再等了，这一轮接着算")
        fire("Notification", ["notification_type": "permission_prompt", "agent_id": "sub7"], at: 53.75)
        fire("UserPromptSubmit", ["prompt": "<task-notification>子代理在等你时来的通知</task-notification>"], at: 53.76)
        check(state() == "waiting", "子代理的弹窗在等你时来了通知：橙灯不被冲掉")
        fire("PostToolUse", ["tool_name": "Bash", "agent_id": "sub7"], at: 53.8)
        fire("Stop", ["background_tasks": [[String: Any]]()], at: 53.9)
        fire("UserPromptSubmit", ["prompt": "<task-notification>迟到的通知</task-notification>"], at: 54)
        check(turn() != turn5 && state() == "running", "已经做完了才来的通知：新的一轮开始干活")
        fire("Stop", ["background_tasks": [[String: Any]]()], at: 55)

        fire("UserPromptSubmit", ["prompt": "下一件"], at: 60)
        fire("StopFailure", ["error": "rate_limit"], at: 61)
        check(state() == "error" && number("turnEndedAt") == start + 61, "主对话自己被限流：照旧标红")

        fire("UserPromptSubmit", ["prompt": "再下一件"], at: 70)
        fire("Stop", ["background_tasks": [["type": "workflow", "status": "running"]]], at: 71)
        fire("UserPromptSubmit", ["prompt": "又一件"], at: 72)
        check(number("background") == nil, "新的一轮清掉上一轮的后台数")
        fire("Notification", ["notification_type": "permission_prompt"], at: 73, session: "s1")
        fire("PostToolUse", [:], at: 73.5)
        fire("Notification", ["notification_type": "permission_prompt", "agent_id": "sub1"], at: 74)
        fire("Stop", ["background_tasks": [[String: Any]]()], at: 75)
        check(state() == "waiting", "子代理的弹窗在等你时主对话停了：还是等你")

        // Codex：点停止有 Interrupt hook，记成「你打断了」；下一句话提交后是新的一轮，不再算打断
        func codex(_ event: String, at offset: TimeInterval) {
            let o: [String: Any] = ["session_id": "c1", "hook_event_name": event, "transcript_path": transcript.path, "cwd": dir.path]
            SessionHook.run(agentArg: "codex", input: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(),
                            env: SessionHook.Environment(dir: dir, now: t0.addingTimeInterval(offset), bundle: nil, title: { _, _, _, _, _, _ in nil }))
        }
        func codexRec() -> AgentSession? {
            (try? Data(contentsOf: SessionFiles.url("codex-c1", in: dir)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.flatMap(SessionFiles.session)
        }
        codex("UserPromptSubmit", at: 80)
        let codexTurn = codexRec()?.turnID
        codex("Interrupt", at: 90)
        check(codexRec()?.state == .idle && codexRec()?.interrupted == true && codexRec()?.briefStatus(.idle, now: t0.addingTimeInterval(95)).hasPrefix("你打断了") == true,
              "Codex 点了停止：空闲，卡片上写你打断了")
        codex("UserPromptSubmit", at: 100)
        check(codexRec()?.state == .running && codexRec()?.interrupted == false && codexRec()?.turnID != codexTurn, "Codex 又说了一句：新的一轮，不再是打断")

        // ZCode：hook 输入是 Claude 兼容格式，没有 Notification/SessionEnd——等你全靠 PermissionRequest；
        // 记录在它的会话库里，新的一轮记当时的最大行号
        let zsid = "sess_abc12345"
        let zdb = dir.appendingPathComponent("zcode-db.sqlite").path
        check(seedZcodeParts(zdb, [(zsid, #"{"type":"text","text":"之前的话"}"#),
                                   (zsid, #"{"type":"tool","tool":"Bash","state":{"status":"completed","input":{"command":"./test.sh"}}}"#)]),
              "ZCode 会话库建好")
        func zfire(_ event: String, _ extra: [String: Any] = [:], at offset: TimeInterval) {
            var o: [String: Any] = ["session_id": zsid, "hook_event_name": event, "transcript_path": transcript.path, "cwd": dir.path]
            for (key, value) in extra { o[key] = value }
            SessionHook.run(agentArg: "zcode", input: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(),
                            env: SessionHook.Environment(dir: dir, now: t0.addingTimeInterval(offset), bundle: nil,
                                                         zcodeDB: zdb, title: { _, _, _, _, _, _ in nil }))
        }
        func zrec() -> AgentSession? {
            (try? Data(contentsOf: SessionFiles.url("zcode-" + zsid, in: dir)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.flatMap(SessionFiles.session)
        }
        zfire("UserPromptSubmit", ["prompt": "帮我改改"], at: 110)
        let zturn = zrec()?.turnID
        check(zrec()?.state == .running && zrec()?.turnRow == 2 && zrec()?.agentName == "ZCode" && zrec()?.appBundle == "dev.zcode.app",
              "ZCode 提交：在跑，记下会话库当时的行号，名字和 app 对")
        zfire("PermissionRequest", at: 112)
        check(zrec()?.state == .waiting && zrec()?.waitReason == "permission", "ZCode 弹批准：等你批准")
        zfire("PostToolUse", at: 113)
        check(zrec()?.state == .running, "ZCode 批准后接着跑")
        zfire("Stop", at: 115)
        check(zrec()?.state == .done, "ZCode 停下：完成")
        check(seedZcodeParts(zdb, [(zsid, #"{"type":"tool","tool":"Edit","state":{"status":"running","input":{"file_path":"/p/A.swift"}}}"#)]), "再塞一行")
        zfire("UserPromptSubmit", ["prompt": "再来一件"], at: 120)
        check(zrec()?.turnID != zturn && zrec()?.turnRow == 3, "ZCode 再提交：新的一轮，行号跟着走")
        zfire("PostToolUseFailure", ["is_interrupt": true], at: 122)
        check(zrec()?.state == .idle && zrec()?.interrupted == true, "ZCode 里你打断了：空闲，记成你打断了")
        zfire("UserPromptSubmit", ["prompt": "继续"], at: 124)
        check(zrec()?.state == .running && zrec()?.interrupted != true, "ZCode 再提交：新一轮，不再是打断")

        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks.log").path), "日志也写在临时目录里")
    }
}
