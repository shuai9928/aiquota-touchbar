import AppKit

struct AttentionItem {
    enum Kind: Equatable {
        case answer, permission, waiting, error, result
    }

    let session: AgentSession
    let light: Light
    let kind: Kind

    var key: String { session.key }

    var action: String {
        switch kind {
        case .answer: return "回答问题"
        case .permission: return "查看权限请求"
        case .waiting: return "查看任务"
        case .error: return session.errorType == "rate_limit" ? "被限流了" : "查看错误"
        case .result: return "查看结果"
        }
    }

    var destination: String {
        if session.threadURL != nil { return "跳到这条对话" }
        switch session.agent {
        case "codex": return "打开 Codex"
        case "zcode": return "打开 ZCode"
        default: return "打开 Claude app"
        }
    }

    var subtitle: String { action + " · " + destination }
}

enum Attention {
    static func kind(of session: AgentSession, light: Light) -> AttentionItem.Kind? {
        switch light {
        case .waiting:
            switch session.waitReason {
            case "question": return .answer
            case "permission": return .permission
            default: return .waiting
            }
        case .error: return .error
        case .done: return .result
        case .running, .idle: return nil
        }
    }

    static func items(from lights: [TouchBarItem.TaskItem]) -> [AttentionItem] {
        lights.compactMap { entry in
            kind(of: entry.session, light: entry.light).map { AttentionItem(session: entry.session, light: entry.light, kind: $0) }
        }
        .sorted { lhs, rhs in
            if lhs.light.rank != rhs.light.rank { return lhs.light.rank < rhs.light.rank }
            if lhs.session.first != rhs.session.first { return lhs.session.first < rhs.session.first }
            return lhs.key < rhs.key
        }
    }

    static func summary(_ items: [AttentionItem]) -> String {
        let waiting = items.filter { $0.light == .waiting }.count
        let errors = items.filter { $0.light == .error }.count
        let results = items.filter { $0.light == .done }.count
        let parts = [("等你", waiting), ("出错", errors), ("完成", results)].filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "没有要看的" : parts.joined(separator: " · ")
    }

    static func tint(_ items: [AttentionItem]) -> NSColor? {
        items.first.map { $0.light.color }
    }
}

extension AgentSession {
    /// 点一下要打开的深链接：Codex 跳到那条对话；Claude 用桌面 app 的 resume 链接直接打开这条 CLI 会话
    ///（id 是合法 UUID 才有链接；打开时若发现已收编进 app，会换成 code/continue 跳转，见 AppModel.open）
    var threadURL: URL? {
        if agent == "codex", appBundle == "com.openai.codex",
           let thread = SessionHook.codexThreadId(transcript) ?? (UUID(uuidString: id) == nil ? nil : id) {
            return URL(string: "codex://threads/" + thread)
        }
        if agent == "claude", appBundle == "com.anthropic.claudefordesktop", UUID(uuidString: id) != nil {
            return URL(string: "claude://resume?session=" + id)
        }
        return nil
    }
}

extension TouchBarItem {
    static let attentionItemWidth: CGFloat = 176

    static func attentionImages(_ items: [AttentionItem]) -> [Part] {
        guard !items.isEmpty else {
            return [Part(image: TouchBarArt.card("没有待处理", subtitle: "等你回答或批准、出错、刚完成还没看的任务会出现在这里", width: 330),
                         action: .none, id: "attention:empty")]
        }
        var parts = items.map { item in
            Part(image: TouchBarArt.card(item.session.displayTitle, subtitle: item.subtitle, width: attentionItemWidth, color: item.light.color),
                 action: .session(item.key), id: "attention:" + item.key)
        }
        return parts
    }
}
