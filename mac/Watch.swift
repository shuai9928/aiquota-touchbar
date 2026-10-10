import AppKit
import UserNotifications

/// 做完叫我：在任务页（Claude、Codex 的会话）或跑着的 tb 灯上点一下，订阅「这一次」执行：
/// 之后第一次看到它完成、出错或停下来等你，就响一声、让小猫先说它、弹到小猫的家，系统允许通知的话再发一条（静音，不重复响）。
/// 订阅只放在内存里、叫过一次就没了；换了一轮（会话）或同名灯重新跑（tb）算新的一次，旧订阅悄悄作废，不会冒充。
/// 主对话停了但工作流、子代理还在后台跑的，灯还是「在跑」（见 SessionHook.backgroundWork），不会提前叫。
struct WatchTarget: Equatable {
    enum Kind: Equatable { case session, light }
    let kind: Kind
    let name: String               // 会话 key 或灯名
    let identity: String           // 会话的 turnID；灯的开始时间
    var armed: Bool                // 订阅时已经在等你：要先看到它接着跑（或换了一次等待）才算数，不然马上就会叫
    let waitingSince: Date?

    var key: String { Self.key(kind, name) }
    static func key(_ kind: Kind, _ name: String) -> String { (kind == .session ? "session:" : "light:") + name }
}

/// 刚叫过你的那一件：小猫三分钟内先说它
struct PetNews: Equatable {
    let target: String             // WatchTarget.key
    let identity: String
    let state: String              // done / error / waiting
    let at: Date
    let title: String
    let body: String

    static let freshFor: TimeInterval = 180
    func fresh(at now: Date) -> Bool { now.timeIntervalSince(at) < Self.freshFor && now >= at }
}

/// 任务页上那张卡：可以订阅（在跑 / 在等你）、已经订阅了
enum WatchCard: Equatable {
    case offer, offerAfterWait, armed
}

extension AppModel {
    static func lightIdentity(_ light: CustomLight) -> String { "\(light.started.timeIntervalSince1970)" }
    static func watchKey(light name: String) -> String { WatchTarget.key(.light, name) }

    /// 这件事现在在任务页上怎么显示；nil 表示不能订阅（已经结束、没有轮次的旧记录）
    func watchCard(session: AgentSession) -> WatchCard? {
        if watched[WatchTarget.key(.session, session.key)] != nil { return .armed }
        guard session.turnID != nil else { return nil }
        switch session.state {
        case .running: return .offer
        case .waiting: return .offerAfterWait
        default: return nil
        }
    }

    var watchedKeys: Set<String> { Set(watched.keys) }

    /// 任务页用的：每个会话现在能不能订阅、订阅了没有
    var watchCards: [String: WatchCard] {
        var out: [String: WatchCard] = [:]
        for session in sessions { if let card = watchCard(session: session) { out[session.key] = card } }
        return out
    }

    func toggleWatch(_ key: String) {
        if watched.removeValue(forKey: key) != nil { onUpdate?(); return }
        if key.hasPrefix("session:") {
            let name = String(key.dropFirst("session:".count))
            guard let session = sessions.first(where: { $0.key == name }), watchCard(session: session) != nil, let turn = session.turnID else { return }
            let waiting = session.state == .waiting
            watched[key] = WatchTarget(kind: .session, name: name, identity: turn, armed: !waiting, waitingSince: waiting ? session.since : nil)
        } else if key.hasPrefix("light:") {
            let name = String(key.dropFirst("light:".count))
            guard let light = allLights.first(where: { $0.name == name }), light.state == .running else { return }
            watched[key] = WatchTarget(kind: .light, name: name, identity: Self.lightIdentity(light), armed: true, waitingSince: nil)
        }
        onUpdate?()
    }

    /// 会话或 tb 灯的文件一变就看一次（跟着现有的目录监视和 tick，不另外轮询）。按 key 排好，一件一件叫
    func checkWatched() {
        for key in watched.keys.sorted() {
            guard var target = watched[key] else { continue }
            switch target.kind {
            case .session:
                guard let raw = sessions.first(where: { $0.key == target.name }), raw.turnID == target.identity,
                      !(raw.state == .idle && raw.interrupted) else {
                    watched[key] = nil                              // 会话没了、换了一轮、你打断了（Claude 按 Esc、Codex 点停止）：悄悄作废
                    continue
                }
                let session = annotated(raw, now: Date())
                if !target.armed {
                    // 订阅时在等你：看到它接着跑才布防；还是那一次等待就不叫。直接完成、出错，或者已经换了一次等待，照叫
                    if session.state == .running {
                        target.armed = true
                        watched[key] = target
                        continue
                    }
                    if session.state == .waiting && session.since == target.waitingSince { continue }
                }
                guard [.done, .error, .waiting].contains(session.state) else { continue }
                watched[key] = nil
                let what: String
                switch session.state {
                case .error: what = session.errorType == "rate_limit" ? " 被限流了" : " 出错了"
                case .waiting: what = " " + session.waitingLabel
                default: what = " 做完了"
                }
                let body = session.errorType == "rate_limit" && session.state == .error
                    ? session.briefStatus(.error, now: Date()) + " · " + session.displayTitle : session.displayTitle
                fireWatch(PetNews(target: key, identity: target.identity, state: session.state.rawValue, at: Date(),
                                  title: session.agentName + what, body: body), error: session.state == .error, open: session.key)
            case .light:
                guard let light = allLights.first(where: { $0.name == target.name }), Self.lightIdentity(light) == target.identity else {
                    watched[key] = nil                              // 灯没了或者同名的重新跑了：悄悄作废
                    continue
                }
                let what: String
                switch light.state {
                case .done: what = " 跑完了"
                case .error: what = " 失败了"
                case .waiting: what = " 在等你"
                case .running, .info: continue
                }
                watched[key] = nil
                fireWatch(PetNews(target: key, identity: target.identity, state: light.state.rawValue, at: Date(),
                                  title: light.name + what, body: CustomLights.summary(light, now: Date())), error: light.state == .error, open: nil)
            }
        }
    }

    /// 先记下消息、刷新（小猫要说的话先准备好），再响、发通知、让触控栏弹
    private func fireWatch(_ news: PetNews, error: Bool, open: String?) {
        petNews = news
        onUpdate?()
        watchSound(error ? "Funk" : "Purr")
        let reminder = ResetReminder(id: "watch:" + news.target + ":" + news.identity + ":" + news.state, fireAt: Date().addingTimeInterval(2),
                                     title: news.title, body: news.body, sound: false, open: open)
        notificationsAllowed { [weak self] allowed in
            if allowed { self?.watchReminder.add(reminder) }          // 只看系统有没有允许通知，不主动去要权限
        }
        onWatchFired?(news)
    }

    /// 三分钟内的那条（给触控栏）
    func activeNews(at now: Date) -> PetNews? {
        guard let petNews, petNews.fresh(at: now) else { return nil }
        return petNews
    }

    static func systemNotificationsAllowed(_ done: @escaping @MainActor (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
            Task { @MainActor in done(allowed) }
        }
    }
}
