import Foundation

/// 被限流后到点叫你、认出按 Esc 打断。会话文件和 transcript 都写在临时目录（test.sh 设的 AIQUOTA_TEST_HOME）
enum InterruptRateLimitTests {
    @MainActor
    final class Reminders: ReminderCenter {
        var added: [ResetReminder] = []
        var removed: [String] = []
        func requestAuthorization(_ done: @escaping @MainActor (Bool) -> Void) { done(true) }
        func add(_ reminder: ResetReminder) { added.append(reminder) }
        func remove(ids: [String]) { removed += ids }
    }

    static func line(_ object: [String: Any]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? ""
    }

    @MainActor
    static func run(now: Date, check: (Bool, String) -> Void) {
        hook(check: check)
        interrupt(now: now, check: check)
        rateLimit(now: now, check: check)
    }

    /// hook 记下主对话出错的类型；子代理的、下一轮开始后都不留
    @MainActor
    static func hook(check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-rate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func fire(_ event: String, _ extra: [String: Any] = [:], at offset: TimeInterval) {
            var o: [String: Any] = ["session_id": "s1", "hook_event_name": event, "transcript_path": dir.appendingPathComponent("t.jsonl").path]
            for (key, value) in extra { o[key] = value }
            SessionHook.run(agentArg: "claude", input: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(),
                            env: SessionHook.Environment(dir: dir, now: t0.addingTimeInterval(offset), bundle: nil, title: { _, _, _, _, _, _ in nil }))
        }
        func rec() -> [String: Any] {
            (try? Data(contentsOf: SessionFiles.url("claude-s1", in: dir))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        fire("UserPromptSubmit", ["prompt": "修一下"], at: 0)
        fire("StopFailure", ["agent_id": "sub", "error": "rate_limit"], at: 1)
        check(rec()["errorType"] == nil, "子代理被限流：不记在主会话上")
        fire("StopFailure", ["error": "rate_limit", "error_details": "详细信息不留"], at: 2)
        check(rec()["state"] as? String == "error" && rec()["errorType"] as? String == "rate_limit", "主对话被限流：记下 rate_limit")
        check(!String(describing: rec()).contains("详细信息不留"), "错误详情不写进状态文件")
        fire("UserPromptSubmit", ["prompt": "继续"], at: 3)
        check(rec()["errorType"] == nil, "接着跑了：出错类型清掉")
        fire("StopFailure", ["error": "奇怪的 值; rm -rf"], at: 4)
        check(rec()["errorType"] as? String == "rmrf", "出错类型只留英文字母和下划线")
    }

    /// Esc 打断：transcript 最后一条对话是「[Request interrupted by user…]」（比最后一次变状态晚）就改成空闲
    @MainActor
    static func interrupt(now: Date, check: (Bool, String) -> Void) {
        let dir = SessionFiles.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcripts = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-esc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let ids = ["esc", "busy", "fresh", "fake", "side", "wait", "cmd", "synth", "stale", "old", "bg"]
        defer {
            try? FileManager.default.removeItem(at: transcripts)
            for name in ids { try? FileManager.default.removeItem(at: SessionFiles.url("claude-" + name)) }
        }
        let t = now.timeIntervalSince1970
        let stampFormatter = ISO8601DateFormatter()
        func stamp(_ seconds: TimeInterval) -> String { stampFormatter.string(from: Date(timeIntervalSince1970: seconds)) }
        func session(_ id: String, state: String = "running", updated: TimeInterval, extra: [String: Any] = [:], lines: [String]) {
            let path = transcripts.appendingPathComponent(id + ".jsonl").path
            FileManager.default.createFile(atPath: path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))
            var rec: [String: Any] = ["agent": "claude", "id": id, "state": state, "since": updated, "updated": updated, "first": updated,
                                      "transcript": path, "turnID": "T"]
            for (key, value) in extra { rec[key] = value }
            try? JSONSerialization.data(withJSONObject: rec).write(to: SessionFiles.url("claude-" + id))
        }
        let toolUse = line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "a", "name": "Bash", "input": ["command": "ls"]]]]])
        let toolResult = line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "a", "content": "ok"]]]])
        func marker(at seconds: TimeInterval) -> String {
            line(["type": "user", "timestamp": stamp(seconds), "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user for tool use]"]]]])
        }
        let meta = [line(["type": "queue-operation"]), line(["type": "custom-title", "title": "x"]), line(["type": "last-prompt"])]
        let command = line(["type": "user", "message": ["role": "user", "content": "<command-name>/model</command-name>"]])
        let caveat = line(["type": "user", "isMeta": true, "message": ["role": "user", "content": "<local-command-caveat>…</local-command-caveat>"]])
        let synthetic = line(["type": "assistant", "message": ["role": "assistant", "model": "<synthetic>", "content": [["type": "text", "text": "No response requested."]]]])
        session("esc", updated: t - 60, lines: [toolUse, toolResult, marker(at: t - 30)] + meta)
        session("busy", updated: t - 60, lines: [toolUse, toolResult] + meta)
        session("fresh", updated: t - 3, lines: [toolUse, toolResult, marker(at: t - 2)])
        session("fake", updated: t - 60, lines: [toolUse, line(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "a", "content": "[Request interrupted by user] 这是命令输出里的一段字"]]]])])
        session("side", updated: t - 60, lines: [toolUse, toolResult,
                                                line(["type": "user", "isSidechain": true, "message": ["role": "user", "content": "[Request interrupted by user]"]])])
        session("wait", state: "waiting", updated: t - 5, extra: ["waitReason": "permission", "waitAgent": ""],
                lines: [toolUse, line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "a", "is_error": true,
                        "content": "The user doesn't want to proceed"]]]]), marker(at: t - 3)])
        session("cmd", updated: t - 60, lines: [toolUse, marker(at: t - 40), caveat, command] + meta)
        session("synth", updated: t - 60, lines: [toolUse, marker(at: t - 40), synthetic])
        session("stale", updated: t - 20, lines: [toolUse, marker(at: t - 100), caveat])
        session("old", updated: t - 2 * 86400 - 60, lines: [toolUse, marker(at: t - 2 * 86400)])
        session("bg", updated: t - 60, lines: [toolUse, marker(at: t - 30)])
        let sub = transcripts.appendingPathComponent("bg/subagents/workflows/wf")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("agent-1.jsonl").path, contents: Data("{}\n".utf8))

        let model = AppModel()
        model.sessions = SessionFiles.load(now: now)
        let sessions = model.sessions
        func find(_ id: String) -> AgentSession? { sessions.first { $0.id == id } }
        check(find("esc")?.state == .idle && find("esc")?.interrupted == true, "最后一条对话是 Esc 打断：改成空闲")
        check(find("esc")?.briefStatus(.idle, now: now).hasPrefix("你打断了") == true, "卡片上写「你打断了」")
        check(abs((find("esc")?.since.timeIntervalSince1970 ?? 0) - (t - 30)) < 1.5, "按打断的那一刻算，不按发现的时候")
        check(find("busy")?.state == .running, "最后一条是工具结果：还在跑")
        check(find("fresh")?.state == .running, "刚有过事件（10 秒内）：先不看")
        check(find("fake")?.state == .running, "命令输出里恰好有这句话：不算打断")
        check(find("side")?.state == .running, "子代理的打断不算主对话的")
        check(find("wait")?.state == .idle && find("wait")?.waitReason == "", "在等你批准时拒绝（或按 Esc）：也认出来，不再亮橙灯")
        check(find("cmd")?.state == .idle, "打断后马上用了 /model 这类本地命令：命令记录不挡住打断")
        check(find("synth")?.state == .idle, "系统补的空回复不挡住打断")
        check(find("stale")?.state == .running, "打断比最后一次变状态还早（之后又提交过）：不算这一轮被打断")
        check(find("old")?.state == .idle && model.lights(at: now).allSatisfy { $0.session.id != "old" }, "很久以前的打断：改成空闲但不重新亮灯")
        check(find("bg")?.state == .running, "后台子代理、工作流最近还在写：主对话停了也还算在跑")
        let log = (try? String(contentsOf: dir.appendingPathComponent("hooks.log"), encoding: .utf8)) ?? ""
        check(log.contains("Esc 打断"), "日志里记一笔")
        check(SessionFiles.interruptTime(transcripts.appendingPathComponent("没有这个文件").path) == nil, "transcript 不在：不算打断")

        // 在跑的任务订了「做完叫我」，然后按了 Esc：订阅悄悄作废
        var running = AgentSession(agent: "claude", id: "esc", state: .running, since: now, updated: now, first: now, title: "修登录", bundle: "", turnID: "T")
        model.sessions = [running]
        model.watchSound = { _ in }
        model.notificationsAllowed = { $0(false) }
        model.toggleWatch("session:claude-esc")
        check(model.watched["session:claude-esc"] != nil, "订上了")
        running.state = .idle
        running.interrupted = true
        model.sessions = [running]
        model.checkWatched()
        check(model.watched.isEmpty && model.watchCard(session: running) == nil, "你按 Esc 打断了：订阅作废，卡片不再显示「会叫你」")
    }

    /// 被限流：卡片写几点恢复；额度恢复的提醒里带上被卡住的任务，点了打开它
    @MainActor
    static func rateLimit(now: Date, check: (Bool, String) -> Void) {
        let model = AppModel()
        func window(_ label: String, _ used: Double, resets: TimeInterval?, approx: Bool) -> QuotaWindow {
            QuotaWindow(label: label, short: "", used: used, resetsAt: resets.map { now.addingTimeInterval($0) }, approx: approx, length: 5 * 3600)
        }
        model.claude = Provider(name: "Claude", windows: [window("5小时", 100, resets: 7200, approx: true), window("本周", 40, resets: 86400 * 3, approx: false)],
                                updatedAt: now)
        let estimate = model.resumeEstimate(now: now)
        check(estimate?.at == now.addingTimeInterval(7200) && estimate?.approx == true && estimate?.window == "5小时", "按用满的那个窗口估几点恢复（推算的算「约」）")
        model.claude.windows[1].used = 96
        check(model.resumeEstimate(now: now)?.window == "5小时", "周额度快满（96%）但还没用满：按用满的 5 小时算")
        model.claude.windows[1].used = 100
        check(model.resumeEstimate(now: now)?.at == now.addingTimeInterval(86400 * 3) && model.resumeEstimate(now: now)?.window == "本周",
              "两个窗口都用满了：等最晚的那个")
        model.claude.windows[1].resetsAt = nil
        check(model.resumeEstimate(now: now) == nil, "周额度用满但不知道几点重置：说不准，不瞎报 5 小时的时间")
        model.claude.windows[1].resetsAt = now.addingTimeInterval(86400 * 3)
        model.claude.windows[1].used = 40

        var blocked = AgentSession(agent: "claude", id: "rl", state: .error, since: now, updated: now, first: now, title: "修登录", bundle: "",
                                   turnID: "T", errorType: "rate_limit")
        model.sessions = [blocked]
        let task = model.tasks(at: now).first?.session
        let clock = Fmt.shortClock(now.addingTimeInterval(7200), now: now)
        check(task?.resumeAt == now.addingTimeInterval(7200) && task?.briefStatus(.error, now: now) == "被限流 · 约 " + clock + " 恢复",
              "任务卡写「被限流 · 约几点恢复」")
        check(model.lights(at: now).first?.session.resumeAt != nil, "会话灯（小猫、待处理用的）也带上恢复时间")
        blocked.errorType = "server_error"
        check(blocked.briefStatus(.error, now: now).hasPrefix("服务器忙"), "服务器出错（Claude 发的是 server_error）写服务器忙")
        blocked.errorType = "max_output_tokens"
        check(blocked.briefStatus(.error, now: now).hasPrefix("长度超限停了"), "长度超限（输出或上下文）另外写")
        blocked.errorType = "rate_limit"
        check(blocked.briefStatus(.error, now: now) == "被限流 · 稍后再试", "估不出来（窗口没满，多半是临时限流）：写稍后再试")
        let line = TouchBarItem.petLine(.error, PetContext(lights: [(task ?? blocked, .error)], now: now))
        check(line.title == "Claude 被限流了" && line.subtitle == "约 " + clock + " 恢复 · 修登录", "小猫说被限流了、几点恢复")
        check(Attention.items(from: [(blocked, .error)]).first?.action == "被限流了", "待处理页写被限流了")

        // 额度恢复的提醒里带上被卡住的任务（写在估算用的那个窗口的提醒上）
        let rows = [model.claude]
        let plain = ResetReminders.plan(rows: rows, now: now)
        let merged = ResetReminders.plan(rows: rows, now: now, blocked: [(key: "claude-rl", title: "修登录"), (key: "claude-b", title: "写文档")],
                                         window: model.resumeEstimate(now: now)?.window)
        check(plain.count == merged.count && merged.first?.fireAt == plain.first?.fireAt, "不多弹一条，还是那一条提醒")
        check(merged.first?.title.hasSuffix("可以接着做了") == true && merged.first?.body.contains("修登录、写文档") == true && merged.first?.open == "claude-rl",
              "提醒里写上被限流停下的任务，点了打开最近那件")
        check(plain.first?.open == nil, "没有被卡住的任务时照旧（点了打开面板）")
        var both = model.claude
        both.windows[1].used = 100
        let late = ResetReminders.plan(rows: [both], now: now, blocked: [(key: "claude-rl", title: "修登录")], window: "本周")
        check(late.first { $0.open != nil }?.id.hasSuffix("本周") == true && late.filter { $0.open != nil }.count == 1, "写在估算用的那个窗口的提醒上")
        check(ResetReminders.plan(rows: rows, now: now, blocked: [(key: "claude-rl", title: "修登录")], window: nil).allSatisfy { $0.open == nil },
              "估不出恢复时间：不在提醒里写「可以接着做了」")

        // 同一时间点内容变了（多了被卡住的任务）：重新排
        let center = Reminders()
        let scheduler = ReminderScheduler(center: center)
        scheduler.sync(plain, enabled: true, now: now)
        let first = center.added.count
        scheduler.sync(merged, enabled: true, now: now)
        check(center.added.count == first + 1 && center.added.last?.open == "claude-rl", "提醒内容变了：同一个 id 重排一次")
        scheduler.sync(merged, enabled: true, now: now)
        check(center.added.count == first + 1, "内容没变不重排")

        // 重置时间过了、提醒还没发（推算的晚 7 分钟）：刷新时不能把它撤掉——数据还是满的、或者已经降下来了，都一样
        let grace = Reminders()
        let waiter = ReminderScheduler(center: grace)
        let pendingRows = [Provider(name: "Claude", windows: [window("5小时", 100, resets: 60, approx: true)], updatedAt: now)]
        waiter.sync(ResetReminders.plan(rows: pendingRows, now: now), enabled: true, now: now)
        let firstFire = waiter.scheduled.values.first
        waiter.sync(ResetReminders.plan(rows: pendingRows, now: now.addingTimeInterval(80)), enabled: true, now: now.addingTimeInterval(80))
        check(firstFire != nil && waiter.scheduled.values.first == firstFire && grace.removed.isEmpty, "重置后还在计划里（等着晚 7 分钟发）")
        var dropped = pendingRows
        dropped[0].windows[0].used = 0
        waiter.sync(ResetReminders.plan(rows: dropped, now: now.addingTimeInterval(90)), enabled: true, now: now.addingTimeInterval(90))
        check(waiter.scheduled.values.first == firstFire && grace.removed.isEmpty, "重置后数据降下来了：正在等发的那条也留着，不撤")
        waiter.sync(ResetReminders.plan(rows: dropped, now: now.addingTimeInterval(600)), enabled: true, now: now.addingTimeInterval(600))
        check(waiter.scheduled.isEmpty && grace.removed.isEmpty, "发过以后忘掉（不去撤已经发出的）")
        let early = Reminders()
        let canceller = ReminderScheduler(center: early)
        let farRows = [Provider(name: "Claude", windows: [window("5小时", 100, resets: 3600, approx: false)], updatedAt: now)]
        canceller.sync(ResetReminders.plan(rows: farRows, now: now), enabled: true, now: now)
        var eased = farRows
        eased[0].windows[0].used = 50
        canceller.sync(ResetReminders.plan(rows: eased, now: now), enabled: true, now: now)
        check(early.removed.count == 1 && canceller.scheduled.isEmpty, "还没到重置时间、额度降下来了：照旧撤掉")

        // 被限流的红灯亮到估计恢复之后半小时；过了重置时间说「额度应已恢复」
        let limited = AgentSession(agent: "claude", id: "long", state: .error, since: now.addingTimeInterval(-3 * 3600),
                                   updated: now.addingTimeInterval(-3 * 3600), first: now, title: "等额度", bundle: "", turnID: "T", errorType: "rate_limit")
        model.sessions = [limited]
        check(model.lights(at: now).first?.light == .error, "被限流 3 小时了、还没到恢复时间：红灯还亮着（不是 2 小时就灭）")
        let after = now.addingTimeInterval(7200 + 60)
        check(model.tasks(at: after).first?.session.briefStatus(.error, now: after) == "额度应已恢复 · 可以继续", "过了恢复时间：说额度应已恢复，不说稍后再试")
        let recovered = TouchBarItem.petLine(.error, PetContext(lights: [(model.tasks(at: after).first?.session ?? limited, .error)], now: after))
        check(recovered.title == "Claude 额度应已恢复", "小猫也说额度应已恢复")
        check(model.lights(at: now.addingTimeInterval(7200 + 3600)).isEmpty, "恢复半小时后红灯才灭")
        let oldSession = AgentSession(agent: "claude", id: "gone", state: .error, since: now.addingTimeInterval(-86400 * 2),
                                      updated: now.addingTimeInterval(-86400 * 2), first: now, title: "前天的", bundle: "", turnID: "T", errorType: "rate_limit")
        model.resumeMemo = [:]
        model.claude.windows[0].used = 40
        model.sessions = [oldSession]
        check(model.lights(at: now).isEmpty, "前天被限流、早就放下的：不亮灯（提醒里也只挂还亮着红灯的）")
    }
}
