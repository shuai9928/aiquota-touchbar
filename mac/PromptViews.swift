import AppKit
import SwiftUI

extension TouchBarItem {
    static let promptMinWidth: CGFloat = 64
    static let promptMaxWidth: CGFloat = 200

    static func promptWidth(_ text: String) -> CGFloat {
        let measured = ceil((text as NSString).size(withAttributes: [.font: TouchBarArt.nameFont]).width) + 18
        return min(promptMaxWidth, max(promptMinWidth, measured))
    }

    static let promptEditWidth: CGFloat = 120

    static func promptsCard(_ count: Int) -> Part {
        Part(image: TouchBarArt.card("常用指令", subtitle: "\(count) 条 · 点了复制", width: 96), action: .prompts, id: "prompts")
    }

    static func promptImages(_ prompts: [PromptItem], app: String?, note: PromptNote?) -> [Part] {
        guard !prompts.isEmpty else {
            return [Part(image: TouchBarArt.card("还没有常用指令", subtitle: "点这里到菜单栏里添加", width: 180), action: .editPrompts, id: "prompts:empty")]
        }
        let orphan = note.flatMap { current in prompts.contains { $0.id == current.id } ? nil : current }
        var parts = prompts.map { prompt -> Part in
            let own = note?.id == prompt.id ? note : nil
            let color = own.map { $0.warning ? NSColor.systemOrange : NSColor.systemGreen }
            return Part(image: TouchBarArt.card(prompt.text, subtitle: own?.text ?? "", width: promptWidth(prompt.text), color: color),
                        action: .prompt(prompt.id), id: "prompt:" + prompt.id)
        }
        parts.append(Part(image: TouchBarArt.card("编辑…", subtitle: orphan?.text ?? "在菜单栏里改", width: promptEditWidth,
                                                  color: orphan.map { $0.warning ? NSColor.systemOrange : NSColor.systemGreen }),
                          action: .editPrompts, id: "prompts:edit"))
        return parts
    }
}

struct PromptSection: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var edits: [String: String] = [:]
    @State private var lastFocused: String?
    @State private var expanded = false
    @FocusState private var focused: String?

    var body: some View {
        let items = model.promptStore.items
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("常用指令").font(.system(size: 13, weight: .bold))
                Text("\(items.count)/\(PromptStore.limit)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Claude/Codex 在前台时自动显示", isOn: Binding(get: { model.promptStore.autoShow }, set: { model.setPromptAutoShow($0) }))
                    .toggleStyle(.checkbox).font(.system(size: 10.5))
                Button(expanded ? "收起" : "编辑") { if expanded { commitAll() }; expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if !expanded {
                Text(items.prefix(3).map(\.text).joined(separator: " · ") + (items.count > 3 ? " 等 \(items.count) 条" : ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if expanded {
                Text("在触控栏上点一下，就把这句话复制到剪贴板（替换原来的内容）；你按 ⌘V 粘贴、回车才会发出去。改完按回车或点别处就保存。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                ForEach(items) { item in
                    HStack(spacing: 5) {
                        TextField("", text: Binding(get: { edits[item.id] ?? item.text }, set: { edits[item.id] = $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                            .focused($focused, equals: item.id)
                            .onSubmit { commit(item.id) }
                        Button("↑") { commitAll(); model.movePrompt(item.id, by: -1) }.disabled(item.id == items.first?.id)
                        Button("↓") { commitAll(); model.movePrompt(item.id, by: 1) }.disabled(item.id == items.last?.id)
                        Button("删除") { edits[item.id] = nil; model.removePrompt(item.id) }
                    }
                    .font(.system(size: 11)).controlSize(.small)
                }
                HStack(spacing: 6) {
                    TextField("新的常用指令，回车添加", text: $draft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                        .onSubmit(add)
                    Button("添加", action: add).disabled(PromptStore.clean(draft).isEmpty)
                }
                .font(.system(size: 11)).controlSize(.small)
            }
            if let note = model.promptNote, note.id.isEmpty {
                Text(note.text).font(.system(size: 10.5)).foregroundStyle(note.warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: focused) { current in
            if let previous = lastFocused, previous != current { commit(previous) }
            lastFocused = current
        }
        .onDisappear { commitAll() }
        .onAppear { openIfRequested() }
        .onChange(of: model.promptEditorRequested) { _ in openIfRequested() }
    }

    private func openIfRequested() {
        guard model.promptEditorRequested else { return }
        model.promptEditorRequested = false
        expanded = true
    }

    private func add() {
        if case .saved = model.editPrompts({ $0.add(draft) }) { draft = "" }
    }

    private func commit(_ id: String) {
        guard let text = edits[id] else { return }
        edits[id] = nil
        if model.promptStore.item(id)?.text == PromptStore.clean(text) { return }
        model.editPrompts { $0.update(id, text: text) }
    }

    private func commitAll() {
        for id in Array(edits.keys) { commit(id) }
    }
}

extension Snapshot {
    static func writePrompts(dir: String) {
        let store = PromptStore()
        touchBar(TouchBarItem.promptImages(store.items, app: "Claude", note: nil).map(\.image), to: "\(dir)/touchbar-prompts.png")
        if let second = store.items.dropFirst().first {
            touchBar(TouchBarItem.promptImages(store.items, app: "Codex", note: PromptNote(id: second.id, text: "已复制，⌘V 粘贴", warning: false)).map(\.image),
                     to: "\(dir)/touchbar-prompts-pasted.png")
        }
    }
}
