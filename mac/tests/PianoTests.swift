import AVFoundation
import AppKit

/// 小猫的家里的钢琴：音高换算、琴键命中（和弦、松一个、滑音、取消）、换八度、进出钢琴页时声音的开关、系统钢琴音色真能出声
enum PianoTests {
    final class FakeSound: PianoSound {
        var started = 0, stopped = 0, silenced = 0
        var downs: [UInt8] = [], ups: [UInt8] = []
        var fail = false
        func start() throws { if fail { throw NSError(domain: "test", code: 1) }; started += 1 }
        func stop() { stopped += 1 }
        func silence() { silenced += 1 }
        func down(_ note: UInt8) { downs.append(note) }
        func up(_ note: UInt8) { ups.append(note) }
    }

    final class Recorder: PianoViewDelegate {
        var events: [String] = []
        func pianoView(didKeyDown key: PianoKey, at index: Int, type: PianoKey.KeyType) { events.append("+\(type == .white ? "w" : "b")\(key.octave * 10 + index)") }
        func pianoView(didKeyUp key: PianoKey, at index: Int, type: PianoKey.KeyType) { events.append("-\(type == .white ? "w" : "b")\(key.octave * 10 + index)") }
    }

    @MainActor
    static func run(now: Date, rows: [Provider], check: (Bool, String) -> Void) {
        // ---------- 音高 ----------
        check(PianoNotes.midi(base: 5, octave: 0, index: 0, type: .white) == 60 && PianoNotes.midi(base: 5, octave: 1, index: 6, type: .white) == 83
              && PianoNotes.midi(base: 5, octave: 0, index: 0, type: .black) == 61, "从中央 C 开始：C4=60，第二组的 B 是 B5=83，第一个黑键是 C#4")
        check(PianoNotes.midi(base: 5, octave: 0, index: 7, type: .white) == nil && PianoNotes.midi(base: 5, octave: 0, index: 5, type: .black) == nil
              && PianoNotes.midi(base: 9, octave: 0, index: 0, type: .white) == nil && PianoNotes.midi(base: 5, octave: -1, index: 0, type: .white) == nil,
              "越界的键、八度不算")
        check(PianoNotes.midi(base: PianoNotes.highest, octave: 1, index: 6, type: .white).map { $0 <= 127 } == true, "最高八度的最高音还在 MIDI 范围里")
        check(PianoNotes.range(base: 5) == "C4–B5", "音域写法")

        // ---------- 琴键命中 ----------
        let view = PianoView(numberOfWhiteKeys: 14, frame: NSRect(x: 0, y: 0, width: 490, height: 30))
        let recorder = Recorder()
        view.delegate = recorder
        let w = view.whiteKeyWidth
        func white(_ i: Int) -> CGPoint { CGPoint(x: w * (CGFloat(i) + 0.5), y: 4) }      // 白键下半截（黑键碰不到的地方）
        func black(_ i: Int) -> CGPoint { CGPoint(x: w * CGFloat(i + 1), y: 26) }         // 第 i 个白键右边的黑键
        check(view.keyIndex(at: CGPoint(x: -1, y: 10)) == nil && view.keyIndex(at: CGPoint(x: 491, y: 10)) == nil && view.keyIndex(at: CGPoint(x: 10, y: 31)) == nil,
              "琴键外面不出声")
        view.updateKeysState(with: [white(0), white(2), white(4)])
        check(Set(recorder.events) == ["+w0", "+w2", "+w4"], "三个手指：C 大三和弦（C、E、G）")
        recorder.events = []
        view.updateKeysState(with: [white(0), white(4)])
        check(recorder.events == ["-w2"], "松开一个手指：只停那一个，另外两个照响")
        recorder.events = []
        view.updateKeysState(with: [white(0), black(3)])
        check(recorder.events == ["-w4", "+b2"], "滑到黑键：先停原来的音，再按 F#（第 3 个黑键）")
        recorder.events = []
        view.updateKeysState(with: [white(7)])
        check(Set(recorder.events) == ["-w0", "-b2", "+w10"], "第二组的 C 是第二个八度（octave 1）")
        view.releaseAll()
        check(view.whiteKeys.allSatisfy { $0.state == .up } && view.blackKeys.allSatisfy { $0.state == .up }, "全部放开（取消、收起时）")
        view.updateKeysState(with: [white(1)])
        recorder.events = []
        view.setFrameSize(NSSize(width: 400, height: 30))
        check(recorder.events == ["-w1"], "尺寸变了：先把按着的放开")
        view.setLabels([0: "C4", 7: "C5"])
        check(view.labelsForTesting == ["C4", "C5"], "每组的 C 上写音名")

        // ---------- 钢琴面板：假音源 ----------
        let fake = FakeSound()
        let saved = PianoPanel.makeSound
        PianoPanel.makeSound = { fake }
        defer { PianoPanel.makeSound = saved }
        let panel = PianoPanel()
        var presses: [Bool] = []
        panel.onPress = { presses.append($0) }
        check(PianoPanel.keysWidth + TouchBarItem.backWidth + TouchBarItem.detailSpacing * 3 + PianoPanel.buttonWidth * 2 == TouchBarItem.detailWidth,
              "返回键、低八度、琴键、高八度正好一整条（610pt）")
        let kw = PianoPanel.keysWidth / CGFloat(PianoPanel.whiteKeys)
        check(kw >= 34, "白键至少 34pt 宽，手指按得准（\(kw)）")
        panel.keys.updateKeysState(with: [CGPoint(x: kw * 0.5, y: 4)])
        check(fake.downs.isEmpty && presses == [true], "没进钢琴页（没开引擎）时不出声，但按下照样算手指在上面")
        panel.keys.releaseAll()
        panel.activate()
        check(fake.started == 1 && panel.active, "进钢琴页：开引擎")
        panel.keys.updateKeysState(with: [CGPoint(x: kw * 0.5, y: 4), CGPoint(x: kw * 2.5, y: 4)])
        check(fake.downs == [60, 64] && panel.downCountForTesting == 2 && presses == [true, false, true], "按下 C4、E4 出声；第一个键按下时通知「手指在上面」")
        panel.keys.updateKeysState(with: [])
        check(Set(fake.ups) == [60, 64] && presses.last == false && panel.downCountForTesting == 0, "都松开：停音，通知「手指离开」")
        panel.shift(1)
        check(panel.base == 6 && panel.keys.labelsForTesting == ["C5", "C6"] && fake.silenced >= 1, "高八度：C5–B6，换之前先静音")
        panel.keys.updateKeysState(with: [CGPoint(x: kw * 0.5, y: 4)])
        check(fake.downs.last == 72, "高一个八度的 C 是 C5=72")
        panel.keys.releaseAll()
        for _ in 0..<10 { panel.shift(1) }
        check(panel.base == PianoNotes.highest && !panel.higher.isEnabled && panel.lower.isEnabled, "到最高就不能再高（按钮变灰）")
        for _ in 0..<10 { panel.shift(-1) }
        check(panel.base == PianoNotes.lowest && !panel.lower.isEnabled && panel.higher.isEnabled, "到最低就不能再低")
        panel.keys.updateKeysState(with: [CGPoint(x: kw * 0.5, y: 4)])
        panel.deactivate()
        check(fake.stopped == 1 && !panel.active && panel.downCountForTesting == 0 && panel.sound != nil, "离开钢琴页：放开所有键、停引擎，音源先留着")
        let broken = FakeSound()
        broken.fail = true
        PianoPanel.makeSound = { broken }
        let failing = PianoPanel()
        failing.activate()
        check(failing.failure != nil && failing.keys.accessibilityLabel()?.contains("音源没开起来") == true, "音源开不起来：不崩，读屏说清楚")
        PianoPanel.makeSound = { fake }

        // ---------- 在展开条里：小猫的家 → 钢琴页 → 返回 ----------
        let bar = TouchBarItem()
        bar.pretendShownForTesting()
        bar.update(rows: rows, lights: [], tasks: [], now: now)
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "pet" } ?? 0)
        check(bar.shown.map(\.id).contains("piano") && bar.shown.map(\.id).suffix(2) == ["piano", "pet:pat"], "小猫的家里有「钢琴」，在「摸摸」前面")
        let startedBefore = fake.started
        bar.tapForTesting(bar.shown.firstIndex { $0.id == "piano" } ?? 0)
        if case .piano = bar.page {} else { check(false, "点「钢琴」进钢琴页") }
        check(bar.pianoShownForTesting && fake.started == startedBefore + 1, "钢琴页：琴键换掉那一排，引擎开了")
        bar.piano.keys.updateKeysState(with: [CGPoint(x: kw * 0.5, y: 4)])
        check(bar.hasTouchSnapshotForTesting, "按着琴键：当成手指在上面（不换页、不自动收起）")
        bar.piano.keys.updateKeysState(with: [])
        check(bar.settlingForTesting, "松开：和松开手指一样收尾")
        bar.settleForTesting(generation: bar.touchGenerationForTesting)
        check(!bar.settlingForTesting && !bar.hasTouchSnapshotForTesting, "收尾完（不等真的 0.3 秒）")
        if case .piano = bar.page {} else { check(false, "松手收尾时还在钢琴页（不被数据刷新换走）") }
        bar.piano.touchedForTesting(at: Date())
        let closes = bar.closeRequestsForTesting
        bar.closeTimerFiredForTesting()
        check(bar.closeRequestsForTesting == closes, "刚弹过：到时间也不收起")
        bar.piano.touchedForTesting(at: Date().addingTimeInterval(-TouchBarItem.pianoIdleClose - 1))
        bar.closeTimerFiredForTesting()
        check(bar.closeRequestsForTesting == closes + 1, "两分钟没碰：收起")
        let stoppedBefore = fake.stopped
        bar.backForTesting()
        if case .pet = bar.page {} else { check(false, "钢琴页返回小猫的家") }
        check(!bar.pianoShownForTesting && fake.stopped == stoppedBefore + 1, "离开钢琴页：换回那一排、停掉声音")
        bar.openPage(named: "piano")
        if case .piano = bar.page {} else { check(false, "广播 piano 直接打开钢琴页") }
        let stopsBeforeHide = fake.stopped
        bar.piano.keys.updateKeysState(with: [CGPoint(x: kw * 0.5, y: 4)])   // 按着键的时候收起
        bar.detailHiddenForTesting()
        check(fake.stopped == stopsBeforeHide + 1 && bar.piano.downCountForTesting == 0, "展开条收起：放开按着的键、停掉声音")
        check(!bar.settlingForTesting, "收起时放开键不再报一次「松手」（不挡住收起后的检查）")
        if case .piano = bar.page { check(false, "收起后离开钢琴页") }
        let startsAfterHide = fake.started
        bar.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(20))
        bar.update(rows: rows, lights: [], tasks: [], now: now.addingTimeInterval(40))
        check(fake.started == startsAfterHide && !bar.piano.active && !bar.pianoShownForTesting, "收起之后的数据刷新不会把引擎重新打开")
        // 刚进钢琴页、还没弹：到 45 秒的收起时间也不收（进页算碰过一次）
        bar.openPage(named: "piano")
        let closesAtEntry = bar.closeRequestsForTesting
        bar.closeTimerFiredForTesting()
        check(bar.closeRequestsForTesting == closesAtEntry, "刚进钢琴页没弹：不会 45 秒就收起")

        // ---------- 真的音源：系统钢琴音色能出声（离线渲染，不用扬声器）----------
        do {
            let audio = try PianoAudio()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            audio.engine.stop()
            try audio.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try audio.start()
            audio.down(60)
            audio.down(60)
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.engine.manualRenderingFormat, frameCapacity: 4096)!
            var peak: Float = 0
            for _ in 0..<5 {
                _ = try audio.engine.renderOffline(4096, to: buffer)
                if let data = buffer.floatChannelData?[0] { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) } }
            }
            check(peak > 0.001 && peak < 1, "系统钢琴音色真的出声（峰值 \(peak)），没有爆音")
            audio.up(60)
            check(audio.held[60] == 1, "同一个音两处按着：松开一处还在响")
            audio.up(60)
            check(audio.held.isEmpty, "两处都松开才停")
            audio.stop()
            check(!audio.engine.isRunning, "停掉引擎")
        } catch {
            check(false, "系统钢琴音色加载 / 离线渲染失败：\(error)")
        }
    }
}
