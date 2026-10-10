// 在别的 Mac 上「一打开就复刻」：第一次打开（或面板里点「接入…」）时，把会话灯要用的 hooks 接到 Claude Code / Codex / ZCode，
// 装 tb 命令、开机启动，放好 Chrome 歌词扩展的文件；也能从同一个窗口卸载。
// 规矩（都有测试）：
// - 改别的程序的配置前先备份（同目录 *.bak-aiquota-时间，同一秒再改加 -2、-3，从不删已有的备份）；符号链接的配置改它指向的那个文件；只读的不改。
// - 只动命令里带「AIQuota … --hook <agent>」的条目，别人的 hook 一条不碰；已有的我们的条目**原地改**，不挪位置
//   （Codex 按「事件:组序号:条序号」记信任，挪了位置别人的 hook 就要重新信任、在那之前停跑）。
// - 启动时只修「指向的程序已经不在了」的路径（app 挪了位置）；你删掉的条目、关掉的开关不补回来；另一份拷贝还在就不抢。
// - ZCode 的 hooks 总开关是我们打开的，就记下原来的值，卸载时（没有别的 hook 了）还原；不写全局超时（我们的每条自己带了）。
// - 文件解析不了（被手改坏了）就不写，原样留着并告诉你。

import AppKit

enum Setup {
    enum Agent: String, CaseIterable {
        case claude, codex, zcode
        var name: String { self == .claude ? "Claude Code" : self == .codex ? "Codex" : "ZCode" }
        /// 这个 AI 的配置目录在不在（没装的就不接）
        func installed(home: URL) -> Bool {
            FileManager.default.fileExists(atPath: home.appendingPathComponent(self == .claude ? ".claude" : self == .codex ? ".codex" : ".zcode").path)
        }
        func configURL(home: URL) -> URL {
            switch self {
            case .claude: return home.appendingPathComponent(".claude/settings.json")
            case .codex: return home.appendingPathComponent(".codex/hooks.json")
            case .zcode: return home.appendingPathComponent(".zcode/cli/config.json")
            }
        }
        var displayPath: String {
            switch self {
            case .claude: return "~/.claude/settings.json"
            case .codex: return "~/.codex/hooks.json"
            case .zcode: return "~/.zcode/cli/config.json"
            }
        }
        var hooks: [Hook] { self == .claude ? Setup.claudeHooks : self == .codex ? Setup.codexHooks : Setup.zcodeHooks }
    }

    struct Hook { let event: String; let matcher: String?; let guarded: Bool; let status: String }

    /// 每次工具调用后的那几条先看有没有会话在等你（.any-waiting），没有就不启动这个程序
    static let claudeHooks: [Hook] = [
        Hook(event: "UserPromptSubmit", matcher: nil, guarded: false, status: ""),
        Hook(event: "PreToolUse", matcher: "AskUserQuestion", guarded: false, status: ""),
        Hook(event: "Notification", matcher: "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input", guarded: false, status: ""),
        Hook(event: "PostToolUse", matcher: nil, guarded: true, status: ""),
        Hook(event: "PostToolUseFailure", matcher: nil, guarded: true, status: ""),
        Hook(event: "Stop", matcher: nil, guarded: false, status: ""),
        Hook(event: "StopFailure", matcher: nil, guarded: false, status: ""),
        Hook(event: "SessionEnd", matcher: nil, guarded: false, status: ""),
    ]
    static let codexHooks: [Hook] = [
        Hook(event: "UserPromptSubmit", matcher: nil, guarded: false, status: ""),
        Hook(event: "PermissionRequest", matcher: nil, guarded: false, status: ""),
        Hook(event: "PostToolUse", matcher: nil, guarded: true, status: ""),
        Hook(event: "Stop", matcher: nil, guarded: false, status: ""),
        Hook(event: "Interrupt", matcher: nil, guarded: false, status: ""),
        Hook(event: "SessionEnd", matcher: nil, guarded: false, status: ""),
    ]
    static let zcodeHooks: [Hook] = [
        Hook(event: "UserPromptSubmit", matcher: nil, guarded: false, status: "通知触控栏：开始干活"),
        Hook(event: "PreToolUse", matcher: "AskUserQuestion", guarded: false, status: "通知触控栏：在等你回答"),
        Hook(event: "PermissionRequest", matcher: nil, guarded: false, status: "通知触控栏：在等你批准"),
        Hook(event: "PostToolUse", matcher: nil, guarded: false, status: "通知触控栏：接着干"),
        Hook(event: "PostToolUseFailure", matcher: nil, guarded: false, status: "通知触控栏：接着干"),
        Hook(event: "Stop", matcher: nil, guarded: false, status: "通知触控栏：干完了"),
    ]

    static func shellQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`") + "\""
    }

    static func command(_ hook: Hook, agent: Agent, exe: String, dataDir: String) -> String {
        let call = shellQuote(exe) + " --hook " + agent.rawValue + " 2>/dev/null; exit 0"
        return hook.guarded ? "[ -e " + shellQuote(dataDir + "/sessions/.any-waiting") + " ] && " + call : call
    }

    /// 一条我们的 hook 该长什么样
    static func entry(_ hook: Hook, agent: Agent, exe: String, dataDir: String) -> [String: Any] {
        agent == .zcode
            ? ["type": "process", "command": exe, "args": ["--hook", "zcode"], "timeoutMs": 10000, "statusMessage": hook.status]
            : ["type": "command", "command": command(hook, agent: agent, exe: exe, dataDir: dataDir), "timeout": 5]
    }

    /// 这条 hook 是不是我们的：Claude / Codex 看命令里有没有「AIQuota」和「--hook <agent>」；ZCode 看命令是 AIQuota、参数是 --hook zcode
    static func isOurs(_ hook: Any, agent: Agent) -> Bool {
        guard let h = hook as? [String: Any], let command = h["command"] as? String else { return false }
        if agent == .zcode { return command.contains("AIQuota") && (h["args"] as? [String] ?? []) == ["--hook", "zcode"] }
        return command.contains("AIQuota") && command.contains("--hook " + agent.rawValue)
    }

    /// 我们的条目指向哪个程序（命令里「--hook」前面那段引号里的路径；ZCode 就是 command）
    static func target(of hook: Any, agent: Agent) -> String? {
        guard let h = hook as? [String: Any], let command = h["command"] as? String else { return nil }
        if agent == .zcode { return command }
        guard let end = command.range(of: "\" --hook " + agent.rawValue) else { return nil }
        let before = Array(command[..<end.lowerBound])
        var i = before.count - 1
        while i >= 0 {
            if before[i] == "\"" {
                var slashes = 0, j = i - 1
                while j >= 0 && before[j] == "\\" { slashes += 1; j -= 1 }
                if slashes % 2 == 0 { break }
            }
            i -= 1
        }
        guard i >= 0 else { return nil }
        var out = "", escaped = false
        for c in before[(i + 1)...] {
            if escaped { out.append(c); escaped = false } else if c == "\\" { escaped = true } else { out.append(c) }
        }
        return out
    }

    static func events(of config: [String: Any], agent: Agent) -> [String: Any] {
        agent == .zcode ? ((config["hooks"] as? [String: Any])?["events"] as? [String: Any] ?? [:]) : (config["hooks"] as? [String: Any] ?? [:])
    }

    static func withEvents(_ config: [String: Any], agent: Agent, _ events: [String: Any]) -> [String: Any] {
        var config = config
        if agent == .zcode {
            var hooks = config["hooks"] as? [String: Any] ?? [:]
            hooks["events"] = events
            config["hooks"] = hooks
        } else {
            config["hooks"] = events
        }
        return config
    }

    /// 把每条 hook 交给 body（事件、组序号、条序号、内容），body 返回新的内容（nil = 去掉这条）；因此空了的组去掉
    static func mapHooks(_ events: [String: Any], _ body: (String, Int, Int, Any) -> Any?) -> [String: Any] {
        var out = events
        for (event, value) in events {
            guard let groups = value as? [Any] else { continue }
            var kept: [Any] = []
            for (gi, group) in groups.enumerated() {
                guard var g = group as? [String: Any], let hooks = g["hooks"] as? [Any] else { kept.append(group); continue }
                let next = hooks.enumerated().compactMap { body(event, gi, $0.offset, $0.element) }
                if next.isEmpty && !hooks.isEmpty { continue }
                g["hooks"] = next
                kept.append(g)
            }
            out[event] = kept
        }
        return out
    }

    /// 接上：已有的我们的条目原地改成现在该有的样子（保留你在它上面加的别的字段）；同一事件里重复的去掉；缺的事件接在末尾；
    /// 不在清单里的事件上的我们的条目去掉。ZCode 打开 hooks 总开关
    static func installed(_ config: [String: Any], agent: Agent, exe: String, dataDir: String) -> [String: Any] {
        let wanted = Dictionary(agent.hooks.map { ($0.event, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        let before = events(of: config, agent: agent)
        var events = mapHooks(before) { event, _, _, hook in
            guard isOurs(hook, agent: agent) else { return hook }
            guard let spec = wanted[event], !seen.contains(event), let h = hook as? [String: Any] else { return nil }
            seen.insert(event)
            return h.merging(entry(spec, agent: agent, exe: exe, dataDir: dataDir)) { _, new in new }
        }
        events = droppingEmptied(events, before: before)
        for spec in agent.hooks where !seen.contains(spec.event) {
            var group: [String: Any] = ["hooks": [entry(spec, agent: agent, exe: exe, dataDir: dataDir)]]
            if let m = spec.matcher { group["matcher"] = m }
            events[spec.event] = (events[spec.event] as? [Any] ?? []) + [group]
        }
        var out = withEvents(config, agent: agent, events)
        if agent == .zcode, var hooks = out["hooks"] as? [String: Any] {
            hooks["enabled"] = true
            out["hooks"] = hooks
        }
        return out
    }

    /// 只修路径：我们的条目里指向的程序已经不在了（exists 返回 false）的，改成指向 exe；不补、不删、不碰开关
    static func retargeted(_ config: [String: Any], agent: Agent, exe: String, exists: (String) -> Bool) -> [String: Any] {
        let events = mapHooks(events(of: config, agent: agent)) { _, _, _, hook in
            guard isOurs(hook, agent: agent), var h = hook as? [String: Any], let old = target(of: hook, agent: agent),
                  old != exe, !exists(old), let command = h["command"] as? String else { return hook }
            h["command"] = agent == .zcode ? exe : command.replacingOccurrences(of: shellQuote(old), with: shellQuote(exe))
            return h
        }
        return withEvents(config, agent: agent, events)
    }

    /// 卸载：去掉我们的条目。shifted = 别人的条目里有几条因此挪了位置（Codex 要重新信任它们）
    static func uninstalled(_ config: [String: Any], agent: Agent) -> (config: [String: Any], shifted: Int) {
        let before = events(of: config, agent: agent)
        var oldSpots: [String: [String]] = [:]                 // 每个事件里别人的条目原来在哪
        _ = mapHooks(before) { event, g, h, hook in
            if !isOurs(hook, agent: agent) { oldSpots[event, default: []].append("\(g):\(h)") }
            return hook
        }
        var events = mapHooks(before) { _, _, _, hook in isOurs(hook, agent: agent) ? nil : hook }
        var newSpots: [String: [String]] = [:]
        _ = mapHooks(events) { event, g, h, hook in newSpots[event, default: []].append("\(g):\(h)"); return hook }
        var shifted = 0
        for (event, spots) in oldSpots { shifted += zip(spots, newSpots[event] ?? []).filter { $0 != $1 }.count }
        events = droppingEmptied(events, before: before)
        var out = withEvents(config, agent: agent, events)
        if agent != .zcode && events.isEmpty { out.removeValue(forKey: "hooks") }
        return (out, shifted)
    }

    /// 因为去掉我们的条目而空了的事件整个去掉（原来就是空的不动）
    static func droppingEmptied(_ events: [String: Any], before: [String: Any]) -> [String: Any] {
        events.filter { event, value in !((value as? [Any])?.isEmpty == true && (before[event] as? [Any])?.isEmpty == false) }
    }

    /// 我们的条目都在、都指向 exe、一个事件一条（ZCode 还要总开关开着）
    static func current(_ config: [String: Any], agent: Agent, exe: String, dataDir: String) -> Bool {
        var found: [String: [String: Any]] = [:]
        var extra = false
        _ = mapHooks(events(of: config, agent: agent)) { event, _, _, hook in
            if isOurs(hook, agent: agent), let h = hook as? [String: Any] {
                if found[event] != nil { extra = true } else { found[event] = h }
            }
            return hook
        }
        guard !extra, Set(found.keys) == Set(agent.hooks.map(\.event)) else { return false }
        if agent == .zcode && (config["hooks"] as? [String: Any])?["enabled"] as? Bool != true { return false }
        return agent.hooks.allSatisfy { spec in
            guard let h = found[spec.event] else { return false }
            return agent == .zcode ? h["command"] as? String == exe : h["command"] as? String == command(spec, agent: agent, exe: exe, dataDir: dataDir)
        }
    }

    /// 配置里有没有我们的条目（不管指向哪）
    static func present(_ config: [String: Any], agent: Agent) -> Bool {
        var any = false
        _ = mapHooks(events(of: config, agent: agent)) { _, _, _, hook in
            if isOurs(hook, agent: agent) { any = true }
            return hook
        }
        return any
    }

    // MARK: 读写文件

    enum Outcome: Equatable {
        case written(backup: String?, note: String?)   // 改了（原来有文件的话先备份到这里）；note：要告诉你的事
        case unchanged
        case unreadable(String)                        // 解析不了 / 只读 / 写不进：原样留着
    }

    enum Mode { case install, uninstall, retarget }

    static func read(_ url: URL) -> (config: [String: Any]?, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], nil) }
        guard let data = try? Data(contentsOf: url) else { return (nil, "读不了") }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return ([:], nil) }
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else { return (nil, "不是合法的 JSON 对象") }
        return (dict, nil)
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// 备份文件名：同一秒里已经有了就加 -2、-3……，从不覆盖已有的备份
    static func backupPath(for path: String, now: Date) -> String {
        let base = path + ".bak-aiquota-" + stamp(now)
        var candidate = base, n = 2
        while FileManager.default.fileExists(atPath: candidate) { candidate = base + "-\(n)"; n += 1 }
        return candidate
    }

    static func zcodeMarker(dataDir: String) -> URL { URL(fileURLWithPath: dataDir).appendingPathComponent("zcode-hooks-enabled-before") }
    static let zcodeRestored = "ZCode 的 hooks 总开关还原成原来的样子"

    /// 接上 / 去掉 / 只修路径（一个 AI）
    @discardableResult
    static func apply(_ agent: Agent, home: URL, exe: String, dataDir: String, mode: Mode = .install, now: Date = Date(),
                      exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Outcome {
        let fm = FileManager.default
        let url = agent.configURL(home: home).resolvingSymlinksInPath()   // 符号链接（dotfiles）：改它指向的那个文件
        let fileThere = fm.fileExists(atPath: url.path)
        if mode != .install && !fileThere { return .unchanged }          // 卸载、修路径不新建文件
        let (config, error) = read(url)
        guard let config else { return .unreadable(error ?? "读不了") }
        var note: String?
        let next: [String: Any]
        switch mode {
        case .install:
            next = installed(config, agent: agent, exe: exe, dataDir: dataDir)
            if agent == .zcode, (config["hooks"] as? [String: Any])?["enabled"] as? Bool != true {
                note = "打开了 ZCode 的 hooks 总开关（你别的 ZCode hook 也会开始运行；卸载时还原）"
            }
        case .uninstall:
            guard present(config, agent: agent) else { return .unchanged }
            let result = uninstalled(config, agent: agent)
            var out = result.config
            if agent == .codex && result.shifted > 0 { note = "Codex 里你别的 \(result.shifted) 条 hook 位置挪了，要在 Codex 设置 → Hooks 里重新信任" }
            if agent == .zcode, let previous = try? String(contentsOf: zcodeMarker(dataDir: dataDir), encoding: .utf8),
               var hooks = out["hooks"] as? [String: Any], (hooks["events"] as? [String: Any] ?? [:]).isEmpty {
                if previous == "absent" { hooks.removeValue(forKey: "enabled") } else { hooks["enabled"] = false }
                out["hooks"] = hooks
                note = zcodeRestored
            }
            next = out
        case .retarget:
            next = retargeted(config, agent: agent, exe: exe, exists: exists)
        }
        if NSDictionary(dictionary: next).isEqual(to: config) { return .unchanged }
        if fileThere && !fm.isWritableFile(atPath: url.path) { return .unreadable("是只读的，没改") }
        guard let data = try? JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return .unreadable("写不出 JSON")
        }
        var backup: String?
        if fileThere {
            let copy = backupPath(for: url.path, now: now)
            guard let original = try? Data(contentsOf: url), (try? original.write(to: URL(fileURLWithPath: copy))) != nil else { return .unreadable("备份失败，没改") }
            backup = copy
        }
        // ZCode 的总开关是我们打开的：记下原来的值（只记第一次），卸载时还原
        if mode == .install, agent == .zcode, note != nil, !fm.fileExists(atPath: zcodeMarker(dataDir: dataDir).path) {
            let previous = (config["hooks"] as? [String: Any])?["enabled"] == nil ? "absent" : "false"
            try? fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            try? Data(previous.utf8).write(to: zcodeMarker(dataDir: dataDir))
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        } catch {
            return .unreadable("写不进去：" + error.localizedDescription)
        }
        if mode == .uninstall && note == zcodeRestored { try? fm.removeItem(at: zcodeMarker(dataDir: dataDir)) }
        return .written(backup: backup, note: note)
    }

    // MARK: tb 命令、Chrome 扩展

    static func tbScript(exe: String) -> String {
        """
        #!/bin/sh
        # AIQuota 的 tb：在触控栏上点灯
        APP=\(shellQuote(exe))
        if [ -x "$APP" ]; then exec "$APP" --tb "$@"; fi
        if [ "$1" = "run" ]; then
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                    --keep) shift ;;
                    --name) shift; [ $# -gt 0 ] && shift ;;
                    --) shift; break ;;
                    *) break ;;
                esac
            done
            exec "$@"
        fi
        exit 0

        """
    }

    /// 是不是我们装的 tb：除了 APP= 那一行，每行都和我们写的一样（只看「有没有 AIQuota 字样」会误伤你自己的脚本）
    static func isOurTB(_ text: String) -> Bool {
        func normalized(_ s: String) -> [String] {
            s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("APP=") }
        }
        return normalized(text) == normalized(tbScript(exe: "/x"))
    }

    static func tbURL(home: URL) -> URL { home.appendingPathComponent(".local/bin/tb") }

    /// 我们装的 tb 在不在（符号链接一律当成别人的）
    static func ourTB(home: URL) -> Bool {
        let url = tbURL(home: home)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return isOurTB(text)
    }

    /// 装 ~/.local/bin/tb：没有别的 tb，或者那个就是我们装的，才写
    static func installTB(home: URL, exe: String) -> Bool {
        let url = tbURL(home: home)
        let fm = FileManager.default
        let taken = fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
        if taken && !ourTB(home: home) { return false }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(tbScript(exe: exe).utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }

    static func removeTB(home: URL) { if ourTB(home: home) { try? FileManager.default.removeItem(at: tbURL(home: home)) } }

    /// ~/.local/bin 在不在你终端的 PATH 里：看 shell 的配置文件里提没提到它（不启动 shell，免得执行你的配置）
    static func tbOnPath(home: URL) -> Bool {
        for name in [".zshrc", ".zprofile", ".zshenv", ".bash_profile", ".bashrc", ".profile", ".config/fish/config.fish"] {
            if let text = try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8), text.contains(".local/bin") { return true }
        }
        return false
    }

    static var chromeInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil }

    /// Chrome 歌词扩展：app 里带着一份（Contents/Resources/ChromeExtension），放到固定位置给 Chrome 加载
    static func installExtension(dataDir: URL) -> URL? {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension"),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else { return nil }
        let target = dataDir.appendingPathComponent("ChromeExtension")
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        return (try? fm.copyItem(at: source, to: target)) != nil ? target : nil
    }

    // MARK: 在哪运行、数据放哪

    /// 直接在 DMG 里、或者被系统「随机化路径」（App Translocation）打开时不能接 hooks：路径是临时的，下次就找不到了
    static func unstableLocation(_ bundlePath: String) -> String? {
        if bundlePath.contains("/AppTranslocation/") { return "app 被系统放在临时位置运行（从下载的地方或安装盘里直接打开会这样）" }
        if bundlePath.hasPrefix("/Volumes/") { return "app 还在安装盘（DMG）里" }
        if bundlePath.hasSuffix("/build/AIQuota.app") { return "这是编译目录里的那份（装好的在「应用程序」里）" }
        return nil
    }

    /// 设了 AIQUOTA_SETUP_HOME 时，home 和数据目录都在那下面（拿来试安装、卸载，不碰真的）
    static var overrideHome: URL? {
        #if AIQUOTA_TEST
        if let h = ProcessInfo.processInfo.environment["AIQUOTA_TEST_HOME"], !h.isEmpty { return URL(fileURLWithPath: h).appendingPathComponent("home") }
        #endif
        if let h = ProcessInfo.processInfo.environment["AIQUOTA_SETUP_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return nil
    }
    static var home: URL { overrideHome ?? FileManager.default.homeDirectoryForCurrentUser }
    static var dataURL: URL {
        #if AIQUOTA_TEST
        return AppConfig.dir
        #else
        return overrideHome.map { $0.appendingPathComponent("Library/Application Support/AIQuota") } ?? AppConfig.dir
        #endif
    }
    static var dataDir: String { dataURL.path }
    static var exe: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    // MARK: 设置过什么（数据目录里的 setup.json）

    /// offered：上次问过的 AI（之后新装了别的 AI 再问一次）
    static var stateURL: URL { dataURL.appendingPathComponent("setup.json") }

    static func loadOffered() -> Set<Agent>? {
        if let data = try? Data(contentsOf: stateURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return Set((object["offered"] as? [String] ?? []).compactMap(Agent.init(rawValue:)))
        }
        if FileManager.default.fileExists(atPath: dataURL.appendingPathComponent("setup-done").path) {   // 早一版的标记
            return Set(Agent.allCases.filter { $0.installed(home: home) })
        }
        return nil
    }

    static func saveOffered(_ agents: Set<Agent>) {
        try? FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        let object: [String: Any] = ["offered": agents.map(\.rawValue).sorted(), "at": stamp(Date())]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: stateURL) }
    }

    // MARK: 启动时

    /// 设置窗口里改了开机启动等之后，让面板刷新（AppDelegate 接上）
    nonisolated(unsafe) static var onChanged: (() -> Void)?

    /// app 挪了位置：把指向「已经不在了的程序」的条目改到这里；返回改了哪几个
    static func repairPaths(home: URL = home) -> [Agent] {
        var fixed: [Agent] = []
        for agent in Agent.allCases {
            if case .written = apply(agent, home: home, exe: exe, dataDir: dataDir, mode: .retarget) { fixed.append(agent) }
        }
        LoginItem.retarget()
        return fixed
    }

    /// 启动时调：第一次打开弹设置窗口；之后只在新装了别的 AI 时再问；已经全接好的机器（比如开发机）不打扰
    @MainActor
    static func onLaunch() {
        guard unstableLocation(Bundle.main.bundlePath) == nil else {
            if loadOffered() == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { presentDialog(firstRun: true) } }
            return
        }
        let fixed = repairPaths()
        if fixed.contains(.codex) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let alert = NSAlert()
                alert.messageText = "AIQuota 换了位置，会话灯已改好"
                alert.informativeText = "Codex 要重新信任一次（它的 hooks 改了路径）：Codex 设置 → Hooks → 找到 6 条「AIQuota --hook codex」→ Trust。"
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        let h = home
        let installed = Set(Agent.allCases.filter { $0.installed(home: h) })
        let present = Set(installed.filter { agent in read(agent.configURL(home: h)).config.map { self.present($0, agent: agent) } ?? false })
        if let offered = loadOffered() {
            if !installed.subtracting(offered).subtracting(present).isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { presentDialog(firstRun: false) }
            }
            return
        }
        let allCurrent = !installed.isEmpty && installed.allSatisfy { agent in
            read(agent.configURL(home: h)).config.map { current($0, agent: agent, exe: exe, dataDir: dataDir) } ?? false
        }
        if allCurrent { saveOffered(installed); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { presentDialog(firstRun: true) }
    }

    // MARK: 设置窗口

    struct Choice { var agents: Set<Agent>; var tb: Bool; var login: Bool; var chrome: Bool }

    @MainActor
    static func presentDialog(firstRun: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        if let reason = unstableLocation(Bundle.main.bundlePath) {
            let alert = NSAlert()
            alert.messageText = "先把 AIQuota 拖进「应用程序」"
            alert.informativeText = reason + "。会话灯要在配置里记下 app 的位置，临时位置下次就找不到了。\n\n点下面的按钮：打开「应用程序」文件夹、退出这一份；把 AIQuota 拖进去，再从那里打开，就会弹出设置。"
            alert.addButton(withTitle: "打开「应用程序」并退出")
            alert.addButton(withTitle: "先这样用（不接会话灯）")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                NSApp.terminate(nil)
            }
            return
        }
        let h = home
        let offered = loadOffered() ?? []
        let alert = NSAlert()
        alert.messageText = firstRun ? "欢迎使用 AIQuota" : "接入 AI 和触控栏"
        alert.informativeText = "勾上的接上，取消勾的去掉。改配置前会先备份（同目录 .bak-aiquota-时间），只动 AIQuota 自己的条目，别的不碰。以后在菜单栏面板里点「接入…」还能改。"
        var boxes: [(NSButton, String)] = []
        func box(_ title: String, _ key: String, on: Bool, enabled: Bool = true) {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = on && enabled ? .on : .off
            b.isEnabled = enabled
            boxes.append((b, key))
        }
        for agent in Agent.allCases {
            let there = agent.installed(home: h)
            let isPresent = read(agent.configURL(home: h)).config.map { present($0, agent: agent) } ?? false
            // 第一次、或者这个 AI 是新装的（没问过）：默认勾上；问过的按现在接没接
            let on = isPresent || (there && (firstRun || !offered.contains(agent)))
            box(there ? "\(agent.name) 会话灯（改 \(agent.displayPath)）" : "\(agent.name) 会话灯（没找到 \(agent.name)）", agent.rawValue, on: on, enabled: there)
        }
        box("tb 命令（~/.local/bin/tb，给任何命令点一盏灯）", "tb", on: firstRun || ourTB(home: h))
        box("开机启动", "login", on: firstRun || LoginItem.isEnabled)
        let chrome = chromeInstalled
        box(chrome ? "Chrome 歌词扩展（放好文件，带你去加载）" : "Chrome 歌词扩展（没找到 Chrome）", "chrome", on: false, enabled: chrome)
        let stack = NSStackView(views: boxes.map(\.0))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let width = max(380, boxes.map { ceil($0.0.fittingSize.width) }.max() ?? 380)
        stack.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(boxes.count) * 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: "设置")
        alert.addButton(withTitle: "以后再说")
        alert.addButton(withTitle: "卸载 AIQuota…")
        let answer = alert.runModal()
        saveOffered(Set(Agent.allCases.filter { $0.installed(home: h) }))
        if answer == .alertThirdButtonReturn { confirmUninstall(); return }
        guard answer == .alertFirstButtonReturn else { return }
        var choice = Choice(agents: [], tb: false, login: false, chrome: false)
        for (button, key) in boxes where button.state == .on {
            if let agent = Agent(rawValue: key) { choice.agents.insert(agent) }
            if key == "tb" { choice.tb = true }
            if key == "login" { choice.login = true }
            if key == "chrome" { choice.chrome = true }
        }
        let report = run(choice, home: h)
        onChanged?()
        let done = NSAlert()
        done.messageText = "设置好了"
        done.informativeText = report
        done.addButton(withTitle: "好")
        done.runModal()
    }

    static func describe(_ outcome: Outcome, agent: Agent, installing: Bool) -> String? {
        switch outcome {
        case .written(let backup, let note):
            let verb = installing ? "✓ \(agent.name) 会话灯已接上" : "· \(agent.name) 会话灯已去掉"
            return verb + (backup.map { "（原文件备份在 " + ($0 as NSString).lastPathComponent + "）" } ?? "") + (note.map { "\n  " + $0 } ?? "")
        case .unchanged: return installing ? "✓ \(agent.name) 会话灯本来就接着" : nil
        case .unreadable(let why): return "✗ \(agent.name)：\(agent.displayPath) \(why)，没有改它"
        }
    }

    /// 按选择做：勾上的接上，取消勾的（原来接着的）去掉；返回一段给人看的结果
    @MainActor
    static func run(_ choice: Choice, home: URL) -> String {
        var lines: [String] = []
        for agent in Agent.allCases where agent.installed(home: home) {
            let on = choice.agents.contains(agent)
            let outcome = apply(agent, home: home, exe: exe, dataDir: dataDir, mode: on ? .install : .uninstall)
            if let line = describe(outcome, agent: agent, installing: on) { lines.append(line) }
            if on, agent == .codex, case .written = outcome { lines.append("· Codex 要你点一次信任：Codex 设置 → Hooks → 找到 6 条「AIQuota --hook codex」→ Trust") }
        }
        if !choice.agents.isEmpty { lines.append("· 已经开着的 AI 会话要新开一个才会亮灯") }
        if choice.tb {
            if installTB(home: home, exe: exe) {
                lines.append("✓ tb 命令装好了（~/.local/bin/tb）")
                if !tbOnPath(home: home) {
                    lines.append("· 要在终端里直接用 tb，先把 ~/.local/bin 加进 PATH：\n  echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc，再开一个新的终端窗口")
                }
            } else {
                lines.append("· ~/.local/bin/tb 是别的程序，没动它")
            }
        } else if ourTB(home: home) {
            removeTB(home: home)
            lines.append("· tb 命令已去掉")
        }
        if choice.login != LoginItem.isEnabled {
            LoginItem.set(choice.login)
            lines.append(choice.login ? "✓ 开机启动" : "· 取消了开机启动")
        } else if choice.login {
            lines.append("✓ 开机启动")
        }
        if choice.chrome {
            if let folder = installExtension(dataDir: dataURL) {
                lines.append("· Chrome 歌词扩展：在打开的扩展页面右上角打开「开发者模式」，再把 Finder 里选中的 ChromeExtension 文件夹拖到扩展页面上")
                NSWorkspace.shared.activateFileViewerSelecting([folder])
                if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"), let page = URL(string: "chrome://extensions") {
                    NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
                }
            } else {
                lines.append("✗ 这份 app 里没带 Chrome 扩展")
            }
        }
        lines.append("· 触控栏：系统设置 → 键盘 → 触控栏设置里要打开「显示 Control Strip」，额度小图标在它左边")
        return lines.joined(separator: "\n")
    }

    // MARK: 卸载

    @MainActor
    static func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "卸载 AIQuota？"
        alert.informativeText = "会去掉 Claude Code / Codex / ZCode 配置里 AIQuota 的条目（先备份）、AIQuota 装的 tb 命令、开机启动，然后把 AIQuota 移到废纸篓并退出。"
        let purge = NSButton(checkboxWithTitle: "也删掉 AIQuota 的数据（设置、常用指令、会话状态）", target: nil, action: nil)
        purge.state = .off
        alert.accessoryView = purge
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let result = uninstall(home: home, purge: purge.state == .on)
        let done = NSAlert()
        if result.ok {
            done.messageText = "卸载好了"
            done.informativeText = (result.lines.isEmpty ? ["没有要去掉的配置"] : result.lines).joined(separator: "\n") + "\n\nAIQuota 会移到废纸篓。"
            done.addButton(withTitle: "退出")
            done.runModal()
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else {
            done.messageText = "有些没去掉"
            done.informativeText = result.lines.joined(separator: "\n") + "\n\nAIQuota 留着没删，处理好上面的文件后再卸载一次。"
            done.addButton(withTitle: "好")
            done.runModal()
        }
    }

    /// 去掉三个 AI 里我们的 hooks、我们的 tb、开机启动、歌词桥；purge 再删数据目录。ok=false：有配置文件改不了（里面可能还留着我们的条目）
    static func uninstall(home: URL, purge: Bool) -> (lines: [String], ok: Bool) {
        var lines: [String] = []
        var ok = true
        for agent in Agent.allCases {
            let outcome = apply(agent, home: home, exe: exe, dataDir: dataDir, mode: .uninstall)
            if case .unreadable = outcome { ok = false }
            if let line = describe(outcome, agent: agent, installing: false) { lines.append(line) }
        }
        if ourTB(home: home) { removeTB(home: home); lines.append("· tb 命令已去掉") }
        if LoginItem.isEnabled { LoginItem.set(false); lines.append("· 取消了开机启动") }
        try? FileManager.default.removeItem(at: home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/local.aiquota.lyrics.json"))
        if ok && purge {
            try? FileManager.default.removeItem(at: dataURL)
            lines.append("· 删除了数据目录（" + dataURL.path.replacingOccurrences(of: home.path, with: "~") + "）")
        } else {
            try? FileManager.default.removeItem(at: stateURL)                     // 重装后会再问一次
            try? FileManager.default.removeItem(at: dataURL.appendingPathComponent("setup-done"))
        }
        return (lines, ok)
    }
}
