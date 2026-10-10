import AppKit

enum ToolTests {
    final class Recorder {
        var dismissed: [String] = []
        var commands: [TranslationCommand] = []
        var presented = 0
        var translated = 0
    }

    @MainActor
    final class FakeTranslator: Translator {
        var delays: [TimeInterval] = []
        var failure: TranslateError?
        var calls: [(text: String, from: String, to: String)] = []

        func translate(_ text: String, from: String, to: String) async throws -> String {
            calls.append((text, from, to))
            let delay = delays.isEmpty ? 0 : delays.removeFirst()
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if let failure { throw failure }
            return "译文：" + text
        }
    }

    @MainActor
    static func run(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        let generalCount = NSPasteboard.general.changeCount
        await lights(now: now, rows: rows, check: check)
        await translation(now: now, rows: rows, check: check)
        check(NSPasteboard.general.changeCount == generalCount, "灯和翻译的测试没有碰用户真实的剪贴板")
    }

    @MainActor
    static func lights(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        check(TBCommand.parse(["run", "--name", "构建", "--keep", "make", "-j8"]) == .run(name: "构建", keep: true, command: ["make", "-j8"])
              && TBCommand.parse(["run", "--", "ls", "--all"]) == .run(name: nil, keep: false, command: ["ls", "--all"])
              && TBCommand.parse(["run"]) == nil && TBCommand.parse(["run", "--bogus", "ls"]) == nil,
              "tb run 的参数：--name、--keep、-- 之后原样交给命令")
        check(TBCommand.parse(["light", "部署", "绿", "v1.2", "上线了", "--keep"]) == .light(name: "部署", state: .done, detail: "v1.2 上线了", keep: true)
              && TBCommand.parse(["light", "部署", "紫"]) == nil && TBCommand.parse(["light", "部署"]) == nil,
              "tb light：颜色认中文和英文，说明可以有空格")
        check(TBCommand.parse(["progress", "构建", "42%"]) == .progress(name: "构建", percent: 42, detail: "")
              && TBCommand.parse(["off", "构建"]) == .off("构建") && TBCommand.parse(["clear"]) == .clear
              && TBCommand.parse([]) == .help && TBCommand.parse(["nope"]) == nil, "其余几个命令")
        check(CustomLights.fileID("构建") == CustomLights.fileID(" 构建 ") && CustomLights.fileID("a") != CustomLights.fileID("b")
              && CustomLights.clean("第一行\n第二行\u{1b}[31m", limit: 40) == "第一行 第二行 [31m", "同名同一盏灯；换行和控制字符去掉")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-lights-" + UUID().uuidString)
        check(TB.main(["run", "--name", "会失败", "/bin/sh", "-c", "exit 3"], folder: folder, reraise: false) == 3, "tb run 原样返回命令的退出码")
        let failed = CustomLights.read("会失败", in: folder)
        check(failed?.state == .error && failed?.code == 3 && failed?.pid == nil && CustomLights.summary(failed!, now: Date()).hasPrefix("失败 · 退出码 3"),
              "失败的命令点红灯，写明退出码")
        check(TB.main(["run", "--name", "会成功", "true"], folder: folder, reraise: false) == 0 && CustomLights.read("会成功", in: folder)?.state == .done, "成功的命令点绿灯")
        check(TB.main(["run", "--name", "找不到", "aiquota-no-such-command-xyz"], folder: folder, reraise: false) == 127
              && CustomLights.read("找不到", in: folder)?.state == .error, "命令不存在时也是红灯，退出码 127")
        check(TB.main(["light", "部署", "橙", "等人确认"], folder: folder, reraise: false) == 0 && CustomLights.read("部署", in: folder)?.state == .waiting, "tb light 点橙灯")
        check(TB.main(["progress", "部署", "60"], folder: folder, reraise: false) == 0 && CustomLights.read("部署", in: folder)?.progress == 60
              && CustomLights.read("部署", in: folder)?.detail == "等人确认", "tb progress 更新进度，说明不丢")
        check(TB.main(["bogus"], folder: folder, reraise: false) == 2, "用法不对返回 2")
        check(TB.main(["off", "部署"], folder: folder, reraise: false) == 0 && CustomLights.read("部署", in: folder) == nil, "tb off 关掉一盏")

        let stale = CustomLight(name: "早就完成", state: .done, started: now.addingTimeInterval(-3600), updated: now.addingTimeInterval(-1300))
        let kept = CustomLight(name: "留着", state: .done, started: now.addingTimeInterval(-3600), updated: now.addingTimeInterval(-1300), keep: true)
        let orphan = CustomLight(name: "没人管了", state: .running, started: now.addingTimeInterval(-60), updated: now.addingTimeInterval(-60), pid: 999_999)
        for light in [stale, kept, orphan] { try? CustomLights.write(light, in: folder) }
        let loaded = CustomLights.load(from: folder, now: now, alive: { _, _ in false })
        check(!loaded.contains { $0.name == "早就完成" } && CustomLights.read("早就完成", in: folder) == nil, "完成 20 分钟后自动消失，文件也删掉")
        check(loaded.contains { $0.name == "留着" }, "加了 --keep 的留着")
        check(loaded.first { $0.name == "没人管了" }?.state == .error, "跑着的进程已经不在了，就标成红灯")
        try? Data(repeating: 65, count: CustomLights.maxFileBytes + 10).write(to: folder.appendingPathComponent("huge.json"))
        try? Data("{}".utf8).write(to: folder.appendingPathComponent("junk.json"))
        check(CustomLights.load(from: folder, now: now, alive: { _, _ in true }).count == loaded.count, "太大或格式不对的文件不认")

        let recorder = Recorder()
        let bar = TouchBarItem()
        bar.onLightDismiss = { name, _ in recorder.dismissed.append(name) }
        let shown = CustomLights.load(from: folder, now: now, alive: { _, _ in true })
        bar.update(rows: rows, lights: [], tasks: [], now: now, customLights: shown)
        check(bar.shown.contains { $0.id.hasPrefix("light:") } || shown.allSatisfy { $0.light == .idle }, "AI 页上最要紧的灯在对话区")
        bar.open(.chats)
        let ids = bar.shown.map(\.id)
        check(shown.allSatisfy { light in ids.contains("light:" + light.id) }, "对话页里每盏灯一张卡")
        if let index = ids.firstIndex(of: "light:" + CustomLights.fileID("会失败")) {
            bar.tapForTesting(index)
            check(recorder.dismissed == ["会失败"], "点完成或失败的灯就清掉")
        }
        let running = CustomLight(name: "还在跑", state: .running, progress: 30, started: now, updated: now, pid: getpid(), pidStart: CustomLights.startTime(of: getpid()))
        check({ if case .watch("light:还在跑") = TouchBarItem.lightCard(running, now: now, watched: [], width: TouchBarItem.chatCardWidth).action { return true }; return false }(),
              "tb run 跑着的灯点了是「做完叫我」，不会把它关掉")
        check(CustomLights.summary(running, now: now).hasPrefix("30% · 运行中"), "跑着时写进度")
        let plain = TouchBarArt.glance(rows: rows, lights: [.running], now: now)
        let lit = TouchBarArt.glance(rows: rows, lights: [.running, .error], now: now)
        check(plain.size == lit.size && plain.tiffRepresentation != lit.tiffRepresentation, "灯也画在小图标的那排点里")

        let model = AppModel()
        model.lightsFolder = folder
        model.reloadLights()
        let before = model.customLights.count
        let seen = CustomLights.read("会成功", in: folder)?.updated ?? now
        model.dismissLight("会成功", updated: seen.addingTimeInterval(-5))
        check(CustomLights.read("会成功", in: folder) != nil, "看到的是旧版本时不删（灯在这期间更新过）")
        model.dismissLight("会成功", updated: seen)
        check(model.customLights.count == before - 1 && CustomLights.read("会成功", in: folder) == nil, "菜单栏里清除一盏灯")
        try? FileManager.default.removeItem(at: folder)
        await fixes(now: now, rows: rows, check: check)
    }

    @MainActor
    static func fixes(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-lights-fixes-" + UUID().uuidString)
        let sameGroup = #"test "$(ps -o pgid= -p $$ | tr -d ' ')" = "$(ps -o pgid= -p $PPID | tr -d ' ')""#
        check(TB.main(["run", "--name", "同组", "/bin/sh", "-c", sameGroup], folder: folder, reraise: false) == 0,
              "tb run 的命令和 tb 在同一个进程组：终端输入、Ctrl-C、Ctrl-Z 都照常")
        check(TB.main(["run", "--name", "崩溃", "/bin/sh", "-c", "kill -SEGV $$"], folder: folder, reraise: false) == 139
              && CustomLights.read("崩溃", in: folder)?.detail.hasPrefix("崩溃") == true, "程序崩溃写崩溃，不写被中断")
        check(TB.main(["run", "--name", "中断", "/bin/sh", "-c", "kill -TERM $$"], folder: folder, reraise: false) == 143
              && CustomLights.read("中断", in: folder)?.detail.hasPrefix("被中断了") == true, "被信号结束时写被中断了")
        check(TBCommand.parse(["light", "  ", "绿"]) == nil && TBCommand.parse(["run", "--name", "", "ls"]) == nil && TBCommand.parse(["off", " "]) == nil,
              "空名字不收")
        check(TB.defaultName(["make", "-j8"], directory: "/Users/demo/projects/app") == "make -j8 · app", "默认名字带上当前文件夹，两个项目的 make 分开")
        let own = getpid()
        let ownStart = CustomLights.startTime(of: own)
        check(ownStart != nil && CustomLights.alive(own, ownStart) && !CustomLights.alive(own, (ownStart ?? 0) &+ 1), "按启动时间认进程，进程号被复用也认得出")
        try? CustomLights.write(CustomLight(name: "占着", state: .running, started: now, updated: now, pid: own, pidStart: ownStart), in: folder)
        check(TB.freeName("占着", folder: folder) == "占着 #2", "同名的还在跑，就换一个名字，不互相覆盖")
        let longAgo = now.addingTimeInterval(-13 * 3600)
        try? CustomLights.write(CustomLight(name: "跑了很久", state: .running, started: longAgo, updated: longAgo, pid: own, pidStart: ownStart), in: folder)
        try? CustomLights.write(CustomLight(name: "认错进程", state: .running, started: now, updated: now, pid: own, pidStart: (ownStart ?? 0) &+ 1), in: folder)
        try? CustomLights.write(CustomLight(name: "没进程", state: .running, progress: 40, started: longAgo, updated: now.addingTimeInterval(-2 * 3600)), in: folder)
        let loaded = CustomLights.load(from: folder, now: now)
        check(loaded.first { $0.name == "跑了很久" }?.state == .running, "命令还在跑就一直显示，不因为过了 12 小时删掉")
        check(loaded.first { $0.name == "认错进程" }?.state == .error, "进程号对上但启动时间不对，算已经不在了")
        check(!loaded.contains { $0.name == "没进程" }, "没有进程的「跑着」一小时没更新就消失")
        let junk = folder.appendingPathComponent("junk.json")
        try? Data("{}".utf8).write(to: junk)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 86400)], ofItemAtPath: junk.path)
        _ = CustomLights.load(from: folder, now: now)
        check(!FileManager.default.fileExists(atPath: junk.path), "认不出来的旧文件过一天清掉")
        check(CustomLight(name: "手动", state: .running, started: now, updated: now).dismissable
              && !CustomLight(name: "有进程", state: .running, started: now, updated: now, pid: own).dismissable, "没有进程的「跑着」也能清除")
        for number in 1...25 {
            try? CustomLights.write(CustomLight(name: "批量 \(number)", state: .done, started: now.addingTimeInterval(Double(number)), updated: now), in: folder)
        }
        let everything = CustomLights.load(from: folder, now: now)
        let visible = CustomLights.visible(everything)
        check(visible.count == CustomLights.maxLights && visible.contains { $0.name == "跑了很久" } && visible.contains { $0.name == "认错进程" },
              "放不下时先留跑着的和失败的")
        check(TB.main(["clear"], folder: folder, reraise: false) == 0 && CustomLights.load(from: folder, now: now).isEmpty, "tb clear 清掉全部，不受 20 盏的上限影响")
        try? FileManager.default.removeItem(at: folder)

        check(TranslateText.direction(for: "请帮我 review 一下这个 PR") == ("zh-Hans", "en") && TranslateText.direction(for: "这个 bug 在 production 上出现了") == ("zh-Hans", "en"),
              "中英混写按中文算")
        check(TranslateText.direction(for: "OK") == ("en", "zh-Hans") && TranslateText.direction(for: "npm install") == ("en", "zh-Hans"), "短的英文词按英文算")
        check(TranslateText.direction(for: "你好世界") == ("zh-Hans", "en") && TranslateText.direction(for: "請幫我看看這個問題") == ("zh-Hant", "en")
              && TranslateText.direction(for: "これはテストです") == ("ja", "zh-Hans"), "简体、繁体、日文分得清")
        check(TranslateText.message(for: TranslateError.notInstalled(from: "ja", to: "zh-Hans")).text.contains("日语"), "缺哪种语言就写哪种")
        check(TranslateText.chunks("1.5 版本号 3.14，见 example.com", limit: 30) == ["1.5 版本号 3.14，见 example.com"], "小数点和网址不切开")
        check(TranslateText.chunks("Dr. Smith went to Washington D.C. today.", limit: 56) == ["Dr. Smith went to Washington D.C. today."], "英文缩写不多加空格")
        let words = String(repeating: "internationalization ", count: 6)
        let wordPieces = TranslateText.chunks(words, limit: 56)
        check(wordPieces.allSatisfy { $0.split(separator: " ").allSatisfy { $0 == "internationalization" } }, "到上限时在空格处切，不从单词中间断")
        check(TranslateText.chunks("第一行内容\r\n第二行内容\r第三行", limit: 30).allSatisfy { !$0.contains(where: \.isNewline) }, "各种换行都不会画到卡片外面")
        check(TouchBarArt.readingPieces(String(repeating: "WWWWWWWWWW ", count: 8), limit: 56).allSatisfy { TouchBarArt.readingFits($0) }, "每块译文都完整画得下，不被省略号截掉")

        let board = NSPasteboard(name: NSPasteboard.Name("local.aiquota.tests." + UUID().uuidString))
        let model = AppModel()
        let fake = FakeTranslator()
        let recorder = Recorder()
        model.translator = fake
        model.pasteboard = board
        model.onTranslate = { recorder.translated += 1 }
        board.clearContents()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("demo-secret", forType: .string)
        model.translateClipboard()
        check(fake.calls.isEmpty && model.translation == .failed("剪贴板里是密码管理器标记的保密内容，没有翻译", needsDownload: false), "保密内容不翻译、不显示")
        model.translate("   ")
        check(recorder.translated == 2, "选中的只有空白时也展开告诉你")
        fake.delays = [0.3]
        model.translate("Slow one.")
        board.clearContents()
        model.translateClipboard()
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(model.translation == .failed("剪贴板里没有文字", needsDownload: false), "慢的旧结果不覆盖你刚做的操作")
        board.releaseGlobally()

        let bar = TouchBarItem()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        bar.presenter = { _ in recorder.presented += 1 }
        bar.pretendShownForTesting()
        if let view = bar.detailViewForTesting { window.contentView = view }
        bar.update(rows: rows, lights: [], tasks: [], now: now, translation: .working("The quick brown fox jumps over the lazy dog."))
        bar.showTranslation()
        let result = TranslationResult(source: "The quick brown fox jumps over the lazy dog.", text: String(repeating: "敏捷的棕色狐狸跳过了那只懒狗。", count: 4),
                                       from: "en", to: "zh-Hans", truncated: false)
        bar.update(rows: rows, lights: [], tasks: [], now: now, translation: .done(result))
        check(bar.leadingIDForTesting() == "translate:head", "翻译完成后从头开始看，不跳到最后")
        check(bar.shown.dropFirst().first?.label?.isEmpty == false, "译文每块都有读屏文字")
        bar.beginInteractionForTesting()
        bar.visibleForTesting = true
        bar.backForTesting()
        bar.showTranslation()
        if case .overview = bar.page {} else { check(false, "手指按着时不切到翻译页") }
        bar.endInteractionForTesting()
        bar.settleForTesting(generation: bar.touchGenerationForTesting)
        if case .translation = bar.page {} else { check(false, "松手后再切到翻译页") }
        bar.setPromptContext(app: nil, autoShow: false)
        bar.visibleForTesting = nil
        bar.setPromptContext(app: "Codex", autoShow: true)
        bar.visibleForTesting = true
        bar.showTranslation()
        bar.closeTimerFiredForTesting()
        if case .prompts = bar.page {} else { check(false, "在 AI app 里翻译完，到时间回到指令条而不是收起") }
    }

    @MainActor
    static func translation(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        check(TranslateText.direction(for: "今天天气不错，我们去公园散步吧。") == ("zh-Hans", "en"), "中文译成英文")
        check(TranslateText.direction(for: "The quick brown fox jumps over the lazy dog.") == ("en", "zh-Hans"), "英文译成中文")
        let long = String(repeating: "长", count: TranslateText.maxLength + 50)
        check(TranslateText.clean("  \(long) ").text.count == TranslateText.maxLength && TranslateText.clean(long).truncated, "太长只翻前 2000 字并说明")
        let text = "第一句话。第二句话比较长一些，但是也不算太长！第三句？" + String(repeating: "很", count: 70)
        let pieces = TranslateText.chunks(text, limit: 30)
        check(pieces.allSatisfy { $0.count <= 30 } && pieces.joined() == text, "译文按句子切成一块块，每块不超过上限，内容不丢")
        check(TranslateText.chunks("One. Two. Three.", limit: 56) == ["One. Two. Three."], "短句合并成一块")

        let board = NSPasteboard(name: NSPasteboard.Name("local.aiquota.tests." + UUID().uuidString))
        let model = AppModel()
        let fake = FakeTranslator()
        let recorder = Recorder()
        model.translator = fake
        model.pasteboard = board
        model.onTranslate = { recorder.translated += 1 }
        board.clearContents()
        board.setString("Hello world.", forType: .string)
        check(model.translation == .idle && fake.calls.isEmpty, "不点就不读剪贴板、不翻译")
        model.translateClipboard()
        if case .working = model.translation {} else { check(false, "点了就开始翻译") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        if case .done(let result) = model.translation {
            check(result.text == "译文：Hello world." && result.from == "en" && result.to == "zh-Hans" && recorder.translated == 1, "翻译剪贴板：拿到译文并展开触控栏")
        } else {
            check(false, "翻译剪贴板：拿到译文并展开触控栏")
        }
        model.copyTranslation()
        check(board.string(forType: .string) == "译文：Hello world.", "复制译文")
        board.clearContents()
        model.translateClipboard()
        check(model.translation == .failed("剪贴板里没有文字", needsDownload: false), "剪贴板里没有文字时直接说")
        fake.delays = [0.4, 0.05]
        model.translate("First request.")
        model.translate("Second request.")
        try? await Task.sleep(nanoseconds: 600_000_000)
        if case .done(let result) = model.translation { check(result.source == "Second request.", "先发的慢结果回来晚了不覆盖后发的") } else { check(false, "先发的慢结果回来晚了不覆盖后发的") }
        fake.failure = .notInstalled(from: "en", to: "zh-Hans")
        model.translate("Needs download.")
        try? await Task.sleep(nanoseconds: 100_000_000)
        if case .failed(let message, let download) = model.translation {
            check(download && message.contains("翻译语言"), "没下载语言时说清楚去哪里下载")
        } else {
            check(false, "没下载语言时说清楚去哪里下载")
        }
        fake.failure = nil

        let servicePasteboard = NSPasteboard(name: NSPasteboard.Name("local.aiquota.tests.service." + UUID().uuidString))
        servicePasteboard.clearContents()
        servicePasteboard.setString("Selected text.", forType: .string)
        let service = TranslateService(model: model)
        var problem: NSString?
        service.translateOnTouchBar(servicePasteboard, userData: nil, error: &problem)
        try? await Task.sleep(nanoseconds: 100_000_000)
        if case .done(let result) = model.translation { check(result.source == "Selected text." && problem == nil, "「服务」送来的选中文字直接翻译") } else { check(false, "「服务」送来的选中文字直接翻译") }
        servicePasteboard.releaseGlobally()

        let bar = TouchBarItem()
        bar.presenter = { _ in recorder.presented += 1 }
        bar.onTranslation = { recorder.commands.append($0) }
        bar.pretendShownForTesting()
        bar.update(rows: rows, lights: [], tasks: [], now: now, translation: .idle)
        check(!bar.shown.contains { $0.id == "translate" }, "翻译卡不占 AI 页")
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "tools" } ?? 0)
        let ids = bar.shown.map(\.id)
        if let shelfIndex = ids.firstIndex(of: "shelf") { check(ids[shelfIndex + 1] == "translate", "工具页里材料架后面是翻译卡") } else { check(false, "工具页里材料架后面是翻译卡") }
        bar.tapForTesting(ids.firstIndex(of: "translate") ?? 0)
        check(bar.shown.map(\.id) == ["translate:clipboard", "translate:help"], "没翻过时：翻译剪贴板和用法说明")
        bar.tapForTesting(0)
        check(recorder.commands == [.clipboard], "点翻译剪贴板")
        if case .done(let result) = model.translation {
            bar.update(rows: rows, lights: [], tasks: [], now: now, translation: .done(result))
            let parts = bar.shown.map(\.id)
            check(parts.first == "translate:head" && parts.contains("translate:piece:0") && Array(parts.suffix(2)) == ["translate:copy", "translate:clipboard"], "有译文时：方向、译文几块、复制、再翻译")
            check(bar.shown.allSatisfy { $0.image.size.width <= TouchBarItem.detailWidth }, "每块放得进一屏")
        }
        let missing = TouchBarItem.translationImages(.failed(TranslateText.message(for: TranslateError.notInstalled(from: "en", to: "zh-Hans")).text, needsDownload: true)).map(\.id)
        check(missing == ["translate:head", "translate:settings", "translate:clipboard"], "没下载语言时给一个打开设置的按钮")
        let quiet = TouchBarItem()
        quiet.presenter = { _ in recorder.presented += 1 }
        quiet.pretendShownForTesting()
        quiet.update(rows: rows, lights: [], tasks: [], now: now)
        quiet.showTranslation()
        if case .translation = quiet.page { check(recorder.presented == 1, "从「服务」翻译时自动展开到翻译页") } else { check(false, "从「服务」翻译时自动展开到翻译页") }
        board.releaseGlobally()
    }
}
