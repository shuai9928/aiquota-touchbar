import AppKit

/// 工作流路线图：从对话记录里提取走过的路、待办清单；挑会话；左边空位什么时候摆出来、什么时候收起
enum RoadmapTests {
    static func use(_ id: String, _ name: String, _ input: [String: Any], sidechain: Bool = false) -> String {
        ReceiptTests.use(id, name, input, sidechain: sidechain)
    }
    static func result(_ id: String, error: Bool = false, text: String = "ok") -> String {
        ReceiptTests.result(id, error: error, text: text)
    }
    static func parse(_ lines: [String]) -> RoadParse {
        RoadmapBuilder.parse(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    @MainActor
    static func run(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        builder(now: now, check: check)
        await model(now: now, check: check)
        bar(now: now, rows: rows, check: check)
    }

    @MainActor
    static func builder(now: Date, check: (Bool, String) -> Void) {
        var lines: [String] = []
        for index in 0..<3 { lines += [use("r\(index)", "Read", ["file_path": "/p/Pet\(index).swift"]), result("r\(index)")] }
        lines += [use("e1", "Edit", ["file_path": "/p/AIQuota.swift"]), result("e1"), use("e2", "Edit", ["file_path": "/p/Watch.swift"]), result("e2"),
                  use("t1", "Bash", ["command": "./test.sh"]), result("t1"),
                  use("c1", "Bash", ["command": "cd /p && git status -s"]), result("c1"),
                  use("t2", "Bash", ["command": "swift test"]), result("t2", error: true, text: "Exit code 1\n失败"),
                  use("s1", "Edit", ["file_path": "/p/side.swift"], sidechain: true), result("s1"),
                  use("g1", "Grep", ["pattern": "petLine"])]
        let parsed = parse(lines)
        check(parsed.actions.map(\.kind) == [.read, .read, .read, .edit, .edit, .test, .command, .test, .search], "按顺序认出每个动作（子代理的不算）")
        check(parsed.actions[5].object == "test.sh" && parsed.actions[6].object == "git status" && parsed.actions[7].failed && !parsed.actions[5].failed
              && parsed.actions[8].done == false, "测试认出简称、命令取开头（跳过 cd）、失败的标红、没返回的还没完成")
        let grouped = RoadmapBuilder.groups(parsed.actions)
        check(grouped.map(\.count) == [3, 2, 1, 1, 1, 1] && grouped.map(\.kind) == [.read, .edit, .test, .command, .test, .search], "连着的同一种事合成一步，测试和失败的单独一步")

        let running = RoadmapBuilder.trail(parsed, state: .running, open: "claude-a", took: nil, now: now)
        check(running.steps.count == 6 && running.hidden == 0, "六步都在")
        check(running.steps[0].title == "读 ×3" && running.steps[0].sub == "Pet2.swift 等" && running.steps[0].state == .done, "读 ×3，写最后一个文件名")
        check(running.steps[2].sub == "test.sh · 过了" && running.steps[4].state == .failed && running.steps[4].sub == "swift test · 没过", "测试过了、没过")
        check(running.steps[5].state == .current && running.steps[5].sub == "进行中 · petLine" && running.steps[5].open == "claude-a", "最后一步是正在做的，点了打开对话")
        check(running.steps[0].open == nil && running.steps[2].open == nil, "做完的步点了不动")
        let waiting = RoadmapBuilder.trail(parsed, state: .waiting, open: "claude-a", took: nil, now: now)
        check(waiting.steps.last?.state == .waiting && waiting.steps.last?.title == "等你" && waiting.steps.count == 7, "等你批准：最后多一步「等你」")
        let finished = RoadmapBuilder.trail(parsed, state: .done, open: "claude-a", took: 725, now: now)
        check(finished.steps.last?.title == "完成" && finished.steps.last?.sub == "用了 12分" && finished.steps.dropLast().allSatisfy { $0.state != .current },
              "做完：最后一步写完成和用了多久，没有「正在做」")
        let failedTurn = RoadmapBuilder.trail(parsed, state: .error, open: "claude-a", errorText: "被限流 · 约 21:10 恢复", took: nil, now: now)
        check(failedTurn.steps.last?.state == .failed && failedTurn.steps.last?.sub == "被限流 · 约 21:10 恢复", "出错：最后一步写原因")
        check(RoadmapBuilder.trail(RoadParse(), state: .running, open: "k", took: nil, now: now).steps.first?.title == "开始了", "还没有动作：写开始了")
        var many = RoadParse()
        for index in 0..<20 { many.actions.append(RoadAction(kind: index % 2 == 0 ? .read : .edit, object: "f\(index)", done: true)) }
        let long = RoadmapBuilder.trail(many, state: .running, open: "k", took: nil, now: now)
        check(long.steps.count == 20 && long.hidden == 0 && long.steps.last?.state == .current, "二十步全留着（放不下就左右划），不再只留最后 8 步")
        var huge60 = RoadParse()
        for index in 0..<60 { huge60.actions.append(RoadAction(kind: index % 2 == 0 ? .read : .edit, object: "f\(index)", done: true)) }
        let longer = RoadmapBuilder.trail(huge60, state: .running, open: "k", took: nil, now: now)
        check(longer.steps.count == RoadmapBuilder.keepSteps && longer.hidden == 60 - RoadmapBuilder.keepSteps && longer.steps.last?.state == .current,
              "特别长的只留最后 \(RoadmapBuilder.keepSteps) 步，更前面的折成 +N")

        // 管道、后台跑的测试/构建：看不出成败，不写「过了」
        let piped = parse([use("p1", "Bash", ["command": "./test.sh 2>&1 | tail -5"]), result("p1"),
                           use("p2", "Bash", ["command": "./test.sh", "run_in_background": true]), result("p2")])
        let unverified = RoadmapBuilder.trail(piped, state: .done, open: "k", took: nil, now: now).steps
        check(unverified[0].sub == "test.sh" && unverified.dropLast().allSatisfy { !$0.sub.contains("过了") }, "管道里、后台跑的测试：不写「过了」")
        check(RoadmapBuilder.brief("FOO=secret BAR=1 ./run.sh --x") == "run.sh" && RoadmapBuilder.brief("export TOKEN=abc123") == "export"
              && RoadmapBuilder.brief("cd /p && git status -s") == "git status" && RoadmapBuilder.brief("OPENAI_API_KEY=sk-xx") == "",
              "命令简称：跳过环境变量赋值，export 这类只写命令名，不把密钥显示出来")
        // 命令分类：读文件、搜索、在 PC 上、请 Codex；其余算命令
        check(RoadmapBuilder.shellKind("cat AIQuota.swift") == .read && RoadmapBuilder.shellKind("head -5 b.swift") == .read
              && RoadmapBuilder.shellKind("rg -n petLine mac") == .search && RoadmapBuilder.shellKind("find . -name y") == .search
              && RoadmapBuilder.shellKind("ssh win 'tb list'") == .pc && RoadmapBuilder.shellKind("codex exec -- 检查") == .codex,
              "命令分类：读、搜索、在 PC 上、请 Codex")
        check(RoadmapBuilder.shellKind("FOO=1 grep -r x .") == .search && RoadmapBuilder.shellKind("cd /p && find . -name y") == .search,
              "命令分类：跳过环境变量赋值和 cd")
        check(RoadmapBuilder.shellKind("git status") == .command && RoadmapBuilder.shellKind("make -j8") == .command
              && RoadmapBuilder.shellKind("sed -n '1,5p' a.swift") == .command, "命令分类：其余算命令")
        let shell = parse([use("h1", "Bash", ["command": "cat a.swift"]), result("h1"),
                           use("h2", "Bash", ["command": "head -5 b.swift"]), result("h2")])
        let groupedShell = RoadmapBuilder.groups(shell.actions)
        check(groupedShell.count == 1 && groupedShell[0].kind == .read && groupedShell[0].count == 2, "shell 读文件也并进「读」")

        // ZCode 的路线图：动作在它的会话库（part 表）里，明文的思考链画成「想」
        let zdb = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-zroad-\(UUID().uuidString).sqlite").path
        check(SessionHookTests.seedZcodeParts(zdb, [
            ("sessR", #"{"type":"text","text":"这段对话不画"}"#),
            ("sessR", #"{"type":"reasoning","text":"先把命令分类想清楚\n再动手"}"#),
            ("sessR", #"{"type":"tool","tool":"Edit","state":{"status":"error","input":{"file_path":"/p/A.swift"}}}"#),
            ("sessR", #"{"type":"tool","tool":"Bash","state":{"status":"completed","input":{"command":"./test.sh"}}}"#),
            ("sessR", #"{"type":"tool","tool":"Bash","state":{"status":"running","input":{"command":"sleep 5"}}}"#),
            ("sessR", #"{"type":"tool","tool":"TodoWrite","state":{"status":"completed","input":{"todos":[{"content":"分类","status":"in_progress"}]}}}"#),
        ]), "ZCode 会话库建好")
        check(ZcodeRoad.maxRow(db: zdb, session: "sessR") == 6, "ZCode 行号：最大行")
        check(ZcodeRoad.maxRow(db: zdb, session: "没有的会话") == 0 && ZcodeRoad.maxRow(db: "/没有的库.sqlite", session: "s") == nil,
              "ZCode 行号：没有记录算 0（新会话第一轮从 0 读起），打不开库是 nil")
        let zparse = ZcodeRoad.read(db: zdb, session: "sessR", fromRow: 0)
        check(zparse.actions.map(\.kind) == [.think, .edit, .test, .command], "ZCode 动作：想、改、跑测试、命令，对话不画")
        check(zparse.actions[0].object.contains("先把命令分类") && zparse.actions[1].done && zparse.actions[1].failed
              && zparse.actions[2].done && !zparse.actions[3].done && zparse.plan?.map(\.text) == ["分类"],
              "ZCode：思考取开头一段；error 算没成；completed 算做完；running 还没完；待办进计划")
        let zsteps = RoadmapBuilder.trail(zparse, state: .running, open: "zcode-a", took: nil, now: now).steps
        check(zsteps.map(\.title) == ["想", "改", "跑测试", "命令"] && zsteps[1].state == .failed
              && zsteps[2].sub == "test.sh · 过了" && zsteps[3].state == .current && zsteps[3].sub == "进行中 · sleep",
              "ZCode 路线：一格一步，正在做的接最后")
        // ZCode 的 token 记账和会话标题；token 卡和目的地文案
        let zdb2 = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-zusage-\(UUID().uuidString).sqlite").path
        check(SessionHookTests.seedZcodeParts(zdb2, [], sessions: [("sessT", "把触控栏接上 ZCode")],
              usage: [("sessT", 1_000, 900_000, 100_000), ("sessT", 2_000, 5_000_000, 400_000), ("sessT", 90_000_000_000, 1_000_000, 100_000)]),
              "ZCode 记账库建好")
        check(ZcodeRoad.tokens(db: zdb2, sinceMs: 500) == 7_500_000 && ZcodeRoad.tokens(db: zdb2, sinceMs: 50_000_000_000) == 1_100_000
              && ZcodeRoad.tokens(db: zdb2, sinceMs: 100_000_000_000) == 0, "token 记账：按起点往后合计")
        check(ZcodeRoad.title(db: zdb2, session: "sessT") == "把触控栏接上 ZCode" && ZcodeRoad.title(db: zdb2, session: "没有的") == nil,
              "ZCode 会话标题：查得到就用它")
        check(Fmt.tokens(9806) == "9806" && Fmt.tokens(23_700) == "2.4万" && Fmt.tokens(237_833_150) == "2.4亿", "token 数的短格式")
        check(PromptTargets.resolve("dev.zcode.app", own: nil).app == "ZCode", "常用指令：ZCode 也是目标 app")
        let quotaProvider = Provider(name: "Claude", detail: "",
                                     windows: [QuotaWindow(label: "5小时", short: "5h", used: 30, length: 5 * 3600)], updatedAt: now)
        let tokenCard = TouchBarArt.provider(Provider(name: "ZCode", detail: "", updatedAt: now, tokens: (237_833_150, 8_100_000_000)), now: now)
        let quotaCard = TouchBarArt.provider(quotaProvider, now: now)
        check(abs(tokenCard.size.width - quotaCard.size.width) < 0.5, "token 卡和额度卡一样宽")
        let withUsage = TouchBarItem.quotaImages(rows: [quotaProvider], usage: Provider(name: "ZCode", updatedAt: now, tokens: (1, 2)), now: now)
        check(withUsage.last?.id == "provider:ZCode#1", "ZCode 用量卡在额度页，跟在各家额度后面")
        check(!TouchBarItem.aiPage(rows: [quotaProvider], tasks: [], lights: [], relays: [], watched: [], now: now, link: nil, pet: TouchBarItem.relaxChip)
            .contains { $0.id.hasPrefix("provider:") }, "AI 页上不放 ZCode 用量卡")

        // 待办清单
        let plan = parse([use("p", "TodoWrite", ["todos": [["content": "读现有代码", "status": "completed"], ["content": "写实现", "status": "in_progress"],
                                                           ["content": "补测试", "status": "pending"], ["content": "装上", "status": "pending"]]]), result("p")])
        check(plan.plan?.count == 4 && plan.actions.isEmpty, "待办清单单独记，不算动作")
        let steps = RoadmapBuilder.planSteps(plan.plan ?? [], latest: RoadAction(kind: .edit, object: "Watch.swift"), state: .running, open: "claude-a")
        check(steps.steps.map(\.state) == [.done, .current, .todo, .todo] && steps.steps[1].sub == "进行中 · 改 Watch.swift" && steps.steps[2].sub == "下一步"
              && steps.steps[3].sub == "还没开始" && steps.steps[1].open == "claude-a" && steps.hidden == 0, "计划：做完的、正在做的（写最近的动作）、下一步、还没开始的")
        check(RoadmapBuilder.planSteps(plan.plan ?? [], latest: nil, state: .waiting, open: "k").steps[1].state == .waiting, "等你时计划里正在做的那步标成等你")
        var bigPlan: [RoadPlanItem] = []
        for index in 0..<10 { bigPlan.append(RoadPlanItem(text: "步骤\(index)", status: index < 5 ? .completed : index == 5 ? .inProgress : .pending)) }
        let window = RoadmapBuilder.planSteps(bigPlan, latest: nil, state: .running, open: "k")
        check(window.steps.count == 10 && window.hidden == 0 && window.steps[5].state == .current, "十项计划整个留着，不再只取 8 项")
        var hugePlan: [RoadPlanItem] = []
        for index in 0..<60 { hugePlan.append(RoadPlanItem(text: "步骤\(index)", status: index < 30 ? .completed : index == 30 ? .inProgress : .pending)) }
        let hugeWindow = RoadmapBuilder.planSteps(hugePlan, latest: nil, state: .running, open: "k")
        check(hugeWindow.steps.count == RoadmapBuilder.keepSteps && hugeWindow.hidden == 20 && hugeWindow.steps[10].state == .current,
              "计划特别长：留 \(RoadmapBuilder.keepSteps) 项（正在做的那步在里面，后面还没做的尽量多留），前面折起来")
        // 给 Windows 小乔的快照还是一段 8 步：走过的路取最后 8 步，清单以正在做的那步为中心
        let trailRoad = Roadmap(key: "k", turnID: "T", steps: long.steps, hidden: 0, finished: false, plan: false)
        let trailWindow = trailRoad.windowed(RoadmapBuilder.visibleSteps)
        check(trailWindow.steps == Array(long.steps.suffix(8)) && trailWindow.hidden == 12 && trailRoad.windowed(40) == trailRoad, "快照里走过的路：最后 8 步，前面算进 hidden；不够长就原样")
        let planRoad = Roadmap(key: "k", turnID: "T", steps: RoadmapBuilder.planSteps(bigPlan, latest: nil, state: .running, open: "k").steps, hidden: 0, finished: false, plan: true)
        let planWindow = planRoad.windowed(RoadmapBuilder.visibleSteps)
        check(planWindow.steps.count == 8 && planWindow.hidden == 2 && planWindow.steps[3].state == .current, "快照里的计划：以正在做的那步为中心取 8 项，前面折起来（和改版前一样）")

        // 画的时候不再按屏幕宽度折：整条画出来，放不下就左右划；前面真被截掉的才折成 +N，id 用绝对序号
        var wide: [RoadStep] = (0..<8).map { RoadStep(title: "读 ×\($0 + 2)", sub: "很长的文件名\($0).swift 等", state: .done) }
        wide[7].state = .current
        wide[7].open = "claude-a"
        let crowded = TouchBarItem.roadParts(Roadmap(key: "claude-a", turnID: "T", steps: wide, hidden: 0, finished: false, plan: false))
        let crowdedWidth = crowded.reduce(CGFloat(0)) { $0 + $1.image.size.width } + TouchBarItem.detailSpacing * CGFloat(crowded.count - 1)
        check(crowdedWidth > TouchBarItem.detailWidth && crowded.count == 15 && crowded.first?.id == "road:step:0" && crowded.last?.label?.contains("正在做") == true,
              "步太宽一屏放不下：八步一步不少地整条画出来（交给触控栏左右划）")
        let fewer = TouchBarItem.roadParts(Roadmap(key: "claude-a", turnID: "T", steps: Array(wide.suffix(2)), hidden: 0, finished: false, plan: false))
        check(fewer.first?.id == "road:step:0" && fewer.count == 3, "两步就两步")
        let cutRoad = TouchBarItem.roadParts(Roadmap(key: "claude-a", turnID: "T", steps: Array(wide.suffix(3)), hidden: 5, finished: false, plan: false))
        check(cutRoad.map(\.id) == ["road:more", "road:arrow:more", "road:step:5", "road:arrow:5", "road:step:6", "road:arrow:6", "road:step:7"]
              && cutRoad[0].label == "前面还有 5 步" && cutRoad[2].label?.hasPrefix("第 6 步") == true, "前面被截掉的折成「+5」；每步的 id 和读屏序号都算上前面折掉的")

        // 连着的同一个测试合并，失败的单独一步
        let again = parse([use("a1", "Bash", ["command": "./test.sh"]), result("a1"), use("a2", "Bash", ["command": "./test.sh"]), result("a2"),
                           use("a3", "Bash", ["command": "./test.sh"]), result("a3", error: true, text: "Exit code 1"), use("a4", "Bash", ["command": "./test.sh"]), result("a4")])
        let merged = RoadmapBuilder.trail(again, state: .running, open: "k", took: nil, now: now).steps
        check(merged.map(\.title) == ["跑测试 ×2", "跑测试", "跑测试"] && merged[1].state == .failed && merged[0].sub == "test.sh · 过了" && merged[2].state == .current,
              "连着跑了两次过了的测试合成「跑测试 ×2」；失败的单独一步；最后一次是正在做的")

        // 大结果行（截图、长输出）不整段解析，也能对上、认出失败
        let big = String(repeating: "A", count: RoadmapBuilder.hugeLine + 100)
        let huge = parse([use("h1", "Read", ["file_path": "/p/shot.png"]), result("h1", text: big), use("h2", "Bash", ["command": "make"]),
                          result("h2", error: true, text: "Exit code 2\n" + big)])
        check(huge.actions.count == 2 && huge.actions[0].done && !huge.actions[0].failed && huge.actions[1].done && huge.actions[1].failed, "大结果行：对上 id、认出失败")
        check(RoadmapBuilder.toolUseID(Data("{\"tool_use_id\":\"toolu_abc\",\"x\":1}".utf8)) == "toolu_abc", "从大行里取出 id")

        // 接着解析：只吃完整的行，半行留到下次
        let first = use("i1", "Read", ["file_path": "/p/A.swift"]) + "\n" + result("i1") + "\n" + use("i2", "Edit", ["file_path": "/p/B.swift"])
        var growing = RoadParse()
        let ate = RoadmapBuilder.feed(&growing, Data(first.utf8))
        check(ate == (use("i1", "Read", ["file_path": "/p/A.swift"]) + "\n" + result("i1") + "\n").utf8.count && growing.actions.count == 1 && growing.actions[0].done,
              "最后没写完的半行留着，先解析前面完整的")
        let rest = String(first.dropFirst(ate)) + "\n" + result("i2") + "\n"
        RoadmapBuilder.feed(&growing, Data(rest.utf8))
        check(growing.actions.count == 2 && growing.actions.allSatisfy { $0.done }, "补全之后接着解析：前面的动作还在，结果对得上")

        // 用 shell 写文件：算「写」，写目标文件名；只是把错误并进来、扔进 /dev/null 的不算写
        let written = parse([use("w1", "Bash", ["command": "cat > /p/notes.md <<'EOF'\nhello\nEOF"]), result("w1"),
                             use("w2", "Bash", ["command": "echo hi >> /p/log.txt"]), result("w2"),
                             use("w3", "Bash", ["command": "cat /p/a.swift 2>&1 | head"]), result("w3"),
                             use("w4", "Bash", ["command": "ls /p > /dev/null"]), result("w4")])
        check(written.actions.map(\.kind) == [.write, .write, .read, .read] && written.actions[0].object == "notes.md" && written.actions[1].object == "log.txt",
              "cat > 文件、echo >> 文件算写文件；2>&1、> /dev/null 不算")

        // 半行、没有工具的行、奇怪的输入
        check(parse(["{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\"", "随便什么"]).actions.isEmpty, "半行和乱行不崩")
    }

    @MainActor
    static func model(now: Date, check: (Bool, String) -> Void) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-road-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.jsonl").path
        let before = "前面一轮的内容\n"
        let turn = [use("a", "Read", ["file_path": "/p/A.swift"]), result("a"), use("b", "Edit", ["file_path": "/p/B.swift"])].joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: path, contents: Data((before + turn).utf8))
        let identity = AppModel.fileIdentity(path)
        func session(_ state: SessionState, id: String = "a", turn: String = "T1", ended: Date? = nil, agent: String = "claude") -> AgentSession {
            AgentSession(agent: agent, id: id, state: state, since: now, updated: now, first: now, title: "修登录", bundle: "", transcript: path,
                         turnID: turn, turnStart: before.utf8.count, turnInode: identity?.inode, turnAt: now.addingTimeInterval(-60), turnEndedAt: ended)
        }
        let model = AppModel()
        var queued: [() -> Void] = []
        model.roadRun = { queued.append($0) }
        model.sessions = [session(.running)]
        model.refreshRoadmaps()
        check(queued.isEmpty, "没要画时不读")
        model.roadWanted = "claude"
        model.refreshRoadmaps()
        check(queued.count == 1 && model.roadmap(agent: "claude", now: now)?.steps.map(\.title) == ["开始了"], "要画了才读；读完之前先画「开始了」的空路线（不空一下）")
        queued.removeFirst()()
        try? await Task.sleep(nanoseconds: 80_000_000)
        let road = model.roadmap(agent: "claude", now: now)
        check(road?.steps.map(\.title) == ["读", "改"] && road?.steps.last?.state == .current && road?.steps.last?.sub == "进行中 · B.swift" && road?.key == "claude-a",
              "读完：从这一轮开始的位置算起（前面一轮的不算），最后一步正在做")
        model.refreshRoadmaps()
        check(queued.isEmpty, "文件没变不再读")
        // 追加了新的动作：重读
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((result("b") + "\n" + use("c", "Bash", ["command": "./test.sh"]) + "\n" + result("c") + "\n").utf8))
            try? handle.close()
        }
        model.refreshRoadmaps()
        check(queued.count == 1, "记录追加了：重读")
        queued.removeFirst()()
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(model.roadmap(agent: "claude", now: now)?.steps.map(\.title) == ["读", "改", "跑测试"], "多了一步")
        let consumed = model.roadParses["claude-a"]?.parse.consumed ?? 0
        check(consumed == (turn + result("b") + "\n" + use("c", "Bash", ["command": "./test.sh"]) + "\n" + result("c") + "\n").utf8.count,
              "解析到哪里记着：下次只读后面追加的")

        // 新的一轮：旧的不拿来冒充
        model.sessions = [session(.running, turn: "T2")]
        check(model.roadmap(agent: "claude", now: now)?.steps.map(\.title) == ["开始了"] && model.roadmap(agent: "claude", now: now)?.turnID == "T2",
              "新的一轮还没读完：画「开始了」的空路线，不拿上一轮的冒充")
        model.refreshRoadmaps()
        check(queued.count == 1, "新的一轮：重新读")
        let stale = queued.removeFirst()
        model.sessions = [session(.running, turn: "T3")]
        stale()
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(model.roadmap(agent: "claude", now: now)?.steps.map(\.title) == ["开始了"], "迟到的旧一轮结果丢掉")

        // 卡在「在跑」的旧会话：不算
        var frozen = session(.running, id: "s")
        frozen.updated = now.addingTimeInterval(-4 * 3600)
        model.sessions = [frozen]
        check(model.roadSession(agent: "claude", now: now) == nil, "在跑但 3 小时没动静的旧会话：不画")

        // 挑哪个会话
        let done = session(.done, id: "d", ended: now.addingTimeInterval(-3))
        let longDone = session(.done, id: "e", ended: now.addingTimeInterval(-60))
        let waitingOne = session(.waiting, id: "w")
        let runningOne = session(.running, id: "r")
        model.sessions = [longDone, done]
        check(model.roadSession(agent: "claude", now: now)?.id == "d", "几个都做完了：留最近一次做完的")
        model.sessions = [longDone]
        check(model.roadSession(agent: "claude", now: now)?.id == "e", "做完一分钟了：还留着（不自己消失）")
        let ancient = session(.done, id: "o", ended: now.addingTimeInterval(-13 * 3600))
        model.sessions = [ancient]
        check(model.roadSession(agent: "claude", now: now) == nil, "放了半天以上的旧路线不再留")
        model.sessions = [runningOne, waitingOne, done]
        check(model.roadSession(agent: "claude", now: now)?.id == "w", "等你的优先")
        model.sessions = [runningOne, done]
        check(model.roadSession(agent: "claude", now: now)?.id == "r", "再是在跑的")
        model.sessions = [session(.running, id: "x", agent: "codex"), done]
        check(model.roadSession(agent: "codex", now: now)?.id == "x" && model.roadSession(agent: "claude", now: now)?.id == "d"
              && model.roadmaps(at: now)["codex"]?.key == "codex-x", "Claude、Codex 各挑各的")

        // 文件换了：读不了，显示开始了，不假装
        var moved = session(.running, id: "m")
        moved.turnInode = (identity?.inode ?? 0) + 1
        model.sessions = [moved]
        model.roadParses = [:]
        model.roadPending = [:]
        model.refreshRoadmaps()
        check(queued.isEmpty, "transcript 换了一个文件：不读")
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
        let road = Roadmap(key: "claude-a", turnID: "T1", steps: [RoadStep(title: "读 ×3", sub: "A.swift 等", state: .done),
                                                                   RoadStep(title: "改", sub: "进行中 · B.swift", state: .current, open: "claude-a")],
                           hidden: 0, finished: false, plan: false)
        var offset: TimeInterval = 0
        // 每次都往后拨 10 秒，免得撞上「刚弹出 2 秒内不再弹」
        func sync(_ roads: [String: Roadmap], ambient: Bool = true, calm: CalmState = .none) {
            offset += 10
            bar.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(offset), calm: calm, roads: roads, ambient: ambient)
        }
        let firstPresent = { () -> Bool in
            bar.frontAppChanged("com.apple.finder", promptApp: nil, autoShow: false)
            return true
        }
        _ = firstPresent()
        sync(["claude": road])
        check(presented == 0 && wanted.isEmpty, "前台不是 Claude：不摆，也不要数据")
        bar.frontAppChanged("com.anthropic.claudefordesktop", promptApp: "Claude", autoShow: false)
        check(wanted == ["claude"] && presented == 1, "Claude 到前台：要数据，已经有路线图就马上摆在左边空位")
        bar.visibleForTesting = true                          // 真机上摆出来之后展开条就是可见的
        sync(["claude": road])
        check(presented == 1 && bar.shown.map(\.id).first == "road:step:0", "数据刷新不重复摆")
        check(bar.shown.map(\.id) == ["road:step:0", "road:arrow:0", "road:step:1"] && bar.shown.allSatisfy { $0.image.size.height == TouchBarArt.height }, "一格一步、箭头连着")
        check(bar.shown.last?.label?.contains("第 2 步，正在做") == true && bar.shown.last?.label?.contains("点了打开这条对话") == true, "读屏说清第几步、什么状态、点了去哪")
        bar.closeTimerFiredForTesting()
        if case .road = bar.page {} else { check(false, "路线图摆着时不到时间收起") }
        var taps = 0
        bar.onOpenSession = { _ in taps += 1 }
        bar.tapForTesting(2)
        check(taps == 1, "点正在做的那步打开对话")
        bar.tapForTesting(0)
        check(taps == 1, "点做完的步不动")

        // 点小图标：展开成完整的；再点回路线图
        bar.tapGlanceForTesting()
        if case .overview = bar.page {} else { check(false, "路线图摆着时点小图标：展开成 AI 页") }
        bar.tapGlanceForTesting()
        if case .road = bar.page {} else { check(false, "再点回到路线图") }

        // 换成 Chrome：收起
        let closes = bar.closeRequestsForTesting
        bar.frontAppChanged("com.google.Chrome", promptApp: nil, autoShow: false)
        check(bar.closeRequestsForTesting == closes + 1 && wanted.last == .some(nil), "切到别的 app：收起，不再要数据")
        bar.detailHiddenForTesting()
        bar.visibleForTesting = false
        presented = 0
        sync(["claude": road])
        bar.frontAppChanged("com.anthropic.claudefordesktop", promptApp: "Claude", autoShow: false)
        check(presented == 1, "切回 Claude：又摆出来")

        // 点系统的 ×：这一轮不再弹；新的一轮再弹
        bar.visibleForTesting = true
        bar.detailHiddenForTesting()
        bar.visibleForTesting = false
        presented = 0
        sync(["claude": road])
        check(presented == 0, "你点了 × 关掉：这一轮不再弹")
        var next = road
        next.turnID = "T2"
        sync(["claude": next])
        check(presented == 1, "新的一轮：再弹")

        // 任务做完了、没有路线图了：收起
        bar.visibleForTesting = true
        let before = bar.closeRequestsForTesting
        sync([:])
        check(bar.closeRequestsForTesting == before + 1, "没有要画的了：收起")
        bar.detailHiddenForTesting()
        bar.visibleForTesting = false

        // 开关关掉、呼吸时、系统触控栏模式不允许：不摆
        presented = 0
        sync(["claude": road], ambient: false)
        check(presented == 0, "菜单栏里关掉了：不摆")
        sync(["claude": road], calm: .breath(started: now, rounds: 4))
        check(presented == 0, "呼吸时不摆")
        bar.presentationAllowed = { false }
        bar.frontAppChanged("com.anthropic.claudefordesktop", promptApp: "Claude", autoShow: false)
        sync(["claude": next])
        check(presented == 0, "系统把触控栏设成 F 键等：不摆")
        bar.ownAppFront("com.anthropic.AIQuota")
        bar.presentationAllowed = { true }
        sync(["claude": next])
        check(presented == 0, "AIQuota 自己的面板到前台：不重算系统模式，Claude 那边不允许就还是不摆")
        bar.frontAppChanged("com.anthropic.claudefordesktop", promptApp: "Claude", autoShow: false)

        // 点 × 关掉之后：对话页上多一格「路线」，点了再打开；没关的时候没有这一格
        let reopen = make0(rows: rows, presented: &presented)
        reopen.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(900), roads: ["claude": road])
        reopen.visibleForTesting = true
        check(!reopen.shown.contains { $0.id == "road" } || { if case .road = reopen.page { return true }; return false }(), "路线图摆着时 AI 页上没有「路线」小格")
        check(!reopen.shown.contains { $0.id == "road" } || { if case .road = reopen.page { return true }; return false }(), "AI 页上永远没有「路线」小格（位置固定）")
        reopen.detailHiddenForTesting()
        reopen.visibleForTesting = false
        reopen.tapGlanceForTesting()
        check(!reopen.shown.contains { $0.id == "road" } && reopen.shown.last?.id == "tools", "关掉这一轮之后：AI 页还是固定那几块，没有多出「路线」")
        reopen.open(.chats)
        check(reopen.shown.first?.id == "road", "关掉这一轮之后：对话页最前面多一格「路线」")
        let roadIndex = reopen.shown.firstIndex { $0.id == "road" } ?? 0
        let presentedBefore = presented
        reopen.visibleForTesting = true
        reopen.tapForTesting(roadIndex)
        if case .road = reopen.page {} else { check(false, "点「路线」：展开的条里换成路线图") }
        check(presented == presentedBefore, "已经是展开着的，不重复弹")
        reopen.closeTimerFiredForTesting()
        if case .road = reopen.page {} else { check(false, "打开的路线图不到时间收起") }
        reopen.tapGlanceForTesting()
        if case .overview = reopen.page {} else { check(false, "再点小图标：展开成 AI 页") }
        reopen.open(.chats)
        check(!reopen.shown.contains { $0.id == "road" }, "打开之后不再算关掉了：对话页上不再有「路线」小格")

        // 手指按着时不弹
        let touched = TouchBarItem()
        touched.presenter = { _ in presented += 1 }
        touched.presentationAllowed = { true }
        touched.pretendShownForTesting()
        touched.frontAppChanged("com.anthropic.claudefordesktop", promptApp: "Claude", autoShow: false)
        touched.update(rows: rows, lights: [], tasks: [], now: now, roads: ["claude": road])
        touched.beginInteractionForTesting()
        presented = 0
        touched.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(10), roads: ["claude": next])
        touched.endInteractionForTesting()
        check(presented <= 1, "摸着时不重复弹")
        edgeCases(now: now, rows: rows, check: check)
    }

    /// 路线图一屏放不下时可以左右划：刚摆出来停在最新的一步；手指没划走时新的一步出现还停在最右；划到前面看时位置不动
    @MainActor
    static func scrolling(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        let host = TouchBarItem()
        host.presenter = { _ in }
        host.presentationAllowed = { true }
        host.pretendShownForTesting()
        host.frontAppChanged("com.anthropic.claudefordesktop", promptApp: "Claude", autoShow: false)
        guard let view = host.detailViewForTesting else { check(false, "拿不到展开条的视图"); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        func steps(_ count: Int) -> [RoadStep] {
            (0..<count).map { index in
                RoadStep(title: index % 2 == 0 ? "读 ×3" : "改", sub: "文件名\(index).swift 等", state: index == count - 1 ? .current : .done,
                         open: index == count - 1 ? "claude-a" : nil)
            }
        }
        var offset: TimeInterval = 0
        func sync(_ count: Int) {
            offset += 10
            host.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(offset), roads: ["claude": Roadmap(key: "claude-a", turnID: "T", steps: steps(count), hidden: 0, finished: false, plan: false)])
            view.layoutSubtreeIfNeeded()
        }
        sync(3)
        host.visibleForTesting = true
        if case .road = host.page {} else { check(false, "路线图摆出来了"); return }
        check(host.pinnedToEndForTesting() && host.leadingIDForTesting() == "road:step:0", "三步放得下：不用划，从头到尾都在屏幕里")
        sync(30)
        let wide = host.shown.reduce(CGFloat(0)) { $0 + $1.image.size.width } + TouchBarItem.detailSpacing * CGFloat(host.shown.count - 1)
        check(host.shown.count == 59 && wide > TouchBarItem.detailWidth * 3, "三十步一屏放不下：整条都在（59 块，一步不折），比三屏还宽")
        check(host.pinnedToEndForTesting() && host.leadingIDForTesting() != "road:step:0" && host.shown.last?.id == "road:step:29", "长了以后停在最新的一步（最右）")
        sync(31)
        check(host.pinnedToEndForTesting() && host.shown.last?.id == "road:step:30", "停在最右时新来一步，还停在最新的一步")
        host.swipeForTesting(to: 0)
        try? await Task.sleep(nanoseconds: 600_000_000)
        check(host.leadingIDForTesting() == "road:step:0" && !host.pinnedToEndForTesting(), "划到最前面看")
        sync(32)
        check(host.leadingIDForTesting() == "road:step:0" && !host.pinnedToEndForTesting(), "划到前面看时新来一步：位置不动，不把你拉回最右")
        host.swipeForTesting(to: host.shown.count - 1)
        try? await Task.sleep(nanoseconds: 600_000_000)
        check(host.pinnedToEndForTesting(), "再划回最右")
        let before = host.leadingIDForTesting()
        sync(33)
        check(host.pinnedToEndForTesting() && host.leadingIDForTesting() != before && host.shown.last?.id == "road:step:32", "划回最右以后，新来的一步又跟着停在最右")
        host.swipeForTesting(to: 20)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let middle = host.leadingIDForTesting()
        sync(34)
        check(host.leadingIDForTesting() == middle && !host.pinnedToEndForTesting(), "划到中间看时新来一步：左边缘还是同一步")
    }

    @MainActor
    static func make0(rows: [Provider], presented: inout Int) -> TouchBarItem {
        let bar = TouchBarItem()
        bar.presenter = { _ in }
        bar.presentationAllowed = { true }
        bar.pretendShownForTesting()
        bar.frontAppChanged("com.anthropic.claudefordesktop", promptApp: "Claude", autoShow: false)
        return bar
    }

    /// 评审里确认过的几种时序
    @MainActor
    static func edgeCases(now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        var presented = 0
        var offset: TimeInterval = 0
        func make() -> TouchBarItem {
            let bar = TouchBarItem()
            bar.presenter = { _ in presented += 1 }
            bar.presentationAllowed = { true }
            bar.pretendShownForTesting()
            bar.frontAppChanged("com.anthropic.claudefordesktop", promptApp: "Claude", autoShow: false)
            return bar
        }
        func road(_ key: String, _ turn: String) -> Roadmap {
            Roadmap(key: key, turnID: turn, steps: [RoadStep(title: "读", sub: "A.swift", state: .done), RoadStep(title: "改", sub: "进行中 · B.swift", state: .current, open: key)],
                    hidden: 0, finished: false, plan: false)
        }
        func sync(_ bar: TouchBarItem, _ roads: [String: Roadmap]) {
            offset += 10
            bar.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(offset), roads: roads)
        }

        // 专注到点、翻译这些把路线图换掉以后：不是路线图了；到时间收起，不转成常驻指令条，收起后路线图回来
        let bar = make()
        sync(bar, ["claude": road("claude-a", "T1")])
        bar.visibleForTesting = true
        bar.showCalm()
        if case .calm = bar.page {} else { check(false, "路线图摆着时番茄钟到点：换成番茄钟页") }
        bar.closeTimerFiredForTesting()
        let closes = bar.closeRequestsForTesting
        check(closes >= 1, "到时间：收起（不转成常驻的指令条把路线图挡住）")
        if case .prompts = bar.page { check(false, "不转成指令条") }
        bar.detailHiddenForTesting()
        bar.visibleForTesting = false
        presented = 0
        sync(bar, ["claude": road("claude-a", "T1")])
        check(presented == 1, "收起后路线图回来（番茄钟页上没点 ×，不算关掉这一轮）")

        // 点路线图上的一步：只打开对话，条不收起
        bar.visibleForTesting = true
        var opened = 0
        bar.onOpenSession = { _ in opened += 1 }
        let before = bar.closeRequestsForTesting
        if let index = bar.shown.indices.last { bar.tapForTesting(index) }
        check(opened == 1 && bar.closeRequestsForTesting == before, "点路线图上的一步：打开对话，条不收起（不闪）")

        // 几个会话交替：A 被关、B 被关，B 做完回到 A，A 不再弹
        let two = make()
        sync(two, ["claude": road("claude-a", "T1")])
        two.visibleForTesting = true
        two.detailHiddenForTesting()
        two.visibleForTesting = false
        presented = 0
        sync(two, ["claude": road("claude-b", "T9")])
        check(presented == 1, "另一个会话的路线图照常弹")
        two.visibleForTesting = true
        two.detailHiddenForTesting()
        two.visibleForTesting = false
        presented = 0
        sync(two, ["claude": road("claude-a", "T1")])
        check(presented == 0, "A 之前被关过：B 做完回到 A，A 不再弹（记得住不止一个）")

        // 路线图没有了：条里保持原样（不闪出 AI 页），然后收起
        let gone = make()
        sync(gone, ["claude": road("claude-a", "T1")])
        gone.visibleForTesting = true
        let ids = gone.shown.map(\.id)
        let closesBefore = gone.closeRequestsForTesting
        sync(gone, [:])
        check(gone.shown.map(\.id) == ids && gone.closeRequestsForTesting == closesBefore + 1, "没有要画的了：先保持原样再收起，不闪出 AI 页的内容")

        // 从路线图展开的 AI 页，手动收起：放着歌的 Chrome 那首记下不再弹
        let lyricBar = make()
        sync(lyricBar, ["claude": road("claude-a", "T1")])
        lyricBar.visibleForTesting = true
        lyricBar.tapGlanceForTesting()
        if case .overview = lyricBar.page {} else { check(false, "展开成 AI 页") }
        lyricBar.frontAppChanged("com.google.Chrome", promptApp: nil, autoShow: false)
        let song = NowLyric(site: "bilibili", title: "晴天", line: "刮风这天", next: "", kind: "lyrics", playing: true, received: Date())
        lyricBar.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(500), lyric: song)
        lyricBar.tapGlanceForTesting()
        check(lyricBar.closeRequestsForTesting >= 1, "手动收起")
        lyricBar.detailHiddenForTesting()
        lyricBar.visibleForTesting = false
        presented = 0
        lyricBar.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(520), lyric: song)
        check(presented == 0 && !lyricBar.lyricAutoForTesting, "手动收起后这首歌词不会马上又弹出来")
    }
}
