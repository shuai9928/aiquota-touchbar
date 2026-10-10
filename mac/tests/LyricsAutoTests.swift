import AppKit

// 看视频时自动展开歌词：只在 Chrome 在前台、在放、有词时弹；还在自动弹的歌词页时，暂停、停了、切走就收起；
// 手动收起（点小图标或系统的 ×）后这首不再弹，换一首或切走再回来会再弹；Chrome 和 Claude/Codex 之间切换时和指令条原地互换；
// 手动点小图标时歌词优先于指令条；扩展每秒的心跳让「还在放」跟上。
enum LyricsAutoTests {
    final class Recorder {
        var presented = 0
        var allowed = true
    }

    @MainActor
    static func run(now _: Date, rows: [Provider], check: (Bool, String) -> Void) {
        let chrome = "com.google.Chrome", finder = "com.apple.finder", claude = "com.anthropic.claudefordesktop"
        let song = { (title: String, playing: Bool) in
            NowLyric(site: "bilibili", title: title, line: "风到这里就是粘", next: "粘住过客的思念", kind: "lyrics", playing: playing, received: Date())
        }
        let recorder = Recorder()
        let bar = TouchBarItem()
        bar.presenter = { _ in recorder.presented += 1 }
        bar.presentationAllowed = { true }
        bar.pretendShownForTesting()
        // 每次 update 往后拨 10 秒，免得撞上「刚弹出 2 秒内不再弹」；真实时间只用来判断歌词新不新鲜
        var t = Date()
        let play = { (lyric: NowLyric?) in
            t += 10
            bar.update(rows: rows, lights: [], tasks: [], now: t, lyric: lyric)
        }
        let front = { (bundle: String) in
            bar.frontAppChanged(bundle, promptApp: PromptTargets.resolve(bundle, own: nil).app, autoShow: true)
        }
        let onLyrics = { () -> Bool in if case .lyrics = bar.page { return true }; return false }

        // 弹和收
        front(finder)
        play(song("江南", true))
        check(recorder.presented == 0, "Chrome 不在前台时不自动弹歌词")
        front(chrome)
        check(recorder.presented == 1 && bar.lyricAutoForTesting && onLyrics(), "切到 Chrome、正在放，自动展开歌词页")
        bar.visibleForTesting = true
        play(song("江南", true))
        check(recorder.presented == 1 && bar.closeRequestsForTesting == 0, "换句不重复弹、不收")
        play(song("江南", false))
        check(bar.closeRequestsForTesting == 1 && !bar.lyricAutoForTesting, "暂停就收起自动弹的歌词")
        bar.visibleForTesting = false
        bar.detailHiddenForTesting()                        // App 自己收的，不算用户关
        play(song("江南", true))
        check(recorder.presented == 2 && bar.lyricAutoForTesting, "接着放又弹出来")
        bar.visibleForTesting = true
        front(finder)
        check(bar.closeRequestsForTesting == 2 && !bar.lyricAutoForTesting, "切到别的 app 就收起")
        bar.visibleForTesting = false
        bar.detailHiddenForTesting()
        play(song("江南", true))
        check(recorder.presented == 2, "在别的 app 里放着也不弹，只留 ♪")

        // 关掉视频标签、换视频（扩展发 none，歌词没了）：收起，而不是停在总览上挡住下一首
        front(chrome)
        check(recorder.presented == 3, "回到 Chrome 再弹")
        bar.visibleForTesting = true
        play(nil)
        check(bar.closeRequestsForTesting == 3, "歌词没了就收起")
        bar.visibleForTesting = false
        bar.detailHiddenForTesting()
        play(song("交换余生", true))
        check(recorder.presented == 4, "下一首接着弹")

        // 系统的 ×（没有回调，收起时没有 App 自己收的记号）：这首不再弹
        bar.visibleForTesting = false
        bar.detailHiddenForTesting()
        play(song("交换余生", true))
        check(recorder.presented == 4 && !bar.lyricAutoForTesting, "点 × 收起后这首不再弹")
        play(song("可惜没如果", true))
        check(recorder.presented == 5, "换一首会再弹")
        // 点小图标收起也一样
        bar.visibleForTesting = true
        bar.tapGlanceForTesting()
        bar.visibleForTesting = false
        bar.detailHiddenForTesting()
        play(song("可惜没如果", true))
        check(recorder.presented == 5, "点小图标收起后这首不再弹")
        play(song("交换余生", true))
        check(recorder.presented == 6, "关过 A、放 B 时关了 B，再放 A 还会弹（换歌就清掉记录）")
        bar.visibleForTesting = false
        bar.detailHiddenForTesting()
        play(song("交换余生", true))
        check(recorder.presented == 6, "点 × 关掉 A 后 A 不再弹")
        front(finder)
        front(chrome)
        check(recorder.presented == 7, "切走再回到 Chrome，关过的这首也会再弹")

        // 翻到总览再关：还是算手动关（自动弹的记号跟到真正收起为止），也不替用户收总览
        bar.visibleForTesting = true
        bar.backForTesting()
        play(song("交换余生", true))
        check(bar.lyricAutoForTesting && bar.closeRequestsForTesting == 4, "翻到总览后不替用户收")
        play(song("交换余生", false))
        check(bar.closeRequestsForTesting == 4, "在总览上暂停也不收")
        play(song("交换余生", true))
        bar.visibleForTesting = false
        bar.detailHiddenForTesting()
        play(song("交换余生", true))
        check(recorder.presented == 7, "从总览点 × 关掉，这首也不再弹")

        // 手指按着时不收，松手后再收
        play(song("美人鱼", true))
        check(recorder.presented == 8, "新歌弹出")
        bar.visibleForTesting = true
        bar.beginInteractionForTesting()
        play(song("美人鱼", false))
        check(bar.lyricAutoForTesting && bar.closeRequestsForTesting == 4, "按着时暂停先不收")
        bar.endInteractionForTesting()
        bar.settleForTesting(generation: bar.touchGenerationForTesting)
        check(!bar.lyricAutoForTesting && bar.closeRequestsForTesting == 5, "松手后收起")
        bar.visibleForTesting = false
        bar.detailHiddenForTesting()

        // Chrome ⇄ Claude：和指令条原地互换，不重新弹出
        play(song("美人鱼", true))
        check(recorder.presented == 9, "接着放又弹")
        bar.visibleForTesting = true
        front(claude)
        if case .prompts = bar.page {
            check(bar.promptAutoForTesting && !bar.lyricAutoForTesting, "切到 Claude 时歌词原地换成指令条")
        } else {
            check(false, "切到 Claude 时歌词原地换成指令条")
        }
        front(chrome)
        check(onLyrics() && bar.lyricAutoForTesting && !bar.promptAutoForTesting, "切回 Chrome 时指令条原地换回歌词")
        check(recorder.presented == 9 && bar.closeRequestsForTesting == 5, "互换时不收起、不重新弹出")

        // 手动点小图标：在放歌就先看歌词（比指令条优先）；手动打开的不替用户收
        front(claude)
        bar.visibleForTesting = false
        bar.tapGlanceForTesting()
        check(onLyrics() && !bar.lyricAutoForTesting, "在 Claude 里放着歌，点小图标先看歌词，不算自动弹")
        bar.visibleForTesting = true
        let closes = bar.closeRequestsForTesting
        play(song("美人鱼", false))
        check(bar.closeRequestsForTesting == closes, "手动打开的歌词页暂停时不自动收")
        bar.backForTesting()
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "tools" } ?? 0)
        check(bar.shown.map(\.id).contains("prompts"), "从歌词页返回 AI 页，点「工具」就能进指令条")

        // 换歌就清掉「不再弹」：关过 A，B 放完（App 自己收的），再放 A 会弹；
        // App 自己收起（比如翻到总览后 45 秒到时间）不算用户关，歌还在放就接着弹
        let replay = TouchBarItem()
        let replayShown = Recorder()
        replay.presenter = { _ in replayShown.presented += 1 }
        replay.presentationAllowed = { true }
        replay.pretendShownForTesting()
        var t2 = Date()
        let play2 = { (lyric: NowLyric?) in
            t2 += 10
            replay.update(rows: rows, lights: [], tasks: [], now: t2, lyric: lyric)
        }
        replay.frontAppChanged(chrome, promptApp: nil, autoShow: true)
        play2(song("江南", true))
        replay.detailHiddenForTesting()                     // 用户点 × 关掉 A
        play2(song("江南", true))
        check(replayShown.presented == 1, "关掉 A 后 A 不再弹")
        play2(song("修炼爱情", true))
        check(replayShown.presented == 2, "B 弹出")
        replay.visibleForTesting = true
        play2(song("修炼爱情", false))
        replay.visibleForTesting = false
        replay.detailHiddenForTesting()                     // B 暂停，App 自己收的
        play2(song("江南", true))
        check(replayShown.presented == 3, "放过 B 以后再放 A 会弹")
        replay.visibleForTesting = true
        replay.backForTesting()
        play2(song("江南", true))
        replay.closeTimerFiredForTesting()                  // 总览 45 秒没动，App 自己收起
        replay.visibleForTesting = false
        replay.detailHiddenForTesting()
        check(replayShown.presented == 4 && replay.lyricAutoForTesting, "App 自己收起不算用户关，歌还在放就接着弹歌词")
        replay.tapGlanceForTesting()                        // 点了 ×、系统的通知还没到就又点开
        replay.visibleForTesting = true
        let closesBefore = replay.closeRequestsForTesting
        play2(song("江南", false))
        check(replay.closeRequestsForTesting == closesBefore, "× 后马上手动点开的算手动打开，暂停时不替用户收")

        // 从歌词条去别处（点额度卡开菜单栏面板、打开 Claude、终端……）：收起后不马上又弹回来，到了那边再切回 Chrome 才再弹；
        // AIQuota 自己的面板在前台时不新弹，已经弹着的也不收
        let hand = TouchBarItem()
        let handShown = Recorder()
        hand.presenter = { _ in handShown.presented += 1 }
        hand.presentationAllowed = { handShown.allowed }
        hand.pretendShownForTesting()
        var t3 = Date()
        let play3 = { (lyric: NowLyric?) in
            t3 += 10
            hand.update(rows: rows, lights: [], tasks: [], now: t3, lyric: lyric)
        }
        let own = "local.aiquota.menubar"
        hand.frontAppChanged(chrome, promptApp: nil, autoShow: true)
        play3(song("江南", true))
        hand.visibleForTesting = true
        hand.backForTesting()
        check(hand.shown.first?.id == "quota", "总览第一块是额度表")
        hand.tapForTesting(0)                               // 额度表：进额度页（不收起）
        check(hand.closeRequestsForTesting == 0 && hand.shown.first?.id.hasPrefix("provider:") == true, "点额度表进额度页")
        hand.tapForTesting(0)                               // 额度页上的卡：打开菜单栏面板
        check(hand.closeRequestsForTesting == 1, "点额度页上的卡先收起")
        hand.visibleForTesting = false
        hand.detailHiddenForTesting()
        play3(song("江南", true))                            // 10 秒后面板还没到前台（不靠「刚弹出 2 秒内」挡着）
        check(handShown.presented == 1, "去面板时歌词不马上弹回来")
        hand.ownAppFront(own)
        play3(song("江南", true))
        check(handShown.presented == 1, "面板在前台时不弹")
        hand.frontAppChanged(chrome, promptApp: nil, autoShow: true)
        check(handShown.presented == 2 && hand.lyricAutoForTesting, "面板关了回到 Chrome 再弹")
        hand.visibleForTesting = true
        hand.ownAppFront(own)
        play3(song("江南", true))
        check(hand.closeRequestsForTesting == 1 && hand.lyricAutoForTesting, "打开菜单栏面板时，已经弹着的歌词不收")
        hand.frontAppChanged(chrome, promptApp: nil, autoShow: true)

        // 手指按着时关掉视频（扩展发 none）：松手后收起，不停在总览上挡住下一首
        hand.beginInteractionForTesting()
        play3(nil)
        check(hand.closeRequestsForTesting == 1 && hand.lyricAutoForTesting, "按着时歌没了先不收")
        hand.endInteractionForTesting()
        hand.settleForTesting(generation: hand.touchGenerationForTesting)
        check(hand.closeRequestsForTesting == 2 && !hand.lyricAutoForTesting, "松手后收起")
        hand.visibleForTesting = false
        hand.detailHiddenForTesting()
        play3(song("交换余生", true))
        check(handShown.presented == 3, "下一首照常弹")

        // Chrome 的触控栏设成只显示 F 键（系统不让弹）：从 Claude 切回来时指令条不换成歌词，直接收起
        hand.visibleForTesting = true
        hand.frontAppChanged(claude, promptApp: "Claude", autoShow: true)
        handShown.allowed = false
        hand.frontAppChanged(chrome, promptApp: nil, autoShow: true)
        check(!hand.lyricAutoForTesting && hand.closeRequestsForTesting == 3, "系统不让弹的 app 不换成歌词")

        // 心跳：内容没变时只刷新收到时间，前奏、间奏再长也算在放；切回 Chrome 时不用等换句
        let quietBar = TouchBarItem()
        let quiet = Recorder()
        quietBar.presenter = { _ in quiet.presented += 1 }
        quietBar.presentationAllowed = { true }
        quietBar.pretendShownForTesting()
        var stale = song("江南", true)
        stale.received = Date().addingTimeInterval(-30)
        quietBar.update(rows: rows, lights: [], tasks: [], now: Date(), lyric: stale)
        quietBar.frontAppChanged(chrome, promptApp: nil, autoShow: true)
        check(quiet.presented == 0, "上一次内容变化是 30 秒前、又没心跳：当成停了")
        quietBar.refreshLyric(song("江南", true))
        check(quiet.presented == 1, "心跳一到就弹")

        // 刚弹出别的页（比如翻译），系统还没显示出来时，不抢
        let busy = TouchBarItem()
        let busyShown = Recorder()
        busy.presenter = { _ in busyShown.presented += 1 }
        busy.presentationAllowed = { true }
        busy.pretendShownForTesting()
        let at = Date()
        busy.update(rows: rows, lights: [], tasks: [], now: at, lyric: nil)
        busy.frontAppChanged(chrome, promptApp: nil, autoShow: true)
        busy.showTranslation()
        busy.update(rows: rows, lights: [], tasks: [], now: at, lyric: song("江南", true))
        if case .translation = busy.page { check(busyShown.presented == 1, "刚弹出的翻译不被歌词抢走") } else { check(false, "刚弹出的翻译不被歌词抢走") }

        // 前台 app 的触控栏设成不显示 app 控件（系统不让弹）、菜单栏里关掉触控栏时都不弹
        let blocked = TouchBarItem()
        let blockedShown = Recorder()
        blocked.presenter = { _ in blockedShown.presented += 1 }
        blocked.presentationAllowed = { false }
        blocked.pretendShownForTesting()
        blocked.frontAppChanged(chrome, promptApp: nil, autoShow: true)
        blocked.update(rows: rows, lights: [], tasks: [], now: Date(), lyric: song("江南", true))
        check(blockedShown.presented == 0, "系统不让弹出时不弹")
        let off = TouchBarItem()
        off.presenter = { _ in blockedShown.presented += 1 }
        off.presentationAllowed = { true }
        off.frontAppChanged(chrome, promptApp: nil, autoShow: true)
        off.update(rows: rows, lights: [], tasks: [], now: Date(), lyric: song("江南", true))
        check(blockedShown.presented == 0, "触控栏关掉时不弹")
    }
}
