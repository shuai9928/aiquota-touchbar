import AppKit
import Darwin

/// 用户主动点击后才执行的本机项目操作，不读取会话正文或调用模型。
enum ProjectActions {
    /// 只接受现有的绝对目录；允许用 ~ 表示用户目录。
    static func directory(_ path: String) -> URL? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url.resolvingSymlinksInPath()
    }

    @MainActor
    static func openFolder(_ path: String) -> Bool {
        guard let url = directory(path) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// 直接把目录 URL 交给 Terminal，不生成或插入 shell 命令。
    @MainActor
    static func openTerminal(_ path: String) async -> Bool {
        guard let url = directory(path),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: terminal,
                                    configuration: configuration) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }

    /// 返回可复制的本机状态摘要；调用方决定是否复制或发送。
    static func handoff(projectPath: String, title: String, agentName: String,
                        sessionID: String, state: String) async -> String {
        await Task.detached(priority: .userInitiated) {
            makeHandoff(projectPath: projectPath, title: title, agentName: agentName,
                        sessionID: sessionID, state: state)
        }.value
    }

    private static func makeHandoff(projectPath: String, title: String, agentName: String,
                                    sessionID: String, state: String) -> String {
        var lines = [
            "请先阅读项目规则，审查当前改动，列出带文件位置的问题。",
            "",
            "任务名：\(field(title, fallback: "未命名", limit: 240))",
            "来源 agent：\(field(agentName, fallback: "未知", limit: 120))",
            "源会话 ID：\(field(sessionID, fallback: "未提供", limit: 240))",
            "源会话状态：\(field(state, fallback: "未知", limit: 240))"
        ]
        guard let project = directory(projectPath) else {
            lines.append("项目绝对路径：无法确认")
            lines.append("提供的路径：\(field(projectPath, fallback: "未提供", limit: 2_048))")
            lines.append("Git 信息：未读取（需要一个现有的绝对目录，可使用 ~）。")
            return lines.joined(separator: "\n")
        }
        lines.append("项目绝对路径：\(oneLine(project.path, limit: 4_096))")
        guard let git = gitExecutable else {
            lines.append("Git 信息：无法读取（未找到可执行的 Git）。")
            return lines.joined(separator: "\n")
        }

        // 共用截止时间，避免几个失败命令依次造成长时间等待。
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        func run(_ arguments: [String]) -> GitResult {
            runGit(git, in: project, arguments: arguments,
                   timeout: max(0, min(3, deadline - ProcessInfo.processInfo.systemUptime)))
        }

        let root = run(["rev-parse", "--show-toplevel"])
        guard root.succeeded, !root.stdoutTruncated else {
            let reason = root.stdoutTruncated ? "Git 根目录输出超过长度限制" : root.failureReason
            lines.append("Git 信息：无法读取（\(reason)）。")
            return lines.joined(separator: "\n")
        }
        lines.append("Git 根目录：\(oneLine(removeLineEnding(root.output), limit: 4_096))")

        let branch = run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        if branch.succeeded, !branch.stdoutTruncated {
            lines.append("当前分支：\(oneLine(removeLineEnding(branch.output), limit: 1_024))")
        } else if branch.exitCode == 1, !branch.timedOut, branch.launchError == nil {
            let commit = run(["rev-parse", "--short", "HEAD"])
            if commit.succeeded, !commit.stdoutTruncated {
                lines.append("当前分支：分离 HEAD（\(oneLine(removeLineEnding(commit.output), limit: 80))）")
            } else {
                lines.append("当前分支：分离 HEAD；提交读取失败（\(commit.failureReason)）")
            }
        } else {
            lines.append("当前分支：读取失败（\(branch.failureReason)）")
        }

        // status 比较文件内容时会执行仓库自己配置里的 filter（clean/process），比如解压来的仓库带着 .git/config。
        // 先只读出所有 filter 驱动名（读配置不执行任何东西），再在这次查询里把它们清空；读不准就不查改动。
        guard let noFilters = filterOverrides(run(["config", "--null", "--name-only", "--get-regexp",
                                                   "^filter\\..+\\.(clean|smudge|process)$"])) else {
            lines.append("已跟踪文件变更：未读取（无法确认仓库的 filter 配置，为免执行仓库里的命令而跳过）。")
            return lines.joined(separator: "\n")
        }
        let status = run(noFilters + ["status", "--porcelain=v1", "-z", "--untracked-files=no",
                                      "--ignore-submodules=all", "--no-renames"])
        if status.succeeded {
            lines += trackedChanges(status)
        } else {
            lines.append("已跟踪文件变更：读取失败（\(status.failureReason)）")
        }
        return lines.joined(separator: "\n")
    }

    /// 把配置里出现的每个 filter 驱动都覆盖成不执行命令；git config 没有匹配时退出码是 1，也算读到了
    private static func filterOverrides(_ result: GitResult) -> [String]? {
        guard result.launchError == nil, !result.timedOut, !result.stdoutTruncated,
              result.exitCode == 0 || result.exitCode == 1 else { return nil }
        var drivers = Set<String>()
        for name in result.output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard name.hasPrefix("filter."), let dot = name.lastIndex(of: ".") else { return nil }
            let driver = name[name.index(name.startIndex, offsetBy: 7)..<dot]
            guard !driver.isEmpty, !driver.contains("\n"), !driver.contains("=") else { return nil }
            drivers.insert(String(driver))
        }
        return drivers.sorted().flatMap { d in
            ["-c", "filter.\(d).clean=", "-c", "filter.\(d).smudge=", "-c", "filter.\(d).process=", "-c", "filter.\(d).required=false"]
        }
    }

    private static var gitExecutable: URL? {
        ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private static func trackedChanges(_ result: GitResult) -> [String] {
        var records = result.output.split(separator: "\0", omittingEmptySubsequences: true)
        // 超过上限时，最后一个记录可能只截取了一部分文件名。
        if result.stdoutTruncated, result.stdout.last != 0, !records.isEmpty {
            records.removeLast()
        }
        let entries = records.filter { $0.count >= 4 && $0.dropFirst(2).first == " " }
        if entries.isEmpty, !result.stdoutTruncated {
            return ["已跟踪文件变更：无（未列出未跟踪文件；未检查子模块）。"]
        }
        let prefix = result.stdoutTruncated ? "至少 " : ""
        var lines = ["已跟踪文件变更：\(prefix)\(entries.count) 项（未列出未跟踪文件；未检查子模块）。"]
        lines.append("状态两位依次为暂存区/工作区；· 无改动，M 修改，A 新增，D 删除，U 冲突，T 类型变化。")
        for entry in entries.prefix(30) {
            let status = entry.prefix(2).replacingOccurrences(of: " ", with: "·")
            lines.append("  [\(status)] \(oneLine(String(entry.dropFirst(3)), limit: 600))")
        }
        if entries.count > 30 || result.stdoutTruncated {
            lines.append("  ……仅展示前 \(min(entries.count, 30)) 项；请在项目内查看完整状态。")
        }
        return lines
    }

    private struct GitResult {
        var stdout = Data()
        var stderr = Data()
        var stdoutTruncated = false
        var exitCode: Int32?
        var timedOut = false
        var launchError: String?

        var output: String { String(decoding: stdout, as: UTF8.self) }
        var succeeded: Bool { launchError == nil && !timedOut && exitCode == 0 }
        var failureReason: String {
            if let launchError = launchError { return "Git 启动失败：\(ProjectActions.oneLine(launchError, limit: 300))" }
            if timedOut { return "Git 查询超时" }
            let detail = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("not a git repository") { return "该目录不在 Git 仓库中" }
            if detail.contains("must be run in a work tree") { return "该目录是裸仓库，未找到工作区" }
            if !detail.isEmpty { return ProjectActions.oneLine(detail, limit: 400) }
            return "Git 查询失败（退出码 \(exitCode.map(String.init) ?? "未知")）"
        }
    }

    /// 非阻塞读取两路输出，在后台线程上检查超时；不经 shell，也不写 Git 索引。
    private static func runGit(_ executable: URL, in directory: URL,
                               arguments: [String], timeout: TimeInterval) -> GitResult {
        var result = GitResult()
        guard timeout > 0 else { result.timedOut = true; return result }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = ["--no-pager", "--no-optional-locks",
                             "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                             "-c", "core.hooksPath=/dev/null"] + arguments
        // 避免继承 GIT_DIR / GIT_WORK_TREE / 配置注入，确保只查询用户所选目录。
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        defer {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
        }
        guard fcntl(outFD, F_SETFL, O_NONBLOCK) != -1,
              fcntl(errFD, F_SETFL, O_NONBLOCK) != -1 else {
            result.launchError = "无法配置输出读取"
            return result
        }
        do { try process.run() }
        catch { result.launchError = error.localizedDescription; return result }
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var terminationSentAt: TimeInterval?
        var killSent = false
        var ignoredStderrTruncation = false
        while true {
            drain(outFD, into: &result.stdout, limit: 65_536, truncated: &result.stdoutTruncated)
            drain(errFD, into: &result.stderr, limit: 8_192, truncated: &ignoredStderrTruncation)
            if !process.isRunning {
                // 退出时管道仍可能留有少量尾部数据。
                drain(outFD, into: &result.stdout, limit: 65_536, truncated: &result.stdoutTruncated)
                drain(errFD, into: &result.stderr, limit: 8_192, truncated: &ignoredStderrTruncation)
                result.exitCode = process.terminationStatus
                return result
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= deadline, terminationSentAt == nil {
                result.timedOut = true
                terminationSentAt = now
                process.terminate()
            }
            if let sentAt = terminationSentAt {
                if now - sentAt >= 0.2, !killSent {
                    killSent = true
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                // 即使系统迟迟不回报进程退出，也不无限等待。
                if now - sentAt >= 0.7 { return result }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func drain(_ descriptor: Int32, into data: inout Data,
                              limit: Int, truncated: inout Bool) {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        // 持续输出也不能阻止调用方检查截止时间。
        for _ in 0..<32 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
            }
            if count <= 0 {
                if count < 0, errno == EINTR { continue }
                return
            }
            let keep = min(count, max(0, limit - data.count))
            if keep > 0 { data.append(contentsOf: buffer.prefix(keep)) }
            if keep < count { truncated = true }
        }
    }

    private static func field(_ text: String, fallback: String, limit: Int) -> String {
        text.isEmpty ? fallback : oneLine(text, limit: limit)
    }

    private static func removeLineEnding(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// 让文件名、任务名中的换行和控制字符可见，避免破坏交接文本结构。
    private static func oneLine(_ text: String, limit: Int) -> String {
        let prefix = text.prefix(limit)
        var value = ""
        for scalar in prefix.unicodeScalars {
            switch scalar.value {
            case 10: value += "\\n"
            case 13: value += "\\r"
            case 9: value += "\\t"
            case 0...31, 127...159: value += "\\u{\(String(scalar.value, radix: 16))}"
            default: value.unicodeScalars.append(scalar)
            }
        }
        return value + (text.count > limit ? "…" : "")
    }
}
