// 小猫的家里的钢琴：点「钢琴」，整条触控栏换成两个八度的琴键（左边返回键、两头换八度），用 macOS 自带的钢琴音色发声。
// 琴键和音源改编自 p-x9/pock-piano-widget（MIT，见 LICENSE.piano-upstream；上游基线 8df0f73），
// 经过本机独立版 Touch Bar Piano（~/Documents/Codex/2026-09-28/ni/work/touchbar-piano）的修正：
// 只认还按着的手指、取消 / 换八度 / 收起时放开所有音、限制八度和 MIDI 范围、同一个音两处按着要都松开才停。
// 只在钢琴页开着时才开音频引擎；离开、收起就停，两分钟没再用就把音源放掉（AIQuota 一直开着，不常驻几十 MB 的采样）。

import AVFoundation
import AppKit

// MARK: - 音源

protocol PianoSound: AnyObject {
    func start() throws
    func stop()
    func silence()
    func down(_ note: UInt8)
    func up(_ note: UInt8)
}

final class PianoAudio: PianoSound {
    let sampler = AVAudioUnitSampler()
    let engine = AVAudioEngine()
    private(set) var held: [UInt8: Int] = [:]
    private var wanted = false
    private var observer: NSObjectProtocol?
    static let volume: Float = 0.25                 // 钢琴自己的音量，不动系统音量（系统音量用右边的音量键调）

    init() throws {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = Self.volume
        let bank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        try sampler.loadSoundBankInstrument(at: bank, program: 0, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
        // 换了输出设备（插拔耳机、蓝牙）引擎会停：放开所有音，还在弹就重新开
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.silence()
            if self.wanted { try? self.engine.start() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.stop()
    }

    func start() throws {
        wanted = true
        if !engine.isRunning { try engine.start() }
    }

    func stop() {
        wanted = false
        silence()
        engine.stop()
    }

    func silence() {
        for note in held.keys { sampler.stopNote(note, onChannel: 0) }
        held.removeAll()
        sampler.sendController(123, withValue: 0, onChannel: 0)   // All Notes Off
        sampler.sendController(120, withValue: 0, onChannel: 0)   // All Sound Off
    }

    func down(_ note: UInt8) {
        guard note < 128, engine.isRunning else { return }
        let count = held[note, default: 0]
        held[note] = count + 1
        if count == 0 { sampler.startNote(note, withVelocity: 90, onChannel: 0) }
    }

    func up(_ note: UInt8) {
        guard let count = held[note] else { return }
        if count > 1 { held[note] = count - 1 }
        else { held[note] = nil; sampler.stopNote(note, onChannel: 0) }
    }
}

enum PianoNotes {
    /// base 是起始八度（5 = 从中央 C 开始），octave 是琴键在第几组，index 是组里第几个白键 / 黑键
    static func midi(base: Int, octave: Int, index: Int, type: PianoKey.KeyType) -> UInt8? {
        let steps = type == .white ? [0, 2, 4, 5, 7, 9, 11] : [1, 3, 6, 8, 10]
        guard steps.indices.contains(index), (0...8).contains(base), (0...3).contains(octave) else { return nil }
        let value = base * 12 + octave * 12 + steps[index]
        return (0...127).contains(value) ? UInt8(value) : nil
    }

    static let lowest = 2, highest = 7               // C1–B2 到 C6–B7

    /// 「C4–B5」这样的音域（科学音高记法：MIDI 60 是 C4）
    static func range(base: Int) -> String { "C\(base - 1)–B\(base)" }
}

// MARK: - 琴键（改编自 p-x9/pock-piano-widget，MIT）

final class PianoKey: NSObject {
    enum KeyType { case white, black }
    enum State { case up, down }

    let type: KeyType
    var octave = 0
    let layer = CALayer()
    var state: State = .up {
        didSet { layer.backgroundColor = (state == .up ? color : NSColor.systemTeal).cgColor }
    }
    var color: NSColor { type == .white ? .white : .black }

    init(type: KeyType) {
        self.type = type
        super.init()
        layer.backgroundColor = color.cgColor
        layer.borderWidth = 1
        layer.borderColor = NSColor.black.cgColor
        layer.cornerRadius = 2
        layer.maskedCorners = [.layerMaxXMinYCorner, .layerMinXMinYCorner]
    }
}

@MainActor
protocol PianoViewDelegate: AnyObject {
    func pianoView(didKeyDown key: PianoKey, at index: Int, type: PianoKey.KeyType)
    func pianoView(didKeyUp key: PianoKey, at index: Int, type: PianoKey.KeyType)
}

final class PianoView: NSView {
    private(set) var numberOfWhiteKeys: Int
    private(set) var whiteKeys: [PianoKey] = []
    private(set) var blackKeys: [PianoKey] = []
    private var labelLayers: [CATextLayer] = []
    weak var delegate: PianoViewDelegate?

    var whiteKeyWidth: CGFloat { frame.width / CGFloat(numberOfWhiteKeys) }
    var blackKeyWidth: CGFloat { whiteKeyWidth * 0.6 }
    var blackKeyHeight: CGFloat { frame.height * 0.6 }

    init(numberOfWhiteKeys: Int, frame: CGRect) {
        self.numberOfWhiteKeys = max(7, min(28, numberOfWhiteKeys))
        super.init(frame: frame)
        wantsLayer = true
        allowedTouchTypes = [.direct]
        for index in 0..<self.numberOfWhiteKeys {
            let key = PianoKey(type: .white)
            key.octave = index / 7
            whiteKeys.append(key)
            layer?.addSublayer(key.layer)
        }
        for index in 0..<self.numberOfWhiteKeys where hasBlackKeyAtRight(for: index) {
            let key = PianoKey(type: .black)
            key.octave = index / 7
            blackKeys.append(key)
            layer?.addSublayer(key.layer)
        }
        layoutKeys()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        layoutKeys()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { releaseAll(); layoutKeys() }       // 尺寸变了，按着的位置对不上了：先全放开
    }

    private func layoutKeys() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = whiteKeyWidth
        for (index, key) in whiteKeys.enumerated() {
            key.layer.frame = CGRect(x: width * CGFloat(index), y: 0, width: width, height: frame.height)
        }
        var black = 0
        for index in 0..<numberOfWhiteKeys where hasBlackKeyAtRight(for: index) {
            let key = blackKeys[black]
            key.layer.removeFromSuperlayer()
            layer?.addSublayer(key.layer)                   // 黑键压在白键上面
            key.layer.frame = CGRect(x: width * CGFloat(index + 1) - blackKeyWidth / 2, y: frame.height - blackKeyHeight,
                                     width: blackKeyWidth, height: blackKeyHeight)
            black += 1
        }
        for label in labelLayers { label.removeFromSuperlayer(); layer?.addSublayer(label) }
        CATransaction.commit()
    }

    /// 在白键底部写小字（每组的 C 写音名，看得出现在弹的是哪个八度）
    func setLabels(_ labels: [Int: String]) {
        for label in labelLayers { label.removeFromSuperlayer() }
        labelLayers = labels.sorted { $0.key < $1.key }.compactMap { index, text in
            guard whiteKeys.indices.contains(index) else { return nil }
            let label = CATextLayer()
            label.string = text
            label.font = NSFont.systemFont(ofSize: 8, weight: .medium)
            label.fontSize = 8
            label.foregroundColor = NSColor(white: 0.45, alpha: 1).cgColor
            label.alignmentMode = .center
            label.contentsScale = 2
            label.frame = CGRect(x: whiteKeyWidth * CGFloat(index), y: 1, width: whiteKeyWidth, height: 10)
            layer?.addSublayer(label)
            return label
        }
        needsLayout = true
    }

    var labelsForTesting: [String] { labelLayers.compactMap { $0.string as? String } }

    // MARK: 触摸：只认还按着的手指（结束、取消的不算）

    override func touchesBegan(with event: NSEvent) { super.touchesBegan(with: event); updateKeysState(with: event) }
    override func touchesMoved(with event: NSEvent) { super.touchesMoved(with: event); updateKeysState(with: event) }
    override func touchesEnded(with event: NSEvent) { super.touchesEnded(with: event); updateKeysState(with: event) }
    override func touchesCancelled(with event: NSEvent) { super.touchesCancelled(with: event); updateKeysState(with: event) }

    override func mouseDown(with event: NSEvent) { updateKeysState(with: [convert(event.locationInWindow, from: nil)]) }
    override func mouseDragged(with event: NSEvent) { updateKeysState(with: [convert(event.locationInWindow, from: nil)]) }
    override func mouseUp(with event: NSEvent) { releaseAll() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { releaseAll() }
    }

    func releaseAll() { updateKeysState(with: [CGPoint]()) }

    private func updateKeysState(with event: NSEvent) {
        let touches = event.touches(matching: .touching, in: self).filter { $0.phase == .began || $0.phase == .moved || $0.phase == .stationary }
        updateKeysState(with: touches.map { $0.location(in: self) })
    }

    func keyIndex(at point: CGPoint) -> (PianoKey.KeyType, Int)? {
        guard bounds.contains(point), whiteKeyWidth > 0 else { return nil }
        let whiteIndex = Int(point.x / whiteKeyWidth)
        guard whiteKeys.indices.contains(whiteIndex) else { return nil }
        for index in (0..<5).map({ $0 + whiteIndex / 7 * 5 }) where blackKeys.indices.contains(index) {
            if blackKeys[index].layer.frame.contains(point) { return (.black, index) }
        }
        return (.white, whiteIndex)
    }

    func updateKeysState(with points: [CGPoint]) {
        var white = Set<Int>(), black = Set<Int>()
        for point in points {
            guard let (type, index) = keyIndex(at: point) else { continue }
            if type == .white { white.insert(index) } else { black.insert(index) }
        }
        // 先松开再按下：滑过去换音时，旧的那个音先停
        for (index, key) in whiteKeys.enumerated() where key.state == .down && !white.contains(index) {
            key.state = .up
            delegate?.pianoView(didKeyUp: key, at: index % 7, type: .white)
        }
        for (index, key) in blackKeys.enumerated() where key.state == .down && !black.contains(index) {
            key.state = .up
            delegate?.pianoView(didKeyUp: key, at: index % 5, type: .black)
        }
        for (index, key) in whiteKeys.enumerated() where key.state == .up && white.contains(index) {
            key.state = .down
            delegate?.pianoView(didKeyDown: key, at: index % 7, type: .white)
        }
        for (index, key) in blackKeys.enumerated() where key.state == .up && black.contains(index) {
            key.state = .down
            delegate?.pianoView(didKeyDown: key, at: index % 5, type: .black)
        }
    }

    func hasBlackKeyAtRight(for index: Int) -> Bool { ![2, 6].contains(index % 7) }
}

// MARK: - 钢琴页（展开条里换掉可滑动的那一排）

@MainActor
final class PianoPanel: NSObject, PianoViewDelegate {
    static var makeSound: () throws -> PianoSound = { try PianoAudio() }
    static let buttonWidth: CGFloat = 34
    static let whiteKeys = 14                        // 两个八度
    /// 返回键之后的整段：低八度 + 琴键 + 高八度
    static var keysWidth: CGFloat {
        TouchBarItem.detailWidth - TouchBarItem.backWidth - TouchBarItem.detailSpacing - 2 * (buttonWidth + TouchBarItem.detailSpacing)
    }
    static let releaseAfter: TimeInterval = 120     // 离开钢琴页这么久没回来，就把音源放掉

    let keys = PianoView(numberOfWhiteKeys: PianoPanel.whiteKeys, frame: NSRect(x: 0, y: 0, width: PianoPanel.keysWidth, height: TouchBarArt.height))
    let view = NSStackView()
    let lower = NSButton(title: "", target: nil, action: nil)
    let higher = NSButton(title: "", target: nil, action: nil)
    private(set) var base = 5                        // 从中央 C（C4）开始，两个八度：C4–B5
    private(set) var sound: PianoSound?
    private(set) var active = false
    private(set) var lastTouch = Date.distantPast
    private(set) var failure: String?
    private var downCount = 0
    private var releaseTimer: Timer?
    /// 第一个键按下（true）/ 所有键都松开（false）：展开条把它当成「手指在上面」，不换页、不自动收起、不弹别的
    var onPress: ((Bool) -> Void)?

    override init() {
        super.init()
        keys.delegate = self
        keys.setAccessibilityLabel("钢琴琴键")
        for (button, action) in [(lower, #selector(lowerOctave)), (higher, #selector(higherOctave))] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: Self.buttonWidth),
                                         button.heightAnchor.constraint(equalToConstant: TouchBarArt.height)])
        }
        keys.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([keys.widthAnchor.constraint(equalToConstant: Self.keysWidth),
                                     keys.heightAnchor.constraint(equalToConstant: TouchBarArt.height)])
        view.orientation = .horizontal
        view.spacing = TouchBarItem.detailSpacing
        view.addArrangedSubview(lower)
        view.addArrangedSubview(keys)
        view.addArrangedSubview(higher)
        refreshOctave()
    }

    /// 进钢琴页：开引擎（第一次进来时才加载音源）
    func activate() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        active = true
        lastTouch = Date()                               // 进钢琴页本身算碰过一次：没弹也不会 45 秒就收起
        do {
            if sound == nil { sound = try Self.makeSound() }
            try sound?.start()
            failure = nil
        } catch {
            failure = error.localizedDescription
            NSLog("[AIQuota] 钢琴音源开不了：\(error.localizedDescription)")
        }
        refreshOctave()
    }

    /// 离开钢琴页、展开条收起：放开所有键、停引擎；过一会儿没回来就把音源放掉。
    /// notify=false：展开条已经收起、「手指在上面」的状态已经清掉了，放开键时不要再报「松手」（不然又会排一次收尾，挡住收起后的检查）
    func deactivate(notify: Bool = true) {
        guard active || sound != nil || downCount > 0 else { return }
        active = false
        let callback = onPress
        if !notify { onPress = nil }
        keys.releaseAll()
        onPress = callback
        downCount = 0
        sound?.stop()
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: Self.releaseAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.active else { return }
                self.sound = nil
            }
        }
    }

    @objc func lowerOctave() { shift(-1) }
    @objc func higherOctave() { shift(1) }

    func shift(_ delta: Int) {
        keys.releaseAll()
        sound?.silence()
        base = min(PianoNotes.highest, max(PianoNotes.lowest, base + delta))
        lastTouch = Date()
        refreshOctave()
    }

    private func refreshOctave() {
        let range = PianoNotes.range(base: base)
        let canLower = base > PianoNotes.lowest, canRaise = base < PianoNotes.highest
        lower.image = TouchBarArt.card("−", subtitle: "八度", width: Self.buttonWidth, enabled: canLower)
        higher.image = TouchBarArt.card("+", subtitle: "八度", width: Self.buttonWidth, enabled: canRaise)
        lower.isEnabled = canLower
        higher.isEnabled = canRaise
        lower.setAccessibilityLabel("低八度（现在 \(range)）")
        higher.setAccessibilityLabel("高八度（现在 \(range)）")
        keys.setLabels([0: "C\(base - 1)", 7: "C\(base)"])
        keys.setAccessibilityLabel("钢琴琴键，\(range)" + (failure.map { "。音源没开起来：" + $0 } ?? ""))
    }

    func pianoView(didKeyDown key: PianoKey, at index: Int, type: PianoKey.KeyType) {
        downCount += 1
        lastTouch = Date()
        if downCount == 1 { onPress?(true) }
        guard active, let note = PianoNotes.midi(base: base, octave: key.octave, index: index, type: type) else { return }
        sound?.down(note)
    }

    func pianoView(didKeyUp key: PianoKey, at index: Int, type: PianoKey.KeyType) {
        downCount = max(0, downCount - 1)
        lastTouch = Date()
        if let note = PianoNotes.midi(base: base, octave: key.octave, index: index, type: type) { sound?.up(note) }
        if downCount == 0 { onPress?(false) }
    }

    var downCountForTesting: Int { downCount }
    #if AIQUOTA_TEST
    func touchedForTesting(at date: Date) { lastTouch = date }
    #endif
}

extension TouchBarItem {
    static let pianoCardWidth: CGFloat = 76

    /// 小猫的家里进钢琴页的那一格
    static var pianoCard: Part {
        Part(image: TouchBarArt.card("钢琴", subtitle: "两个八度", width: pianoCardWidth), action: .piano, id: "piano",
             label: "钢琴：整条触控栏换成两个八度的琴键，用系统自带的钢琴音色")
    }
}

// MARK: - 预览图（--snapshot 用）

extension Snapshot {
    /// 钢琴页：返回键、低八度、两个八度的琴键（按着 C 大三和弦）、高八度
    static func writePiano(dir: String) {
        let panel = PianoPanel()
        let keys = panel.keys
        keys.layoutSubtreeIfNeeded()
        let w = keys.whiteKeyWidth
        keys.updateKeysState(with: [CGPoint(x: w * 0.5, y: 4), CGPoint(x: w * 2.5, y: 4), CGPoint(x: w * 4.5, y: 4)])   // C、E、G
        let keysImage = NSImage(size: keys.frame.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext, let layer = keys.layer else { return false }
            layer.render(in: context)
            return true
        }
        let back = TouchBarArt.card("‹", width: TouchBarItem.backWidth)
        touchBar([back, panel.lower.image, keysImage, panel.higher.image].compactMap { $0 }, to: "\(dir)/touchbar-piano.png")
        keys.releaseAll()
    }
}
