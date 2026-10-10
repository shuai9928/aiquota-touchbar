import Foundation

/// 在别的 Mac 上「一打开就复刻」：接 hooks（Claude Code / Codex / ZCode）的合并、幂等、原地改不挪位置、只修「程序不在了」的路径、
/// 不碰别人的条目、ZCode 总开关记下并还原、备份（不覆盖、符号链接、只读）、坏文件不写、带空格引号的路径真能跑、
/// 只在有人等你时才启动、tb 认得准、卸载（不新建文件、不重写没有我们条目的文件、改不了时报失败）、临时位置不接
enum SetupTests {
    @MainActor
    static func run(check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("aiquota-setup-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        let exe = "/Applications/AIQuota.app/Contents/MacOS/AIQuota"
        let oldExe = "/old/place/AIQuota.app/Contents/MacOS/AIQuota"
        let data = root.appendingPathComponent("data").path
        func hooks(_ c: [String: Any], _ agent: Setup.Agent) -> [[String: Any]] {
            Setup.events(of: c, agent: agent).values.compactMap { $0 as? [Any] }.flatMap { $0 }
                .compactMap { ($0 as? [String: Any])?["hooks"] as? [Any] }.flatMap { $0 }.compactMap { $0 as? [String: Any] }
        }
        func ours(_ c: [String: Any], _ agent: Setup.Agent) -> [[String: Any]] { hooks(c, agent).filter { Setup.isOurs($0, agent: agent) } }
        func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }
        func commands(_ c: [String: Any], _ agent: Setup.Agent, _ event: String) -> [String] {
            ((Setup.events(of: c, agent: agent)[event] as? [[String: Any]]) ?? []).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
        }

        // ---------- 接上 ----------
        let fresh = Setup.installed([:], agent: .claude, exe: exe, dataDir: data)
        check(ours(fresh, .claude).count == 8 && ours(fresh, .claude).allSatisfy { ($0["timeout"] as? Int) == 5 && ($0["type"] as? String) == "command" },
              "Claude：空配置接上 8 条，超时 5 秒")
        check(Set(Setup.events(of: fresh, agent: .claude).keys) == Set(Setup.claudeHooks.map(\.event)), "Claude 的 8 个事件")
        check(commands(fresh, .claude, "PostToolUse").first?.hasPrefix("[ -e \"" + data + "/sessions/.any-waiting\" ] && ") == true, "每次工具调用后的那条先看有没有人等你")
        check(((Setup.events(of: fresh, agent: .claude)["PreToolUse"] as? [[String: Any]])?.first?["matcher"] as? String) == "AskUserQuestion", "提问那条只匹配 AskUserQuestion")
        check(same(Setup.installed(fresh, agent: .claude, exe: exe, dataDir: data), fresh), "接两次和接一次一样（幂等）")
        check(Setup.current(fresh, agent: .claude, exe: exe, dataDir: data) && Setup.present(fresh, agent: .claude), "接上之后算「都在、指向现在这个程序」")

        // 别人的 hook：原样、原位置；我们的条目在中间时原地改，不挪任何人的位置（Codex 按位置记信任）
        let mem: [String: Any] = ["type": "command", "command": "/usr/bin/python3 /Users/x/memory/hook.py stop"]
        let pet: [String: Any] = ["type": "command", "command": "/Users/x/crosspet/notify"]
        func ourOld(_ agent: String, guarded: Bool = false) -> [String: Any] {
            ["type": "command", "command": (guarded ? "[ -e \"\(data)/sessions/.any-waiting\" ] && " : "") + "\"\(oldExe)\" --hook \(agent) 2>/dev/null; exit 0", "timeout": 5, "note": "mine"]
        }
        let codexUser: [String: Any] = ["hooks": [
            "Stop": [["hooks": [mem]], ["hooks": [ourOld("codex")]], ["hooks": [pet]]],
            "UserPromptSubmit": [["hooks": [ourOld("codex")]], ["hooks": [pet]]],
            "PostToolUse": [["hooks": [ourOld("codex", guarded: true), pet]]],
        ]]
        let codexAfter = Setup.installed(codexUser, agent: .codex, exe: exe, dataDir: data)
        check(commands(codexAfter, .codex, "Stop") == [mem["command"] as! String, Setup.command(Setup.codexHooks[3], agent: .codex, exe: exe, dataDir: data), pet["command"] as! String],
              "我们的条目夹在中间：原地改路径，前后别人的条目一个没挪")
        check(commands(codexAfter, .codex, "UserPromptSubmit").last == pet["command"] as? String
              && (Setup.events(of: codexAfter, agent: .codex)["UserPromptSubmit"] as? [Any])?.count == 2, "UserPromptSubmit：别人的还在第 2 组")
        check(commands(codexAfter, .codex, "PostToolUse") == [Setup.command(Setup.codexHooks[2], agent: .codex, exe: exe, dataDir: data), pet["command"] as! String],
              "和别人挤在一个组里：同组同位置原地改")
        check(ours(codexAfter, .codex).count == 6 && Setup.current(codexAfter, agent: .codex, exe: exe, dataDir: data), "缺的事件接在末尾，总共 6 条")
        let stopOurs = (((Setup.events(of: codexAfter, agent: .codex)["Stop"] as? [[String: Any]])?[1]["hooks"]) as? [[String: Any]])?.first
        check(stopOurs?["note"] as? String == "mine" && Setup.isOurs(stopOurs as Any, agent: .codex), "原地改时保留你在我们条目上加的别的字段")
        check(same(Setup.installed(codexAfter, agent: .codex, exe: exe, dataDir: data), codexAfter), "接好以后再跑：一个字不变")
        let doubled: [String: Any] = ["hooks": ["Stop": [["hooks": [ourOld("codex"), pet, ourOld("codex")]]]]]
        check(commands(Setup.installed(doubled, agent: .codex, exe: exe, dataDir: data), .codex, "Stop").count == 2, "同一事件里重复的我们的条目去掉，只留一条")
        let stale: [String: Any] = ["hooks": ["OldEvent": [["hooks": [ourOld("codex")]]]]]
        check(Setup.events(of: Setup.installed(stale, agent: .codex, exe: exe, dataDir: data), agent: .codex)["OldEvent"] == nil, "不在清单里的事件上的我们的条目去掉")

        // 认条目
        check(!Setup.isOurs(["command": "\"/x/AIQuota\" --hook codex"], agent: .claude) && !Setup.isOurs(["command": "echo --hook claude"], agent: .claude),
              "Claude 的不会把 Codex 的、别的程序的当成自己的")
        check(Setup.target(of: ourOld("codex", guarded: true), agent: .codex) == oldExe && Setup.target(of: ["command": Setup.command(Setup.claudeHooks[0], agent: .claude,
              exe: "/a \"b\" $c/AIQuota", dataDir: data)], agent: .claude) == "/a \"b\" $c/AIQuota", "从命令里读出指向的程序（带引号和 $ 的也读得对）")

        // ---------- 只修路径 ----------
        let partial: [String: Any] = ["hooks": ["Stop": [["hooks": [mem]], ["hooks": [ourOld("codex")]]]]]
        let moved = Setup.retargeted(partial, agent: .codex, exe: exe) { _ in false }
        check(commands(moved, .codex, "Stop") == [mem["command"] as! String, "\"\(exe)\" --hook codex 2>/dev/null; exit 0"] && ours(moved, .codex).count == 1,
              "原来的程序不在了：只改路径，不补你删掉的那 5 条")
        check(same(Setup.retargeted(partial, agent: .codex, exe: exe) { _ in true }, partial), "原来那份程序还在（另一份拷贝）：不抢")
        let zOff: [String: Any] = ["hooks": ["enabled": false, "events": ["Stop": [["hooks": [["type": "process", "command": oldExe, "args": ["--hook", "zcode"]]]]]]]]
        let zMoved = Setup.retargeted(zOff, agent: .zcode, exe: exe) { _ in false }
        check((zMoved["hooks"] as? [String: Any])?["enabled"] as? Bool == false && ours(zMoved, .zcode).first?["command"] as? String == exe, "ZCode：只改路径，你关掉的总开关不打开")

        // ---------- 卸载 ----------
        let gone = Setup.uninstalled(codexAfter, agent: .codex)
        check(ours(gone.config, .codex).isEmpty && hooks(gone.config, .codex).count == 4, "卸载只去掉我们的，别人的 4 条都在")
        check(gone.shifted == 3, "卸载后别人的条目有 3 条挪了位置（要在 Codex 里重新信任）：算得出来")
        check(Setup.uninstalled(fresh, agent: .claude).config["hooks"] == nil, "只有我们的：卸载后 hooks 整个去掉")
        let tail: [String: Any] = ["hooks": ["Stop": [["hooks": [mem]], ["hooks": [ourOld("codex")]]]]]
        check(Setup.uninstalled(tail, agent: .codex).shifted == 0, "我们的在最后：没人挪位置")

        // ---------- Codex / ZCode 格式 ----------
        let zcode = Setup.installed(["model": "glm", "hooks": ["enabled": false, "events": ["Stop": [["hooks": [["type": "process", "command": "/bin/echo", "args": ["hi"]]]]]]]],
                                    agent: .zcode, exe: exe, dataDir: data)
        let zh = zcode["hooks"] as? [String: Any] ?? [:]
        check(zh["enabled"] as? Bool == true && zh["timeoutMs"] == nil && zcode["model"] as? String == "glm", "ZCode：打开 hooks 总开关，不写全局超时，别的设置原样")
        check(ours(zcode, .zcode).count == 6 && hooks(zcode, .zcode).count == 7
              && ours(zcode, .zcode).allSatisfy { $0["command"] as? String == exe && $0["args"] as? [String] == ["--hook", "zcode"] && $0["timeoutMs"] as? Int == 10000 },
              "ZCode：6 条 process 类型，每条自己带超时")
        check(Setup.current(zcode, agent: .zcode, exe: exe, dataDir: data) && same(Setup.installed(zcode, agent: .zcode, exe: exe, dataDir: data), zcode), "ZCode 幂等")

        // ---------- 读写文件 ----------
        let claudeDir = home.appendingPathComponent(".claude")
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settings = Setup.Agent.claude.configURL(home: home)
        let userClaude: [String: Any] = ["model": "opus", "hooks": ["SessionStart": [["matcher": "startup", "hooks": [mem]]]]]
        try? JSONSerialization.data(withJSONObject: userClaude).write(to: settings)
        let original = try? Data(contentsOf: settings)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        if case .written(let backup?, _) = Setup.apply(.claude, home: home, exe: exe, dataDir: data, now: now) {
            check(backup.hasSuffix(".bak-aiquota-" + Setup.stamp(now)) && (try? Data(contentsOf: URL(fileURLWithPath: backup))) == original, "改之前先备份，备份是原样")
        } else { check(false, "改之前先备份") }
        check(Setup.read(settings).config.map { Setup.current($0, agent: .claude, exe: exe, dataDir: data) } == true, "写进去的就是接好的")
        check(Setup.apply(.claude, home: home, exe: exe, dataDir: data) == .unchanged, "再跑一次：不改、不再备份")
        // 同一秒里再改一次：备份加 -2，不覆盖第一份
        if case .written(let second?, _) = Setup.apply(.claude, home: home, exe: exe, dataDir: data, mode: .uninstall, now: now) {
            check(second.hasSuffix(Setup.stamp(now) + "-2") && (try? Data(contentsOf: URL(fileURLWithPath: settings.path + ".bak-aiquota-" + Setup.stamp(now)))) == original,
                  "同一秒第二次备份加 -2，第一份原样还在")
        } else { check(false, "同一秒第二次备份加 -2") }
        // 没有我们条目的文件：卸载不动它
        let untouched = try? Data(contentsOf: settings)
        check(Setup.apply(.claude, home: home, exe: exe, dataDir: data, mode: .uninstall) == .unchanged && (try? Data(contentsOf: settings)) == untouched,
              "里面没有我们的条目：卸载不重写、不备份")
        try? JSONSerialization.data(withJSONObject: ["hooks": [String: Any]()]).write(to: settings)
        check(Setup.apply(.claude, home: home, exe: exe, dataDir: data, mode: .uninstall) == .unchanged, "hooks 是空的：卸载也不重写")
        // 坏文件、只读、符号链接
        let codexFile = Setup.Agent.codex.configURL(home: home)
        try? fm.createDirectory(at: codexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{ \"hooks\": { oops".utf8).write(to: codexFile)
        if case .unreadable = Setup.apply(.codex, home: home, exe: exe, dataDir: data) {} else { check(false, "坏的 JSON 不写") }
        check((try? String(contentsOf: codexFile, encoding: .utf8)) == "{ \"hooks\": { oops", "坏的 JSON 原样留着")
        try? Data("[1, 2]".utf8).write(to: codexFile)
        if case .unreadable = Setup.apply(.codex, home: home, exe: exe, dataDir: data) {} else { check(false, "顶层不是对象也不写") }
        try? Data("{}".utf8).write(to: codexFile)
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: codexFile.path)
        if case .unreadable(let why) = Setup.apply(.codex, home: home, exe: exe, dataDir: data) { check(why.contains("只读"), "只读的配置不改，说明原因") } else { check(false, "只读的配置不改") }
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: codexFile.path)
        try? Data("  \n".utf8).write(to: codexFile)
        if case .written = Setup.apply(.codex, home: home, exe: exe, dataDir: data) {} else { check(false, "空白文件当成空配置") }
        let dotfiles = root.appendingPathComponent("dotfiles/settings.json")
        try? fm.createDirectory(at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: userClaude).write(to: dotfiles)
        try? fm.removeItem(at: settings)
        try? fm.createSymbolicLink(at: settings, withDestinationURL: dotfiles)
        if case .written(let backup?, _) = Setup.apply(.claude, home: home, exe: exe, dataDir: data, now: now.addingTimeInterval(60)) {
            let backupIsLink = (try? fm.destinationOfSymbolicLink(atPath: backup)) != nil
            check(!backupIsLink && backup.hasPrefix(dotfiles.path), "符号链接：备份是一份真文件，放在它指向的文件旁边")
        } else { check(false, "符号链接也能接") }
        check((try? fm.destinationOfSymbolicLink(atPath: settings.path)) != nil && Setup.read(dotfiles).config.map { Setup.current($0, agent: .claude, exe: exe, dataDir: data) } == true,
              "符号链接还是链接，改的是它指向的那个文件")
        // ZCode：总开关是我们打开的，卸载时还原
        let zfile = Setup.Agent.zcode.configURL(home: home)
        try? fm.createDirectory(at: zfile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["model": "glm"]).write(to: zfile)
        if case .written(_, let note?) = Setup.apply(.zcode, home: home, exe: exe, dataDir: data) { check(note.contains("总开关"), "打开 ZCode 总开关时说一声") }
        else { check(false, "打开 ZCode 总开关时说一声") }
        if case .written(_, let note?) = Setup.apply(.zcode, home: home, exe: exe, dataDir: data, mode: .uninstall) {
            let restored = Setup.read(zfile).config?["hooks"] as? [String: Any]
            check(note == Setup.zcodeRestored && restored?["enabled"] == nil && !fm.fileExists(atPath: Setup.zcodeMarker(dataDir: data).path),
                  "卸载：原来没有总开关，就把它去掉（还原），记号也删掉")
        } else { check(false, "卸载时还原 ZCode 总开关") }
        let missing = root.appendingPathComponent("bare-home")
        try? fm.createDirectory(at: missing, withIntermediateDirectories: true)
        check(Setup.apply(.zcode, home: missing, exe: exe, dataDir: data, mode: .uninstall) == .unchanged
              && Setup.apply(.zcode, home: missing, exe: exe, dataDir: data, mode: .retarget) == .unchanged
              && !fm.fileExists(atPath: missing.appendingPathComponent(".zcode").path), "卸载、修路径不新建文件")

        // ---------- 带空格、引号、$ 的路径真能跑；没人等你时工具调用后的那条不启动程序 ----------
        let weird = root.appendingPathComponent("Apps $HOME `x` \"q\"/AIQuota.app/Contents/MacOS")
        try? fm.createDirectory(at: weird, withIntermediateDirectories: true)
        let fake = weird.appendingPathComponent("AIQuota")
        let marker = root.appendingPathComponent("ran.txt")
        try? Data("#!/bin/sh\necho \"$@\" >> \"\(marker.path)\"\n".utf8).write(to: fake)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let weirdData = root.appendingPathComponent("data dir").path
        func sh(_ command: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        _ = sh(Setup.command(Setup.claudeHooks[0], agent: .claude, exe: fake.path, dataDir: weirdData))
        check((try? String(contentsOf: marker, encoding: .utf8)) == "--hook claude\n", "路径里有空格、引号、$、反引号：命令照样调到程序，参数对")
        let guarded = Setup.command(Setup.claudeHooks[3], agent: .claude, exe: fake.path, dataDir: weirdData)
        try? fm.removeItem(at: marker)
        _ = sh(guarded)
        check(!fm.fileExists(atPath: marker.path), "没有会话在等你：工具调用后的那条不启动程序")
        try? fm.createDirectory(atPath: weirdData + "/sessions", withIntermediateDirectories: true)
        fm.createFile(atPath: weirdData + "/sessions/.any-waiting", contents: Data())
        _ = sh(guarded)
        check((try? String(contentsOf: marker, encoding: .utf8)) == "--hook claude\n", "有会话在等你：才启动程序")
        check(sh(Setup.command(Setup.claudeHooks[0], agent: .claude, exe: "/nonexistent/AIQuota", dataDir: weirdData)) == 0, "程序不在了：hook 也退出 0，不拦 AI")

        // ---------- tb ----------
        check(Setup.installTB(home: home, exe: fake.path), "没有 tb：装上")
        let tb = Setup.tbURL(home: home)
        check(Setup.ourTB(home: home) && ((try? fm.attributesOfItem(atPath: tb.path))?[.posixPermissions] as? Int) == 0o755, "tb 认得出是我们的，可执行")
        try? fm.removeItem(at: marker)
        _ = sh(Setup.shellQuote(tb.path) + " light 构建 绿")
        check((try? String(contentsOf: marker, encoding: .utf8)) == "--tb light 构建 绿\n", "tb 把参数原样交给程序")
        let buildShTB = "#!/bin/sh\n# AIQuota 的 tb：在触控栏上点灯\nAPP=\"/Users/x/Applications/AIQuota.app/Contents/MacOS/AIQuota\"\n"
            + "if [ -x \"$APP\" ]; then exec \"$APP\" --tb \"$@\"; fi\nif [ \"$1\" = \"run\" ]; then\n    shift\n    while [ $# -gt 0 ]; do\n        case \"$1\" in\n"
            + "            --keep) shift ;;\n            --name) shift; [ $# -gt 0 ] && shift ;;\n            --) shift; break ;;\n            *) break ;;\n        esac\n    done\n"
            + "    exec \"$@\"\nfi\nexit 0\n"
        check(Setup.isOurTB(buildShTB), "build.sh 装的那份 tb 也认得出是我们的")
        let mineToo = "#!/bin/sh\n# 我自己的 tb，转给 AIQuota\ncase \"$1\" in deploy) ./deploy.sh ;; *) exec /Applications/AIQuota.app/Contents/MacOS/AIQuota --tb \"$@\" ;; esac\n"
        try? Data(mineToo.utf8).write(to: tb)
        check(!Setup.installTB(home: home, exe: exe) && (try? String(contentsOf: tb, encoding: .utf8)) == mineToo, "你自己写的 tb（里面也有 AIQuota 字样）：不覆盖")
        Setup.removeTB(home: home)
        check(fm.fileExists(atPath: tb.path), "卸载也不删你自己的 tb")
        try? fm.removeItem(at: tb)
        try? fm.createSymbolicLink(atPath: tb.path, withDestinationPath: fake.path)
        check(!Setup.installTB(home: home, exe: exe) && (try? fm.destinationOfSymbolicLink(atPath: tb.path)) != nil, "tb 是符号链接：当成别人的，不换掉")
        try? fm.removeItem(at: tb)
        let rcHome = root.appendingPathComponent("rc-home")
        try? fm.createDirectory(at: rcHome, withIntermediateDirectories: true)
        check(!Setup.tbOnPath(home: rcHome), "shell 配置里没提 ~/.local/bin：要提醒加 PATH")
        try? Data("export PATH=\"$HOME/.local/bin:$PATH\"\n".utf8).write(to: rcHome.appendingPathComponent(".zshrc"))
        check(Setup.tbOnPath(home: rcHome), "提到了就不用提醒")

        // ---------- 整体卸载 ----------
        _ = Setup.apply(.claude, home: home, exe: exe, dataDir: data)
        _ = Setup.installTB(home: home, exe: exe)
        let result = Setup.uninstall(home: home, purge: false)
        check(result.ok && !(Setup.read(dotfiles).config.map { Setup.present($0, agent: .claude) } ?? true) && !Setup.ourTB(home: home),
              "卸载：去掉我们的 hooks 和 tb")
        check(!fm.fileExists(atPath: Setup.stateURL.path), "卸载后忘掉「设置过」，重装会再问一次")
        try? Data("{ broken".utf8).write(to: codexFile)
        _ = Setup.apply(.claude, home: home, exe: exe, dataDir: data)
        try? JSONSerialization.data(withJSONObject: Setup.installed(["model": "glm"], agent: .zcode, exe: exe, dataDir: data)).write(to: zfile)
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: zfile.path)
        let blocked = Setup.uninstall(home: home, purge: true)
        check(!blocked.ok && blocked.lines.contains { $0.contains("ZCode") && $0.contains("只读") }, "有配置改不了：卸载报失败（卸载脚本就不删 app），说清是哪个")
        check(!blocked.lines.contains { $0.contains("删除了数据目录") }, "改不了时不删数据目录（purge 不执行）")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: zfile.path)

        // ---------- 临时位置不接 ----------
        check(Setup.unstableLocation("/private/var/folders/x/T/AppTranslocation/ABC/d/AIQuota.app") != nil
              && Setup.unstableLocation("/Volumes/AIQuota/AIQuota.app") != nil
              && Setup.unstableLocation("/Users/x/src/ai-quota/mac/build/AIQuota.app") != nil
              && Setup.unstableLocation("/Applications/AIQuota.app") == nil && Setup.unstableLocation("/Users/x/Applications/AIQuota.app") == nil,
              "从 DMG、系统临时位置、编译目录打开时不接 hooks；「应用程序」里的才接")
        check(LoginItem.plistURL.path.hasPrefix(ProcessInfo.processInfo.environment["AIQUOTA_TEST_HOME"] ?? "/nonexistent"), "测试里的开机启动项写在临时目录，不碰真的")
    }
}
