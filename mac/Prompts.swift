import AppKit

struct PromptItem: Identifiable, Equatable {
    let id: String
    var text: String
}

enum PromptRejection: Equatable {
    case empty, tooLong, full, missing

    var message: String {
        switch self {
        case .empty: return "内容是空的"
        case .tooLong: return "太长了（最多 \(PromptStore.maxLength) 字）"
        case .full: return "最多 \(PromptStore.limit) 条，先删掉一条"
        case .missing: return "这条已经不在了"
        }
    }
}

enum PromptEditResult: Equatable {
    case saved(String)
    case duplicate(String)
    case rejected(PromptRejection)
}

struct PromptNote: Equatable {
    let id: String
    let text: String
    let warning: Bool
}

struct PromptStore: Equatable {
    static let limit = 20
    static let maxLength = 500
    static let defaults = [
        "继续",
        "先别改代码，先说说你的方案",
        "跑一下测试，把结果告诉我",
        "解释一下刚才改了什么、为什么",
        "改动尽量小，别动无关的代码",
        "检查一下有没有漏掉的边界情况",
        "按约定写一份交接说明",
        "用中文回答",
    ]
    static var defaultURL: URL {
        AppConfig.dir.appendingPathComponent("prompts.json")
    }

    private(set) var items: [PromptItem] = []
    var autoShow = false
    private var nextNumber = 1

    init(texts: [String] = PromptStore.defaults) {
        for text in texts {
            let clean = Self.clean(text)
            guard !clean.isEmpty, clean.count <= Self.maxLength, items.count < Self.limit, !items.contains(where: { $0.text == clean }) else { continue }
            items.append(PromptItem(id: "p\(nextNumber)", text: clean))
            nextNumber += 1
        }
    }

    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func item(_ id: String) -> PromptItem? {
        items.first { $0.id == id }
    }

    private func check(_ text: String, except id: String?) -> PromptEditResult? {
        if text.isEmpty { return .rejected(.empty) }
        if text.count > Self.maxLength { return .rejected(.tooLong) }
        if let same = items.first(where: { $0.text == text && $0.id != id }) { return .duplicate(same.id) }
        return nil
    }

    mutating func add(_ text: String) -> PromptEditResult {
        let clean = Self.clean(text)
        if let problem = check(clean, except: nil) { return problem }
        if items.count >= Self.limit { return .rejected(.full) }
        let item = PromptItem(id: "p\(nextNumber)", text: clean)
        nextNumber += 1
        items.append(item)
        return .saved(item.id)
    }

    mutating func update(_ id: String, text: String) -> PromptEditResult {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return .rejected(.missing) }
        let clean = Self.clean(text)
        if let problem = check(clean, except: id) { return problem }
        items[index].text = clean
        return .saved(id)
    }

    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        return true
    }

    @discardableResult
    mutating func move(_ id: String, by offset: Int) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        guard items.indices.contains(target), target != index else { return false }
        let item = items.remove(at: index)
        items.insert(item, at: target)
        return true
    }

    static func load(from url: URL) -> (store: PromptStore, damaged: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (PromptStore(), false) }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["items"] as? [Any] else { return (PromptStore(), true) }
        let texts = list.compactMap { $0 as? String }
        var store = PromptStore(texts: texts)
        if let auto = object["autoShow"] as? Bool { store.autoShow = auto }
        return (store, texts.count != list.count || store.items.count != texts.count)
    }

    func save(to url: URL) throws {
        let object: [String: Any] = ["autoShow": autoShow, "items": items.map(\.text)]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

enum PromptTargets {
    static let apps = ["com.anthropic.claudefordesktop": "Claude", "com.openai.codex": "Codex", "dev.zcode.app": "ZCode"]

    static func resolve(_ bundle: String?, own: String?) -> (ignore: Bool, app: String?) {
        if let bundle, bundle == own { return (true, nil) }
        return (false, bundle.flatMap { apps[$0] })
    }
}

extension AppModel {
    func loadPrompts() {
        let loaded = PromptStore.load(from: promptsFile)
        promptStore = loaded.store
        promptsDamaged = loaded.damaged
        if loaded.damaged {
            showPromptNote(PromptNote(id: "", text: "prompts.json 有内容没能完整读进来，下次保存前会先把原文件备份成 prompts.json.bad-…", warning: true))
        }
    }

    static func backupURL(for file: URL, now: Date) -> URL {
        let folder = file.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = file.lastPathComponent + ".bad-" + formatter.string(from: now)
        var candidate = folder.appendingPathComponent(base)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(base + "-\(number)")
            number += 1
        }
        return candidate
    }

    @discardableResult
    private func savePrompts() -> Bool {
        if promptsDamaged {
            if FileManager.default.fileExists(atPath: promptsFile.path) {
                let backup = Self.backupURL(for: promptsFile, now: Date())
                do {
                    try FileManager.default.moveItem(at: promptsFile, to: backup)
                } catch {
                    showPromptNote(PromptNote(id: "", text: "原来的 prompts.json 备份不了，这次没保存：" + error.localizedDescription, warning: true))
                    return false
                }
                showPromptNote(PromptNote(id: "", text: "原来的 prompts.json 已备份为 " + backup.lastPathComponent, warning: false))
            }
            promptsDamaged = false
        }
        do {
            try promptStore.save(to: promptsFile)
            return true
        } catch {
            showPromptNote(PromptNote(id: "", text: "保存失败：" + error.localizedDescription, warning: true))
            return false
        }
    }

    @discardableResult
    func editPrompts(_ change: (inout PromptStore) -> PromptEditResult) -> PromptEditResult {
        var store = promptStore
        let result = change(&store)
        switch result {
        case .saved:
            promptStore = store
            savePrompts()
            onUpdate?()
        case .duplicate:
            showPromptNote(PromptNote(id: "", text: "已经有这一条了", warning: true))
        case .rejected(let reason):
            showPromptNote(PromptNote(id: "", text: reason.message, warning: true))
        }
        return result
    }

    func removePrompt(_ id: String) {
        var store = promptStore
        guard store.remove(id) else { return }
        promptStore = store
        savePrompts()
        onUpdate?()
    }

    func movePrompt(_ id: String, by offset: Int) {
        var store = promptStore
        guard store.move(id, by: offset) else { return }
        promptStore = store
        savePrompts()
        onUpdate?()
    }

    func setPromptAutoShow(_ on: Bool) {
        promptStore.autoShow = on
        savePrompts()
        onUpdate?()
    }

    func usePrompt(_ id: String) {
        guard let item = promptStore.item(id) else {
            showPromptNote(PromptNote(id: "", text: "这条指令已经删掉了", warning: true))
            return
        }
        let phrase = PromptStore.clean(item.text)
        guard !phrase.isEmpty else { return }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let copied = pasteboard.setString(phrase, forType: .string)
        showPromptNote(PromptNote(id: id, text: copied ? "已复制，⌘V 粘贴" : "复制失败，再点一次", warning: !copied))
    }

    func showPromptNote(_ note: PromptNote) {
        promptNote = note
        promptNoteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.promptNote == note else { return }
                self.promptNote = nil
                self.onUpdate?()
            }
        }
        promptNoteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        onUpdate?()
    }
}
