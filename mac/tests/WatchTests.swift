import AppKit

/// 做完叫我：一次性订阅、按看到的状态变化触发、通知权限、小猫先说它、触控栏什么时候弹
enum WatchTests {
    @MainActor
    final class Reminders: ReminderCenter {
        var added: [ResetReminder] = []
        var asked = 0
        func requestAuthorization(_ done: @escaping @MainActor (Bool) -> Void) { asked += 1; done(true) }
        func add(_ reminder: ResetReminder) { added.append(reminder) }
        func remove(ids: [String]) {}
    }

    static func session(_ state: SessionState, turn: String, since: Date, id: String = "w1", reason: String = "") -> AgentSession {
        AgentSession(agent: "claude", id: id, state: state, since: since, updated: since, first: since.addingTimeInterval(-600), title: "修登录", bundle: "",
                     waitReason: reason, turnID: turn, turnAt: since.addingTimeInterval(-720), turnEndedAt: state == .done || state == .error ? since : nil)
    }

    @MainActor
    static func run(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        subscriptions(now: now, check: check)
        bar(now: now, rows: rows, check: check)
    }

    @MainActor
    static func subscriptions(now: Date, check: (Bool, String) -> Void) {
        let model = AppModel()
        var sounds: [String] = []
        model.watchSound = { sounds.append($0) }
        let reminders = Reminders()
        model.watchReminder = reminders
        var allowed = true
        model.notificationsAllowed = { done in done(allowed) }
        var fired: [PetNews] = []
        model.onWatchFired = { fired.append($0) }
        let key = "session:claude-w1"

        model.sessions = [session(.running, turn: "T1", since: now)]
        model.checkWatched()
        model.sessions = [session(.done, turn: "T1", since: now.addingTimeInterval(5))]
        model.checkWatched()
        check(sounds.isEmpty && fired.isEmpty, "没订阅的任务变化不响")

        model.sessions = [session(.running, turn: "T1", since: now)]
        check(model.watchCards["claude-w1"] == .offer, "在跑的任务可以点「做完叫我」")
        model.toggleWatch(key)
        check(model.watchCards["claude-w1"] == .armed, "点了显示「会叫你」")
        model.toggleWatch(key)
        check(model.watchCards["claude-w1"] == .offer && model.watched.isEmpty, "再点一下取消")
        model.toggleWatch(key)
        model.sessions = [session(.done, turn: "T1", since: now.addingTimeInterval(5))]
        model.checkWatched()
        check(sounds == ["Purr"] && fired.count == 1 && fired.first?.title == "Claude 做完了" && fired.first?.body == "修登录" && model.watched.isEmpty,
              "跑完：响一声、叫一次、订阅用掉")
        check(reminders.added.count == 1 && reminders.added.first?.sound == false && reminders.added.first?.id.hasPrefix("watch:session:claude-w1:T1:") == true,
              "系统允许通知：发一条静音的通知（已经响过一声），id 带这一次的身份")
        check(model.petNews?.target == key && model.activeNews(at: model.petNews!.at.addingTimeInterval(179)) != nil
              && model.activeNews(at: model.petNews!.at.addingTimeInterval(180)) == nil, "小猫三分钟内先说它，满三分钟恢复平常")
        model.checkWatched()
        check(sounds.count == 1, "重复加载不再响")

        model.sessions = [session(.running, turn: "T2", since: now.addingTimeInterval(10))]
        model.toggleWatch(key)
        model.sessions = [session(.error, turn: "T2", since: now.addingTimeInterval(20))]
        model.checkWatched()
        check(sounds.last == "Funk" && fired.last?.title == "Claude 出错了", "出错：换一种声音")

        model.sessions = [session(.running, turn: "T3", since: now.addingTimeInterval(30))]
        model.toggleWatch(key)
        model.sessions = [session(.waiting, turn: "T3", since: now.addingTimeInterval(40), reason: "permission")]
        model.checkWatched()
        check(fired.last?.title == "Claude 等你批准" && sounds.last == "Purr", "停下来等你：也叫")

        // 订阅时已经在等你：这次等待不叫；接着跑了之后再等你才叫
        let waitingSince = now.addingTimeInterval(50)
        model.sessions = [session(.waiting, turn: "T4", since: waitingSince, reason: "question")]
        check(model.watchCards["claude-w1"] == .offerAfterWait, "在等你的任务：按钮写「继续后叫我」")
        model.toggleWatch(key)
        let count = fired.count
        model.checkWatched()
        model.checkWatched()
        check(fired.count == count, "订阅时的那次等待不叫")
        model.sessions = [session(.running, turn: "T4", since: now.addingTimeInterval(55))]
        model.checkWatched()
        check(fired.count == count && model.watched[key]?.armed == true, "接着跑了：布防，不叫")
        model.sessions = [session(.waiting, turn: "T4", since: now.addingTimeInterval(60), reason: "question")]
        model.checkWatched()
        check(fired.count == count + 1 && fired.last?.title == "Claude 等你回答", "再等你：叫一次")

        // 订阅时在等你，下一次看到时已经完成（中间的运行没看到）：照叫；已经换了一次等待：也叫
        model.sessions = [session(.waiting, turn: "T4b", since: now.addingTimeInterval(61), reason: "question")]
        model.toggleWatch(key)
        model.sessions = [session(.done, turn: "T4b", since: now.addingTimeInterval(62))]
        model.checkWatched()
        check(fired.count == count + 2 && fired.last?.title == "Claude 做完了", "等你时订阅、直接看到完成：照叫")
        model.sessions = [session(.waiting, turn: "T4c", since: now.addingTimeInterval(63), reason: "question")]
        model.toggleWatch(key)
        model.sessions = [session(.waiting, turn: "T4c", since: now.addingTimeInterval(64), reason: "permission")]
        model.checkWatched()
        check(fired.count == count + 3 && fired.last?.title == "Claude 等你批准", "等你时订阅、已经换了一次等待：照叫")
        let settled = fired.count

        // 换了一轮、会话没了：悄悄作废
        model.sessions = [session(.running, turn: "T5", since: now.addingTimeInterval(70))]
        model.toggleWatch(key)
        model.sessions = [session(.done, turn: "T6", since: now.addingTimeInterval(80))]
        model.checkWatched()
        check(fired.count == settled && model.watched.isEmpty, "换了一轮（你又提交了一句）：旧订阅作废，不冒充")
        model.sessions = [session(.running, turn: "T7", since: now.addingTimeInterval(90))]
        model.toggleWatch(key)
        model.sessions = []
        model.checkWatched()
        check(fired.count == settled && model.watched.isEmpty, "会话没了：订阅作废，不当成完成")
        // Codex：一样能订阅；做完叫「Codex 做完了」；你点停止打断了：悄悄作废
        var codex = AgentSession(agent: "codex", id: "c1", state: .running, since: now, updated: now, first: now, title: "改路由", bundle: "", turnID: "C")
        model.sessions = [codex]
        check(model.watchCard(session: codex) == .offer, "Codex 在跑的任务也能订阅")
        model.toggleWatch("session:codex-c1")
        codex.state = .done
        codex.since = now.addingTimeInterval(95)
        model.sessions = [codex]
        model.checkWatched()
        check(fired.last?.title == "Codex 做完了" && fired.last?.body == "改路由" && fired.count == settled + 1 && model.watched.isEmpty, "Codex 跑完：一样叫一次")
        codex = AgentSession(agent: "codex", id: "c1", state: .running, since: now, updated: now, first: now, title: "改路由", bundle: "", turnID: "C2")
        model.sessions = [codex]
        model.toggleWatch("session:codex-c1")
        codex.state = .idle
        codex.interrupted = true
        model.sessions = [codex]
        model.checkWatched()
        check(fired.count == settled + 1 && model.watched.isEmpty, "Codex 被你打断：订阅作废，不叫")
        let legacy = AgentSession(agent: "codex", id: "c2", state: .running, since: now, updated: now, first: now, title: "x", bundle: "")
        check(model.watchCard(session: legacy) == nil, "没有轮次的旧记录：不能订阅")

        // tb 灯
        let started = now.addingTimeInterval(-100)
        var light = CustomLight(name: "构建", state: .running, started: started, updated: started)
        model.allLights = [light]
        model.customLights = []                               // 被挤出显示的灯也照样盯
        model.toggleWatch("light:构建")
        light.state = .error
        light.detail = "没等到结束，进程已经不在了"
        model.allLights = [light]
        model.checkWatched()
        check(fired.last?.title == "构建 失败了" && sounds.last == "Funk" && model.watched.isEmpty,
              "进程没了推断出错：照样叫（更新时间比订阅早也算）；没显示出来的灯也盯")
        light = CustomLight(name: "部署", state: .running, started: started, updated: started)
        model.allLights = [light]
        model.toggleWatch("light:部署")
        light.state = .info
        model.allLights = [light]
        model.checkWatched()
        check(fired.last?.title != "部署 跑完了" && model.watched["light:部署"] != nil, "变成 info 不算跑完")
        light.state = .waiting
        model.allLights = [light]
        model.checkWatched()
        check(fired.last?.title == "部署 在等你", "tb 灯等你：写在等你")
        light = CustomLight(name: "测试", state: .running, started: started, updated: started)
        model.allLights = [light]
        model.toggleWatch("light:测试")
        let rerun = CustomLight(name: "测试", state: .running, started: now, updated: now)
        model.allLights = [rerun]
        model.checkWatched()
        var done = rerun
        done.state = .done
        model.allLights = [done]
        let before = fired.count
        model.checkWatched()
        check(fired.count == before && model.watched.isEmpty, "同名的重新跑：不继承旧订阅")

        allowed = false
        light = CustomLight(name: "打包", state: .running, started: started, updated: started)
        model.allLights = [light]
        model.toggleWatch("light:打包")
        light.state = .done
        model.allLights = [light]
        let added = reminders.added.count
        model.checkWatched()
        check(reminders.added.count == added && reminders.asked == 0 && fired.last?.title == "打包 跑完了",
              "系统没允许通知：不发，也不去要权限；声音和小猫照常")
    }

    @MainActor
    static func bar(now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        var presented = 0
        var taps: [String] = []
        let bar = TouchBarItem()
        bar.presenter = { _ in presented += 1 }
        bar.presentationAllowed = { true }
        bar.onWatch = { taps.append($0) }
        bar.pretendShownForTesting()
        let running = session(.running, turn: "U1", since: now)
        bar.update(rows: rows, lights: [(running, .running)], tasks: [(running, .running)], now: now, watchCards: ["claude-w1": .offer])
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "task:claude-w1" } ?? 0)
        check(bar.shown.map(\.id) == ["title:claude-w1", "watch:claude-w1", "open:claude-w1", "folder:claude-w1", "terminal:claude-w1", "handoff:claude-w1"],
              "任务页：任务名、做完叫我、打开、文件夹、终端、复制交接")
        let width = bar.shown.reduce(0) { $0 + $1.image.size.width } + TouchBarItem.detailSpacing * CGFloat(bar.shown.count - 1)
        check(width + TouchBarItem.backWidth + TouchBarItem.detailSpacing <= TouchBarItem.detailWidth, "加了一张卡还是一屏放得下（含返回键）")
        bar.tapForTesting(1)
        check(taps == ["session:claude-w1"], "点「做完叫我」订阅的是这个任务")
        bar.update(rows: rows, lights: [(running, .running)], tasks: [(running, .running)], now: now, watchCards: ["claude-w1": .armed])
        check(bar.shown[1].label == "已经订阅做完叫我，再点取消", "订阅了：读屏说再点取消")

        let long = AgentSession(agent: "claude", id: "w1", state: .done, since: now, updated: now, first: now,
                                title: String(repeating: "很长的任务名", count: 8), bundle: "", turnID: "U1",
                                turnAt: now.addingTimeInterval(-720), turnEndedAt: now)
        var receipt = TurnReceipt()
        receipt.files = 3
        receipt.check = "swift test"
        receipt.result = .failed
        for step in 0..<10 {
            bar.update(rows: rows, lights: [(long, .done)], tasks: [(long, .done)], now: now.addingTimeInterval(Double(step) * 60),
                       receipts: ["claude-w1": .ready(receipt)])
        }
        check(bar.shown.map(\.id).contains("receipt:claude-w1"), "跑完了：任务页有「本轮」卡")
        let receiptLabel = bar.shown.first { $0.id == "receipt:claude-w1" }?.label ?? ""
        check(receiptLabel == "本轮 · 用了 12分：测试没过 swift test · 编辑工具改了 3 个文件", "本轮卡读屏是完整的，刷新十次用时不变")
        check(bar.shown[0].label?.hasPrefix(String(repeating: "很长的任务名", count: 8)) == true, "长任务名读屏完整")

        // 叫你时：专注中照弹
        let news = PetNews(target: "session:claude-w1", identity: "U1", state: "done", at: Date(), title: "Claude 做完了", body: "修登录")
        let focusing = CalmState.focus(started: now, ends: now.addingTimeInterval(900))
        bar.update(rows: rows, lights: [(long, .done)], tasks: [(long, .done)], now: now, calm: focusing, pet: .done,
                   receipts: ["claude-w1": .ready(receipt)], news: news)
        bar.backForTesting()
        var count = presented
        bar.showPetNews(news)
        if case .pet = bar.page {} else { check(false, "叫你时弹到小猫的家") }
        check(presented == count + 1, "专注中也弹（是你自己要它叫的）")
        check(bar.shown.first { $0.id == "pet:say" }?.label?.hasPrefix("Claude 做完了，但测试没过") == true, "小猫先说刚叫你的那件，小票没过用橙色说出来")

        // 呼吸时不弹，事后也不补
        let breathing = TouchBarItem()
        breathing.presenter = { _ in presented += 1 }
        breathing.presentationAllowed = { true }
        breathing.pretendShownForTesting()
        breathing.update(rows: rows, lights: [], tasks: [], now: now, calm: .breath(started: now, rounds: 4))
        count = presented
        breathing.showPetNews(news)
        breathing.update(rows: rows, lights: [], tasks: [], now: now, calm: .none)
        check(presented == count, "呼吸时不弹，呼吸完也不补弹")

        // 呼吸时手指按着来的：松手时呼吸已经停了也不补弹
        breathing.update(rows: rows, lights: [], tasks: [], now: now, calm: .breath(started: now, rounds: 4))
        breathing.beginInteractionForTesting()
        count = presented
        breathing.showPetNews(news)
        breathing.update(rows: rows, lights: [], tasks: [], now: now, calm: .none)
        breathing.endInteractionForTesting()
        breathing.settleForTesting(generation: breathing.touchGenerationForTesting)
        check(presented == count, "呼吸时手指按着来的消息：松手后也不补弹")

        // 系统不让弹
        let quiet = TouchBarItem()
        quiet.presenter = { _ in presented += 1 }
        quiet.presentationAllowed = { false }
        quiet.pretendShownForTesting()
        count = presented
        quiet.showPetNews(news)
        check(presented == count, "系统把触控栏设成 F 键等：不弹")

        // 手指按着：先不换页，松手后正好弹一次
        let touched = TouchBarItem()
        touched.presenter = { _ in presented += 1 }
        touched.presentationAllowed = { true }
        touched.pretendShownForTesting()
        touched.update(rows: rows, lights: [], tasks: [], now: now)
        touched.beginInteractionForTesting()
        count = presented
        touched.showPetNews(news)
        if case .overview = touched.page {} else { check(false, "按着时不换页") }
        touched.endInteractionForTesting()
        touched.settleForTesting(generation: touched.touchGenerationForTesting)
        touched.settleForTesting(generation: touched.touchGenerationForTesting)
        if case .pet = touched.page {} else { check(false, "松手后弹到小猫的家") }
        check(presented == count + 1, "松手后正好弹一次")

        // 在小猫的家时歌词停了、切 app：不把它收掉
        let lyric = NowLyric(site: "bilibili", title: "晴天", line: "刮风这天", next: "", kind: "lyrics", playing: false, received: Date())
        touched.visibleForTesting = true
        touched.update(rows: rows, lights: [], tasks: [], now: now, lyric: lyric)
        touched.frontAppChanged("com.google.Chrome", promptApp: nil, autoShow: true)
        touched.frontAppChanged("com.anthropic.claudefordesktop", promptApp: "Claude", autoShow: true)
        if case .pet = touched.page {} else { check(false, "歌词暂停、在 Chrome 和 Claude 之间切换都不抢走小猫的家") }
        touched.visibleForTesting = nil

        // 小猫关着：会话去任务页，tb 灯去对话页（AI 页只放最要紧的两张，那盏灯不一定在上面）
        let plain = TouchBarItem()
        plain.presenter = { _ in presented += 1 }
        plain.presentationAllowed = { true }
        plain.pretendShownForTesting()
        plain.update(rows: rows, lights: [(long, .done)], tasks: [(long, .done)], now: now, petEnabled: false)
        plain.showPetNews(news)
        if case .task(let key) = plain.page { check(key == "claude-w1", "小猫关着：叫你时去那个任务页") } else { check(false, "小猫关着：叫你时去那个任务页") }
        plain.showPetNews(PetNews(target: "light:构建", identity: "1", state: "done", at: Date(), title: "构建 跑完了", body: ""))
        if case .chats = plain.page {} else { check(false, "小猫关着：tb 灯叫你时去对话页") }

        // 跑着的 tb 灯：点了订阅
        let light = CustomLight(name: "构建", state: .running, started: now, updated: now)
        let card = TouchBarItem.lightCard(light, now: now, watched: ["light:构建"], width: TouchBarItem.chatCardWidth)
        if case .watch(let key) = card.action { check(key == "light:构建", "跑着的 tb 灯点了就是做完叫我") } else { check(false, "跑着的 tb 灯点了就是做完叫我") }
        check(card.label?.hasSuffix("跑完会叫你，再点取消") == true, "订阅了的灯读屏说会叫你")
        var finished = light
        finished.state = .done
        if case .watch = TouchBarItem.lightCard(finished, now: now, watched: [], width: TouchBarItem.chatCardWidth).action { check(false, "跑完的灯照旧（点了关掉）") }
        // 经过展开条：对话页上点跑着的灯，订阅的是它
        let watchBar = TouchBarItem()
        var watchedKeys: [String] = []
        watchBar.onWatch = { watchedKeys.append($0) }
        watchBar.update(rows: rows, lights: [], tasks: [], now: now, customLights: [light])
        check(watchBar.shown.contains { $0.id == "light:" + light.id }, "跑着的灯是第一页对话区里的一张（没有别的对话时）")
        watchBar.tapForTesting(watchBar.shown.firstIndex { $0.id == "light:" + light.id } ?? 0)
        check(watchedKeys == ["light:构建"], "第一页上点跑着的灯：订阅它")
        watchBar.open(.chats)
        watchBar.tapForTesting(watchBar.shown.firstIndex { $0.id == "light:" + light.id } ?? 0)
        check(watchedKeys == ["light:构建", "light:构建"], "对话页上点跑着的灯：订阅它")

        // 被挤出显示的 tb 灯叫了你：小猫也要说得出来
        var trimmed = CustomLight(name: "第21盏", state: .done, started: now, updated: now)
        trimmed.detail = "完成"
        let lightNews = PetNews(target: "light:第21盏", identity: AppModel.lightIdentity(trimmed), state: "done", at: Date(), title: "第21盏 跑完了", body: "完成")
        let far = TouchBarItem()
        far.presenter = { _ in presented += 1 }
        far.presentationAllowed = { true }
        far.pretendShownForTesting()
        far.update(rows: rows, lights: [], tasks: [], now: now, customLights: [], news: lightNews, allLights: [trimmed])
        far.showPetNews(lightNews)
        check(far.shown.first { $0.id == "pet:say" }?.label?.hasPrefix("第21盏 跑完了") == true, "被挤出显示的灯叫了你，小猫照样先说它")

        // 小猫说的话：三分钟内先说它；小票晚到只改文字
        var context = PetContext(lights: [(long, .done)], news: news, now: news.at.addingTimeInterval(60))
        check(TouchBarItem.petLine(.done, context).title == "Claude 做完了", "小票还没到：先说做完了")
        context.receipts = ["claude-w1": .ready(receipt)]
        let line = TouchBarItem.petLine(.done, context)
        check(line.title == "Claude 做完了，但测试没过" && line.color == .systemOrange, "小票到了：改成测试没过、橙色")
        var built = receipt
        built.check = "swift build"
        built.kind = .build
        context.receipts = ["claude-w1": .ready(built)]
        check(TouchBarItem.petLine(.done, context).title == "Claude 做完了，但构建没过", "构建没过不说成测试没过")
        context.now = news.at.addingTimeInterval(200)
        context.lights = []
        check(TouchBarItem.petLine(.idle, context).title == "都没事", "过了三分钟不再先说它")
        var otherTurn = long
        otherTurn.turnID = "U2"
        context = PetContext(lights: [(otherTurn, .done)], news: news, now: news.at)
        check(TouchBarItem.petLine(.idle, context).title == "都没事", "换了一轮：不套用旧消息")
    }

    /// 合成数据画的预览：任务页的「做完叫我」三种样子、本轮小票几种结果、叫你时的小猫的家
    @MainActor
    static func writePreviews(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = Date()
        let back = TouchBarArt.card("‹", width: TouchBarItem.backWidth)
        let running = session(.running, turn: "P", since: now.addingTimeInterval(-300))
        let waiting = session(.waiting, turn: "P", since: now.addingTimeInterval(-120), reason: "permission")
        func page(_ item: TouchBarItem.TaskItem, watch: WatchCard? = nil, receipt: ReceiptSlot? = nil, file: String) {
            let parts = TouchBarItem.projectImages(item: item, now: now, watch: watch, receipt: receipt, took: 12 * 60)
            Snapshot.touchBar([back] + parts.map(\.image), to: "\(dir)/\(file).png")
        }
        page((running, .running), watch: .offer, file: "touchbar-watch-offer")
        page((waiting, .waiting), watch: .offerAfterWait, file: "touchbar-watch-after-wait")
        page((running, .running), watch: .armed, file: "touchbar-watch-armed")
        let done = session(.done, turn: "P", since: now)
        var passed = TurnReceipt()
        passed.files = 3
        passed.check = "test.sh"
        passed.result = .passed
        var failed = passed
        failed.check = "swift test"
        failed.result = .failed
        var unknown = passed
        unknown.result = .unknown
        var partial = passed
        partial.partial = true
        page((done, .done), receipt: .ready(passed), file: "touchbar-receipt-passed")
        page((done, .done), receipt: .ready(failed), file: "touchbar-receipt-failed")
        page((done, .done), receipt: .ready(unknown), file: "touchbar-receipt-unknown")
        page((done, .done), receipt: .ready(partial), file: "touchbar-receipt-partial")
        page((done, .done), receipt: .unreadable, file: "touchbar-receipt-unreadable")
        let news = PetNews(target: "session:claude-w1", identity: "P", state: "done", at: now, title: "Claude 做完了", body: "修登录")
        let context = PetContext(lights: [(done, .done)], calm: .focus(started: now.addingTimeInterval(-600), ends: now.addingTimeInterval(900)),
                                 receipts: ["claude-w1": .ready(failed)], news: news, now: now)
        Snapshot.touchBar([back] + TouchBarItem.petHomeImages(pose: .done, elapsed: 10, context).map(\.image), to: "\(dir)/touchbar-watch-news.png")
        let light = CustomLight(name: "构建", state: .running, progress: 40, started: now.addingTimeInterval(-90), updated: now)
        Snapshot.touchBar([TouchBarItem.lightCard(light, now: now, watched: ["light:构建"], width: TouchBarItem.chatCardWidth).image,
                           TouchBarItem.lightCard(light, now: now, watched: [], width: TouchBarItem.chatCardWidth).image],
                          to: "\(dir)/touchbar-watch-light.png")
        // 歌词页：一句、放大、居中；前奏没词时写歌名；暂停变灰；太长缩小再截
        let lyrics = [
            NowLyric(site: "bilibili", title: "晴天 · 周杰伦", line: "刮风这天 我试过握着你手", next: "但偏偏", kind: "lyrics", playing: true, received: now),
            NowLyric(site: "bilibili", title: "晴天 · 周杰伦", line: "", next: "", kind: "lyrics", playing: true, received: now),
            NowLyric(site: "bilibili", title: "晴天 · 周杰伦", line: "但偏偏 雨渐渐 大到我看你不见", next: "", kind: "lyrics", playing: false, received: now),
            NowLyric(site: "youtube", title: "Lex Fridman Podcast",
                     line: "and I think the most important thing about building these systems is that you have to be honest about what you don't know",
                     next: "", kind: "subtitle", playing: true, received: now),
        ]
        for (index, lyric) in lyrics.enumerated() {
            Snapshot.touchBar([back] + TouchBarItem.lyricImages(lyric).map(\.image), to: "\(dir)/touchbar-lyrics-\(index).png")
        }
        print("预览写到了 " + dir)
    }
}
