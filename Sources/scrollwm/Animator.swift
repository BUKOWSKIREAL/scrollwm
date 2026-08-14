import AppKit
import QuartzCore
import ScrollCore

/// 帧动画器：以 CADisplayLink 驱动 AX 窗口移动。
///
/// 默认使用解析式弹簧（标准阻尼谐振方程，与 niri/libadwaita 同款）。AX 写入是同步 RPC，因此按 App
/// 串行、不同 App 并行；上一笔尚未返回的窗口跳过该显示帧，但物理时钟继续前进。
final class FrameAnimator {

    struct Transition {
        let window: AXWindow
        let from: CGRect
        let to: CGRect
    }

    private struct ActiveTransition {
        let window: AXWindow
        let from: CGRect
        let to: CGRect
        let springX: ScalarSpring?
        let springY: ScalarSpring?
        let duration: TimeInterval

        /// 窗口尺寸通过 AX 一次性落到目标，因此视觉边框尺寸也必须立即一致；
        /// 只有位置沿 Spring 运动，避免边框右缘短暂画在窗口内部。
        func frame(at elapsed: TimeInterval, curve: Interpolation.Curve) -> CGRect {
            if let springX, let springY {
                return CGRect(
                    x: springX.value(at: elapsed),
                    y: springY.value(at: elapsed),
                    width: to.width,
                    height: to.height
                )
            }
            let progress = duration > 0 ? min(1, elapsed / duration) : 1
            let origin = Interpolation.lerp(from.origin, to.origin, curve.value(progress))
            return CGRect(origin: origin, size: to.size)
        }

        func velocity(at elapsed: TimeInterval) -> CGPoint {
            CGPoint(
                x: springX?.velocity(at: elapsed) ?? 0,
                y: springY?.velocity(at: elapsed) ?? 0
            )
        }
    }

    /// 每次 AX 下发前回调，供 WindowManager 记录回声抑制帧。
    var onWrite: ((CGWindowID, CGRect) -> Void)?

    /// 每个 DisplayLink tick 的完整视觉帧；不受 AX inFlight 丢帧影响。
    var onVisualFrame: ((CGWindowID, CGRect) -> Void)?

    /// AX 实际接受的 frame 与请求不一致（通常是 App 最小宽度钳制）时回调布局层。
    var onConstrainedFrame: ((CGWindowID, CGRect) -> Void)?

    /// 可选合成器批量通道；为 nil 时走 AX。
    var batchSink: (([(id: CGWindowID, rect: CGRect)], Bool) -> Void)?

    /// 视口动画：每 tick 由布局引擎给出整条纸带的帧，窗口保持相对位置。
    var onLayoutSample: ((_ elapsed: TimeInterval, _ isFinal: Bool) -> [(window: AXWindow, rect: CGRect)])?

    var mode: AnimationMode = .spring
    var curve: Interpolation.Curve = .default
    var springParameters: SpringParameters = .niriDefault
    /// 实验性：锁定到所在屏最大刷新率（ProMotion 上系统平时会压到 60Hz 省电）。
    var highFrameRate = false {
        didSet { applyFrameRateRange() }
    }
    private(set) var isLayoutAnimating = false
    private var layoutDuration: TimeInterval = 0

    private var displayLink: CADisplayLink?
    private var linkedDisplayID: CGDirectDisplayID?
    private var linkedMaxFPS: Float = 60
    private let linkTarget = DisplayLinkProxy()
    private var startTime: CFTimeInterval = 0
    private var transitions: [ActiveTransition] = []
    private var appQueues: [pid_t: DispatchQueue] = [:]
    private var inFlight: Set<CGWindowID> = []
    /// AX 实际接受的窗口尺寸。部分 App 会按最小尺寸钳制 setSize，不能假设请求值即实际值。
    private var presentedSizes: [CGWindowID: CGSize] = [:]

    /// 最后一次计划下发的帧，避免动画热路径读取 AX。
    private(set) var lastSent: [CGWindowID: CGRect] = [:]
    private(set) var currentTargets: [CGWindowID: CGRect] = [:]

    var isRunning: Bool { displayLink != nil }

    init() {
        linkTarget.owner = self
    }

    func hasTarget(for id: CGWindowID) -> Bool {
        currentTargets[id] != nil
    }

    func isAnimating(toward targets: [CGWindowID: CGRect]) -> Bool {
        guard isRunning, targets.count == currentTargets.count else { return false }
        for (id, rect) in targets {
            guard let existing = currentTargets[id],
                  existing.approximatelyEqual(to: rect, tolerance: 1.5)
            else { return false }
        }
        return true
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let queue = appQueues[pid] { return queue }
        let queue = DispatchQueue(label: "scrollwm.ax.\(pid)", qos: .userInteractive)
        appQueues[pid] = queue
        return queue
    }

    // MARK: - 立即应用

    func applyInstantly(window: AXWindow, rect: CGRect) {
        let id = window.windowID
        lastSent[id] = rect
        presentedSizes[id] = rect.size
        onWrite?(id, rect)
        onVisualFrame?(id, rect)
        queue(for: window.pid).async { [weak self] in
            window.setFrame(rect)
            guard let actual = window.frame() else { return }
            DispatchQueue.main.async {
                self?.acceptActualFrame(actual, for: id)
            }
        }
    }

    // MARK: - 拖拽热路径

    /// 拖拽期间的坐标写入：走 per-App 串行队列 + 飞行中合并，绝不阻塞主线程。
    /// App 响应慢时只丢中间帧，松手位置始终是最后一笔。
    private var dragPending: [CGWindowID: CGPoint] = [:]
    private var dragInFlight: Set<CGWindowID> = []

    func dragMove(window: AXWindow, to origin: CGPoint) {
        dragPending[window.windowID] = origin
        pumpDrag(window: window)
    }

    /// 拖拽结束：丢弃尚未写出的坐标，避免旧帧在后续重排动画开始后才落地。
    func cancelDrag(for id: CGWindowID) {
        dragPending.removeValue(forKey: id)
    }

    private func pumpDrag(window: AXWindow) {
        let id = window.windowID
        guard !dragInFlight.contains(id),
              let origin = dragPending.removeValue(forKey: id)
        else { return }
        dragInFlight.insert(id)
        queue(for: window.pid).async { [weak self] in
            window.setPosition(origin)
            let actual = window.frame()
            DispatchQueue.main.async {
                guard let self else { return }
                self.dragInFlight.remove(id)
                if let actual {
                    self.lastSent[id] = actual
                    self.onVisualFrame?(id, actual)
                }
                self.pumpDrag(window: window)
            }
        }
    }

    // MARK: - 动画

    /// 视口级动画：每帧按插值后的 offset 重新 layout，纸带作为整体滑动。
    func animateLayout(
        duration: TimeInterval,
        targets: [CGWindowID: CGRect],
        screen: NSScreen? = nil
    ) {
        transitions = []
        isLayoutAnimating = true
        layoutDuration = max(0, duration)
        currentTargets = targets
        startTime = CACurrentMediaTime()

        let displayID = screen.map(ScreenGeometry.displayID)
        if displayLink == nil || linkedDisplayID != displayID {
            startDisplayLink(on: screen)
        }
        tick(at: startTime)
    }

    /// 启动动画，或在运行中无缝改道。Spring 模式继承当前解析位置和速度，连续按键不会
    /// 重新从静止状态起步，这正是 niri 横向视口移动手感的关键。
    func animate(
        transitions rawTransitions: [Transition],
        duration requestedDuration: TimeInterval,
        screen: NSScreen? = nil
    ) {
        guard !rawTransitions.isEmpty else { return }
        isLayoutAnimating = false
        layoutDuration = 0

        let now = CACurrentMediaTime()
        let previousElapsed = max(0, now - startTime)
        let previousByID = Dictionary(uniqueKeysWithValues: transitions.map { ($0.window.windowID, $0) })

        var prepared: [ActiveTransition] = []
        var newTargets: [CGWindowID: CGRect] = [:]
        prepared.reserveCapacity(rawTransitions.count)

        for transition in rawTransitions {
            let id = transition.window.windowID
            let previous = previousByID[id]
            let liveFrom = previous?.frame(at: previousElapsed, curve: curve)
                ?? lastSent[id]
                ?? transition.from
            let inheritedVelocity = previous?.velocity(at: previousElapsed) ?? .zero

            let sizeChanged = abs(liveFrom.width - transition.to.width) > 1
                || abs(liveFrom.height - transition.to.height) > 1
            presentedSizes[id] = transition.to.size
            if sizeChanged {
                // AX 连续 resize 会让客户端重排并闪烁；尺寸先到位，弹簧只负责位置。
                // 亮边必须立刻用目标尺寸，否则 Ctrl+加号时框会缩在窗口里面。
                queue(for: transition.window.pid).async { [weak self, window = transition.window] in
                    window.setSize(transition.to.size)
                    guard let actual = window.frame() else { return }
                    DispatchQueue.main.async {
                        self?.acceptActualFrame(actual, for: id)
                    }
                }
            }

            // 位置动画仍以目标几何为准；视觉尺寸由 presentedSizes 使用 AX 实际值覆盖。
            let from = CGRect(origin: liveFrom.origin, size: transition.to.size)
            let active: ActiveTransition
            switch mode {
            case .spring:
                let springX = ScalarSpring(
                    from: from.minX,
                    to: transition.to.minX,
                    initialVelocity: inheritedVelocity.x,
                    parameters: springParameters
                )
                let springY = ScalarSpring(
                    from: from.minY,
                    to: transition.to.minY,
                    initialVelocity: inheritedVelocity.y,
                    parameters: springParameters
                )
                active = ActiveTransition(
                    window: transition.window,
                    from: from,
                    to: transition.to,
                    springX: springX,
                    springY: springY,
                    duration: max(springX.settlingDuration, springY.settlingDuration)
                )
            case .easing:
                let maxTravel = hypot(transition.to.minX - from.minX, transition.to.minY - from.minY)
                let distanceScale = min(1, Double(maxTravel) / 900)
                let base = max(0.05, requestedDuration)
                let adapted = base * (0.55 + 0.45 * max(0.25, distanceScale))
                active = ActiveTransition(
                    window: transition.window,
                    from: from,
                    to: transition.to,
                    springX: nil,
                    springY: nil,
                    duration: adapted
                )
            }

            prepared.append(active)
            newTargets[id] = transition.to
            // AX 语义下尺寸已经计划一次性到目标；缓存反映实际窗口而不是视觉亮边。
            lastSent[id] = CGRect(origin: from.origin, size: transition.to.size)
        }

        transitions = prepared
        currentTargets = newTargets
        startTime = now

        let displayID = screen.map(ScreenGeometry.displayID)
        if displayLink == nil || linkedDisplayID != displayID {
            startDisplayLink(on: screen)
        }
        tick(at: now)
    }

    func cancel() {
        stopDisplayLink()
        transitions = []
        currentTargets = [:]
        isLayoutAnimating = false
        layoutDuration = 0
    }

    /// 停掉单个窗口的动画，其它窗口继续。系统 zoom/fill 时必须立刻放手。
    func cancelAnimation(for id: CGWindowID) {
        currentTargets.removeValue(forKey: id)
        inFlight.remove(id)
        transitions.removeAll { $0.window.windowID == id }
        if isLayoutAnimating {
            if currentTargets.isEmpty { finish() }
            return
        }
        if transitions.isEmpty {
            stopDisplayLink()
        }
    }

    // MARK: - DisplayLink

    private func startDisplayLink(on screen: NSScreen?) {
        stopDisplayLink()
        // 必须绑到窗口所在屏。默认 CADisplayLink 跟主屏/内建屏 vsync；
        // 外接屏 60Hz、内建屏 ProMotion 省电降到 1Hz 时，动画会直接停住。
        let link: CADisplayLink
        if let screen {
            link = screen.displayLink(target: linkTarget, selector: #selector(DisplayLinkProxy.tick(_:)))
            linkedDisplayID = ScreenGeometry.displayID(of: screen)
        } else {
            link = CADisplayLink(target: linkTarget, selector: #selector(DisplayLinkProxy.tick(_:)))
            linkedDisplayID = nil
        }
        let fps = max(30, screen?.maximumFramesPerSecond ?? 60)
        linkedMaxFPS = Float(fps)
        link.preferredFrameRateRange = frameRateRange()
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func frameRateRange() -> CAFrameRateRange {
        CAFrameRateRange(
            minimum: highFrameRate ? linkedMaxFPS : 30,
            maximum: linkedMaxFPS,
            preferred: linkedMaxFPS
        )
    }

    /// 配置热更新时，运行中的 DisplayLink 也要跟着换帧率档。
    private func applyFrameRateRange() {
        displayLink?.preferredFrameRateRange = frameRateRange()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        linkedDisplayID = nil
    }

    fileprivate func handleDisplayLink(_ link: CADisplayLink) {
        let now: CFTimeInterval
        if #available(macOS 14.0, *) {
            now = link.targetTimestamp
        } else {
            now = CACurrentMediaTime()
        }
        tick(at: now)
    }

    private func tick(at now: CFTimeInterval) {
        if isLayoutAnimating {
            tickLayout(at: now)
            return
        }
        guard !transitions.isEmpty else {
            stopDisplayLink()
            return
        }

        let elapsed = max(0, now - startTime)
        let isFinal = transitions.allSatisfy { elapsed >= $0.duration }

        if let sink = batchSink {
            var batch: [(id: CGWindowID, rect: CGRect)] = []
            batch.reserveCapacity(transitions.count)
            for transition in transitions {
                let rect = isFinal ? transition.to : transition.frame(at: elapsed, curve: curve)
                lastSent[transition.window.windowID] = rect
                onWrite?(transition.window.windowID, rect)
                onVisualFrame?(transition.window.windowID, visualFrame(rect, for: transition.window.windowID))
                batch.append((transition.window.windowID, rect))
            }
            sink(batch, isFinal)
            if isFinal { finish() }
            return
        }

        for transition in transitions {
            let id = transition.window.windowID

            if isFinal {
                lastSent[id] = transition.to
                onWrite?(id, transition.to)
                onVisualFrame?(id, visualFrame(transition.to, for: id))
                queue(for: transition.window.pid).async { [weak self, window = transition.window] in
                    window.setFrame(transition.to)
                    let actual = window.frame()
                    DispatchQueue.main.async {
                        self?.inFlight.remove(id)
                        if let actual { self?.acceptActualFrame(actual, for: id) }
                    }
                }
                continue
            }

            let visualRect = visualFrame(transition.frame(at: elapsed, curve: curve), for: id)
            onVisualFrame?(id, visualRect)

            guard !inFlight.contains(id) else { continue }
            let axRect = CGRect(origin: visualRect.origin, size: transition.to.size)
            guard let last = lastSent[id],
                  !last.origin.approximatelyEqual(to: axRect.origin, tolerance: 0.25)
            else { continue }

            inFlight.insert(id)
            lastSent[id] = axRect
            onWrite?(id, axRect)
            queue(for: transition.window.pid).async { [weak self, window = transition.window] in
                window.setPosition(axRect.origin)
                DispatchQueue.main.async { self?.inFlight.remove(id) }
            }
        }

        if isFinal { finish() }
    }

    private func tickLayout(at now: CFTimeInterval) {
        guard let sample = onLayoutSample else {
            finish()
            return
        }
        let elapsed = max(0, now - startTime)
        let isFinal = layoutDuration <= 0 || elapsed >= layoutDuration
        let frames = sample(elapsed, isFinal).filter { currentTargets[$0.window.windowID] != nil }

        if let sink = batchSink {
            var batch: [(id: CGWindowID, rect: CGRect)] = []
            batch.reserveCapacity(frames.count)
            for (window, rect) in frames {
                let id = window.windowID
                lastSent[id] = rect
                presentedSizes[id] = rect.size
                onWrite?(id, rect)
                onVisualFrame?(id, visualFrame(rect, for: id))
                batch.append((id, rect))
            }
            if !batch.isEmpty { sink(batch, isFinal) }
            if isFinal { finish() }
            return
        }

        // AX 路径：任一窗口还在飞行则整帧停写，避免纸带被拆开。
        if !isFinal, frames.contains(where: { inFlight.contains($0.window.windowID) }) {
            return
        }

        for (window, rect) in frames {
            let id = window.windowID
            if isFinal {
                lastSent[id] = rect
                presentedSizes[id] = rect.size
                onWrite?(id, rect)
                onVisualFrame?(id, visualFrame(rect, for: id))
                queue(for: window.pid).async { [weak self] in
                    window.setFrame(rect)
                    let actual = window.frame()
                    DispatchQueue.main.async {
                        self?.inFlight.remove(id)
                        if let actual { self?.acceptActualFrame(actual, for: id) }
                    }
                }
                continue
            }

            let visualRect = visualFrame(rect, for: id)
            onVisualFrame?(id, visualRect)
            let axRect = CGRect(origin: visualRect.origin, size: presentedSizes[id] ?? visualRect.size)
            if let last = lastSent[id], last.origin.approximatelyEqual(to: axRect.origin, tolerance: 0.25) {
                continue
            }

            inFlight.insert(id)
            lastSent[id] = axRect
            onWrite?(id, axRect)
            queue(for: window.pid).async { [weak self] in
                window.setPosition(axRect.origin)
                DispatchQueue.main.async { self?.inFlight.remove(id) }
            }
        }

        if isFinal { finish() }
    }

    private func finish() {
        stopDisplayLink()
        transitions = []
        currentTargets = [:]
        isLayoutAnimating = false
        layoutDuration = 0
    }

    private func visualFrame(_ requested: CGRect, for id: CGWindowID) -> CGRect {
        CGRect(origin: requested.origin, size: presentedSizes[id] ?? requested.size)
    }

    /// AX 写回后的真实 frame 是焦点边框的最终权威，尤其是有最小尺寸约束的 App。
    private func acceptActualFrame(_ actual: CGRect, for id: CGWindowID) {
        let requested = currentTargets[id] ?? lastSent[id]
        // "弹回默认中央"守卫只适用于非动画路径：动画途中 origin 必然偏离最终目标，
        // 若据此丢弃反馈，最小宽度 App 的真实尺寸永远吸收不进模型（列会互相覆盖）。
        if currentTargets[id] == nil, let requested {
            let originDelta = hypot(actual.minX - requested.minX, actual.minY - requested.minY)
            if originDelta > 12 {
                // 客户端把窗口弹回默认中央，不能把我们的目标改成那个尺寸。
                return
            }
        }
        let requestedSize = requested?.size
        presentedSizes[id] = actual.size
        if let requestedSize,
           abs(requestedSize.width - actual.width) > 2 || abs(requestedSize.height - actual.height) > 2 {
            if currentTargets[id] == nil {
                onConstrainedFrame?(id, actual)
            }
        }
        if var cached = lastSent[id] {
            cached.size = actual.size
            lastSent[id] = cached
            onVisualFrame?(id, CGRect(origin: cached.origin, size: actual.size))
        } else {
            lastSent[id] = actual
            onVisualFrame?(id, actual)
        }
    }

    // MARK: - 缓存维护

    func invalidate(_ id: CGWindowID) {
        lastSent.removeValue(forKey: id)
        presentedSizes.removeValue(forKey: id)
    }

    func invalidateAll() {
        lastSent.removeAll()
        presentedSizes.removeAll()
        // currentTargets / transitions 已由 cancel() 清理，这里兜底再清一次 inFlight 避免残留跳帧
        inFlight.removeAll()
        dragPending.removeAll()
    }

    func forget(_ id: CGWindowID) {
        lastSent.removeValue(forKey: id)
        currentTargets.removeValue(forKey: id)
        inFlight.remove(id)
        presentedSizes.removeValue(forKey: id)
        dragPending.removeValue(forKey: id)
        transitions.removeAll { $0.window.windowID == id }
    }
}

private final class DisplayLinkProxy: NSObject {
    weak var owner: FrameAnimator?
    @objc func tick(_ link: CADisplayLink) {
        owner?.handleDisplayLink(link)
    }
}

private extension CGPoint {
    func approximatelyEqual(to other: CGPoint, tolerance: CGFloat) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
    }
}
