import AppKit
import SwiftUI

struct RelaySection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let now = model.now
        let pairs = model.relayPairs(at: now)
        VStack(alignment: .leading, spacing: 7) {
            Text("接力").font(.system(size: 13, weight: .bold))
            ForEach(pairs, id: \.cwd) { pair in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(pair.project).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(pair.summary).font(.system(size: 10.5))
                            .foregroundStyle(pair.tone == .turn ? Color.green : Color.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 7) {
                        ForEach(pair.targets, id: \.self) { agent in
                            button(pair: pair, agent: agent, now: now)
                        }
                        if let note = pair.note {
                            Button("看交接说明") { model.relayCommand(.note(note.file)) }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11)).controlSize(.small)
                }
            }
            Text("「交给」会复制一句交接的话并切到对方，你按 ⌘V 回车才会发出去；交接说明约定放在 \(Relay.folder)/。")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func button(pair: RelayPair, agent: String, now: Date) -> some View {
        let availability = Relay.availability(agent == "codex" ? model.codex.first : model.claude, now: now)
        switch availability {
        case .ready:
            Button("交给 " + Relay.name(agent)) { model.relayCommand(.hand(pair.cwd, agent)) }
        case .exhausted(let reset):
            Button("交给 " + Relay.name(agent) + (reset.map { "（" + Fmt.shortClock($0, now: now) + " 恢复）" } ?? "（额度用完）")) {}
                .disabled(true)
        }
    }
}

extension Snapshot {
    static func demoRelayLights(now: Date) -> [TouchBarItem.TaskItem] {
        let entries: [(agent: String, title: String, state: SessionState, light: Light, minutes: Double, cwd: String)] = [
            ("claude", "笔记应用改版", .done, .done, 3, "/Users/demo/projects/notes-app"),
            ("codex", "笔记应用审查", .idle, .idle, 40, "/Users/demo/projects/notes-app"),
            ("claude", "天气小组件", .running, .running, 1, "/Users/demo/projects/weather-widget"),
            ("codex", "天气小组件审查", .running, .running, 2, "/Users/demo/projects/weather-widget"),
            ("codex", "单独的任务", .waiting, .waiting, 5, "/Users/demo/projects/other"),
        ]
        return entries.enumerated().map { index, entry in
            let moment = now.addingTimeInterval(-entry.minutes * 60)
            let id = entry.agent == "codex" ? "00000000-0000-4000-8000-00000000010\(index)" : "demo-relay-\(index)"
            return (AgentSession(agent: entry.agent, id: id, state: entry.state, since: moment, updated: moment,
                                 first: now.addingTimeInterval(Double(index) * 60 - 3600), title: entry.title, bundle: "", cwd: entry.cwd,
                                 waitReason: entry.state == .waiting ? "question" : ""), entry.light)
        }
    }

    static func writeRelay(dir: String, rows: [Provider], now: Date) {
        let lights = demoRelayLights(now: now)
        let note = HandoffNote(file: Relay.stamp(now) + "-codex-to-claude-weather-widget.md", from: "codex", to: "claude",
                               project: "weather-widget", modified: now)
        let pairs = Relay.pairs(lights: lights, notes: [])
        let glancePairs = TouchBarItem.glancePairs(pairs, lights: lights)
        touchBar([TouchBarArt.glance(rows: rows, lights: lights.map(\.light), now: now, pairs: glancePairs)], to: "\(dir)/touchbar-glance-relay.png")
        touchBar([TouchBarItem.relayCard(pairs).image], to: "\(dir)/touchbar-relay-card.png")
        touchBar(TouchBarItem.relayImages(pairs, claude: rows.first, codex: rows.dropFirst().first, now: now).map(\.image), to: "\(dir)/touchbar-relay.png")
        var tired = rows
        if tired.count > 1 {
            tired[1].windows[0].used = 100
            tired[1].windows[0].resetsAt = now.addingTimeInterval(2 * 3600)
        }
        var finished = lights
        finished[2] = (finished[2].session, .idle)
        finished[3] = (finished[3].session, .idle)
        let noted = Relay.pairs(lights: finished, notes: [note])
        touchBar(TouchBarItem.relayImages(noted, claude: tired.first, codex: tired.dropFirst().first, now: now).map(\.image),
                 to: "\(dir)/touchbar-relay-note.png")
    }
}
