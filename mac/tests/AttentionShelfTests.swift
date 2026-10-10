import AppKit
import SwiftUI

enum AttentionShelfTests {
    final class Recorder {
        var urls: [URL] = []
        var bundles: [String] = []
        var sessions: [String] = []
        var projects = 0
        var links = 0
        var commands: [ShelfCommand] = []
    }

    @MainActor
    static func run(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        let generalCount = NSPasteboard.general.changeCount
        attention(now: now, rows: rows, check: check)
        let board = NSPasteboard(name: NSPasteboard.Name("local.aiquota.tests." + UUID().uuidString))
        shelfStore(board: board, check: check)
        shelfModel(board: board, check: check)
        shelfBar(now: now, rows: rows, check: check)
        await clearConfirmation(now: now, rows: rows, check: check)
        tapToCopy(board: board, now: now, rows: rows, check: check)
        await popoverHeight(now: now, rows: rows, check: check)
        board.releaseGlobally()
        check(NSPasteboard.general.changeCount == generalCount, "测试没有写过用户真实的剪贴板")
    }

    static func session(_ agent: String, _ id: String, _ state: SessionState, now: Date, reason: String = "",
                        minutesAgo: Double = 1, order: Double) -> AgentSession {
        let moment = now.addingTimeInterval(-minutesAgo * 60)
        return AgentSession(agent: agent, id: id, state: state, since: moment, updated: moment,
                            first: now.addingTimeInterval(order * 60 - 7200), title: "任务 " + id, bundle: "", waitReason: reason)
    }

    @MainActor
    static func attention(now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        let question = session("codex", "00000000-0000-4000-8000-000000000001", .waiting, now: now, reason: "question", minutesAgo: 30, order: 0)
        let permission = session("claude", "permission", .waiting, now: now, reason: "permission", order: 1)
        let unknown = session("codex", "legacy-wait", .waiting, now: now, order: 2)
        let failed = session("claude", "failed", .error, now: now, order: 3)
        let finished = session("codex", "00000000-0000-4000-8000-000000000005", .done, now: now, minutesAgo: 3, order: 4)
        let running = session("claude", "running", .running, now: now, order: 5)
        let oldDone = session("claude", "old-done", .done, now: now, minutesAgo: 30, order: 6)
        let staleWait = session("codex", "stale-wait", .waiting, now: now, reason: "question",
                                minutesAgo: SessionHook.waitingExpiry / 60 + 1, order: 7)
        let staleError = session("claude", "stale-error", .error, now: now, minutesAgo: 180, order: 8)
        let model = AppModel()
        let recorder = Recorder()
        model.openURL = { url in recorder.urls.append(url); return true }
        model.launchApp = { bundle, done in recorder.bundles.append(bundle); done(.opened) }
        model.sessions = [staleError, finished, running, failed, oldDone, unknown, staleWait, permission, question]
        let items = Attention.items(from: model.lights(at: now))
        check(items.map(\.key) == [question.key, permission.key, unknown.key, failed.key, finished.key], "待处理按等待 > 出错 > 完成排，同组按出现先后")
        check(items.map(\.action) == ["回答问题", "查看权限请求", "查看任务", "查看错误", "查看结果"], "每种待处理写明要做什么，原因不明只写查看任务")
        check(items.map(\.destination) == ["跳到这条对话", "打开 Claude app", "打开 Codex", "打开 Claude app", "跳到这条对话"],
              "Codex 有线程 id 才说跳到对话，Claude 如实写只能打开 app")
        check(Attention.summary(items) == "等你 3 · 出错 1 · 完成 1", "待处理卡上的分类计数")
        check(!items.contains { [running.key, oldDone.key, staleWait.key, staleError.key].contains($0.key) },
              "运行中、看过或过了 20 分钟的完成、过期的等待和出错都不算待处理")
        var touched = model.sessions
        if let index = touched.firstIndex(where: { $0.key == question.key }) { touched[index].updated = now }
        model.sessions = touched
        check(Attention.items(from: model.lights(at: now)).map(\.key) == items.map(\.key), "同组顺序不因为最近更新而跳动")

        for key in [question.key, permission.key, unknown.key, failed.key, finished.key] { model.open(key) }
        check(recorder.urls.map(\.absoluteString) == ["codex://threads/00000000-0000-4000-8000-000000000001", "codex://threads/00000000-0000-4000-8000-000000000005"],
              "Codex 任务只是跳到对话")
        check(recorder.bundles == ["com.anthropic.claudefordesktop", "com.openai.codex", "com.anthropic.claudefordesktop"], "其余只是打开对应的 app")
        let after = Attention.items(from: model.lights(at: now))
        check(after.map(\.key) == [question.key, permission.key, unknown.key, failed.key], "打开成功后等待和出错仍在，只有完成算看过")
        check(model.sessions.map(\.state) == touched.map(\.state), "打开任务不改任何会话状态")

        // Claude 的会话也直达：id 是 UUID 的用桌面 app 深链接；已收编的用 code/continue 跳转，没收编的用 resume 导入
        let claudeUuid = "01000000-0000-4000-8000-000000000009"
        let claudeTask = session("claude", claudeUuid, .running, now: now, order: 8)
        check(claudeTask.threadURL?.absoluteString == "claude://resume?session=" + claudeUuid, "Claude 会话默认用 resume 深链接")
        check(session("claude", "legacy-id", .running, now: now, order: 9).threadURL == nil, "id 不是 UUID 的 Claude 会话没有链接")
        model.claudeAdopted = { _ in false }
        model.sessions = [claudeTask]
        model.open(claudeTask.key)
        check(recorder.urls.last?.absoluteString == "claude://resume?session=" + claudeUuid, "没收编的 Claude 会话：resume 导入并打开")
        model.claudeAdopted = { _ in true }
        model.open(claudeTask.key)
        check(recorder.urls.last?.absoluteString == "claude://code/continue?session=local_" + claudeUuid, "已收编的 Claude 会话：continue 跳转")
        model.claudeAdopted = { _ in false }
        model.sessions = touched
        let zTask = session("zcode", "sess_z1", .running, now: now, order: 10)
        check(zTask.agentName == "ZCode" && zTask.appBundle == "dev.zcode.app" && zTask.threadURL == nil
              && AttentionItem(session: zTask, light: .running, kind: .result).destination == "打开 ZCode",
              "ZCode 的任务写打开 ZCode（还没有会话级深链接）")

        let bar = TouchBarItem()
        bar.onOpenSession = { recorder.sessions.append($0) }
        bar.onProjectAction = { _, _ in recorder.projects += 1 }
        bar.onLink = { _ in recorder.links += 1 }
        bar.onShelf = { recorder.commands.append($0) }
        bar.update(rows: rows, lights: model.lights(at: now), tasks: model.tasks(at: now), now: now)
        let ids = bar.shown.map(\.id)
        check(ids[0] == "quota" && ids[1] == "task:" + model.tasks(at: now)[0].session.key && ids.suffix(3) == ["chats", "pet", "tools"],
              "AI 页：额度表在最前，紧跟着最急的那条对话，后面是「对话」、小猫、「工具」（待处理、番茄钟、材料架这些都不占 AI 页）")
        check(!ids.contains("attention") && !ids.contains("calm") && !ids.contains("shelf") && !ids.contains("translate"), "工具卡不在 AI 页")
        check(bar.shown.reduce(CGFloat(0)) { $0 + $1.image.size.width } + CGFloat(bar.shown.count - 1) * TouchBarItem.detailSpacing == TouchBarItem.detailWidth,
              "AI 页正好一屏，不用划")
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "pet" } ?? 0)
        if case .pet = bar.page {} else { check(false, "点小猫进小猫的家") }
        check(!bar.shown.contains { $0.id.contains("attention") || $0.id == "shelf" || $0.id == "translate" || $0.id == "prompts" || $0.id == "link" },
              "小猫的家只留放松的：待处理、材料架、翻译、常用指令、双机都不在里面")
        bar.backForTesting()
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "tools" } ?? 0)
        if case .tools = bar.page {} else { check(false, "点「工具」进工具页") }
        check(bar.shown.map(\.id) == ["shelf", "translate", "attention"], "工具页：材料架、翻译、待处理（没在 Claude/Codex 里就没有常用指令）")
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "attention" } ?? 0)
        if case .attention = bar.page {} else { check(false, "工具页里点待处理进待处理页") }
        check(bar.shown.map(\.id) == after.map { "attention:" + $0.key }, "待处理页列出全部任务，不再有「Claude 只能打开 app」的说明卡")
        bar.backForTesting()
        if case .tools = bar.page {} else { check(false, "工具页里进的待处理页，返回回到工具页") }
        bar.backForTesting()
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "tools" } ?? 0)
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "attention" } ?? 0)

        bar.beginInteractionForTesting()
        let urgent = session("codex", "urgent", .waiting, now: now, reason: "question", order: -1)
        model.sessions = model.sessions + [urgent]
        bar.update(rows: rows, lights: model.lights(at: now), tasks: model.tasks(at: now), now: now)
        check(bar.shown.first?.id == "attention:" + question.key, "手指按着时不换成新的待处理")
        bar.tapForTesting(0)
        bar.endInteractionForTesting()
        check(recorder.sessions == [question.key], "按着时插进来新任务，点的仍是手指下面那个")
        check(recorder.projects == 0 && recorder.links == 0 && recorder.commands.isEmpty, "点待处理只导航，不做别的动作")

        let empty = TouchBarItem()
        empty.presenter = { _ in }
        empty.pretendShownForTesting()
        empty.update(rows: rows, lights: [], tasks: [], now: now)
        check(!empty.shown.contains { $0.id == "attention" }, "没有待处理时 AI 页上没有待处理卡")
        empty.openPage(named: "attention")
        check(empty.shown.map(\.id) == ["attention:empty"], "没有待处理时是清楚的空态")
        empty.tapForTesting(0)
        if case .attention = empty.page {} else { check(false, "点空态不跳走") }
        let codexOnly = Attention.items(from: [(question, .waiting)])
        check(!TouchBarItem.attentionImages(codexOnly).contains { $0.id == "attention:claude-note" }, "只有 Codex 任务时不显示 Claude 说明")
    }

    static func isClear(_ command: ShelfCommand) -> Bool {
        if case .clear = command { return true }
        return false
    }

    @MainActor
    static func index(_ bar: TouchBarItem, _ id: String) -> Int {
        bar.shown.firstIndex { $0.id == id } ?? -1
    }

    /// 材料架在小猫的家里：先点小猫（关掉小猫时是「工具」），再点材料架
    @MainActor
    static func openShelf(_ bar: TouchBarItem) {
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "tools" } ?? -1)
        bar.tapForTesting(index(bar, "shelf"))
    }

    static func put(_ board: NSPasteboard, _ text: String, markers: [String] = []) {
        board.clearContents()
        board.declareTypes([.string] + markers.map { NSPasteboard.PasteboardType($0) }, owner: nil)
        board.setString(text, forType: .string)
        for marker in markers { board.setData(Data(), forType: NSPasteboard.PasteboardType(marker)) }
    }

    @MainActor
    static func shelfStore(board: NSPasteboard, check: (Bool, String) -> Void) {
        var shelf = Shelf()
        board.clearContents()
        check(shelf.add(from: board) == .rejected(.empty), "剪贴板空的不添加")
        put(board, "  \n\t ")
        check(shelf.add(from: board) == .rejected(.blank) && shelf.items.isEmpty, "只有空白不添加")
        put(board, "第一条材料")
        check(shelf.add(from: board) == .added("m1"), "添加文本")
        check(shelf.add(from: board) == .duplicate("m1") && shelf.items.count == 1, "重复内容复用原来的 id")
        let before = shelf.items
        put(board, String(repeating: "中", count: 21846))
        check(shelf.add(from: board) == .rejected(.tooLarge) && shelf.items == before, "超过 64KiB（按 UTF-8）不添加、不改原内容")
        put(board, String(repeating: "a", count: Shelf.maxBytes + 1))
        check(shelf.add(from: board) == .rejected(.tooLarge) && shelf.items == before, "多 1 字节也不添加")
        put(board, String(repeating: "a", count: Shelf.maxBytes))
        check(shelf.add(from: board) == .added("m2"), "正好 64KiB 可以添加")
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            let snapshot = shelf.items
            put(board, "demo-secret-value", markers: [marker])
            check(shelf.add(from: board) == .rejected(.sensitive) && shelf.items == snapshot, "带 \(marker) 标记的不添加")
        }
        let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        board.clearContents()
        board.setData(picture?.tiffRepresentation ?? Data(), forType: .tiff)
        let beforeImage = shelf.items
        check(shelf.add(from: board) == .rejected(.image) && shelf.items == beforeImage, "图片和截图暂不支持")
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("local.aiquota.tests.custom"))
        check(shelf.add(from: board) == .rejected(.unsupported) && shelf.items == beforeImage, "别的格式不支持")
        board.clearContents()
        let paths = ["/Users/demo/不存在的目录/报告.pdf", "/Users/demo/草稿 b.txt"]
        board.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        check(shelf.add(from: board) == .added("m3"), "复制的文件按路径添加（文件不存在也不去读）")
        check(shelf.item("m3")?.kind == .paths(2) && shelf.item("m3")?.text == paths.joined(separator: "\n"), "文件只转成路径文本")
        check(shelf.item("m3")?.preview(limit: 24) == "报告.pdf 等 2 个", "路径的短预览")
        put(board, "第四条")
        _ = shelf.add(from: board)
        put(board, "第五条")
        _ = shelf.add(from: board)
        let full = shelf.items
        put(board, "第六条")
        check(shelf.add(from: board) == .rejected(.full) && shelf.items == full, "满 5 条时明确拒绝，不悄悄挤掉旧的")
        put(board, "第一条材料")
        check(shelf.add(from: board) == .duplicate("m1"), "满了时重复内容仍复用原 id")
        check(ShelfRejection.full.message.contains("先移除"), "满了的提示让你先移除")
        check(shelf.copy("m1", to: board) && board.string(forType: .string) == "第一条材料", "复制回剪贴板")
        check(shelf.copy("m3", to: board) && board.string(forType: .string) == paths.joined(separator: "\n"), "路径按文本复制回去")
        check(!shelf.copy("missing", to: board), "不存在的材料不复制")
        check(shelf.remove("m1") && shelf.items.count == 4 && !shelf.remove("m1") && !shelf.remove("missing"), "单条移除，重复移除没有副作用")
        put(board, "第六条")
        check(shelf.add(from: board) == .added("m6"), "移除后能再加，id 不复用旧的")
        shelf.clear()
        check(shelf.items.isEmpty, "清空")
    }

    @MainActor
    static func shelfModel(board: NSPasteboard, check: (Bool, String) -> Void) {
        let model = AppModel()
        model.pasteboard = board
        put(board, "模型里的材料")
        check(model.shelf.items.isEmpty, "不点添加就不读剪贴板")
        model.shelfAction(.add)
        check(model.shelf.items.count == 1 && model.shelfNote == ShelfNote(text: "已添加", scope: .shelf, warning: false), "点添加才读一次")
        model.shelfAction(.add)
        check(model.shelf.items.count == 1 && model.shelfNote?.text == "已经有这一条了", "重复添加有提示")
        for index in 2...5 {
            put(board, "材料 \(index)")
            model.shelfAction(.add)
        }
        put(board, "放不下的材料")
        model.shelfAction(.add)
        check(model.shelf.items.count == 5 && model.shelfNote?.warning == true && model.shelfNote?.text.contains("先移除") == true, "满了提示先移除")
        let first = model.shelf.items[0].id
        model.shelfAction(.copy(first))
        check(board.string(forType: .string) == "模型里的材料" && model.shelfNote?.scope == .item(first), "复制成功有提示")
        model.shelfAction(.remove(first))
        check(model.shelf.items.count == 4 && model.shelf.item(first) == nil, "移除一条")
        model.shelfAction(.clear(["m2"]))
        check(model.shelf.items.count == 4 && model.shelfNote?.warning == true, "要清的集合和现在的不一致就不清")
        model.shelfAction(.clear(Set(model.shelf.items.map(\.id))))
        check(model.shelf.items.isEmpty && model.shelfNote?.text == "已清空", "清空确认过的这几条")
    }

    @MainActor
    static func shelfBar(now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        var shelf = Shelf()
        for text in ["甲材料", "乙材料", "丙材料"] { _ = shelf.add(kind: .text, text: text) }
        let recorder = Recorder()
        let bar = TouchBarItem()
        bar.onShelf = { recorder.commands.append($0) }
        bar.onOpenSession = { recorder.sessions.append($0) }
        bar.update(rows: rows, lights: [], tasks: [], now: now, shelf: shelf)
        openShelf(bar)
        check(bar.shown.map(\.id) == ["shelf:add", "shelf:item:m1", "shelf:item:m2", "shelf:item:m3", "shelf:clear"], "材料页：添加、每条材料、清空")
        bar.tapForTesting(0)
        check(recorder.commands == [.add], "点添加才去读剪贴板")
        bar.tapForTesting(2)
        if case .material(let id) = bar.page { check(id == "m2", "点材料进它的详情页") } else { check(false, "点材料进它的详情页") }
        check(recorder.commands == [.add, .copy("m2")], "点材料按它的 id 复制一次")
        check(bar.shown.map(\.id) == ["material:preview", "material:copy", "material:remove"], "详情页：预览、复制、移除")
        bar.tapForTesting(0)
        bar.tapForTesting(1)
        check(recorder.commands == [.add, .copy("m2"), .copy("m2"), .copy("m2")], "详情里点预览或复制都会再复制")
        bar.backForTesting()
        if case .shelf = bar.page {} else { check(false, "从材料详情返回材料页") }
        bar.tapForTesting(2)
        bar.tapForTesting(2)
        check(recorder.commands.last == .remove("m2"), "详情页里的移除只移除这一条")
        if case .shelf = bar.page {} else { check(false, "移除后回到材料页") }

        let clearIndex = bar.shown.firstIndex { $0.id == "shelf:clear" }!
        let clearSize = bar.shown[clearIndex].image.size
        bar.tapForTesting(clearIndex)
        check(!recorder.commands.contains(where: isClear), "点一下清空只上膛")
        check(bar.shown[clearIndex].image.size == clearSize, "上膛前后清空卡一样宽")
        bar.tapForTesting(clearIndex)
        check(recorder.commands.last == .clear(["m1", "m2", "m3"]), "再点一下才清空，清的是确认过的这几条")
        bar.tapForTesting(clearIndex)
        bar.tapForTesting(1)
        bar.backForTesting()
        bar.tapForTesting(clearIndex)
        check(recorder.commands.filter(isClear).count == 1, "上膛后换页就取消，回来再点只是重新上膛")
        bar.closeDetail()

        var removed = shelf
        removed.remove("m1")
        bar.beginInteractionForTesting()
        bar.update(rows: rows, lights: [], tasks: [], now: now, shelf: removed)
        check(bar.shown.map(\.id).contains("shelf:item:m1"), "手指按着时不换材料列表")
        bar.tapForTesting(3)
        bar.endInteractionForTesting()
        if case .material(let id) = bar.page { check(id == "m3", "按着时少了一条，点的仍是手指下面那条") } else { check(false, "按着时少了一条，点的仍是手指下面那条") }
        var gone = removed
        gone.remove("m3")
        bar.update(rows: rows, lights: [], tasks: [], now: now, shelf: gone)
        bar.backForTesting()
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "shelf:item:m2" } ?? 0)
        bar.update(rows: rows, lights: [], tasks: [], now: now, shelf: Shelf())
        bar.settleForTesting(generation: bar.touchGenerationForTesting)
        if case .shelf = bar.page {} else { check(false, "材料在别处被移除后详情页退回材料页") }
        check(bar.shown.map(\.id) == ["shelf:add", "shelf:empty"], "退回的材料页是最新的空态")

        // 工具页 → 材料架 → 一条材料 → 返回 → 返回：回到工具页（不是 AI 页）
        let twoLevel = TouchBarItem()
        twoLevel.update(rows: rows, lights: [], tasks: [], now: now, shelf: shelf)
        openShelf(twoLevel)
        twoLevel.tapForTesting(twoLevel.shown.firstIndex { $0.id == "shelf:item:m1" } ?? 0)
        if case .material = twoLevel.page {} else { check(false, "点材料进详情") }
        twoLevel.backForTesting()
        if case .shelf = twoLevel.page {} else { check(false, "详情返回材料架") }
        twoLevel.backForTesting()
        if case .tools = twoLevel.page {} else { check(false, "工具页里进的材料架，看过一条材料再返回，还是回到工具页") }

        let emptyBar = TouchBarItem()
        emptyBar.update(rows: rows, lights: [], tasks: [], now: now)
        openShelf(emptyBar)
        check(emptyBar.shown.map(\.id) == ["shelf:add", "shelf:empty"], "材料架空时有空态，没有清空按钮")
        let plain = TouchBarItem.shelfImages(shelf, note: nil, clearArmed: nil)
        let warned = TouchBarItem.shelfImages(shelf, note: ShelfNote(text: ShelfRejection.image.message, scope: .shelf, warning: true), clearArmed: 3)
        check(zip(plain, warned).allSatisfy { $0.image.size == $1.image.size && $0.id == $1.id }, "提示和上膛只换图，不改块的大小和身份")
        check(plain.allSatisfy { $0.image.size.width <= TouchBarItem.detailWidth }, "材料页每块放得进一屏")
        check(TouchBarItem.shelfCard(Shelf()).image.size == TouchBarItem.shelfCard(shelf).image.size, "材料架卡条数变了宽度不变")
        check(recorder.sessions.isEmpty, "材料架不碰任务")
    }

    @MainActor
    static func clearConfirmation(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        var two = Shelf()
        for text in ["甲", "乙"] { _ = two.add(kind: .text, text: text) }
        var three = two
        _ = three.add(kind: .text, text: "丙")
        var sameCount = three
        sameCount.remove("m3")
        _ = sameCount.add(kind: .text, text: "丁")
        let recorder = Recorder()
        let bar = TouchBarItem()
        bar.onShelf = { recorder.commands.append($0) }
        bar.update(rows: rows, lights: [], tasks: [], now: now, shelf: two)
        openShelf(bar)
        bar.tapForTesting(index(bar, "shelf:clear"))
        check(bar.clearArmedForTesting == ["m1", "m2"], "上膛时记下要清的是哪几条")
        bar.update(rows: rows, lights: [], tasks: [], now: now, shelf: three)
        check(bar.clearArmedForTesting == nil, "别处又加了一条：确认作废")
        bar.tapForTesting(index(bar, "shelf:clear"))
        check(!recorder.commands.contains(where: isClear) && bar.clearArmedForTesting == ["m1", "m2", "m3"], "作废后再点只是按现在的三条重新上膛")
        bar.update(rows: rows, lights: [], tasks: [], now: now, shelf: sameCount)
        check(bar.clearArmedForTesting == nil, "条数没变但换了一条：确认也作废")
        bar.tapForTesting(index(bar, "shelf:clear"))
        bar.tapForTesting(index(bar, "shelf:clear"))
        check(recorder.commands.filter(isClear) == [.clear(["m1", "m2", "m4"])], "第二次点按清的正是这次确认的集合")

        let frozen = TouchBarItem()
        frozen.onShelf = { recorder.commands.append($0) }
        frozen.update(rows: rows, lights: [], tasks: [], now: now, shelf: two)
        openShelf(frozen)
        let frozenClear = index(frozen, "shelf:clear")
        frozen.tapForTesting(frozenClear)
        frozen.beginInteractionForTesting()
        frozen.update(rows: rows, lights: [], tasks: [], now: now, shelf: three)
        frozen.tapForTesting(frozenClear)
        frozen.endInteractionForTesting()
        check(recorder.commands.filter(isClear).count == 1, "手指按着时材料变了，点冻结着的「再点清空」也不清")

        let savedDelay = TouchBarItem.disarmDelay
        TouchBarItem.disarmDelay = 0.3
        let timed = TouchBarItem()
        timed.onShelf = { recorder.commands.append($0) }
        timed.update(rows: rows, lights: [], tasks: [], now: now, shelf: three)
        openShelf(timed)
        timed.tapForTesting(index(timed, "shelf:clear"))
        let timedBefore = timed.shown.map(\.id)
        timed.beginInteractionForTesting()
        var withoutFirst = three
        withoutFirst.remove("m1")
        timed.update(rows: rows, lights: [], tasks: [], now: now, shelf: withoutFirst)
        try? await Task.sleep(nanoseconds: 600_000_000)
        check(timed.shown.map(\.id) == timedBefore && timed.hasTouchSnapshotForTesting, "确认超时时手指还按着：不换数据、不丢快照")
        timed.endInteractionForTesting()

        let steady = TouchBarItem()
        steady.onShelf = { recorder.commands.append($0) }
        steady.update(rows: rows, lights: [], tasks: [], now: now, shelf: three)
        openShelf(steady)
        let steadyClear = index(steady, "shelf:clear")
        steady.tapForTesting(steadyClear)
        let steadyBefore = steady.shown.map(\.id)
        steady.beginInteractionForTesting()
        steady.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(1), shelf: three,
                      shelfNote: ShelfNote(text: "已添加", scope: .shelf, warning: false))
        try? await Task.sleep(nanoseconds: 600_000_000)
        check(steady.clearArmedForTesting == nil, "4 秒没确认就取消")
        check(steady.hasTouchSnapshotForTesting && steady.shown.map(\.id) == steadyBefore, "超时只取消确认，按着时照样冻结")
        steady.tapForTesting(steadyClear)
        check(recorder.commands.filter(isClear).count == 1 && steady.clearArmedForTesting == ["m1", "m2", "m3"], "超时后点冻结着的确认卡只是重新上膛")
        steady.endInteractionForTesting()
        steady.disarmTimeoutForTesting()
        check(steady.clearArmedForTesting == nil && steady.settlingForTesting, "超时回调在刚松手时也只取消确认、等收尾再刷新")
        TouchBarItem.disarmDelay = savedDelay
    }

    @MainActor
    static func tapToCopy(board: NSPasteboard, now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        let model = AppModel()
        model.pasteboard = board
        let bar = TouchBarItem()
        let sync = { bar.update(rows: rows, lights: [], tasks: [], now: now, shelf: model.shelf, shelfNote: model.shelfNote) }
        model.onUpdate = sync
        bar.onShelf = { model.shelfAction($0) }
        put(board, "第一条")
        model.shelfAction(.add)
        put(board, "第二条")
        model.shelfAction(.add)
        put(board, "用户自己复制的内容")
        openShelf(bar)
        bar.tapForTesting(index(bar, "shelf:item:m1"))
        check(board.string(forType: .string) == "第一条", "点材料就把这一条复制回剪贴板")
        if case .material(let id) = bar.page { check(id == "m1", "复制后进详情页") } else { check(false, "复制后进详情页") }
        check(model.shelfNote == ShelfNote(text: "已复制，可以粘贴了", scope: .item("m1"), warning: false), "详情页显示复制成功")
        check(bar.shown.map(\.id) == ["material:preview", "material:copy", "material:remove"], "详情里仍有复制和移除")
        bar.backForTesting()
        put(board, "用户自己复制的内容")
        let before = board.changeCount
        let stale = index(bar, "shelf:item:m2")
        bar.beginInteractionForTesting()
        model.shelfAction(.remove("m2"))
        bar.tapForTesting(stale)
        bar.endInteractionForTesting()
        check(board.changeCount == before && board.string(forType: .string) == "用户自己复制的内容", "点到已经不在的材料不碰剪贴板")
        if case .shelf = bar.page {} else { check(false, "不在的材料不进详情，留在材料页") }
        check(model.shelfNote == ShelfNote(text: "这条材料已经不在了", scope: .shelf, warning: true), "提示这条已经不在了")
        model.shelfAction(.copy("missing"))
        check(board.changeCount == before, "复制不存在的 id 也不碰剪贴板")
        model.onUpdate = nil
    }

    @MainActor
    static func popoverHeight(now: Date, rows: [Provider], check: (Bool, String) -> Void) async {
        let model = AppModel()
        model.claude = rows[0]
        model.codex = Array(rows.dropFirst())
        model.sessions = Snapshot.demoSessions(now: now)
        model.link = Snapshot.demoLink(now: now, on: true)
        for number in 1...5 { _ = model.shelf.add(kind: .text, text: "材料 \(number) " + String(repeating: "很长的说明文字", count: 8)) }
        model.shelfNote = ShelfNote(text: String(repeating: "很长的错误反馈，", count: 12), scope: .shelf, warning: true)
        check(PopoverView.scrollLimit(screenHeight: 795) == 645 && PopoverView.scrollLimit(screenHeight: 300) == 240, "滚动区高度按屏幕可用高度留出余量")
        for screen in [600.0, 795.0, 1000.0] {
            let host = NSHostingView(rootView: PopoverView(model: model, screenHeight: screen))
            host.layoutSubtreeIfNeeded()
            check(host.fittingSize.height <= screen - 60, "屏幕可用高度 \(Int(screen)) 时面板不超出，底部按钮在滚动区外")
        }
        let small = AppModel()
        small.sessions = []
        let compact = NSHostingView(rootView: PopoverView(model: small, screenHeight: 2000))
        compact.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        compact.layoutSubtreeIfNeeded()
        check(compact.fittingSize.height < PopoverView.scrollLimit(screenHeight: 2000) / 2, "内容少时面板按内容高度，不撑到上限")
    }
}
