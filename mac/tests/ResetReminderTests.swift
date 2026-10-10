import AppKit

enum ResetReminderTests {
    @MainActor
    final class FakeCenter: ReminderCenter {
        var grant = true
        var asks = 0
        var added: [ResetReminder] = []
        var removed: [String] = []
        var pending: ((Bool) -> Void)?
        var answerLater = false

        func requestAuthorization(_ done: @escaping @MainActor (Bool) -> Void) {
            asks += 1
            if answerLater { pending = { done($0) } } else { done(grant) }
        }

        func add(_ reminder: ResetReminder) { added.append(reminder) }
        func remove(ids: [String]) { removed.append(contentsOf: ids) }
    }

    static func window(_ label: String, used: Double, resetIn: TimeInterval?, now: Date, approx: Bool = false) -> QuotaWindow {
        QuotaWindow(label: label, short: "", used: used, resetsAt: resetIn.map { now.addingTimeInterval($0) }, approx: approx, length: 5 * 3600)
    }

    @MainActor
    static func run(now: Date, check: (Bool, String) -> Void) {
        let codex = Provider(name: "Codex", detail: "Plus", windows: [window("5小时", used: 100, resetIn: 3 * 3600 + 23 * 60, now: now),
                                                                     window("本周", used: 32, resetIn: 6 * 86400, now: now)],
                             updatedAt: now, accountId: "acct-a")
        let claude = Provider(name: "Claude", windows: [window("5小时", used: 96, resetIn: 1800, now: now, approx: true),
                                                        window("本周", used: 99, resetIn: nil, now: now)], updatedAt: now)
        let plan = ResetReminders.plan(rows: [claude, codex], now: now)
        check(plan.map(\.id) == ["reset:Claude#1:5小时", "reset:acct-a#1:5小时"], "只给 95% 以上、知道重置时间的窗口排提醒")
        check(plan.last?.fireAt == now.addingTimeInterval(3 * 3600 + 23 * 60 + 60) && plan.last?.title == "Codex 5小时额度恢复了", "Codex 在重置后 1 分钟提醒")
        check(plan.first?.fireAt == now.addingTimeInterval(1800 + 7 * 60) && plan.first?.body.contains("推算") == true, "Claude 是推算的时间，晚 7 分钟提醒并说明可能有偏差")
        let lower = Provider(name: "Codex", windows: [window("5小时", used: 94.9, resetIn: 600, now: now)], updatedAt: now)
        let passed = Provider(name: "Codex", windows: [window("5小时", used: 100, resetIn: -60, now: now)], updatedAt: now)
        check(ResetReminders.plan(rows: [lower, passed], now: now).isEmpty, "不到 95% 或重置时间已过都不提醒")
        let second = Provider(name: "Codex", detail: "Pro", windows: codex.windows, updatedAt: now, accountId: "acct-b")
        let twoAccounts = ResetReminders.plan(rows: [codex, second], now: now)
        check(Set(twoAccounts.map(\.id)).count == 2 && twoAccounts.map(\.title) == ["Codex（Plus） 5小时额度恢复了", "Codex（Pro） 5小时额度恢复了"],
              "两个 Codex 账号分开提醒，标题带上账号类型")

        let center = FakeCenter()
        let scheduler = ReminderScheduler(center: center)
        scheduler.sync([], enabled: true, now: now)
        check(center.asks == 0 && scheduler.status == .idle, "没有要提醒的就不请求通知权限")
        scheduler.sync(plan, enabled: true, now: now)
        check(center.asks == 1 && scheduler.status == .on && center.added.map(\.id) == plan.map(\.id), "第一次需要时才请求权限，同意后排上提醒")
        scheduler.sync(plan, enabled: true, now: now)
        check(center.asks == 1 && center.added.count == 2, "同样的提醒不重复排")
        let moved = [ResetReminder(id: plan[0].id, fireAt: plan[0].fireAt.addingTimeInterval(120), title: plan[0].title, body: plan[0].body), plan[1]]
        scheduler.sync(moved, enabled: true, now: now)
        check(center.added.count == 3 && center.added.last?.fireAt == moved[0].fireAt && center.removed.isEmpty, "重置时间变了就用同一个 id 改约")
        scheduler.sync([plan[1]], enabled: true, now: now)
        check(center.removed == [plan[0].id] && scheduler.scheduled.keys.sorted() == [plan[1].id], "额度降下来了就撤掉那条提醒")
        scheduler.sync(plan, enabled: false, now: now)
        check(center.removed.contains(plan[1].id) && scheduler.scheduled.isEmpty && scheduler.status == .off, "配置里关掉就全部撤掉")

        let denied = FakeCenter()
        denied.grant = false
        let refused = ReminderScheduler(center: denied)
        refused.sync(plan, enabled: true, now: now)
        check(refused.status == .denied && denied.added.isEmpty, "不允许通知时不排提醒")
        refused.sync(plan, enabled: true, now: now.addingTimeInterval(60))
        check(denied.asks == 1, "被拒后不会一直追问")
        denied.grant = true
        refused.sync(plan, enabled: true, now: now.addingTimeInterval(ReminderScheduler.recheckInterval + 60))
        check(denied.asks == 2 && refused.status == .on && denied.added.count == 2, "过一阵再确认一次：在系统设置里打开后就能排上")

        let slow = FakeCenter()
        slow.answerLater = true
        let waiting = ReminderScheduler(center: slow)
        waiting.sync(plan, enabled: true, now: now)
        waiting.sync(plan, enabled: true, now: now)
        check(slow.asks == 1 && waiting.status == .asking, "等你回答权限弹窗时不重复弹")
        waiting.sync([plan[1]], enabled: true, now: now)
        slow.pending?(true)
        check(slow.added.map(\.id) == [plan[1].id], "允许后按最新的计划排")

        let info = Fmt.touchBarInfo(codex.windows[0], now: now)
        check(info.text == "3时23分后恢复" && info.color == .systemRed, "展开后额度卡上写多久后恢复")
        check(Fmt.touchBarInfo(claude.windows[0], now: now).text != "30分后恢复", "没用完时照旧写重置或用完的时间")
        let approxFull = window("5小时", used: 100, resetIn: 1800, now: now, approx: true)
        check(Fmt.touchBarInfo(approxFull, now: now).text == "约30分后恢复", "推算的恢复时间前面加约")
        check(Fmt.reminderHint(codex.windows[0], status: .on, now: now)?.hasSuffix("恢复时会发通知提醒你") == true, "面板里说明到时会提醒")
        check(Fmt.reminderHint(codex.windows[0], status: .denied, now: now)?.contains("通知没打开") == true, "通知被关了要如实说")
        check(Fmt.reminderHint(codex.windows[0], status: .off, now: now) == nil && Fmt.reminderHint(codex.windows[1], status: .on, now: now) == nil,
              "关掉提醒或没快用完时不写")
    }
}
