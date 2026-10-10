import AppKit

enum CalmPetTests {
    @MainActor
    final class FakeReminders: ReminderCenter {
        var added: [String] = []
        var removed: [String] = []
        func requestAuthorization(_ done: @escaping @MainActor (Bool) -> Void) { done(true) }
        func add(_ reminder: ResetReminder) { added.append(reminder.id) }
        func remove(ids: [String]) { removed.append(contentsOf: ids) }
    }

    final class Recorder {
        var calm: [CalmCommand] = []
        var shown = 0
        var presented = 0
        var tapped: [PetMood] = []
    }

    @MainActor
    static func run(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        breath(check: check)
        await model(check: check)
        wallClock(check: check)
        var guardian = QuitGuard()
        let t = Date()
        check(!guardian.tap(at: t) && guardian.armed(at: t.addingTimeInterval(1)), "点一下「退出」只是上膛")
        check(guardian.tap(at: t.addingTimeInterval(2)) && !guardian.armed(at: t.addingTimeInterval(2)), "3 秒内再点才退出")
        check(!guardian.tap(at: t.addingTimeInterval(10)) && !guardian.tap(at: t.addingTimeInterval(14)), "隔久了重新上膛，不会一下就退出")
        bar(now: now, rows: rows, check: check)
        pet(now: now, rows: rows, check: check)
    }

    @MainActor
    static func breath(check: (Bool, String) -> Void) {
        let start = Breath.state(at: 0)
        check(start.name == "吸气" && start.left == 4 && start.level < 0.01 && start.round == 1, "呼吸从吸气 4 秒开始")
        let hold = Breath.state(at: 4.01)
        check(hold.name == "屏住" && hold.left == 7 && hold.level > 0.9, "吸满后屏住 7 秒，光带保持亮")
        let out = Breath.state(at: 11.01)
        check(out.name == "呼气" && out.left == 8 && out.level > 0.95, "然后呼气 8 秒")
        check(Breath.state(at: 18.9).level < 0.05 && Breath.state(at: 19.01).round == 2, "一轮 19 秒，呼完进下一轮")
        check(Breath.state(at: Breath.length - 0.1).round == Breath.rounds && Breath.length == 76, "一共 4 轮约 1 分钟")
        check(Focus.clock(1500) == "25:00" && Focus.clock(0.2) == "00:01" && Focus.clock(-3) == "00:00", "专注倒计时的写法")
        check(Focus.color(remaining: 900) != .systemOrange && Focus.color(remaining: 299) == .systemOrange && Focus.color(remaining: 0) == .systemGreen,
              "最后 5 分钟变橙，结束变绿")
        let started = Date()
        let focus = CalmState.focus(started: started, ends: started.addingTimeInterval(1000))
        check(abs((focus.glanceFocus(at: started.addingTimeInterval(400))?.fraction ?? 0) - 0.6) < 0.001, "小图标上的细线按剩余时间变短")
        check(CalmState.rest(since: started).glanceFocus(at: started)?.color == .systemGreen && CalmState.none.glanceFocus(at: started) == nil
              && CalmState.breath(started: started, rounds: 4).glanceFocus(at: started) == nil, "休息时细线变绿；没在专注时不画")
        check(SystemTouchBar.resolve(bundle: "com.google.Chrome", global: nil, perApp: nil) == "appWithControlStrip"
              && SystemTouchBar.resolve(bundle: "com.google.Chrome", global: "functionKeys", perApp: nil) == "functionKeys"
              && SystemTouchBar.resolve(bundle: "com.google.Chrome", global: "appWithControlStrip", perApp: ["com.google.Chrome": "functionKeys"]) == "functionKeys"
              && SystemTouchBar.resolve(bundle: "com.apple.Safari", global: "appWithControlStrip", perApp: ["com.google.Chrome": "functionKeys"]) == "appWithControlStrip",
              "读系统设置：默认是 App 控制 + Control Strip，全局和按 app 的设置都认")
    }

    @MainActor
    static func model(check: (Bool, String) -> Void) async {
        let model = AppModel()
        let reminders = FakeReminders()
        let recorder = Recorder()
        model.calmReminder = reminders
        var chimes = 0
        model.calmChime = { chimes += 1 }
        model.focusLength = 0.3
        model.restLength = 0.3
        model.onCalm = { recorder.shown += 1 }
        model.reminderStatus = .on
        model.calmCommand(.focus)
        if case .focus = model.calm {} else { check(false, "开始专注") }
        check(recorder.shown == 1 && reminders.added == ["focus:end"], "开始专注时展开触控栏，并预约结束提醒")
        try? await Task.sleep(nanoseconds: 450_000_000)
        if case .rest = model.calm {} else { check(false, "专注时间到了进入休息") }
        check(recorder.shown == 2 && chimes == 1, "专注结束时响一声、再展开一次，提醒休息")
        try? await Task.sleep(nanoseconds: 450_000_000)
        check(model.calm == .none, "休息时间过了就结束")
        model.calmCommand(.focus)
        model.calmCommand(.stop)
        check(model.calm == .none && reminders.removed.contains("focus:end"), "中途停止撤掉结束提醒")
        model.reminderStatus = .denied
        model.calmCommand(.focus)
        check(reminders.added.count == 2, "没开通知权限时不预约提醒")
        model.calmCommand(.breath)
        if case .breath = model.calm {} else { check(false, "开始呼吸") }
        model.calmCommand(.stop)
        check(model.calm == .none, "停止呼吸")
    }

    /// 番茄钟按墙上时间校正：用注入的时间，不靠真的睡眠和调度快慢
    @MainActor
    static func wallClock(check: (Bool, String) -> Void) {
        let model = AppModel()
        model.calmReminder = FakeReminders()
        var chimes = 0
        model.calmChime = { chimes += 1 }
        model.focusLength = 1500
        model.restLength = 300
        model.calmCommand(.focus)
        guard case .focus(_, let ends) = model.calm else { check(false, "开始专注"); return }
        let focusing = { () -> Bool in if case .focus = model.calm { return true }; return false }
        model.advanceCalm(now: ends.addingTimeInterval(-1))
        check(focusing() && chimes == 0, "没到点：不结束、不响")
        let wake = ends.addingTimeInterval(600)
        model.didWake(now: wake)
        check(model.calm == .rest(since: wake) && chimes == 1, "合盖睡过了专注的点，醒来马上结束专注、响一声，休息从这一刻算 5 分钟")
        model.advanceCalm(now: wake.addingTimeInterval(1))
        check(chimes == 1 && model.calm == .rest(since: wake), "重复校正不再响")
        model.advanceCalm(now: wake.addingTimeInterval(301))
        check(model.calm == .none && chimes == 1, "睡过了休息的点：直接结束")
        model.calmCommand(.focus)
        let old = model.calmVersion
        model.calmCommand(.stop)
        model.calmCommand(.focus)
        model.calmTimerFired(version: old, now: Date().addingTimeInterval(100_000))
        check(focusing(), "停掉重开后，旧的那次回调不能结束新的专注")
        model.calmTimerFired(version: model.calmVersion, now: Date())
        check(focusing() && chimes == 1, "回调早到了一点：不结束，再等")
        model.calmCommand(.stop)
    }

    @MainActor
    static func bar(now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        let recorder = Recorder()
        let bar = TouchBarItem()
        bar.presenter = { _ in recorder.presented += 1 }
        bar.onCalm = { recorder.calm.append($0) }
        bar.presentationAllowed = { true }
        bar.pretendShownForTesting()
        let lyric = NowLyric(site: "bilibili", title: "晴天", line: "刮风这天", next: "", kind: "lyrics", playing: true, received: Date())
        bar.update(rows: rows, lights: [], tasks: [], now: now, lyric: lyric)
        let ids = bar.shown.map(\.id)
        check(ids.first == "quota" && !ids.contains("lyrics") && !ids.contains("calm"), "额度仍在最前面；歌词卡、番茄钟都不占 AI 页")
        bar.tapForTesting(ids.firstIndex(of: "pet") ?? 0)
        let home = bar.shown.map(\.id)
        check(home.contains("lyrics") && home.contains("pet:focus") && home.contains("pet:breath"), "小猫的家里歌词卡和专注、呼吸同时在")
        bar.tapForTesting(home.firstIndex(of: "pet:focus") ?? 0)
        check(bar.shown.map(\.id) == ["calm:focus", "calm:breath"], "番茄钟页：专注在前，呼吸在后")
        bar.tapForTesting(1)
        check(recorder.calm == [.focus, .breath], "点了就发出开始的命令")
        let started = Date()
        bar.update(rows: rows, lights: [], tasks: [], now: now, lyric: lyric, calm: .breath(started: started, rounds: 4))
        check(bar.shown.map(\.id) == ["calm:session", "calm:stop"], "呼吸时：一整条光带和停止")
        check(bar.shown.allSatisfy { $0.image.size.width <= TouchBarItem.detailWidth - TouchBarItem.backWidth - TouchBarItem.detailSpacing }, "呼吸页一屏放得下（含返回键）")
        bar.visibleForTesting = true
        bar.closeTimerFiredForTesting()
        if case .calm = bar.page {} else { check(false, "呼吸时不会到时间自动收起") }
        let before = recorder.presented
        bar.setPromptContext(app: nil, autoShow: true)
        bar.setPromptContext(app: "Claude", autoShow: true)
        if case .calm = bar.page {} else { check(false, "呼吸时切到 Claude，指令条不来抢") }
        check(recorder.presented == before, "呼吸时不弹指令条")
        bar.visibleForTesting = false
        bar.setPromptContext(app: nil, autoShow: false)
        bar.tapGlanceForTesting()
        if case .calm = bar.page {} else { check(false, "呼吸时点小图标回到呼吸页") }
        bar.update(rows: rows, lights: [], tasks: [], now: now, lyric: lyric, calm: .none)
        bar.tapGlanceForTesting()
        bar.tapGlanceForTesting()
        if case .lyrics = bar.page {} else { check(false, "没在呼吸时，点小图标照旧先进歌词页") }

        let quiet = TouchBarItem()
        quiet.presenter = { _ in recorder.presented += 1 }
        quiet.pretendShownForTesting()
        quiet.presentationAllowed = { false }
        let count = recorder.presented
        quiet.showCalm()
        quiet.showTranslation()
        check(recorder.presented == count, "系统把触控栏设成 F 键或展开的 Control Strip 时，不自动弹出")
        quiet.presentationAllowed = { true }
        quiet.showCalm()
        check(recorder.presented == count + 1, "设成 App 控制 + Control Strip 时才弹出")
        quiet.update(rows: rows, lights: [], tasks: [], now: now, calm: .none)
        quiet.visibleForTesting = true
        quiet.setPromptContext(app: "Claude", autoShow: false)
        quiet.showCalm()
        quiet.closeTimerFiredForTesting()
        if case .prompts = quiet.page {} else { check(false, "在 Claude 里放松完，到时间回到指令条") }

        let focusState = CalmState.focus(started: now.addingTimeInterval(-600), ends: now.addingTimeInterval(900))
        let plain = TouchBarArt.glance(rows: rows, lights: [.running], now: now, lyric: true)
        let marked = TouchBarArt.glance(rows: rows, lights: [.running], now: now, lyric: true, focus: focusState.glanceFocus(at: now))
        check(plain.size == marked.size && plain.tiffRepresentation != marked.tiffRepresentation, "专注细线不改变小图标大小，和额度、会话灯、♪ 一起画")
    }

    @MainActor
    static func pet(now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        check(PetMood.from([]) == .idle && PetMood.from([.idle]) == .idle && PetMood.from([.running, .done]) == .done
              && PetMood.from([.running, .error, .waiting]) == .waiting && PetMood.from([.running]) == .running && PetMood.from([.error, .done]) == .error,
              "小猫的心情按最要紧的任务：等你 > 出错 > 完成 > 在跑 > 睡觉；没有任务也在睡觉")
        let focusing = CalmState.focus(started: now, ends: now.addingTimeInterval(900))
        check(PetPose.of(mood: .waiting, calm: focusing, music: true, patted: false) == .waiting
              && PetPose.of(mood: .error, calm: focusing, music: false, patted: false) == .error
              && PetPose.of(mood: .running, calm: focusing, music: true, patted: false) == .focus
              && PetPose.of(mood: .idle, calm: .rest(since: now), music: true, patted: false) == .rest
              && PetPose.of(mood: .running, calm: .none, music: true, patted: false) == .running
              && PetPose.of(mood: .idle, calm: .none, music: true, patted: false) == .music
              && PetPose.of(mood: .idle, calm: .breath(started: now, rounds: 4), music: false, patted: false) == .idle
              && PetPose.of(mood: .waiting, calm: .none, music: false, patted: true) == .happy,
              "小猫的样子：刚摸过最开心；等你、出错、完成先说；专注看书、休息伸懒腰；再是在跑、听歌、睡觉")

        let recorder = Recorder()
        let bar = TouchBarItem()
        bar.presenter = { _ in recorder.presented += 1 }
        bar.presentationAllowed = { true }
        bar.onCalm = { recorder.calm.append($0) }
        bar.pretendShownForTesting()
        bar.update(rows: rows, lights: [], tasks: [], now: now)
        if let petIndex = bar.shown.firstIndex(where: { $0.id == "pet" }) {
            check(bar.shown.map(\.id) == ["quota", "empty", "chats", "pet", "tools"] && bar.shown[petIndex].image.size.width == TouchBarItem.chipWidth,
                  "没有 AI 任务时小猫也在（睡觉）：在「对话」和「工具」之间，44pt 的入口格")
            check(bar.shown[petIndex].label?.hasPrefix(PetPose.idle.label) == true, "小猫有读屏文字")
        } else {
            check(false, "没有 AI 任务时小猫也在（睡觉）：在「对话」和「工具」之间")
        }
        check(PetArt.image(.waiting, time: 0, animated: false, chip: true).tiffRepresentation != PetArt.image(.waiting, time: 0, animated: false).tiffRepresentation,
              "AI 页上的小猫是另一张图（44pt、没有「?」气泡）")
        bar.update(rows: rows, lights: [], tasks: [], now: now, pet: .running)
        check(bar.tickerIntervalForTesting == 1.0 / 8, "样子刚变时动 4 秒（每秒 8 帧），只重画会动的几块")
        bar.update(rows: rows, lights: [], tasks: [], now: now, pet: .waiting)
        check(bar.tickerIntervalForTesting == nil, "等你的小猫在 AI 页上是不闪「?」的 44pt 小格，坐着不动，不开定时器")
        bar.setPromptContext(app: "Claude", autoShow: true)
        check(!bar.shown.contains { $0.id == "pet" }, "指令条里不放小猫")
        bar.update(rows: rows, lights: [], tasks: [], now: now, pet: .waiting, petEnabled: false)
        bar.backForTesting()
        check(!bar.shown.contains { $0.id == "pet" } && bar.tickerIntervalForTesting == nil, "菜单栏里关掉就不显示，动画也停")

        // 小猫的家
        let waiting = session("codex", "w", title: "修登录", state: .waiting, since: Date().addingTimeInterval(-200), reason: "permission")
        let running = session("claude", "r", title: "写文档", state: .running, since: Date().addingTimeInterval(-60))
        let lights: [TouchBarItem.TaskItem] = [(running, .running), (waiting, .waiting)]
        bar.update(rows: rows, lights: lights, tasks: lights, now: now, pet: .waiting)
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "pet" } ?? 0)
        if case .pet = bar.page {} else { check(false, "点小猫进小猫的家") }
        check(bar.shown.map(\.id) == ["pet:cat", "pet:say", "pet:focus", "pet:breath", "piano", "pet:pat"],
              "家里只留放松的：小猫、它说的话、专注、呼吸、钢琴、摸摸（歌词在放时多一张歌词卡）")
        let room = TouchBarItem.detailWidth - TouchBarItem.backWidth - TouchBarItem.detailSpacing
        let head = bar.shown.prefix(4)
        check(head.reduce(0) { $0 + $1.image.size.width } + TouchBarItem.detailSpacing * CGFloat(head.count - 1) <= room, "小猫、它说的话、专注、呼吸在第一屏（含返回键）")
        func at(_ id: String) -> Int { bar.shown.firstIndex { $0.id == id } ?? -1 }
        check(bar.shown[0].image.size.width == PetArt.homeWidth, "家里的小猫大一号")
        check(bar.shown[1].label == "Codex 等你批准，已等 3分钟 · 修登录。点了打开这条对话", "它先说在等你的那件、等了多久，读屏说清点了去哪")
        check(bar.tickerIntervalForTesting == 1.0 / 8, "进家时小猫在动")
        bar.tapForTesting(at("pet:focus"))
        check(recorder.calm == [.focus], "点专注就开始番茄钟")
        if case .calm = bar.page {} else { check(false, "点了专注进番茄钟页看着（手指刚松开也换）") }
        bar.backForTesting()
        if case .pet = bar.page {} else { check(false, "从家里进的番茄钟页，返回回到家里") }
        bar.tapForTesting(at("pet:breath"))
        check(recorder.calm == [.focus, .breath], "点呼吸就开始呼吸")
        if case .calm = bar.page {} else { check(false, "点了呼吸进呼吸页") }
        bar.backForTesting()
        bar.tapForTesting(at("pet:pat"))
        if case .pet = bar.page {} else { check(false, "摸摸不离开家") }
        check(bar.shown[0].label?.hasPrefix(PetPose.happy.label) == true && bar.shown[1].label == "喵～，再摸摸？点了摸摸它", "摸一下：开心、说喵")
        bar.tapForTesting(0)
        check(bar.shown[1].label == "呼噜呼噜…，再摸摸？点了摸摸它" && bar.tickerIntervalForTesting == 1.0 / 8, "点小猫本身也是摸，每次说的不一样，爱心在飘")
        // 手指按着时动画到头了：先不换，松手收尾时补一次，不会停在半截
        bar.beginInteractionForTesting()
        bar.forgetPatForTesting()
        bar.tickForTesting()
        check(bar.shown[0].label?.hasPrefix(PetPose.happy.label) == true, "按着时不换图")
        bar.endInteractionForTesting()
        bar.settleForTesting(generation: bar.touchGenerationForTesting)
        check(bar.shown[0].label?.hasPrefix(PetPose.waiting.label) == true, "松手后补上最后一帧：爱心飘完回到原来的样子")
        bar.tapForTesting(1)                                 // 它说的话：点了打开那条对话（不换页）
        bar.backForTesting()
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "tools" } ?? 0)
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "attention" } ?? 0)
        if case .attention = bar.page {} else { check(false, "工具页里的待处理去待处理页") }
        check(bar.tickerIntervalForTesting == nil, "离开 AI 页和家后小猫不再占计时器")
        bar.detailHiddenForTesting()
        bar.visibleForTesting = false
        bar.tapGlanceForTesting()
        bar.tapForTesting(bar.shown.firstIndex { $0.id.hasPrefix("task:") } ?? 0)
        bar.backForTesting()
        if case .overview = bar.page {} else { check(false, "收起再展开后，从 AI 页进的任务页返回 AI 页（不记上一次从家里来的）") }
        bar.visibleForTesting = nil
        bar.openPage(named: "nonsense")
        if case .overview = bar.page {} else { check(false, "广播里不认识的页不理") }
        let opened = recorder.presented
        bar.openPage(named: "pet")
        if case .pet = bar.page {} else { check(false, "广播 local.aiquota.touchbar.open pet 直接打开小猫的家") }
        check(recorder.presented == opened + 1, "没展开时广播会展开触控栏")

        // 专注中：陪你看书，按钮只显示剩多少、点了去番茄钟页，不会重新开始
        bar.update(rows: rows, lights: [(running, .running)], tasks: [(running, .running)], now: now, calm: focusing, pet: .running)
        check(bar.shown[0].label?.hasPrefix(PetPose.focus.label) == true && bar.shown[1].label?.hasPrefix("陪你专注，还剩") == true, "专注时小猫看书陪你")
        check(!bar.shown.contains { $0.id == "pet:breath" }, "专注中不放呼吸")
        let before = recorder.calm
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "pet:focus" } ?? 0)
        check(recorder.calm == before, "专注中点番茄钟不会重新开始")
        if case .calm = bar.page {} else { check(false, "专注中点番茄钟去番茄钟页（那里能停）") }
        bar.backForTesting()
        if case .pet = bar.page {} else { check(false, "番茄钟页返回回到家里") }
        check(bar.shown.first { $0.id == "pet:focus" }?.label?.hasPrefix("专注中，还剩") == true, "家里的专注按钮上是倒计时")
        bar.update(rows: rows, lights: [(running, .running)], tasks: [(running, .running)], now: now, calm: focusing, pet: .running, petEnabled: false)
        check(bar.shown.first?.id == "pet:focus" && !bar.shown.contains { $0.id == "pet:cat" || $0.id == "pet:pat" }, "关了小猫：家里只剩番茄钟和工具")
        check(bar.tickerIntervalForTesting == 1, "专注时家里每秒走一下倒计时（关了小猫也走）")
        bar.backForTesting()
        check(bar.shown.contains { $0.id == "tools" } && !bar.shown.contains { $0.id == "pet" }, "关了小猫：AI 页上换成「工具」按钮")
        check(bar.tickerIntervalForTesting == nil, "AI 页上没有会动的东西时不开计时器")
        bar.update(rows: rows, lights: [(running, .running)], tasks: [(running, .running)], now: now, calm: focusing, pet: .running)

        // 说的话：在跑的一件点了去那个任务；都没事时额度过 80% 提一句，不然就睡觉
        check(TouchBarItem.petLine(.running, PetContext(lights: [(running, .running)], now: now)).title == "Claude 在干活",
              "只有一件在跑：说是谁在干活")
        let busy = TouchBarItem.petLine(.running, PetContext(lights: [(running, .running), (session("codex", "x", title: "查资料", state: .running, since: now), .running)], now: now))
        check(busy.title == "2 个任务在跑" && busy.subtitle == "写文档 · 查资料", "几件在跑：说几件、列名字")
        check(TouchBarItem.petLine(.music, PetContext(song: "晴天", now: now)).subtitle == "晴天", "放歌时说在听哪首")
        var hot = rows
        for i in hot.indices { hot[i].windows = hot[i].windows.map { var w = $0; w.used = 10; return w } }
        if !hot.isEmpty, !hot[0].windows.isEmpty {
            hot[0].updatedAt = now
            hot[0].windows[0].used = 86
            hot[0].windows[0].resetsAt = now.addingTimeInterval(7200)
            let quota = TouchBarItem.petLine(.idle, PetContext(rows: hot, now: now))
            check(quota.title == hot[0].name + " " + hot[0].windows[0].label + "已用 86%" && quota.subtitle == "2小时后重置", "都没事时额度过 80% 提一句")
        } else {
            check(false, "测试数据里要有额度")
        }
        var calmRows = rows
        for i in calmRows.indices { calmRows[i].windows = calmRows[i].windows.map { var w = $0; w.used = 10; return w } }
        check(TouchBarItem.petLine(.idle, PetContext(rows: calmRows, now: now)).title == "都没事", "额度也够：说都没事")


        // 工具页、小猫的家：点进去的页返回回到原来那页；叫你时回到家的开头；前台 app 变了工具页马上跟着变
        let host = TouchBarItem()
        host.presenter = { _ in }
        host.presentationAllowed = { true }
        host.pretendShownForTesting()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        if let view = host.detailViewForTesting {
            window.contentView = view
            var link = LinkState()
            link.available = true
            let song = NowLyric(site: "bilibili", title: "晴天", line: "刮风这天", next: "", kind: "lyrics", playing: true, received: Date())
            host.update(rows: rows, lights: [], tasks: [], now: now, lyric: song, link: link)
            host.openPage(named: "tools")
            if case .tools = host.page {} else { check(false, "广播 tools 打开工具页") }
            host.tapForTesting(host.shown.firstIndex { $0.id == "shelf" } ?? 0)
            if case .shelf = host.page {} else { check(false, "工具页里点材料架") }
            host.backForTesting()
            if case .tools = host.page {} else { check(false, "从工具页点进去的页，返回回到工具页") }
            host.backForTesting()
            if case .overview = host.page {} else { check(false, "工具页再返回是 AI 页") }

            host.openPage(named: "pet")
            if case .pet = host.page {} else { check(false, "广播 pet 打开小猫的家") }
            host.tapForTesting(host.shown.firstIndex { $0.id == "lyrics" } ?? 0)
            if case .lyrics = host.page {} else { check(false, "家里点歌词进歌词页") }
            host.backForTesting()
            if case .pet = host.page {} else { check(false, "从家里点进去的歌词页，返回回到家里") }

            // 「做完叫我」弹过来：回到家的开头（小猫说的话看得见）
            host.settleForTesting(generation: host.touchGenerationForTesting)
            let news = PetNews(target: "light:x", identity: "1", state: "done", at: Date(), title: "x 跑完了", body: "")
            host.showPetNews(news)
            check(host.leadingIDForTesting() == "pet:cat", "叫你时回到家的开头")

            // 从家里进的歌词页，歌没了：回家，不是 AI 页
            host.tapForTesting(host.shown.firstIndex { $0.id == "lyrics" } ?? 0)
            host.update(rows: rows, lights: [], tasks: [], now: now, lyric: nil, link: link)
            if case .pet = host.page {} else { check(false, "家里进的歌词页，歌没了回到家里") }

            // 工具页开着时前台切到 Claude / 切走：「常用指令」卡马上出现、消失
            host.openPage(named: "tools")
            host.setPromptContext(app: "Claude", autoShow: false)
            check(host.shown.contains { $0.id == "prompts" }, "切到 Claude：工具页马上多一张常用指令")
            host.setPromptContext(app: nil, autoShow: false)
            check(!host.shown.contains { $0.id == "prompts" }, "切走：常用指令卡马上去掉")

            // 家里呼吸时每秒刷新吸气/屏住/呼气
            host.update(rows: rows, lights: [], tasks: [], now: now, link: link, calm: .breath(started: Date(), rounds: 4), petEnabled: false)
            host.openPage(named: "pet")
            check(host.tickerIntervalForTesting == 1, "家里呼吸时每秒刷新阶段")
            host.openPage(named: "overview")
            check(host.shown.contains { $0.id == "relax" } && !host.shown.contains { $0.id == "pet" }, "关了小猫：AI 页上是「放松」小格（进番茄钟、呼吸）")
        } else {
            check(false, "拿不到展开条的视图")
        }
        let poses: [PetPose] = [.running, .waiting, .done, .error, .idle, .focus, .rest, .music, .happy]
        for pose in poses {
            let still = PetArt.image(pose, time: 0, animated: false)
            let moving = PetArt.image(pose, time: 0.35, animated: true)
            let big = PetArt.image(pose, time: 0.35, animated: true, home: true)
            check(still.size == NSSize(width: PetArt.width, height: TouchBarArt.height) && moving.size == still.size
                  && big.size == NSSize(width: PetArt.homeWidth, height: TouchBarArt.height), "每种样子的图都是 40×30（家里 56×30）")
        }
    }

    static func session(_ agent: String, _ id: String, title: String, state: SessionState, since: Date, reason: String = "") -> AgentSession {
        AgentSession(agent: agent, id: id, state: state, since: since, updated: since, first: since, title: title, bundle: "", waitReason: reason)
    }
}
