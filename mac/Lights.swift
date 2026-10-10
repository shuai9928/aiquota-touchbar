import AppKit

struct CustomLight: Equatable {
    enum State: String {
        case running, done, error, waiting, info
    }

    var name: String
    var state: State
    var detail = ""
    var progress: Double?
    var started: Date
    var updated: Date
    var pid: Int32?
    var pidStart: UInt64?
    var keep = false
    var code: Int32?

    var id: String { CustomLights.fileID(name) }

    var light: Light {
        switch state {
        case .running: return .running
        case .done: return .done
        case .error: return .error
        case .waiting: return .waiting
        case .info: return .idle
        }
    }

    var dismissable: Bool { state != .running || pid == nil }

    func json() -> [String: Any] {
        var object: [String: Any] = ["name": name, "state": state.rawValue, "detail": detail, "keep": keep,
                                     "started": started.timeIntervalSince1970, "updated": updated.timeIntervalSince1970]
        if let progress { object["progress"] = progress }
        if let pid { object["pid"] = Int(pid) }
        if let pidStart { object["pidStart"] = NSNumber(value: pidStart) }
        if let code { object["code"] = Int(code) }
        return object
    }

    init(name: String, state: State, detail: String = "", progress: Double? = nil, started: Date, updated: Date,
         pid: Int32? = nil, pidStart: UInt64? = nil, keep: Bool = false, code: Int32? = nil) {
        self.name = CustomLights.clean(name, limit: CustomLights.nameLimit)
        self.state = state
        self.detail = CustomLights.clean(detail, limit: CustomLights.detailLimit)
        self.progress = progress.map { min(100, max(0, $0)) }
        self.started = started
        self.updated = updated
        self.pid = pid
        self.pidStart = pidStart
        self.keep = keep
        self.code = code
    }

    init?(json object: [String: Any]) {
        guard let name = object["name"] as? String, !CustomLights.clean(name, limit: CustomLights.nameLimit).isEmpty,
              let raw = object["state"] as? String, let state = State(rawValue: raw),
              let started = object["started"] as? Double, let updated = object["updated"] as? Double else { return nil }
        self.init(name: name, state: state, detail: object["detail"] as? String ?? "", progress: object["progress"] as? Double,
                  started: Date(timeIntervalSince1970: started), updated: Date(timeIntervalSince1970: updated),
                  pid: (object["pid"] as? Int).map { Int32(clamping: $0) }, pidStart: (object["pidStart"] as? NSNumber)?.uint64Value,
                  keep: object["keep"] as? Bool ?? false, code: (object["code"] as? Int).map { Int32(clamping: $0) })
    }
}

enum CustomLights {
    static let nameLimit = 40
    static let detailLimit = 120
    static let maxLights = 20
    static let maxFileBytes = 8192
    static var folder: URL {
        AppConfig.dir.appendingPathComponent("lights")
    }

    static func clean(_ text: String, limit: Int) -> String {
        let flat = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let trimmed = flat.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    static func fileID(_ name: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in clean(name, limit: nameLimit).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    static func url(for name: String, in folder: URL) -> URL {
        folder.appendingPathComponent(fileID(name) + ".json")
    }

    static func write(_ light: CustomLight, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: light.json(), options: [.sortedKeys])
        try data.write(to: url(for: light.name, in: folder), options: .atomic)
    }

    static func read(_ name: String, in folder: URL) -> CustomLight? {
        let file = url(for: name, in: folder)
        guard let data = try? Data(contentsOf: file), data.count <= maxFileBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return CustomLight(json: object)
    }

    static func remove(_ name: String, in folder: URL) {
        try? FileManager.default.removeItem(at: url(for: name, in: folder))
    }

    static func startTime(of pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    static func alive(_ pid: Int32, _ start: UInt64?) -> Bool {
        guard let start else { return kill(pid, 0) == 0 }
        return startTime(of: pid) == start
    }

    static func owned(_ light: CustomLight, alive: (Int32, UInt64?) -> Bool) -> Bool {
        guard light.state == .running, let pid = light.pid else { return false }
        return alive(pid, light.pidStart)
    }

    static func expired(_ light: CustomLight, now: Date, alive: (Int32, UInt64?) -> Bool) -> Bool {
        let quiet = now.timeIntervalSince(light.updated)
        if light.state == .running, light.pid != nil {
            return !alive(light.pid ?? 0, light.pidStart) && quiet > 12 * 3600
        }
        if light.keep { return quiet > 7 * 86400 }
        switch light.state {
        case .done: return quiet > 20 * 60
        case .error, .waiting, .info: return quiet > 2 * 3600
        case .running: return quiet > 3600
        }
    }

    static func settle(_ light: CustomLight, alive: (Int32, UInt64?) -> Bool) -> CustomLight {
        guard light.state == .running, let pid = light.pid, !alive(pid, light.pidStart) else { return light }
        var ended = light
        ended.state = .error
        ended.detail = "没等到结束，进程已经不在了"
        ended.pid = nil
        ended.pidStart = nil
        return ended
    }

    static func load(from folder: URL, now: Date, alive: (Int32, UInt64?) -> Bool = CustomLights.alive, prune: Bool = true) -> [CustomLight] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var lights: [CustomLight] = []
        for file in urls where file.pathExtension == "json" {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            let parsed: CustomLight? = size <= maxFileBytes
                ? (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.flatMap(CustomLight.init(json:))
                : nil
            guard let light = parsed else {
                if prune, let modified = values?.contentModificationDate, now.timeIntervalSince(modified) > 86400 {
                    try? FileManager.default.removeItem(at: file)
                }
                continue
            }
            if expired(light, now: now, alive: alive) {
                if prune { try? FileManager.default.removeItem(at: file) }
                continue
            }
            lights.append(settle(light, alive: alive))
        }
        return lights.sorted { ($0.started, $0.name) < ($1.started, $1.name) }
    }

    static func visible(_ lights: [CustomLight], limit: Int = maxLights) -> [CustomLight] {
        guard lights.count > limit else { return lights }
        let important: (CustomLight) -> Bool = { $0.state != .done && $0.state != .info || $0.keep }
        let ranked = lights.sorted { lhs, rhs in
            if important(lhs) != important(rhs) { return important(lhs) }
            return lhs.updated > rhs.updated
        }
        let chosen = Set(ranked.prefix(limit).map(\.name))
        return lights.filter { chosen.contains($0.name) }
    }

    static func summary(_ light: CustomLight, now: Date) -> String {
        let took = Fmt.short(light.updated.timeIntervalSince(light.started))
        switch light.state {
        case .running:
            let percent = light.progress.map { "\(Int($0.rounded()))% · " } ?? ""
            return percent + (light.detail.isEmpty ? "运行中" : light.detail) + " · " + Fmt.short(now.timeIntervalSince(light.started))
        case .done:
            return light.detail.isEmpty ? "完成 · 用了 " + took : light.detail
        case .error:
            if !light.detail.isEmpty { return light.detail }
            return light.code.map { "失败 · 退出码 \($0) · 用了 " + took } ?? "失败"
        case .waiting, .info:
            return light.detail.isEmpty ? "更新于 " + Fmt.short(now.timeIntervalSince(light.updated)) + "前" : light.detail
        }
    }
}

enum TBCommand: Equatable {
    case run(name: String?, keep: Bool, command: [String])
    case light(name: String, state: CustomLight.State, detail: String, keep: Bool)
    case progress(name: String, percent: Double, detail: String)
    case off(String)
    case clear
    case list
    case help

    static let usage = """
    tb：在触控栏上点一盏灯（AIQuota）
      tb run [--name 名字] [--keep] 命令 参数…   跑命令，跑着是暗灯，成功变绿、失败变红；输出、输入和退出码都不变
      tb light 名字 红|绿|橙|灰 [说明] [--keep]  手动点灯（也可以写 error|done|waiting|running|info）
      tb progress 名字 0-100 [说明]              更新进度
      tb off 名字                                 关掉这盏灯
      tb clear                                    关掉全部
      tb list                                     看现在有哪些灯
    完成的灯 20 分钟后自动消失，失败的 2 小时；加 --keep 留 7 天。
    """

    static func state(_ word: String) -> CustomLight.State? {
        switch word.lowercased() {
        case "红", "red", "error", "fail", "failed": return .error
        case "绿", "green", "done", "ok", "success": return .done
        case "橙", "黄", "orange", "yellow", "waiting", "wait": return .waiting
        case "灰", "gray", "grey", "running", "run": return .running
        case "info", "白", "white": return .info
        default: return nil
        }
    }

    static func named(_ name: String) -> String? {
        let clean = CustomLights.clean(name, limit: CustomLights.nameLimit)
        return clean.isEmpty ? nil : name
    }

    static func parse(_ args: [String]) -> TBCommand? {
        guard let verb = args.first else { return .help }
        var rest = Array(args.dropFirst())
        switch verb {
        case "run":
            var name: String?
            var keep = false
            while let flag = rest.first, flag.hasPrefix("--") {
                rest.removeFirst()
                if flag == "--" { break }
                if flag == "--keep" { keep = true; continue }
                if flag == "--name", let value = rest.first {
                    guard let valid = named(value) else { return nil }
                    name = valid
                    rest.removeFirst()
                    continue
                }
                return nil
            }
            return rest.isEmpty ? nil : .run(name: name, keep: keep, command: rest)
        case "light":
            let keep = rest.contains("--keep")
            rest.removeAll { $0 == "--keep" }
            guard rest.count >= 2, let name = named(rest[0]), let state = state(rest[1]) else { return nil }
            return .light(name: name, state: state, detail: rest.dropFirst(2).joined(separator: " "), keep: keep)
        case "progress":
            guard rest.count >= 2, let name = named(rest[0]), let percent = Double(rest[1].replacingOccurrences(of: "%", with: "")) else { return nil }
            return .progress(name: name, percent: percent, detail: rest.dropFirst(2).joined(separator: " "))
        case "off":
            guard rest.count == 1, let name = named(rest[0]) else { return nil }
            return .off(name)
        case "clear": return rest.isEmpty ? .clear : nil
        case "list": return rest.isEmpty ? .list : nil
        case "help", "-h", "--help": return .help
        default: return nil
        }
    }
}

enum TB {
    static let forwarded = [SIGTERM, SIGHUP]
    static let interrupts = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    static func main(_ args: [String], folder: URL = CustomLights.folder, reraise: Bool = true) -> Int32 {
        guard let command = TBCommand.parse(args) else {
            FileHandle.standardError.write(Data(("用法不对。\n" + TBCommand.usage + "\n").utf8))
            return 2
        }
        let now = Date()
        do {
            switch command {
            case .help:
                print(TBCommand.usage)
            case .list:
                for light in CustomLights.load(from: folder, now: now, prune: false) {
                    print(light.name + "\t" + light.state.rawValue + "\t" + CustomLights.summary(light, now: now))
                }
            case .clear:
                for light in CustomLights.load(from: folder, now: now, prune: false) { CustomLights.remove(light.name, in: folder) }
            case .off(let name):
                CustomLights.remove(name, in: folder)
            case .light(let name, let state, let detail, let keep):
                let old = CustomLights.read(name, in: folder)
                // 从结束的状态重新点成「在跑」：算新的一次，开始时间重算（「做完叫我」靠它分辨是不是同一次）
                let restarted = state == .running && old?.state != .running
                try CustomLights.write(CustomLight(name: name, state: state, detail: detail, progress: old?.progress,
                                                   started: restarted ? now : old?.started ?? now, updated: now, keep: keep), in: folder)
            case .progress(let name, let percent, let detail):
                let old = CustomLights.read(name, in: folder)
                let running = old?.state == .running
                try CustomLights.write(CustomLight(name: name, state: .running, detail: detail.isEmpty ? old?.detail ?? "" : detail,
                                                   progress: percent, started: running ? old?.started ?? now : now, updated: now,
                                                   pid: running ? old?.pid : nil, pidStart: running ? old?.pidStart : nil,
                                                   keep: old?.keep ?? false), in: folder)
            case .run(let name, let keep, let arguments):
                return run(arguments, name: name ?? defaultName(arguments), keep: keep, folder: folder, reraise: reraise)
            }
        } catch {
            FileHandle.standardError.write(Data(("tb：写不了灯的状态：" + error.localizedDescription + "\n").utf8))
            return 1
        }
        return 0
    }

    static func defaultName(_ arguments: [String], directory: String = FileManager.default.currentDirectoryPath) -> String {
        let words = arguments.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
        let place = (directory as NSString).lastPathComponent
        return place.isEmpty || place == "/" ? words : words + " · " + place
    }

    static func freeName(_ base: String, folder: URL, alive: (Int32, UInt64?) -> Bool = CustomLights.alive) -> String {
        var candidate = base
        var number = 2
        while let existing = CustomLights.read(candidate, in: folder), CustomLights.owned(existing, alive: alive), number < 100 {
            candidate = base + " #\(number)"
            number += 1
        }
        return candidate
    }

    static func decode(_ status: Int32) -> (code: Int32, signal: Int32?) {
        let low = status & 0x7f
        if low == 0 { return ((status >> 8) & 0xff, nil) }
        return (128 + low, low)
    }

    static func spawn(_ arguments: [String]) -> (pid: pid_t, error: Int32) {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for number in interrupts + [SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE] { sigaddset(&defaults, number) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawnp(&pid, arguments[0], nil, &attributes, argv, environ)
        return (pid, result)
    }

    static func run(_ arguments: [String], name requested: String, keep: Bool, folder: URL, reraise: Bool) -> Int32 {
        let name = freeName(requested, folder: folder)
        let started = Date()
        let own = getpid()
        let ownStart = CustomLights.startTime(of: own)
        try? CustomLights.write(CustomLight(name: name, state: .running, started: started, updated: started,
                                            pid: own, pidStart: ownStart, keep: keep), in: folder)
        for number in interrupts { signal(number, SIG_IGN) }
        let spawned = spawn(arguments)
        var sources: [DispatchSourceSignal] = []
        if spawned.error == 0 {
            for number in forwarded {
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { kill(spawned.pid, number) }
                source.resume()
                sources.append(source)
            }
        }
        var outcome: (code: Int32, signal: Int32?) = (127, nil)
        if spawned.error == 0 {
            var status: Int32 = 0
            while waitpid(spawned.pid, &status, 0) == -1 && errno == EINTR {}
            outcome = decode(status)
        } else {
            let reason = String(cString: strerror(spawned.error))
            FileHandle.standardError.write(Data(("tb：启动不了「" + arguments[0] + "」：" + reason + "\n").utf8))
            outcome = (spawned.error == ENOENT ? 127 : 126, nil)
        }
        sources.forEach { $0.cancel() }
        for number in interrupts { signal(number, SIG_DFL) }
        let ended = Date()
        var detail = ""
        if let caught = outcome.signal {
            detail = interrupts.contains(caught)
                ? "被中断了 · 用了 " + Fmt.short(ended.timeIntervalSince(started))
                : "崩溃 · " + String(cString: strsignal(caught))
        }
        let result = CustomLight(name: name, state: outcome.code == 0 ? .done : .error, detail: detail, started: started,
                                 updated: ended, keep: keep, code: outcome.code)
        let current = CustomLights.read(name, in: folder)
        if current == nil || current?.pid == own || current?.state != .running {
            try? CustomLights.write(result, in: folder)
        } else {
            var moved = result
            moved.name = freeName(name + " #2", folder: folder)
            try? CustomLights.write(moved, in: folder)
        }
        if reraise, let caught = outcome.signal, interrupts.contains(caught) {
            signal(caught, SIG_DFL)
            var set = sigset_t()
            sigemptyset(&set)
            sigaddset(&set, caught)
            sigprocmask(SIG_UNBLOCK, &set, nil)
            kill(own, caught)
        }
        return outcome.code
    }
}

extension AppModel {
    func reloadLights() {
        let all = CustomLights.load(from: lightsFolder, now: Date())
        allLights = all                                     // 全部的：「做完叫我」要看被挤出显示的那几盏
        let fresh = CustomLights.visible(all)
        if fresh != customLights { customLights = fresh }
        checkWatched()
    }

    func dismissLight(_ name: String, updated: Date) {
        if let current = CustomLights.read(name, in: lightsFolder), current.dismissable,
           abs(current.updated.timeIntervalSince(updated)) < 0.001 {
            CustomLights.remove(name, in: lightsFolder)
        }
        reloadLights()
        onUpdate?()
    }

    func watchLights() {
        try? FileManager.default.createDirectory(at: lightsFolder, withIntermediateDirectories: true)
        reloadLights()
        let descriptor = Darwin.open(lightsFolder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                self.reloadLights()
                self.onUpdate?()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        lightsWatcher = source
    }
}
