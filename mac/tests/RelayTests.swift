import AppKit

enum RelayTests {
    final class Recorder {
        var urls: [URL] = []
        var bundles: [String] = []
        var commands: [RelayCommand] = []
    }

    static func entry(_ agent: String, _ id: String, _ light: Light, cwd: String, now: Date, minutesAgo: Double = 1, order: Double) -> TouchBarItem.TaskItem {
        let state: SessionState
        switch light {
        case .done: state = .done
        case .running: state = .running
        case .waiting: state = .waiting
        case .error: state = .error
        case .idle: state = .idle
        }
        let moment = now.addingTimeInterval(-minutesAgo * 60)
        return (AgentSession(agent: agent, id: id, state: state, since: moment, updated: moment, first: now.addingTimeInterval(order * 60 - 7200),
                             title: "任务 " + id, bundle: "", cwd: cwd), light)
    }

    @MainActor
    static func run(now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        let generalCount = NSPasteboard.general.changeCount
        let stamp = "20260927-2015"
        let project = "/Users/demo/projects/notes-app"
        let noteFile = "\(stamp)-codex-to-claude-notes-app.md"
        check(Relay.parse("\(stamp)-claude-to-codex-notes-app.md", modified: now)
              == HandoffNote(file: "\(stamp)-claude-to-codex-notes-app.md", from: "claude", to: "codex", project: "notes-app", modified: now),
              "按约定的文件名认出交接说明，项目名可以带连字符")
        check(Relay.parse("\(stamp)-claude-to-claude-x.md", modified: now) == nil && Relay.parse("notes.md", modified: now) == nil
              && Relay.parse("\(stamp)-claude-to-codex-x.txt", modified: now) == nil, "不合约定的文件不算")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-relay-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("done"), withIntermediateDirectories: true)
        for name in [noteFile, "done/\(stamp)-claude-to-codex-notes-app.md", "random.md", ".\(stamp)-claude-to-codex-hidden.md"] {
            try? Data("内容不该被读".utf8).write(to: folder.appendingPathComponent(name))
        }
        check(Relay.notes(in: folder).map(\.file) == [noteFile], "只看目录第一层合约定的文件，done/ 里的、隐藏的和别的文件都不算")
        check(Relay.notes(in: folder.appendingPathComponent("missing")).isEmpty, "目录不存在时就是没有")

        let claudeDone = entry("claude", "claude-a", .done, cwd: project, now: now, minutesAgo: 3, order: 0)
        let codexIdle = entry("codex", "00000000-0000-4000-8000-000000000201", .idle, cwd: project + "/", now: now, minutesAgo: 40, order: 1)
        let lonely = entry("codex", "lonely", .waiting, cwd: "/Users/demo/projects/other", now: now, order: 2)
        let turn = Relay.pairs(lights: [claudeDone, codexIdle, lonely], notes: [])
        check(turn.count == 1 && turn[0].cwd == project, "同一个项目（路径写法不同也算）里各有一个才配成一对")
        check(turn.first?.tone == .turn && turn.first?.next == "codex" && turn.first?.summary == "Claude 完成了 → 轮到 Codex" && turn.first?.short == "轮到 Codex",
              "Claude 刚完成、Codex 闲着：轮到 Codex")
        let codexRunning = entry("codex", "codex-run", .running, cwd: project, now: now, order: 1)
        let busy = Relay.pairs(lights: [claudeDone, codexRunning], notes: [])
        check(busy.first?.tone == .working && busy.first?.next == nil && busy.first?.summary == "Codex 在跑", "对方已经在跑就不催")
        let claudeRunning = entry("claude", "claude-run", .running, cwd: project, now: now, order: 0)
        let both = Relay.pairs(lights: [claudeRunning, codexRunning], notes: [])
        check(both.first?.summary == "Claude 在跑，Codex 在跑" && both.first?.short == "两边在忙", "两边都在跑")
        check(both.first?.targets == [] && busy.first?.targets == [], "在忙时不给交接按钮")
        let claudeIdle = entry("claude", "claude-idle", .idle, cwd: project, now: now, minutesAgo: 30, order: 0)
        let quiet = Relay.pairs(lights: [claudeIdle, codexIdle], notes: [])
        check(quiet.first?.tone == .quiet && quiet.first?.targets == ["codex", "claude"], "都停着时两个方向都能交")
        let newer = entry("claude", "claude-newer", .running, cwd: project, now: now, minutesAgo: 0, order: 3)
        check(Relay.pairs(lights: [claudeIdle, codexIdle, newer], notes: []).first?.claude.session.id == "claude-newer", "同一项目有几个 Claude 任务时取最近动过的")

        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-relay-roots-" + UUID().uuidString).path
        let repo = tree + "/work/repo"
        try? FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: repo + "/app/src", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: tree + "/plain/sub", withIntermediateDirectories: true)
        check(Relay.root(of: repo + "/app/src") == repo && Relay.root(of: tree + "/plain/sub") == tree + "/plain/sub", "往上找 git 仓库根目录，找不到就用原目录")
        let inRepo = Relay.pairs(lights: [entry("claude", "deep", .done, cwd: repo + "/app/src", now: now, order: 0),
                                          entry("codex", "top", .idle, cwd: repo, now: now, minutesAgo: 40, order: 1)], notes: [], home: tree + "/home")
        check(inRepo.first?.cwd == repo && inRepo.first?.project == "repo", "同一个 git 仓库里不同子目录的两个任务配成一对")
        let nested = Relay.pairs(lights: [entry("claude", "child", .done, cwd: tree + "/plain/sub", now: now, order: 0),
                                          entry("codex", "parent", .idle, cwd: tree + "/plain", now: now, minutesAgo: 40, order: 1)], notes: [], home: tree + "/home")
        check(nested.first?.cwd == tree + "/plain", "不是 git 仓库时，一个目录在另一个里面也算同一个项目")
        let homeLevel = Relay.pairs(lights: [entry("claude", "home", .done, cwd: tree + "/home", now: now, order: 0),
                                             entry("codex", "inside", .idle, cwd: tree + "/home/project", now: now, minutesAgo: 40, order: 1)], notes: [], home: tree + "/home")
        check(homeLevel.isEmpty, "开在家目录的任务不和别的配对")
        let byFolder = HandoffNote(file: "\(stamp)-codex-to-claude-src.md", from: "codex", to: "claude", project: "src", modified: now)
        let deepPairs = Relay.pairs(lights: [entry("claude", "deep", .idle, cwd: repo + "/app/src", now: now, minutesAgo: 30, order: 0),
                                             entry("codex", "top", .idle, cwd: repo, now: now, minutesAgo: 40, order: 1)], notes: [byFolder], home: tree + "/home")
        check(deepPairs.first?.note == byFolder, "交接说明写的是子文件夹名也认")
        let outside = HandoffNote(file: "\(stamp)-codex-to-claude-work.md", from: "codex", to: "claude", project: "work", modified: now)
        check(Relay.pairs(lights: [entry("claude", "deep", .idle, cwd: repo + "/app/src", now: now, minutesAgo: 30, order: 0),
                                   entry("codex", "top", .idle, cwd: repo, now: now, minutesAgo: 40, order: 1)], notes: [outside], home: tree + "/home").first?.note == nil,
              "项目根目录上面的文件夹名不算")
        try? FileManager.default.removeItem(atPath: tree)

        let fresh = HandoffNote(file: noteFile, from: "codex", to: "claude", project: "notes-app", modified: now)
        let noted = Relay.pairs(lights: [claudeIdle, codexIdle], notes: [fresh])
        check(noted.first?.next == "claude" && noted.first?.note == fresh && noted.first?.summary == "Codex 留了交接说明 → 轮到 Claude", "有新的交接说明就指给该接手的一方")
        let stale = HandoffNote(file: noteFile, from: "codex", to: "claude", project: "notes-app", modified: now.addingTimeInterval(-3600))
        check(Relay.pairs(lights: [claudeIdle, codexIdle], notes: [stale]).first?.note == nil, "接手方在交接说明之后动过，就当已经看过")
        let elsewhere = HandoffNote(file: "\(stamp)-codex-to-claude-other.md", from: "codex", to: "claude", project: "other", modified: now)
        check(Relay.pairs(lights: [claudeIdle, codexIdle], notes: [elsewhere]).first?.note == nil, "别的项目的交接说明不算")

        if let pair = turn.first {
            let toCodex = Relay.sentence(for: pair, to: "codex", now: now)
            check(toCodex.contains(project) && toCodex.contains("git diff") && toCodex.contains("~/.ai-handoff/" + Relay.stamp(now) + "-codex-to-claude-notes-app.md"),
                  "交给 Codex 的话写明项目、审查未提交的改动、意见写到约定的位置")
        }
        if let pair = noted.first {
            check(Relay.sentence(for: pair, to: "claude", now: now) == "请读交接说明 ~/.ai-handoff/\(noteFile)，按里面的要求继续；开始处理后把它移到 ~/.ai-handoff/done/。",
                  "有交接说明时让对方去读那个文件")
        }

        let reset = now.addingTimeInterval(2 * 3600)
        let spent = Provider(name: "Codex", windows: [QuotaWindow(label: "5小时", short: "", used: 100, resetsAt: reset)], updatedAt: now)
        check(Relay.availability(spent, now: now) == .exhausted(reset) && Relay.availability(rows.first, now: now) == .ready
              && Relay.availability(nil, now: now) == .ready, "额度用完才拦，并带上恢复时间")

        let units = TouchBarArt.glanceUnits(lights: [.done, .idle, .waiting], pairs: [.init(first: 0, second: 1, tone: .turn)], slots: 6)
        check(units == [[0, 1], [2]], "小图标里一对任务画成两点一线，位置按先后")
        let tight = TouchBarArt.glanceUnits(lights: [.waiting, .waiting, .done, .idle], pairs: [.init(first: 2, second: 3, tone: .turn)], slots: 3)
        check(tight == [[0], [1], [2]], "放不下一整对时先留紧急的单点")
        let plainGlance = TouchBarArt.glance(rows: rows, lights: [.done, .idle], now: now)
        let pairedGlance = TouchBarArt.glance(rows: rows, lights: [.done, .idle], now: now, pairs: [.init(first: 0, second: 1, tone: .turn)])
        check(plainGlance.size == pairedGlance.size && plainGlance.tiffRepresentation != pairedGlance.tiffRepresentation, "连线不改变小图标大小")

        let recorder = Recorder()
        let bar = TouchBarItem()
        bar.onRelay = { recorder.commands.append($0) }
        let lights = [claudeDone, codexIdle, lonely]
        bar.update(rows: rows, lights: lights, tasks: lights, now: now, relays: turn)
        check(!bar.shown.contains { $0.id == "relay" }, "接力卡不在 AI 页上")
        check(bar.shown.first(where: { $0.id == "chats" })?.label?.contains("接力轮到你了") == true, "轮到你接手时，AI 页的「对话」入口写「接力」")
        bar.open(.chats)
        check(bar.shown.first?.id == "relay", "接力卡在对话页最前面")
        bar.tapForTesting(0)
        check(bar.shown.map(\.id) == ["relay:" + project, "relay:" + project + ":to-codex"], "接力页：状态和该交给谁")
        bar.tapForTesting(1)
        check(recorder.commands == [.hand(project, "codex")], "点「交给 Codex」只发出交接命令")
        var tiredRows = rows
        if tiredRows.count > 1 { tiredRows[1] = spent }
        let tiredBar = TouchBarItem()
        tiredBar.onRelay = { recorder.commands.append($0) }
        tiredBar.update(rows: tiredRows, lights: lights, tasks: lights, now: now, relays: turn)
        tiredBar.open(.chats)
        tiredBar.tapForTesting(0)
        let tiredButton = tiredBar.shown.firstIndex { $0.id == "relay:" + project + ":to-codex" } ?? 0
        tiredBar.tapForTesting(tiredButton)
        check(recorder.commands.count == 1 && tiredBar.shown[tiredButton].image.size == bar.shown[1].image.size, "对方额度用完时按钮变灰、点了没反应，大小不变")

        let held = TouchBarItem()
        held.onRelay = { recorder.commands.append($0) }
        held.update(rows: rows, lights: lights, tasks: lights, now: now, relays: turn)
        held.open(.chats)
        held.tapForTesting(0)
        held.beginInteractionForTesting()
        let otherProject = "/Users/demo/projects/aaa"
        let extra = [entry("claude", "aaa-claude", .done, cwd: otherProject, now: now, order: -2), entry("codex", "aaa-codex", .idle, cwd: otherProject, now: now, order: -1)]
        let grown = Relay.pairs(lights: extra + lights, notes: [])
        held.update(rows: rows, lights: extra + lights, tasks: extra + lights, now: now, relays: grown)
        check(held.shown.first?.id == "relay:" + project, "手指按着时不换接力页")
        held.tapForTesting(1)
        held.endInteractionForTesting()
        check(recorder.commands.last == .hand(project, "codex"), "按着时前面插进一对，点的仍是手指下面那个按钮")

        let board = NSPasteboard(name: NSPasteboard.Name("local.aiquota.tests." + UUID().uuidString))
        let model = AppModel()
        model.pasteboard = board
        model.handoffFolder = folder
        model.openURL = { url in recorder.urls.append(url); return true }
        model.launchApp = { bundle, done in recorder.bundles.append(bundle); done(.opened) }
        model.sessions = [claudeDone.session, codexIdle.session]
        model.reloadHandoffs()
        check(model.handoffs.map(\.file) == [noteFile], "模型读到约定目录里的交接说明")
        board.clearContents()
        board.setString("用户原来的内容", forType: .string)
        model.relayCommand(.hand(project, "codex"))
        let copied = board.string(forType: .string) ?? ""
        check(copied.contains(project) && copied.contains("git diff"), "交给 Codex：把交接的话放进剪贴板")
        check(recorder.urls.map(\.absoluteString) == ["codex://threads/00000000-0000-4000-8000-000000000201"], "切到 Codex 的那条对话，不发送任何东西")
        check(model.actionMessage.contains("⌘V") && model.sessions.map(\.state) == [.done, .idle], "提示你自己按 ⌘V 回车，不改任务状态")
        model.codex = [spent]
        board.setString("用户原来的内容", forType: .string)
        let before = board.changeCount
        model.relayCommand(.hand(project, "codex"))
        check(board.changeCount == before && model.actionMessage.contains("额度用完了"), "对方额度用完时不碰剪贴板、不切换，说明几点恢复")
        model.relayCommand(.hand("/Users/demo/projects/none", "codex"))
        check(board.changeCount == before && recorder.urls.count == 1, "不存在的一对什么都不做")
        model.relayCommand(.note(noteFile))
        check(recorder.urls.last == folder.appendingPathComponent(noteFile), "看交接说明打开约定目录里的那个文件")
        model.relayCommand(.note("../../etc/hosts"))
        check(recorder.urls.count == 2, "只打开目录里认得出的交接说明")
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
        check(NSPasteboard.general.changeCount == generalCount, "接力测试没有写过用户真实的剪贴板")
    }
}
