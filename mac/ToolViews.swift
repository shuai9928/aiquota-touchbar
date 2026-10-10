import AppKit
import SwiftUI

enum TranslationCommand: Equatable {
    case clipboard, copy, settings
}

extension TouchBarArt {
    static let readingFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    static func reading(_ text: String, width: CGFloat) -> NSImage {
        let line = fit(text, width: width - 16, font: readingFont)
        let lineHeight = ceil(readingFont.ascender - readingFont.descender)
        return image(width: width) { rect in
            pill(rect, NSColor(white: 1, alpha: 0.11))
            (line as NSString).draw(at: NSPoint(x: 8, y: (height - lineHeight) / 2),
                                    withAttributes: [.font: readingFont, .foregroundColor: NSColor.labelColor])
        }
    }

    static let readingMaxWidth: CGFloat = 460

    static func readingWidth(_ text: String) -> CGFloat {
        min(readingMaxWidth, max(80, ceil((text as NSString).size(withAttributes: [.font: readingFont]).width) + 18))
    }

    static func readingFits(_ text: String) -> Bool {
        ceil((text as NSString).size(withAttributes: [.font: readingFont]).width) + 18 <= readingMaxWidth
    }

    static func readingPieces(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        for piece in TranslateText.chunks(text, limit: limit) {
            var pending = [piece]
            while let first = pending.first {
                pending.removeFirst()
                if readingFits(first) || first.count < 2 {
                    out.append(first)
                } else {
                    let halves = TranslateText.split(first, limit: max(1, first.count / 2))
                    pending.insert(contentsOf: halves.count > 1 ? halves : [String(first.prefix(first.count / 2)), String(first.dropFirst(first.count / 2))], at: 0)
                }
            }
        }
        return out
    }
}

extension TouchBarItem {
    static let translateCardWidth: CGFloat = 96

    static func translateCard(_ state: TranslationState) -> Part {
        let subtitle: String
        var color: NSColor?
        switch state {
        case .idle: subtitle = "选中文字 → 服务"
        case .working: subtitle = "翻译中…"
        case .done(let result): subtitle = TranslateText.name(result.from) + "→" + TranslateText.name(result.to) + " " + TranslateText.flat(result.text)
        case .failed: subtitle = "没翻成"; color = .systemOrange
        }
        return Part(image: TouchBarArt.card("翻译", subtitle: subtitle, width: translateCardWidth, color: color), action: .translation, id: "translate")
    }

    static func translationImages(_ state: TranslationState) -> [Part] {
        let clipboard = Part(image: TouchBarArt.card("翻译剪贴板", subtitle: "只在点时读一次", width: 104), action: .translateClipboard, id: "translate:clipboard")
        switch state {
        case .idle:
            return [clipboard,
                    Part(image: TouchBarArt.card("怎么翻译选中的文字", subtitle: "选中后右键 → 服务 → 在触控栏上翻译（可在系统设置里配快捷键）", width: 330),
                         action: .none, id: "translate:help")]
        case .working(let source):
            return [Part(image: TouchBarArt.card("翻译中…", subtitle: TranslateText.flat(source), width: 300), action: .none, id: "translate:head",
                         label: "翻译中：" + source), clipboard]
        case .failed(let message, let download):
            let short = download ? "要先在系统设置里下载翻译语言" : message
            var parts = [Part(image: TouchBarArt.card("没翻成", subtitle: short, width: 330, color: .systemOrange), action: .none, id: "translate:head",
                              label: "没翻成：" + message)]
            if download {
                parts.append(Part(image: TouchBarArt.card("打开设置", subtitle: "下载翻译语言", width: 96), action: .translationSettings, id: "translate:settings"))
            }
            parts.append(clipboard)
            return parts
        case .done(let result):
            let limit = result.to.hasPrefix("zh") ? 30 : 56
            let direction = TranslateText.name(result.from) + " → " + TranslateText.name(result.to)
            var parts = [Part(image: TouchBarArt.card(direction, subtitle: result.truncated ? "只翻了前 \(TranslateText.maxLength) 字" : "原文：" + TranslateText.flat(result.source), width: 120),
                              action: .none, id: "translate:head", label: direction + "，原文：" + result.source)]
            for (index, piece) in TouchBarArt.readingPieces(result.text, limit: limit).enumerated() {
                parts.append(Part(image: TouchBarArt.reading(piece, width: TouchBarArt.readingWidth(piece)), action: .none, id: "translate:piece:\(index)", label: piece))
            }
            parts.append(Part(image: TouchBarArt.card("复制译文", width: 80), action: .copyTranslation, id: "translate:copy"))
            parts.append(clipboard)
            return parts
        }
    }
}

struct LightSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("灯").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("终端里用 tb run 命令、tb light 名字 颜色").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            ForEach(model.customLights, id: \.name) { light in
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: light.light.color)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(light.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(CustomLights.summary(light, now: model.now)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if light.dismissable {
                        Button("清除") { model.dismissLight(light.name, updated: light.updated) }.font(.system(size: 11)).controlSize(.small)
                    }
                }
            }
        }
    }
}

struct TranslateSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("翻译").font(.system(size: 13, weight: .bold))
                Spacer()
                Button("翻译剪贴板") { model.translateClipboard() }
                if case .done = model.translation { Button("复制译文") { model.copyTranslation() } }
            }
            .font(.system(size: 11)).controlSize(.small)
            switch model.translation {
            case .idle:
                Text("选中任意文字后：右键 → 服务 → 在触控栏上翻译（可以在 系统设置 → 键盘 → 键盘快捷键 → 服务 里配快捷键）。用系统自带的本地翻译，不联网。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            case .working:
                Text("翻译中…").font(.system(size: 11)).foregroundStyle(.secondary)
            case .done(let result):
                Text(result.text).font(.system(size: 11.5)).lineLimit(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message, let download):
                Text(message).font(.system(size: 10.5)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                if download {
                    Button("打开语言与地区设置") { model.openTranslationSettings() }.font(.system(size: 11)).controlSize(.small)
                }
            }
        }
    }
}

extension Snapshot {
    static func writeTools(dir: String, now: Date) {
        let lights = [
            CustomLight(name: "make test", state: .running, progress: 42, started: now.addingTimeInterval(-190), updated: now, pid: getpid()),
            CustomLight(name: "部署 staging", state: .done, started: now.addingTimeInterval(-300), updated: now.addingTimeInterval(-40)),
            CustomLight(name: "docker build", state: .error, started: now.addingTimeInterval(-600), updated: now.addingTimeInterval(-120), code: 2),
        ]
        touchBar(lights.map { TouchBarItem.lightCard($0, now: now, watched: [], width: TouchBarItem.chatCardWidth).image }, to: "\(dir)/touchbar-lights.png")
        touchBar([TouchBarArt.glance(rows: demoRows(now: now), lights: [.running, .waiting] + lights.map(\.light), now: now)], to: "\(dir)/touchbar-glance-lights.png")
        let result = TranslationResult(source: "The quick brown fox jumps over the lazy dog. It was a sunny day in the park.",
                                       text: "敏捷的棕色狐狸跳过了那只懒狗。那天公园里阳光明媚。", from: "en", to: "zh-Hans", truncated: false)
        touchBar(TouchBarItem.translationImages(.done(result)).map(\.image), to: "\(dir)/touchbar-translate.png")
        touchBar(TouchBarItem.translationImages(.failed(TranslateText.message(for: TranslateError.notInstalled(from: "en", to: "zh-Hans")).text, needsDownload: true)).map(\.image),
                 to: "\(dir)/touchbar-translate-missing.png")
        touchBar(TouchBarItem.translationImages(.idle).map(\.image), to: "\(dir)/touchbar-translate-idle.png")
    }
}
