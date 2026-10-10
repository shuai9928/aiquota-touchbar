import Foundation

/// 给 Windows 小乔的会话快照：哪些会话发、按什么顺序、路线图和思维链怎么写、不带路径和对话内容
enum SessionSnapshotTests {
    @MainActor
    static func run(now: Date, check: (Bool, String) -> Void) {
        func session(_ id: String, _ state: SessionState, ago: TimeInterval = 0, agent: String = "claude", turn: String? = "T") -> AgentSession {
            AgentSession(agent: agent, id: id, state: state, since: now.addingTimeInterval(-ago), updated: now.addingTimeInterval(-ago),
                         first: now.addingTimeInterval(-3600), title: "修登录 " + id, bundle: "", cwd: "/Users/me/secret/proj-" + id,
                         waitReason: state == .waiting ? "permission" : "", transcript: "/Users/me/.claude/projects/x/" + id + ".jsonl",
                         turnID: turn, turnStart: 0, turnAt: now.addingTimeInterval(-ago - 60))
        }
        var parse = RoadParse()
        parse.actions = [RoadAction(kind: .read, object: "A.swift", done: true), RoadAction(kind: .test, object: "test.sh", done: true, verified: true),
                         RoadAction(kind: .edit, object: "B.swift")]
        let sessions = [session("run", .running, ago: 30), session("old", .running, ago: 4 * 3600), session("wait", .waiting, ago: 100),
                        session("err", .error, ago: 50, agent: "codex"), session("fin", .done, ago: 40 * 60), session("ancient", .idle, ago: 2 * 3600),
                        session("legacy", .running, ago: 10, turn: nil)]
        let object = SessionSnapshot.build(sessions: sessions, now: now, parse: { _ in parse }, title: { "T-" + $0.id })
        let list = object["sessions"] as? [[String: Any]] ?? []
        check(object["schemaVersion"] as? Int == 1 && object["source"] as? String == "mac", "带版本号和来源")
        check(list.map { $0["id"] as? String ?? "" } == ["wait", "err", "legacy", "run", "fin"],
              "按紧急程度排（等你、出错、在跑、空闲），同级新的在前；3 小时没动静的在跑、1 小时前的空闲不发")
        check(list.first { $0["id"] as? String == "fin" }?["light"] as? String == "idle", "做完 40 分钟：灯是空闲")
        let run = list.first { $0["id"] as? String == "run" } ?? [:]
        check(run["actions"] as? [String] == ["改 B.swift（进行中）", "跑测试 test.sh · 过了", "读 A.swift"], "思维链：最新的三步，新的在前，正在做的写进行中")
        let steps = run["steps"] as? [[String: Any]] ?? []
        check(steps.map { $0["state"] as? String ?? "" } == ["done", "done", "current"] && steps.last?["sub"] as? String == "进行中 · B.swift", "路线图每步带状态")
        let wait = list.first { $0["id"] as? String == "wait" } ?? [:]
        check((wait["actions"] as? [String])?.first == "等你批准" && wait["waitReason"] as? String == "permission", "等你：思维链第一句写等你批准")
        let err = list.first { $0["id"] as? String == "err" } ?? [:]
        check((err["steps"] as? [[String: Any]])?.last?["state"] as? String == "failed" && err["agent"] as? String == "codex", "出错的最后一步标失败")
        check(list.first { $0["id"] as? String == "legacy" }?["steps"] == nil && list.first { $0["id"] as? String == "fin" }?["steps"] == nil,
              "没有轮次的旧记录、做完的：不算路线图")
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        check(!data.isEmpty && !text.contains("/Users/me") && run["project"] as? String == "proj-run" && run["title"] as? String == "T-run",
              "能转成 JSON；不带完整路径，项目只给文件夹名；标题用真的标题")
        var empty = RoadParse()
        empty.actions = []
        let fresh = SessionSnapshot.build(sessions: [session("new", .running)], now: now, parse: { _ in empty }, title: { _ in "" })
        check(((fresh["sessions"] as? [[String: Any]])?.first?["actions"] as? [String]) == [], "刚开始还没动手：思维链是空的（小乔自己写状态词）")
        var many: [AgentSession] = []
        for index in 0..<6 { many.append(session("m\(index)", .running, ago: Double(index))) }
        var reads = 0
        _ = SessionSnapshot.build(sessions: many, now: now, parse: { _ in reads += 1; return parse }, title: { _ in "" })
        check(reads == SessionSnapshot.maxRoads, "最多给几条会话读记录")

        // 有待办清单时：路线图画清单，思维链还是实际做的最新三步（不是清单里还没做的）；等你时第一句还是等你批准
        var planned = parse
        planned.plan = [RoadPlanItem(text: "读代码", status: .completed), RoadPlanItem(text: "改登录", status: .inProgress),
                        RoadPlanItem(text: "写测试", status: .pending), RoadPlanItem(text: "跑测试", status: .pending)]
        let withPlan = SessionSnapshot.build(sessions: [session("p", .running), session("q", .waiting, ago: 5)], now: now,
                                             parse: { _ in planned }, title: { _ in "" })["sessions"] as? [[String: Any]] ?? []
        let p = withPlan.first { $0["id"] as? String == "p" } ?? [:]
        check(p["plan"] as? Bool == true && (p["steps"] as? [[String: Any]])?.count == 4 && p["actions"] as? [String] == ["改 B.swift（进行中）", "跑测试 test.sh · 过了", "读 A.swift"],
              "有待办清单：路线图画清单，思维链是实际做的最新三步")
        check((withPlan.first { $0["id"] as? String == "q" }?["actions"] as? [String])?.first == "等你批准", "有待办清单时等你：第一句还是等你批准")

        // ZCode 的「想」（明文推理）不发；在等你回答时不和「提问」说两遍
        var thinking = parse
        thinking.actions.insert(RoadAction(kind: .think, object: "我在想用户的密码", done: true), at: 0)
        thinking.actions.append(RoadAction(kind: .ask, object: "等你回答"))
        var asking = session("z", .waiting, agent: "zcode")
        asking.waitReason = "question"
        let z = (SessionSnapshot.build(sessions: [asking], now: now, parse: { _ in thinking }, title: { _ in "" })["sessions"] as? [[String: Any]])?.first ?? [:]
        let zText = String(data: (try? JSONSerialization.data(withJSONObject: z)) ?? Data(), encoding: .utf8) ?? ""
        check(!zText.contains("密码") && (z["actions"] as? [String])?.first == "等你回答" && (z["actions"] as? [String])?.filter { $0.hasPrefix("提问") }.isEmpty == true,
              "ZCode 的想不发到别的机器；等你回答不说两遍")
        var scratch = session("s", .running)
        scratch.cwd = "/Users/me/Library/Application Support/Claude/scratch-workspaces/x/y"
        check(SessionSnapshot.project(scratch) == "" && SessionSnapshot.project(session("r", .running)) == "proj-r", "临时文件夹不当项目名")
    }
}
