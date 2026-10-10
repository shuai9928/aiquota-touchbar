import AppKit
import UserNotifications

struct ResetReminder: Equatable {
    let id: String
    let fireAt: Date
    let title: String
    let body: String
    var sound = true               // 「做完叫我」自己已经响过一声，通知就静音
    var open: String? = nil        // 点通知打开这个会话（被限流停下、等额度恢复的那件）
}

enum ReminderStatus: Equatable {
    case off, idle, asking, on, denied
}

enum ResetReminders {
    static let threshold = 95.0
    static let exactDelay: TimeInterval = 60
    static let approxDelay: TimeInterval = 7 * 60

    /// blocked：被限流停下的 Claude 任务（新的在前）；window：估算它们什么时候能继续用的那个 Claude 窗口（AppModel.resumeEstimate 选的）。
    /// 那个窗口的「额度恢复了」提醒里写上它们，点了打开第一件；估不出来就不写
    static func plan(rows: [Provider], now: Date, blocked: [(key: String, title: String)] = [], window: String? = nil) -> [ResetReminder] {
        var reminders = plainPlan(rows: rows, now: now)
        guard !blocked.isEmpty, let window,
              let index = reminders.firstIndex(where: { $0.id.hasPrefix("reset:Claude#") && $0.id.hasSuffix(":" + window) })
        else { return reminders }
        let old = reminders[index]
        let names = blocked.prefix(3).map(\.title).joined(separator: "、") + (blocked.count > 3 ? " 等 \(blocked.count) 件" : "")
        reminders[index] = ResetReminder(id: old.id, fireAt: old.fireAt, title: old.title + "，可以接着做了",
                                         body: "被限流停下的：" + names + "。点这里打开" + (blocked.count > 1 ? "最近的那件。" : "它。"),
                                         open: blocked[0].key)
        return reminders
    }

    static func plainPlan(rows: [Provider], now: Date) -> [ResetReminder] {
        let names = rows.map(\.name)
        var seen: [String: Int] = [:]
        return rows.flatMap { provider -> [ResetReminder] in
            let base = provider.accountId ?? provider.name
            seen[base, default: 0] += 1
            let owner = "\(base)#\(seen[base] ?? 1)"
            let shared = names.filter { $0 == provider.name }.count > 1 && !provider.detail.isEmpty
            let name = shared ? provider.name + "（" + provider.detail + "）" : provider.name
            return provider.windows.compactMap { window in
                // 重置时间过了、还没到提醒的时候（晚 1 或 7 分钟发）：这条还在计划里，不然下一次刷新就把它撤了
                guard window.used >= threshold, let reset = window.resetsAt,
                      reset.addingTimeInterval(window.approx ? approxDelay : exactDelay) > now else { return nil }
                let body = window.approx
                    ? "按用量记录推算大约已经重置（可能差几分钟），打开看看最新用量。"
                    : "已经重置，可以继续用了。"
                return ResetReminder(id: "reset:" + owner + ":" + window.label,
                                     fireAt: reset.addingTimeInterval(window.approx ? approxDelay : exactDelay),
                                     title: name + " " + window.label + "额度恢复了", body: body)
            }
        }
    }
}

@MainActor
protocol ReminderCenter: AnyObject {
    func requestAuthorization(_ done: @escaping @MainActor (Bool) -> Void)
    func add(_ reminder: ResetReminder)
    func remove(ids: [String])
}

@MainActor
final class SystemReminderCenter: ReminderCenter {
    func requestAuthorization(_ done: @escaping @MainActor (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in done(granted) }
        }
    }

    func add(_ reminder: ResetReminder) {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = reminder.sound ? .default : nil
        if let open = reminder.open { content.userInfo = ["open": open] }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }

    func remove(ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}

@MainActor
final class ReminderScheduler {
    static let recheckInterval: TimeInterval = 600

    private(set) var status: ReminderStatus = .idle
    private(set) var scheduled: [String: Date] = [:]
    private var contents: [String: String] = [:]      // 排过的标题、正文、点了打开谁：同一时间点内容变了（多了被限流的任务）也要重排
    private var latest: [ResetReminder] = []
    private var lastAsked = Date.distantPast
    private let center: ReminderCenter
    var onStatus: (() -> Void)?

    init(center: ReminderCenter) {
        self.center = center
    }

    func sync(_ plan: [ResetReminder], enabled: Bool, now: Date) {
        latest = plan
        guard enabled else {
            if !scheduled.isEmpty { center.remove(ids: Array(scheduled.keys)) }
            scheduled = [:]
            contents = [:]
            status = .off
            return
        }
        if status == .off { status = .idle }
        let wanted = Dictionary(plan.map { ($0.id, $0.fireAt) }, uniquingKeysWith: { first, _ in first })
        // 不在计划里了：还没到重置时间的撤掉（额度降下来了、时间变了）；已经过了重置时间、正在等发出的留着让它发，发过的忘掉
        let stale = scheduled.keys.filter { wanted[$0] == nil }.sorted()
        let pending = stale.filter { id in
            guard let fire = scheduled[id] else { return false }
            return fire > now && fire.timeIntervalSince(now) <= ResetReminders.approxDelay
        }
        let cancel = stale.filter { id in (scheduled[id] ?? .distantPast) > now && !pending.contains(id) }
        if !cancel.isEmpty { center.remove(ids: cancel) }
        for id in stale where !pending.contains(id) { scheduled[id] = nil; contents[id] = nil }
        guard !plan.isEmpty else { return }
        switch status {
        case .on:
            for reminder in plan where scheduled[reminder.id] != reminder.fireAt || contents[reminder.id] != Self.content(reminder) {
                center.add(reminder)                           // 同一个 id 再加一次就是替换
                scheduled[reminder.id] = reminder.fireAt
                contents[reminder.id] = Self.content(reminder)
            }
        case .idle:
            ask(now: now)
        case .denied:
            if now.timeIntervalSince(lastAsked) >= Self.recheckInterval { ask(now: now) }
        case .asking, .off:
            return
        }
    }

    static func content(_ reminder: ResetReminder) -> String {
        reminder.title + "\n" + reminder.body + "\n" + (reminder.open ?? "")
    }

    private func ask(now: Date) {
        status = .asking
        lastAsked = now
        center.requestAuthorization { [weak self] granted in
            guard let self, self.status == .asking else { return }
            self.status = granted ? .on : .denied
            if granted { self.sync(self.latest, enabled: true, now: Date()) }
            self.onStatus?()
        }
    }
}
