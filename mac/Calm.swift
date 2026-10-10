import AppKit
import SwiftUI

enum CalmState: Equatable {
    case none
    case breath(started: Date, rounds: Int)
    case focus(started: Date, ends: Date)
    case rest(since: Date)

    var active: Bool { self != .none }
}

enum CalmCommand: Equatable {
    case breath, focus, stop
}

enum Breath {
    static let phases: [(name: String, seconds: Double)] = [("吸气", 4), ("屏住", 7), ("呼气", 8)]
    static let rounds = 4
    static var cycle: Double { phases.reduce(0) { $0 + $1.seconds } }
    static var length: Double { cycle * Double(rounds) }

    static func state(at elapsed: Double) -> (name: String, left: Int, level: Double, round: Int) {
        let round = min(rounds, Int(max(0, elapsed) / cycle) + 1)
        var local = max(0, elapsed).truncatingRemainder(dividingBy: cycle)
        for phase in phases {
            if local < phase.seconds {
                let progress = local / phase.seconds
                let eased = 0.5 - 0.5 * cos(progress * .pi)
                let level: Double
                switch phase.name {
                case "吸气": level = eased
                case "呼气": level = 1 - eased
                default: level = 1 - 0.04 * sin(progress * .pi * 6)
                }
                return (phase.name, Int(ceil(phase.seconds - local)), level, round)
            }
            local -= phase.seconds
        }
        return (phases[0].name, Int(phases[0].seconds), 0, round)
    }

    static let teal = NSColor(red: 0.35, green: 0.82, blue: 0.86, alpha: 1)

    static func image(elapsed: Double, width: CGFloat) -> NSImage {
        let current = state(at: elapsed)
        return TouchBarArt.image(width: width) { rect in
            TouchBarArt.pill(rect, NSColor(white: 1, alpha: 0.06))
            let side: CGFloat = 92
            let span = width - side * 2
            let bandWidth = 24 + (span - 24) * CGFloat(current.level)
            let bandHeight = 6 + 10 * CGFloat(current.level)
            let band = NSRect(x: side + (span - bandWidth) / 2, y: (TouchBarArt.height - bandHeight) / 2, width: bandWidth, height: bandHeight)
            let strength = 0.55 + 0.4 * current.level
            let glow = NSGradient(colors: [teal.withAlphaComponent(0), teal.withAlphaComponent(strength), teal.withAlphaComponent(strength), teal.withAlphaComponent(0)],
                                  atLocations: [0, 0.3, 0.7, 1], colorSpace: .sRGB)
            glow?.draw(in: NSBezierPath(roundedRect: band, xRadius: bandHeight / 2, yRadius: bandHeight / 2), angle: 0)
            let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let small = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            (current.name as NSString).draw(at: NSPoint(x: 10, y: 1.5), withAttributes: [.font: title, .foregroundColor: teal])
            ("\(current.left) 秒" as NSString).draw(at: NSPoint(x: 10, y: 16.5), withAttributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])
            let info = "4-7-8 呼吸" as NSString
            let rounds = "第 \(current.round)/\(Breath.rounds) 轮" as NSString
            info.draw(at: NSPoint(x: width - 10 - info.size(withAttributes: [.font: small]).width, y: 3), withAttributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])
            rounds.draw(at: NSPoint(x: width - 10 - rounds.size(withAttributes: [.font: small]).width, y: 16), withAttributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }
}

enum Focus {
    static let length: TimeInterval = 25 * 60
    static let rest: TimeInterval = 5 * 60
    static let lateAt: TimeInterval = 5 * 60

    static func color(remaining: TimeInterval) -> NSColor {
        if remaining <= 0 { return .systemGreen }
        return remaining < lateAt ? .systemOrange : NSColor(white: 1, alpha: 0.8)
    }

    static func clock(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func image(remaining: TimeInterval, total: TimeInterval, width: CGFloat) -> NSImage {
        TouchBarArt.image(width: width) { rect in
            TouchBarArt.pill(rect, NSColor(white: 1, alpha: 0.06))
            let done = remaining <= 0
            let color = self.color(remaining: remaining)
            let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let digits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            let small = NSFont.systemFont(ofSize: 10, weight: .regular)
            ((done ? "休息一下" : "专注") as NSString).draw(at: NSPoint(x: 10, y: 1.5), withAttributes: [.font: title, .foregroundColor: color])
            let clockText = done ? "5 分钟" : clock(remaining)
            (clockText as NSString).draw(at: NSPoint(x: 10, y: 15), withAttributes: [.font: done ? small : digits, .foregroundColor: done ? NSColor.secondaryLabelColor : color])
            let barX: CGFloat = 92, barWidth = width - barX - 110
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: 13, width: barWidth, height: 4), xRadius: 2, yRadius: 2).fill()
            color.setFill()
            let fraction = done ? 1 : CGFloat(max(0, min(1, remaining / total)))
            NSBezierPath(roundedRect: NSRect(x: barX, y: 13, width: max(4, barWidth * fraction), height: 4), xRadius: 2, yRadius: 2).fill()
            let note = (done ? "这一轮做完了" : remaining < lateAt ? "最后 5 分钟" : "番茄钟 25 分钟") as NSString
            note.draw(at: NSPoint(x: width - 10 - note.size(withAttributes: [.font: small]).width, y: 9),
                      withAttributes: [.font: small, .foregroundColor: done ? NSColor.systemGreen : NSColor.secondaryLabelColor])
        }
    }
}

enum SystemTouchBar {
    static let controlStripMode = "appWithControlStrip"

    static func resolve(bundle: String?, global: Any?, perApp: Any?) -> String {
        if let bundle, let table = perApp as? [String: Any], let mode = table[bundle] as? String { return mode }
        return global as? String ?? controlStripMode
    }

    static func mode(for bundle: String?) -> String {
        let domain = "com.apple.touchbar.agent" as CFString
        return resolve(bundle: bundle, global: CFPreferencesCopyAppValue("PresentationModeGlobal" as CFString, domain),
                       perApp: CFPreferencesCopyAppValue("PresentationModePerApp" as CFString, domain))
    }

    static func allowsPresentation(for bundle: String?) -> Bool {
        mode(for: bundle) == controlStripMode
    }
}

struct GlanceFocus: Equatable {
    let fraction: Double
    let color: NSColor
}

extension CalmState {
    func glanceFocus(at now: Date) -> GlanceFocus? {
        switch self {
        case .focus(let started, let ends):
            let total = ends.timeIntervalSince(started)
            let remaining = ends.timeIntervalSince(now)
            return GlanceFocus(fraction: total > 0 ? max(0, min(1, remaining / total)) : 0, color: Focus.color(remaining: remaining))
        case .rest:
            return GlanceFocus(fraction: 1, color: .systemGreen)
        case .none, .breath:
            return nil
        }
    }

    func summary(at now: Date) -> String {
        switch self {
        case .none: return "呼吸 · 专注"
        case .breath(let started, _):
            let current = Breath.state(at: now.timeIntervalSince(started))
            return current.name + " · 第 \(current.round)/\(Breath.rounds) 轮"
        case .focus(_, let ends): return "专注 " + Focus.clock(ends.timeIntervalSince(now))
        case .rest: return "休息一下"
        }
    }
}

extension TouchBarItem {
    static let calmWideWidth: CGFloat = 470

    static func calmImages(_ state: CalmState, now: Date) -> [Part] {
        let stop = Part(image: TouchBarArt.card("停止", width: 64), action: .stopCalm, id: "calm:stop")
        switch state {
        case .none:
            return [
                Part(image: TouchBarArt.card("专注", subtitle: "番茄钟 25 分钟，结束提醒休息", width: 170), action: .startFocus, id: "calm:focus"),
                Part(image: TouchBarArt.card("呼吸", subtitle: "4-7-8 · \(Breath.rounds) 轮 · 约 \(Int((Breath.length / 60).rounded())) 分钟", width: 150, color: Breath.teal),
                     action: .startBreath, id: "calm:breath"),
            ]
        case .breath(let started, _):
            let current = Breath.state(at: now.timeIntervalSince(started))
            return [Part(image: Breath.image(elapsed: now.timeIntervalSince(started), width: calmWideWidth), action: .none, id: "calm:session",
                         label: current.name + "，还有 \(current.left) 秒"), stop]
        case .focus(let started, let ends):
            let remaining = ends.timeIntervalSince(now)
            return [Part(image: Focus.image(remaining: remaining, total: ends.timeIntervalSince(started), width: calmWideWidth), action: .none, id: "calm:session",
                         label: "专注，还剩 " + Focus.clock(remaining)), stop]
        case .rest:
            return [Part(image: Focus.image(remaining: 0, total: 1, width: calmWideWidth), action: .none, id: "calm:session", label: "专注结束，休息一下"),
                    Part(image: TouchBarArt.card("好的", width: 64), action: .stopCalm, id: "calm:stop")]
        }
    }
}

extension AppModel {
    func calmCommand(_ command: CalmCommand) {
        switch command {
        case .breath: startCalm(.breath(started: Date(), rounds: Breath.rounds), until: Date().addingTimeInterval(Breath.length))
        case .focus:
            let started = Date()
            let ends = started.addingTimeInterval(focusLength)
            startCalm(.focus(started: started, ends: ends), until: ends)
            if reminderStatus == .on {
                calmReminder.add(ResetReminder(id: "focus:end", fireAt: ends, title: "专注 25 分钟结束", body: "起来走走，休息 5 分钟。"))
            }
        case .stop:
            stopCalm()
        }
    }

    private func startCalm(_ state: CalmState, until end: Date) {
        calmReminder.remove(ids: ["focus:end"])
        calm = state
        scheduleCalm(at: end)
        now = Date()
        onCalm?()
        onUpdate?()
    }

    /// 排下一次到点；每排一次换一个版本号，之前排的回调作废
    private func scheduleCalm(at end: Date) {
        calmWork?.cancel()
        calmVersion += 1
        let version = calmVersion
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.calmTimerFired(version: version, now: Date()) }
        }
        calmWork = work
        // 按墙上时间：合盖睡着时也在走，醒来已经过点就马上到（和系统通知对得上）
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, end.timeIntervalSince(Date())), execute: work)
    }

    /// 现在这一段什么时候到点
    var calmDue: Date? {
        switch calm {
        case .focus(_, let ends): return ends
        case .rest(let since): return since.addingTimeInterval(restLength)
        case .breath(let started, _): return started.addingTimeInterval(Breath.length)
        case .none: return nil
        }
    }

    func calmTimerFired(version: Int, now: Date) {
        guard version == calmVersion else { return }            // 停过或重新开始过：旧的回调不算
        if let due = calmDue, now < due {
            scheduleCalm(at: due)                                  // 早到了一点：再等
        } else {
            advanceCalm(now: now)
        }
    }

    /// 按现在的时间校正：定时器到点、电脑醒来、已有的 20 秒 tick 都调它。没到点什么也不做，重复调用不会多响。
    /// 睡醒时专注已经过点：马上结束专注，休息从这一刻起 5 分钟；休息也过点了就直接结束
    func advanceCalm(now: Date) {
        guard let due = calmDue, now >= due else { return }
        switch calm {
        case .focus:
            calm = .rest(since: now)
            calmChime()
            scheduleCalm(at: now.addingTimeInterval(restLength))
            onCalm?()
        case .rest, .breath, .none:
            calmWork?.cancel()
            calmWork = nil
            calmVersion += 1
            calm = .none
        }
        self.now = Date()
        onUpdate?()
    }

    /// 电脑醒来：先记下睡着时段的终点（绿灯只算醒着的时间），马上校正番茄钟，再做别的（别等网络）
    func didWake(now: Date) {
        closeAsleepSpan(at: now)
        advanceCalm(now: now)
    }

    func stopCalm() {
        calmWork?.cancel()
        calmWork = nil
        calmVersion += 1
        calmReminder.remove(ids: ["focus:end"])
        calm = .none
        now = Date()
        onUpdate?()
    }
}

struct CalmSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("番茄钟 · 呼吸").font(.system(size: 13, weight: .bold))
                if model.calm.active {
                    Text(model.calm.summary(at: model.now)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("停止") { model.calmCommand(.stop) }
                } else {
                    Spacer()
                    Button("专注 25 分钟") { model.calmCommand(.focus) }
                    Button("呼吸 1 分钟") { model.calmCommand(.breath) }
                }
            }
            Toggle("AI 页显示小猫（看它就知道 AI 在忙什么；点它进小猫的家：番茄钟、呼吸、歌词。关掉后换成「放松」按钮）", isOn: $model.petEnabled)
                .toggleStyle(.checkbox).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Toggle("触控栏左边空位显示工作流路线图（Claude、Codex 或 ZCode 在前台、有任务在跑时自动出现，点系统的 × 关掉这一轮）", isOn: $model.ambientEnabled)
                .toggleStyle(.checkbox).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .font(.system(size: 11)).controlSize(.small)
    }
}

extension Snapshot {
    static func writeCalm(dir: String, rows: [Provider], now: Date) {
        touchBar(TouchBarItem.calmImages(.none, now: now).map(\.image), to: "\(dir)/touchbar-calm.png")
        touchBar(TouchBarItem.calmImages(.breath(started: now.addingTimeInterval(-2), rounds: Breath.rounds), now: now).map(\.image), to: "\(dir)/touchbar-calm-breath.png")
        touchBar(TouchBarItem.calmImages(.focus(started: now.addingTimeInterval(-600), ends: now.addingTimeInterval(900)), now: now).map(\.image), to: "\(dir)/touchbar-calm-focus.png")
        let focusGlance = CalmState.focus(started: now.addingTimeInterval(-600), ends: now.addingTimeInterval(900)).glanceFocus(at: now)
        touchBar([TouchBarArt.glance(rows: rows, lights: [.waiting, .running], now: now, lyric: true, focus: focusGlance)], to: "\(dir)/touchbar-glance-focus.png")
        touchBar(TouchBarItem.aiPage(rows: rows, tasks: [], lights: [], relays: [], watched: [], now: now, link: nil,
                                     pet: TouchBarItem.petChip(.waiting, elapsed: 10)).map(\.image), to: "\(dir)/touchbar-pet-overview.png")
        let poses: [PetPose] = [.running, .waiting, .done, .error, .idle, .focus, .rest, .music, .happy]
        touchBar(poses.map { PetArt.image($0, time: 0, animated: false) }, to: "\(dir)/touchbar-pet.png")
        touchBar(poses.map { PetArt.image($0, time: 0.3, animated: true, home: true) }, to: "\(dir)/touchbar-pet-big.png")
        writePetHome(dir: dir, rows: rows, now: now)
    }
}
