import AppKit
import SwiftUI

extension TouchBarItem {
    static let shelfCardWidth: CGFloat = 96

    static func shelfCard(_ shelf: Shelf) -> Part {
        let count = shelf.items.count
        let subtitle = count == 0 ? "空 · 点开添加" : shelf.items.last.map { $0.preview(limit: 12) } ?? ""
        return Part(image: TouchBarArt.card(count == 0 ? "材料架" : "材料架 \(count)/\(Shelf.limit)", subtitle: subtitle, width: shelfCardWidth),
                    action: .shelf, id: "shelf")
    }

    static func shelfImages(_ shelf: Shelf, note: ShelfNote?, clearArmed: Int?) -> [Part] {
        let shelfNote = note?.scope == .shelf ? note : nil
        var parts = [Part(image: TouchBarArt.card("添加当前复制内容", subtitle: shelfNote?.text ?? "只在点这里时读一次剪贴板 · 别放密码",
                                                  width: 190, color: shelfNote?.warning == true ? .systemOrange : nil),
                          action: .shelfAdd, id: "shelf:add")]
        if shelf.items.isEmpty {
            parts.append(Part(image: TouchBarArt.card("还是空的", subtitle: "复制文字或文件后点「添加」，退出 app 就清空", width: 230),
                              action: .none, id: "shelf:empty"))
            return parts
        }
        for item in shelf.items {
            parts.append(Part(image: TouchBarArt.card(item.kindLabel, subtitle: item.preview(limit: 24), width: 150),
                              action: .material(item.id), id: "shelf:item:" + item.id))
        }
        if let count = clearArmed {
            parts.append(Part(image: TouchBarArt.card("再点清空", subtitle: "会移除 \(count) 条", width: 96, color: .systemOrange),
                              action: .shelfClear, id: "shelf:clear"))
        } else {
            parts.append(Part(image: TouchBarArt.card("清空", subtitle: "要点两下", width: 96), action: .shelfClear, id: "shelf:clear"))
        }
        return parts
    }

    static func materialImages(_ item: ShelfItem, note: ShelfNote?) -> [Part] {
        let itemNote = note?.scope == .item(item.id) ? note : nil
        return [
            Part(image: TouchBarArt.card(item.kindLabel, subtitle: item.preview(limit: 60), width: 250),
                 action: .shelfCopy(item.id), id: "material:preview"),
            Part(image: TouchBarArt.card("复制", subtitle: itemNote?.text ?? "放回剪贴板", width: 120,
                                         color: itemNote.map { $0.warning ? NSColor.systemOrange : NSColor.systemGreen }),
                 action: .shelfCopy(item.id), id: "material:copy"),
            Part(image: TouchBarArt.card("移除", subtitle: "只移除这一条", width: 100), action: .shelfRemove(item.id), id: "material:remove"),
        ]
    }
}

struct ShelfSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let items = model.shelf.items
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("材料架").font(.system(size: 13, weight: .bold))
                Text("\(items.count)/\(Shelf.limit)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if !items.isEmpty {
                    Button("清空…") { confirmClear() }
                        .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Text("只在点「添加」时读一次剪贴板，只收文字和文件路径，不存到磁盘，退出 app 就清空。不要添加密码。")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            ForEach(items) { item in
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.preview(limit: 60)).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                        Text(item.kindLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("复制") { model.shelfAction(.copy(item.id)) }
                    Button("移除") { model.shelfAction(.remove(item.id)) }
                }
                .font(.system(size: 11)).controlSize(.small)
            }
            Button("添加当前复制内容") { model.shelfAction(.add) }
                .font(.system(size: 11)).controlSize(.small)
            if let note = model.shelfNote {
                Text(note.text).font(.system(size: 10.5))
                    .foregroundStyle(note.warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func confirmClear() {
        let ids = Set(model.shelf.items.map(\.id))
        let alert = NSAlert()
        alert.messageText = "清空材料架？"
        alert.informativeText = "会移除全部 \(ids.count) 条材料，不能撤销。剪贴板里现在的内容不受影响。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.shelfAction(.clear(ids)) }
    }
}

extension Snapshot {
    static func demoShelf() -> Shelf {
        var shelf = Shelf()
        _ = shelf.add(kind: .text, text: "会议纪要：周三前定下配速条的颜色，周五交第二版设计稿")
        _ = shelf.add(kind: .paths(1), text: "/Users/demo/Desktop/设计稿-第二版.pdf")
        _ = shelf.add(kind: .text, text: "SELECT id, title FROM notes WHERE done = 0 ORDER BY updated DESC;")
        return shelf
    }

    static func demoAttention(now: Date) -> [TouchBarItem.TaskItem] {
        let entries: [(agent: String, title: String, state: SessionState, reason: String, light: Light, minutes: Double)] = [
            ("codex", "文档目录整理", .waiting, "question", .waiting, 2),
            ("claude", "依赖升级", .waiting, "permission", .waiting, 5),
            ("codex", "周报汇总", .error, "", .error, 9),
            ("claude", "图标重绘", .done, "", .done, 4),
        ]
        return entries.enumerated().map { index, entry in
            let moment = now.addingTimeInterval(-entry.minutes * 60)
            let id = entry.agent == "codex" ? "00000000-0000-4000-8000-00000000000\(index)" : "demo-attention-\(index)"
            return (AgentSession(agent: entry.agent, id: id, state: entry.state, since: moment, updated: moment,
                                 first: now.addingTimeInterval(Double(index) * 60 - 3600), title: entry.title, bundle: "",
                                 waitReason: entry.reason), entry.light)
        }
    }

    static func writeAttentionAndShelf(dir: String, rows: [Provider], now: Date) {
        let attention = Attention.items(from: demoAttention(now: now))
        let shelf = demoShelf()
        // AI 页：额度表、最要紧的两张对话（等你、出错的在前）、入口
        touchBar(TouchBarItem.aiPage(rows: rows, tasks: demoAttention(now: now).sorted { $0.light.rank < $1.light.rank }, lights: [], relays: [],
                                     watched: [], now: now, link: nil, pet: TouchBarItem.petChip(.waiting, elapsed: 10)).map(\.image),
                 to: "\(dir)/touchbar-overview-cards.png")
        // 工具页：常用指令、材料架、翻译、待处理
        touchBar(TouchBarItem.toolCards(now: now, prompts: 6, shelf: shelf, translation: .idle, attention: attention).map(\.image),
                 to: "\(dir)/touchbar-home-tools.png")
        touchBar(TouchBarItem.attentionImages(attention).map(\.image), to: "\(dir)/touchbar-attention.png")
        touchBar(TouchBarItem.attentionImages([]).map(\.image), to: "\(dir)/touchbar-attention-empty.png")
        touchBar(TouchBarItem.toolCards(now: now, shelf: Shelf(), translation: .idle).map(\.image), to: "\(dir)/touchbar-cards-empty.png")
        touchBar(TouchBarItem.shelfImages(shelf, note: nil, clearArmed: nil).map(\.image), to: "\(dir)/touchbar-shelf.png")
        touchBar(TouchBarItem.shelfImages(shelf, note: ShelfNote(text: ShelfRejection.image.message, scope: .shelf, warning: true), clearArmed: 3).map(\.image),
                 to: "\(dir)/touchbar-shelf-armed.png")
        touchBar(TouchBarItem.shelfImages(Shelf(), note: nil, clearArmed: nil).map(\.image), to: "\(dir)/touchbar-shelf-empty.png")
        if let first = shelf.items.first {
            touchBar(TouchBarItem.materialImages(first, note: ShelfNote(text: "已复制，可以粘贴了", scope: .item(first.id), warning: false)).map(\.image),
                     to: "\(dir)/touchbar-material.png")
        }
    }
}
