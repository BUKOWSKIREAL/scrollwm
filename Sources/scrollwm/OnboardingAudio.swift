import AVFoundation
import os

/// 引导页配乐：低音量环境垫 + 场景铃音 + 交互轻点，全部实时合成，不打包任何音频资源。
///
/// 渲染回调跑在音频线程，只读写预分配内存：pad 振荡器常驻，铃音在 partial 池里找空位。
/// 主线程投递音符走一个小队列，音频线程用 trylock 取——抢不到锁就下个回调再取，绝不阻塞。
final class OnboardingAudio {

    private struct Partial {
        var phase: Float = 0
        var inc: Float = 0
        var env: Float = 0
        var decay: Float = 1
    }

    /// 常驻的环境垫振荡器：极慢的独立颤音让和弦一直在轻微呼吸
    private struct PadVoice {
        var phase: Float = 0
        var inc: Float = 0
        var tremPhase: Float = 0
        var tremInc: Float = 0
        var gain: Float = 0
        var panL: Float = 1
        var panR: Float = 1
    }

    private struct Note {
        var freq: Float = 0
        var amp: Float = 0
        var seconds: Float = 0
    }

    private struct Master {
        var gain: Float = 0
        var target: Float = 0
        /// 每采样趋近系数，约 0.6s 时间常数
        var alpha: Float = 0.000035
        var sampleRate: Float = 48_000
    }

    private static let partialCount = 64
    private static let padCount = 4
    private static let queueCapacity = 32

    /// 非谐波泛音比：接近钟 / 颤音琴，不是干巴巴的正弦
    private static let ratios: [Float] = [1.0, 2.01, 2.98, 4.16]
    private static let ratioAmps: [Float] = [1.0, 0.46, 0.24, 0.13]
    private static let ratioDecays: [Float] = [1.0, 0.68, 0.46, 0.30]

    /// D 小调五声音阶：章节推进时逐级上行
    private static let scale: [Float] = [146.83, 174.61, 196.00, 220.00, 261.63, 293.66, 349.23]
    /// 引导是背景，不是主角；1.0 会偏响
    private static let liveGain: Float = 0.32

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var started = false
    private var stopping = false
    private var restartScheduled = false
    private var fadeOutWork: DispatchWorkItem?
    private var lastTickAt: CFTimeInterval = 0

    private let partials: UnsafeMutablePointer<Partial>
    private let pads: UnsafeMutablePointer<PadVoice>
    private let notes: UnsafeMutablePointer<Note>
    /// [0] = 音频线程读游标，[1] = 主线程写游标；两侧都在锁内访问
    private let cursor: UnsafeMutablePointer<Int>
    private let master: UnsafeMutablePointer<Master>
    /// 主线程只写这里，音频线程拿到锁时才同步进 master.target
    private let pendingGain: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>

    var isMuted: Bool = false {
        didSet {
            guard isMuted != oldValue else { return }
            setTargetGain(isMuted ? 0 : Self.liveGain)
        }
    }

    init() {
        partials = .allocate(capacity: Self.partialCount)
        partials.initialize(repeating: Partial(), count: Self.partialCount)
        pads = .allocate(capacity: Self.padCount)
        pads.initialize(repeating: PadVoice(), count: Self.padCount)
        notes = .allocate(capacity: Self.queueCapacity)
        notes.initialize(repeating: Note(), count: Self.queueCapacity)
        cursor = .allocate(capacity: 2)
        cursor.initialize(repeating: 0, count: 2)
        master = .allocate(capacity: 1)
        master.initialize(to: Master())
        pendingGain = .allocate(capacity: 1)
        pendingGain.initialize(to: 0)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange, object: engine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // 必须先停引擎：渲染线程停下来之后才能回收它读写的内存
        if started { engine.stop() }
        partials.deallocate()
        pads.deallocate()
        notes.deallocate()
        cursor.deallocate()
        master.deallocate()
        pendingGain.deallocate()
        lock.deallocate()
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        fadeOutWork?.cancel()
        fadeOutWork = nil
        stopping = false

        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = hardwareRate > 0 ? hardwareRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }

        master.pointee.sampleRate = Float(rate)
        master.pointee.gain = 0
        master.pointee.target = 0
        configurePad(sampleRate: Float(rate))

        // 捕获裸指针而不是 self：音频线程上不碰 ARC
        let partials = self.partials
        let pads = self.pads
        let notes = self.notes
        let cursor = self.cursor
        let master = self.master
        let pendingGain = self.pendingGain
        let lock = self.lock

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, rawBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(rawBufferList)
            let left = buffers.count > 0 ? buffers[0].mData?.assumingMemoryBound(to: Float.self) : nil
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : left

            if os_unfair_lock_trylock(lock) {
                master.pointee.target = pendingGain.pointee
                while cursor[0] < cursor[1] {
                    let note = notes[cursor[0] % Self.queueCapacity]
                    cursor[0] &+= 1
                    Self.strike(note, into: partials, sampleRate: master.pointee.sampleRate)
                }
                os_unfair_lock_unlock(lock)
            }

            var state = master.pointee
            let twoPi = Float.pi * 2

            for frame in 0..<Int(frameCount) {
                state.gain += (state.target - state.gain) * state.alpha
                var l: Float = 0
                var r: Float = 0

                for index in 0..<Self.padCount {
                    var voice = pads[index]
                    let tremolo = 0.62 + 0.38 * sinf(voice.tremPhase)
                    let sample = sinf(voice.phase) * voice.gain * tremolo
                    l += sample * voice.panL
                    r += sample * voice.panR
                    voice.phase += voice.inc
                    if voice.phase > twoPi { voice.phase -= twoPi }
                    voice.tremPhase += voice.tremInc
                    if voice.tremPhase > twoPi { voice.tremPhase -= twoPi }
                    pads[index] = voice
                }

                for index in 0..<Self.partialCount {
                    var partial = partials[index]
                    guard partial.env > 0.00002 else { continue }
                    let sample = sinf(partial.phase) * partial.env
                    l += sample
                    r += sample
                    partial.phase += partial.inc
                    if partial.phase > twoPi { partial.phase -= twoPi }
                    partial.env *= partial.decay
                    partials[index] = partial
                }

                // 软削波兜底：铃音叠加时也不会硬切
                left?[frame] = tanhf(l * state.gain)
                right?[frame] = tanhf(r * state.gain)
            }

            master.pointee = state
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.detach(node)
            Log.debug("引导配乐启动失败：\(error.localizedDescription)")
            return
        }
        source = node
        started = true
        setTargetGain(isMuted ? 0 : Self.liveGain)
    }

    /// 淡出后停机。窗口关闭时调用，别让声音被硬切断。
    func stop(fadeOut: TimeInterval = 1.4) {
        guard started else { return }
        stopping = true
        setTargetGain(0)
        fadeOutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.engine.stop()
            if let node = self.source {
                self.engine.detach(node)
                self.source = nil
            }
            self.started = false
            self.stopping = false
        }
        fadeOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOut, execute: work)
    }

    @objc private func handleConfigurationChange() {
        // 通知可能来自音频线程；所有 graph 操作切回主线程。旧 source 必须先
        // detach，不能只丢引用，否则每次换耳机都会在 graph 里多留一个振荡器。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started, !self.stopping, !self.restartScheduled else { return }
            self.restartScheduled = true
            self.engine.stop()
            if let node = self.source {
                self.engine.detach(node)
                self.source = nil
            }
            self.started = false
            self.start()
            // stop / detach / start 自己也可能再发 configuration-change；保留
            // 一小段保护窗，吞掉这批由重建动作产生的回声。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restartScheduled = false
            }
        }
    }

    // MARK: - 声音事件

    /// 章节推进：五声音阶逐级上行的一记铃音
    func chime(step: Int) {
        let index = min(max(step, 0), Self.scale.count - 1)
        let root = Self.scale[index]
        post(freq: root * 2, amp: 0.20, seconds: 2.4)
        post(freq: root * 3, amp: 0.05, seconds: 1.5)
    }

    /// 交互反馈。鼠标扫过一排按键时会连发，这里做 90ms 节流。
    func tick() {
        let now = CACurrentMediaTime()
        guard now - lastTickAt > 0.09 else { return }
        lastTickAt = now
        post(freq: 1_180, amp: 0.05, seconds: 0.09)
    }

    /// 授权通过：上行小三度
    func success() {
        post(freq: 523.25, amp: 0.16, seconds: 2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.post(freq: 783.99, amp: 0.14, seconds: 2.6)
        }
    }

    /// 收尾和弦
    func finale() {
        post(freq: 587.33, amp: 0.15, seconds: 3.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            self?.post(freq: 698.46, amp: 0.12, seconds: 3.0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.post(freq: 880.00, amp: 0.10, seconds: 3.4)
        }
    }

    // MARK: - 内部

    private func configurePad(sampleRate: Float) {
        // D3 / A3 / D4 / F4：不带三度的开放和声，长时间听不腻
        let spec: [(freq: Float, gain: Float, tremolo: Float, pan: Float)] = [
            (146.83, 0.050, 0.061, -0.5),
            (220.00, 0.034, 0.043, 0.45),
            (293.66, 0.027, 0.077, 0.30),
            (349.23, 0.020, 0.052, -0.35),
        ]
        let twoPi = Float.pi * 2
        for (index, item) in spec.enumerated() where index < Self.padCount {
            // 每个分音起始相位错开，避免同相叠加出爆音
            pads[index] = PadVoice(
                phase: Float(index) * 1.7,
                inc: twoPi * item.freq / sampleRate,
                tremPhase: Float(index) * 0.9,
                tremInc: twoPi * item.tremolo / sampleRate,
                gain: item.gain,
                panL: 1 - max(0, item.pan) * 0.55,
                panR: 1 + min(0, item.pan) * 0.55
            )
        }
    }

    private func setTargetGain(_ value: Float) {
        os_unfair_lock_lock(lock)
        pendingGain.pointee = value
        os_unfair_lock_unlock(lock)
    }

    private func post(freq: Float, amp: Float, seconds: Float) {
        guard started, !isMuted else { return }
        os_unfair_lock_lock(lock)
        if cursor[1] - cursor[0] < Self.queueCapacity {
            notes[cursor[1] % Self.queueCapacity] = Note(freq: freq, amp: amp, seconds: seconds)
            cursor[1] &+= 1
        }
        os_unfair_lock_unlock(lock)
    }

    /// 音频线程上把一个音符铺进 partial 池。只在音符事件时调用，不在逐采样热路径。
    private static func strike(
        _ note: Note,
        into partials: UnsafeMutablePointer<Partial>,
        sampleRate: Float
    ) {
        guard note.freq > 0, sampleRate > 0 else { return }
        for k in 0..<ratios.count {
            let freq = note.freq * ratios[k]
            guard freq < sampleRate * 0.45 else { continue }
            let slot = freeSlot(in: partials)
            let seconds = max(0.02, note.seconds * ratioDecays[k])
            partials[slot] = Partial(
                phase: 0,
                inc: 2 * .pi * freq / sampleRate,
                env: note.amp * ratioAmps[k],
                decay: expf(-1 / (seconds * sampleRate))
            )
        }
    }

    /// 优先用空位，池子满了就顶掉最轻的那个
    private static func freeSlot(in partials: UnsafeMutablePointer<Partial>) -> Int {
        var quietest = 0
        var quietestEnv = Float.greatestFiniteMagnitude
        for index in 0..<partialCount {
            let env = partials[index].env
            if env < 0.00002 { return index }
            if env < quietestEnv {
                quietestEnv = env
                quietest = index
            }
        }
        return quietest
    }
}
