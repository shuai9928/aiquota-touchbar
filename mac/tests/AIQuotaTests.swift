import AppKit

@main
struct AIQuotaTests {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        // 预览图：只用合成数据画，不启动 app、不读真实的会话和配置
        if let index = CommandLine.arguments.firstIndex(of: "--previews"), index + 1 < CommandLine.arguments.count {
            WatchTests.writePreviews(dir: CommandLine.arguments[index + 1])
            return
        }
        // 拿一份真实的对话记录看看路线图认成什么样（手动核对用）：--road 记录 [--codex] [--from 字节] [--png 输出]
        if let index = CommandLine.arguments.firstIndex(of: "--road"), index + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            CodexRoadTests.inspect(path: args[index + 1], codex: args.contains("--codex"), from: value("--from").flatMap(Int.init) ?? 0, png: value("--png"))
            return
        }
        // 测试里永远不真的跑 two-machine / tailscale：换成假的，只记下被要求跑了什么
        final class Ran: @unchecked Sendable { var calls: [(path: String, args: [String])] = [] }
        let ran = Ran()
        let statusJSON = """
        {"BackendState":"Running","Self":{"HostName":"mac","KeyExpiry":"2026-10-03T00:00:00Z"},
         "Peer":{"nodekey:a":{"HostName":"other-box","DNSName":"other-box.tail.ts.net.","Online":true,"CurAddr":"1.2.3.4:41641","RxBytes":9,"TxBytes":9},
                 "nodekey:b":{"HostName":"win-wsl","DNSName":"win-wsl.tail.ts.net.","Online":true,"CurAddr":"","Relay":"tok","LastSeen":"0001-01-01T00:00:00Z","RxBytes":1000,"TxBytes":24}}}
        """
        TwoMachine.runner = { path, args, _, _ in
            ran.calls.append((path, args))
            switch args {
            case ["status", "--json"]: return .init(status: 0, out: statusJSON, err: "")
            case ["status"]: return .init(status: 1, out: "Mac → Windows/WSL：正常\n",
                                          err: "Windows/WSL → Mac 失败。检查 Mac 远程登录、Tailscale 账号以及 WSL 的 SSH 密钥。\n")
            case ["on"]: return .init(status: 1, out: "", err: "Tailscale 连接失败；若已退出账号，请在 Mac 的 Tailscale 应用中重新登录。\n")
            default: return .init(status: 0, out: "", err: "")
            }
        }
        let now = Date()
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: " + label) }
            checks += 1
        }
        let base: [String: Any] = ["agent": "claude", "id": "legacy", "state": "waiting", "updated": now.timeIntervalSince1970]
        let old = SessionFiles.session(base)!
        check(old.cwd.isEmpty && old.waitReason.isEmpty, "旧状态文件兼容")
        check(old.waitingLabel == "等你处理", "未知等待原因不编造")
        var record = base
        record["cwd"] = FileManager.default.currentDirectoryPath
        record["waitReason"] = "permission"
        let enriched = SessionFiles.session(record)!
        check(enriched.waitingLabel == "等你批准" && !enriched.cwd.isEmpty, "项目目录和批准原因")
        let uuid = "01a0dfda-7e83-7e10-89b2-5c3a3c0067cb"
        check(SessionHook.codexThreadId("/tmp/rollout-2026-09-26T18-00-00-\(uuid).jsonl") == uuid, "Codex rollout线程ID")
        check(SessionHook.codexThreadId("/tmp/rollout-2026-09-26T18-00-00-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.jsonl") == nil, "拒绝无效线程ID")
        // Claude 周重置推算：没填配置时，本周用量（sd）只在窗口边界整段掉下来，最近一次大掉落的中点 + 7 天
        func claudeWeek(_ points: [(ago: Double, fh: Double, sd: Double)], spec: String = "") -> Provider {
            let now2 = Date()
            let samples: [[String: Any]] = points.map {
                ["t": now2.addingTimeInterval(-$0.ago * 86400).timeIntervalSince1970 * 1000,
                 "u": ["fh": $0.fh, "sd": $0.sd]] as [String: Any]
            }
            let path = NSTemporaryDirectory() + "aiquota-claude-\(UUID().uuidString).json"
            try? JSONSerialization.data(withJSONObject: ["samples": samples]).write(to: URL(fileURLWithPath: path))
            defer { try? FileManager.default.removeItem(atPath: path) }
            return ClaudeHistory.load(path: path, weeklySpec: spec, now: now2)
        }
        func closeTo(_ a: Date?, _ b: Date) -> Bool { a.map { abs($0.timeIntervalSince(b)) < 120 } ?? false }
        let inferred = claudeWeek([(8, 90, 100), (1.05, 80, 96), (1.0, 10, 2)])
        check(closeTo(inferred.windows[1].resetsAt, Date().addingTimeInterval((7 - 1.025) * 86400)) && inferred.windows[1].approx,
              "周重置推算：掉落区间中点+7天、标约")
        let stale = claudeWeek([(10, 90, 100), (9.98, 0, 0), (1, 30, 40)])
        check(stale.windows[1].resetsAt == nil && stale.windows[1].note == "未设置重置时间", "周重置推算：这周的边界没观察到就不猜")
        check(claudeWeek([(12, 90, 100), (8, 0, 0)]).windows[1].resetsAt == nil, "周重置推算：掉落区间比48小时宽不定")
        let wide = claudeWeek([(9, 90, 100), (7, 5, 4), (6.9, 20, 10)])
        check(wide.windows[1].resetsAt != nil && wide.windows[1].approx, "周重置推算：两天内宽的区间也认")
        check(claudeWeek([(3, 50, 60), (2.9, 40, 45)]).windows[1].resetsAt == nil, "周重置推算：一周内的小回落不当边界")
        let manual = claudeWeek([(8, 90, 100), (1.05, 80, 96), (1.0, 10, 2)], spec: "周五 11:00")
        check(manual.windows[1].approx == false
              && manual.windows[1].resetsAt.map { Calendar.current.component(.weekday, from: $0) } == 6,
              "周重置：配置里填的优先、不标约")
        let model = AppModel()
        func session(_ state: SessionState, _ id: String, ago: Double = 0) -> AgentSession {
            AgentSession(agent: "claude", id: id, state: state,
                         since: now.addingTimeInterval(-ago), updated: now.addingTimeInterval(-ago),
                         first: now, title: "任务 " + id, bundle: "local.aiquota.tests.missing-app",
                         cwd: FileManager.default.currentDirectoryPath)
        }
        model.sessions = [session(.running, "run"), session(.done, "done"), session(.error, "error"), session(.waiting, "wait")]
        check(model.tasks(at: now).map { $0.session.id } == ["wait", "error", "done", "run"], "任务按紧急程度排序")
        model.open("claude-wait")
        check(model.tasks(at: now).first { $0.session.id == "wait" }?.light == .waiting, "打开失败不清除橙灯")
        model.open("claude-done")
        check(model.tasks(at: now).first { $0.session.id == "done" }?.light == .done, "打开失败不确认绿灯")
        // 绿灯只算醒着的时间：任务一小时前做完、中间睡了 48 分钟，绿灯还亮着；不记睡着就早该灭了
        check(AppModel.awakeInterval(since: now.addingTimeInterval(-7200), until: now,
                                     asleep: [(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800))]) == 5400,
              "醒着时间=墙钟减睡着")
        check(AppModel.awakeInterval(since: now.addingTimeInterval(-7200), until: now, asleep: []) == 7200, "没睡过=墙钟")
        check(AppModel.awakeInterval(since: now.addingTimeInterval(-1800), until: now,
                                     asleep: [(start: now.addingTimeInterval(-1700), end: now.addingTimeInterval(-100))]) == 200,
              "睡着段裁进区间里")
        var doneSlept = session(.done, "slept-done", ago: 0)
        doneSlept.since = now.addingTimeInterval(-3600)
        model.sessions = [doneSlept]
        model.asleepSpans = [(start: now.addingTimeInterval(-3500), end: now.addingTimeInterval(-600))]
        check(model.light(for: doneSlept, now: now) == .done, "睡着的时间不算绿灯的20分钟")
        model.asleepSpans = []
        check(model.light(for: doneSlept, now: now) == .idle, "墙钟算绿灯一小时后已转空闲")
        model.didSleep(now: now.addingTimeInterval(-120))
        model.closeAsleepSpan(at: now)
        check(model.asleepSpans.last.map { $0 == (start: now.addingTimeInterval(-120), end: now) } == true, "睡着/醒来记满一段")
        model.asleepSpans = []
        model.sessions = [session(.done, "old", ago: 7200)]
        check(model.lights(at: now).isEmpty, "过期任务不亮灯")
        check(model.tasks(at: now).count == 1 && model.tasks(at: now)[0].light == .idle, "过期任务仍可打开最近项目")
        let rows = Snapshot.demoRows(now: now)
        for count in [0, 1, 2, 3, 4, 8, 20] {
            model.sessions = (0..<count).map { session($0 % 2 == 0 ? .waiting : .running, String($0)) }
            let tasks = model.tasks(at: now)
            // AI 页固定一屏、不用划：不管多少任务，各块加块间距正好 610pt；全部任务在对话页里（可以划，每块放得进一屏）
            let chip = TouchBarItem.linkChip(Snapshot.demoLink(now: now, on: true), now: now)
            let parts = TouchBarItem.aiPage(rows: rows, tasks: tasks, lights: [], relays: [], watched: [], now: now, link: chip, pet: TouchBarItem.relaxChip)
            let span = parts.reduce(CGFloat(0)) { $0 + $1.image.size.width } + CGFloat(parts.count - 1) * TouchBarItem.detailSpacing
            check(span == TouchBarItem.detailWidth, "\(count)个任务：AI 页正好一屏（\(span)）")
            check(parts.map(\.id).first == "quota" && parts.map(\.id).suffix(4) == ["chats", "link", "relax", "tools"], "\(count)个任务：额度表在最前，后面四个入口位置固定")
            check(parts.filter { $0.id.hasPrefix("task:") }.count == min(2, count), "\(count)个任务：第一页最多两张对话卡")
            let everything = TouchBarItem.chatsImages(tasks: tasks, lights: [], relays: [], watched: [], now: now, reopen: nil)
            check(everything.allSatisfy { $0.image.size.width <= TouchBarItem.detailWidth }, "\(count)个任务：对话页每块都放得进一屏")
            check(everything.count == max(1, count), "\(count)个任务：对话页是全部任务")
            if count > 0, case .select = everything[0].action {} else if count > 0 { check(false, "任务卡片点了进操作页") }
        }
        let playing = NowLyric(site: "bilibili", title: "晴天 · 周杰伦", line: "刮风这天 我试过握着你手", next: "但偏偏", kind: "lyrics", playing: true, received: now)
        let lyricPage = TouchBarItem.lyricImages(playing)
        check(lyricPage.reduce(CGFloat(0)) { $0 + $1.image.size.width } + CGFloat(lyricPage.count - 1) * TouchBarItem.detailSpacing <= TouchBarItem.detailWidth, "歌词页一屏放得下")
        let lyricWidth = TouchBarItem.detailWidth - TouchBarItem.backWidth - TouchBarItem.detailSpacing - 24
        check(TouchBarArt.lyricFont("刮风这天 我试过握着你手", width: lyricWidth).pointSize == TouchBarArt.lyricLargest, "一句歌词用最大的字（20 号）")
        check(TouchBarArt.lyricFont(String(repeating: "and the most important thing ", count: 6), width: lyricWidth).pointSize == TouchBarArt.lyricSmallest,
              "太长的一句缩到最小 13 号为止")
        check(TouchBarItem.lyricCard(playing, now: now).map { if case .lyrics = $0.action { return true }; return false } == true, "在放歌时小猫的家里有歌词卡")
        check(TouchBarItem.lyricCard(nil, now: now) == nil && TouchBarItem.lyricCard(playing, now: now.addingTimeInterval(9)) == nil, "没在放：没有歌词卡")
        check(!TouchBarItem.aiPage(rows: rows, tasks: [], lights: [], relays: [], watched: [], now: now, link: nil, pet: TouchBarItem.relaxChip).contains { $0.id == "lyrics" }, "歌词卡不占 AI 页")
        check(playing.active(at: now) && !playing.active(at: now.addingTimeInterval(9)), "8 秒没收到更新就不算在放")
        model.receiveLyric(["type": "lyric", "site": "youtube", "title": "T", "line": String(repeating: "长", count: 500), "next": "", "kind": "subtitle", "playing": true])
        check(model.lyric?.line.count == 300 && model.lyric?.playing == true, "收到的歌词截到 300 字")
        model.receiveLyric(["type": "none"])
        check(model.lyric == nil, "扩展说没词了就清掉")
        let item = (session: session(.waiting, "detail"), light: Light.waiting)
        let project = TouchBarItem.projectImages(item: item, now: now)
        check(project.reduce(CGFloat(0)) { $0 + $1.image.size.width } + CGFloat(project.count - 1) * TouchBarItem.detailSpacing <= 610, "项目操作页宽度")
        let missing = (session: AgentSession(agent: "claude", id: "no-path", state: .idle, since: now, updated: now, first: now, title: "", bundle: ""), light: Light.idle)
        let disabled = TouchBarItem.projectImages(item: missing, now: now).filter { part in
            if case .none = part.action { return true }; return false
        }
        check(disabled.count == 2, "无目录时禁止文件夹/终端但仍允许复制交接")
        let text = await ProjectActions.handoff(projectPath: "", title: "任务\n伪造字段", agentName: "Claude", sessionID: "fixture", state: "等你回答")
        check(text.contains("任务\\n伪造字段") && text.contains("源会话状态：等你回答") && text.contains("未提供"), "交接信息保留状态、转义多行并说明缺失路径")
        // 仓库自己的 .git/config 里定义的 filter 不能在复制交接时被执行
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-filter-\(UUID().uuidString)")
        let marker = repo.appendingPathComponent("FILTER-RAN").path
        func git(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.currentDirectoryURL = repo
            p.arguments = ["-c", "user.email=t@t", "-c", "user.name=t"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["init", "-q", "."])
        try? "a\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try? "* filter=evil\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        git(["add", "-A"])
        git(["commit", "-q", "-m", "init"])
        git(["config", "filter.evil.clean", "touch '\(marker)'; cat"])
        git(["config", "filter.evil.process", "touch '\(marker)'; false"])
        git(["config", "filter.evil.required", "true"])
        try? "b\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let handoff = await ProjectActions.handoff(projectPath: repo.path, title: "filter", agentName: "Claude", sessionID: "t", state: "运行中")
        check(!FileManager.default.fileExists(atPath: marker), "复制交接不执行仓库配置里的 filter")
        check(handoff.contains("f.txt") && handoff.contains("[·M]"), "关掉 filter 后仍能列出已修改文件")
        try? FileManager.default.removeItem(at: repo)

        // 展开那一条：全部账号都在；手指按住时数据不换，点按按按下时的那一排找（两种回调顺序都对）
        let fiveRows = (0..<5).map { Provider(name: "P\($0)", windows: [QuotaWindow(label: "5小时", short: "5h", used: 20)], updatedAt: now) }
        func taskItem(_ id: String) -> TouchBarItem.TaskItem {
            (AgentSession(agent: "claude", id: id, state: .running, since: now, updated: now, first: now, title: id, bundle: ""), .running)
        }
        let fifty = (0..<50).map { taskItem("k\($0)") }
        // 对话页按「轻重、最近更新、名字」排：要让一排任务的顺序整个倒过来，就把它们的更新时间倒着给
        func reversedOrder(_ items: [TouchBarItem.TaskItem]) -> [TouchBarItem.TaskItem] {
            items.enumerated().map { index, item in
                var session = item.session
                session.updated = now.addingTimeInterval(Double(index) - 10)
                return (session, item.light)
            }
        }
        let all = TouchBarItem.chatsImages(tasks: fifty, lights: [], relays: [], watched: [], now: now, reopen: nil)
        check(all.count == 50 && Set(all.map(\.id)).count == 50, "对话页：50 个任务都在，而且 id 不重复")
        let quotaPage = TouchBarItem.quotaImages(rows: fiveRows, usage: nil, now: now)
        check(quotaPage.count == 5 && Set(quotaPage.map(\.id)).count == 5, "额度页：5 个账号都在，而且 id 不重复")
        func isTask(_ page: TouchBarItem.Page, _ key: String) -> Bool { if case .task(let k) = page { return k == key }; return false }
        for finishFirst in [true, false] {
            let bar = TouchBarItem()
            let five = Array(fifty.prefix(5))
            bar.update(rows: rows, lights: five, tasks: five, now: now); bar.open(.chats)
            let before = bar.shown.map(\.id)
            let oldIndex = before.firstIndex(of: "task:claude-k2")!
            bar.beginInteractionForTesting()
            bar.update(rows: rows, lights: reversedOrder(five), tasks: reversedOrder(five), now: now)
            check(bar.shown.map(\.id) == before, "手指按住时不换数据（finishFirst=\(finishFirst)）")
            if finishFirst { bar.endInteractionForTesting(); bar.tapForTesting(oldIndex) }
            else { bar.tapForTesting(oldIndex); bar.endInteractionForTesting() }
            check(isTask(bar.page, "claude-k2"), "按下时那一排的第 \(oldIndex) 块还是原来的任务（finishFirst=\(finishFirst)）")
            try? await Task.sleep(nanoseconds: 500_000_000)
            check(bar.shown.first?.id == "title:claude-k2", "松手后进了那个任务的操作页（finishFirst=\(finishFirst)）")
        }
        // 连续两次交互在 0.3 秒内先后松手：第一次松手排的回调不能替第二次清快照、换数据（晚到的点按还要按第二次按下时的那一排找）
        do {
            let five = Array(fifty.prefix(5))
            // 1) 确定性：直接让第一次的旧回调在第二次松手后跑
            let bar = TouchBarItem()
            bar.update(rows: rows, lights: five, tasks: five, now: now); bar.open(.chats)
            let before = bar.shown.map(\.id)
            let oldIndex = before.firstIndex(of: "task:claude-k2")!
            bar.beginInteractionForTesting(); bar.endInteractionForTesting()
            let first = bar.touchGenerationForTesting
            bar.beginInteractionForTesting()
            bar.update(rows: rows, lights: reversedOrder(five), tasks: reversedOrder(five), now: now)
            bar.endInteractionForTesting()
            let second = bar.touchGenerationForTesting
            check(second == first + 1, "每次按下代次加一")
            bar.settleForTesting(generation: first)
            check(bar.settlingForTesting && bar.hasTouchSnapshotForTesting && bar.shown.map(\.id) == before, "旧代次的回调什么都不动")
            bar.tapForTesting(oldIndex)
            check(isTask(bar.page, "claude-k2"), "晚到的点按仍按第二次按下时的那一排找")
            // 2) 真实计时（把 0.3 秒调成 1 秒，留足余量）：A 松手 → 0.5 秒后 B 按下、来新数据、松手 → 第 1.2 秒（A 的回调时刻已过、B 的还没到）
            let saved = TouchBarItem.settleDelay
            TouchBarItem.settleDelay = 1.0
            let timed = TouchBarItem()
            timed.update(rows: rows, lights: five, tasks: five, now: now); timed.open(.chats)
            let timedBefore = timed.shown.map(\.id)
            timed.beginInteractionForTesting(); timed.endInteractionForTesting()
            try? await Task.sleep(nanoseconds: 500_000_000)
            timed.beginInteractionForTesting()
            timed.update(rows: rows, lights: reversedOrder(five), tasks: reversedOrder(five), now: now)
            timed.endInteractionForTesting()
            try? await Task.sleep(nanoseconds: 700_000_000)
            check(timed.settlingForTesting && timed.hasTouchSnapshotForTesting && timed.shown.map(\.id) == timedBefore,
                  "真实计时：第一次松手的回调到点了也不提前换数据")
            timed.tapForTesting(oldIndex)
            check(isTask(timed.page, "claude-k2"), "真实计时：晚到的点按点对")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            check(!timed.settlingForTesting && !timed.hasTouchSnapshotForTesting, "第二次松手的回调到点后正常收尾")
            // 3) 第二次还按着时，第一次的回调到点也不动
            let held = TouchBarItem()
            held.update(rows: rows, lights: five, tasks: five, now: now); held.open(.chats)
            let heldBefore = held.shown.map(\.id)
            held.beginInteractionForTesting(); held.endInteractionForTesting()
            try? await Task.sleep(nanoseconds: 300_000_000)
            held.beginInteractionForTesting()
            held.update(rows: rows, lights: reversedOrder(five), tasks: reversedOrder(five), now: now)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            check(held.hasTouchSnapshotForTesting && held.shown.map(\.id) == heldBefore, "按着不放时旧回调到点也不换数据")
            held.endInteractionForTesting()
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            check(held.shown.map(\.id) != heldBefore && !held.hasTouchSnapshotForTesting, "松手 1 秒后攒下的新数据换上")
            TouchBarItem.settleDelay = saved
        }

        // 放进离屏窗口让 NSScrubber 真的排版：对话页里 50 个任务每块都滚得到、整块看得见；纯滑动后刷新 / 进任务页再返回，左边缘还是同一块
        do {
            let host = TouchBarItem()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
            if let view = host.detailViewForTesting {
                window.contentView = view
                host.update(rows: fiveRows, lights: fifty, tasks: fifty, now: now)
                view.layoutSubtreeIfNeeded()
                // AI 页固定一屏：不管多少账号和任务，不出现要划的内容
                check(host.shown.map(\.id).prefix(1) == ["quota"] && host.shown.indices.allSatisfy { host.fullyVisibleForTesting($0) }, "AI 页固定一屏，每块都整块看得见")
                host.open(.chats)
                view.layoutSubtreeIfNeeded()
                check(host.shown.count == 50 && fifty.allSatisfy { item in host.shown.contains { $0.id == "task:" + item.session.key } },
                      "对话页里 50 个任务都在（没截断）")
                check(host.shown.indices.allSatisfy { host.fullyVisibleForTesting($0) }, "50 块每一块都能滚到、整块看得见")
                host.swipeForTesting(to: 20)
                let anchorID = host.shown[20].id
                check(host.leadingIDForTesting() == anchorID, "纯滑动后左边缘是第 20 块")
                // 松手后 0.3 秒内来了新数据：前面多了一个任务、后面少了一个
                let changed = [taskItem("new")] + fifty.dropLast()
                host.update(rows: fiveRows, lights: changed, tasks: changed, now: now)
                check(host.shown.count == 50 && host.shown[20].id == anchorID, "还在收尾时不换数据")
                try? await Task.sleep(nanoseconds: 600_000_000)
                check(host.shown.map(\.id).contains("task:claude-new") && host.leadingIDForTesting() == anchorID,
                      "纯滑动后刷新（前面插进一块）左边缘还是同一块")
                // 纯滑动后刷新时锚点那块没了：对到原来排在它后面的那块
                host.swipeForTesting(to: 30)
                let gone = host.shown[30].id, next = host.shown[31].id
                try? await Task.sleep(nanoseconds: 600_000_000)
                let without = changed.filter { "task:" + $0.session.key != gone }
                host.update(rows: fiveRows, lights: without, tasks: without, now: now)
                check(!host.shown.map(\.id).contains(gone) && host.leadingIDForTesting() == next, "锚点那块没了就对到它后面那块")
                // 进任务页再返回对话页：回到离开时的位置
                host.swipeForTesting(to: 12)
                let backID = host.shown[12].id
                try? await Task.sleep(nanoseconds: 600_000_000)
                host.tapForTesting(host.shown.firstIndex { $0.id == backID }!)
                check(host.leadingIDForTesting() != backID, "进了任务页")
                host.backForTesting()
                check(host.leadingIDForTesting() == backID, "从任务页返回对话页回到原来的位置")
                if case .chats = host.page {} else { check(false, "对话页里进的任务页，返回回到对话页（不是 AI 页）") }
            } else {
                check(false, "拿不到展开条的视图")
            }
        }

        // 浏览锚点：左边缘过半露出的第一块；它没了就找后面还在的
        let frames = [NSRect(x: 0, y: 0, width: 186, height: 30), NSRect(x: 192, y: 0, width: 142, height: 30), NSRect(x: 340, y: 0, width: 142, height: 30)]
        check(TouchBarItem.leadingID(ids: ["a", "b", "c"], frames: frames, visible: NSRect(x: 200, y: 0, width: 400, height: 30)) == "b", "左边缘切到一块时，过半露出的算锚点")
        check(TouchBarItem.leadingID(ids: ["a", "b", "c"], frames: frames, visible: NSRect(x: 280, y: 0, width: 400, height: 30)) == "c", "露出不到一半的跳过")
        check(TouchBarItem.anchorIndex(id: "b", oldIDs: ["a", "b", "c"], ids: ["c", "a", "b"]) == 2, "锚点按 id 找新位置")
        check(TouchBarItem.anchorIndex(id: "b", oldIDs: ["a", "b", "c"], ids: ["c", "a"]) == 0, "锚点没了找原来后面那块")

        // ---------------- 双机灯 ----------------
        check(Fmt.short(30) == "不到1分" && Fmt.short(720) == "12分" && Fmt.short(4800) == "1时20分" && Fmt.short(183600) == "2天3时", "时长简写")
        let det = TwoMachine.parseDetail(Data(statusJSON.utf8), pcHost: "win-wsl")
        check(det?.running == true && det?.pcOnline == true && det?.direct == false && det?.relay == "tok", "按主机名找到 PC 节点，CurAddr 空 = 经中转")
        check(det?.traffic == 1024 && det?.pcLastSeen == nil && det?.keyExpiry != nil, "流量计数、在线时 LastSeen 为零值、密钥过期时间")
        let offJSON = #"{"BackendState":"Running","Peer":{"k":{"HostName":"WIN-WSL","Online":false,"CurAddr":"","LastSeen":"2026-09-27T01:00:00Z"}}}"#
        let offDet = TwoMachine.parseDetail(Data(offJSON.utf8), pcHost: "win-wsl")
        check(offDet?.pcOnline == false && offDet?.direct == nil && offDet?.pcLastSeen != nil, "PC 离线：记下上次在线，直连未知")
        let fracJSON = #"{"Peer":{"k":{"HostName":"win-wsl","Online":false,"LastSeen":"2026-09-27T05:30:00.1Z"}}}"#
        check(TwoMachine.parseDetail(Data(fracJSON.utf8), pcHost: "win-wsl")?.pcLastSeen != nil, "LastSeen 带小数秒也认得")
        check(TwoMachine.parseDetail(Data(#"{"BackendState":"Stopped","Peer":{"k":{"HostName":"nas","Online":true}}}"#.utf8), pcHost: "win-wsl")?.pcOnline == nil, "别的节点不算 PC")
        check(TwoMachine.parseDetail(Data("not json".utf8), pcHost: "win-wsl") == nil, "解析不了就当不知道")
        let allOK = TwoMachine.parseCheck(out: "Mac → Windows/WSL：正常\nWindows/WSL → Mac：正常\nWindows 原生 → Mac：正常\n", err: "", at: now)
        check(allOK.ok && allOK.summary == "Mac→WSL ✓  WSL→Mac ✓  Win→Mac ✓", "三条线路都通")
        let half = TwoMachine.parseCheck(out: "Mac → Windows/WSL：正常\n", err: "Windows/WSL → Mac 失败。检查 Mac 远程登录。\n", at: now)
        check(!half.ok && half.macToWSL == true && half.wslToMac == false && half.winToMac == nil && half.reason.hasPrefix("Windows/WSL → Mac 失败"), "第二条断了：第三条没走到，原因取最后一行")

        // 概览小图标：宽度不变，三种状态画出来不一样
        let g = [TouchBarArt.GlanceLink.none, .online, .offline].map { TouchBarArt.glance(rows: rows, lights: [.waiting], now: now, link: $0) }
        check(g.allSatisfy { $0.size.width == g[0].size.width }, "双机线不改变小图标宽度")
        check(Set(g.map { $0.tiffRepresentation ?? Data() }).count == 3, "没连 / 连着 / PC 离线三种画法不同")

        var link = LinkState()
        link.available = true
        let noLink = TouchBarItem.aiPage(rows: rows, tasks: [], lights: [], relays: [], watched: [], now: now, link: nil, pet: TouchBarItem.relaxChip)
        check(!noLink.contains { $0.id == "link" }, "没装双机就没有双机小格")
        let withLink = TouchBarItem.aiPage(rows: rows, tasks: [], lights: [], relays: [], watched: [], now: now, link: TouchBarItem.linkChip(link, now: now), pet: TouchBarItem.relaxChip)
        check(withLink.map(\.id) == ["quota", "empty", "chats", "link", "relax", "tools"],
              "AI 页：额度表、对话（没有就一块暗的）、「对话」、双机小格、小猫（关了是「放松」）、最后是「工具」")
        check(TouchBarItem.toolCards(now: now, prompts: 3, shelf: Shelf(), translation: .idle).map(\.id) == ["prompts", "shelf", "translate"],
              "工具页的顺序：常用指令、材料架、翻译")
        // 双机小格：固定宽度，读屏说清状态
        var chipLink = LinkState()
        chipLink.available = true
        let off = TouchBarItem.linkChip(chipLink, now: now)
        check(off.image.size.width == TouchBarItem.chipWidth && off.label == "双机：未连（省电）。点开看详情", "没连：暗着，读屏说未连（省电）")
        chipLink.on = true
        chipLink.pcOnline = true
        check(TouchBarItem.linkChip(chipLink, now: now).label == "双机：已连 · WSL 在线。点开看详情", "连着、WSL 在线")
        chipLink.pcOnline = false
        check(TouchBarItem.linkChip(chipLink, now: now).label?.hasPrefix("双机：WSL 离线") == true, "WSL 离线")
        chipLink.error = "Tailscale 连接失败"
        check(TouchBarItem.linkChip(chipLink, now: now).label == "双机：Tailscale 连接失败。点开看详情", "出错时写出原因")
        check(TouchBarItem.toolsChip.image.size.width == TouchBarItem.chipWidth && TouchBarItem.relaxChip.image.size.width == TouchBarItem.chipWidth, "工具、放松小格同宽")
        check(TouchBarItem.linkImages(link, now: now, armed: nil).map(\.id) == ["link:state", "link:connect"], "没连时只有状态和「连接」")
        link.on = true
        link.since = now.addingTimeInterval(-2520)
        link.pcOnline = true
        link.direct = true
        link.lastTraffic = now.addingTimeInterval(-720)
        let onPage = TouchBarItem.linkImages(link, now: now, armed: nil)
        check(onPage.map(\.id) == ["link:state", "link:pc", "link:check", "link:terminal", "link:off"], "连着时：状态、PC、检查线路、SSH、断开")
        check(onPage.reduce(CGFloat(0)) { $0 + $1.image.size.width } + CGFloat(onPage.count - 1) * TouchBarItem.detailSpacing + TouchBarItem.backWidth + TouchBarItem.detailSpacing <= TouchBarItem.detailWidth, "连着时一屏放得下（含返回键）")
        let armedPage = TouchBarItem.linkImages(link, now: now, armed: 2)
        check(armedPage.last?.image.size == onPage.last?.image.size, "「断开」上膛前后一样宽（只换图，手指下不挪）")
        link.pcOnline = false
        link.pcLastSeen = now.addingTimeInterval(-7200)
        link.keyExpiry = now.addingTimeInterval(3 * 86400)
        link.check = half
        let badPage = TouchBarItem.linkImages(link, now: now, armed: nil).map(\.id)
        check(!badPage.contains("link:terminal") && badPage.contains("link:reason") && badPage.contains("link:key"), "PC 离线不给 SSH；线路坏了写原因；密钥快过期提醒")
        check(TouchBarItem.linkImages(link, now: now, armed: nil).allSatisfy { $0.image.size.width <= TouchBarItem.detailWidth }, "双机页每块放得进一屏")

        // 断开要点两下；收起就取消
        link.pcOnline = true
        link.check = nil
        link.keyExpiry = nil
        var asked: [AppModel.LinkAction] = []
        var expanded = 0
        let lb = TouchBarItem()
        lb.onLink = { asked.append($0) }
        lb.onExpand = { expanded += 1 }
        lb.update(rows: rows, lights: [], tasks: [], now: now, link: link)
        lb.tapForTesting(lb.shown.firstIndex { $0.id == "link" }!)
        check(lb.shown.first?.id == "link:state" && expanded == 1, "AI 页上点双机小格进双机页，顺便问一次 tailscaled")
        let offIndex = lb.shown.firstIndex { $0.id == "link:off" }!
        lb.tapForTesting(offIndex)
        check(asked.isEmpty, "点一下「断开」只上膛，不断")
        lb.tapForTesting(offIndex)
        check(asked == [.disconnect], "4 秒内再点一下才断")
        lb.tapForTesting(offIndex)
        lb.closeDetail()
        lb.tapForTesting(offIndex)
        check(asked == [.disconnect], "上膛后收起就取消，再点一下只是重新上膛")
        lb.tapForTesting(lb.shown.firstIndex { $0.id == "link:check" }!)
        check(asked == [.disconnect, .check], "检查线路一点就查")
        lb.update(rows: rows, lights: [], tasks: [], now: now, link: LinkState())
        check(lb.shown.first?.id != "link:state", "双机不可用了就回总览")

        // AppModel：只有点了才跑，跑的是假的；结果和原因记下来
        let lm = AppModel()
        lm.link.available = true
        ran.calls.removeAll()
        lm.linkAction(.check)
        check(lm.link.busy == .checking, "检查中")
        lm.linkAction(.disconnect)
        for _ in 0..<60 where lm.link.busy != nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        check(ran.calls.filter { $0.path == TwoMachine.script }.map(\.args) == [["status"]], "忙的时候不接第二个操作")
        check(lm.link.check?.macToWSL == true && lm.link.check?.wslToMac == false, "检查结果记下来")
        lm.linkAction(.connect)
        for _ in 0..<60 where lm.link.busy != nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        check(lm.link.error?.hasPrefix("Tailscale 连接失败") == true, "连不上时写出脚本给的原因")
        check(ran.calls.allSatisfy { $0.path == TwoMachine.script || $0.path == TwoMachine.cli }, "只调 two-machine 和 tailscale（都是假的）")

        await AttentionShelfTests.run(now: now, rows: rows, check: check)
        ResetReminderTests.run(now: now, check: check)
        RelayTests.run(now: now, rows: rows, check: check)
        await PromptTests.run(now: now, rows: rows, check: check)
        await ToolTests.run(now: now, rows: rows, check: check)
        await CalmPetTests.run(now: now, rows: rows, check: check)
        LyricsAutoTests.run(now: now, rows: rows, check: check)
        SessionHookTests.run(check: check)
        await ReceiptTests.run(check: check)
        await WatchTests.run(now: now, rows: rows, check: check)
        InterruptRateLimitTests.run(now: now, check: check)
        await RoadmapTests.run(now: now, rows: rows, check: check)
        await RoadmapTests.scrolling(now: now, rows: rows, check: check)
        await CodexRoadTests.run(now: now, rows: rows, check: check)
        SessionSnapshotTests.run(now: now, check: check)
        AIPageTests.run(now: now, check: check)
        PianoTests.run(now: now, rows: rows, check: check)
        SetupTests.run(check: check)

        print("PASS: \(checks) checks")
    }
}
