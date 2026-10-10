import AppKit

/// Codex 的路线图：从 rollout 记录里认出做完的动作、正在做的调用；模型按 AI 分开读；前台换成 Codex 时画 Codex 的
enum CodexRoadTests {
    static func json(_ object: [String: Any]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? ""
    }
    static func item(_ item: [String: Any], at ms: Double = 1_790_807_459_629) -> String {
        json(["timestamp": "2026-09-30T22:30:59.629Z", "type": "event_msg",
              "payload": ["type": "item_completed", "thread_id": "th", "turn_id": "tu", "item": item, "started_at_ms": ms, "completed_at_ms": ms]])
    }
    static func command(_ cmd: String, exit: Int = 0, parsed: [[String: Any]]? = nil, output: String = "") -> String {
        item(["type": "CommandExecution", "id": "exec-\(UUID().uuidString)", "command": ["/bin/zsh", "-lc", cmd],
              "parsed_cmd": parsed ?? [["type": "unknown", "cmd": cmd]], "status": exit == 0 ? "completed" : "failed", "exit_code": exit,
              "aggregated_output": output, "stdout": output])
    }
    static func call(_ id: String, script: String) -> String {
        json(["timestamp": "2026-09-30T22:30:59.496Z", "type": "response_item",
              "payload": ["type": "custom_tool_call", "status": "completed", "call_id": id, "name": "exec", "input": script]])
    }
    static func function(_ id: String, _ name: String, namespace: String? = nil, arguments: [String: Any] = [:]) -> String {
        var payload: [String: Any] = ["type": "function_call", "call_id": id, "name": name, "arguments": json(arguments)]
        if let namespace { payload["namespace"] = namespace }
        return json(["timestamp": "2026-09-30T22:30:59.496Z", "type": "response_item", "payload": payload])
    }
    static func output(_ id: String, custom: Bool = true, text: String = "Script completed") -> String {
        json(["timestamp": "2026-09-30T22:31:01.689Z", "type": "response_item",
              "payload": ["type": custom ? "custom_tool_call_output" : "function_call_output", "call_id": id, "output": [["type": "input_text", "text": text]]]])
    }
    static func parse(_ lines: [String]) -> RoadParse {
        RoadmapBuilder.parse(Data((lines.joined(separator: "\n") + "\n").utf8), codex: true)
    }

    @MainActor
    static func inspect(path: String, codex: Bool, from: Int, png: String?) {
        guard let data = FileManager.default.contents(atPath: path), from <= data.count else { print("读不了"); return }
        let parse = RoadmapBuilder.parse(data.subdata(in: from..<data.count), codex: codex)
        print("动作 \(parse.actions.count) 个，没返回的调用 \(parse.calls.count) 个")
        for action in parse.actions.suffix(30) { print(" ", RoadmapBuilder.verb(action.kind), action.object, action.failed ? "✗" : "", action.verified ? "✓" : "") }
        let built = RoadmapBuilder.trail(parse, state: .running, open: "k", took: nil, now: Date())
        for step in built.steps { print("→", step.title, "|", step.sub, "|", step.state) }
        if let png {
            let road = Roadmap(key: "k", turnID: "T", steps: built.steps, hidden: built.hidden, finished: false, plan: false)
            Snapshot.touchBar(TouchBarItem.roadParts(road).map(\.image), to: png)
        }
    }

    @MainActor
    static func run(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        builder(now: now, check: check)
        await model(now: now, check: check)
        bar(now: now, rows: rows, check: check)
    }

    @MainActor
    static func builder(now: Date, check: (Bool, String) -> Void) {
        // 一段脚本里跑两条命令：先 ls（Codex 自己认出是看目录）、再测试；中间还有消息、推理、token 记录这些不算
        let script = "text(await tools.exec_command({cmd:\"ls /p\",max_output_tokens:100}));\ntext(await tools.exec_command({cmd:\"./test.sh\"}));\n"
        let noise = [json(["type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "AgentMessage", "content": [["type": "Text", "text": "我先看看"]]]]]),
                     json(["type": "event_msg", "payload": ["type": "token_count", "info": [:]]]),
                     json(["type": "response_item", "payload": ["type": "reasoning", "encrypted_content": "gAAA"]])]
        var lines = noise + [call("c1", script: script)]
        let started = parse(lines)
        check(started.actions.isEmpty && started.pending?.kind == .read && started.calls.first?.steps.map(\.kind) == [.read, .test],
              "脚本发出去还没做完：认出里面要做的两件事，正在做的是第一件（ls 分成读）")
        check(started.pending?.object == "ls", "字面写出的命令：取程序名（ls 后面的路径不写）")
        lines.append(command("ls /p", parsed: [["type": "list_files", "cmd": "ls /p", "path": "p"]]))
        let half = parse(lines)
        check(half.actions.map(\.kind) == [.search] && half.pending?.kind == .test && half.pending?.object == "test.sh",
              "第一件做完了：记下来；正在做的换成第二件（跑测试）")
        let running = RoadmapBuilder.trail(half, state: .running, open: "codex-a", took: nil, now: now).steps
        check(running.map(\.title) == ["搜索", "跑测试"] && running.last?.state == .current && running.last?.sub == "进行中 · test.sh" && running.last?.open == "codex-a",
              "在跑：正在做的那件接在最后，写进行中")
        let waiting = RoadmapBuilder.trail(half, state: .waiting, open: "codex-a", took: nil, now: now).steps
        check(waiting.map(\.title) == ["搜索", "等你"], "等你批准：正在做的那件不画，最后一步是等你")
        lines.append(command("./test.sh", exit: 1))
        lines.append(output("c1"))
        let done = parse(lines)
        check(done.actions.count == 2 && done.actions[1].kind == .test && done.actions[1].failed && done.calls.isEmpty && done.pending == nil,
              "测试退出码非零：没过；调用返回了就不再算正在做")
        let quiet = parse([command("rg -n nothing /p", exit: 1, parsed: [["type": "search", "cmd": "rg -n nothing /p", "query": "nothing", "path": "p"]]),
                           command("grep -rn nothing /p", exit: 1), command("rg --files", exit: 127, parsed: [["type": "list_files", "cmd": "rg --files"]]),
                           item(["type": "Extension", "kind": "clock.sleep", "id": "z", "durationMs": 45000])])
        check(!quiet.actions[0].failed && !quiet.actions[1].failed && quiet.actions[2].failed && quiet.actions[2].object == "列文件"
              && quiet.actions[3].kind == .other && quiet.actions[3].object == "等一会儿",
              "搜索没搜到（退出码 1）不算出错；找不到命令（127）算；等一会儿不写成工具名")
        let passed = parse([command("./test.sh"), command("./test.sh 2>&1 | tail -3")])
        check(passed.actions[0].verified && !passed.actions[1].verified, "单条测试退出码 0：算过了；管道里的看不出")

        // 读文件、改文件（一次改了几个）、搜网页、看图、MCP、子代理
        let mixed = parse([
            command("sed -n '1,80p' /p/Pet.swift", parsed: [["type": "read", "cmd": "sed -n '1,80p' /p/Pet.swift", "name": "Pet.swift", "path": "/p/Pet.swift"]]),
            item(["type": "FileChange", "id": "e1", "status": "completed", "changes": ["/p/B.swift": ["type": "update", "unified_diff": "@@"],
                                                                                     "/p/A.swift": ["type": "update", "unified_diff": "@@"],
                                                                                     "/p/New.swift": ["type": "add", "content": "x"]]]),
            item(["type": "Extension", "kind": "web.search", "id": "w", "query": "q", "action": ["type": "search", "queries": ["q"]]]),
            item(["type": "Extension", "kind": "web.search", "id": "w2", "query": "", "action": ["type": "openPage", "url": "https://x"]]),
            item(["type": "ImageView", "id": "i", "path": "file:///p/shot%20one.png"]),
            item(["type": "McpToolCall", "id": "m", "server": "cua_repl", "tool": "js", "arguments": ["code": "x"], "status": "completed",
                  "result": ["content": [], "isError": true]]),
            item(["type": "SubAgentActivity", "id": "s", "kind": "started", "agent_thread_id": "t", "agent_path": "/root/a"]),
            command("FOO=secret ./run.sh --x", exit: 2),
        ])
        check(mixed.actions.map(\.kind) == [.read, .edit, .edit, .write, .web, .web, .read, .tool, .agent, .command],
              "认出读文件、改文件（新建的算写）、搜网页、读网页、看图、工具、子代理、命令")
        check(mixed.actions[0].object == "Pet.swift" && mixed.actions[1].object == "A.swift" && mixed.actions[3].object == "New.swift"
              && mixed.actions[6].object == "shot one.png" && mixed.actions[7].object == "操作电脑" && mixed.actions[7].failed
              && mixed.actions[9].object == "run.sh" && mixed.actions[9].failed && mixed.actions.allSatisfy { $0.done && $0.at != nil },
              "只写文件名、不写路径；工具报错、命令非零都算没成；环境变量赋值不显示")
        let grouped = RoadmapBuilder.trail(mixed, state: .done, open: "k", took: 90, now: now).steps
        check(grouped.map(\.title) == ["读", "改 ×2", "写", "查网页 ×2", "读", "调用工具", "子代理", "命令", "完成"],
              "连着的合成一步；做完了最后写完成（九步都留着，不再只留最后 8 步）")

        // 补丁：exec 脚本里调 apply_patch（转义过的 \n）、function_call 的提问、等结果、子代理
        let patched = parse([call("p1", script: "const patch=\"*** Begin Patch\\n*** Update File: /p/Watch.swift\\n@@\\n-a\\n+b\\n*** End Patch\";\ntext(await tools.apply_patch(patch));")])
        check(patched.pending?.kind == .edit && patched.pending?.object == "Watch.swift", "脚本里改文件：认出改哪个")
        check(parse([function("q", "request_user_input", arguments: ["questions": []])]).pending?.kind == .ask
              && parse([function("w", "wait", arguments: ["cell_id": "1"])]).pending?.object == "等结果"
              && parse([function("a", "spawn_agent", namespace: "collaboration")]).pending?.object == "派出子代理"
              && parse([function("x", "exec_command", arguments: ["cmd": "swift build"])]).pending?.kind == .build,
              "提问、等结果、派子代理、老式的命令调用")
        check(parse([call("v", script: "const cmd = pick();\nawait tools.exec_command({cmd});")]).pending.map { $0.kind == .command && $0.object.isEmpty } == true,
              "变量拼出来的命令：只写「命令」")
        check(parse([call("t", script: "text('hi');")]).calls.isEmpty, "只输出文字的脚本：不算动作")

        // 大结果（截图、长输出）：不整段解析，只取 call_id
        let big = String(repeating: "A", count: RoadmapBuilder.hugeLine + 100)
        let huge = parse([function("f", "view_image", arguments: ["path": "/p/x.png"]), output("f", custom: false, text: big)])
        check(huge.calls.isEmpty, "大结果行也能对上 call_id")
        check(CodexRoad.callID(Data("{\"call_id\":\"call_abc\",\"x\":1}".utf8)) == "call_abc", "从大行里取出 call_id")

        // 被打断留下的调用：只留最近几个；半行留到下次
        var many: [String] = []
        for index in 0..<12 { many.append(call("k\(index)", script: "await tools.exec_command({cmd:\"sleep \(index)\"});")) }
        check(parse(many).calls.count == CodexRoad.keepCalls && parse(many).pending?.object == "sleep", "没返回的调用只留最近几个，正在做的是最后一个")
        let line = command("ls")
        var growing = RoadParse()
        let ate = RoadmapBuilder.feed(&growing, Data((line + "\n" + String(line.prefix(30))).utf8), codex: true)
        check(ate == line.utf8.count + 1 && growing.actions.count == 1, "最后没写完的半行留着")
        check(parse(["{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\"", "乱七八糟"]).actions.isEmpty, "半行和乱行不崩")
    }

    @MainActor
    static func model(now: Date, check: (Bool, String) -> Void) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-codexroad-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("rollout-2026-09-30T18-30-52-01a0f471-2cda-7340-ab5e-4504596e9578.jsonl").path
        let before = command("echo 上一轮") + "\n"
        let turn = [command("ls", parsed: [["type": "list_files", "cmd": "ls", "path": "."]]),
                    call("c", script: "await tools.exec_command({cmd:\"swift build\"});")].joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: path, contents: Data((before + turn).utf8))
        let identity = AppModel.fileIdentity(path)
        let codex = AgentSession(agent: "codex", id: "01a0f471", state: .running, since: now, updated: now, first: now, title: "改路由", bundle: "", transcript: path,
                                 turnID: "T1", turnStart: before.utf8.count, turnInode: identity?.inode, turnAt: now.addingTimeInterval(-30))
        let model = AppModel()
        var queued: [() -> Void] = []
        model.roadRun = { queued.append($0) }
        model.sessions = [codex]
        model.roadWanted = "claude"
        model.refreshRoadmaps()
        check(queued.isEmpty, "前台是 Claude：不读 Codex 的")
        model.roadWanted = "codex"
        model.refreshRoadmaps()
        check(queued.count == 1, "前台是 Codex：读 Codex 的")
        queued.removeFirst()()
        try? await Task.sleep(nanoseconds: 80_000_000)
        let road = model.roadmaps(at: now)["codex"]
        check(road?.steps.map(\.title) == ["搜索", "构建"] && road?.steps.last?.sub == "进行中 · swift build" && road?.key == "codex-01a0f471" && model.roadmaps(at: now)["claude"] == nil,
              "Codex 的路线图：上一轮的不算，正在构建")
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((command("swift build") + "\n" + output("c") + "\n").utf8))
            try? handle.close()
        }
        var finished = codex
        finished.state = .done
        finished.turnEndedAt = now
        model.sessions = [finished]
        model.refreshRoadmaps()
        queued.first?()
        try? await Task.sleep(nanoseconds: 80_000_000)
        let after = model.roadmaps(at: now)["codex"]
        check(after?.steps.map(\.title) == ["搜索", "构建", "完成"] && after?.steps[1].sub == "swift build · 过了" && after?.finished == true,
              "接着读追加的：构建过了；做完留着最后一次路线")
    }

    @MainActor
    static func bar(now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        var presented = 0
        let bar = TouchBarItem()
        bar.presenter = { _ in presented += 1 }
        bar.presentationAllowed = { true }
        bar.pretendShownForTesting()
        var wanted: [String?] = []
        bar.onRoadWanted = { wanted.append($0) }
        func road(_ key: String, _ sub: String) -> Roadmap {
            Roadmap(key: key, turnID: "T", steps: [RoadStep(title: "读", sub: "A.swift", state: .done), RoadStep(title: "改", sub: sub, state: .current, open: key)],
                    hidden: 0, finished: false, plan: false)
        }
        let roads = ["claude": road("claude-a", "进行中 · Claude.swift"), "codex": road("codex-b", "进行中 · Codex.swift")]
        bar.update(rows: rows, lights: [], tasks: [], now: now, roads: roads)
        bar.frontAppChanged("com.openai.codex", promptApp: "Codex", autoShow: false)
        check(wanted == ["codex"] && presented == 1 && bar.shown.last?.label?.contains("Codex.swift") == true, "Codex 到前台：要 Codex 的数据，摆 Codex 的路线图")
        bar.visibleForTesting = true
        bar.frontAppChanged("com.anthropic.claudefordesktop", promptApp: "Claude", autoShow: false)
        check(wanted == ["codex", "claude"] && bar.shown.last?.label?.contains("Claude.swift") == true, "直接切到 Claude：换成 Claude 的，不收起再弹")
        bar.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(10), roads: ["claude": road("claude-a", "进行中 · Claude.swift")])
        let closes = bar.closeRequestsForTesting
        bar.frontAppChanged("com.openai.codex", promptApp: "Codex", autoShow: false)
        check(bar.closeRequestsForTesting == closes + 1 && wanted.last == "codex", "切到 Codex、它没有路线图：收起")
    }
}
