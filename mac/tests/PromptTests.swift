import AppKit

enum PromptTests {
    final class Recorder {
        var presses = 0
        var presented = 0
        var used: [String] = []
        var edits = 0
    }

    @MainActor
    static func run(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        let generalCount = NSPasteboard.general.changeCount
        store(check: check)
        files(check: check)
        model(check: check)
        bar(now: now, rows: rows, check: check)
        check(NSPasteboard.general.changeCount == generalCount, "指令条测试没有碰用户真实的剪贴板")
    }

    @MainActor
    static func store(check: (Bool, String) -> Void) {
        var store = PromptStore()
        check(store.items.count == PromptStore.defaults.count && store.items.first == PromptItem(id: "p1", text: "继续") && !store.autoShow, "第一次用有一组默认指令，默认不自动弹指令条")
        check(store.add("  \n ") == .rejected(.empty) && store.add(String(repeating: "长", count: PromptStore.maxLength + 1)) == .rejected(.tooLong), "空的和太长的不收")
        check(store.add("  用中文回答\n") == .duplicate("p8"), "去掉首尾空白后重复的算同一条")
        let added = store.add("再想想有没有更简单的办法")
        check(added == .saved("p9") && store.items.last?.text == "再想想有没有更简单的办法", "添加一条")
        check(store.update("p9", text: "继续") == .duplicate("p1") && store.item("p9")?.text == "再想想有没有更简单的办法", "改成和别的重复就不改")
        check(store.update("p9", text: "  换个思路\n") == .saved("p9") && store.item("p9")?.text == "换个思路", "修改一条")
        check(store.update("missing", text: "x") == .rejected(.missing), "改不存在的一条")
        check(store.move("p9", by: -1) && store.items[store.items.count - 2].id == "p9" && !store.move("p1", by: -1) && !store.move("p9", by: 5), "上下移，不出界")
        check(store.remove("p2") && !store.remove("p2") && store.item("p2") == nil, "删除一条")
        while store.items.count < PromptStore.limit { _ = store.add("填满 \(store.items.count)") }
        check(store.add("放不下") == .rejected(.full) && store.items.count == PromptStore.limit, "最多 \(PromptStore.limit) 条")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-prompts-" + UUID().uuidString)
        let file = folder.appendingPathComponent("prompts.json")
        let missing = PromptStore.load(from: file)
        check(missing.store == PromptStore() && !missing.damaged, "没有文件时用默认指令")
        var saved = PromptStore(texts: ["甲", "乙"])
        saved.autoShow = true
        try? saved.save(to: file)
        let loaded = PromptStore.load(from: file)
        check(loaded.store.items.map(\.text) == ["甲", "乙"] && loaded.store.autoShow && !loaded.damaged, "存了再读回来一样（包括打开了自动弹出）")
        try? Data("不是 JSON".utf8).write(to: file)
        let broken = PromptStore.load(from: file)
        check(broken.damaged && broken.store.items.count == PromptStore.defaults.count, "文件坏了先用默认指令，并标记出来")
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    static func files(check: (Bool, String) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-prompts-files-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("prompts.json")
        let many = (1...25).map { "第 \($0) 条" }
        try? JSONSerialization.data(withJSONObject: ["items": many]).write(to: file)
        let trimmed = PromptStore.load(from: file)
        check(trimmed.damaged && trimmed.store.items.count == PromptStore.limit, "超过 20 条读不全时标记出来，保存前会先备份")
        try? JSONSerialization.data(withJSONObject: ["items": ["甲", 3, "乙"]]).write(to: file)
        check(PromptStore.load(from: file).damaged, "混进了不是文字的条目也标记出来")
        try? JSONSerialization.data(withJSONObject: ["items": ["甲", "乙"]]).write(to: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let locked = PromptStore.load(from: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        check(locked.damaged, "文件在但读不了，不当成没有文件")
        let base = file.lastPathComponent + ".bad-"
        let first = AppModel.backupURL(for: file, now: Date(timeIntervalSince1970: 0))
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = AppModel.backupURL(for: file, now: Date(timeIntervalSince1970: 0))
        check(first.lastPathComponent.hasPrefix(base) && second != first && second.lastPathComponent.hasPrefix(first.lastPathComponent + "-"), "备份文件名重了就换一个，不覆盖旧备份")
        check(PromptTargets.resolve("com.anthropic.claudefordesktop", own: "local.aiquota.menubar") == (false, "Claude")
              && PromptTargets.resolve("local.aiquota.menubar", own: "local.aiquota.menubar") == (true, nil)
              && PromptTargets.resolve("com.apple.finder", own: "local.aiquota.menubar") == (false, nil)
              && PromptTargets.resolve(nil, own: "local.aiquota.menubar") == (false, nil),
              "打开自己的菜单栏面板不算离开 AI app")
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    static func model(check: (Bool, String) -> Void) {
        let board = NSPasteboard(name: NSPasteboard.Name("local.aiquota.tests." + UUID().uuidString))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiquota-prompts-model-" + UUID().uuidString)
        let model = AppModel()
        model.pasteboard = board
        model.promptsFile = folder.appendingPathComponent("prompts.json")
        model.loadPrompts()
        check(model.promptStore.items.count == PromptStore.defaults.count && !FileManager.default.fileExists(atPath: model.promptsFile.path), "读的时候不写文件")
        board.clearContents()
        board.setString("用户原来的内容", forType: .string)
        model.usePrompt("p1")
        check(board.string(forType: .string) == "继续" && model.promptNote == PromptNote(id: "p1", text: "已复制，⌘V 粘贴", warning: false), "点一条：复制这句话并提示按 ⌘V")
        let types = board.types?.map(\.rawValue) ?? []
        check(!types.contains("org.nspasteboard.TransientType"), "复制的是普通文字，不假装是临时内容")
        model.usePrompt("missing")
        check(model.promptNote == PromptNote(id: "", text: "这条指令已经删掉了", warning: true), "点到已经删掉的一条，提示放在大家都看得到的地方")
        check(TouchBarItem.promptImages(model.promptStore.items, app: "Claude", note: model.promptNote).last?.image.tiffRepresentation
              != TouchBarItem.promptImages(model.promptStore.items, app: "Claude", note: nil).last?.image.tiffRepresentation,
              "触控栏上这条提示画在「编辑…」卡上")
        model.editPrompts { $0.add("看看日志里有没有报错") }
        let reloaded = PromptStore.load(from: model.promptsFile)
        check(reloaded.store.items.last?.text == "看看日志里有没有报错", "改动存到 prompts.json")
        model.editPrompts { $0.add("继续") }
        check(model.promptNote?.text == "已经有这一条了", "重复添加有提示")
        try? Data("坏掉的内容".utf8).write(to: model.promptsFile)
        model.loadPrompts()
        check(model.promptNote?.warning == true && model.promptNote?.text.contains("备份") == true, "读到坏文件时先告诉你")
        model.setPromptAutoShow(false)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasPrefix("prompts.json.bad-") } ?? []
        check(backups.count == 1 && PromptStore.load(from: model.promptsFile).store.autoShow == false, "文件坏了时先备份再保存")
        check(model.promptNote?.text.contains(backups.first ?? "?") == true, "告诉你备份到了哪个文件")
        try? Data("又坏了".utf8).write(to: model.promptsFile)
        model.loadPrompts()
        model.setPromptAutoShow(true)
        let twice = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasPrefix("prompts.json.bad-") } ?? []
        check(twice.count == 2, "同一分钟里第二次坏掉也另存一份备份")
        try? FileManager.default.removeItem(at: folder)
        board.releaseGlobally()
    }

    @MainActor
    static func bar(now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        let recorder = Recorder()
        let store = PromptStore()
        let bar = TouchBarItem()
        bar.presenter = { _ in recorder.presented += 1 }
        bar.onPrompt = { recorder.used.append($0) }
        bar.onEditPrompts = { recorder.edits += 1 }
        bar.pretendShownForTesting()
        bar.update(rows: rows, lights: [], tasks: [], now: now, prompts: store.items)
        bar.setPromptContext(app: "Claude", autoShow: true)
        check(recorder.presented == 1 && bar.promptAutoForTesting, "Claude 到前台时自动展开指令条")
        check(bar.shown.map(\.id) == store.items.map { "prompt:" + $0.id } + ["prompts:edit"], "指令条：每条一块，最后是编辑")
        check(bar.shown.allSatisfy { $0.image.size.width <= TouchBarItem.promptMaxWidth }, "每块不超过 \(Int(TouchBarItem.promptMaxWidth))pt")
        bar.setPromptContext(app: "Claude", autoShow: true)
        check(recorder.presented == 1, "同一个 app 重复报到前台不再弹一次")
        bar.setPromptContext(app: nil, autoShow: true)
        bar.setPromptContext(app: "Codex", autoShow: false)
        check(recorder.presented == 1, "关掉自动显示就不弹")
        bar.setPromptContext(app: nil, autoShow: true)
        bar.setPromptContext(app: "Codex", autoShow: true)
        check(recorder.presented == 2, "切走再切回来会再弹")
        bar.tapForTesting(1)
        check(recorder.used == ["p2"], "点一条只发出这一条的 id")
        bar.tapForTesting(bar.shown.count - 1)
        check(recorder.edits == 1, "点编辑去菜单栏")
        bar.tapForTesting(0)
        var reordered = store
        reordered.move("p3", by: -2)
        bar.beginInteractionForTesting()
        bar.update(rows: rows, lights: [], tasks: [], now: now, prompts: reordered.items)
        bar.tapForTesting(0)
        bar.endInteractionForTesting()
        check(recorder.used == ["p2", "p1", "p1"], "按着时在菜单栏改了顺序，点的仍是手指下面那条")
        let noted = TouchBarItem.promptImages(store.items, app: "Claude", note: PromptNote(id: "p1", text: "已粘贴，回车发送", warning: false))
        let plain = TouchBarItem.promptImages(store.items, app: "Claude", note: nil)
        check(zip(noted, plain).allSatisfy { $0.image.size == $1.image.size && $0.id == $1.id }, "提示只换图，不改大小和身份")
        check(TouchBarItem.promptImages([], app: "Claude", note: nil).map(\.id) == ["prompts:empty"], "没有指令时提示去添加")

        let other = TouchBarItem()
        other.presenter = { _ in recorder.presented += 1 }
        other.pretendShownForTesting()
        other.update(rows: rows, lights: [], tasks: [], now: now, prompts: store.items)
        other.tapGlanceForTesting()
        if case .overview = other.page {} else { check(false, "不在 AI app 里点小图标还是打开总览") }
        other.setPromptContext(app: "Codex", autoShow: false)
        other.closeDetail()
        other.tapGlanceForTesting()
        if case .overview = other.page {} else { check(false, "在 AI app 里点小图标也先看总览，指令条在下一层") }
        other.backForTesting()
        check(!other.shown.contains { $0.id == "prompts" }, "「常用指令」卡不占 AI 页")
        other.tapForTesting(other.shown.firstIndex { $0.id == "tools" } ?? 0)
        let toolIDs = other.shown.map(\.id)
        if let promptsIndex = toolIDs.firstIndex(of: "prompts"), let shelfIndex = toolIDs.firstIndex(of: "shelf") {
            check(promptsIndex < shelfIndex, "在 AI app 里，工具页里材料架前面有一张「常用指令」卡")
            other.tapForTesting(promptsIndex)
            if case .prompts = other.page {} else { check(false, "从工具页能进指令条") }
            other.backForTesting()
            if case .tools = other.page {} else { check(false, "指令条返回回到工具页") }
        } else {
            check(false, "在 AI app 里，工具页里有「常用指令」卡")
        }

        let later = TouchBarItem()
        let shown = Recorder()
        later.presenter = { _ in shown.presented += 1 }
        later.pretendShownForTesting()
        later.update(rows: rows, lights: [], tasks: [], now: now, prompts: store.items)
        later.tapGlanceForTesting()
        later.visibleForTesting = true
        later.setPromptContext(app: "Claude", autoShow: true)
        if case .overview = later.page {} else { check(false, "正在看总览时切到 Claude，先不打断") }
        check(shown.presented == 1, "正在看别的页时不重复弹出")
        later.closeTimerFiredForTesting()
        if case .prompts = later.page { check(later.promptAutoForTesting, "总览到时间后换成指令条，而不是收起") } else { check(false, "总览到时间后换成指令条，而不是收起") }
    }
}
