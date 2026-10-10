// AIQuota：在 macOS 菜单栏（和触控栏的 Control Strip）显示 Claude / Codex 的 5 小时和每周限额，
// 触控栏上另外给每个正在用的 AI 会话一盏状态灯。
// - Claude：读 Claude 桌面 app 自己记录的用量（plan-usage-history.json，约 15 分钟一条），不需要额外登录。
// - Codex：用本机 Codex 的登录（~/.codex/auth.json）查询 chatgpt.com 的用量接口，每分钟刷新。
//   只读 token，不刷新也不改写 auth.json（token 由 Codex 自己续期）。
// - 会话状态：Claude Code 和 Codex 的 hooks 调用 `AIQuota --hook`，每个会话写一个小状态文件，这里监视那个目录。

import AppKit
import UserNotifications
import SwiftUI

// MARK: - 数据模型

struct QuotaWindow {
    var label: String          // 5小时 / 本周 / 30天
    var short: String          // 5h / 周 / 月
    var used: Double           // 已用百分比
    var resetsAt: Date? = nil
    var approx = false         // 重置时间是估算的
    var note: String? = nil
    var length: TimeInterval? = nil   // 窗口长度，用来算这一轮时间过去了多少

    /// 重置时间已过、数据还没更新时，按已重置显示
    func effective(at now: Date) -> QuotaWindow {
        guard let r = resetsAt, r <= now else { return self }
        var w = self
        w.used = 0
        w.resetsAt = nil
        w.note = "已重置"
        return w
    }

    /// 这一轮时间已经过去的比例（0…1），不知道重置时间时为 nil
    func elapsed(at now: Date) -> Double? {
        guard let r = resetsAt, let len = length, len > 0 else { return nil }
        return min(1, max(0, 1 - r.timeIntervalSince(now) / len))
    }

    /// 照这一轮到现在的平均速度，重置前会在什么时候用完；用不完为 nil
    func runsOut(at now: Date) -> Date? {
        guard used > 0, used < 100, let r = resetsAt, let len = length, let e = elapsed(at: now), e > 0 else { return nil }
        let t = now.addingTimeInterval((100 - used) * e * len / used)
        return t < r ? t : nil
    }

    enum Pace { case ok, fast, full }

    /// 用量跑到时间前面（且已用 15% 以上）算太快，90% 以上算快满了；不知道重置时间时只看用量
    func pace(at now: Date) -> Pace {
        if used >= 90 { return .full }
        if let e = elapsed(at: now) { return used >= 15 && used > e * 100 ? .fast : .ok }
        return used >= 70 ? .fast : .ok
    }
}

extension QuotaWindow.Pace {
    var color: NSColor? {
        switch self {
        case .ok: return nil
        case .fast: return .systemOrange
        case .full: return .systemRed
        }
    }
}

struct Provider {
    var name: String
    var detail = ""
    var windows: [QuotaWindow] = []
    var updatedAt: Date? = nil
    var error: String? = nil
    var accountId: String? = nil
    var staleAfter: TimeInterval = 5 * 60
    /// ZCode：没有可查的计划额度，画本机 token 用量（今日 / 近 7 天，按会话记账统计）
    var tokens: (today: Int, week: Int)? = nil

    func isStale(at now: Date) -> Bool {
        guard let t = updatedAt else { return true }
        return now.timeIntervalSince(t) > staleAfter
    }
}

func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

// MARK: - 配置

struct CodexAccount {
    var label: String
    var auth: String
    var authPath: String { expand(auth) }
}

struct AppConfig {
    var claudeHistory = "~/Library/Application Support/Claude/plan-usage-history.json"
    var claudeWeeklyReset = ""
    var codex = [CodexAccount(label: "Codex", auth: "~/.codex/auth.json")]
    var refreshSeconds: Double = 60
    var touchBar = true
    var lyrics = true
    var twoMachine = true
    var pcHost = "win-wsl"
    var resetReminder = true

    var claudeHistoryPath: String { expand(claudeHistory) }

    static let dir: URL = {
        #if AIQUOTA_TEST
        // 测试把配置、会话、灯、指令都放到临时目录（test.sh 设这个变量），不读写真实的
        if let home = ProcessInfo.processInfo.environment["AIQUOTA_TEST_HOME"], !home.isEmpty { return URL(fileURLWithPath: home) }
        #endif
        return URL(fileURLWithPath: expand("~/Library/Application Support/AIQuota"))
    }()
    static var fileURL: URL { dir.appendingPathComponent("config.json") }

    static let defaultText = """
    {
      "claudeWeeklyReset": "",
      "_说明": "claudeWeeklyReset 填 Claude 每周限额的重置时间（Claude 桌面 app 设置 → 用量 里能看到），例如 周五 11:00；codex 可以列多个 auth.json，同一账号只显示一次；touchBar 改成 false 就不在触控栏显示",
      "codex": [
        { "label": "Codex", "auth": "~/.codex/auth.json" }
      ],
      "refreshSeconds": 60,
      "touchBar": true
    }

    """

    static func load() -> AppConfig {
        var cfg = AppConfig()
        guard let data = try? Data(contentsOf: fileURL) else {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? defaultText.write(to: fileURL, atomically: true, encoding: .utf8)
            return cfg
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return cfg }
        if let s = obj["claudeHistory"] as? String, !s.isEmpty { cfg.claudeHistory = s }
        if let s = obj["claudeWeeklyReset"] as? String { cfg.claudeWeeklyReset = s }
        if let arr = obj["codex"] as? [[String: Any]] {
            let list = arr.compactMap { d -> CodexAccount? in
                guard let a = d["auth"] as? String, !a.isEmpty else { return nil }
                return CodexAccount(label: d["label"] as? String ?? "Codex", auth: a)
            }
            if !list.isEmpty { cfg.codex = list }
        }
        if let n = num(obj["refreshSeconds"]) { cfg.refreshSeconds = max(30, n) }
        if let b = obj["touchBar"] as? Bool { cfg.touchBar = b }
        if let b = obj["lyrics"] as? Bool { cfg.lyrics = b }
        if let b = obj["twoMachine"] as? Bool { cfg.twoMachine = b }
        if let h = obj["pcHost"] as? String, !h.isEmpty { cfg.pcHost = h }
        if let enabled = obj["resetReminder"] as? Bool { cfg.resetReminder = enabled }
        return cfg
    }
}

// MARK: - Claude（桌面 app 的用量记录）

enum ClaudeHistory {
    private struct Sample { let t: Double; let fh: Double; let sd: Double; let org: String }

    static func load(path: String, weeklySpec: String, now: Date) -> Provider {
        var p = Provider(name: "Claude", detail: "桌面 app", staleAfter: 30 * 60)
        guard let data = FileManager.default.contents(atPath: path) else {
            p.error = "没找到 Claude 桌面 app 的用量记录"
            return p
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["samples"] as? [[String: Any]] else {
            p.error = "Claude 用量记录格式无法识别"
            return p
        }
        var list: [Sample] = raw.compactMap { s in
            guard let t = num(s["t"]), let u = s["u"] as? [String: Any],
                  let fh = num(u["fh"]), let sd = num(u["sd"]) else { return nil }
            return Sample(t: t / 1000, fh: fh, sd: sd, org: s["org"] as? String ?? "")
        }
        list.sort { $0.t < $1.t }
        guard let last = list.last else {
            p.error = "Claude 用量记录为空"
            return p
        }
        list = list.filter { $0.org == last.org }
        let sampleTime = Date(timeIntervalSince1970: last.t)
        p.updatedAt = sampleTime

        // 5 小时窗口：往回找本轮窗口第一次出现用量的时间，估算重置时间（误差约 ±7 分钟）
        var five = QuotaWindow(label: "5小时", short: "5h", used: last.fh, length: 5 * 3600)
        if last.fh <= 0 {
            five.note = "本轮还没开始"
        } else {
            var k = list.count - 1
            while k > 0 {
                let prev = list[k - 1]
                if prev.fh <= 0 || prev.fh > list[k].fh || last.t - prev.t >= 5 * 3600 { break }
                k -= 1
            }
            let upper = list[k].t
            var lower = last.t - 5 * 3600
            if k > 0 { lower = max(lower, list[k - 1].t) }
            // 只有在这 5 小时里看到了起点（归零或下降）才估算，否则可能把上一轮的样本当成这一轮的开头
            if k > 0 && list[k - 1].t > last.t - 5 * 3600 && upper - lower <= 3600 {
                five.resetsAt = Date(timeIntervalSince1970: (upper + lower) / 2 + 5 * 3600)
                five.approx = true
            }
        }

        // 每周窗口：桌面 app 的记录里没有重置时间。配置里填了就用；没填时按用量推算（见 inferWeeklyReset）
        var week = QuotaWindow(label: "本周", short: "周", used: last.sd, length: 7 * 86400)
        if let next = Fmt.nextWeekly(weeklySpec, after: now) {
            if sampleTime < next.addingTimeInterval(-7 * 86400) {
                week.used = 0
                week.note = "已重置"
            }
            week.resetsAt = next
        } else if let inferred = ClaudeHistory.inferWeeklyReset(list, sampleTime: sampleTime) {
            if sampleTime < inferred.addingTimeInterval(-7 * 86400) {
                week.used = 0
                week.note = "已重置"
            }
            week.resetsAt = inferred
            week.approx = true
        } else {
            week.note = "未设置重置时间"
        }
        p.windows = [five, week]
        return p
    }

    /// 没填 claudeWeeklyReset 时，从用量历史推算本周窗口什么时候结束：
    /// 一周之内 sd 只涨不落（偶尔几个点的小回落），只在窗口边界整段掉下来。
    /// 从最新往回找最近一次大掉落（掉 30 个点以上、落到 15 以内），它发生在前后两个样本之间——
    /// 中点当这一周的开始，+7 天就是结束，误差是区间宽度的一半。三种情况不推算：
    /// 区间比 48 小时还宽（跨着 app 长时间关着，定不准）、宽度为 0（多半是坏样本）、
    /// 推出来的结束已经落在最后一份样本之前（说明这一周的边界没观察到，最近一次掉落是更早的周）。
    private static func inferWeeklyReset(_ list: [Sample], sampleTime: Date) -> Date? {
        var k = list.count - 1
        while k > 0 {
            let prev = list[k - 1], cur = list[k]
            if prev.sd >= 40, cur.sd <= 15, prev.sd - cur.sd >= 30 {
                let width = cur.t - prev.t
                guard width > 0, width <= 48 * 3600 else { return nil }
                let start = Date(timeIntervalSince1970: (prev.t + cur.t) / 2)
                let end = start.addingTimeInterval(7 * 86400)
                return end > sampleTime ? end : nil
            }
            k -= 1
        }
        return nil
    }
}

// MARK: - Codex（chatgpt.com 用量接口）

enum CodexAPI {
    private static let session = URLSession(configuration: .ephemeral)

    static func fetch(_ account: CodexAccount) async -> Provider {
        var p = Provider(name: account.label)
        guard let data = FileManager.default.contents(atPath: account.authPath),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            p.error = "没找到 Codex 登录信息：\(account.auth)"
            return p
        }
        p.accountId = tokens["account_id"] as? String

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let id = p.accountId { req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("AIQuota/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (body, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                p.error = "Codex 登录已过期，打开一次 Codex 即可自动续期"
                return p
            }
            guard code == 200, let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                p.error = "Codex 接口返回 HTTP \(code)"
                return p
            }
            if let plan = obj["plan_type"] as? String, let first = plan.first {
                p.detail = first.uppercased() + plan.dropFirst()
            }
            if let rl = obj["rate_limit"] as? [String: Any] {
                for key in ["primary_window", "secondary_window"] {
                    if let w = rl[key] as? [String: Any] { p.windows.append(window(w)) }
                }
            }
            p.updatedAt = Date()
        } catch {
            p.error = "网络错误：\(error.localizedDescription)"
        }
        return p
    }

    private static func window(_ w: [String: Any]) -> QuotaWindow {
        let seconds = Int(num(w["limit_window_seconds"]) ?? 0)
        var q = label(seconds)
        q.used = num(w["used_percent"]) ?? 0
        if seconds > 0 { q.length = TimeInterval(seconds) }
        if let r = num(w["reset_at"]), r > 0 {
            q.resetsAt = Date(timeIntervalSince1970: r)
        } else if let after = num(w["reset_after_seconds"]) {
            q.resetsAt = Date().addingTimeInterval(after)
        }
        return q
    }

    private static func label(_ s: Int) -> QuotaWindow {
        switch s {
        case 18000: return QuotaWindow(label: "5小时", short: "5h", used: 0)
        case 604800: return QuotaWindow(label: "本周", short: "周", used: 0)
        case 86400: return QuotaWindow(label: "今天", short: "日", used: 0)
        case 28 * 86400...31 * 86400: return QuotaWindow(label: "\(s / 86400)天", short: "月", used: 0)
        default:
            if s >= 86400 && s % 86400 == 0 { return QuotaWindow(label: "\(s / 86400)天", short: "\(s / 86400)d", used: 0) }
            if s >= 3600 { return QuotaWindow(label: "\(s / 3600)小时", short: "\(s / 3600)h", used: 0) }
            return QuotaWindow(label: "限额", short: "·", used: 0)
        }
    }
}

// MARK: - 格式化

enum Fmt {
    static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    /// token 数的短格式：9806 / 2.4万 / 2.4亿
    static func tokens(_ v: Double) -> String {
        if v >= 1e8 { return String(format: "%.1f亿", v / 1e8) }
        if v >= 1e4 { return String(format: "%.1f万", v / 1e4) }
        return Int(v.rounded()).description
    }

    static func countdown(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 1 { return "不到1分钟" }
        if m < 60 { return "\(m)分钟" }
        let h = m / 60, mm = m % 60
        if h < 24 { return mm == 0 ? "\(h)小时" : "\(h)小时\(mm)分" }
        let d = h / 24, hh = h % 24
        return hh == 0 ? "\(d)天" : "\(d)天\(hh)小时"
    }

    static func clock(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let hm = f.string(from: d)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 99
        if days == 0 { return hm }
        if days == 1 { return "明天 " + hm }
        if days > 1 && days < 7 { return weekdays[cal.component(.weekday, from: d) - 1] + " " + hm }
        f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }

    static func reminderHint(_ window: QuotaWindow, status: ReminderStatus, now: Date) -> String? {
        guard window.used >= ResetReminders.threshold, let reset = window.resetsAt, reset > now else { return nil }
        switch status {
        case .off: return nil
        case .denied: return "通知没打开，恢复时没法提醒你（系统设置 → 通知 → AI 限额）"
        case .idle, .asking, .on: return (window.approx ? "大约" : "") + clock(reset, now: now) + " 恢复时会发通知提醒你"
        }
    }

    static func reset(_ w: QuotaWindow, now: Date) -> String {
        guard let r = w.resetsAt else { return w.note ?? "重置时间未知" }
        return (w.approx ? "约 " : "") + clock(r, now: now) + " 重置 · 还有 " + countdown(r.timeIntervalSince(now))
    }

    /// 面板里会话那一行右边的状态
    static func session(_ s: AgentSession, light: Light, now: Date) -> String {
        let t = now.timeIntervalSince(s.since)
        let d = t < 60 ? "" : countdown(t)
        switch light {
        case .running: return s.agentName + " · 运行中" + (d.isEmpty ? "" : " " + d)
        case .waiting: return s.agentName + " · 等你" + (d.isEmpty ? "" : " " + d)
        case .done: return s.agentName + (d.isEmpty ? " · 刚完成" : " · \(d)前完成")
        case .error: return s.agentName + " · 出错"
        case .idle: return s.agentName + " · 空闲"
        }
    }

    /// 触控栏展开后用的短时间：今天 17:40、明天09:10、周一11:55、10/23
    static func shortClock(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 99
        if days == 0 { return f.string(from: d) }
        if days == 1 { return "明天" + f.string(from: d) }
        if days > 1 && days < 7 { return weekdays[cal.component(.weekday, from: d) - 1] + f.string(from: d) }
        f.dateFormat = "M/d"
        return f.string(from: d)
    }

    /// 触控栏展开后额度那一行右边的字：用得太快时写照这速度什么时候用完（带颜色），否则写什么时候重置
    static func touchBarInfo(_ w: QuotaWindow, now: Date) -> (text: String, color: NSColor?) {
        if w.used >= 100, let reset = w.resetsAt, reset > now {
            return ((w.approx ? "约" : "") + short(reset.timeIntervalSince(now)) + "后恢复", .systemRed)
        }
        let pace = w.pace(at: now)
        if pace != .ok, let t = w.runsOut(at: now) { return (shortClock(t, now: now) + "用完", pace.color) }
        if let r = w.resetsAt { return ((w.approx ? "约" : "") + shortClock(r, now: now) + "重置", nil) }
        return (w.note ?? "", nil)
    }

    /// 触控栏上用的短时长：不到1分、12分、1时20分、2天3时
    static func short(_ t: TimeInterval) -> String {
        let m = Int(max(0, t) / 60)
        if m < 1 { return "不到1分" }
        if m < 60 { return "\(m)分" }
        let h = m / 60, mm = m % 60
        if h < 24 { return mm == 0 ? "\(h)时" : "\(h)时\(mm)分" }
        let d = h / 24, hh = h % 24
        return hh == 0 ? "\(d)天" : "\(d)天\(hh)时"
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    static func age(_ t: Date?, now: Date) -> String {
        guard let t else { return "暂无数据" }
        let m = now.timeIntervalSince(t) / 60
        if m < 1 { return "刚刚更新" }
        if m < 60 { return "\(Int(m))分钟前更新" }
        if m < 1440 { return "\(Int(m / 60))小时前更新" }
        return "\(Int(m / 1440))天前更新"
    }

    /// "周五 11:00" / "Fri 11:00" → 下一次这个时间
    static func nextWeekly(_ spec: String, after now: Date) -> Date? {
        let parts = spec.split(separator: " ").map(String.init)
        guard parts.count == 2 else { return nil }
        let days = [["sun", "周日", "周天", "星期日", "星期天"], ["mon", "周一", "星期一"], ["tue", "周二", "星期二"],
                    ["wed", "周三", "星期三"], ["thu", "周四", "星期四"], ["fri", "周五", "星期五"], ["sat", "周六", "星期六"]]
        let key = parts[0].lowercased()
        guard let idx = days.firstIndex(where: { names in
            names.contains { key == $0 || ($0.first?.isASCII == true && key.hasPrefix($0)) }
        }) else { return nil }
        let hm = parts[1].split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]) else { return nil }
        var comps = DateComponents()
        comps.weekday = idx + 1
        comps.hour = hm[0]
        comps.minute = hm[1]
        comps.second = 0
        return Calendar.current.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
    }
}

// MARK: - 登录时启动（LaunchAgent）

enum LoginItem {
    static let label = "local.aiquota.menubar"
    static var plistURL: URL { Setup.home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }     // 测试里在临时目录
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// 开机启动项指向的 app 已经不在了（app 挪了位置）：改成指向现在这份；原来那份还在就不抢
    static func retarget() {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = (plist["ProgramArguments"] as? [String])?.last, path != Bundle.main.bundlePath,
              !FileManager.default.fileExists(atPath: path) else { return }
        set(true)
    }

    static func set(_ on: Bool) {
        guard on else {
            try? FileManager.default.removeItem(at: plistURL)
            return
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL)
        }
    }
}

// MARK: - AI 会话状态（Claude Code / Codex 的 hooks 写进来）
// 每个会话一个 JSON 文件：~/Library/Application Support/AIQuota/sessions/<agent>-<会话 id>.json。
// 有会话在等你时另外放一个 .any-waiting 标记，每次工具调用后的 hook 先看它在不在，不在就不启动这个程序。

enum SessionState: String { case running, waiting, done, error, idle }

struct AgentSession {
    var agent: String          // claude / codex
    var id: String
    var state: SessionState
    var since: Date            // 进入当前状态的时间
    var updated: Date
    var first: Date            // 第一次出现，决定灯的先后顺序
    var title: String
    var bundle: String         // 点灯时切过去的 app
    var cwd = ""
    var waitReason = ""
    var transcript = ""
    var background = 0         // 主对话停了，后台还有几个工作流/子代理在跑
    var turnID: String?        // 这一轮的身份：主代理每次提交换一个（后台叫醒不换）
    var turnStart: Int?        // 这一轮开始时 transcript 有多少字节
    var turnInode: UInt64?     // 那时 transcript 是哪个文件（换了文件就对不上位置了）
    var turnRow: Int?          // ZCode 的：这一轮开始时会话库里最大的行号（它的记录在 db.sqlite 里，按行号分轮）
    var turnAt: Date?          // 这一轮什么时候开始
    var turnEndedAt: Date?     // 这一轮什么时候完成或出错
    var errorType = ""         // 主对话出错的类型（StopFailure 给的，比如 rate_limit、overloaded）
    var interrupted = false    // 你打断了这一轮（Claude 按 Esc 没有 hook，从 transcript 里认；Codex 有 Interrupt hook）
    var actions: [String] = [] // 这一轮最近做成的动作（新的在前，最多 3 条）：Windows 小乔拿它当思维链
    var resumeAt: Date?        // 被限流时，估计几点能继续（按 Claude 额度窗口的重置时间，AppModel 填）
    var resumeApprox = false

    var displayTitle: String {
        let clean = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        return clean.isEmpty ? agentName + " 任务" : clean
    }
    var projectName: String { cwd.isEmpty ? "未记录项目目录" : (cwd as NSString).lastPathComponent }
    var waitingLabel: String {
        switch waitReason {
        case "question": return "等你回答"
        case "permission": return "等你批准"
        default: return "等你处理"
        }
    }

    func briefStatus(_ light: Light, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        let age = minutes < 1 ? "刚刚" : minutes < 60 ? "\(minutes)分" : "\(minutes / 60)时\(minutes % 60)分"
        switch light {
        case .waiting: return waitingLabel + " · " + age
        case .running: return (background > 0 ? "后台 \(background) 个在跑 · " : "运行中 · ") + age
        case .done: return "已完成 · " + age
        case .error:
            switch errorType {
            case "rate_limit":
                guard let resumeAt else { return "被限流 · 稍后再试" }
                if resumeAt <= now { return "额度应已恢复 · 可以继续" }
                return "被限流 · " + (resumeApprox ? "约 " : "") + Fmt.shortClock(resumeAt, now: now) + " 恢复"
            case "server_error", "overloaded": return "服务器忙 · " + age
            case "max_output_tokens": return "长度超限停了 · " + age
            case "authentication_failed": return "登录失效 · " + age
            case "billing_error": return "账单出问题 · " + age
            default: return "出错 · " + age
            }
        case .idle: return interrupted ? "你打断了 · " + age : "最近任务"
        }
    }

    var key: String { agent + "-" + id }
    var agentName: String {
        switch agent {
        case "codex": return "Codex"
        case "zcode": return "ZCode"
        default: return "Claude"
        }
    }
    var appBundle: String {
        if !bundle.isEmpty { return bundle }
        switch agent {
        case "codex": return "com.openai.codex"
        case "zcode": return "dev.zcode.app"
        default: return "com.anthropic.claudefordesktop"
        }
    }
}

enum SessionFiles {
    static let dir = AppConfig.dir.appendingPathComponent("sessions")
    static var marker: URL { marker(in: dir) }
    static var logURL: URL { dir.appendingPathComponent("hooks.log") }
    static func marker(in folder: URL) -> URL { folder.appendingPathComponent(".any-waiting") }

    static func url(_ key: String, in folder: URL = dir) -> URL { folder.appendingPathComponent(key + ".json") }

    /// Claude 桌面 app 把收编的 CLI 会话存成 claude-code-sessions/<装机>/<组织>/local_<id>.json。
    /// 只按文件名找（最多两层目录，不读内容）；目录不存在就是没收编
    static func claudeAdopted(_ id: String) -> Bool {
        let fm = FileManager.default
        let root = expand("~/Library/Application Support/Claude/claude-code-sessions")
        let name = "local_" + id + ".json"
        for install in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = root + "/" + install
            if fm.fileExists(atPath: dir + "/" + name) { return true }
            for org in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where fm.fileExists(atPath: dir + "/" + org + "/" + name) { return true }
        }
        return false
    }

    static func safe(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// hook 进程之间（和清理旧文件时）用同一把锁，读-改-写不会互相覆盖
    static func withLock<T>(in folder: URL = dir, wait: Bool = true, _ body: () -> T) -> T? {
        let fd = open(folder.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_EXLOCK | (wait ? 0 : O_NONBLOCK), 0o644)
        guard fd >= 0 else { return wait ? body() : nil }
        defer { close(fd) }
        return body()
    }

    static func records(in folder: URL = dir) -> [(url: URL, rec: [String: Any])] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { u in
            guard let data = try? Data(contentsOf: u),
                  let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (u, rec)
        }
    }

    static func session(_ r: [String: Any]) -> AgentSession? {
        guard let agent = r["agent"] as? String, let id = r["id"] as? String,
              let state = SessionState(rawValue: r["state"] as? String ?? ""),
              let updated = num(r["updated"]) else { return nil }
        let date = { (k: String) in num(r[k]).map { Date(timeIntervalSince1970: $0) } ?? Date(timeIntervalSince1970: updated) }
        return AgentSession(agent: agent, id: id, state: state, since: date("since"), updated: date("updated"),
                            first: date("first"), title: r["title"] as? String ?? "", bundle: r["bundle"] as? String ?? "",
                            cwd: r["cwd"] as? String ?? "", waitReason: r["waitReason"] as? String ?? "",
                            transcript: r["transcript"] as? String ?? "", background: (r["background"] as? NSNumber)?.intValue ?? 0,
                            turnID: r["turnID"] as? String, turnStart: (r["turnStart"] as? NSNumber)?.intValue,
                            turnInode: (r["turnInode"] as? NSNumber)?.uint64Value,
                            turnRow: (r["turnRow"] as? NSNumber)?.intValue,
                            turnAt: num(r["turnAt"]).map { Date(timeIntervalSince1970: $0) },
                            turnEndedAt: num(r["turnEndedAt"]).map { Date(timeIntervalSince1970: $0) },
                            errorType: r["errorType"] as? String ?? "",
                            interrupted: r["interrupted"] as? Bool ?? false,
                            actions: r["actions"] as? [String] ?? [])
    }

    /// 读出所有会话，顺手整理（在锁里做，锁被 hook 占着就等下次）：
    /// - 3 天没动静的删掉（会话没正常结束留下的）
    /// - 已经过去的「等你」改成空闲（见 waitingSettled）
    /// - 没人在等时去掉 .any-waiting
    static func load(now: Date) -> [AgentSession] {
        var all = records()
        let t = now.timeIntervalSince1970
        let old = all.filter { t - (num($0.rec["updated"]) ?? 0) > 3 * 86400 }
        let settled = all.filter { waitingSettled($0.rec, now: t) }
        let interrupted = all.filter { interruptedSettled($0.rec, now: t) != nil }
        let waiting = all.contains { $0.rec["state"] as? String == SessionState.waiting.rawValue }
        if !old.isEmpty || !settled.isEmpty || !interrupted.isEmpty || (!waiting && FileManager.default.fileExists(atPath: marker.path)) {
            let tidied = withLock(wait: false) { () -> Bool in
                for o in old { try? FileManager.default.removeItem(at: o.url) }
                for o in settled {
                    // 锁里重新读一次，hook 可能刚改过
                    guard var rec = (try? Data(contentsOf: o.url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                          waitingSettled(rec, now: t) else { continue }
                    rec["state"] = SessionState.idle.rawValue
                    rec["since"] = t
                    rec.removeValue(forKey: "waitAgent")
                    if let data = try? JSONSerialization.data(withJSONObject: rec) { try? data.write(to: o.url, options: .atomic) }
                }
                for o in interrupted {
                    guard var rec = (try? Data(contentsOf: o.url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                          let marked = interruptedSettled(rec, now: t) else { continue }
                    // 按打断的那一刻算（app 没开着时发生的、很久以前的打断，不会被当成「刚刚」重新亮灯）
                    let at = min(t, marked.timeIntervalSince1970)
                    rec["state"] = SessionState.idle.rawValue
                    rec["since"] = at
                    rec["updated"] = at
                    rec["interrupted"] = true
                    rec.removeValue(forKey: "background")
                    rec.removeValue(forKey: "waitAgent")
                    rec.removeValue(forKey: "waitReason")
                    if let data = try? JSONSerialization.data(withJSONObject: rec) { try? data.write(to: o.url, options: .atomic) }
                    SessionHook.log("\(Fmt.stamp(now)) claude \((rec["id"] as? String ?? "").prefix(8)) transcript 里是 Esc 打断 → idle", in: dir)
                }
                SessionHook.updateMarker()
                return true
            }
            if tidied != nil { all = records() }
        }
        return all.compactMap { session($0.rec) }.filter { now.timeIntervalSince($0.updated) <= 3 * 86400 }
    }

    static let interruptMarker = "[Request interrupted by user"
    /// 打断之后可能跟着的、不算「对话」的行：本地斜杠命令和 ! 命令的记录
    static let commandPrefixes = ["<command-name>", "<local-command-", "<bash-input>", "<bash-stdout>", "<bash-stderr>"]

    /// Claude 里按 Esc 打断（或在权限弹窗里拒绝）没有 hook：在跑或在等你的 Claude 会话，看 transcript 最后一段——
    /// 最后一条对话是「[Request interrupted by user…]」，并且这一句比会话最后一次变状态还晚，就是你打断了。返回打断的时间。
    /// 后台的子代理、工作流最近 60 秒还在写的不算（桌面 app 里按 Esc 只停主对话，后台照跑，干完会把它叫醒）
    static func interruptedSettled(_ rec: [String: Any], now: TimeInterval) -> Date? {
        guard rec["agent"] as? String == "claude", let path = rec["transcript"] as? String, !path.isEmpty else { return nil }
        let state = rec["state"] as? String
        let updated = num(rec["updated"]) ?? now
        let since = num(rec["since"]) ?? updated
        let waitAgent = rec["waitAgent"] as? String ?? ""
        let floor: TimeInterval
        switch state {
        case SessionState.running.rawValue:
            guard now - updated > 10 else { return nil }            // 刚有过事件：先不看
            floor = updated - 1
        case SessionState.waiting.rawValue:
            floor = waitAgent.isEmpty ? since - 10 : since          // 权限通知比弹窗晚几秒才到
        default:
            return nil
        }
        guard let marked = interruptTime(path), marked.timeIntervalSince1970 >= floor, !backgroundActive(path, now: now) else { return nil }
        return marked
    }

    /// 只读最后 64KB，从后往前找第一条算数的对话（跳过子代理、isMeta、元数据行、斜杠命令和 ! 命令的记录、系统补的空回复），
    /// 是打断标记就返回它的时间（没有时间戳就用 transcript 的修改时间）
    static func interruptTime(_ path: String, tail: Int = 64 * 1024) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tail) ? size - UInt64(tail) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { continue }
            if type == "assistant" {
                if message["model"] as? String == "<synthetic>" { continue }
                return nil
            }
            let text: String
            if let string = message["content"] as? String {
                text = string
            } else {
                let blocks = message["content"] as? [[String: Any]] ?? []
                guard blocks.allSatisfy({ $0["type"] as? String == "text" }), let first = blocks.first?["text"] as? String else { return nil }
                text = first
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if commandPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
            guard trimmed.hasPrefix(interruptMarker) else { return nil }
            if let stamp = object["timestamp"] as? String, let date = parseStamp(stamp) { return date }
            return (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        }
        return nil
    }

    static func parseStamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// 这个会话的子代理、工作流（transcript 旁边同名目录下的 subagents）最近 60 秒还在写
    static func backgroundActive(_ path: String, now: TimeInterval) -> Bool {
        let folder = URL(fileURLWithPath: (path as NSString).deletingPathExtension).appendingPathComponent("subagents")
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return false }
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now - modified.timeIntervalSince1970 < 60 { return true }
        }
        return false
    }

    /// 这条「等你」是不是已经过去了：超过 12 小时；或者是主代理在等，而 transcript 在那之后又写过、并且已经安静了 30 秒——
    /// 多半是你拒绝了权限或按 Esc 取消了提问，Claude 这种情况没有 hook。批准后工具跑完会先触发 PostToolUse，轮不到这里。
    static func waitingSettled(_ rec: [String: Any], now: TimeInterval) -> Bool {
        guard rec["state"] as? String == SessionState.waiting.rawValue else { return false }
        let since = num(rec["since"]) ?? num(rec["updated"]) ?? 0
        if now - since > SessionHook.waitingExpiry { return true }
        guard (rec["waitAgent"] as? String ?? "").isEmpty, let path = rec["transcript"] as? String,
              let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date else { return false }
        let m = modified.timeIntervalSince1970
        return m > since + 3 && now - m > 30
    }
}

/// `AIQuota --hook claude|codex`：由 hooks 调用，从标准输入读事件，更新这个会话的状态文件。
/// 不往标准输出写任何东西（UserPromptSubmit 的输出会被当成上下文交给模型），出什么错都安静退出。
enum SessionHook {
    /// Claude 的这些通知表示在等你（批准权限、回答 MCP 的提问等）
    static let waitingNotifications: Set<String> = ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"]

    /// ZCode 的会话库（分轮的行号、会话标题、token 记账都从这里来）
    static let zcodeDBPath = expand("~/.zcode/cli/db/db.sqlite")

    /// hook 运行时依赖的东西：生产用默认值，测试换成临时目录、固定时间和假的标题
    struct Environment {
        var dir = SessionFiles.dir
        var now = Date()
        var bundle = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        var zcodeDB = SessionHook.zcodeDBPath
        var title: (_ agent: String, _ id: String, _ transcript: String, _ cwd: String, _ prompt: String?, _ current: String?) -> String? = SessionHook.title
    }

    static func run(agentArg: String) {
        run(agentArg: agentArg, input: FileHandle.standardInput.readDataToEndOfFile())
    }

    static func run(agentArg: String, input: Data, env: Environment = Environment()) {
        guard let o = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let sid = o["session_id"] as? String, !sid.isEmpty,
              let event = o["hook_event_name"] as? String else { return }
        let transcript = o["transcript_path"] as? String ?? ""
        // 按 transcript 的位置认是谁调的，配置被别的工具原样搬过去也不会记错
        let agent = transcript.contains("/.codex/") ? "codex" : transcript.contains("/.claude/") ? "claude" : agentArg
        let now = env.now
        try? FileManager.default.createDirectory(at: env.dir, withIntermediateDirectories: true)

        _ = SessionFiles.withLock(in: env.dir) {
            let url = SessionFiles.url(agent + "-" + SessionFiles.safe(sid), in: env.dir)
            var rec = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let old = SessionState(rawValue: rec["state"] as? String ?? "")
            // 子代理的事件带 agent_id，主代理的不带；记住是谁在等，别让另一个代理的事件把等待清掉
            let agentId = o["agent_id"] as? String ?? ""
            let main = agentId.isEmpty
            let waitingFor = rec["waitAgent"] as? String ?? ""
            var new: SessionState?
            var detail = ""
            var waitReason = ""
            var prompt = o["prompt"] as? String
            var newTurn = false
            var background: Int?                   // 主代理 Stop 时的后台快照；nil 表示这次不更新
            switch event {
            case "UserPromptSubmit":
                new = .running
                // 主代理每次提交都是新的一轮。例外：系统发来的任务通知（<task-notification> 开头，后台命令、工作流、子代理干完了）
                // 在这一轮还在跑（或在等你）的时候来，不是你说了新的话，接着算这一轮，不然起点会被一次次往后挪，
                // 路线图、本轮小票、「做完叫我」都会断。hook 输入里没有「事件来源」字段，只能看这个开头；
                // 万一你在任务还在跑时自己粘贴了一句以它开头的话，也会被并进这一轮（没有别的影响）
                let tagged = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<task-notification>")
                if tagged { prompt = nil }         // 也别拿它当会话名
                if main {
                    let continuing = tagged && (old == .running || old == .waiting) && rec["turnID"] != nil
                    newTurn = !continuing
                    // 主代理在等你（没有子代理在等）时通知来了，说明它已经在处理这条消息、不再卡在弹窗上：橙灯不能一直挂着（真实日志里会挂满 12 小时）；
                    // 是子代理的弹窗在等你的，照旧等
                    if continuing && old == .waiting && !waitingFor.isEmpty { new = nil }
                }
            case "PreToolUse":
                if o["tool_name"] as? String == "AskUserQuestion" { new = .waiting; waitReason = "question" }
            case "Notification":
                detail = o["notification_type"] as? String ?? ""
                let message = (o["message"] as? String ?? "").lowercased()
                if waitingNotifications.contains(detail) || (detail.isEmpty && message.contains("permission")) {
                    new = .waiting
                    waitReason = detail == "permission_prompt" || message.contains("permission") ? "permission" : "question"
                }
            case "PermissionRequest":
                // Codex 和 ZCode 只有这个事件表示等你批准；Claude 在 auto 模式下不一定真的弹窗，只记日志，以通知为准
                if agent != "claude" { new = .waiting; waitReason = "permission" }
            case "PostToolUse", "PostToolUseFailure":
                // ZCode 在你打断时也发 PostToolUseFailure，带着 is_interrupt——记成「你打断了」
                if event == "PostToolUseFailure", agent == "zcode", o["is_interrupt"] as? Bool == true {
                    new = .idle
                } else if old == .waiting && agentId == waitingFor { new = .running }   // 你批准或回答了，接着干活
            case "Stop":
                // 子代理的 Stop 不结束主会话；主代理跑完了、但还有子代理的弹窗在等你：继续亮橙灯
                guard main, !(old == .waiting && !waitingFor.isEmpty) else { break }
                // 工作流、子代理还在后台跑：还算在跑，要等之后主代理再停一次、而且后台清空了才算完成。
                // 这次没带快照（或者格式不对）时沿用上次知道的，不当成「后台已经清空」
                let known = (rec["background"] as? NSNumber)?.intValue ?? 0
                let count = backgroundWork(o["background_tasks"]) ?? known
                background = count
                new = count > 0 ? .running : .done
                if count > 0 { detail = "后台 \(count) 个" }
            case "StopFailure":
                detail = o["error_type"] as? String ?? o["error"] as? String ?? ""
                // 子代理被限流、出错（带 agent_id）：主对话会自己处理，不把整条任务标红
                if main { new = .error }
            case "Interrupt":
                new = .idle   // Codex 里你打断了这一轮，你自己知道，不用亮灯
            case "SessionEnd":
                try? FileManager.default.removeItem(at: url)
                updateMarker(in: env.dir, now: now)
                log("\(Fmt.stamp(now)) \(agent) \(sid.prefix(8)) SessionEnd → 删除", in: env.dir)
                return
            default:
                break
            }
            let mode = o["permission_mode"] as? String ?? "-"
            let who = agentId.isEmpty ? "" : " agent=\(agentId.prefix(8))"
            // 主代理每做成一个动作，往状态文件里记一笔（新的在前，最多 3 条）：Windows 小乔拿它当思维链。
            // 子代理的不记（和路线图一个口径），TodoWrite 是计划不是动作，也不记。
            // 状态不变也要写文件——动作是在干活的过程中一个个长出来的，不能等状态换才落盘
            var acted = false
            if event == "PostToolUse", main, let name = o["tool_name"] as? String, name != "TodoWrite" {
                let action = RoadmapBuilder.classify(name: name, input: o["tool_input"] as? [String: Any] ?? [:])
                let line = RoadmapBuilder.verb(action.kind) + (action.object.isEmpty ? "" : " " + action.object)
                var list = rec["actions"] as? [String] ?? []
                list.insert(line, at: 0)
                rec["actions"] = Array(list.prefix(3))
                acted = true
            }
            guard let new else {
                if acted {
                    if let data = try? JSONSerialization.data(withJSONObject: rec) { try? data.write(to: url, options: .atomic) }
                    log("\(Fmt.stamp(now)) \(agent) \(sid.prefix(8))\(who) \(event) → 动作+1（状态不变）", in: env.dir)
                } else {
                    log("\(Fmt.stamp(now)) \(agent) \(sid.prefix(8)) mode=\(mode)\(who) \(event) \(detail) → 不变（\(old?.rawValue ?? "无记录")）", in: env.dir)
                }
                return
            }

            let t = now.timeIntervalSince1970
            if rec["first"] == nil { rec["first"] = t }
            if new != old { rec["since"] = t }
            rec["agent"] = agent
            rec["id"] = sid
            rec["state"] = new.rawValue
            rec["updated"] = t
            if new == .waiting { rec["waitAgent"] = agentId } else { rec.removeValue(forKey: "waitAgent") }
            if new == .waiting {
                if !waitReason.isEmpty { rec["waitReason"] = waitReason }
            } else {
                rec.removeValue(forKey: "waitReason")
            }
            if newTurn {
                // 新的一轮：换一个身份，记下开始时间和这一轮从哪读起。
                // Claude/Codex 记 transcript 当时的字节数（本轮小票、路线图只看这之后的）；
                // ZCode 的记录在它的会话库里，记当时最大的行号
                rec["turnID"] = UUID().uuidString
                rec["turnAt"] = t
                if agent == "zcode" {
                    if let row = ZcodeRoad.maxRow(db: env.zcodeDB, session: sid) { rec["turnRow"] = row } else { rec.removeValue(forKey: "turnRow") }
                    rec.removeValue(forKey: "turnStart")
                    rec.removeValue(forKey: "turnInode")
                } else {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: transcript)
                    if let size = attributes?[.size] as? NSNumber { rec["turnStart"] = size.intValue } else { rec.removeValue(forKey: "turnStart") }
                    if let inode = attributes?[.systemFileNumber] as? NSNumber { rec["turnInode"] = inode.uint64Value } else { rec.removeValue(forKey: "turnInode") }
                    rec.removeValue(forKey: "turnRow")
                }
                rec.removeValue(forKey: "turnEndedAt")
                rec.removeValue(forKey: "background")
                rec.removeValue(forKey: "actions")   // 新的一轮：动作记录清空（思维链只画这一轮的）
            }
            if let background {
                if background > 0 { rec["background"] = background } else { rec.removeValue(forKey: "background") }
            }
            // 出错的类型只留短的枚举值（rate_limit 这种），不留详细信息
            let kind = detail.filter { $0.isASCII && ($0.isLetter || $0 == "_") }.prefix(40)
            if new == .error, main, event == "StopFailure", !kind.isEmpty { rec["errorType"] = String(kind) }
            else if new != .error { rec.removeValue(forKey: "errorType") }
            // Codex 有打断的 hook、ZCode 的打断带在 PostToolUseFailure 里：都和 Claude 按 Esc 一样记成「你打断了」
            //（卡片上这么写，订阅悄悄作废）；别的事件来了就不再是
            if event == "Interrupt" || (event == "PostToolUseFailure" && o["is_interrupt"] as? Bool == true) {
                rec["interrupted"] = true
            } else {
                rec.removeValue(forKey: "interrupted")
            }
            if main, new == .done || new == .error, old != new || rec["turnEndedAt"] == nil { rec["turnEndedAt"] = t }
            if !transcript.isEmpty { rec["transcript"] = transcript }
            let cwd = o["cwd"] as? String ?? rec["cwd"] as? String ?? ""
            rec["cwd"] = cwd
            if let b = env.bundle, !b.isEmpty { rec["bundle"] = b }
            if event == "UserPromptSubmit" || event == "Stop",
               let title = env.title(agent, sid, transcript, cwd, prompt, rec["title"] as? String) {
                rec["title"] = title
            }
            if let data = try? JSONSerialization.data(withJSONObject: rec) { try? data.write(to: url, options: .atomic) }
            if new == .waiting || old == .waiting { updateMarker(in: env.dir, now: now) }
            log("\(Fmt.stamp(now)) \(agent) \(sid.prefix(8)) mode=\(mode)\(who) \(event) \(detail) → \(new.rawValue)", in: env.dir)
            return
        }
    }

    /// 等待超过这么久就不算了（会话没正常结束留下的），灯不亮，也不再让每次工具调用都启动这个程序
    static let waitingExpiry: TimeInterval = 12 * 3600

    /// Stop 事件里的 background_tasks：还在排队或在跑的工作流、子代理有几个。
    /// 后台 shell（可能是一直开着的服务器）、监视器、MCP 任务不算，不然灯会一直停在「在跑」
    static let backgroundKinds: Set<String> = ["subagent", "workflow", "teammate", "cloud session"]

    /// nil：这次没带快照，或者格式不对（有一项缺 type 或 status 就算坏的，看不出还在不在跑）；空数组是 0
    static func backgroundWork(_ value: Any?) -> Int? {
        guard let tasks = value as? [[String: Any]],
              tasks.allSatisfy({ $0["type"] is String && $0["status"] is String }) else { return nil }
        return tasks.filter {
            backgroundKinds.contains($0["type"] as? String ?? "") && ["running", "pending"].contains($0["status"] as? String ?? "")
        }.count
    }

    static func updateMarker(in folder: URL = SessionFiles.dir, now date: Date = Date()) {
        let now = date.timeIntervalSince1970
        let waiting = SessionFiles.records(in: folder).contains {
            $0.rec["state"] as? String == SessionState.waiting.rawValue && now - (num($0.rec["updated"]) ?? 0) < waitingExpiry
        }
        if waiting {
            FileManager.default.createFile(atPath: SessionFiles.marker(in: folder).path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: SessionFiles.marker(in: folder))
        }
    }

    /// 会话名：Claude 用桌面 app 起的标题，Codex 用它自己的线程名，ZCode 用它会话库里的标题；
    /// 都没有时用项目文件夹名，临时文件夹就用第一句话
    static func title(agent: String, id: String, transcript: String, cwd: String, prompt: String?, current: String?) -> String? {
        if agent == "claude", let t = claudeTitle(transcript) { return t }
        if agent == "codex", let t = codexTitle(ids: [id, codexThreadId(transcript)].compactMap { $0 }) { return t }
        if agent == "zcode", let t = ZcodeRoad.title(db: zcodeDBPath, session: id) { return t }
        if let c = current, !c.isEmpty { return nil }
        if !cwd.isEmpty, cwd != NSHomeDirectory(), !cwd.contains("/scratch-workspaces/") {
            return (cwd as NSString).lastPathComponent
        }
        guard let line = prompt?.split(whereSeparator: \.isNewline).first else { return nil }
        let s = line.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : String(s.prefix(40))
    }

    static func tailLines(_ path: String, bytes: UInt64) -> [Substring] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    static func claudeTitle(_ transcript: String) -> String? {
        guard !transcript.isEmpty else { return nil }
        for line in tailLines(transcript, bytes: 256 * 1024).reversed() where line.contains("\"custom-title\"") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let t = o["customTitle"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    /// rollout-2026-09-24T19-41-35-<线程 id>.jsonl → 线程 id
    static func codexThreadId(_ transcript: String) -> String? {
        let name = ((transcript as NSString).lastPathComponent as NSString).deletingPathExtension
        guard name.hasPrefix("rollout-"), name.count > 36 else { return nil }
        let id = String(name.suffix(36))
        return UUID(uuidString: id) == nil ? nil : id
    }

    static func codexTitle(ids: [String]) -> String? {
        for line in tailLines(expand("~/.codex/session_index.jsonl"), bytes: 512 * 1024).reversed() where ids.contains(where: { line.contains($0) }) {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let id = o["id"] as? String, ids.contains(id),
               let t = o["thread_name"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    /// 调试日志：只记事件名和状态变化，不记内容；超过 256KB 只留后一半。在锁里调用，一行一次 O_APPEND 写入
    static func log(_ line: String, in folder: URL = SessionFiles.dir) {
        let url = folder.appendingPathComponent("hooks.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 256 * 1024, let data = try? Data(contentsOf: url) {
            try? data.suffix(128 * 1024).write(to: url, options: .atomic)
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}

/// 触控栏上的一盏灯
enum Light {
    case running, waiting, done, error, idle

    var color: NSColor {
        switch self {
        case .waiting: return .systemOrange
        case .done: return .systemGreen
        case .error: return .systemRed
        case .running: return NSColor(white: 1, alpha: 0.5)
        case .idle: return NSColor(white: 1, alpha: 0.35)
        }
    }
    /// 需要你看一眼的状态，灯和文字都亮
    var loud: Bool { self == .waiting || self == .done || self == .error }

    /// 放不下时先留哪盏：等你 > 出错 > 刚完成 > 运行中 > 空闲
    var rank: Int {
        switch self {
        case .waiting: return 0
        case .error: return 1
        case .done: return 2
        case .running: return 3
        case .idle: return 4
        }
    }

    /// 按紧急程度排好的下标（同级按原来的先后）
    static func urgentFirst(_ lights: [Light]) -> [Int] {
        lights.indices.sorted { (lights[$0].rank, $0) < (lights[$1].rank, $1) }
    }
}

// MARK: - 歌词（Chrome 扩展送来的当前一句）

struct NowLyric {
    var site: String          // bilibili / youtube
    var title: String         // 歌名或视频标题
    var line: String          // 当前一句；两句之间的空档为空
    var next: String          // 下一句，可能为空
    var kind: String          // subtitle（视频自带字幕）/ lyrics（按歌名查到的歌词）
    var playing: Bool
    var received: Date

    /// 在放，而且最近 8 秒内收到过更新（扩展放着的时候每秒报一次）才算有词可看
    func active(at now: Date) -> Bool { playing && now.timeIntervalSince(received) < 8 }
}

// MARK: - Chrome 歌词桥
// Chrome 扩展（chrome/ 目录）用 native messaging 启动本程序，第一个参数是 chrome-extension://<扩展 id>/。
// 这时本程序只当传话的：一条条读 Chrome 发来的消息（4 字节长度 + JSON），原样用分布式通知转给正在运行的 AIQuota。
// 标准输出是 Chrome 的消息通道，一个字都不能写。只有 allowed_origins 里的这个扩展能启动它，网页碰不到。

enum LyricsBridge {
    static let hostName = "local.aiquota.lyrics"
    static let extensionID = "jiiacebehbpfkamopejggmcgockmdjja"   // 由 chrome/manifest.json 里的 key 算出来
    static let notification = Notification.Name("local.aiquota.lyric")

    static func runHost() {
        let input = FileHandle.standardInput
        let center = DistributedNotificationCenter.default()
        while true {
            let header = input.readData(ofLength: 4)
            guard header.count == 4 else { break }                          // Chrome 关掉了端口
            let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })   // 本机字节序
            guard length > 0, length < 64 * 1024 else { break }
            let body = input.readData(ofLength: length)
            guard body.count == length, let json = String(data: body, encoding: .utf8) else { break }
            center.postNotificationName(notification, object: nil, userInfo: ["json": json], deliverImmediately: true)
        }
        center.postNotificationName(notification, object: nil, userInfo: ["json": #"{"type":"none"}"#], deliverImmediately: true)
    }

    /// 告诉 Chrome 去哪找这个桥：~/Library/Application Support/Google/Chrome/NativeMessagingHosts/local.aiquota.lyrics.json
    static func installHostManifest(enabled: Bool) {
        let dir = URL(fileURLWithPath: expand("~/Library/Application Support/Google/Chrome/NativeMessagingHosts"))
        let file = dir.appendingPathComponent(hostName + ".json")
        guard enabled, let exe = Bundle.main.executablePath, Bundle.main.bundlePath.hasSuffix(".app") else {
            if !enabled { try? FileManager.default.removeItem(at: file) }
            return
        }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "AIQuota 触控栏歌词",
            "path": exe,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        if (try? Data(contentsOf: file)) == data { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - 两台电脑（Mac ⇄ Windows/WSL，经 Tailscale + SSH）
// 平时只看本机网卡上有没有 Tailscale 的地址（不开进程、不走网络）；开着时偶尔问一下本机的 tailscaled 那台 PC 在不在线。
// 从不定时 ssh；连接、检查线路、断开都是你在触控栏或菜单栏上点了才跑 ~/.local/bin/two-machine。app 永远不会自己连或断。

struct LinkCheck: Equatable {
    var at: Date
    var macToWSL: Bool?          // nil = 没走到这一步
    var wslToMac: Bool?
    var winToMac: Bool?
    var reason: String           // 失败时脚本给的原因（最后一行）

    var ok: Bool { macToWSL == true && wslToMac == true && winToMac == true }
    var summary: String {
        let mark = { (b: Bool?) in b == true ? "✓" : b == false ? "✗" : "–" }
        return "Mac→WSL \(mark(macToWSL))  WSL→Mac \(mark(wslToMac))  Win→Mac \(mark(winToMac))"
    }
}

struct LinkState: Equatable {
    enum Busy: Equatable { case connecting, checking, disconnecting }
    var available = false        // 装了 Tailscale 和 two-machine 脚本
    var on = false               // 本机 Tailscale 开着
    var since: Date?             // 这次开着是什么时候开始的（app 看到的时刻）
    var pcOnline: Bool?          // PC（win-wsl 节点）在不在线；nil = 还没问过或问不到
    var pcLastSeen: Date?
    var direct: Bool?            // true = 直连，false = 经中转
    var relay = ""
    var lastTraffic: Date?       // 和 PC 之间最后一次有流量的时刻（算空闲）
    var traffic: Int64 = -1
    var keyExpiry: Date?
    var detailAt: Date?          // 上次问 tailscaled 的时间
    var check: LinkCheck?        // 上次「检查线路」
    var busy: Busy?
    var error: String?           // 上次连接 / 断开失败的原因

    /// 空闲多久（开着、而且知道最后一次有流量的时间才有）
    func idle(at now: Date) -> TimeInterval? {
        guard on, let t = lastTraffic else { return nil }
        return now.timeIntervalSince(t)
    }
    /// 界面上写「空闲 N」的门槛：刚用过就不写
    func idleShown(at now: Date) -> TimeInterval? { idle(at: now).flatMap { $0 >= 5 * 60 ? $0 : nil } }
}

enum TwoMachine {
    static let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    static var script: String { expand("~/.local/bin/two-machine") }
    static var installed: Bool {
        FileManager.default.isExecutableFile(atPath: cli) && FileManager.default.isExecutableFile(atPath: script)
    }

    /// 本机网卡（utun）上有没有 100.64.0.0/10 的地址：只读网卡列表，约 15 微秒
    static func tailscaleUp() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: p.pointee.ifa_name).hasPrefix("utun") else { continue }
            let raw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if UInt32(bigEndian: raw) >> 22 == 401 { return true }        // 100.64/10：前 10 位是 0110010001
        }
        return false
    }

    struct Detail: Equatable {
        var running: Bool
        var pcOnline: Bool?
        var pcLastSeen: Date?
        var direct: Bool?
        var relay: String
        var traffic: Int64
        var keyExpiry: Date?
    }

    /// 解析 `tailscale status --json`；按主机名找 PC 那个节点（不取第一个）。格式官方说会变，解析不了的字段就当不知道
    static func parseDetail(_ data: Data, pcHost: String) -> Detail? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]    // tailscaled 有时带小数秒（…05:30:00.1Z）
        let date = { (v: Any?) -> Date? in
            guard let s = v as? String, let d = iso.date(from: s) ?? isoFrac.date(from: s), d.timeIntervalSince1970 > 0 else { return nil }
            return d
        }
        var detail = Detail(running: (o["BackendState"] as? String) == "Running", pcOnline: nil, pcLastSeen: nil,
                            direct: nil, relay: "", traffic: -1, keyExpiry: date((o["Self"] as? [String: Any])?["KeyExpiry"]))
        let want = pcHost.lowercased()
        let peers = (o["Peer"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        if let pc = peers.first(where: { ($0["HostName"] as? String)?.lowercased() == want
                                        || ($0["DNSName"] as? String)?.lowercased().hasPrefix(want + ".") == true }) {
            detail.pcOnline = pc["Online"] as? Bool
            detail.pcLastSeen = date(pc["LastSeen"])
            let cur = pc["CurAddr"] as? String ?? ""
            detail.direct = detail.pcOnline == true ? !cur.isEmpty : nil
            detail.relay = pc["Relay"] as? String ?? ""
            detail.traffic = ((pc["RxBytes"] as? NSNumber)?.int64Value ?? 0) + ((pc["TxBytes"] as? NSNumber)?.int64Value ?? 0)
        }
        return detail
    }

    /// 解析 `two-machine status/on` 的输出：成功的线路写在标准输出，失败的原因写在标准错误
    static func parseCheck(out: String, err: String, at: Date) -> LinkCheck {
        func line(_ ok: String, _ fail: String) -> Bool? {
            if out.contains(ok) { return true }
            if err.contains(fail) { return false }
            return nil
        }
        let reason = err.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        return LinkCheck(at: at,
                         macToWSL: line("Mac → Windows/WSL：正常", "Mac → Windows/WSL 失败"),
                         wslToMac: line("Windows/WSL → Mac：正常", "Windows/WSL → Mac 失败"),
                         winToMac: line("Windows 原生 → Mac：正常", "Windows 原生 → Mac 失败"),
                         reason: String(reason.prefix(120)))
    }

    struct Output { var status: Int32; var out: String; var err: String }

    /// 跑一个命令（带超时，输出最多 64KB）。测试里换成假的，免得真的去连或断
    nonisolated(unsafe) static var runner: (_ path: String, _ args: [String], _ env: [String: String], _ timeout: TimeInterval) async -> Output = { path, args, env, timeout in
        final class Sink: @unchecked Sendable { var data = Data(); var done = false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (e["PATH"] ?? "")
        env.forEach { e[$0.key] = $0.value }
        p.environment = e
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return Output(status: -1, out: "", err: error.localizedDescription) }
        // 两路输出在后台一直读着，输出再多也不会把命令卡住
        let o = Sink(), r = Sink()
        for (pipe, sink) in [(out, o), (err, r)] {
            DispatchQueue.global().async { sink.data = pipe.fileHandleForReading.readDataToEndOfFile(); sink.done = true }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        let timedOut = p.isRunning
        if timedOut { p.terminate() }
        let readDeadline = Date().addingTimeInterval(2)
        while !(o.done && r.done) && Date() < readDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        if timedOut { return Output(status: -2, out: "", err: "超时") }
        return Output(status: p.terminationStatus, out: String(decoding: o.data.prefix(65536), as: UTF8.self),
                      err: String(decoding: r.data.prefix(65536), as: UTF8.self))
    }

    static func detail(pcHost: String) async -> Detail? {
        let r = await runner(cli, ["status", "--json"], ["TAILSCALE_BE_CLI": "1"], 5)
        guard r.status == 0 else { return nil }
        return parseDetail(Data(r.out.utf8), pcHost: pcHost)
    }

    static func run(_ command: String, timeout: TimeInterval) async -> Output {
        await runner(script, [command], [:], timeout)
    }

    /// 本机现在有几个连着 win 的 ssh（断开前告诉你会断掉几个）
    static func sshSessions() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 0 }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").filter { line in
            let words = line.split(separator: " ").map(String.init)
            guard let cmd = words.first, cmd == "ssh" || cmd.hasSuffix("/ssh") else { return false }
            return words.dropFirst().contains("win")
        }.count
    }
}

// MARK: - 状态

@MainActor
final class AppModel: ObservableObject {
    @Published var claude = Provider(name: "Claude", detail: "桌面 app")
    @Published var codex: [Provider] = []
    @Published var zcode: Provider?          // ZCode 的本地 token 用量（没有 %，只有今日 / 近 7 天的记账数）
    @Published var now = Date()
    @Published var refreshing = false
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var sessions: [AgentSession] = []
    @Published var lyric: NowLyric?
    @Published var link = LinkState()
    @Published var shelf = Shelf()
    @Published var shelfNote: ShelfNote?
    @Published var reminderStatus: ReminderStatus = .idle
    @Published var handoffs: [HandoffNote] = []
    @Published var promptStore = PromptStore()
    @Published var promptNote: PromptNote?
    var promptNoteWork: DispatchWorkItem?
    var promptsFile = PromptStore.defaultURL
    var promptsDamaged = false
    @Published var promptEditorRequested = false
    @Published var customLights: [CustomLight] = []
    var lightsFolder = CustomLights.folder
    var lightsWatcher: DispatchSourceFileSystemObject?
    @Published var translation: TranslationState = .idle
    @Published var calm: CalmState = .none
    var calmWork: DispatchWorkItem?
    var calmVersion = 0
    var resumeMemo: [String: (at: Date, approx: Bool)] = [:]   // 被限流时估的恢复时间（会话 key@出错时间）
    // 工作流路线图（Roadmap.swift）：只在左边空位要画的时候读；按会话存解析结果
    var roadParses: [String: (turnID: String, tag: String, parse: RoadParse)] = [:]
    var roadPending: [String: String] = [:]
    var roadWanted: String?                 // 要画哪个 AI 的路线图（前台是谁）；nil 不读
    var roadWatch: DispatchSourceFileSystemObject?
    var roadWatchedPath: String?
    var roadThrottle: DispatchWorkItem?
    var roadLastRun = Date.distantPast
    var roadRun: (@escaping () -> Void) -> Void = { work in AppModel.roadQueue.async(execute: work) }
    @Published var ambientEnabled = UserDefaults.standard.object(forKey: "roadAmbient") as? Bool ?? true {
        didSet { UserDefaults.standard.set(ambientEnabled, forKey: "roadAmbient") }
    }
    // 本轮小票（Receipt.swift）：按会话 key 存，带着是哪一轮；正在读的记着请求标记
    @Published var receipts: [String: (turnID: String, slot: ReceiptSlot, tag: String)] = [:]
    var receiptPending: [String: String] = [:]
    var receiptRun: (@escaping () -> Void) -> Void = { work in AppModel.receiptQueue.async(execute: work) }
    static let receiptQueue = DispatchQueue(label: "local.aiquota.receipts", qos: .utility)
    // 做完叫我（Watch.swift）：只在内存里
    @Published var watched: [String: WatchTarget] = [:]
    @Published var petNews: PetNews?
    var allLights: [CustomLight] = []
    var watchReminder: ReminderCenter = SystemReminderCenter()
    var watchSound: (String) -> Void = { NSSound(named: $0)?.play() }
    var notificationsAllowed: (@escaping @MainActor (Bool) -> Void) -> Void = AppModel.systemNotificationsAllowed
    var onWatchFired: ((PetNews) -> Void)?
    var calmReminder: ReminderCenter = SystemReminderCenter()
    var focusLength: TimeInterval = Focus.length
    var restLength: TimeInterval = Focus.rest
    var onCalm: (() -> Void)?
    var calmChime: () -> Void = { NSSound(named: "Glass")?.play() }
    @Published var petEnabled = UserDefaults.standard.object(forKey: "petOnStrip") as? Bool ?? true {
        didSet { UserDefaults.standard.set(petEnabled, forKey: "petOnStrip") }
    }
    var translator: Translator = SystemTranslator()
    var translationRequest = 0
    var onTranslate: (() -> Void)?
    var handoffFolder = Relay.folderURL
    lazy var reminders: ReminderScheduler = {
        let scheduler = ReminderScheduler(center: SystemReminderCenter())
        scheduler.onStatus = { [weak self] in
            guard let self else { return }
            self.reminderStatus = self.reminders.status
        }
        return scheduler
    }()
    var shelfNoteWork: DispatchWorkItem?
    var pasteboard: NSPasteboard = .general
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var launchApp: @MainActor (String, @escaping @MainActor (LaunchResult) -> Void) -> Void = AppModel.launchBundle
    private var linkFetching = false
    private var linkObserved = false
    @Published var selectedSessionKey: String?
    @Published var actionMessage = ""
    @Published var actionSessionKey = ""
    @Published var copyingSessionKey: String?
    private(set) var config = AppConfig.load()
    private var lastFetch = Date.distantPast
    private var acked: [String: Date] = [:]   // 点过的绿灯
    private var sessionWatcher: DispatchSourceFileSystemObject?
    var onUpdate: (() -> Void)?

    var rows: [Provider] { [claude] + codex }

    /// 活跃任务优先，其余保留最近三天的项目入口。
    /// 被限流停下的 Claude 任务什么时候能继续：Claude 用到 95% 以上的那几个窗口里最晚重置的那个（推算的算「约」）；
    /// 没有窗口满（多半是临时限流）就不知道，写「稍后再试」
    /// 先看用满（100%）的窗口，没有才看快满（95% 以上）的；这些窗口里只要有一个不知道什么时候重置（比如没配每周重置时间），就说不准
    func resumeEstimate(now: Date) -> (at: Date, approx: Bool, window: String)? {
        let windows = claude.windows.map { $0.effective(at: now) }
        let full = windows.filter { $0.used >= 100 }
        let candidates = full.isEmpty ? windows.filter { $0.used >= ResetReminders.threshold } : full
        guard !candidates.isEmpty, candidates.allSatisfy({ ($0.resetsAt ?? .distantPast) > now }),
              let latest = candidates.max(by: { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }), let at = latest.resetsAt else { return nil }
        return (at, latest.approx, latest.label)
    }

    /// 被限流停下的那一次估出来的恢复时间记住（按会话和出错时间）：过了重置时间窗口数据会清零、再也估不出来，
    /// 这时要说「额度应已恢复」，不能说「稍后再试」
    func annotated(_ session: AgentSession, now: Date) -> AgentSession {
        guard session.agent == "claude", session.state == .error, session.errorType == "rate_limit" else { return session }
        let memo = session.key + "@" + String(session.since.timeIntervalSince1970)
        if let resume = resumeEstimate(now: now) { resumeMemo[memo] = (resume.at, resume.approx) }
        guard let resume = resumeMemo[memo] else { return session }
        var out = session
        out.resumeAt = resume.at
        out.resumeApprox = resume.approx
        return out
    }

    func tasks(at now: Date) -> [(session: AgentSession, light: Light)] {
        sessions.map { (annotated($0, now: now), light(for: $0, now: now) ?? .idle) }.sorted {
            if $0.1.rank != $1.1.rank { return $0.1.rank < $1.1.rank }
            if $0.0.updated != $1.0.updated { return $0.0.updated > $1.0.updated }
            return $0.0.key < $1.0.key
        }
    }

    /// 监视会话状态目录，hooks 一写进来就更新（不轮询）
    /// Chrome 扩展经桥送来的一条：{type: lyric|none, site, title, line, next, kind, playing}
    func receiveLyric(_ o: [String: Any]) {
        guard config.lyrics else { return }
        let old = lyric
        if o["type"] as? String == "lyric" {
            let clip = { (k: String, n: Int) in String((o[k] as? String ?? "").prefix(n)) }
            lyric = NowLyric(site: clip("site", 20), title: clip("title", 120), line: clip("line", 300), next: clip("next", 300),
                             kind: clip("kind", 20), playing: o["playing"] as? Bool ?? false, received: Date())
        } else {
            lyric = nil
        }
        // 心跳只刷新收到时间；内容或播放状态变了才重画
        if old?.line != lyric?.line || old?.next != lyric?.next || old?.playing != lyric?.playing || old?.title != lyric?.title || (old == nil) != (lyric == nil) {
            now = Date()
            onUpdate?()
        }
    }

    func watchSessions() {
        try? FileManager.default.createDirectory(at: SessionFiles.dir, withIntermediateDirectories: true)
        reloadSessions()
        let fd = Darwin.open(SessionFiles.dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                self.reloadSessions()
                self.onUpdate?()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sessionWatcher = source
    }

    func reloadSessions() {
        sessions = SessionFiles.load(now: Date())
        reloadHandoffs()
        reloadLights()                                      // 里面会看「做完叫我」
        updateReceipts()
        syncRoadWatch()
        refreshRoadmaps()
    }

    /// 要亮的灯，按会话第一次出现的先后排，位置不跳
    func lights(at now: Date) -> [(session: AgentSession, light: Light)] {
        sessions.sorted { $0.first < $1.first }.compactMap { s in light(for: s, now: now).map { (annotated(s, now: now), $0) } }
    }

    /// 等你和出错一直亮；刚完成亮绿灯 20 分钟（点过就灭）；之后显示成空闲，一小时没动静就不显示
    func light(for s: AgentSession, now: Date) -> Light? {
        let quiet = now.timeIntervalSince(s.updated)
        switch s.state {
        case .waiting:
            if quiet >= SessionHook.waitingExpiry { return nil }
            return .waiting  // 打开 app 不代表已经回答，等待由后续 hook 清除。
        case .error:
            // 被限流的：红灯亮到估计恢复之后半小时（等周额度可能要好几天），不只亮 2 小时
            if let resume = annotated(s, now: now).resumeAt { return now < max(s.updated.addingTimeInterval(2 * 3600), resume.addingTimeInterval(1800)) ? .error : nil }
            return quiet < 2 * 3600 ? .error : nil
        case .running: return quiet < 3 * 3600 ? .running : nil
        case .done:
            let seen = acked[s.key].map { $0 >= s.since } ?? false
            // 绿灯只算醒着的时间：用电池时任务一做完 Mac 很快就睡，按墙钟的话回来时早就灭了
            if !seen && Self.awakeInterval(since: s.since, until: now, asleep: asleepSpans) < 20 * 60 { return .done }
            return quiet < 3600 ? .idle : nil
        case .idle: return quiet < 3600 ? .idle : nil
        }
    }

    /// 睡着的时段（醒来的时间由 didWake 补上）。只留最近两天的：绿灯最多看 20 分钟
    var asleepSpans: [(start: Date, end: Date)] = []

    func didSleep(now: Date) {
        if let last = asleepSpans.last, last.end == last.start { return }   // 已经睡着（不该发生）
        asleepSpans.append((start: now, end: now))
        let cutoff = now.addingTimeInterval(-48 * 3600)
        asleepSpans.removeAll { $0.end < cutoff }
    }

    func closeAsleepSpan(at now: Date) {
        guard var last = asleepSpans.last, last.end == last.start else { return }
        last.end = max(now, last.start)
        asleepSpans[asleepSpans.count - 1] = last
    }

    /// [since, until] 里醒着的时间：总长减去和睡着时段重叠的部分。
    /// end == start 的是还没醒来的那段（理论上只在睡着时出现，防御性地算到 until）
    static func awakeInterval(since: Date, until: Date, asleep: [(start: Date, end: Date)]) -> TimeInterval {
        guard until > since else { return 0 }
        let total = until.timeIntervalSince(since)
        var sleeping: TimeInterval = 0
        for span in asleep {
            let s = max(span.start, since)
            let e = min(span.end == span.start ? until : span.end, until)
            if e > s { sleeping += e.timeIntervalSince(s) }
        }
        return total - min(sleeping, total)
    }

    /// Claude 桌面 app 收编了哪些 CLI 会话；测试里换掉
    var claudeAdopted: (String) -> Bool = { SessionFiles.claudeAdopted($0) }

    /// 点任务要打开的链接。Claude 的 CLI 会话（id 是合法 UUID）用桌面 app 的深链接直达：
    /// 已收编进 app 的用 code/continue 跳转（resume 对已收编的会话只报错不跳），还没收编的用 resume 导入并打开
    func threadURLToOpen(_ s: AgentSession) -> URL? {
        guard s.agent == "claude", s.appBundle == "com.anthropic.claudefordesktop", UUID(uuidString: s.id) != nil else { return s.threadURL }
        return URL(string: (claudeAdopted(s.id) ? "claude://code/continue?session=local_" : "claude://resume?session=") + s.id)
    }

    /// 打开成功后确认绿灯；橙灯保留到实际回答/批准。
    func open(_ key: String) {
        guard let s = sessions.first(where: { $0.key == key }) else { return }
        if let url = threadURLToOpen(s), openURL(url) {
            if s.state == .done { acked[key] = s.since }
            onUpdate?()
            return
        }
        launchApp(s.appBundle) { [weak self] result in
            guard let self else { return }
            switch result {
            case .opened: if s.state == .done { self.acked[key] = s.since }
            case .failed: self.feedback("无法打开 \(s.agentName)", key: key)
            case .missing: self.feedback("未找到这个任务对应的 app", key: key)
            }
            self.onUpdate?()
        }
    }

    enum LaunchResult { case opened, failed, missing }

    static func launchBundle(_ bundle: String, done: @escaping @MainActor (LaunchResult) -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            done(.missing)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            let opened = app != nil && error == nil
            Task { @MainActor in done(opened ? .opened : .failed) }
        }
    }

    func feedback(_ text: String, key: String) {
        actionSessionKey = key
        actionMessage = text
        onUpdate?()
    }

    func projectAction(_ action: ProjectAction, key: String) {
        guard let s = sessions.first(where: { $0.key == key }) else { return }
        switch action {
        case .folder:
            feedback(ProjectActions.openFolder(s.cwd) ? "已打开项目文件夹" : "项目目录不存在", key: key)
        case .terminal:
            Task { @MainActor in
                let ok = await ProjectActions.openTerminal(s.cwd)
                feedback(ok ? "已打开项目终端" : "无法打开终端，请检查项目目录", key: key)
            }
        case .handoff:
            guard copyingSessionKey == nil else { return }
            copyingSessionKey = key
            feedback("正在整理交接信息…", key: key)
            Task { @MainActor in
                let text = await ProjectActions.handoff(projectPath: s.cwd, title: s.displayTitle,
                    agentName: s.agentName, sessionID: s.id,
                    state: annotated(s, now: now).briefStatus(light(for: s, now: now) ?? .idle, now: now))
                NSPasteboard.general.clearContents()
                let ok = NSPasteboard.general.setString(text, forType: .string)
                copyingSessionKey = nil
                feedback(ok ? "已复制交接，可粘贴到另一个 AI" : "剪贴板写入失败，请重试", key: key)
            }
        }
    }

    func reloadClaude() {
        now = Date()
        claude = ClaudeHistory.load(path: config.claudeHistoryPath, weeklySpec: config.claudeWeeklyReset, now: now)
    }

    /// 距上次联网刷新不到 minInterval 秒就跳过
    func refreshAll(minInterval: TimeInterval = 0) async {
        if refreshing { return }
        if minInterval > 0 && Date().timeIntervalSince(lastFetch) < minInterval { return }
        refreshing = true
        config = AppConfig.load()
        reloadClaude()
        var results: [Provider] = []
        var seen = Set<String>()
        for (i, account) in config.codex.enumerated() {
            // 第一个之外的账号是可选的，登录文件不存在就跳过
            if i > 0 && !FileManager.default.fileExists(atPath: account.authPath) { continue }
            var r = await CodexAPI.fetch(account)
            r.staleAfter = max(300, 2.5 * config.refreshSeconds)
            if let id = r.accountId {
                if seen.contains(id) { continue }   // 同一账号只显示一次
                seen.insert(id)
            }
            // 临时出错时保留上一次的数据（会显示为过期）
            if r.error != nil, r.windows.isEmpty,
               let old = codex.first(where: { r.accountId != nil ? $0.accountId == r.accountId : $0.name == r.name }), !old.windows.isEmpty {
                r.windows = old.windows
                r.updatedAt = old.updatedAt
                r.detail = old.detail
            }
            results.append(r)
        }
        codex = results
        loadZcodeUsage()
        lastFetch = Date()
        now = Date()
        refreshing = false
        onUpdate?()
    }

    /// ZCode 的本地 token 用量：它的计划没有可查的额度接口，用会话库里每一轮的记账（turn_usage 表）
    /// 算今日（零点起）和近 7 天的输入+输出。库不在（没装 ZCode）就没有这一行
    func loadZcodeUsage() {
        guard FileManager.default.fileExists(atPath: SessionHook.zcodeDBPath) else {
            zcode = nil
            return
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let today = ZcodeRoad.tokens(db: SessionHook.zcodeDBPath, sinceMs: Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000))
        let week = ZcodeRoad.tokens(db: SessionHook.zcodeDBPath, sinceMs: nowMs - 7 * 86400 * 1000)
        guard let today, let week else { zcode = nil; return }
        var p = Provider(name: "ZCode", detail: "GLM · 本机记账")
        p.tokens = (today, week)
        p.updatedAt = Date()
        p.staleAfter = 10 * 60
        zcode = p
    }

    /// 两台电脑：每次都只看网卡（开没开）；开着时状态刚变、或者超过 maxAge 没问过，才问一次本机的 tailscaled
    func updateLink(forceDetail: Bool = false, maxAge: TimeInterval = 300) {
        guard config.twoMachine, TwoMachine.installed else {
            if link.available { link = LinkState() }
            return
        }
        link.available = true
        let on = TwoMachine.tailscaleUp()
        if on != link.on {
            link.on = on
            link.since = on && linkObserved ? Date() : nil             // app 启动时就开着：不知道开了多久，不瞎写
            link.detailAt = nil
            link.direct = nil
            link.lastTraffic = nil
            link.traffic = -1
            if !on { link.pcOnline = nil; link.check = nil }           // 关着时 PC 在不在线就不知道了，「上次在线」留着
        }
        linkObserved = true
        let stale = link.detailAt.map { Date().timeIntervalSince($0) > (forceDetail ? min(maxAge, 30) : maxAge) } ?? true
        guard on, stale, !linkFetching else { return }
        linkFetching = true
        let host = config.pcHost
        Task { @MainActor in
            let d = await TwoMachine.detail(pcHost: host)
            let sessions = TwoMachine.sshSessions()
            self.linkFetching = false
            let now = Date()
            self.link.detailAt = now
            guard let d, self.link.on else { self.link.pcOnline = nil; self.onUpdate?(); return }
            self.link.pcOnline = d.pcOnline
            if d.pcOnline == true { self.link.pcLastSeen = now } else if let seen = d.pcLastSeen { self.link.pcLastSeen = seen }
            self.link.direct = d.direct
            self.link.relay = d.relay
            self.link.keyExpiry = d.keyExpiry
            // 空闲：流量计数变了、或者本机还有连着 win 的 ssh，就算刚用过
            if d.traffic != self.link.traffic || sessions > 0 || self.link.lastTraffic == nil { self.link.lastTraffic = now }
            self.link.traffic = d.traffic
            self.now = now
            self.onUpdate?()
        }
    }

    enum LinkAction { case connect, check, disconnect, terminal }

    /// 你在触控栏或菜单栏上点了才跑；app 自己永远不连也不断
    func linkAction(_ action: LinkAction) {
        guard link.available else { return }
        switch action {
        case .terminal:
            if let url = URL(string: "ssh://win") { NSWorkspace.shared.open(url) }   // 终端里开 ssh win（用 ~/.ssh/config 里的设置）
            return
        case .connect, .check, .disconnect:
            guard link.busy == nil else { return }
        }
        let command: String, timeout: TimeInterval
        switch action {
        case .connect: link.busy = .connecting; command = "on"; timeout = 45
        case .check: link.busy = .checking; command = "status"; timeout = 30
        default: link.busy = .disconnecting; command = "off"; timeout = 20
        }
        link.error = nil
        onUpdate?()
        Task { @MainActor in
            let r = await TwoMachine.run(command, timeout: timeout)
            let check = TwoMachine.parseCheck(out: r.out, err: r.err, at: Date())
            self.link.busy = nil
            switch action {
            case .connect, .check:
                if check.macToWSL != nil { self.link.check = check }
                if r.status != 0 && check.macToWSL == nil {
                    self.link.error = r.status == -2 ? "超时" : (check.reason.isEmpty ? "没连上" : check.reason)
                }
            default:
                if r.status != 0 { self.link.error = r.status == -2 ? "断开超时" : (check.reason.isEmpty ? "断开失败" : check.reason) }
            }
            self.updateLink(forceDetail: true, maxAge: 0)
            self.onUpdate?()
        }
    }

    func syncReminders() {
        // 只算还亮着红灯、估得出恢复时间的（很久以前被限流、早就放下的不算）
        let now = Date()
        let blocked = sessions.filter { $0.agent == "claude" && $0.state == .error && $0.errorType == "rate_limit" && light(for: $0, now: now) == .error }
            .sorted { $0.since > $1.since }.map { (key: $0.key, title: $0.displayTitle) }
        reminders.sync(ResetReminders.plan(rows: rows, now: now, blocked: blocked, window: resumeEstimate(now: now)?.window),
                       enabled: config.resetReminder, now: now)
        if reminderStatus != reminders.status { reminderStatus = reminders.status }
    }

    func tick() {
        advanceCalm(now: Date())
        updateLink()
        reloadClaude()
        reloadSessions()
        onUpdate?()
    }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    func openConfig() {
        _ = AppConfig.load()   // 确保文件存在
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([AppConfig.fileURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }
}

enum ProjectAction { case folder, terminal, handoff }

// MARK: - 菜单栏图标（两行：名字 + 5小时% + 每周%）

enum StatusImage {
    @MainActor
    static func make(rows: [Provider], now: Date) -> NSImage {
        let shown = Array(rows.prefix(2))
        let height = max(NSStatusBar.system.thickness, 22)
        let nameFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let nameW = ceil(shown.map { ($0.name as NSString).size(withAttributes: [.font: nameFont]).width }.max() ?? 30)
        let numW = ceil(("100" as NSString).size(withAttributes: [.font: numFont]).width)
        let gap: CGFloat = 4
        let width = ceil(1 + nameW + gap + numW + gap + numW + 1)
        let lineH = ceil(nameFont.ascender - nameFont.descender)
        let rowH = height / 2

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            for (i, p) in shown.enumerated() {
                let y = CGFloat(i) * rowH + (rowH - lineH) / 2
                (p.name as NSString).draw(at: NSPoint(x: 1, y: y),
                                          withAttributes: [.font: nameFont, .foregroundColor: NSColor.labelColor])
                let stale = p.isStale(at: now)
                var x = 1 + nameW + gap
                for j in 0..<2 {
                    var text = "–"
                    var color = NSColor.secondaryLabelColor
                    if j < p.windows.count {
                        let w = p.windows[j].effective(at: now)
                        text = "\(Int(w.used.rounded()))"
                        if !stale { color = w.pace(at: now).color ?? .labelColor }
                    }
                    let s = text as NSString
                    let sw = s.size(withAttributes: [.font: numFont]).width
                    s.draw(at: NSPoint(x: x + numW - sw, y: y), withAttributes: [.font: numFont, .foregroundColor: color])
                    x += numW + gap
                }
            }
            return true
        }
        image.cacheMode = .never   // 每次绘制都按当前菜单栏外观（深/浅色）重新取色
        return image
    }
}

// MARK: - 触控栏上画的东西
// 触控栏在视线边缘，只能用余光扫到：余光分得出颜色和长短，读不清数字。所以平时是灰白色、不动，
// 需要你的时候才变色；额度用条的长短表示，数字只是低头细看时用的。

enum TouchBarArt {
    static let height: CGFloat = 30
    /// Control Strip 收起时给自定义按钮的格子只有约 55pt 宽，图比格子宽会被整体缩小（字就看不清了），所以按 54pt 画
    static let glanceWidth: CGFloat = 54
    static let nameFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    static let numFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    static let infoFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    static let labelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    /// 收起时常驻的小图标，只有颜色和长短、没有字：上面两组条是 Claude 和 Codex（粗条是短的那个窗口，细条是本周，
    /// 白竖线是这一轮时间走到的位置，条比竖线长就变橙），最下面一排点是会话灯
    enum GlanceLink { case none, online, offline }

    static func glance(rows: [Provider], lights: [Light], now: Date, lyric: Bool = false, link: GlanceLink = .none, pairs: [GlancePair] = [],
                       focus: GlanceFocus? = nil) -> NSImage {
        let shown = Array(rows.prefix(2))
        // 最多 6 个点（右下角有 ♪ 时少一个，有双机分隔线时再少一个），放不下时先留紧急的，留下的仍按原来的先后排，位置尽量不跳
        let maxDots = (lyric ? 5 : 6) - (link == .none ? 0 : 1)
        let units = glanceUnits(lights: lights, pairs: pairs, slots: maxDots)
        let x: CGFloat = 5, w = glanceWidth - 10
        return image(width: glanceWidth) { rect in
            pill(rect, NSColor(white: 1, alpha: 0.1))
            if let focus {
                NSColor(white: 1, alpha: 0.12).setFill()
                NSRect(x: x, y: 1, width: w, height: 1).fill()
                focus.color.setFill()
                NSRect(x: x, y: 1, width: max(1, w * CGFloat(focus.fraction)), height: 1).fill()
            }
            let top: CGFloat = units.isEmpty && !lyric && link == .none ? 7.5 : 4.5
            for (i, p) in shown.enumerated() {
                let y = top + CGFloat(i) * 9
                let stale = p.isStale(at: now)
                bar(p.windows.first?.effective(at: now), in: NSRect(x: x, y: y, width: w, height: 4), tick: 1.5, now: now, stale: stale)
                bar(p.windows.count > 1 ? p.windows[1].effective(at: now) : nil,
                    in: NSRect(x: x, y: y + 5, width: w, height: 1.5), tick: 0, now: now, stale: stale)
            }
            // 有词可看时右下角一个 ♪，点开小图标就是歌词
            let rowWidth = lyric ? glanceWidth - 11 : glanceWidth
            if lyric {
                let note = "♪" as NSString
                let font = NSFont.systemFont(ofSize: 9, weight: .bold)
                note.draw(at: NSPoint(x: glanceWidth - 12, y: 18.5), withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
            }
            let d: CGFloat = 5, gap: CGFloat = 3
            let pairGap: CGFloat = 4
            // Tailscale 开着时本机的点后面一根竖线（以后 PC 上的会话画在它右边）：实线 = PC 在线，虚线 = 离线，关着不画
            let lineWidth: CGFloat = link == .none ? 0 : (units.isEmpty ? 1 : gap + 1)
            let unitWidths = units.map { $0.count == 2 ? d * 2 + pairGap : d }
            let dotsWidth = units.isEmpty ? 0 : unitWidths.reduce(0, +) + gap * CGFloat(units.count - 1)
            var dx = (rowWidth - dotsWidth - lineWidth) / 2
            for unit in units {
                dot(lights[unit[0]], in: NSRect(x: dx, y: 22.5, width: d, height: d))
                if unit.count == 2 {
                    let tone = pairs.first { $0.first == unit[0] && $0.second == unit[1] }?.tone ?? .quiet
                    relayColor(tone).setFill()
                    NSRect(x: dx + d, y: 24.5, width: pairGap, height: 1).fill()
                    dot(lights[unit[1]], in: NSRect(x: dx + d + pairGap, y: 22.5, width: d, height: d))
                    dx += d * 2 + pairGap + gap
                } else {
                    dx += d + gap
                }
            }
            if link != .none {
                let x = dx
                NSColor(white: 1, alpha: 0.45).setFill()
                if link == .online {
                    NSRect(x: x, y: 22.5, width: 1, height: 5).fill()
                } else {
                    NSRect(x: x, y: 22.5, width: 1, height: 1.5).fill()
                    NSRect(x: x, y: 26, width: 1, height: 1.5).fill()
                }
            }
        }
    }

    /// 歌词页的一大块：上面是当前一句（放不下先缩字号，最小 11pt，再不行才截短），下面一行小字是下一句，没有下一句时写歌名
    static let lyricLargest: CGFloat = 20
    static let lyricSmallest: CGFloat = 13

    /// 歌词页：只放这一句，尽量大（20 号），上下左右居中；太长先缩小（最小 13 号），还放不下才截掉后面。
    /// 前奏、间奏（这一句是空的）写「♪ 歌名」；暂停时变灰
    static func lyricFont(_ text: String, width: CGFloat) -> NSFont {
        var size = lyricLargest
        var font = NSFont.systemFont(ofSize: size, weight: .semibold)
        while size > lyricSmallest && (text as NSString).size(withAttributes: [.font: font]).width > width {
            size -= 0.5
            font = NSFont.systemFont(ofSize: size, weight: .semibold)
        }
        return font
    }

    static func lyric(_ l: NowLyric, width: CGFloat) -> NSImage {
        let pad: CGFloat = 12
        let avail = width - pad * 2
        let text = l.line.isEmpty ? "♪ " + l.title : l.line
        let font = lyricFont(text, width: avail)
        let shown = fit(text, width: avail, font: font)
        let color: NSColor = l.line.isEmpty || !l.playing ? .secondaryLabelColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let measured = (shown as NSString).size(withAttributes: attributes)
        return image(width: width) { rect in
            pill(rect, NSColor(white: 1, alpha: 0.1))
            (shown as NSString).draw(at: NSPoint(x: (width - measured.width) / 2, y: (height - measured.height) / 2), withAttributes: attributes)
        }
    }

    /// 展开后每家一块：上面一行是名字、粗条的百分比、什么时候重置（用得太快时换成照这速度什么时候用完），下面是条
    static func provider(_ p: Provider, now: Date, barW: CGFloat = 170) -> NSImage {
        let stale = p.isStale(at: now)
        // ZCode：没有 % 可画，画 token 数——大字是今日，下面一行是近 7 天
        if let tokens = p.tokens {
            let name = fit(p.name, width: 54, font: nameFont)
            let today = Fmt.tokens(Double(tokens.today))
            let todayW = (today as NSString).size(withAttributes: [.font: numFont]).width
            let sub = fit("今日 · 7天 " + Fmt.tokens(Double(tokens.week)), width: barW - 4, font: infoFont)
            let pad: CGFloat = 8
            let main = stale ? NSColor.tertiaryLabelColor : NSColor.labelColor
            let subColor = stale ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor
            return image(width: pad + barW + pad) { rect in
                pill(rect, NSColor(white: 1, alpha: 0.1))
                (name as NSString).draw(at: NSPoint(x: pad, y: 2.5), withAttributes: [.font: nameFont, .foregroundColor: main])
                (today as NSString).draw(at: NSPoint(x: pad + barW - todayW, y: 2.5), withAttributes: [.font: numFont, .foregroundColor: main])
                (sub as NSString).draw(at: NSPoint(x: pad, y: 18.5), withAttributes: [.font: infoFont, .foregroundColor: subColor])
            }
        }
        let five = p.windows.first?.effective(at: now)
        let week = p.windows.count > 1 ? p.windows[1].effective(at: now) : nil
        let pct = five.map { "\(Int($0.used.rounded()))%" } ?? "–"
        let pctColor = stale || five == nil ? NSColor.tertiaryLabelColor : five!.pace(at: now).color ?? .labelColor
        var info = p.error == nil ? "" : "出错"
        var infoColor = NSColor.secondaryLabelColor
        if let five, !stale {
            let t = Fmt.touchBarInfo(five, now: now)
            info = t.text
            infoColor = t.color ?? .secondaryLabelColor
        } else if stale, p.updatedAt != nil {
            info = "数据过期"
        }
        let name = fit(p.name, width: 54, font: nameFont)
        let nameW = (name as NSString).size(withAttributes: [.font: nameFont]).width
        let pctW = (pct as NSString).size(withAttributes: [.font: numFont]).width
        let pad: CGFloat = 8
        info = fit(info, width: max(0, barW - nameW - pctW - 13), font: infoFont)
        let infoW = (info as NSString).size(withAttributes: [.font: infoFont]).width
        return image(width: pad + barW + pad) { rect in
            pill(rect, NSColor(white: 1, alpha: 0.1))
            (name as NSString).draw(at: NSPoint(x: pad, y: 2.5), withAttributes: [.font: nameFont, .foregroundColor: NSColor.labelColor])
            (pct as NSString).draw(at: NSPoint(x: pad + nameW + 5, y: 2.5), withAttributes: [.font: numFont, .foregroundColor: pctColor])
            (info as NSString).draw(at: NSPoint(x: pad + barW - infoW, y: 3.5), withAttributes: [.font: infoFont, .foregroundColor: infoColor])
            bar(five, in: NSRect(x: pad, y: 18.5, width: barW, height: 4), tick: 2, now: now, stale: stale)
            bar(week, in: NSRect(x: pad, y: 24.5, width: barW, height: 2), tick: 0, now: now, stale: stale)
        }
    }

    private static func dot(_ light: Light, in d: NSRect) {
        light.color.set()
        if light == .idle {
            let ring = NSBezierPath(ovalIn: d.insetBy(dx: 0.6, dy: 0.6))
            ring.lineWidth = 1.2
            ring.stroke()
        } else {
            NSBezierPath(ovalIn: d).fill()
        }
    }

    private static func bar(_ w: QuotaWindow?, in r: NSRect, tick: CGFloat, now: Date, stale: Bool) {
        NSColor(white: 1, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        guard let w else { return }
        if w.used > 0 {
            let fill = stale ? NSColor(white: 1, alpha: 0.3) : (w.pace(at: now).color ?? NSColor(white: 1, alpha: 0.75))
            fill.setFill()
            let fr = NSRect(x: r.minX, y: r.minY, width: max(r.height, r.width * min(1, w.used / 100)), height: r.height)
            NSBezierPath(roundedRect: fr, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        }
        guard tick > 0, !stale, let e = w.elapsed(at: now) else { return }
        let x = r.minX + r.width * e
        let lineW: CGFloat = tick < 2 ? 1 : 1.5
        NSColor.black.setFill()
        NSRect(x: x - lineW / 2 - 0.75, y: r.minY - tick, width: lineW + 1.5, height: r.height + tick * 2).fill()
        NSColor.white.setFill()
        NSRect(x: x - lineW / 2, y: r.minY - tick, width: lineW, height: r.height + tick * 2).fill()
    }

    /// 展开后一个会话一块：灯 + 会话名。等你（橙）、完成（绿）、出错（红）时底色和文字都亮，运行中和空闲是暗的
    static func session(title: String, light: Light, maxWidth: CGFloat = 84) -> NSImage {
        let label = fit(title, width: maxWidth)
        let labelW = ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
        let pad: CGFloat = 7, d: CGFloat = 7
        let lineH = ceil(labelFont.ascender - labelFont.descender)
        return image(width: pad + d + (labelW > 0 ? 6 + labelW : 0) + pad) { rect in
            pill(rect, light.loud ? light.color.withAlphaComponent(0.28) : NSColor(white: 1, alpha: 0.08))
            dot(light, in: NSRect(x: pad, y: (height - d) / 2, width: d, height: d))
            let color: NSColor = light.loud ? .labelColor : light == .running ? .secondaryLabelColor : .tertiaryLabelColor
            (label as NSString).draw(at: NSPoint(x: pad + d + 6, y: (height - lineH) / 2),
                                     withAttributes: [.font: labelFont, .foregroundColor: color])
        }
    }

    /// 灯太多时最后一个显示「+N」
    static func more(_ n: Int) -> NSImage {
        let text = "+\(n)" as NSString
        let w = ceil(text.size(withAttributes: [.font: labelFont]).width)
        let lineH = ceil(labelFont.ascender - labelFont.descender)
        return image(width: w + 14) { rect in
            pill(rect, NSColor(white: 1, alpha: 0.08))
            text.draw(at: NSPoint(x: 7, y: (height - lineH) / 2),
                      withAttributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    /// 放不下就截短加「…」
    static func fit(_ s: String, width: CGFloat, font: NSFont = labelFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= width { return s }
        var chars = Array(s)
        while !chars.isEmpty {
            chars.removeLast()
            let t = String(chars).trimmingCharacters(in: .whitespaces) + "…"
            if (t as NSString).size(withAttributes: attrs).width <= width { return t }
        }
        return ""
    }

    /// 固定宽度的两行按钮，任务名和状态分开，避免系统缩小整排文字。
    static func card(_ title: String, subtitle: String = "", width: CGFloat, color: NSColor? = nil, enabled: Bool = true) -> NSImage {
        image(width: width) { rect in
            pill(rect, color?.withAlphaComponent(enabled ? 0.24 : 0.08) ?? NSColor(white: 1, alpha: enabled ? 0.11 : 0.04))
            let primary = enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor
            let secondary = enabled ? (color ?? NSColor.secondaryLabelColor) : NSColor.tertiaryLabelColor
            let heading = fit(title, width: width - 14, font: nameFont)
            if subtitle.isEmpty {
                let tw = (heading as NSString).size(withAttributes: [.font: nameFont]).width
                (heading as NSString).draw(at: NSPoint(x: (width - tw) / 2, y: 8), withAttributes: [.font: nameFont, .foregroundColor: primary])
            } else {
                (heading as NSString).draw(at: NSPoint(x: 7, y: 1), withAttributes: [.font: nameFont, .foregroundColor: primary])
                let sub = fit(subtitle, width: width - 14, font: infoFont)
                (sub as NSString).draw(at: NSPoint(x: 7, y: 16), withAttributes: [.font: infoFont, .foregroundColor: secondary])
            }
        }
    }

    static func task(_ s: AgentSession, light: Light, now: Date, width: CGFloat = 142) -> NSImage {
        card(s.displayTitle, subtitle: s.agentName + " · " + s.briefStatus(light, now: now),
             width: width, color: light.loud ? light.color : nil)
    }

    static func pill(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    static func image(width: CGFloat, _ draw: @escaping (NSRect) -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: ceil(width), height: height), flipped: true) { rect in
            draw(rect)
            return true
        }
        img.cacheMode = .never
        return img
    }
}

// MARK: - 触控栏（Control Strip 里的常驻按钮 + 点开后的整条）
// 普通 app 的触控栏按钮只在自己处于前台时显示。要常驻只能用 Control Strip 的私有接口（MTMR、Pock 也用这个）：
// NSTouchBarItem.addSystemTrayItem: 登记按钮，DFRFoundation 的 DFRElementSetControlStripPresenceForIdentifier
// 让它显示出来。收起时的格子只有约 55pt 宽，所以常驻的是一个小图标；点它用 NSTouchBar 的
// presentSystemModalTouchBar:placement:systemTrayItemIdentifier:（placement 0：占 app 那一段，右边的 Control Strip
// 还在；app 不在前台时 AppKit 会在左边加系统的关闭键，点它也是 minimize）展开一整条看细节，收起用 minimizeSystemModalTouchBar:（dismiss 会把小图标也去掉）。以后的系统去掉这些接口的话就什么也不做，菜单栏照常显示。

@MainActor
final class TouchBarItem: NSObject, NSScrubberDataSource, NSScrubberDelegate, @preconcurrency NSScrubberFlowLayoutDelegate {
    static let id = NSTouchBarItem.Identifier("local.aiquota.touchbar")
    static let detailID = NSTouchBarItem.Identifier("local.aiquota.touchbar.detail")
    static let itemID = NSUserInterfaceItemIdentifier("local.aiquota.touchbar.part")
    static let detailWidth: CGFloat = 610
    static let detailSpacing: CGFloat = 6
    static let backWidth: CGFloat = 30
    typealias TaskItem = (session: AgentSession, light: Light)
    enum Page {
        case overview, task(String), lyrics, link, attention, shelf, material(String), relay, prompts, translation, calm, pet, tools, road, chats, quota, piano
        /// 能当「家」的页：从这几页点进去的页，点返回回到它（小猫的家、工具页、对话页）
        var homeKey: String? {
            switch self {
            case .pet: return "pet"
            case .tools: return "tools"
            case .chats: return "chats"
            default: return nil
            }
        }
    }
    enum DetailAction {
        case panel, select(String), back
        case session(String), project(ProjectAction, String), none
        case lyrics, stay
        case link, linkConnect, linkCheck, linkDisconnect, linkTerminal
        case attention, shelf, shelfAdd, material(String), shelfCopy(String), shelfRemove(String), shelfClear
        case relay, relayHand(String, String), relayNote(String)
        case prompts, prompt(String), editPrompts
        case translation, translateClipboard, copyTranslation, translationSettings, lightDismiss(String, Date)
        case calm, startBreath, startFocus, stopCalm
        case pet, petPat, tools, openRoad, chats, quota, piano
        case watch(String)                         // 做完叫我：session:<key> 或 light:<灯名>
    }
    /// 展开那一条上的一块。id 是稳定的身份：刷新后按它判断是不是还是那几块、滚回刚才摸过的那块
    struct Part {
        let image: NSImage
        let action: DetailAction
        let id: String
        var label: String? = nil
    }

    /// 一块就是一张画好的图，按原大小显示（不缩放，字才清楚）
    final class PartView: NSScrubberItemView {
        let imageView = NSImageView()
        override init(frame: NSRect) {
            super.init(frame: frame)
            imageView.imageScaling = .scaleNone
            imageView.frame = bounds
            imageView.autoresizingMask = [.width, .height]
            addSubview(imageView)
        }
        required init?(coder: NSCoder) { nil }
    }

    private let item = NSCustomTouchBarItem(identifier: id)
    private let glanceButton = NSButton(title: "", target: nil, action: nil)
    private let detailBar = NSTouchBar()
    private let detailItem = NSCustomTouchBarItem(identifier: detailID)
    // 展开后：左边固定一个返回键（不跟着划走），右边是能像表情栏那样左右划的一排。
    // 用 NSScrubber 的自由滚动：它自己分得清手指是在划还是在点，点按只在松手且没划动时才算。
    private let container = NSStackView()
    private let backButton = NSButton(title: "", target: nil, action: nil)
    private let scrubber = NSScrubber()
    let piano = PianoPanel()                       // 小猫的家里的钢琴：钢琴页时换掉 scrubber（Piano.swift）
    private var scrubberWidth: NSLayoutConstraint!
    private(set) var shown: [Part] = []            // 屏幕上正在显示的；点按按它找动作，数据刷新也不会点错
    private var shownPage = ""
    private var interacting = false                // 手指在上面：不换数据、不自动收起
    private var settling = false                   // 刚松手的一小会儿：系统可能在松手之后才报点按，这时也先不换数据
    private var pending = false                    // 摸着的时候来了新数据，松手后再换
    private var touchSnapshot: [Part]?             // 手指按下时屏幕上的那一排；点按按它找动作，不会点成换了位置的新卡片
    private var touchGeneration = 0                // 第几次按下：松手后排的「0.3 秒后换数据」只认自己这一次
    private var settleWork: DispatchWorkItem?
    static var settleDelay: TimeInterval = 0.3            // 测试里调长，好在真实时间里复现两次交互交错
    private var anchors: [String: (id: String?, ids: [String])] = [:]   // 离开一页时左边缘那块的 id 和整排的 id，从它的下一级返回时对回去
    private var scrollToStart = false              // 这次换页一定从头开始（「做完叫我」弹到家里，小猫说的话要看得见）
    private var closeTimer: Timer?
    private var visibilityObservation: NSKeyValueObservation?
    private var isShown = false
    private var stripPID: pid_t = 0
    private(set) var page: Page = .overview
    private var rows: [Provider] = []
    private var zcodeUsage: Provider?             // ZCode 的本地 token 用量卡（额度页：各家额度后面）
    private var tasks: [TaskItem] = []
    private var lights: [TaskItem] = []
    private var shelf = Shelf()
    private var shelfNote: ShelfNote?
    private var clearArmed: Set<String>?
    private var relays: [RelayPair] = []
    private var prompts: [PromptItem] = []
    private var customLights: [CustomLight] = []
    private var translation: TranslationState = .idle
    private var translationWanted = false
    private var calm: CalmState = .none
    private var calmTicker: Timer?
    private var petMood = PetMood.idle
    private var petPose: PetPose?                 // 上次画的样子：换了样子就从头动 4 秒
    private var petSince = Date.distantPast
    private var pattedAt = Date.distantPast
    private var pats = 0
    private var petEnabled = true
    private var receipts: [String: ReceiptSlot] = [:]
    private var watchCards: [String: WatchCard] = [:]
    private var watchedKeys: Set<String> = []
    private var petNews: PetNews?
    private var newsWanted: PetNews?               // 手指按着时来的「做完叫我」：松手后再弹一次
    // 左边空位的工作流路线图（Roadmap.swift）：Claude 或 Codex 在前台、有任务在跑时自动摆出来，切走或做完就收起
    private var roads: [String: Roadmap] = [:]
    private var ambientOn = true                   // 菜单栏里的开关
    private var ambientDismissed: [String] = []    // 你点系统的 × 关掉的那些轮（会话 + 轮次）：这些轮不再弹（几个会话交替跑时也记得住）
    private var shownRoad: String?                 // 现在摆着的是哪一轮的路线图：点 × 时记的是这一张，不是回调到了才去取的
    private var frontAllowed = true                // 前台 app 切过来时系统触控栏模式允不允许（AIQuota 自己的面板在前台时不重算）
    private var ambientEngaged = false             // 这次展开是路线图弹出来的（点小图标展开、再点回来都算）
    private var roadDataWanted: String?
    private var roadGone = false
    var onRoadWanted: ((String?) -> Void)?
    private var allLights: [CustomLight] = []      // 全部 tb 灯（显示只放得下 20 盏）
    var onWatch: ((String) -> Void)?
    private var homeChild: (key: String, home: Page)?   // 从小猫的家或工具页点进去的那一页（pageKey）：在那页点返回回到原来那页
    private var homeReturn: String?                // 这次换页是从子页返回家里/工具页（它的 pageKey）：对回离开时的位置
    private var breathing: Bool { if case .breath = calm { return true }; return false }
    var presentationAllowed: () -> Bool = { SystemTouchBar.allowsPresentation(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    private var shownTranslation = ""
    private var promptNote: PromptNote?
    private(set) var promptApp: String?
    private var promptAuto = false
    private var promptWanted = false
    #if AIQUOTA_TEST
    var visibleForTesting: Bool?
    #endif

    private var detailVisible: Bool {
        #if AIQUOTA_TEST
        if let visibleForTesting { return visibleForTesting }
        #endif
        return detailBar.isVisible
    }
    private var now = Date()
    private var feedback = ""
    private var feedbackKey = ""
    private var copyingKey: String?
    private var lyric: NowLyric?
    private var lyricActive: Bool { lyric?.active(at: Date()) ?? false }
    private var frontApp: String?                  // 前台 app 的 bundle id
    private var lyricAuto = false                  // 这次展开是看视频时自动弹的歌词（到真正收起为止）：还在歌词页时暂停、停了、切走就收起
    private var lyricDismissed: String?            // 在 Chrome 里放着时被手动收起的那首；换歌、切走再回来前不再弹
    private var closingByApp = false               // 是 App 自己收起的（系统的 × 没有回调，收起时没有这个记号就是用户点的）
    private var lastPresent = Date.distantPast     // 刚弹出的一小会儿系统可能还没显示出来，这时别再弹一次
    private var ownFront = false                   // AIQuota 自己的面板在前台
    private var link = LinkState()
    private var disconnectArmed: Int?              // 点过一次「断开」：会断几个远程连接；4 秒内再点才真断
    private var disarmTimer: Timer?
    private var touchStartX: CGFloat?
    var onLink: ((AppModel.LinkAction) -> Void)?
    var onShelf: ((ShelfCommand) -> Void)?
    var onRelay: ((RelayCommand) -> Void)?
    var onPrompt: ((String) -> Void)?
    var onEditPrompts: (() -> Void)?
    var onLightDismiss: ((String, Date) -> Void)?
    var onTranslation: ((TranslationCommand) -> Void)?
    var onCalm: ((CalmCommand) -> Void)?
    var presenter: ((NSTouchBar) -> Void)?
    var onExpand: (() -> Void)?
    var onOpenPanel: (() -> Void)?
    var onOpenSession: ((String) -> Void)?
    var onProjectAction: ((ProjectAction, String) -> Void)?

    private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)
    private typealias PresenceFn = @convention(c) (CFString, Bool) -> Void
    private static let setPresence: PresenceFn? = dfr.flatMap { dlsym($0, "DFRElementSetControlStripPresenceForIdentifier") }
        .map { unsafeBitCast($0, to: PresenceFn.self) }

    override init() {
        super.init()
        glanceButton.isBordered = false
        glanceButton.imagePosition = .imageOnly
        glanceButton.target = self
        glanceButton.action = #selector(toggleDetail)
        glanceButton.setAccessibilityLabel("AI 额度与任务，点按展开")
        item.view = glanceButton

        backButton.image = TouchBarArt.card("‹", width: Self.backWidth)
        backButton.isBordered = false
        backButton.imagePosition = .imageOnly
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.setAccessibilityLabel("返回")
        backButton.isHidden = true

        scrubber.register(PartView.self, forItemIdentifier: Self.itemID)
        scrubber.mode = .free
        scrubber.isContinuous = false
        scrubber.selectionBackgroundStyle = nil
        scrubber.selectionOverlayStyle = nil
        scrubber.showsArrowButtons = false
        scrubber.showsAdditionalContentIndicators = true    // 两边还有内容时边缘有渐隐提示，看得出能划
        scrubber.floatsSelectionViews = false
        scrubber.itemAlignment = .none
        let layout = NSScrubberFlowLayout()
        layout.itemSpacing = Self.detailSpacing
        scrubber.scrubberLayout = layout
        scrubber.dataSource = self
        scrubber.delegate = self
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubberWidth = scrubber.widthAnchor.constraint(equalToConstant: Self.detailWidth)
        NSLayoutConstraint.activate([scrubberWidth, scrubber.heightAnchor.constraint(equalToConstant: TouchBarArt.height)])

        container.orientation = .horizontal
        container.spacing = Self.detailSpacing
        container.addArrangedSubview(backButton)
        container.addArrangedSubview(scrubber)
        container.addArrangedSubview(piano.view)
        piano.view.isHidden = true
        // 按着琴键就当手指在上面：不换页、不自动收起、「做完叫我」之类的等松手再弹
        piano.onPress = { [weak self] down in
            guard let self else { return }
            if down { self.didBeginInteracting(with: self.scrubber) } else { self.didFinishInteracting(with: self.scrubber) }
        }
        detailItem.view = container
        detailBar.templateItems = [detailItem]
        detailBar.defaultItemIdentifiers = [Self.detailID]
        visibilityObservation = detailBar.observe(\.isVisible) { [weak self] bar, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if bar.isVisible { self.petSince = Date() }      // 展开时小猫动一下打招呼（只动 4 秒）
                    self.updateCalmTicker()
                    if bar.isVisible {
                        if self.closeTimer == nil && !self.interacting && !self.isRoadPage { self.scheduleClose() }
                    } else {
                        // 被系统的关闭键（它调的也是 minimize）或别的方式收起：停掉计时，摸着的状态作废，
                        // 再声明一次小图标要显示（MTMR 也这样做）
                        self.closeTimer?.invalidate()
                        self.closeTimer = nil
                        self.touchGeneration += 1
                        self.settleWork?.cancel()
                        self.settleWork = nil
                        self.interacting = false
                        self.settling = false
                        self.touchSnapshot = nil
                        self.promptAuto = false
                        self.promptWanted = false
                        if self.pending { self.pending = false; self.render() }
                        Self.setPresence?(Self.id.rawValue as CFString, self.isShown)
                        self.detailHidden()
                    }
                }
            }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(toggleDetail),
            name: Notification.Name("local.aiquota.touchbar.toggle"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openRequested(_:)),
            name: Notification.Name("local.aiquota.touchbar.open"), object: nil)
    }

    static func forgetTrayItem(_ identifier: String) {
        setPresence?(identifier as CFString, false)
    }

    func setShown(_ on: Bool) {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlstrip").first?.processIdentifier ?? 0
        if on == isShown && (!on || pid == stripPID) { return }
        let cls: AnyObject = NSTouchBarItem.self
        let add = NSSelectorFromString("addSystemTrayItem:")
        let remove = NSSelectorFromString("removeSystemTrayItem:")
        guard let setPresence = Self.setPresence, cls.responds(to: add), cls.responds(to: remove) else { return }
        if !on { closeDetail() }
        if isShown { _ = cls.perform(remove, with: item) }
        if on { _ = cls.perform(add, with: item) }
        setPresence(Self.id.rawValue as CFString, on)
        isShown = on
        stripPID = pid
    }

    // MARK: 三页的内容

    /// 点系统的 × 关掉路线图之后，对话页上多出这一格：点了再把这一轮（或做完的最后一次）的路线图打开
    static let roadChip = Part(image: TouchBarArt.card("路线", width: chipWidth), action: .openRoad, id: "road", label: "路线：再打开这一轮的工作流路线图")
    /// 小猫关掉时，AI 页上进放松页（番茄钟、呼吸、歌词）的那一格，占小猫的位置
    static let relaxChip = Part(image: TouchBarArt.chipSingle("放松", width: chipWidth), action: .pet, id: "relax", label: "放松：番茄钟、呼吸、歌词")
    static let toolsChip = Part(image: TouchBarArt.chipSingle("工具", width: chipWidth), action: .tools, id: "tools",
                                label: "工具：常用指令、材料架、翻译、待处理")

    /// 小猫的家里的歌词卡（在放时）
    static func lyricCard(_ lyric: NowLyric?, now: Date) -> Part? {
        guard let lyric, lyric.active(at: now) else { return nil }
        return Part(image: TouchBarArt.card("♪ 歌词", subtitle: lyric.title, width: 110), action: .lyrics, id: "lyrics")
    }

    /// 工具页的卡，按这个顺序：常用指令（Claude/Codex 在前台时）、材料架、翻译、待处理（有要看的才出现）
    static func toolCards(now: Date, prompts: Int? = nil, shelf: Shelf? = nil, translation: TranslationState? = nil,
                          attention: [AttentionItem] = []) -> [Part] {
        var out: [Part] = []
        if let prompts { out.append(promptsCard(prompts)) }
        if let shelf { out.append(shelfCard(shelf)) }
        if let translation { out.append(translateCard(translation)) }
        if !attention.isEmpty {
            out.append(Part(image: TouchBarArt.card("待处理 \(attention.count)", subtitle: Attention.summary(attention), width: 120,
                                                    color: Attention.tint(attention)), action: .attention, id: "attention",
                            label: "待处理 \(attention.count) 件：" + Attention.summary(attention)))
        }
        return out
    }

    /// 双机的状态一句话、颜色、是不是暗着（Tailscale 关着是省电，不是问题）
    static func linkStatus(_ l: LinkState, now: Date) -> (text: String, color: NSColor?, dim: Bool) {
        if l.busy == .connecting { return ("连接中…", nil, false) }
        if l.busy == .disconnecting { return ("断开中…", nil, false) }
        if let e = l.error { return (e, .systemOrange, false) }
        if !l.on { return ("未连（省电）", nil, true) }
        if l.pcOnline == false {
            return ("WSL 离线" + (l.pcLastSeen.map { " · 上次在线 " + Fmt.short(now.timeIntervalSince($0)) + "前" } ?? ""), .systemOrange, false)
        }
        if let idle = l.idle(at: now), idle >= 30 * 60, let since = l.since {
            return ("已连 " + Fmt.short(now.timeIntervalSince(since)) + " · 空闲 " + Fmt.short(idle), nil, false)
        }
        return (l.pcOnline == true ? "已连 · WSL 在线" : "已连", nil, false)
    }

    /// AI 页上的双机小格：「双机」加一句短状态——在线、省电、离线、连接中；只有出问题（离线、出错）时前面带一个橙点，
    /// 正常时不画点也不用绿色，没连时整格暗着（省电不是问题）；点了进双机页
    static func linkChip(_ l: LinkState, now: Date) -> Part {
        let status = linkStatus(l, now: now)
        let line: String
        var dot: NSColor?
        if l.busy == .connecting { line = "连接中" }
        else if l.busy == .disconnecting { line = "断开中" }
        else if l.error != nil { line = "出错"; dot = .systemOrange }
        else if !l.on { line = "省电" }
        else if l.pcOnline == false { line = "离线"; dot = .systemOrange }
        else { line = l.pcOnline == true ? "在线" : "已连" }
        let image = TouchBarArt.chipDouble("双机", line: line, color: status.dim ? .tertiaryLabelColor : TouchBarArt.subColor, dot: dot, dim: status.dim, width: chipWidth)
        return Part(image: image, action: .link, id: "link", label: "双机：" + status.text + "。点开看详情")
    }

    /// 双机页：关着时只有状态和「连接」；开着时是状态、PC 在不在线、检查线路、SSH 终端、断开（要点两下）
    static func linkImages(_ l: LinkState, now: Date, armed: Int?) -> [Part] {
        var out: [Part] = []
        func add(_ title: String, _ sub: String, _ width: CGFloat, _ color: NSColor? = nil, _ action: DetailAction = .stay, _ id: String) {
            out.append(Part(image: TouchBarArt.card(title, subtitle: sub, width: width, color: color), action: action, id: id,
                            label: sub.isEmpty ? title : title + "，" + sub))
        }
        let ago = { (d: Date) in Fmt.short(now.timeIntervalSince(d)) + "前" }
        if !l.on {
            add("双机 · 未连（省电）", l.pcLastSeen.map { "WSL 上次在线 " + ago($0) } ?? "Tailscale 关着", 190, nil, .stay, "link:state")
            if l.busy == .connecting { add("连接中…", "启动 Tailscale → 检查线路", 190, nil, .none, "link:connect") }
            else { add("连接", "", 72, nil, .linkConnect, "link:connect") }
            if let e = l.error { add("没连上", e, 190, .systemOrange, .stay, "link:error") }
            return out
        }
        let how = l.direct == true ? "直连" : l.direct == false ? (l.relay.isEmpty ? "经中转" : "经中转 · " + l.relay) : "已连"
        add("双机 · 已连" + (l.since.map { " " + Fmt.short(now.timeIntervalSince($0)) } ?? ""),
            how + (l.idleShown(at: now).map { " · 空闲 " + Fmt.short($0) } ?? ""), 150, nil, .stay, "link:state")
        switch l.pcOnline {
        case true?: add("WSL 在线", "Tailscale 看得到", 100, nil, .stay, "link:pc")
        case false?: add("WSL 离线", l.pcLastSeen.map { "上次在线 " + ago($0) } ?? "可能睡眠或没开 WSL", 150, nil, .stay, "link:pc")
        default: add("WSL", "还没查到", 96, nil, .stay, "link:pc")
        }
        if l.busy == .checking { add("检查中…", "约 2 秒", 96, nil, .none, "link:check") }
        else if let c = l.check, now.timeIntervalSince(c.at) < 300 {
            // 通了就一句「三条都通」；不通写第一条断的（后面的没走到），完整的 ✓✗ 在菜单栏里看
            let names = [("Mac→WSL", c.macToWSL), ("WSL→Mac", c.wslToMac), ("Win→Mac", c.winToMac)]
            let broken = names.first { $0.1 == false }.map { $0.0 + " 不通" } ?? "没查完"
            add(c.ok ? "线路正常" : "线路有问题", c.ok ? "三条都通 · " + ago(c.at) : broken, 120, c.ok ? nil : .systemRed, .linkCheck, "link:check")
            if !c.ok && !c.reason.isEmpty { add("原因", c.reason, 190, .systemRed, .stay, "link:reason") }
        } else { add("检查线路", "约 2 秒", 96, nil, .linkCheck, "link:check") }
        if l.pcOnline != false { add("SSH 终端", "", 76, nil, .linkTerminal, "link:terminal") }
        // 三种状态一样宽：上膛只换图，不重新加载，手指下面的位置不动
        if l.busy == .disconnecting { add("断开中…", "", 96, nil, .none, "link:off") }
        else if let n = armed { add("再点断开", n > 0 ? "会断 \(n) 个 SSH" : "没有远程连接", 96, .systemOrange, .linkDisconnect, "link:off") }
        else { add("断开", "要点两下", 96, nil, .linkDisconnect, "link:off") }
        if let e = l.error { add("出错了", e, 190, .systemOrange, .stay, "link:error") }
        if let k = l.keyExpiry, k.timeIntervalSince(now) < 14 * 86400 {
            add("Tailscale 密钥", Fmt.short(k.timeIntervalSince(now)) + "后过期", 130, .systemOrange, .stay, "link:key")
        }
        return out
    }

    /// 歌词页：一整块歌词（返回键在左边固定着）
    static func lyricImages(_ lyric: NowLyric) -> [Part] {
        [Part(image: TouchBarArt.lyric(lyric, width: detailWidth - backWidth - detailSpacing), action: .stay, id: "lyric",
              label: lyric.line.isEmpty ? lyric.title : lyric.line)]
    }

    static let projectExtraWidth: CGFloat = 120

    /// 任务操作页：任务名、（在跑或等你时）做完叫我 /（跑完时）本轮小票、打开 AI、文件夹、终端、复制交接
    static func projectImages(item: TaskItem, now: Date, feedback: String = "", copying: Bool = false,
                              watch: WatchCard? = nil, receipt: ReceiptSlot? = nil, took: TimeInterval? = nil) -> [Part] {
        let s = item.session
        let available = ProjectActions.directory(s.cwd) != nil
        var extra: Part?
        if let watch {
            let key = "session:" + s.key
            switch watch {
            case .offer:
                extra = Part(image: TouchBarArt.card("做完叫我", subtitle: "完成、出错或等你时", width: projectExtraWidth), action: .watch(key),
                             id: "watch:" + s.key, label: "做完叫我：它完成、出错或停下来等你时响一声、小猫告诉你")
            case .offerAfterWait:
                extra = Part(image: TouchBarArt.card("继续后叫我", subtitle: "不管这次等待", width: projectExtraWidth), action: .watch(key),
                             id: "watch:" + s.key, label: "继续后叫我：这次等你先不叫，它接着跑完、出错或下次等你时叫你")
            case .armed:
                extra = Part(image: TouchBarArt.card("会叫你", subtitle: "再点取消", width: projectExtraWidth, color: .systemOrange), action: .watch(key),
                             id: "watch:" + s.key, label: "已经订阅做完叫我，再点取消")
            }
        } else if let receipt {
            let partial: Bool = { if case .ready(let r) = receipt { return r.partial }; return false }()
            let heading = "本轮" + (partial ? "（部分）" : "") + (took.map { (partial ? " · " : " · 用了 ") + Fmt.short($0) } ?? "")
            switch receipt {
            case .ready(let r):
                extra = Part(image: TouchBarArt.card(heading, subtitle: r.detail, width: projectExtraWidth, color: r.failed ? .systemOrange : nil),
                             action: .none, id: "receipt:" + s.key, label: heading + "：" + r.summary)
            case .unreadable:
                extra = Part(image: TouchBarArt.card(heading, subtitle: "本轮记录暂不可读", width: projectExtraWidth), action: .none,
                             id: "receipt:" + s.key, label: heading + "：本轮记录暂不可读")
            }
        }
        let status = feedback.isEmpty ? s.agentName + " · " + s.briefStatus(item.light, now: now) : feedback
        var parts = [
            Part(image: TouchBarArt.card(s.displayTitle, subtitle: status, width: extra == nil ? 190 : 150,
                                         color: item.light.loud ? item.light.color : nil),
                 action: .session(s.key), id: "title:" + s.key, label: s.displayTitle + "，" + status),
        ]
        if let extra { parts.append(extra) }
        return parts + [
            Part(image: TouchBarArt.card("打开 " + s.agentName, width: 82), action: .session(s.key), id: "open:" + s.key),
            Part(image: TouchBarArt.card("文件夹", width: 56, enabled: available), action: available ? .project(.folder, s.key) : .none, id: "folder:" + s.key),
            Part(image: TouchBarArt.card("终端", width: 50, enabled: available), action: available ? .project(.terminal, s.key) : .none, id: "terminal:" + s.key),
            Part(image: TouchBarArt.card(copying ? "整理中…" : "复制交接", width: 76, enabled: !copying),
                 action: copying ? .none : .project(.handoff, s.key), id: "handoff:" + s.key),
        ]
    }

    func update(rows: [Provider], lights: [TaskItem], tasks: [TaskItem], now: Date,
                feedback: String = "", feedbackKey: String = "", copyingKey: String? = nil, lyric: NowLyric? = nil,
                link: LinkState = LinkState(), shelf: Shelf = Shelf(), shelfNote: ShelfNote? = nil, relays: [RelayPair] = [],
                prompts: [PromptItem] = [], promptNote: PromptNote? = nil, customLights: [CustomLight] = [],
                translation: TranslationState = .idle, calm: CalmState = .none, pet: PetMood = .idle, petEnabled: Bool = true,
                receipts: [String: ReceiptSlot] = [:], watchCards: [String: WatchCard] = [:], watched: Set<String> = [], news: PetNews? = nil,
                allLights: [CustomLight]? = nil, roads: [String: Roadmap] = [:], ambient: Bool = true, zcodeUsage: Provider? = nil) {
        self.lyric = lyric
        self.link = link
        self.lights = lights
        self.shelf = shelf
        self.shelfNote = shelfNote
        self.relays = relays
        self.prompts = prompts
        self.promptNote = promptNote
        self.customLights = customLights
        self.calm = calm
        self.zcodeUsage = zcodeUsage
        petMood = pet
        self.petEnabled = petEnabled
        self.receipts = receipts
        self.watchCards = watchCards
        self.watchedKeys = watched
        petNews = news
        self.allLights = allLights ?? customLights
        self.roads = roads
        ambientOn = ambient
        let finished = { (state: TranslationState) -> Bool in if case .working = state { return false }; return true }
        if case .translation = page, detailVisible, !interacting, !finished(self.translation), finished(translation) { scheduleClose() }
        self.translation = translation
        if let armed = clearArmed, armed != Set(shelf.items.map(\.id)) { clearArmed = nil }
        if disconnectArmed == nil && clearArmed == nil { disarm() }
        self.rows = rows
        self.tasks = tasks
        self.now = now
        self.feedback = feedback
        self.feedbackKey = feedbackKey
        self.copyingKey = copyingKey
        let glanceLink: TouchBarArt.GlanceLink = !link.available || !link.on ? .none : link.pcOnline == false ? .offline : .online
        glanceButton.image = TouchBarArt.glance(rows: rows, lights: lights.map(\.light) + customLights.map(\.light), now: now,
                                                lyric: lyric?.active(at: now) ?? false, link: glanceLink,
                                                pairs: Self.glancePairs(relays, lights: lights), focus: calm.glanceFocus(at: now))
        autoLyrics()                                       // 在 render 前：歌没了时 render 会把歌词页改成总览，就看不出是自动弹的歌词页了
        render()
        syncAmbient()
    }

    // MARK: 左边空位：工作流路线图

    /// 前台是哪个 AI（Claude / Codex）：路线图按它挑
    /// 前台 app 决定摆谁的路线图（AIQuota 自己的面板不算切走：roadFront 只在真的切了 app 时更新，
    /// 和指令条的 promptApp 一个道理）；ZCode 的会话库有记录就摆 ZCode 的
    private var roadFront: String?
    private var roadAgent: String? {
        switch roadFront {
        case "com.anthropic.claudefordesktop": return "claude"
        case "com.openai.codex": return "codex"
        case "dev.zcode.app": return "zcode"
        default: return nil
        }
    }

    /// 前台 Claude 或 Codex 现在要画的路线图
    private var activeRoad: Roadmap? { roadAgent.flatMap { roads[$0] } }

    /// 要不要读数据（模型才去盯对话记录）：开关开着、Claude 或 Codex 在前台、没在呼吸、系统触控栏模式允许
    private var wantRoadData: Bool {
        ambientOn && isShown && roadAgent != nil && !breathing && frontAllowed
    }

    private func isDismissed(_ road: Roadmap) -> Bool { ambientDismissed.contains(road.dismissKey) }

    /// 摆出来或收起：有路线图、没被你关掉、没在别的事上（呼吸），就在空位上摆；不该摆了、正摆着路线图页就收起
    private func syncAmbient() {
        let data = wantRoadData
        let agent = data ? roadAgent : nil
        if agent != roadDataWanted {
            roadDataWanted = agent
            onRoadWanted?(agent)
        }
        if data, let road = activeRoad, !isDismissed(road) {
            if !detailVisible {
                guard !interacting, !settling, clock.timeIntervalSince(lastPresent) > 2 else { return }
                homeChild = nil
                lyricAuto = false
                page = .road
                shownRoad = road.dismissKey
                render(force: true)
                ambientEngaged = true
                _ = present()
            } else if ambientEngaged, case .road = page {
                shownRoad = road.dismissKey
                render()
            }
        } else if ambientEngaged, detailVisible, roadGone || { if case .road = page { return true }; return false }() {
            roadGone = false
            closeDetail()
        }
        roadGone = false
    }
    // MARK: 显示

    private func currentParts() -> [Part] {
        switch page {
        case .overview:
            return overviewParts()
        case .attention:
            return Self.attentionImages(Attention.items(from: lights))
        case .relay:
            return Self.relayImages(relays, claude: rows.first, codex: rows.dropFirst().first, now: now)
        case .prompts:
            return Self.promptImages(prompts, app: promptApp, note: promptNote)
        case .translation:
            return Self.translationImages(translation)
        case .calm:
            return Self.calmImages(calm, now: Date())
        case .pet:
            return petHomeParts()
        case .tools:
            return toolsParts()
        case .chats:
            return chatsParts()
        case .quota:
            return quotaParts()
        case .piano:
            return shown                                   // 钢琴页不用那一排（render 里换成琴键），这里只是占位
        case .road:
            if let road = activeRoad { return Self.roadParts(road) }
            if ambientEngaged {                                // 路线图摆着时没有要画的了：先保持原样，syncAmbient 把条收起（不闪出 AI 页的内容）
                roadGone = true
                return shown
            }
        case .shelf:
            return Self.shelfImages(shelf, note: shelfNote, clearArmed: clearArmed?.count)
        case .material(let id):
            if let item = shelf.item(id) { return Self.materialImages(item, note: shelfNote) }
            page = .shelf
            return Self.shelfImages(shelf, note: shelfNote, clearArmed: clearArmed?.count)
        case .link:
            if link.available { return Self.linkImages(link, now: now, armed: disconnectArmed) }
        case .lyrics:
            if let lyric { return Self.lyricImages(lyric) }
        case .task(let key):
            if let selected = tasks.first(where: { $0.session.key == key }) {
                let s = selected.session
                let took = s.turnAt.flatMap { start in s.turnEndedAt.map { $0.timeIntervalSince(start) } }
                return Self.projectImages(item: selected, now: now, feedback: feedbackKey == key ? feedback : "", copying: copyingKey == key,
                                          watch: watchCards[key], receipt: receipts[key], took: took)
            }
        }
        // 歌词没了、任务没了、双机不可用了：从家里或工具页进来的回原来那页（对回离开时的位置），其余回 AI 页
        if let child = homeChild, child.key == pageKey {
            homeChild = nil
            page = child.home
            homeReturn = child.home.homeKey
            return homeParts(child.home)
        }
        homeChild = nil
        page = .overview
        return overviewParts()
    }

    /// AI 页：固定一屏。额度表、最要紧的两张对话、「对话」入口、双机（装了时）、小猫（关了换成「放松」）、「工具」
    private func overviewParts() -> [Part] {
        let linkChip = link.available ? Self.linkChip(link, now: now) : nil
        var pet = Self.relaxChip
        if petEnabled {
            let frame = petFrame(at: Date())
            pet = Self.petChip(frame.pose, elapsed: frame.elapsed)
        }
        return Self.aiPage(rows: rows, tasks: tasks, lights: customLights, relays: relays, watched: watchedKeys, now: now, link: linkChip, pet: pet)
    }

    /// 对话页：接力、路线入口、全部会话、tb 灯
    private func chatsParts() -> [Part] {
        let reopen = wantRoadData && (activeRoad.map(isDismissed) ?? false) ? Self.roadChip : nil     // 你关掉了路线图、但还有得看：给个打开的入口
        return Self.chatsImages(tasks: tasks, lights: customLights, relays: relays, watched: watchedKeys, now: now, reopen: reopen)
    }

    /// 额度页：每家额度带条的卡，ZCode 的 token 用量
    private func quotaParts() -> [Part] { Self.quotaImages(rows: rows, usage: zcodeUsage, now: now) }

    /// 从「家」点进去的页在内容没了时回到的那一页的内容
    private func homeParts(_ home: Page) -> [Part] {
        switch home {
        case .tools: return toolsParts()
        case .chats: return chatsParts()
        default: return petHomeParts()
        }
    }

    /// 小猫的家（放松的）：小猫和它说的话、专注和呼吸、歌词（在放时）、钢琴、摸摸；小猫关掉时只剩专注、呼吸、歌词和钢琴
    private func petHomeParts() -> [Part] {
        let frame = petFrame(at: Date())
        let tools = [Self.lyricCard(lyric, now: now), Self.pianoCard].compactMap { $0 }
        return Self.petHomeImages(pose: frame.pose, elapsed: frame.elapsed, petContext(), tools: tools, showPet: petEnabled)
    }

    /// 工具页（干活用的）：常用指令（Claude/Codex 在前台时）、材料架、翻译、待处理
    private func toolsParts() -> [Part] {
        Self.toolCards(now: now, prompts: promptApp != nil ? prompts.count : nil, shelf: shelf, translation: translation,
                       attention: Attention.items(from: lights))
    }

    private func petContext() -> PetContext {
        PetContext(lights: lights, calm: calm, rows: rows, song: lyricActive ? lyric?.title : nil, pats: pats, receipts: receipts,
                   customLights: allLights, news: petNews, now: Date())
    }

    /// 小猫现在的样子和这个样子已经动了多久。换了样子（或者刚展开，见 isVisible 的观察）就从头动 4 秒；
    /// 被摸的爱心按最后一次摸的时间算，连着摸会重新飘
    private func petFrame(at now: Date) -> (pose: PetPose, elapsed: TimeInterval) {
        // 刚「做完叫我」叫过你：小猫按那件事的样子（完成、出错、等你）
        let newsMood: PetMood? = petNews.flatMap { news in
            guard news.fresh(at: now) else { return nil }
            return news.state == "error" ? .error : news.state == "waiting" ? .waiting : .done
        }
        let pose = PetPose.of(mood: newsMood ?? petMood, calm: calm, music: lyricActive, patted: now.timeIntervalSince(pattedAt) < PetArt.patLength)
        if pose != petPose {
            petPose = pose
            petSince = now
        }
        return (pose, pose == .happy ? now.timeIntervalSince(pattedAt) : now.timeIntervalSince(petSince))
    }

    private var pageKey: String {
        switch page {
        case .overview: return "overview"
        case .lyrics: return "lyrics"
        case .link: return "link"
        case .attention: return "attention"
        case .shelf: return "shelf"
        case .material(let id): return "material:" + id
        case .relay: return "relay"
        case .prompts: return "prompts"
        case .translation: return "translation"
        case .calm: return "calm"
        case .pet: return "pet"
        case .tools: return "tools"
        case .road: return "road"
        case .chats: return "chats"
        case .quota: return "quota"
        case .piano: return "piano"
        case .task(let key): return "task:" + key
        }
    }

    static func translationKey(_ state: TranslationState) -> String {
        switch state {
        case .idle: return "idle"
        case .working(let source): return "working:" + source
        case .done(let result): return "done:" + result.source + "|" + result.text
        case .failed(let message, _): return "failed:" + message
        }
    }

    static func parentKey(of pageKey: String) -> String? {
        if pageKey == "overview" { return nil }
        return pageKey.hasPrefix("material:") ? "shelf" : "overview"
    }

    /// force：用户自己点了换页（要立刻换）；否则是数据刷新，手指在上面或刚松手时先攒着
    private func render(force: Bool = false) {
        if !force && (interacting || settling) { pending = true; return }
        if force { touchSnapshot = nil }
        // 钢琴页：琴键换掉可滑动的那一排（返回键留着）；离开钢琴页就换回来、停掉声音
        if case .piano = page {
            if shownPage != "piano" {
                if !shownPage.isEmpty { anchors[shownPage] = (leadingVisibleID(), shown.map(\.id)) }   // 从钢琴页返回家里时对回原来的位置
                shownPage = "piano"
            }
            homeReturn = nil
            scrollToStart = false
            updateCalmTicker()
            backButton.isHidden = false
            scrubber.isHidden = true
            piano.view.isHidden = false
            if !piano.active && isShown { piano.activate() }   // 数据刷新时不重复开引擎、不重画按钮；触控栏关掉了就不开
            return
        }
        if !piano.view.isHidden {
            piano.view.isHidden = true
            scrubber.isHidden = false
            piano.deactivate()
        }
        let parts = currentParts()
        let returningTo = homeReturn                       // currentParts 兜底回家时也会设它
        homeReturn = nil
        let fromStart = scrollToStart
        scrollToStart = false
        let pageKey = self.pageKey
        updateCalmTicker()
        let backVisible = pageKey != "overview" && pageKey != "road"
        backButton.isHidden = !backVisible
        scrubberWidth.constant = Self.detailWidth - (backVisible ? Self.backWidth + Self.detailSpacing : 0)

        let translationKey = Self.translationKey(translation)
        let freshTranslation = pageKey == "translation" && translationKey != shownTranslation
        shownTranslation = translationKey
        let samePage = pageKey == shownPage && !freshTranslation && !fromStart
        let sameShape = samePage && parts.map(\.id) == shown.map(\.id)
            && zip(parts, shown).allSatisfy { $0.image.size == $1.image.size }
        if sameShape {
            // 还是那几块、大小也没变：只换图和无障碍标签，不重新加载，划到的位置一点不动
            shown = parts
            for i in shown.indices {
                guard let view = scrubber.itemViewForItem(at: i) as? PartView else { continue }
                view.imageView.image = shown[i].image
                view.setAccessibilityLabel(shown[i].label ?? accessibilityLabel(shown[i].action))
            }
            return
        }
        // 换之前记下左边缘正对着哪一块（按稳定的 id）：纯滑动过、没点过也算
        let leading = leadingVisibleID()
        let pinned = pageKey == "road" && samePage && isPinnedToEnd()      // 路线图：刷新前最新的一步就在屏幕里的，刷新后也要在
        if pageKey != shownPage && !shownPage.isEmpty { anchors[shownPage] = (leading, shown.map(\.id)) }
        let oldIDs = shown.map(\.id)
        shown = parts
        scrubber.reloadData()
        var anchor: (id: String, ids: [String])?
        if samePage {
            anchor = leading.map { ($0, oldIDs) }             // 同一页多了、少了或换了顺序
        } else {
            // 从下一级返回时回到离开时的位置，进新的一页从头开始；从家里点进去的页返回家里也一样。
            // 那块在离开期间没了，就按离开时那一排找它后面（再不行前面）还在的
            let parent = returningTo ?? Self.parentKey(of: shownPage)
            if !fromStart, parent == pageKey, let saved = anchors[pageKey], let id = saved.id { anchor = (id, saved.ids) }
            shownPage = pageKey
        }
        // 路线图可能长过一屏（可以左右划）：刚摆出来、或者刷新前就停在最右的，停在最新的一步（最新的一步一定要看得到）；
        // 手指划到前面看的，位置不动，按左边缘那一步的 id 对回去
        if pageKey == "road", !shown.isEmpty, !samePage || pinned {
            scrubber.scrollItem(at: shown.count - 1, to: .trailing)
            return
        }
        let index = anchor.flatMap { Self.anchorIndex(id: $0.id, oldIDs: $0.ids, ids: shown.map(\.id)) } ?? 0
        if shown.indices.contains(index) { scrubber.scrollItem(at: index, to: .leading) }
    }

    /// 最后一块已经整块在屏幕里（或者整排放得下，没东西可划）
    private func isPinnedToEnd() -> Bool {
        let layout = scrubber.scrubberLayout
        guard let last = shown.indices.last, let frame = layout.layoutAttributesForItem(at: last)?.frame, frame.width > 0,
              layout.visibleRect.width > 0 else { return true }
        return frame.maxX <= layout.visibleRect.maxX + 1
    }

    /// 可见区域左边缘那一块的 id（过半露出来的第一块），用 NSScrubberLayout 的公开接口算
    private func leadingVisibleID() -> String? {
        let layout = scrubber.scrubberLayout
        let visible = layout.visibleRect
        let frames = shown.indices.map { layout.layoutAttributesForItem(at: $0)?.frame ?? .zero }
        return Self.leadingID(ids: shown.map(\.id), frames: frames, visible: visible)
    }

    static func leadingID(ids: [String], frames: [NSRect], visible: NSRect) -> String? {
        guard ids.count == frames.count, visible.width > 0 else { return nil }
        let i = frames.indices.first { frames[$0].width > 0 && frames[$0].midX >= visible.minX && frames[$0].minX < visible.maxX }
        return i.map { ids[$0] }
    }

    /// 锚点那块在新的一排里的位置；它没了就找原来排在它后面（再不行前面）还在的那块
    static func anchorIndex(id: String, oldIDs: [String], ids: [String]) -> Int? {
        if let i = ids.firstIndex(of: id) { return i }
        guard let k = oldIDs.firstIndex(of: id) else { return nil }
        for other in Array(oldIDs.dropFirst(k + 1)) + Array(oldIDs.prefix(k).reversed()) {
            if let i = ids.firstIndex(of: other) { return i }
        }
        return nil
    }

    private func accessibilityLabel(_ action: DetailAction) -> String {
        switch action {
        case .panel: return "打开额度详情"
        case .back: return "返回"
        case .select(let key): return tasks.first(where: { $0.session.key == key })?.session.displayTitle ?? "查看任务"
        case .session: return "打开任务对应的 AI 应用"
        case .project(let action, _):
            switch action { case .folder: return "打开项目文件夹"; case .terminal: return "打开项目终端"; case .handoff: return "复制 AI 交接信息" }
        case .none: return "暂无可用操作"
        case .lyrics: return "查看歌词"
        case .stay: return "说明"
        case .link: return "两台电脑的连接"
        case .linkConnect: return "连接两台电脑"
        case .linkCheck: return "检查三条线路"
        case .linkDisconnect: return disconnectArmed == nil ? "断开 Tailscale（要再点一次）" : "确认断开 Tailscale"
        case .linkTerminal: return "在终端里 ssh win"
        case .attention: return "待处理的任务"
        case .shelf: return "材料架"
        case .shelfAdd: return "把当前复制的内容加到材料架"
        case .material(let id): return shelf.item(id).map { "复制并打开材料：" + $0.kindLabel } ?? "材料"
        case .shelfCopy: return "把这条材料复制到剪贴板"
        case .shelfRemove: return "从材料架移除这一条"
        case .shelfClear: return clearArmed == nil ? "清空材料架（要再点一次）" : "确认清空材料架"
        case .relay: return "Claude 和 Codex 的接力"
        case .relayHand(_, let agent): return "复制交接的话并切到 " + Relay.name(agent)
        case .relayNote: return "打开交接说明"
        case .prompts: return "常用指令"
        case .prompt(let id): return prompts.first { $0.id == id }.map { "放进输入框：" + $0.text } ?? "常用指令"
        case .editPrompts: return "编辑常用指令"
        case .translation: return "翻译"
        case .translateClipboard: return "翻译剪贴板里的文字"
        case .copyTranslation: return "复制译文"
        case .translationSettings: return "打开语言与地区设置，下载翻译语言"
        case .lightDismiss(let name, _): return "清除这盏灯：" + name
        case .calm: return "番茄钟和呼吸"
        case .startBreath: return "开始 4-7-8 呼吸"
        case .startFocus: return "开始专注 25 分钟"
        case .stopCalm: return "停止"
        case .pet: return "小猫的家"
        case .tools: return "工具：常用指令、材料架、翻译、待处理"
        case .chats: return "对话：全部会话、接力、tb 灯"
        case .quota: return "额度：每个窗口的用量"
        case .piano: return "钢琴"
        case .openRoad: return "再打开工作流路线图"
        case .petPat: return "摸摸小猫"
        case .watch: return "做完叫我（再点取消）"
        }
    }

    // MARK: NSScrubber

    func numberOfItems(for scrubber: NSScrubber) -> Int { shown.count }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = scrubber.makeItem(withIdentifier: Self.itemID, owner: nil) as? PartView ?? PartView(frame: .zero)
        if shown.indices.contains(index) {
            view.imageView.image = shown[index].image
            view.setAccessibilityLabel(shown[index].label ?? accessibilityLabel(shown[index].action))
        }
        return view
    }

    func scrubber(_ scrubber: NSScrubber, layout: NSScrubberFlowLayout, sizeForItemAt itemIndex: Int) -> NSSize {
        shown.indices.contains(itemIndex) ? shown[itemIndex].image.size : NSSize(width: Self.backWidth, height: TouchBarArt.height)
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt selectedIndex: Int) {
        scrubber.selectedIndex = -1                          // 不留选中状态，同一块可以再点
        let parts = touchSnapshot ?? shown                   // 按手指按下时屏幕上的那一排找，数据刷新了也不会点错
        guard parts.indices.contains(selectedIndex) else { return }
        perform(parts[selectedIndex].action)
    }

    func didBeginInteracting(with scrubber: NSScrubber) {
        // 新的一次按下：上一次松手排的回调作废（不然它会在这次松手后的 0.3 秒里提前清掉快照、换数据）
        touchGeneration += 1
        settleWork?.cancel()
        settleWork = nil
        interacting = true
        settling = false
        touchSnapshot = shown
        touchStartX = scrubber.scrubberLayout.visibleRect.minX
        closeTimer?.invalidate()                             // 摸着的时候不自动收起
        closeTimer = nil
    }
    func didFinishInteracting(with scrubber: NSScrubber) { endInteraction() }
    func didCancelInteracting(with scrubber: NSScrubber) { endInteraction() }

    /// 松手后再等 0.3 秒才换数据：系统可能在「交互结束」之后才报这次点按，那时还要按旧的一排找动作
    private func endInteraction() {
        interacting = false
        settling = true
        // 按下到松手之间一排被划动过：是滑动不是点按，已经上膛的「断开」取消
        if disconnectArmed != nil || clearArmed != nil, let x0 = touchStartX, abs(scrubber.scrubberLayout.visibleRect.minX - x0) > 4 {
            disarm()
            pending = true
        }
        touchStartX = nil
        let generation = touchGeneration
        settleWork?.cancel()                                 // 同一次交互报了两次结束（finish + cancel）：只留最后一个
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settle(generation: generation) }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// 松手 0.3 秒后：还是同一次交互、手指没再按下，才清掉快照、换上摸着时攒下的数据
    private func settle(generation: Int) {
        guard generation == touchGeneration, !interacting, settling else { return }
        settleWork = nil
        settling = false
        touchSnapshot = nil
        autoLyrics()                                       // 按着时暂停、切走、歌没了的，松手后再收；和 update 一样要在 render 前
        if pending { pending = false; render() }
        if translationWanted {
            translationWanted = false
            showTranslation()
        }
        if let news = newsWanted {
            newsWanted = nil
            showPetNews(news)                              // 里面会重新看呼吸和系统模式
        }
        if detailBar.isVisible && closeTimer == nil { scheduleClose() }
    }

    // MARK: 点按

    @objc private func goBack() { perform(.back) }

    #if AIQUOTA_TEST
    // 测试用：模拟手指按下、点了屏幕上的第几块、松手
    func tapForTesting(_ index: Int) { scrubber(scrubber, didSelectItemAt: index) }
    func beginInteractionForTesting() { didBeginInteracting(with: scrubber) }
    func endInteractionForTesting() { didFinishInteracting(with: scrubber) }
    var touchGenerationForTesting: Int { touchGeneration }
    var settlingForTesting: Bool { settling }
    var hasTouchSnapshotForTesting: Bool { touchSnapshot != nil }
    /// 模拟某一次松手排的回调现在才跑（不等真的 0.3 秒，结果不看机器快慢）
    func settleForTesting(generation: Int) { settle(generation: generation) }
    var detailViewForTesting: NSView? { detailItem.view }
    var pianoShownForTesting: Bool { !piano.view.isHidden && scrubber.isHidden }
    func leadingIDForTesting() -> String? { scrubber.layoutSubtreeIfNeeded(); return leadingVisibleID() }
    /// 最后一块整块在屏幕里（路线图停在最新的一步）
    func pinnedToEndForTesting() -> Bool { scrubber.layoutSubtreeIfNeeded(); return isPinnedToEnd() }
    /// 第 index 块整块落在可见区域里（滚过去以后）
    func fullyVisibleForTesting(_ index: Int) -> Bool {
        scrubber.scrollItem(at: index, to: .center)
        scrubber.layoutSubtreeIfNeeded()
        let layout = scrubber.scrubberLayout
        guard let f = layout.layoutAttributesForItem(at: index)?.frame, f.width > 0 else { return false }
        return layout.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(NSRect(x: f.minX, y: layout.visibleRect.minY, width: f.width, height: 1))
    }
    /// 模拟手指纯滑动：按下、把第 index 块划到左边缘、松手（不点任何一块）
    func swipeForTesting(to index: Int) {
        didBeginInteracting(with: scrubber)
        scrubber.scrollItem(at: index, to: .leading)
        scrubber.layoutSubtreeIfNeeded()
        didFinishInteracting(with: scrubber)
    }
    func backForTesting() { perform(.back) }
    func tapGlanceForTesting() { toggleDetail() }
    func pretendShownForTesting() { isShown = true }
    func closeTimerFiredForTesting() { closeTimerFired() }
    var tickerIntervalForTesting: TimeInterval? { calmTicker?.timeInterval }
    /// 把「上次摸小猫」挪到很久以前（不用真的等 2.5 秒爱心飘完）
    func forgetPatForTesting() { pattedAt = .distantPast }
    func tickForTesting() { tick() }
    var promptAutoForTesting: Bool { promptAuto }
    var lyricAutoForTesting: Bool { lyricAuto }
    /// 模拟系统告诉我们展开的那条收起了（用户点了 ×，或者 App 自己 closeDetail 之后）
    func detailHiddenForTesting() { detailHidden() }
    var closeRequestsForTesting = 0
    var clearArmedForTesting: Set<String>? { clearArmed }
    func disarmTimeoutForTesting() { disarmTimedOut() }
    #endif

    private func perform(_ action: DetailAction) {
        let fromHome: Page? = page.homeKey == nil ? nil : page
        switch action {
        case .panel: handOff(); onOpenPanel?(); return
        case .session(let key):
            if isRoadPage { onOpenSession?(key); return }      // 路线图上点一步：只打开对话，条不收起（不然收了又弹，闪一下）
            handOff(); onOpenSession?(key); return
        case .project(let command, let key): onProjectAction?(command, key)
        case .select(let key): page = .task(key)
        case .back:
            if case .material = page { page = .shelf }                    // homeChild 留着：材料架再返回还回原来那页
            else if let child = homeChild, child.key == pageKey {
                page = child.home
                homeReturn = child.home.homeKey
                homeChild = nil
            }
            else { page = .overview; homeChild = nil }
        case .lyrics: page = .lyrics
        case .stay, .none: return
        case .link:
            page = .link
            onExpand?()                                      // 打开双机页时问一次本机的 tailscaled
        case .linkConnect: onLink?(.connect)
        case .linkCheck: onLink?(.check)
        case .linkTerminal: handOff(); onLink?(.terminal); return
        case .linkDisconnect:
            if disconnectArmed != nil {
                disarm()
                onLink?(.disconnect)
            } else {
                // 第一下只是「上膛」：卡片变橙、写会断几个远程连接，4 秒内再点才真断
                disconnectArmed = TwoMachine.sshSessions()
                startDisarmTimer()
            }
        case .attention: page = .attention
        case .relay: page = .relay
        case .prompts: page = .prompts
        case .prompt(let id): onPrompt?(id)
        case .editPrompts: handOff(); onEditPrompts?(); return
        case .translation: page = .translation
        case .translateClipboard: page = .translation; onTranslation?(.clipboard)
        case .copyTranslation: onTranslation?(.copy)
        case .translationSettings: handOff(); onTranslation?(.settings); return
        case .lightDismiss(let name, let updated): onLightDismiss?(name, updated)
        case .calm: page = .calm
        // 点了开始就进番茄钟页看着（手指刚松开时 showCalm 不换页，所以这里自己换）
        case .startBreath: page = .calm; onCalm?(.breath)
        case .startFocus: page = .calm; onCalm?(.focus)
        case .stopCalm: onCalm?(.stop)
        case .pet: page = .pet
        case .tools: page = .tools
        case .chats: page = .chats
        case .quota: page = .quota
        case .piano: page = .piano
        case .openRoad:
            // 展开着的条里换成路线图页；记下不再算「关掉了」，和点小图标回路线图一样算路线图摆着
            if let road = activeRoad {
                ambientDismissed.removeAll { $0 == road.dismissKey }
                homeChild = nil
                page = .road
                shownRoad = road.dismissKey
                ambientEngaged = true
                closeTimer?.invalidate()
                closeTimer = nil
            }
        case .watch(let key): onWatch?(key)
        case .petPat:
            pattedAt = Date()
            pats += 1
        case .relayHand(let cwd, let agent): handOff(); onRelay?(.hand(cwd, agent)); return
        case .relayNote(let file): handOff(); onRelay?(.note(file)); return
        case .shelf: page = .shelf
        case .material(let id):
            page = .material(id)
            onShelf?(.copy(id))
        case .shelfAdd: onShelf?(.add)
        case .shelfCopy(let id): onShelf?(.copy(id))
        case .shelfRemove(let id):
            page = .shelf
            onShelf?(.remove(id))
        case .shelfClear:
            let current = Set(shelf.items.map(\.id))
            if let armed = clearArmed, armed == current, !current.isEmpty {
                disarm()
                onShelf?(.clear(current))
            } else if !current.isEmpty {
                clearArmed = current
                startDisarmTimer()
            }
        }
        if case .back = action {} else if let home = fromHome, pageKey != home.homeKey { homeChild = (pageKey, home) }
        dropStaleArming()
        render(force: true)                                  // 自己点的换页立刻换
        if detailBar.isVisible && !interacting && !isRoadPage { scheduleClose() }
    }

    private func disarm() {
        disarmTimer?.invalidate()
        disarmTimer = nil
        disconnectArmed = nil
        clearArmed = nil
    }

    static var disarmDelay: TimeInterval = 4

    private func startDisarmTimer() {
        disarmTimer?.invalidate()
        disarmTimer = Timer.scheduledTimer(withTimeInterval: Self.disarmDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.disarmTimedOut() }
        }
    }

    private func disarmTimedOut() {
        disarm()
        render()
    }

    private func dropStaleArming() {
        if case .link = page {} else { disconnectArmed = nil }
        if case .shelf = page {} else { clearArmed = nil }
        if disconnectArmed == nil && clearArmed == nil { disarm() }
    }

    /// 点小图标：展开 / 收起。在放歌时直接打开歌词页（比指令条优先）
    @objc private func toggleDetail() {
        if detailVisible, ambientEngaged {
            // 路线图摆着时点小图标：展开成完整的；展开着再点：回到路线图（没有路线图了就收起）
            if case .road = page {
                onExpand?()
                page = .overview
                render(force: true)
                scheduleClose()
            } else if activeRoad != nil {
                closeTimer?.invalidate()
                closeTimer = nil
                homeChild = nil
                page = .road
                render(force: true)
            } else {
                if lyricAuto || (Self.showsLyrics(frontApp) && lyricActive) { lyricDismissed = lyric?.title }
                closeDetail()
            }
            return
        }
        if detailVisible {
            // 手动收起：自动弹的，或者在 Chrome 里放着歌时，这首不再自动弹
            if lyricAuto || (Self.showsLyrics(frontApp) && lyricActive) { lyricDismissed = lyric?.title }
            closeDetail()
            return
        }
        onExpand?()
        lyricAuto = false                                  // 手动打开的：暂停、切走都不替用户收
        homeChild = nil
        page = breathing ? .calm : lyricActive ? .lyrics : .overview
        render(force: true)
        if !present() { onOpenPanel?() }
    }

    /// 系统广播直接打开某一页（方便绑快捷键）：pet 小猫的家、calm 番茄钟、attention 待处理、overview 总览
    @objc private func openRequested(_ note: Notification) {
        guard let name = note.object as? String else { return }
        openPage(named: name)
    }

    func openPage(named name: String) {
        let pages: [String: Page] = ["pet": .pet, "tools": .tools, "calm": .calm, "attention": .attention, "overview": .overview, "chats": .chats, "quota": .quota, "piano": .piano]
        guard let target = pages[name], isShown, !interacting, !settling else { return }
        onExpand?()
        lyricAuto = false
        homeChild = nil
        if isRoadPage { ambientEngaged = false; shownRoad = nil }
        page = target
        scrollToStart = true
        render(force: true)
        if detailVisible { scheduleClose() } else if !present() { onOpenPanel?() }
    }

    func open(_ target: Page) {
        if isRoadPage { ambientEngaged = false; shownRoad = nil }      // 条换成别的页了，不再是路线图
        homeChild = nil
        page = target
        render(force: true)
        if detailVisible {
            scheduleClose()
        } else if isShown {
            present()
        }
    }

    func showCalm() {
        guard !interacting, !settling else { return }
        if !detailVisible, !presentationAllowed() { return }
        if promptApp != nil { promptWanted = true }
        open(.calm)
    }

    /// 「做完叫我」叫你了：小猫先说它，弹到小猫的家（小猫关着就去那个任务页，tb 灯去对话页——AI 页只放最要紧的两张，那盏灯不一定在上面）。
    /// 手指按着时松手后再弹一次；呼吸时不弹、事后也不补弹（消息留着，进家能看到）；系统不让弹时不弹；专注照常走
    func showPetNews(_ news: PetNews) {
        petNews = news
        newsWanted = nil
        guard !breathing else { render(); return }        // 呼吸时来的：不弹，也不留到之后（手指按着也一样）
        if interacting || settling { newsWanted = news; return }
        guard presentationAllowed() else { render(); return }   // 真要弹的这一刻再看一次系统触控栏模式
        lyricAuto = false                                  // 这一页不是自动弹的歌词：暂停、切走都不替它收
        if promptApp != nil { promptWanted = true }
        scrollToStart = true                               // 已经停在家的后半段也回到开头：小猫说的话要看得见
        if petEnabled {
            open(.pet)
        } else if news.target.hasPrefix("session:"), tasks.contains(where: { "session:" + $0.session.key == news.target }) {
            open(.task(String(news.target.dropFirst("session:".count))))
        } else {
            open(.chats)
        }
    }

    private func tickerInterval() -> TimeInterval? {
        guard detailVisible || presenter != nil else { return nil }
        switch page {
        case .calm:
            switch calm {
            case .breath: return 1.0 / 15
            case .focus: return 1
            case .none, .rest: return nil
            }
        case .overview, .pet:
            var wanted: [TimeInterval] = []
            if case .pet = page {
                switch calm {
                case .focus, .breath: wanted.append(1)           // 家里专注按钮上的倒计时、呼吸按钮上的吸气/屏住/呼气
                case .none, .rest: break
                }
            }
            if petEnabled {
                let frame = petFrame(at: Date())
                // 等你的小猫在 AI 页上是 44pt 的小格，没有闪烁的「?」，坐着不动；只有小猫的家里才要隔半秒闪一下
                let blinks: Bool = { if case .pet = page { return true }; return false }()
                if PetArt.animating(frame.pose, elapsed: frame.elapsed) && (blinks || frame.pose != .waiting) {
                    wanted.append(frame.pose == .waiting && frame.elapsed >= PetArt.animationLength ? 0.5 : 1.0 / 8)
                }
            }
            return wanted.min()
        default:
            return nil
        }
    }

    private func tick() {
        switch page {
        case .overview, .pet: refreshLive()
        default: render()
        }
    }

    /// 会动的几块（小猫、它说的话、番茄钟）：只重做、只换这几块的图，别的等数据刷新；滚到屏幕外的不画
    static let liveIDs: Set<String> = ["pet", "pet:cat", "pet:say", "pet:focus"]

    private func liveParts() -> [Part]? {
        switch page {
        case .overview:
            guard petEnabled else { return [] }
            let frame = petFrame(at: Date())
            return [Self.petChip(frame.pose, elapsed: frame.elapsed)]
        case .pet:
            return petHomeParts().filter { Self.liveIDs.contains($0.id) }
        default:
            return nil
        }
    }

    private func refreshLive() {
        defer { updateCalmTicker() }
        // 手指在上面：先不换，松手收尾时补一次（不然动画正好在这时结束，会停在半截的那一帧）
        guard !interacting, !settling else { pending = true; return }
        guard pageKey == shownPage, let fresh = liveParts() else { render(); return }
        for part in fresh {
            guard let index = shown.firstIndex(where: { $0.id == part.id }) else { continue }
            guard shown[index].image.size == part.image.size else { render(); return }
            shown[index] = part
            guard let view = scrubber.itemViewForItem(at: index) as? PartView else { continue }
            view.imageView.image = part.image
            view.setAccessibilityLabel(part.label ?? accessibilityLabel(part.action))
        }
    }

    private func updateCalmTicker() {
        let wanted = tickerInterval()
        if let interval = wanted, let current = calmTicker, abs(current.timeInterval - interval) < 0.001 { return }
        calmTicker?.invalidate()
        calmTicker = nil
        guard let interval = wanted else { return }
        calmTicker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    @discardableResult
    private func present() -> Bool {
        lastPresent = clock
        closingByApp = false
        if let presenter {
            presenter(detailBar)
            if !isRoadPage { scheduleClose() }
            return true
        }
        let selector = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        guard let method = class_getClassMethod(NSTouchBar.self, selector) else { return false }
        typealias PresentFn = @convention(c) (AnyObject, Selector, NSTouchBar, Int64, NSString) -> Void
        unsafeBitCast(method_getImplementation(method), to: PresentFn.self)(NSTouchBar.self, selector, detailBar, 0, Self.id.rawValue as NSString)
        Self.setPresence?(Self.id.rawValue as CFString, true)
        if !isRoadPage { scheduleClose() }
        return true
    }

    private var isRoadPage: Bool { if case .road = page { return true }; return false }

    func showTranslation() {
        if interacting || settling {
            translationWanted = true
            return
        }
        if !detailVisible, !presentationAllowed() { return }
        if promptApp != nil { promptWanted = true }
        if isRoadPage { ambientEngaged = false; shownRoad = nil }
        page = .translation
        render(force: true)
        if detailVisible {
            scheduleClose()
        } else if isShown {
            present()
        }
    }

    func setPromptContext(app: String?, autoShow: Bool) {
        let changed = app != promptApp
        promptApp = app
        if changed, case .tools = page { render() }       // 工具页的「常用指令」卡跟着前台 app 出现、消失
        guard app != nil else {
            promptWanted = false
            if promptAuto, detailVisible, case .prompts = page {
                if lyricActive, Self.showsLyrics(frontApp), lyricDismissed != lyric?.title, presentationAllowed() {   // 切到 Chrome、在放：原地换成歌词
                    page = .lyrics
                    render(force: true)
                    lyricAuto = true
                    scheduleClose()
                } else {
                    closeDetail()
                }
            }
            promptAuto = false
            return
        }
        guard changed, autoShow, isShown, !breathing else { return }
        if detailVisible {
            if lyricAuto, case .lyrics = page {           // 从 Chrome 切过来：自动弹的歌词原地换成指令条
                lyricAuto = false
                page = .prompts
                render(force: true)
                promptAuto = true
                scheduleClose()
                return
            }
            if case .prompts = page {} else { promptWanted = true }
            return
        }
        page = .prompts
        render(force: true)
        if present() { promptAuto = true }
    }

    /// 装了歌词扩展的只有 Chrome：它在前台才算在看视频
    static func showsLyrics(_ bundle: String?) -> Bool { bundle?.hasPrefix("com.google.Chrome") == true }

    /// 前台 app 变了：先记下它，再按指令条的规则走（Chrome 和 Claude/Codex 之间切换时，自动弹的歌词和指令条原地互换），
    /// 最后看要不要弹或收歌词。切走再回来，手动收起过的那首也会再弹。
    func frontAppChanged(_ bundle: String?, promptApp app: String?, autoShow: Bool) {
        noteFront(bundle)
        roadFront = bundle
        ownFront = false
        frontAllowed = presentationAllowed()
        setPromptContext(app: app, autoShow: autoShow)
        autoLyrics()
        syncAmbient()
    }

    /// AIQuota 自己的面板、编辑窗口到了前台：指令条照旧按原来的 app 走；歌词当成切走了（不新弹），
    /// 但已经弹着的不收——面板一关就回去了
    func ownAppFront(_ bundle: String?) {
        noteFront(bundle)
        ownFront = true
        autoLyrics()
    }

    private func noteFront(_ bundle: String?) {
        guard bundle != frontApp else { return }
        frontApp = bundle
        lyricDismissed = nil
    }

    /// 点了去别处的按钮（面板、Claude、终端……）：收起，而且在切到那边之前别马上又自动弹回来
    private func handOff() {
        lyricDismissed = lyric?.title
        closeDetail()
    }

    /// 扩展每秒一次的心跳：内容没变时 model 不调 update，这里只把收到时间跟上，
    /// 不然前奏、间奏超过 8 秒就会被当成停了（到时间收起、点小图标开成指令条、切回 Chrome 不弹）
    func refreshLyric(_ lyric: NowLyric?) {
        self.lyric = lyric
        autoLyrics()
    }

    /// 测试里 update 的 now 会往后拨；平时就是现在
    private var clock: Date { max(now, Date()) }

    /// 看视频时自动弹歌词：Chrome 在前台、在放、有词就弹歌词页；还停在自动弹的歌词页时，暂停、停了、切走就收起。
    /// 用户收起（点小图标，或系统的 ×——没有回调，见 detailHidden）后这首不再弹。
    private func autoLyrics() {
        if let dismissed = lyricDismissed, let title = lyric?.title, title != dismissed { lyricDismissed = nil }   // 换了一首
        let wanted = lyricActive && Self.showsLyrics(frontApp)
        if lyricAuto {
            // 翻到别的页了就不替用户收；手指按着时等松手（settle 会再来一次）
            if case .lyrics = page, detailVisible, !wanted, !ownFront, !interacting, !settling { closeDetail() }
            return
        }
        guard wanted, isShown, !detailVisible, clock.timeIntervalSince(lastPresent) > 2, lyricDismissed != lyric?.title,
              !interacting, !settling, !breathing, presentationAllowed() else { return }
        page = .lyrics
        render(force: true)
        if present() { lyricAuto = true }
    }

    /// 展开的那条收起了（isVisible 的 KVO 告诉的）。不是 App 自己收的就是用户点了系统的 ×：在 Chrome 里放着歌时这首不再弹。
    /// 收起后再看一次：比如从 Claude 切回 Chrome 时指令条收了，接着就弹歌词
    private func detailHidden() {
        homeChild = nil                                    // 收起后「返回回到小猫的家/工具页」作废，下次展开从 AI 页算起
        // 收起了就别再出声，也离开钢琴页：不然之后的数据刷新还走钢琴页，会在收起状态下把引擎重新打开（引擎开着 Mac 就不会自动睡眠）
        piano.deactivate(notify: false)
        if case .piano = page {
            page = .pet
            piano.view.isHidden = true
            scrubber.isHidden = false
        }
        if ambientEngaged {
            ambientEngaged = false
            if !closingByApp, let key = shownRoad {                                          // 你点了系统的 ×：这一轮不再弹
                ambientDismissed.append(key)
                if ambientDismissed.count > 20 { ambientDismissed.removeFirst(ambientDismissed.count - 20) }
            }
            shownRoad = nil
        }
        if !closingByApp, lyricAuto || (Self.showsLyrics(frontApp) && lyricActive) { lyricDismissed = lyric?.title }
        closingByApp = false
        lyricAuto = false
        autoLyrics()
        syncAmbient()
    }

    static let pianoIdleClose: TimeInterval = 120      // 钢琴页两分钟没碰才自动收起

    private func scheduleClose() {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeTimerFired() }
        }
    }

    private func closeTimerFired() {
        // 摸着的时候、歌词页在放的时候一直开着；停了（或扩展不再报）才收起
        if interacting || settling { scheduleClose(); return }
        if case .road = page { return }                    // 路线图摆着时不到时间收起，由前台 app 和任务状态决定
        if case .lyrics = page, lyricActive { scheduleClose(); return }
        if case .prompts = page, promptApp != nil { scheduleClose(); return }
        if case .translation = page, case .working = translation { scheduleClose(); return }
        if case .calm = page, breathing { scheduleClose(); return }
        if case .piano = page, Date().timeIntervalSince(piano.lastTouch) < Self.pianoIdleClose { scheduleClose(); return }   // 弹着的时候不收
        if promptWanted, promptApp != nil {
            promptWanted = false
            // 有路线图要摆（没被关）：收起，收起后它会回来，不转成常驻的指令条把它挡住
            if wantRoadData, let road = activeRoad, !isDismissed(road) { closeDetail(); return }
            page = .prompts
            render(force: true)
            promptAuto = true
            scheduleClose()
            return
        }
        closeDetail()
    }

    func closeDetail() {
        closeTimer?.invalidate()
        closeTimer = nil
        disarm()
        closingByApp = true                                // 收起后 detailHidden 就知道不是用户点的 ×
        lyricAuto = false
        #if AIQUOTA_TEST
        closeRequestsForTesting += 1
        #endif
        guard detailBar.isVisible else { return }
        let cls: AnyObject = NSTouchBar.self
        let sel = NSSelectorFromString("minimizeSystemModalTouchBar:")
        if cls.responds(to: sel) { _ = cls.perform(sel, with: detailBar) }
        Self.setPresence?(Self.id.rawValue as CFString, isShown)
    }
}

// MARK: - 弹出面板

func barColor(_ pace: QuotaWindow.Pace) -> Color {
    Color(nsColor: pace.color ?? .systemGreen)
}

struct QuotaBar: View {
    var fraction: Double
    var marker: Double? = nil   // 这一轮时间走到的位置
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color)
                    .frame(width: fraction > 0 ? max(6, geo.size.width * min(1, fraction)) : 0)
                if let m = marker {
                    Rectangle().fill(Color.primary.opacity(0.75))
                        .frame(width: 1.5, height: 10)
                        .offset(x: geo.size.width * m - 0.75)
                }
            }
        }
        .frame(height: 6)
    }
}

struct WindowRow: View {
    let window: QuotaWindow
    let stale: Bool
    let now: Date
    var reminder: ReminderStatus = .off

    var body: some View {
        let w = window.effective(at: now)
        let pace = w.pace(at: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(w.label).font(.system(size: 12)).frame(width: 38, alignment: .leading)
                QuotaBar(fraction: w.used / 100, marker: stale ? nil : w.elapsed(at: now),
                         color: stale ? Color.secondary : barColor(pace))
                Text(Fmt.pct(w.used))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(stale ? Color.secondary : Color.primary)
                    .frame(width: 40, alignment: .trailing)
            }
            Text(Fmt.reset(w, now: now))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 46)
            if !stale, pace != .ok, let t = w.runsOut(at: now) {
                Text("照这一轮的速度，约 \(Fmt.clock(t, now: now)) 用完")
                    .font(.system(size: 10.5))
                    .foregroundStyle(barColor(pace))
                    .padding(.leading, 46)
            }
            if let hint = Fmt.reminderHint(w, status: reminder, now: now) {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(reminder == .denied ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 46)
            }
        }
    }
}

struct SessionSection: View {
    @ObservedObject var model: AppModel
    @State private var attentionOnly = false

    var body: some View {
        let tasks = model.tasks(at: model.now)
        let waiting = tasks.filter { $0.light == .waiting }.count
        let filtered = attentionOnly ? tasks.filter { $0.light == .waiting || $0.light == .error } : tasks
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(waiting > 0 ? "等你处理 · \(waiting)" : "AI 任务与项目")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(waiting > 0 ? Color.orange : Color.primary)
                Spacer()
                Button(attentionOnly ? "查看全部" : "只看待处理") { attentionOnly.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if filtered.isEmpty {
                Text(attentionOnly ? "没有需要处理的任务" : "AI 会话有新活动后会显示在这里")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(filtered, id: \.session.key) { item in
                            Button {
                                model.selectedSessionKey = model.selectedSessionKey == item.session.key ? nil : item.session.key
                                model.actionMessage = ""
                            } label: {
                                HStack(spacing: 8) {
                                    dot(item.light)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.session.displayTitle)
                                            .font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(item.session.agentName + " · " + item.session.briefStatus(item.light, now: model.now))
                                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: model.selectedSessionKey == item.session.key ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(model.selectedSessionKey == item.session.key ? Color.primary.opacity(0.07) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(item.session.displayTitle + "\n" + item.session.cwd)
                        }
                    }
                }
                .frame(height: min(185, CGFloat(filtered.count) * 48))
            }
            if let key = model.selectedSessionKey, let s = tasks.first(where: { $0.session.key == key })?.session {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.cwd.isEmpty ? "未记录项目目录" : s.cwd)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    HStack(spacing: 7) {
                        Button("打开 " + s.agentName) { model.open(key) }
                        Button("文件夹") { model.projectAction(.folder, key: key) }
                            .disabled(ProjectActions.directory(s.cwd) == nil)
                        Button("终端") { model.projectAction(.terminal, key: key) }
                            .disabled(ProjectActions.directory(s.cwd) == nil)
                        Spacer(minLength: 0)
                        Button(model.copyingSessionKey == key ? "整理中…" : "复制交接") {
                            model.projectAction(.handoff, key: key)
                        }
                        .disabled(model.copyingSessionKey != nil)
                    }
                    .font(.system(size: 11)).controlSize(.small)
                    if model.actionSessionKey == key && !model.actionMessage.isEmpty {
                        Text(model.actionMessage).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(9)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    @ViewBuilder private func dot(_ light: Light) -> some View {
        switch light {
        case .running: Circle().fill(Color(nsColor: .secondaryLabelColor)).frame(width: 7, height: 7)
        case .idle: Circle().stroke(Color(nsColor: .tertiaryLabelColor), lineWidth: 1.2).frame(width: 7, height: 7)
        default: Circle().fill(Color(nsColor: light.color)).frame(width: 7, height: 7)
        }
    }
}

struct ProviderSection: View {
    let p: Provider
    let now: Date
    var reminder: ReminderStatus = .off
    var body: some View {
        let stale = p.isStale(at: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(p.name).font(.system(size: 13, weight: .bold))
                if !p.detail.isEmpty {
                    Text(p.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.age(p.updatedAt, now: now))
                    .font(.system(size: 10.5))
                    .foregroundStyle(stale ? Color.orange : Color.secondary)
            }
            ForEach(Array(p.windows.enumerated()), id: \.offset) { item in
                WindowRow(window: item.element, stale: stale, now: now, reminder: reminder)
            }
            if let e = p.error {
                Text(e)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// ZCode：没有可查的计划额度，面板里如实写本机记账的 token 数
struct ZcodeSection: View {
    let p: Provider
    let now: Date

    var body: some View {
        let tokens = p.tokens ?? (0, 0)
        let stale = p.isStale(at: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(p.name).font(.system(size: 13, weight: .bold))
                Text(p.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.age(p.updatedAt, now: now))
                    .font(.system(size: 10.5))
                    .foregroundStyle(stale ? Color.orange : Color.secondary)
            }
            Text("今日 " + Fmt.tokens(Double(tokens.today)) + " tokens · 近 7 天 " + Fmt.tokens(Double(tokens.week)) + " tokens")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            Text("按本机会话记账统计（ZCode 会话库），不是计划额度，用超不超不知道")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 两台电脑：Tailscale 开没开、WSL 在不在线、三条线路查一遍的结果
struct LinkSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let l = model.link
        let now = model.now
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("两台电脑").font(.system(size: 13, weight: .bold))
                Text(status(l, now: now)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            if let c = l.check {
                HStack(spacing: 6) {
                    Text(c.summary).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(c.ok ? Color.secondary : Color.red)
                    Spacer()
                    Text(Fmt.short(now.timeIntervalSince(c.at)) + "前查过").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if !c.ok && !c.reason.isEmpty {
                    Text(c.reason).font(.system(size: 10.5)).foregroundStyle(Color.red)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if let e = l.error {
                Text(e).font(.system(size: 10.5)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let k = l.keyExpiry, k.timeIntervalSince(now) < 14 * 86400 {
                Text("Tailscale 登录密钥 " + Fmt.short(max(0, k.timeIntervalSince(now))) + "后过期，到期前在 Tailscale 里重新登录")
                    .font(.system(size: 10.5)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 7) {
                if l.on {
                    Button(l.busy == .checking ? "检查中…" : "检查线路") { model.linkAction(.check) }
                    Button("SSH 终端") { model.linkAction(.terminal) }.disabled(l.pcOnline == false)
                    Spacer(minLength: 0)
                    Button(l.busy == .disconnecting ? "断开中…" : "断开…") { confirmDisconnect() }
                } else {
                    Button(l.busy == .connecting ? "连接中…" : "连接") { model.linkAction(.connect) }
                    Spacer(minLength: 0)
                    Text("平时关着省电，用时再连").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11)).controlSize(.small)
            .disabled(l.busy != nil)
        }
    }

    private func status(_ l: LinkState, now: Date) -> String {
        if !l.on { return "未连（Tailscale 关着）" + (l.pcLastSeen.map { " · WSL 上次在线 " + Fmt.short(now.timeIntervalSince($0)) + "前" } ?? "") }
        var parts = ["已连" + (l.since.map { " " + Fmt.short(now.timeIntervalSince($0)) } ?? "")]
        if let d = l.direct { parts.append(d ? "直连" : "经中转" + (l.relay.isEmpty ? "" : " " + l.relay)) }
        switch l.pcOnline {
        case true?: parts.append("WSL 在线")
        case false?: parts.append("WSL 离线" + (l.pcLastSeen.map { "（上次 " + Fmt.short(now.timeIntervalSince($0)) + "前）" } ?? ""))
        default: break
        }
        if let idle = l.idleShown(at: now) { parts.append("空闲 " + Fmt.short(idle)) }
        return parts.joined(separator: " · ")
    }

    private func confirmDisconnect() {
        let n = TwoMachine.sshSessions()
        let alert = NSAlert()
        alert.messageText = "断开两台电脑的连接？"
        alert.informativeText = (n > 0 ? "现在有 \(n) 个连到 win 的 SSH 会断掉。" : "现在没有连到 win 的 SSH。")
            + "会关掉本机的 Tailscale（两边的 AI 会话、Docker 都不受影响），要用时再点「连接」。"
        alert.addButton(withTitle: "断开")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.linkAction(.disconnect) }
    }
}

struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 菜单栏面板的「退出」要点两下：第一下只是上膛，3 秒内再点才退出（误点一下不会把触控栏小图标、会话灯都停掉）
struct QuitGuard {
    static let window: TimeInterval = 3
    private var armedAt: Date?

    mutating func tap(at now: Date) -> Bool {
        if let armedAt, now.timeIntervalSince(armedAt) < Self.window {
            self.armedAt = nil
            return true
        }
        armedAt = now
        return false
    }

    func armed(at now: Date) -> Bool { armedAt.map { now.timeIntervalSince($0) < Self.window } ?? false }
}

struct PopoverView: View {
    @ObservedObject var model: AppModel
    let screenHeight: CGFloat
    @State private var contentHeight: CGFloat = 0
    @State private var quitGuard = QuitGuard()
    @State private var quitArmed = false

    init(model: AppModel, screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800) {
        self.model = model
        self.screenHeight = screenHeight
    }

    static func scrollLimit(screenHeight: CGFloat) -> CGFloat { max(240, screenHeight - 150) }

    var body: some View {
        let limit = Self.scrollLimit(screenHeight: screenHeight)
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.vertical) {
                sections
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { proxy in Color.clear.preference(key: PopoverHeightKey.self, value: proxy.size.height) })
            }
            .frame(height: min(contentHeight > 0 ? contentHeight : limit, limit))
            .onPreferenceChange(PopoverHeightKey.self) { contentHeight = $0 }
            Divider()
            HStack(spacing: 10) {
                Button(model.refreshing ? "刷新中…" : "刷新") { Task { await model.refreshAll() } }
                    .disabled(model.refreshing)
                Toggle("开机启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("接入…") { Setup.presentDialog(firstRun: false) }
                    .help("接上 Claude Code / Codex / ZCode 的会话灯、tb 命令、开机启动、Chrome 歌词扩展")
                Button("配置") { model.openConfig() }
                Button(quitArmed ? "再点退出" : "退出") {
                    // 要点两下：一下只是「上膛」，3 秒内再点才退出（退出后触控栏小图标、会话灯都会停）
                    if quitGuard.tap(at: Date()) { NSApp.terminate(nil); return }
                    quitArmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + QuitGuard.window) { quitArmed = quitGuard.armed(at: Date()) }
                }
                .foregroundStyle(quitArmed ? Color.orange : Color.primary)
                .help("退出 AI 限额：要点两下")
            }
            .font(.system(size: 12))
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 400)
    }

    @ViewBuilder private var sections: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderSection(p: model.claude, now: model.now, reminder: model.reminderStatus)
            if model.config.claudeWeeklyReset.isEmpty {
                Text("Claude 每周重置时间没填时按用量记录推算（约）；要更准可在「配置」里填写（Claude 桌面 app 设置 → 用量 里能看到）")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(model.codex.enumerated()), id: \.offset) { item in
                Divider()
                ProviderSection(p: item.element, now: model.now, reminder: model.reminderStatus)
            }
            if let z = model.zcode {
                Divider()
                ZcodeSection(p: z, now: model.now)
            }
            if !model.sessions.isEmpty {
                Divider()
                SessionSection(model: model)
            }
            if !model.relayPairs(at: model.now).isEmpty {
                Divider()
                RelaySection(model: model)
            }
            if !model.customLights.isEmpty {
                Divider()
                LightSection(model: model)
            }
            Divider()
            ShelfSection(model: model)
            Divider()
            PromptSection(model: model)
            Divider()
            TranslateSection(model: model)
            Divider()
            CalmSection(model: model)
            if model.link.available {
                Divider()
                LinkSection(model: model)
            }
        }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let touchBar = TouchBarItem()
    private var translateService: TranslateService?
    private var timers: [Timer] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "AIQuota"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        touchBar.onOpenPanel = { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.togglePopover(nil)
        }
        touchBar.onOpenSession = { [weak self] key in self?.model.open(key) }
        touchBar.onProjectAction = { [weak self] action, key in self?.model.projectAction(action, key: key) }
        touchBar.onLink = { [weak self] action in self?.model.linkAction(action) }
        touchBar.onShelf = { [weak self] command in self?.model.shelfAction(command) }
        touchBar.onRelay = { [weak self] command in self?.model.relayCommand(command) }
        touchBar.onPrompt = { [weak self] id in self?.model.usePrompt(id) }
        touchBar.onLightDismiss = { [weak self] name, updated in self?.model.dismissLight(name, updated: updated) }
        touchBar.onTranslation = { [weak self] command in
            guard let model = self?.model else { return }
            switch command {
            case .clipboard: model.translateClipboard()
            case .copy: model.copyTranslation()
            case .settings: model.openTranslationSettings()
            }
        }
        model.onTranslate = { [weak self] in
            guard let self else { return }
            if self.model.config.touchBar { self.touchBar.showTranslation() } else if !self.popover.isShown { self.togglePopover(nil) }
        }
        touchBar.onCalm = { [weak self] command in self?.model.calmCommand(command) }
        touchBar.onWatch = { [weak self] key in self?.model.toggleWatch(key) }
        touchBar.onRoadWanted = { [weak self] wanted in self?.model.setRoadWanted(wanted) }
        model.onWatchFired = { [weak self] news in self?.touchBar.showPetNews(news) }
        model.onCalm = { [weak self] in
            guard let self else { return }
            if self.model.config.touchBar { self.touchBar.showCalm() } else if !self.popover.isShown { self.togglePopover(nil) }
        }
        TouchBarItem.forgetTrayItem("local.aiquota.touchbar.pet")
        translateService = TranslateService(model: model)
        NSApp.servicesProvider = translateService
        NSUpdateDynamicServices()
        touchBar.onEditPrompts = { [weak self] in
            guard let self else { return }
            self.model.promptEditorRequested = true
            if !self.popover.isShown { self.togglePopover(nil) }
        }
        model.loadPrompts()
        touchBar.onExpand = { [weak self] in self?.model.updateLink(forceDetail: true, maxAge: 30) }

        UNUserNotificationCenter.current().delegate = self
        model.onUpdate = { [weak self] in self?.updateStatusItem() }
        model.watchSessions()
        model.watchLights()
        LyricsBridge.installHostManifest(enabled: model.config.lyrics)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lyricArrived(_:)), name: LyricsBridge.notification,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(calmRequested(_:)), name: Notification.Name("local.aiquota.calm"),
                                                            object: nil, suspensionBehavior: .deliverImmediately)
        updateStatusItem()
        Setup.onChanged = { [weak self] in
            MainActor.assumeIsolated { self?.model.launchAtLogin = LoginItem.isEnabled }   // 设置窗口里改了开机启动：面板的勾选跟着变
        }
        Setup.onLaunch()                                   // 第一次打开：弹「接入」窗口；换了位置：把 hooks 里的路径改对
        frontmostChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontmostChanged(bundle) }
        }
        Task { await model.refreshAll() }

        // 每 30 秒看一次，按配置里当前的 refreshSeconds 决定要不要联网刷新（改了配置不用重启）
        let refresh = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let model = self?.model else { return }
                await model.refreshAll(minInterval: model.config.refreshSeconds - 5)
            }
        }
        let tick = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.tick() }
        }
        for t in [refresh, tick] {
            RunLoop.main.add(t, forMode: .common)
            timers.append(t)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.didSleep(now: Date()) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.didWake(now: Date()) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // 等网络恢复
                await self?.model.refreshAll()
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let open = response.notification.request.content.userInfo["open"] as? String
        Task { @MainActor in
            // 「额度恢复了」里带着被限流停下的任务：直接打开那条对话；别的通知打开菜单栏面板
            if let open, self.model.sessions.contains(where: { $0.key == open }) { self.model.open(open); return }
            if !self.popover.isShown { self.togglePopover(nil) }
        }
        completionHandler()
    }

    private func frontmostChanged(_ bundle: String?) {
        let target = PromptTargets.resolve(bundle, own: Bundle.main.bundleIdentifier)
        if target.ignore { touchBar.ownAppFront(bundle); return }
        let allowed = SystemTouchBar.allowsPresentation(for: bundle)
        touchBar.frontAppChanged(bundle, promptApp: target.app, autoShow: model.promptStore.autoShow && model.config.touchBar && allowed)
    }

    @objc private func calmRequested(_ note: Notification) {
        switch note.object as? String {
        case "breath": model.calmCommand(.breath)
        case "focus": model.calmCommand(.focus)
        case "stop": model.calmCommand(.stop)
        default: break
        }
    }

    @objc private func lyricArrived(_ note: Notification) {
        guard let json = note.userInfo?["json"] as? String, json.utf8.count < 64 * 1024,
              let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
        model.receiveLyric(o)
        touchBar.refreshLyric(model.lyric)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        model.tick()
        model.updateLink(forceDetail: true, maxAge: 30)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        Task { await model.refreshAll(minInterval: 15) }
    }

    private func updateStatusItem() {
        let rows = model.rows
        let now = model.now
        statusItem.button?.image = StatusImage.make(rows: rows, now: now)
        touchBar.update(rows: rows, lights: model.lights(at: now), tasks: model.tasks(at: now), now: now,
                        feedback: model.actionMessage, feedbackKey: model.actionSessionKey, copyingKey: model.copyingSessionKey,
                        lyric: model.lyric, link: model.link, shelf: model.shelf, shelfNote: model.shelfNote,
                        relays: model.relayPairs(at: now), prompts: model.promptStore.items, promptNote: model.promptNote,
                        customLights: model.customLights, translation: model.translation, calm: model.calm,
                        pet: PetMood.from(model.lights(at: now).map(\.light)), petEnabled: model.petEnabled,
                        receipts: model.receiptSlots, watchCards: model.watchCards, watched: model.watchedKeys, news: model.activeNews(at: Date()),
                        allLights: model.allLights, roads: model.roadmaps(at: Date()), ambient: model.ambientEnabled,
                        zcodeUsage: model.zcode)
        touchBar.setShown(model.config.touchBar)
        model.syncReminders()
        statusItem.button?.toolTip = rows.map { p in
            let parts = p.windows.map { w -> String in
                let e = w.effective(at: now)
                return "\(e.label) \(Fmt.pct(e.used))"
            }
            return p.name + " " + (parts.isEmpty ? (p.error ?? "暂无数据") : parts.joined(separator: " · "))
        }.joined(separator: "\n")
    }
}

// MARK: - 截图（--snapshot <目录>，用来检查界面）

@MainActor
enum Snapshot {
    static func write(model: AppModel, dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = model.now
        model.sessions = demoSessions(now: now)   // 会话用假数据，几种状态都能看到
        model.selectedSessionKey = model.sessions.first(where: { $0.state == .waiting })?.key
        let image = StatusImage.make(rows: model.rows, now: now)
        for dark in [false, true] {
            let name = dark ? "dark" : "light"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            status(image, appearance: appearance, background: dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.92, alpha: 1),
                   to: "\(dir)/menubar-\(name).png")
            view(PopoverView(model: model), appearance: appearance, to: "\(dir)/popover-\(name).png")
            view(PopoverView(model: model, screenHeight: 4000), appearance: appearance, to: "\(dir)/popover-full-\(name).png")
        }
        // 触控栏：收起时的小图标（按实际大小），和点开后的整条
        let lights = model.lights(at: now)
        for (name, rows) in [("touchbar", model.rows), ("touchbar-demo", demoRows(now: now))] {
            touchBar([TouchBarArt.glance(rows: rows, lights: lights.map(\.light), now: now)], to: "\(dir)/\(name)-glance.png")
            let mood = PetMood.from(model.lights(at: now).map(\.light))
            let pet = TouchBarItem.petChip(PetPose.of(mood: mood, calm: .none, music: false, patted: false), elapsed: 10)
            touchBar(TouchBarItem.aiPage(rows: rows, tasks: model.tasks(at: now), lights: [], relays: [], watched: [], now: now,
                                         link: TouchBarItem.linkChip(demoLink(now: now, on: true), now: now), pet: pet).map(\.image),
                     to: "\(dir)/\(name)-detail.png")
        }
        writeAIPage(dir: dir, now: now)
        writePiano(dir: dir)
        let demoLyric = NowLyric(site: "bilibili", title: "晴天 · 周杰伦", line: "刮风这天 我试过握着你手",
                                 next: "但偏偏 雨渐渐 大到我看你不见", kind: "lyrics", playing: true, received: now)
        touchBar(TouchBarItem.lyricImages(demoLyric).map(\.image), to: "\(dir)/touchbar-lyrics.png")
        touchBar([TouchBarArt.glance(rows: model.rows, lights: lights.map(\.light), now: now, lyric: true)], to: "\(dir)/touchbar-glance-lyric.png")
        let longLine = NowLyric(site: "youtube", title: "Lex Fridman Podcast", line: "and I think the most important thing about building these systems is that you have to be honest about what you don't know",
                                next: "", kind: "subtitle", playing: true, received: now)
        touchBar(TouchBarItem.lyricImages(longLine).map(\.image), to: "\(dir)/touchbar-lyrics-long.png")
        let tasks = model.tasks(at: now)
        if let first = tasks.first {
            touchBar(TouchBarItem.projectImages(item: first, now: now).map(\.image), to: "\(dir)/touchbar-project.png")
        }
        // 双机：小图标的三种线、小猫的家里的双机卡、双机页的几种状态
        for (name, l) in [("none", TouchBarArt.GlanceLink.none), ("online", .online), ("offline", .offline)] {
            touchBar([TouchBarArt.glance(rows: model.rows, lights: lights.map(\.light), now: now, link: l)], to: "\(dir)/touchbar-glance-link-\(name).png")
        }
        let on = demoLink(now: now, on: true), off = demoLink(now: now, on: false)
        touchBar([TouchBarItem.linkChip(on, now: now).image, TouchBarItem.linkChip(off, now: now).image], to: "\(dir)/touchbar-link-card.png")
        touchBar([TouchBarItem.linkChip(off, now: now).image], to: "\(dir)/touchbar-link-card-off.png")
        touchBar(TouchBarItem.linkImages(off, now: now, armed: nil).map(\.image), to: "\(dir)/touchbar-link-off.png")
        touchBar(TouchBarItem.linkImages(on, now: now, armed: nil).map(\.image), to: "\(dir)/touchbar-link-on.png")
        touchBar(TouchBarItem.linkImages(on, now: now, armed: 2).map(\.image), to: "\(dir)/touchbar-link-armed.png")
        var bad = on
        bad.pcOnline = false
        bad.pcLastSeen = now.addingTimeInterval(-7300)
        bad.direct = nil
        bad.check = LinkCheck(at: now, macToWSL: false, wslToMac: nil, winToMac: nil, reason: "Mac → Windows/WSL 失败。检查 Windows 是否开机并登录、WSL 的 Tailscale 和 ssh 服务是否在线。")
        touchBar(TouchBarItem.linkImages(bad, now: now, armed: nil).map(\.image), to: "\(dir)/touchbar-link-bad.png")
        writeAttentionAndShelf(dir: dir, rows: demoRows(now: now), now: now)
        writeRelay(dir: dir, rows: demoRows(now: now), now: now)
        writePrompts(dir: dir)
        writeTools(dir: dir, now: now)
        writeCalm(dir: dir, rows: demoRows(now: now), now: now)
        writeRoad(dir: dir)
        var spent = demoRows(now: now)[1]
        spent.windows[0].used = 100
        touchBar([TouchBarArt.provider(spent, now: now)], to: "\(dir)/touchbar-provider-recovering.png")
    }

    /// 连着 42 分、直连、空闲 12 分、刚查过线路都正常；或者关着、PC 两小时前还在线
    static func demoLink(now: Date, on: Bool) -> LinkState {
        var l = LinkState()
        l.available = true
        l.on = on
        l.pcLastSeen = now.addingTimeInterval(on ? 0 : -7300)
        if on {
            l.since = now.addingTimeInterval(-42 * 60)
            l.pcOnline = true
            l.direct = true
            l.lastTraffic = now.addingTimeInterval(-12 * 60)
            l.check = LinkCheck(at: now.addingTimeInterval(-60), macToWSL: true, wslToMac: true, winToMac: true, reason: "")
        }
        return l
    }

    static func demoSessions(now: Date) -> [AgentSession] {
        let items: [(agent: String, title: String, state: SessionState, ago: TimeInterval)] = [
            ("claude", "Mac Touch Bar 优化", .running, 3 * 60),
            ("codex", "SN61 文档整理", .waiting, 2 * 60),
            ("claude", "AI 限额显示", .done, 4 * 60),
            ("codex", "两台电脑互联", .done, 25 * 60),
        ]
        return items.enumerated().map { i, it in
            let t = now.addingTimeInterval(-it.ago)
            return AgentSession(agent: it.agent, id: "demo\(i)", state: it.state, since: t, updated: t,
                                first: now.addingTimeInterval(Double(i) * 60 - 3600), title: it.title, bundle: "",
                                cwd: FileManager.default.currentDirectoryPath, waitReason: it.state == .waiting ? "question" : "")
        }
    }

    /// 一个用得比时间快（橙）、一个快满了（红）的额度
    static func demoRows(now: Date) -> [Provider] {
        func w(_ label: String, _ used: Double, _ length: TimeInterval, left: TimeInterval?) -> QuotaWindow {
            QuotaWindow(label: label, short: "", used: used, resetsAt: left.map { now.addingTimeInterval($0) }, length: length)
        }
        return [
            Provider(name: "Claude", windows: [w("5小时", 62, 5 * 3600, left: 3 * 3600), w("本周", 35, 7 * 86400, left: nil)], updatedAt: now),
            Provider(name: "Codex", windows: [w("5小时", 18, 5 * 3600, left: 1.5 * 3600), w("本周", 91, 7 * 86400, left: 2 * 86400)], updatedAt: now),
        ]
    }

    /// 触控栏预览：几张图横着排，底色是纯黑，文字按深色外观取色
    static func touchBar(_ images: [NSImage], to path: String) {
        let gap: CGFloat = 4
        let width = images.reduce(0) { $0 + $1.size.width } + gap * CGFloat(max(0, images.count - 1))
        let strip = NSImage(size: NSSize(width: width, height: TouchBarArt.height), flipped: false) { _ in
            var x: CGFloat = 0
            for img in images {
                img.draw(in: NSRect(x: x, y: 0, width: img.size.width, height: img.size.height))
                x += img.size.width + gap
            }
            return true
        }
        status(strip, appearance: NSAppearance(named: .darkAqua)!, background: .black, to: path)
    }

    private static func status(_ image: NSImage, appearance: NSAppearance, background: NSColor, to path: String) {
        let size = NSSize(width: image.size.width + 12, height: image.size.height)
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.draw(in: NSRect(x: 6, y: 0, width: image.size.width, height: image.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func view<V: View>(_ content: V, appearance: NSAppearance, to path: String) {
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

#if !AIQUOTA_TEST
@main
struct AIQuotaMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        // hooks 调用：写完状态就退出，不碰窗口服务器
        if args.count > 1, args[1].hasPrefix("chrome-extension://") {
            LyricsBridge.runHost()
            return
        }
        if args.count > 1, args[1] == "--tb" {
            exit(TB.main(Array(args.dropFirst(2))))
        }
        if let i = args.firstIndex(of: "--hook") {
            SessionHook.run(agentArg: i + 1 < args.count ? args[i + 1] : "claude")
            return
        }
        // Windows 小乔经 ssh 拉的会话快照（SessionSnapshot.swift）：只读，打印完就退出
        if args.contains("--sessions-json") {
            SessionSnapshot.run()
            return
        }
        // 卸载脚本用：去掉三个 AI 里 AIQuota 的 hooks、tb、开机启动（--purge 再删数据目录），打印做了什么
        if args.contains("--uninstall") {
            let result = Setup.uninstall(home: Setup.home, purge: args.contains("--purge"))
            for line in result.lines { print(line) }
            if !result.ok { exit(1) }                       // 有配置改不了：卸载脚本看到失败就不删 app
            return
        }
        // 只看不改：三个 AI 的 hooks 接没接、指没指向这个程序
        if args.contains("--setup-check") {
            let home = Setup.home
            for agent in Setup.Agent.allCases {
                let (config, error) = Setup.read(agent.configURL(home: home))
                let state: String
                if !agent.installed(home: home) { state = "没装" }
                else if let config {
                    state = Setup.current(config, agent: agent, exe: Setup.exe, dataDir: Setup.dataDir) ? "已接好（指向这个程序）"
                        : Setup.present(config, agent: agent) ? "接过，但指向别处或不全" : "没接"
                } else { state = "配置读不了：" + (error ?? "") }
                print(agent.name + "：" + state)
            }
            return
        }
        // 不弹窗的安装（脚本、验证用）：接上装了的 AI 的 hooks 和 tb；--login 加开机启动
        if args.contains("--setup-auto") {
            if let reason = Setup.unstableLocation(Bundle.main.bundlePath) { print("没有设置：" + reason); exit(1) }
            let home = Setup.home
            let agents = Set(Setup.Agent.allCases.filter { $0.installed(home: home) })
            let report = MainActor.assumeIsolated {
                Setup.run(Setup.Choice(agents: agents, tb: true, login: args.contains("--login") || LoginItem.isEnabled, chrome: false), home: home)
            }
            Setup.saveOffered(agents)
            print(report)
            return
        }

        let app = NSApplication.shared
        if let i = args.firstIndex(of: "--snapshot-demo"), i + 1 < args.count {
            let model = AppModel()
            let rows = Snapshot.demoRows(now: model.now)
            model.claude = rows[0]
            model.codex = Array(rows.dropFirst())
            model.link = Snapshot.demoLink(now: model.now, on: true)
            model.shelf = Snapshot.demoShelf()
            app.setActivationPolicy(.accessory)
            Snapshot.write(model: model, dir: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = args[i + 1]
            let model = AppModel()
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                await model.refreshAll()
                model.updateLink(forceDetail: true, maxAge: 0)             // 真实的双机状态（只问本机的 tailscaled）
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                Snapshot.write(model: model, dir: dir)
                exit(0)
            }
            app.run()
            return
        }
        // 已经有一个在菜单栏里了就退出——除非那一份是从安装盘 / 临时位置打开的、这一份在正经位置：那就关掉那份，这份接着来
        if let bid = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid).filter { $0 != NSRunningApplication.current }
            if !others.isEmpty {
                let temporary = others.allSatisfy { Setup.unstableLocation($0.bundleURL?.path ?? "") != nil }
                guard temporary, Setup.unstableLocation(Bundle.main.bundlePath) == nil else { return }
                others.forEach { $0.terminate() }
                for _ in 0..<30 where others.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.1) }
                others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            }
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#endif
