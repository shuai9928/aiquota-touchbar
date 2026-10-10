import AppKit
import NaturalLanguage
import Translation

struct TranslationResult: Equatable {
    let source: String
    let text: String
    let from: String
    let to: String
    let truncated: Bool
}

enum TranslationState: Equatable {
    case idle
    case working(String)
    case done(TranslationResult)
    case failed(String, needsDownload: Bool)
}

enum TranslateError: Error, Equatable {
    case notInstalled(from: String, to: String)
    case unsupported(from: String, to: String)
    case requiresNewerOS
    case other(String)
}

@MainActor
protocol Translator: AnyObject {
    func translate(_ text: String, from: String, to: String) async throws -> String
}

@MainActor
final class SystemTranslator: Translator {
    func translate(_ text: String, from: String, to: String) async throws -> String {
        guard #available(macOS 26.0, *) else { throw TranslateError.requiresNewerOS }
        let source = Locale.Language(identifier: from)
        let target = Locale.Language(identifier: to)
        let availability = LanguageAvailability()
        switch await availability.status(from: source, to: target) {
        case .installed: break
        case .supported: throw TranslateError.notInstalled(from: from, to: to)
        default: throw TranslateError.unsupported(from: from, to: to)
        }
        do {
            let session = TranslationSession(installedSource: source, target: target)
            return try await session.translate(text).targetText
        } catch where TranslationError.notInstalled ~= error {
            throw TranslateError.notInstalled(from: from, to: to)
        } catch {
            throw TranslateError.other(error.localizedDescription)
        }
    }
}

enum TranslateText {
    static let maxLength = 2000
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")

    static func clean(_ text: String) -> (text: String, truncated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return (trimmed, false) }
        return (String(trimmed.prefix(maxLength)), true)
    }

    static func direction(for text: String) -> (from: String, to: String) {
        var han = 0, kana = 0, hangul = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: han += 1
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            default: break
            }
        }
        if kana > 0 && kana * 5 >= han { return ("ja", "zh-Hans") }
        if hangul > 0 && hangul >= han { return ("ko", "zh-Hans") }
        if han > 0 && han * 4 >= han + latin {
            let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
            return (simplified == text ? "zh-Hans" : "zh-Hant", "en")
        }
        guard latin >= 20 else { return ("en", "zh-Hans") }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .french, .german, .spanish, .italian, .portuguese, .dutch]
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 else { return ("en", "zh-Hans") }
        return (best.key.rawValue, "zh-Hans")
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
    }

    static func name(_ code: String) -> String {
        switch code {
        case "zh-Hans": return "中"
        case "zh-Hant": return "繁"
        case "en": return "英"
        case "ja": return "日"
        case "ko": return "韩"
        case "fr": return "法"
        case "de": return "德"
        case "es": return "西"
        default: return code
        }
    }

    static func sentences(_ text: String) -> [String] {
        let characters = Array(text)
        let wide: Set<Character> = ["。", "！", "？", "；", "…"]
        let narrow: Set<Character> = [".", "!", "?", ";"]
        var pieces: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if character.isNewline {
                pieces.append(current)
                current = ""
                continue
            }
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if wide.contains(character) || (narrow.contains(character) && (next == nil || next?.isWhitespace == true)) {
                pieces.append(current)
                current = ""
            }
        }
        pieces.append(current)
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func split(_ piece: String, limit: Int) -> [String] {
        var parts: [String] = []
        var rest = Substring(piece)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: { $0.isWhitespace }).map { rest.index(after: $0) } ?? window.endIndex
            let head = rest[..<cut].trimmingCharacters(in: .whitespaces)
            if head.isEmpty { break }
            parts.append(head)
            rest = rest[cut...].drop(while: { $0.isWhitespace })
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    static func chunks(_ text: String, limit: Int) -> [String] {
        var merged: [String] = []
        for piece in sentences(text).flatMap({ split($0, limit: limit) }) {
            if let last = merged.last, last.count + piece.count + 1 <= limit {
                let joiner = last.last?.isASCII == true && piece.first?.isASCII == true ? " " : ""
                merged[merged.count - 1] = last + joiner + piece
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    static func flat(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func message(for error: Error) -> (text: String, download: Bool) {
        switch error as? TranslateError {
        case .notInstalled(let from, let to)?:
            return ("还没下载翻译语言：系统设置 → 通用 → 语言与地区 → 翻译语言，下载「" + languageName(from) + "」和「" + languageName(to) + "」", true)
        case .unsupported(let from, let to)?:
            return ("系统翻译不支持从「" + languageName(from) + "」译成「" + languageName(to) + "」", false)
        case .requiresNewerOS?:
            return ("划词翻译要 macOS 26 或更新", false)
        case .other(let text)?:
            return ("翻译失败：" + text, false)
        case nil:
            return ("翻译失败：" + error.localizedDescription, false)
        }
    }
}

extension AppModel {
    func translate(_ raw: String) {
        let cleaned = TranslateText.clean(raw)
        guard !cleaned.text.isEmpty else {
            translationRequest += 1
            translation = .failed("没有要翻译的文字", needsDownload: false)
            onTranslate?()
            onUpdate?()
            return
        }
        let direction = TranslateText.direction(for: cleaned.text)
        translationRequest += 1
        let request = translationRequest
        translation = .working(cleaned.text)
        onTranslate?()
        onUpdate?()
        Task { @MainActor in
            do {
                let text = try await translator.translate(cleaned.text, from: direction.from, to: direction.to)
                guard request == translationRequest else { return }
                translation = .done(TranslationResult(source: cleaned.text, text: text, from: direction.from, to: direction.to, truncated: cleaned.truncated))
            } catch {
                guard request == translationRequest else { return }
                let problem = TranslateText.message(for: error)
                translation = .failed(problem.text, needsDownload: problem.download)
            }
            onUpdate?()
        }
    }

    func translateClipboard() {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        if !types.isDisjoint(with: Shelf.sensitiveTypes) {
            failTranslation("剪贴板里是密码管理器标记的保密内容，没有翻译")
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failTranslation("剪贴板里没有文字")
            return
        }
        translate(text)
    }

    private func failTranslation(_ message: String) {
        translationRequest += 1
        translation = .failed(message, needsDownload: false)
        onTranslate?()
        onUpdate?()
    }

    func copyTranslation() {
        guard case .done(let result) = translation else { return }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(result.text, forType: .string)
    }

    func openTranslationSettings() {
        if let url = TranslateText.settingsURL { _ = openURL(url) }
    }
}

@MainActor
final class TranslateService: NSObject {
    weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    @objc(translateOnTouchBar:userData:error:)
    func translateOnTouchBar(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = "没有收到文字" as NSString
            return
        }
        model?.translate(text)
    }
}
