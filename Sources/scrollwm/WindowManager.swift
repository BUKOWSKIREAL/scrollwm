import AppKit
import ApplicationServices
import ScrollCore

/// 编排器：维护纸带状态，消费 AX 事件，向窗口下发帧。
/// 全部逻辑运行在主线程（AX 观察者、热键、NSWorkspace 通知都投递到主 RunLoop）。
final class WindowManager {
    static private(set) var shared: WindowManager?

    private(set) var config: Config
    private var strip = Strip()
    private var apps: [pid_t: AXApplication] = [:]
    /// 所有已知标准窗口（含浮动豁免的）
    private var windows: [CGWindowID: AXWindow] = [:]
    private var floating: Set<CGWindowID> = []
    /// 切走 Space / 全屏 / 最小化后窗口会暂时离开纸带；切回时用这份记忆恢复列宽与列序，而不是 defaultWidth。
    private struct RememberedColumn {
        var fraction: Double
        var savedFraction: Double?
        var index: Int
    }
    private var rememberedColumns: [CGWindowID: RememberedColumn] = [:]
    /// 刚 park 进全屏的窗口：进入过渡期内不要立刻拉回纸带（否则会把正在进入全屏的窗口拽出来）。
    private var fullscreenParkUntil: [CGWindowID: CFTimeInterval] = [:]
    /// 退出全屏后轮询收编：AXFullScreen 已关但几何还盖住整屏时，等动画结束或超时强制拉回。
    private var fullscreenExitWork: [CGWindowID: DispatchWorkItem] = [:]
    /// 进过原生全屏（AXFullScreen 或随 Space 切走）的窗口；退出后若仍盖住整屏则强制收编。
    private var nativeFullscreenParked: Set<CGWindowID> = []
    /// 进入/处于全屏时禁止焦点框重现；只有窗口真正恢复入列后才解除。
    private var fullscreenFocusRingSuppressed: Set<CGWindowID> = []
    /// 最近一次获得焦点的标准窗口（含浮动），供 close/toggle-float 使用
    private var lastFocusedID: CGWindowID?
    private(set) var paused = false

    // 回声抑制：记录我们主动下发的帧
    private struct PendingFrame {
        let rect: CGRect
        let timestamp: CFTimeInterval
    }
    private var pendingFrames: [CGWindowID: PendingFrame] = [:]

    // 拖拽跟踪：鼠标按住期间不与用户抢窗口
    private var externallyTouched: Set<CGWindowID> = []
    private var mouseMonitors: [Any] = []
    /// 标题栏双击候选：这段时间内不要按旧列宽回弹，等系统 fill/zoom 落定。
    private var zoomCandidateUntil: [CGWindowID: CFTimeInterval] = [:]
    private var lastTitleClick: (id: CGWindowID, time: CFTimeInterval, point: CGPoint)?
    private var settleWork: [CGWindowID: DispatchWorkItem] = [:]

    /// niri Mod+拖动：Command 按住后拖平铺窗口，松手按落点重排列序。
    private struct CommandDrag {
        let id: CGWindowID
        let grabOffset: CGPoint
        let startAX: CGPoint
        let startFrame: CGRect
        let size: CGSize
        var didMove = false
    }
    private var commandDrag: CommandDrag?
    /// 必须挂在 `.eventTracking`：标题栏拖动时系统进入 tracking loop，default 模式收不到 dragged。
    private var commandDragPoll: Timer?

    // 帧动画器（也承担 per-App 并行写队列与"当前帧"缓存）
    private let animator = FrameAnimator()
    private let focusRing = FocusRingController()

    // 合成器后端（SkyLight）。仅当 payload 已注入 Dock 且配置开启时启用，
    // 否则动画走 AX（batchSink 为 nil）。
    private let compositor = CompositorMover()

    // 去抖
    private var retileWork: DispatchWorkItem?
    private var reconcileWork: DispatchWorkItem?
    /// 启动扫描结束前不把已有窗口按"新窗口"插到焦点右侧，交给 reconcile 按几何排。
    private var didFinishStartup = false
    /// 刚入列的窗口短时间内不要被对账当成"不在屏上"而摘掉再追加到纸带末尾。
    private var stickyUntil: [CGWindowID: CFTimeInterval] = [:]
    /// 已有列从全屏/Space 恢复后的短静默期：只吞 moved/resized 回声，不强制写帧。
    private var restoredQuietUntil: [CGWindowID: CFTimeInterval] = [:]
    /// 新入列窗口不要从屏幕中央弹簧滑到目标列，直接落位。
    private var pendingInstantPlace = Set<CGWindowID>()
    /// 最近一次布局下发的目标帧，开启动画弹回时仍按这个强制铺满。
    private var layoutFrames: [CGWindowID: CGRect] = [:]
    /// 屏幕上正在显示的视口偏移；焦点切换时弹簧驱动这个值，而不是每个窗口各弹各的。
    private var visualViewportOffset: CGFloat?
    private var viewportSpring: ScalarSpring?
    private var viewportEasingFrom: CGFloat = 0
    private var viewportEasingTo: CGFloat = 0
    private var viewportAnimStart: CFTimeInterval = 0
    private var viewportAnimDuration: TimeInterval = 0
    private var layoutAnimScreen: CGRect = .zero
    private var layoutAnimViewport: CGRect = .zero
    private var layoutColumnIDs: [WindowID] = []
    private var layoutFractions: [Double] = []

    var onStateChange: (() -> Void)?

    private var spec: LayoutSpec { config.layoutSpec }
    private var insertSide: HDirection { config.newWindowSide == .left ? .left : .right }

    init(config: Config) {
        self.config = config
        WindowManager.shared = self
        // 每笔下发都登记进回声抑制表（动画 tick 与瞬时应用统一走这里）
        animator.onWrite = { [weak self] id, rect in
            guard let self else { return }
            self.pendingFrames[id] = PendingFrame(rect: rect, timestamp: CACurrentMediaTime())
        }
        animator.onVisualFrame = { [weak self] id, rect in
            guard let self, self.strip.focusedID == id,
                  !self.fullscreenFocusRingSuppressed.contains(id)
            else { return }
            if !self.config.focusRingAlwaysOn,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != self.windows[id]?.pid { return }
            guard let window = self.windows[id] else { return }
            self.focusRing.show(windowID: id, pid: window.pid, axFrame: rect)
        }
        animator.onConstrainedFrame = { [weak self] id, rect in
            guard let self, !self.isSticky(id) else { return }
            self.absorbConstrainedFrame(id, rect: rect)
        }
        animator.onLayoutSample = { [weak self] elapsed, isFinal in
            self?.sampleViewportLayout(elapsed: elapsed, isFinal: isFinal) ?? []
        }
        configureAnimator(from: config)
        configureFocusRing(from: config)
    }

    private func configureAnimator(from config: Config) {
        animator.mode = config.animationMode
        animator.curve = config.animationCurve
        animator.highFrameRate = config.animationHighFrameRate
        animator.springParameters = SpringParameters(
            dampingRatio: config.springDampingRatio,
            stiffness: config.springStiffness,
            epsilon: config.springEpsilon
        )
    }

    private func configureFocusRing(from config: Config) {
        focusRing.configure(
            enabled: config.focusRingEnabled,
            width: CGFloat(config.focusRingWidth),
            glowRadius: CGFloat(config.focusRingGlowRadius),
            alwaysOn: config.focusRingAlwaysOn
        )
        refreshFocusRing()
    }

    private func refreshFocusRing() {
        guard !paused, let id = strip.focusedID, let window = windows[id] else {
            focusRing.hide()
            return
        }
        guard !fullscreenFocusRingSuppressed.contains(id) else {
            focusRing.hide()
            return
        }
        if !config.focusRingAlwaysOn,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid {
            focusRing.hide()
            return
        }
        // 亮边必须用 AX / 布局点坐标。kCGWindowBounds 与 CGDisplayBounds 可能是像素，
        // 混进 overlay 会在外接屏上整体错位。
        let frame: CGRect?
        if animator.hasTarget(for: id) {
            frame = animator.lastSent[id]
        } else {
            frame = window.frame()
        }
        guard let frame else {
            focusRing.hide()
            return
        }
        focusRing.show(windowID: id, pid: window.pid, axFrame: frame, reorder: true)
    }

    // MARK: - 生命周期

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(spaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(appVisibilityChanged(_:)),
            name: NSWorkspace.didHideApplicationNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(appVisibilityChanged(_:)),
            name: NSWorkspace.didUnhideApplicationNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(sessionBecameActive(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(sessionBecameActive(_:)),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // 拖拽：普通拖动松手回弹；Command+拖动按 niri 语义搬列。
        // 全局监视器收不到本进程事件，所以 local / global 都要挂。
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouse(event)
        }) {
            mouseMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouse(event)
            return event
        }) {
            mouseMonitors.append(monitor)
        }

        for app in NSWorkspace.shared.runningApplications {
            adoptApp(app)
        }
        refreshCompositorBackend()
        reconcile()
        didFinishStartup = true
        // 若恰好在 Mission Control/锁屏状态启动，optionOnScreenOnly 会暂时返回空集合；
        // 界面恢复后再扫一次即可收编，无需重启守护进程。
        scheduleReconcile(after: 2.0)
        Log.info("窗口管理已启动：\(strip.count) 列（\(Bundle.main.executablePath ?? "?"))")
    }

    private func rememberColumn(_ id: CGWindowID, forFullscreen: Bool = false) {
        guard let idx = strip.index(of: id) else { return }
        var column = strip.columns[idx]
        if forFullscreen, column.fraction >= 0.98, let saved = column.savedFraction {
            // 视频全屏触发的“铺满”不算用户宽度，恢复时用进入全屏前的真实宽度
            column.fraction = saved
            column.savedFraction = nil
        }
        rememberedColumns[id] = RememberedColumn(
            fraction: column.fraction,
            savedFraction: column.savedFraction,
            index: idx
        )
    }

    /// 摘除前已快照列序/列宽时，用快照的值记忆，避免边摘边查 index 被前面摘除挤到 0
    private func rememberColumn(
        _ id: CGWindowID, at index: Int, fraction rawFraction: Double,
        savedFraction: Double?, forFullscreen: Bool = false
    ) {
        var fraction = rawFraction
        var saved = savedFraction
        if forFullscreen, fraction >= 0.98, let s = saved {
            fraction = s
            saved = nil
        }
        rememberedColumns[id] = RememberedColumn(fraction: fraction, savedFraction: saved, index: index)
    }

    /// 切回 Space 时优先用离开前记住的列宽；否则按窗口当前实际宽度反推，避免被重置成 default_width。
    private func restoredFraction(
        for id: CGWindowID,
        window: AXWindow?,
        viewportWidth: CGFloat
    ) -> Double {
        if let remembered = rememberedColumns[id] {
            return remembered.fraction.clamped(0.15, 1.0)
        }
        if viewportWidth > 0, let width = window?.frame()?.width, width > 1 {
            let inferred = Double((width / viewportWidth).clamped(0.15, 1.0))
            // 视频/系统全屏留下的满屏宽度不能当成用户列宽
            if inferred >= 0.97 { return config.defaultWidth }
            return inferred
        }
        return config.defaultWidth
    }

    /// 根据配置与 payload 可用性，决定动画走合成器还是 AX
    private func refreshCompositorBackend() {
        if config.compositorEnabled, compositor.connect() {
            animator.batchSink = { [weak self] frames, settle in
                self?.compositor.apply(
                    frames.map { ($0.id, $0.rect, Float(1.0)) }, settle: settle
                )
            }
            Log.info("动画后端：合成器（SkyLight，payload 已连接）")
        } else {
            animator.batchSink = nil
            if config.compositorEnabled {
                Log.warn("已开启合成器但 payload 未连接，回退 AX。见 docs/COMPOSITOR-SETUP.md")
            }
        }
    }

    // MARK: - App 收编

    private func isIgnored(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return config.ignoreBundleIDs.contains(bundleID)
    }

    @discardableResult
    private func adoptApp(_ runningApp: NSRunningApplication) -> AXApplication? {
        let pid = runningApp.processIdentifier
        guard runningApp.activationPolicy == .regular,
              pid != ProcessInfo.processInfo.processIdentifier,
              !isIgnored(bundleID: runningApp.bundleIdentifier)
        else { return nil }

        if let existing = apps[pid] { return existing }

        let app = AXApplication(pid: pid, bundleID: runningApp.bundleIdentifier)
        guard app.startObserving(callback: axEventCallback) else { return nil }
        apps[pid] = app

        // 登记既有窗口的观察者。启动扫描交给 reconcile 按几何排；运行中新 App 立刻入列。
        var enrolled = false
        for element in app.windowElements() {
            if let window = AXWindow(element: element, pid: pid) {
                registerWindow(window, app: app)
                if didFinishStartup, !paused,
                   tryEnrollNewWindow(window, retileNow: false) {
                    enrolled = true
                }
            }
        }
        if enrolled { retile() }
        return app
    }

    /// 窗口进入已知集合并挂好观察者；不改变纸带
    private func registerWindow(_ window: AXWindow, app: AXApplication) {
        if windows[window.windowID] == nil {
            windows[window.windowID] = window
        }
        app.observeWindow(window)
    }

    // MARK: - 窗口筛选

    /// 当前平铺所在屏：跟焦点窗口走，这样外接显示器不会继续用笔记本主屏的几何。
    private func layoutScreen() -> NSScreen? {
        ScreenGeometry.activeScreen(preferredAXFrame: focusedAXFrame())
    }

    private func focusedAXFrame() -> CGRect? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let focused = apps[frontmost.processIdentifier]?.focusedWindow(),
           let frame = focused.frame() {
            return frame
        }
        if let id = lastFocusedID ?? strip.focusedID {
            return windows[id]?.frame() ?? animator.lastSent[id]
        }
        return nil
    }

    /// 是否具备被平铺的资格（不含浮动豁免判断）
    private func isTileable(_ window: AXWindow, on screen: NSScreen? = nil, ignoreCovering: Bool = false) -> Bool {
        guard window.isStandard, !window.isMinimized else { return false }
        guard !window.isFullscreen else { return false }
        if !ignoreCovering, isSystemFullscreen(window) { return false }
        guard let frame = window.frame() else { return false }
        let target = screen ?? ScreenGeometry.screen(containingAX: frame) ?? layoutScreen()
        guard let target else { return false }
        // 停靠列的大部分窗口在屏外，只露 screenMargin 宽纸边；重启后仍必须重新收编。
        return ScreenGeometry.intersects(frame, screen: target)
    }

    /// 窗口是否盖住整块屏（含菜单栏）。原生/视频全屏退出后常会短暂停在这个几何上。
    private func coversDisplay(_ window: AXWindow) -> Bool {
        guard let frame = window.frame(),
              let ns = ScreenGeometry.screen(containingAX: frame) else { return false }
        let full = ScreenGeometry.axFull(of: ns)
        return frame.minY <= full.minY + 4
            && frame.width >= full.width - 8
            && frame.height >= full.height - 8
    }

    /// 系统/HTML5 视频全屏：AXFullScreen，或盖住菜单栏。不是 alt-f 的平铺全宽。
    private func isSystemFullscreen(_ window: AXWindow) -> Bool {
        window.isFullscreen || coversDisplay(window)
    }

    /// 焦点框应更早于 park 隐藏：全屏动画接近整屏时先抑制，避免跟着中间帧乱跳。
    private func isFullscreenFocusRingCandidate(_ window: AXWindow, frame: CGRect) -> Bool {
        if window.isFullscreen { return true }
        guard let screen = ScreenGeometry.screen(containingAX: frame) else { return false }
        let full = ScreenGeometry.axFull(of: screen)
        return frame.minY <= full.minY + 24
            && frame.width >= full.width * 0.9
            && frame.height >= full.height * 0.9
    }

    private func suppressFocusRingForFullscreen(_ id: CGWindowID) {
        fullscreenFocusRingSuppressed.insert(id)
        if strip.focusedID == id { focusRing.hide() }
    }

    // MARK: - 全量对账

    /// 幂等的全量重扫：候选集与纸带对齐（增删），并同步观察者。
    func reconcile() {
        guard !paused, commandDrag == nil else { return }
        let onScreen = OnScreenWindows.ids()
        var tileable: [CGWindowID: AXWindow] = [:]
        var appWindowCounts: [String] = []
        let screen = layoutScreen()

        for (pid, app) in apps {
            let elements = app.windowElements()
            appWindowCounts.append("\(pid):\(elements.count)")
            for element in elements {
                guard let window = AXWindow(element: element, pid: pid) else { continue }
                registerWindow(window, app: app)
                guard onScreen.contains(window.windowID), isTileable(window, on: screen) else { continue }
                if window.isSizeSettable {
                    tileable[window.windowID] = window
                } else {
                    // 固定尺寸窗口自动浮动
                    floating.insert(window.windowID)
                }
            }
        }
        let screenDesc = screen.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil"
        Log.info("对账：屏 \(screenDesc)，在屏 \(onScreen.count)，可平铺 \(tileable.count)，纸带 \(strip.count)，app窗口 [\(appWindowCounts.joined(separator: ", "))]")

        let now = CACurrentMediaTime()
        stickyUntil = stickyUntil.filter { $0.value > now }

        // 摘除前先快照整条纸带的列序：同一趟对账里连续摘多列时，边摘边拿 index 会被前面的摘除挤到 0
        let columnsAtEntry = strip.columns
        let indexByIDAtEntry: [CGWindowID: Int] = Dictionary(
            uniqueKeysWithValues: columnsAtEntry.enumerated().map { ($1.id, $0) }
        )
        let fractionByIDAtEntry: [CGWindowID: (Double, Double?)] = Dictionary(
            uniqueKeysWithValues: columnsAtEntry.map { ($0.id, ($0.fraction, $0.savedFraction)) }
        )

        // 移除已消失/不再合格的列（切 Space 时只是暂时离开，记住列宽与列序）
        var removedCount = 0
        for id in strip.windowIDs where tileable[id] == nil {
            if let until = stickyUntil[id], now < until {
                Log.debug("对账：保留刚入列 #\(id)（尚未出现在 CGWindowList）")
                continue
            }
            let forFullscreen = windows[id].map { isSystemFullscreen($0) } ?? false
            if let idx = indexByIDAtEntry[id], let (frac, saved) = fractionByIDAtEntry[id] {
                rememberColumn(id, at: idx, fraction: frac, savedFraction: saved, forFullscreen: forFullscreen)
            } else {
                rememberColumn(id, forFullscreen: forFullscreen)
            }
            Log.info("对账：移除列 #\(id)")
            strip.remove(id: id)
            removedCount += 1
        }
        floating = floating.filter { id in
            windows[id] != nil && onScreen.contains(id)
        }

        let viewportWidth = screen.map {
            LayoutEngine.viewport(screen: ScreenGeometry.axVisible(of: $0), spec: spec).width
        } ?? 0

        let hadColumns = !strip.isEmpty
        // 空纸带（启动 / 切 Space）按几何从左到右收编；已有列时插到焦点右侧（niri 语义）。
        // 全屏 park 宽限期内的窗口不重收编（过渡中几何未定型）。
        let newIDs = tileable.keys
            .filter { id in
                if strip.contains(id) || floating.contains(id) { return false }
                guard let until = fullscreenParkUntil[id] else { return true }
                if CACurrentMediaTime() < until { return false }
                fullscreenParkUntil.removeValue(forKey: id)
                return true
            }
            .sorted { a, b in
                let fa = tileable[a]?.frame()?.minX ?? 0
                let fb = tileable[b]?.frame()?.minX ?? 0
                return fa < fb
            }
        var plannedRestores: [(id: CGWindowID, index: Int, fraction: Double, saved: Double?)] = []
        var plannedNew: [(id: CGWindowID, fraction: Double, saved: Double?)] = []
        for id in newIDs {
            let remembered = rememberedColumns[id]
            var fraction = restoredFraction(for: id, window: tileable[id], viewportWidth: viewportWidth)
            var saved = remembered?.savedFraction
            // 系统双击填满后若被短暂移出纸带，对账时窗口仍是满屏：
            // 不能用离开前的旧列宽把窗口拽回去。有记忆的恢复（全屏退出/切 Space）不走此启发式。
            if remembered == nil,
               let window = tileable[id], fillsTilingViewport(window), fraction < 0.98 {
                saved = saved ?? fraction
                fraction = 1.0
            }
            if let remembered {
                plannedRestores.append((id, remembered.index, fraction, saved))
            } else {
                plannedNew.append((id, fraction, saved))
            }
        }
        // 有记忆的列按原列序升序插入，避免恢复顺序互相挤压错位；再插入全新窗口。
        for item in plannedRestores.sorted(by: { $0.index < $1.index }) {
            Log.info("对账：恢复列 #\(item.id) → 原位 \(item.index) 宽 \(String(format: "%.2f", item.fraction))")
            strip.insert(id: item.id, at: item.index, fraction: item.fraction, savedFraction: item.saved)
            rememberedColumns.removeValue(forKey: item.id)
            prepareRestoredColumn(item.id)
        }
        for item in plannedNew {
            Log.info("对账：新窗口入列 #\(item.id) fraction=\(String(format: "%.2f", item.fraction))")
            if hadColumns || !strip.isEmpty {
                strip.insertAdjacentToFocused(
                    id: item.id, fraction: item.fraction, savedFraction: item.saved, side: insertSide
                )
                markSticky(item.id)
                pendingInstantPlace.insert(item.id)
                scheduleLayoutEnforcement(item.id)
            } else {
                strip.append(id: item.id, fraction: item.fraction, savedFraction: item.saved)
            }
        }

        // 焦点兜底：跟随系统当前焦点窗口
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let focused = apps[frontmost.processIdentifier]?.focusedWindow(),
           strip.contains(focused.windowID) {
            strip.focus(id: focused.windowID)
            lastFocusedID = focused.windowID
        } else if strip.focusedID == nil, let first = strip.windowIDs.first {
            strip.focus(id: first)
        }

        let incrementalAdd = hadColumns && !newIDs.isEmpty && removedCount == 0
        if incrementalAdd {
            retile(animated: true)
        } else if !newIDs.isEmpty || removedCount > 0 {
            retile(animated: false)
        } else if !animator.isRunning, !hasStickyWindows() {
            retile(animated: false)
        }
        refreshFocusRing()
    }

    /// 带日志的对账入口（Space 切换等诊断用）
    private func reconcileLogged(_ reason: String) {
        Log.info("对账触发：\(reason)")
        reconcile()
    }

    // MARK: - 布局下发（Applier）

    /// 计算布局并把差异帧下发给窗口。
    /// - reveal: 是否先做"最小滚动露出焦点列"
    /// - animated: 是否用缓动动画过渡（批量对账/首次布局用瞬时）
    func retile(reveal: Bool = true, animated: Bool = true) {
        guard !paused, commandDrag == nil else { return }
        guard let nsScreen = layoutScreen() else { return }
        let screen = ScreenGeometry.axVisible(of: nsScreen)
        let viewport = LayoutEngine.viewport(screen: screen, spec: spec)
        let fromOffset = currentVisualOffset()

        if reveal {
            strip.viewportOffset = LayoutEngine.revealOffset(
                strip, viewportWidth: viewport.width, spec: spec
            )
        } else {
            let widths = LayoutEngine.columnWidths(strip, viewportWidth: viewport.width)
            strip.viewportOffset = LayoutEngine.clampOffset(
                strip.viewportOffset,
                stripLength: LayoutEngine.stripLength(widths: widths, gap: spec.innerGap),
                viewportWidth: viewport.width
            )
        }

        let placements = LayoutEngine.computeLayout(strip, viewport: viewport, screen: screen, spec: spec)
        layoutFrames = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0.frame) })
        Log.debug("retile(animated=\(animated))：\(placements.count) 个目标帧")

        let instantIDs = pendingInstantPlace.intersection(Set(placements.map(\.id)))
        pendingInstantPlace.subtract(instantIDs)

        let animationHasDuration = config.animationMode == .spring || config.animationDurationMs > 0
        let wantAnimation = animated && config.animationEnabled && animationHasDuration
        if wantAnimation, shouldSlideViewport(
            from: fromOffset, to: strip.viewportOffset, instantIDs: instantIDs
        ) {
            startViewportSlide(
                from: fromOffset,
                to: strip.viewportOffset,
                placements: placements,
                nsScreen: nsScreen,
                screen: screen,
                viewport: viewport
            )
            rememberLayoutSignature()
            onStateChange?()
            return
        }

        // 差异收集：正常操作优先用写缓存避免全量 AX 读；切 Space/解锁后
        // lastSent 已在 spaceChanged 入口处全部作废，故会自然回落到 AX 实读，
        // 避免 stale 缓存把"已在目标"误判而跳过下发导致重叠。
        var transitions: [FrameAnimator.Transition] = []
        var targets: [CGWindowID: CGRect] = [:]
        for placement in placements {
            guard let window = windows[placement.id] else { continue }
            // 新窗口从系统默认中央滑过来会先「卡在中间」；直接落到目标列。
            if instantIDs.contains(placement.id) {
                animator.applyInstantly(window: window, rect: placement.frame)
                continue
            }
            // 对账（animated=false）必须读真实机位并瞬时落位
            if !animated {
                guard let actual = window.frame() else {
                    animator.applyInstantly(window: window, rect: placement.frame)
                    continue
                }
                if actual.approximatelyEqual(to: placement.frame, tolerance: 1.5) { continue }
                targets[placement.id] = placement.frame
                transitions.append(FrameAnimator.Transition(window: window, from: actual, to: placement.frame))
                continue
            }
            // 动画路径：有缓存时先以缓存判断，命中"无需移动"时仍以 AX 核对一次，
            // 防止 Space 滑动画中间态把 stale 位置误判为已到位。
            // 正在动画的窗口例外：lastSent 就是我们刚下发的帧，可信，
            // 无需同步 AX 读——连续按键改道时这里是每 tick 热路径。
            if let cached = animator.lastSent[placement.id] {
                let animating = animator.hasTarget(for: placement.id)
                if cached.approximatelyEqual(to: placement.frame, tolerance: 1.5) {
                    if !animating,
                       let actual = window.frame(),
                       !actual.approximatelyEqual(to: placement.frame, tolerance: 1.5) {
                        targets[placement.id] = placement.frame
                        transitions.append(FrameAnimator.Transition(window: window, from: actual, to: placement.frame))
                    }
                    continue
                }
                let from: CGRect
                if !animating, let actual = window.frame(), abs(actual.minX - cached.minX) > 8 {
                    from = actual
                } else {
                    from = cached
                }
                if from.approximatelyEqual(to: placement.frame, tolerance: 1.5) { continue }
                targets[placement.id] = placement.frame
                transitions.append(FrameAnimator.Transition(window: window, from: from, to: placement.frame))
                continue
            }
            guard let actual = window.frame() else {
                animator.applyInstantly(window: window, rect: placement.frame)
                continue
            }
            if actual.approximatelyEqual(to: placement.frame, tolerance: 1.5) { continue }
            targets[placement.id] = placement.frame
            transitions.append(FrameAnimator.Transition(window: window, from: actual, to: placement.frame))
        }

        rememberLayoutSignature()
        visualViewportOffset = strip.viewportOffset

        guard !transitions.isEmpty else {
            Log.debug("retile：全部在位，无下发")
            onStateChange?()
            return
        }
        Log.info("retile(animated=\(animated))：下发 \(transitions.count) 帧")

        if wantAnimation {
            configureAnimator(from: config)
            viewportSpring = nil
            // 已朝同一目标动画时不重启，避免重复触发的"橡皮筋"效应
            if !animator.isAnimating(toward: targets) {
                animator.animate(
                    transitions: transitions,
                    duration: config.animationDurationMs / 1000.0,
                    screen: nsScreen
                )
            }
        } else {
            animator.cancel()
            viewportSpring = nil
            for transition in transitions {
                animator.applyInstantly(window: transition.window, rect: transition.to)
            }
        }
        onStateChange?()
    }

    private func rememberLayoutSignature() {
        layoutColumnIDs = strip.windowIDs
        layoutFractions = strip.columns.map(\.fraction)
    }

    private func resetVisualViewport() {
        visualViewportOffset = nil
        viewportSpring = nil
        layoutColumnIDs = []
        layoutFractions = []
    }

    private func fractionsMatchCurrentLayout() -> Bool {
        layoutFractions.count == strip.columns.count
            && zip(layoutFractions, strip.columns.map(\.fraction)).allSatisfy { abs($0 - $1) < 0.0005 }
    }

    private func shouldSlideViewport(
        from: CGFloat, to: CGFloat, instantIDs: Set<CGWindowID>
    ) -> Bool {
        instantIDs.isEmpty
            && layoutColumnIDs == strip.windowIDs
            && fractionsMatchCurrentLayout()
            && abs(from - to) > 0.5
            && (animator.isLayoutAnimating || !animator.isRunning)
    }

    private func currentVisualOffset() -> CGFloat {
        visualViewportOffset ?? strip.viewportOffset
    }

    private func startViewportSlide(
        from: CGFloat,
        to: CGFloat,
        placements: [WindowPlacement],
        nsScreen: NSScreen,
        screen: CGRect,
        viewport: CGRect
    ) {
        var targets: [CGWindowID: CGRect] = [:]
        for placement in placements {
            guard windows[placement.id] != nil else { continue }
            targets[placement.id] = placement.frame
        }
        if animator.isLayoutAnimating, animator.isAnimating(toward: targets) {
            return
        }

        let liveFrom: CGFloat
        let inheritedVelocity: Double
        if let spring = viewportSpring, animator.isLayoutAnimating {
            let elapsed = max(0, CACurrentMediaTime() - viewportAnimStart)
            liveFrom = CGFloat(spring.value(at: elapsed))
            inheritedVelocity = spring.velocity(at: elapsed)
        } else {
            liveFrom = from
            inheritedVelocity = 0
        }

        configureAnimator(from: config)
        layoutAnimScreen = screen
        layoutAnimViewport = viewport
        viewportAnimStart = CACurrentMediaTime()
        viewportEasingFrom = liveFrom
        viewportEasingTo = to
        visualViewportOffset = liveFrom

        let duration: TimeInterval
        if config.animationMode == .spring {
            let spring = ScalarSpring(
                from: Double(liveFrom),
                to: Double(to),
                initialVelocity: inheritedVelocity,
                parameters: animator.springParameters
            )
            viewportSpring = spring
            duration = spring.settlingDuration
        } else {
            viewportSpring = nil
            duration = config.animationDurationMs / 1000.0
        }
        viewportAnimDuration = duration
        Log.info("retile：视口滑动 \(Int(liveFrom)) → \(Int(to))")
        animator.animateLayout(duration: duration, targets: targets, screen: nsScreen)
    }

    private func sampleViewportLayout(
        elapsed: TimeInterval, isFinal: Bool
    ) -> [(window: AXWindow, rect: CGRect)] {
        let offset: CGFloat
        if isFinal {
            offset = strip.viewportOffset
            visualViewportOffset = offset
            viewportSpring = nil
        } else if let spring = viewportSpring {
            offset = CGFloat(spring.value(at: elapsed))
            visualViewportOffset = offset
        } else {
            let t = viewportAnimDuration > 0 ? min(1, elapsed / viewportAnimDuration) : 1
            offset = Interpolation.lerp(viewportEasingFrom, viewportEasingTo, animator.curve.value(t))
            visualViewportOffset = offset
        }

        var visual = strip
        visual.viewportOffset = offset
        let placements = LayoutEngine.computeLayout(
            visual, viewport: layoutAnimViewport, screen: layoutAnimScreen, spec: spec
        )
        layoutFrames = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0.frame) })
        return placements.compactMap { placement in
            guard let window = windows[placement.id] else { return nil }
            return (window, placement.frame)
        }
    }

    /// Space 切换后的快照日志：窗口真实位置 vs 布局目标，诊断重叠根因
    private func logLayoutSnapshot(_ tag: String) {
        guard let nsScreen = layoutScreen() else { return }
        let screen = ScreenGeometry.axVisible(of: nsScreen)
        let viewport = LayoutEngine.viewport(screen: screen, spec: spec)
        let placements = LayoutEngine.computeLayout(strip, viewport: viewport, screen: screen, spec: spec)
        var parts: [String] = []
        for placement in placements {
            let actual = windows[placement.id]?.frame()
            let actualDesc = actual.map { "x=\(Int($0.minX))" } ?? "nil"
            parts.append("#\(placement.id) 目标x=\(Int(placement.frame.minX)) 实际\(actualDesc)")
        }
        Log.info("快照[\(tag)]：\(parts.joined(separator: " | "))")
    }

    private func scheduleRetile(
        after delay: TimeInterval = 0.08, reveal: Bool = true, animated: Bool = true
    ) {
        guard commandDrag == nil else { return }
        retileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.retile(reveal: reveal, animated: animated)
        }
        retileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleReconcile(after delay: TimeInterval = 0.3) {
        guard commandDrag == nil else { return }
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - AX 事件

    func handleAXEvent(notification: String, element: AXUIElement, refcon: UnsafeMutableRawPointer?) {
        switch notification {
        case kAXWindowCreatedNotification:
            handleWindowCreated(element: element)
        case kAXFocusedWindowChangedNotification:
            handleFocusChanged(element: element)
        case kAXUIElementDestroyedNotification:
            if let id = windowID(from: refcon) { handleWindowGone(id) }
        case kAXWindowMiniaturizedNotification:
            if let id = windowID(from: refcon) {
                rememberColumn(id)
                strip.remove(id: id)
                scheduleRetile(after: 0.05)
            }
        case kAXWindowDeminiaturizedNotification:
            if let id = windowID(from: refcon) { handleWindowRestored(id) }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let id = windowID(from: refcon) { handleExternalFrameChange(id) }
        default:
            break
        }
    }

    private func windowID(from refcon: UnsafeMutableRawPointer?) -> CGWindowID? {
        guard let refcon else { return nil }
        return CGWindowID(UInt(bitPattern: refcon))
    }

    private func handleWindowCreated(element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = apps[pid]
        else { return }
        retryWindowCreated(element: element, pid: pid, app: app, attempt: 0)
    }

    /// 刚创建时 AX 角色/几何经常还没就绪（windowID 都取不到），多重试几拍，
    /// 避免落到对账末尾追加，更不要永远等用户点一下才收编。
    private func retryWindowCreated(element: AXUIElement, pid: pid_t, app: AXApplication, attempt: Int) {
        if let window = AXWindow(element: element, pid: pid) {
            registerWindow(window, app: app)
            guard !paused else { return }
            if tryEnrollNewWindow(window) { return }
            if strip.contains(window.windowID) || floating.contains(window.windowID) { return }
        }
        guard attempt < 12 else {
            Log.debug("created 重试超时：pid=\(pid)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.retryWindowCreated(element: element, pid: pid, app: app, attempt: attempt + 1)
        }
    }

    /// 把新窗口插到当前焦点列右侧。真正入列或改浮动时返回 true。
    /// 若该窗口有 park 记忆（全屏/切 Space/最小化离开过），优先恢复原列宽与原列序。
    @discardableResult
    private func tryEnrollNewWindow(
        _ window: AXWindow, retileNow: Bool = true, ignoreCovering: Bool = false
    ) -> Bool {
        guard !paused else { return false }
        guard !strip.contains(window.windowID), !floating.contains(window.windowID) else { return false }
        if window.isFullscreen {
            return false
        }
        // 进入全屏宽限期内任何路径都不能拉回。之前在几何尚未盖满屏时会提前清掉宽限期，
        // 导致全屏窗先插进空纸带，随后普通列再回来，顺序取决于 AX 事件先后。
        if let until = fullscreenParkUntil[window.windowID] {
            if CACurrentMediaTime() < until { return false }
            fullscreenParkUntil.removeValue(forKey: window.windowID)
        }
        if !ignoreCovering, coversDisplay(window) {
            if nativeFullscreenParked.contains(window.windowID) {
                scheduleFullscreenExitCatchup(window.windowID)
            }
            return false
        }
        guard isTileable(window, on: layoutScreen(), ignoreCovering: ignoreCovering) else { return false }
        if window.isSizeSettable {
            let restored: Bool
            if let remembered = rememberedColumns[window.windowID] {
                // 绝对 index 只有在原来位于左侧的列都已回来后才有意义；否则钳位到
                // strip.count 会把右侧窗口提前塞到最左/中间，之后批量恢复也无法纠正。
                if hasPendingRememberedPredecessor(for: window.windowID, index: remembered.index) {
                    scheduleReconcile(after: 0.08)
                    return false
                }
                let index = min(max(0, remembered.index), strip.count)
                strip.insert(
                    id: window.windowID,
                    at: index,
                    fraction: remembered.fraction.clamped(0.15, 1.0),
                    savedFraction: remembered.savedFraction
                )
                rememberedColumns.removeValue(forKey: window.windowID)
                prepareRestoredColumn(window.windowID)
                restored = true
                Log.info("恢复列 #\(window.windowID) → 原位 \(index) 宽 \(String(format: "%.2f", remembered.fraction))")
            } else {
                let anchor = strip.focusedID.map { "#\($0)" } ?? "nil"
                strip.insertAdjacentToFocused(
                    id: window.windowID, fraction: config.defaultWidth, side: insertSide
                )
                markSticky(window.windowID)
                pendingInstantPlace.insert(window.windowID)
                restored = false
                let sideText = insertSide == .left ? "左侧" : "右侧"
                Log.info("新窗口入列 #\(window.windowID) 插在 \(anchor) \(sideText) index=\(strip.focusedIndex ?? -1)/\(strip.count)")
            }
            fullscreenParkUntil.removeValue(forKey: window.windowID)
            nativeFullscreenParked.remove(window.windowID)
            fullscreenFocusRingSuppressed.remove(window.windowID)
            fullscreenExitWork[window.windowID]?.cancel()
            fullscreenExitWork.removeValue(forKey: window.windowID)
            if retileNow { retile() }
            if !restored { scheduleLayoutEnforcement(window.windowID) }
            return true
        }
        floating.insert(window.windowID)
        Log.info("固定尺寸窗口浮动 #\(window.windowID) \(window.title)")
        return true
    }

    /// 恢复某列前，确认原来位于它左侧且仍存在的记忆列已经回到纸带。
    private func hasPendingRememberedPredecessor(for id: CGWindowID, index: Int) -> Bool {
        rememberedColumns.contains { otherID, remembered in
            otherID != id
                && remembered.index < index
                && windows[otherID] != nil
                && !strip.contains(otherID)
        }
    }

    /// 全屏/Space 返回的是已有列：清掉过渡遗留并只做一次瞬时落位。
    /// 不使用新窗口的 sticky + 多次强制写帧，否则切焦点动画会与 enforcement 互相打架。
    private func prepareRestoredColumn(_ id: CGWindowID) {
        settleWork[id]?.cancel()
        settleWork.removeValue(forKey: id)
        fullscreenExitWork[id]?.cancel()
        fullscreenExitWork.removeValue(forKey: id)
        fullscreenParkUntil.removeValue(forKey: id)
        nativeFullscreenParked.remove(id)
        fullscreenFocusRingSuppressed.remove(id)
        pendingFrames.removeValue(forKey: id)
        stickyUntil.removeValue(forKey: id)
        restoredQuietUntil[id] = CACurrentMediaTime() + 1.0
        animator.invalidate(id)
        pendingInstantPlace.insert(id)
    }

    private func markSticky(_ id: CGWindowID) {
        stickyUntil[id] = CACurrentMediaTime() + 2.4
    }

    private func isSticky(_ id: CGWindowID) -> Bool {
        guard let until = stickyUntil[id] else { return false }
        if CACurrentMediaTime() < until { return true }
        stickyUntil.removeValue(forKey: id)
        return false
    }

    private func isRestoredQuiet(_ id: CGWindowID) -> Bool {
        guard let until = restoredQuietUntil[id] else { return false }
        if CACurrentMediaTime() < until { return true }
        restoredQuietUntil.removeValue(forKey: id)
        return false
    }

    private func hasStickyWindows() -> Bool {
        let now = CACurrentMediaTime()
        stickyUntil = stickyUntil.filter { $0.value > now }
        return !stickyUntil.isEmpty
    }

    /// Electron / 系统恢复默认几何会把窗口弹回中央；按布局目标连写几次。
    private func scheduleLayoutEnforcement(_ id: CGWindowID) {
        for delay in [0.08, 0.22, 0.55, 1.1, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enforceLayout(for: id)
            }
        }
    }

    private func enforceLayout(for id: CGWindowID) {
        guard !paused, strip.contains(id), let window = windows[id],
              let rect = layoutFrames[id]
        else { return }
        animator.applyInstantly(window: window, rect: rect)
    }

    private func handleFocusChanged(element: AXUIElement) {
        var wid: CGWindowID = 0
        var pid: pid_t = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0,
              AXUIElementGetPid(element, &pid) == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else {
            focusRing.hideIfNotAlwaysOn()
            return
        }
        lastFocusedID = wid
        if commandDrag != nil { return }
        guard !paused else {
            focusRing.hide()
            return
        }
        guard strip.contains(wid) else {
            // 保存框、偏好设置、微信子窗口等非纸带窗口获得焦点时，不让旧亮边穿过它。
            focusRing.hideIfNotAlwaysOn()
            if let window = windows[wid], tryEnrollNewWindow(window) {
                refreshFocusRing()
                return
            }
            if nativeFullscreenParked.contains(wid) {
                scheduleFullscreenExitCatchup(wid)
            }
            // 焦点跑到另一块屏上的普通窗口：重建该屏纸带，避免外接屏继续用主屏几何。
            if let window = windows[wid], isTileable(window), !fillsTilingViewport(window) {
                scheduleReconcile(after: 0.05)
            }
            return
        }
        if strip.focusedID != wid {
            strip.focus(id: wid)
            scheduleRetile(after: 0.02)
        }
        refreshFocusRing()
    }

    private func handleWindowGone(_ id: CGWindowID) {
        // 普通 Space 暂离窗口若真的关闭，必须清掉记忆；仅真实全屏窗口允许 AX 元素
        // 在过渡中短暂销毁后继续保留。把“已有记忆”本身当保留理由会留下幽灵前驱，阻塞排序。
        let keepFullscreenMemory = nativeFullscreenParked.contains(id)
            || (windows[id].map { $0.isFullscreen || coversDisplay($0) } ?? false)
        if strip.contains(id) {
            rememberColumn(id, forFullscreen: keepFullscreenMemory)
            strip.remove(id: id)
            Log.debug("窗口离场 #\(id)")
            scheduleRetile(after: 0.05)
        }
        windows.removeValue(forKey: id)
        stickyUntil.removeValue(forKey: id)
        restoredQuietUntil.removeValue(forKey: id)
        pendingInstantPlace.remove(id)
        layoutFrames.removeValue(forKey: id)
        floating.remove(id)
        focusRing.forget(id)
        pendingFrames.removeValue(forKey: id)
        externallyTouched.remove(id)
        fullscreenExitWork[id]?.cancel()
        fullscreenExitWork.removeValue(forKey: id)
        if commandDrag?.id == id {
            stopCommandDragPoll()
            commandDrag = nil
        }
        animator.forget(id)
        for app in apps.values { app.forgetWindow(id) }
        if !keepFullscreenMemory {
            rememberedColumns.removeValue(forKey: id)
            fullscreenParkUntil.removeValue(forKey: id)
            nativeFullscreenParked.remove(id)
            fullscreenFocusRingSuppressed.remove(id)
        }
    }

    private func handleWindowRestored(_ id: CGWindowID) {
        guard !paused, let window = windows[id], isTileable(window, on: layoutScreen()),
              !strip.contains(id), !floating.contains(id)
        else { return }
        if rememberedColumns[id] != nil {
            // 有记忆（最小化前）：恢复原列宽与列序
            _ = tryEnrollNewWindow(window)
            return
        }
        // 无记忆（如重启后取消最小化）：按当前实际宽度反推列宽
        let viewportWidth = layoutScreen().map {
            LayoutEngine.viewport(screen: ScreenGeometry.axVisible(of: $0), spec: spec).width
        } ?? 0
        let fraction = restoredFraction(for: id, window: window, viewportWidth: viewportWidth)
        strip.insertAdjacentToFocused(id: id, fraction: fraction, side: insertSide)
        markSticky(id)
        pendingInstantPlace.insert(id)
        retile()
        scheduleLayoutEnforcement(id)
    }

    /// moved/resized 事件：区分回声、用户拖拽、外部改动、视频全屏
    private func handleExternalFrameChange(_ id: CGWindowID) {
        guard let window = windows[id] else { return }
        if commandDrag?.id == id { return }
        if isRestoredQuiet(id) { return }

        if let frame = window.frame(), isFullscreenFocusRingCandidate(window, frame: frame) {
            suppressFocusRingForFullscreen(id)
        }

        // 标题栏双击后的系统 fill 动画：不要中途按旧列宽回弹
        if isZoomCandidate(id) { return }

        // 新窗口开启动画会在中央反复改尺寸；不要取消我们的落位去跟着它跑。
        if isSticky(id) {
            if let target = layoutFrames[id] ?? animator.currentTargets[id] {
                animator.applyInstantly(window: window, rect: target)
            }
            return
        }

        guard let current = window.frame() else { return }

        // 动画/回声：接近我们下发的帧才吞掉。尺寸骤变是系统 zoom，不是回声。
        if animator.hasTarget(for: id) {
            if let target = animator.currentTargets[id], !isExternalSizeJump(from: target, to: current) {
                return
            }
            // 刚改列宽时窗口还停在旧尺寸，和目标差很大是正常的；真正的系统铺满另算。
            if let pending = pendingFrames[id],
               CACurrentMediaTime() - pending.timestamp < 1.0,
               !fillsTilingViewport(window) {
                return
            }
            animator.cancelAnimation(for: id)
        }

        if let pending = pendingFrames[id] {
            if current.approximatelyEqual(to: pending.rect, tolerance: 2.0) {
                pendingFrames.removeValue(forKey: id)
                return
            }
            if CACurrentMediaTime() - pending.timestamp < 1.0, !fillsTilingViewport(window) {
                return
            }
            pendingFrames.removeValue(forKey: id)
        }

        guard !paused else { return }

        if window.isFullscreen || isSystemFullscreen(window) {
            if strip.contains(id) {
                parkForFullscreen(id)
            } else if !window.isFullscreen, nativeFullscreenParked.contains(id) {
                scheduleFullscreenExitCatchup(id)
            }
            return
        }

        // 退出全屏后重新收编，用记住的列宽而不是当前的满屏尺寸
        if !strip.contains(id) {
            if tryEnrollNewWindow(window) { return }
            if isTileable(window, on: layoutScreen()), !floating.contains(id),
               !fillsTilingViewport(window) {
                scheduleReconcile(after: 0.08)
            }
            return
        }

        animator.invalidate(id)

        if NSEvent.pressedMouseButtons & 0x1 != 0 {
            externallyTouched.insert(id)
            return
        }

        // 系统 fill/zoom 会连发 moved+resized。先等落定再决定全宽还是吸收列宽。
        scheduleSettle(id, after: 0.22)
    }

    private func isExternalSizeJump(from old: CGRect, to new: CGRect) -> Bool {
        abs(new.width - old.width) > 40 || abs(new.height - old.height) > 40
    }

    private func isZoomCandidate(_ id: CGWindowID) -> Bool {
        guard let until = zoomCandidateUntil[id] else { return false }
        if CACurrentMediaTime() < until { return true }
        zoomCandidateUntil.removeValue(forKey: id)
        return false
    }

    private func scheduleSettle(_ id: CGWindowID, after delay: TimeInterval) {
        settleWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.settleExternalFrame(id)
        }
        settleWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func settleExternalFrame(_ id: CGWindowID) {
        settleWork[id] = nil
        zoomCandidateUntil.removeValue(forKey: id)
        guard !paused, commandDrag == nil, let window = windows[id] else { return }
        if isSticky(id) { return }

        if window.isFullscreen || isSystemFullscreen(window) {
            if strip.contains(id) {
                parkForFullscreen(id)
            } else if !window.isFullscreen, nativeFullscreenParked.contains(id) {
                scheduleFullscreenExitCatchup(id)
            }
            return
        }
        if !strip.contains(id) {
            if tryEnrollNewWindow(window) { return }
            if isTileable(window, on: layoutScreen()), !floating.contains(id),
               !fillsTilingViewport(window) {
                scheduleReconcile(after: 0.05)
            }
            return
        }

        // 只是在放大、最终没有进入全屏：settle 后撤销提前抑制，恢复焦点框。
        if fullscreenFocusRingSuppressed.remove(id) != nil {
            refreshFocusRing()
        }
        animator.invalidate(id)
        if adoptZoomedFill(id) {
            scheduleRetile(after: 0.02)
            return
        }
        if let frame = window.frame(),
           let nsScreen = layoutScreen() {
            let viewport = LayoutEngine.viewport(
                screen: ScreenGeometry.axVisible(of: nsScreen), spec: spec
            )
            if frame.height < viewport.height * 0.85 {
                Log.info("外部改帧落定 #\(id) 高度未铺满 \(Int(frame.height))<\(Int(viewport.height))，强制重排")
                retile()
                scheduleLayoutEnforcement(id)
                return
            }
            Log.info("外部改帧落定 #\(id) \(Int(frame.width))x\(Int(frame.height))")
        }
        adoptExternalWidth(id)
        scheduleRetile(after: 0.02)
    }

    private func parkForFullscreen(_ id: CGWindowID) {
        suppressFocusRingForFullscreen(id)
        guard strip.contains(id) else { return }
        rememberColumn(id, forFullscreen: true)
        strip.remove(id: id)
        // 只挡住「正在进入」的短暂过渡；真正退出后由 catchup 收编，不能用数秒禁收编把窗口卡死。
        fullscreenParkUntil[id] = CACurrentMediaTime() + 1.2
        if windows[id]?.isFullscreen == true {
            nativeFullscreenParked.insert(id)
        }
        focusRing.hide()
        Log.info("全屏：#\(id) 暂离纸带，保留列宽与列序")
        scheduleRetile(after: 0.05)
    }

    /// 退出全屏后几何还盖住整屏（Preview 黑底等）时轮询：等动画结束，超时则强制拉回纸带。
    private func scheduleFullscreenExitCatchup(_ id: CGWindowID, attempt: Int = 0) {
        guard !paused, !strip.contains(id) else { return }
        if attempt == 0, fullscreenExitWork[id] != nil { return }
        fullscreenExitWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pollFullscreenExit(id, attempt: attempt)
        }
        fullscreenExitWork[id] = work
        let delay: TimeInterval = attempt == 0 ? 0.18 : 0.12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func pollFullscreenExit(_ id: CGWindowID, attempt: Int) {
        fullscreenExitWork[id] = nil
        guard !paused, !strip.contains(id), !floating.contains(id) else { return }
        guard let window = windows[id] else {
            if rememberedColumns[id] != nil, attempt < 20 {
                scheduleFullscreenExitCatchup(id, attempt: attempt + 1)
            }
            return
        }
        if window.isFullscreen {
            if attempt < 16 {
                scheduleFullscreenExitCatchup(id, attempt: attempt + 1)
            }
            return
        }
        if let until = fullscreenParkUntil[id], CACurrentMediaTime() < until {
            scheduleFullscreenExitCatchup(id, attempt: attempt)
            return
        }
        let covering = coversDisplay(window)
        if covering, attempt < 12 {
            scheduleFullscreenExitCatchup(id, attempt: attempt + 1)
            return
        }
        let force = covering && nativeFullscreenParked.contains(id)
        if covering, !force { return }
        if tryEnrollNewWindow(window, retileNow: true, ignoreCovering: covering) {
            Log.info("全屏退出收编 #\(id) covering=\(covering) attempt=\(attempt)")
        } else if attempt < 24 {
            scheduleFullscreenExitCatchup(id, attempt: attempt + 1)
        }
    }

    private func fillsTilingViewport(_ window: AXWindow) -> Bool {
        guard let frame = window.frame(),
              let ns = ScreenGeometry.screen(containingAX: frame) ?? layoutScreen()
        else { return false }
        let visible = ScreenGeometry.axVisible(of: ns)
        let viewport = LayoutEngine.viewport(screen: visible, spec: spec)
        func nearlyFills(_ target: CGRect) -> Bool {
            guard target.width > 1, target.height > 1 else { return false }
            return frame.width >= target.width * 0.9
                && frame.height >= target.height * 0.9
                && frame.width >= target.width - 32
                && frame.height >= target.height - 32
        }
        // 纸带视口、系统「填满」可见区，或盖住整屏（含菜单栏）都算铺满。
        return nearlyFills(viewport) || nearlyFills(visible) || nearlyFills(ScreenGeometry.axFull(of: ns))
    }

    private func commandModifierHeld(on event: NSEvent) -> Bool {
        let mask = NSEvent.ModifierFlags.deviceIndependentFlagsMask
        return event.modifierFlags.intersection(mask).contains(.command)
            || NSEvent.modifierFlags.intersection(mask).contains(.command)
    }

    private func handleMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if commandModifierHeld(on: event) {
                beginCommandDragIfNeeded()
            } else {
                // 命中检测含 CGWindowList + 逐列 AX 读，一次点击只做一次，两处共用。
                let ax = ScreenGeometry.axPoint(fromAppKit: NSEvent.mouseLocation)
                let hit = tiledWindowID(atAX: ax)
                noteTitleBarClick(hit: hit, at: ax)
                // 点击已聚焦窗口时系统把窗口抬到最顶、盖住同级的边框面板，
                // 且这种点击不产生 AX 焦点通知；点落点检测到是焦点列时立即重排。
                if let focused = strip.focusedID, hit == focused,
                   !fullscreenFocusRingSuppressed.contains(focused) {
                    focusRing.reorderAbove(focused)
                }
            }
        case .leftMouseDragged:
            if commandDrag == nil, commandModifierHeld(on: event) {
                beginCommandDragIfNeeded()
            }
            applyCommandDragMouse()
        case .leftMouseUp:
            if commandDrag != nil {
                finishCommandDrag()
            } else {
                mouseDidRelease()
            }
        default:
            break
        }
    }

    /// 标题栏双击命中检测。铺满由 beginTitleBarZoom 自己下发，不依赖 App 是否真的 fill。
    private func noteTitleBarClick(hit: CGWindowID?, at ax: CGPoint) {
        guard let id = hit,
              let frame = windows[id]?.frame()
        else {
            lastTitleClick = nil
            return
        }
        // 跳过交通灯；顶栏约 52pt 是双击填满的命中区。
        let titleBand = CGRect(
            x: frame.minX + 78,
            y: frame.minY,
            width: max(0, frame.width - 78),
            height: 52
        )
        guard titleBand.contains(ax) else {
            lastTitleClick = nil
            return
        }
        let now = CACurrentMediaTime()
        if let last = lastTitleClick,
           last.id == id,
           now - last.time <= NSEvent.doubleClickInterval,
           hypot(ax.x - last.point.x, ax.y - last.point.y) <= 8 {
            lastTitleClick = nil
            beginTitleBarZoom(id)
            return
        }
        lastTitleClick = (id, now, ax)
    }

    /// 标题栏双击 = 我们自己切换全宽（与 alt-f 相同）。
    /// 不能等系统 fill：Terminal 等 App 的双击是「按内容缩放」，窗口不会铺满，
    /// 若再按那个尺寸吸收列宽，看起来就是铺满被立刻拉回去。
    private func beginTitleBarZoom(_ id: CGWindowID) {
        guard strip.contains(id) else { return }
        retileWork?.cancel()
        settleWork[id]?.cancel()
        animator.cancelAnimation(for: id)
        pendingFrames.removeValue(forKey: id)
        externallyTouched.remove(id)
        strip.focus(id: id)
        lastFocusedID = id

        let wasFull = (strip.columns.first { $0.id == id }?.fraction ?? 0) >= 0.98
        if wasFull {
            strip.toggleFocusedFullWidth(fallback: config.defaultWidth)
            Log.info("标题栏双击 #\(id) 退出全宽")
        } else {
            strip.enterFullWidth(id: id)
            Log.info("标题栏双击 #\(id) 进入全宽")
        }

        zoomCandidateUntil[id] = CACurrentMediaTime() + 1.2
        scheduleRetile(after: 0.08)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.strip.contains(id), self.commandDrag == nil, !self.paused else { return }
            self.retile()
        }
    }

    /// 把 CG 命中映射到纸带上的标准窗口：点到 Chrome/Electron 子窗口时仍要拖到父列。
    private func tiledWindowID(atAX point: CGPoint) -> CGWindowID? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let candidates = strip.windowIDs.filter { id in
            !floating.contains(id) && windows[id]?.frame()?.insetBy(dx: -8, dy: -8).contains(point) == true
        }
        guard !candidates.isEmpty else { return nil }

        if let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] {
            for entry in info {
                if let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == selfPID { continue }
                guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                      let number = entry[kCGWindowNumber as String] as? UInt32
                else { continue }
                if candidates.contains(number) { return number }
                if windows[number] != nil, !strip.contains(number) { continue }
                if let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                   let match = candidates.first(where: { windows[$0]?.pid == pid })
                {
                    return match
                }
            }
        }
        if let focused = strip.focusedID, candidates.contains(focused) { return focused }
        return candidates.first
    }

    private func beginCommandDragIfNeeded() {
        guard !paused, commandDrag == nil else { return }
        guard NSEvent.modifierFlags.contains(.command) else { return }
        let ax = ScreenGeometry.axPoint(fromAppKit: NSEvent.mouseLocation)
        guard let id = tiledWindowID(atAX: ax),
              let frame = windows[id]?.frame()
        else { return }

        retileWork?.cancel()
        reconcileWork?.cancel()
        settleWork[id]?.cancel()
        zoomCandidateUntil.removeValue(forKey: id)
        animator.cancel()
        animator.invalidate(id)
        externallyTouched.insert(id)
        commandDrag = CommandDrag(
            id: id,
            grabOffset: CGPoint(x: ax.x - frame.minX, y: ax.y - frame.minY),
            startAX: ax,
            startFrame: frame,
            size: frame.size
        )
        strip.focus(id: id)
        lastFocusedID = id
        startCommandDragPoll()
        if let window = windows[id] {
            window.raise()
            focusRing.show(windowID: id, pid: window.pid, axFrame: frame, reorder: true)
        }
        Log.debug("Command 拖动开始 #\(id)")
    }

    private func startCommandDragPoll() {
        commandDragPoll?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pollCommandDrag()
        }
        commandDragPoll = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func pollCommandDrag() {
        if NSEvent.pressedMouseButtons & 0x1 == 0 {
            if commandDrag != nil { finishCommandDrag() }
            return
        }
        applyCommandDragMouse()
    }

    private func applyCommandDragMouse() {
        guard !paused, var drag = commandDrag, let window = windows[drag.id] else { return }
        let ax = ScreenGeometry.axPoint(fromAppKit: NSEvent.mouseLocation)
        if hypot(ax.x - drag.startAX.x, ax.y - drag.startAX.y) > 4 {
            drag.didMove = true
            commandDrag = drag
        }
        guard drag.didMove else { return }
        let origin = CGPoint(x: ax.x - drag.grabOffset.x, y: ax.y - drag.grabOffset.y)
        let frame = CGRect(origin: origin, size: drag.size)
        pendingFrames[drag.id] = PendingFrame(rect: frame, timestamp: CACurrentMediaTime())
        // 写入走 per-App 队列并合并飞行中帧：慢 App 只丢中间帧，不再拖住主线程。
        animator.dragMove(window: window, to: origin)
        // 亮边直接跟手画计算帧；真实帧由 dragMove 回读经 onVisualFrame 校正。
        focusRing.show(windowID: drag.id, pid: window.pid, axFrame: frame)
    }

    private func stopCommandDragPoll() {
        commandDragPoll?.invalidate()
        commandDragPoll = nil
    }

    private func finishCommandDrag() {
        guard let drag = commandDrag else { return }
        stopCommandDragPoll()
        commandDrag = nil
        animator.cancelDrag(for: drag.id)
        externallyTouched.remove(drag.id)
        defer { externallyTouched.removeAll() }

        let current = windows[drag.id]?.frame() ?? drag.startFrame
        let moved = drag.didMove
            || hypot(current.midX - drag.startFrame.midX, current.midY - drag.startFrame.midY) > 12
        guard moved, strip.contains(drag.id) else {
            refreshFocusRing()
            scheduleRetile(after: 0.05)
            return
        }

        let dest = dropIndex(for: drag.id, midX: current.midX)
        _ = strip.move(id: drag.id, toIndex: dest)
        strip.focus(id: drag.id)
        animator.invalidate(drag.id)
        Log.info("Command 拖动落点：#\(drag.id) → 列 \(dest)")
        retile()
        refreshFocusRing()
    }

    /// 按被拖窗口中心 x，相对其余列当前中心，计算应插入的最终下标。
    private func dropIndex(for id: CGWindowID, midX: CGFloat) -> Int {
        var dest = 0
        for other in strip.windowIDs where other != id {
            let otherMid = windows[other]?.frame()?.midX ?? 0
            if midX > otherMid { dest += 1 }
        }
        return dest
    }

    private func mouseDidRelease() {
        guard commandDrag == nil, !externallyTouched.isEmpty else { return }
        let ids = externallyTouched
        externallyTouched.removeAll()
        for id in ids {
            if isZoomCandidate(id) { continue }
            let current = windows[id]?.frame()
            let cached = animator.lastSent[id]
            // 纯拖动（尺寸没变）：立刻回弹到纸带。尺寸变了则可能是 zoom，等落定。
            if let current, let cached,
               abs(current.width - cached.width) <= 8,
               abs(current.height - cached.height) <= 8 {
                if current.approximatelyEqual(to: cached, tolerance: 8) {
                    continue
                }
                adoptExternalWidth(id)
                scheduleRetile(after: 0.05)
            } else {
                scheduleSettle(id, after: 0.22)
            }
        }
    }

    /// 标题栏双击填满屏幕：进入全宽列并保留原宽，便于再按 alt-f 还原。
    @discardableResult
    private func adoptZoomedFill(_ id: CGWindowID) -> Bool {
        guard let window = windows[id], fillsTilingViewport(window) else { return false }
        guard let column = strip.columns.first(where: { $0.id == id }),
              column.fraction < 0.98
        else { return false }
        strip.focus(id: id)
        lastFocusedID = id
        strip.enterFullWidth(id: id)
        Log.info("铺满：#\(id) \(Int(window.frame()?.width ?? 0))x\(Int(window.frame()?.height ?? 0)) 进入全宽（保留列宽 \(String(format: "%.2f", column.fraction))）")
        return true
    }

    /// 用户手动改了窗口宽度 → 吸收为列宽分数（niri 交互式调宽的精神）
    private func adoptExternalWidth(_ id: CGWindowID) {
        guard let window = windows[id], let frame = window.frame() else { return }
        absorbWidth(id, width: frame.width, tolerance: 0.02)
    }

    /// App 拒绝请求尺寸（例如 Music 最小宽度）后，把真实宽度反馈给纸带模型。
    /// 否则后续列仍按较小的请求宽度排列，视觉上必然互相覆盖。
    private func absorbConstrainedFrame(_ id: CGWindowID, rect: CGRect) {
        // 浏览器等会把一次 AX 改尺寸拆成很多中间帧。动画还在朝目标走时，
        // 不能把半路上的宽度写进列宽，否则 ⌘+ 每次只剩几像素。
        if animator.hasTarget(for: id),
           let target = animator.currentTargets[id],
           abs(target.width - rect.width) > 8 {
            return
        }
        guard absorbWidth(id, width: rect.width, tolerance: 0.01) else { return }
        scheduleRetile(after: 0.02, animated: true)
    }

    @discardableResult
    private func absorbWidth(_ id: CGWindowID, width: CGFloat, tolerance: Double) -> Bool {
        guard strip.contains(id), let nsScreen = layoutScreen() else { return false }
        let screen = ScreenGeometry.axVisible(of: nsScreen)
        let viewport = LayoutEngine.viewport(screen: screen, spec: spec)
        guard viewport.width > 0 else { return false }
        let fraction = Double((width / viewport.width).clamped(0.15, 1.0))
        guard let column = strip.columns.first(where: { $0.id == id }),
              abs(column.fraction - fraction) > tolerance
        else { return false }
        strip.setFraction(id: id, fraction: fraction, minFraction: 0.15)
        return true
    }

    // MARK: - NSWorkspace 事件

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        adoptApp(app)
        // Electron 类 App 的 AX 树就绪可以比 launch 通知晚十几秒（实测 ChatGPT 约 12s），
        // 单次短重试不够；持续轮询直到窗口出现，否则新窗口会一直卡在默认居中几何。
        pollLaunchWindows(app, remaining: 30)
        scheduleReconcile(after: 0.35)
    }

    private func pollLaunchWindows(_ app: NSRunningApplication, remaining: Int) {
        guard remaining > 0 else {
            Log.warn("启动轮询超时：pid=\(app.processIdentifier) 未完成收编")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if self.rescanAppWindows(app) { return }
            self.pollLaunchWindows(app, remaining: remaining - 1)
        }
    }

    /// 重扫某个 App 的窗口并收编。窗口全部落到纸带/浮动集才返回 true，
    /// 否则继续轮询——Electron 窗口刚出现时角色/几何可能还没就绪。
    private func rescanAppWindows(_ app: NSRunningApplication) -> Bool {
        guard let axApp = apps[app.processIdentifier] ?? adoptApp(app) else { return false }
        var found = false
        var allHandled = true
        var enrolled = false
        for element in axApp.windowElements() {
            guard let window = AXWindow(element: element, pid: app.processIdentifier) else { continue }
            found = true
            registerWindow(window, app: axApp)
            if strip.contains(window.windowID) || floating.contains(window.windowID) { continue }
            if didFinishStartup, !paused, tryEnrollNewWindow(window, retileNow: false) {
                enrolled = true
            } else {
                allHandled = false
            }
        }
        if enrolled { retile() }
        return found && allHandled
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        guard let axApp = apps.removeValue(forKey: pid) else { return }
        axApp.stopObserving()
        let goneIDs = windows.values.filter { $0.pid == pid }.map(\.windowID)
        for id in goneIDs { handleWindowGone(id) }
    }

    @objc private func appActivated(_ note: Notification) {
        guard !paused,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            focusRing.hideIfNotAlwaysOn()
            return
        }

        // App 激活通知先于 AX focusedWindow 就绪很常见。任何不确定状态先隐藏旧边框，
        // 再尝试即时收编；稍后 focused-window 通知/对账会恢复正确边框。
        focusRing.hideIfNotAlwaysOn()
        let axApp = apps[app.processIdentifier] ?? adoptApp(app)
        guard let focused = axApp?.focusedWindow() else {
            scheduleReconcile(after: 0.12)
            return
        }
        lastFocusedID = focused.windowID
        if tryEnrollNewWindow(focused) {
            refreshFocusRing()
            return
        }
        guard strip.contains(focused.windowID) else {
            focusRing.hideIfNotAlwaysOn()
            if nativeFullscreenParked.contains(focused.windowID) {
                scheduleFullscreenExitCatchup(focused.windowID)
            }
            if isTileable(focused), !fillsTilingViewport(focused) {
                scheduleReconcile(after: 0.05)
            }
            return
        }
        if strip.focusedID != focused.windowID {
            strip.focus(id: focused.windowID)
            scheduleRetile(after: 0.02)
        }
        refreshFocusRing()
    }

    @objc private func spaceChanged(_ note: Notification) {
        Log.info("收到 Space 切换通知")
        // Space 滑动画会让窗口在 0.4-0.7s 内处于中间态：
        // 若沿用 animator.lastSent 做差量对比，会误判为"已在目标位置"而跳过下发，
        // 切回后就会看到窗口重叠（retile 直接 return）。
        // 切 Space 时必须作废全部帧缓存与回声抑制，等待动画落定后再对账。
        animator.cancel()
        animator.invalidateAll()
        resetVisualViewport()
        pendingFrames.removeAll()
        externallyTouched.removeAll()
        zoomCandidateUntil.removeAll()
        settleWork.values.forEach { $0.cancel() }
        settleWork.removeAll()
        stopCommandDragPoll()
        commandDrag = nil
        // 系统的 Space 切场动画约 0.5s，activeSpaceDidChange 在动画结束后才发，
        // 但 AX frame / CGWindowList 仍有短暂滞后，安排两段对账兜底。
        scheduleReconcile(after: 0.35)
        // 普通 Space 暂离列只由 reconcile 按原 index 批量恢复；每列单独跑 catchup
        // 会按 AX 事件到达顺序插入，导致顺序漂移。这里只轮询真正 park 过的原生全屏窗。
        for id in nativeFullscreenParked where windows[id]?.isFullscreen != true {
            scheduleFullscreenExitCatchup(id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.reconcileLogged("spaceChanged+0.9s")
            self?.logLayoutSnapshot("spaceChanged+0.9s")
        }
    }

    @objc private func appVisibilityChanged(_ note: Notification) {
        animator.cancel()
        animator.invalidateAll()
        resetVisualViewport()
        pendingFrames.removeAll()
        scheduleReconcile(after: 0.2)
    }

    @objc private func sessionBecameActive(_ note: Notification) {
        focusRing.hideIfNotAlwaysOn()
        animator.cancel()
        animator.invalidateAll()
        resetVisualViewport()
        pendingFrames.removeAll()
        scheduleReconcile(after: 0.5)
    }

    @objc private func screenChanged(_ note: Notification) {
        Log.info("屏幕参数变化：\(NSScreen.screens.count) 屏")
        animator.cancel()
        animator.invalidateAll()
        resetVisualViewport()
        pendingFrames.removeAll()
        focusRing.hideIfNotAlwaysOn()
        scheduleReconcile(after: 0.3)
    }

    // MARK: - 动作

    func perform(_ action: WMAction) {
        if paused && action != .retile { return }
        switch action {
        case .focusLeft:
            if let id = strip.focusAdjacent(.left) { focusWindow(id) }
            retile()
        case .focusRight:
            if let id = strip.focusAdjacent(.right) { focusWindow(id) }
            retile()
        case .moveLeft:
            strip.moveFocused(.left)
            retile()
        case .moveRight:
            strip.moveFocused(.right)
            retile()
        case .cycleWidth:
            strip.cycleFocusedWidth(presets: config.widthPresets, minFraction: 0.15)
            retile()
        case .growWidth:
            resizeTarget(by: config.resizeStep)
        case .shrinkWidth:
            resizeTarget(by: -config.resizeStep)
        case .toggleFullWidth:
            strip.toggleFocusedFullWidth(fallback: config.defaultWidth)
            retile()
        case .centerColumn:
            if let nsScreen = layoutScreen() {
                let screen = ScreenGeometry.axVisible(of: nsScreen)
                let viewport = LayoutEngine.viewport(screen: screen, spec: spec)
                strip.viewportOffset = LayoutEngine.centeredOffset(
                    strip, viewportWidth: viewport.width, spec: spec
                )
                retile(reveal: false)
            }
        case .toggleFloat:
            toggleFloat()
        case .closeWindow:
            let target = lastFocusedID ?? strip.focusedID
            if let target, let window = windows[target] { window.close() }
        case .retile:
            reconcile()
        case .unbind:
            break
        }
    }

    /// 调宽：焦点是浮动窗则围绕中心等比缩放；平铺窗则调列宽。
    /// 浏览器等 App 对 AX 改尺寸有延迟，不能把中间帧吸回列宽，否则每次看起来只动几像素。
    private func resizeTarget(by delta: Double) {
        focusResizeTarget()
        if let target = lastFocusedID, floating.contains(target) {
            scaleFloatingWindow(target, factor: 1.0 + delta * 2)
        } else {
            strip.adjustFocusedWidth(by: delta, minFraction: 0.15)
            retile()
            refreshFocusRing()
        }
    }

    /// 快捷键应对准用户正在看的窗口，而不是纸带上可能已经过期的焦点列
    private func focusResizeTarget() {
        if let target = lastFocusedID, strip.contains(target), strip.focusedID != target {
            strip.focus(id: target)
        }
    }

    private func scaleFloatingWindow(_ id: CGWindowID, factor: Double) {
        guard let window = windows[id], let frame = window.frame(),
              let nsScreen = layoutScreen()
        else { return }
        let screen = ScreenGeometry.axVisible(of: nsScreen)
        let width = (frame.width * factor).clamped(240, screen.width)
        let height = (frame.height * factor).clamped(180, screen.height)
        var newFrame = CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
        // 缩放后保持在屏幕可用区内
        newFrame.origin.x = newFrame.origin.x
            .clamped(screen.minX, max(screen.minX, screen.maxX - newFrame.width))
        newFrame.origin.y = newFrame.origin.y
            .clamped(screen.minY, max(screen.minY, screen.maxY - newFrame.height))
        window.setFrame(newFrame)
    }

    /// 把焦点真正交给窗口：AXRaise + 激活所属 App
    private func focusWindow(_ id: CGWindowID) {
        guard let window = windows[id] else { return }
        // activate 尚未完成前先隐藏旧边框，避免它穿过新前台窗口。
        // 常驻模式下也先隐藏，refreshFocusRing 会在下一帧重新显示到新焦点
        focusRing.hide()
        window.raise()
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [])
        }
        lastFocusedID = id
        DispatchQueue.main.async { [weak self] in self?.refreshFocusRing() }
    }

    private func toggleFloat() {
        guard let target = lastFocusedID ?? strip.focusedID else { return }
        if floating.contains(target) {
            floating.remove(target)
            if let window = windows[target], isTileable(window), window.isSizeSettable {
                strip.insertAdjacentToFocused(
                    id: target, fraction: config.defaultWidth, side: insertSide
                )
            }
        } else if strip.contains(target) {
            strip.remove(id: target)
            floating.insert(target)
        }
        retile()
    }

    // MARK: - 暂停 / 配置

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        Log.info(value ? "已暂停管理" : "恢复管理")
        if value {
            focusRing.hide()
        } else {
            reconcile()
            refreshFocusRing()
        }
        onStateChange?()
    }

    func updateConfig(_ newConfig: Config) {
        let old = config
        config = newConfig
        guard old != newConfig else { return }
        configureAnimator(from: newConfig)
        if old.focusRingEnabled != newConfig.focusRingEnabled
            || old.focusRingWidth != newConfig.focusRingWidth
            || old.focusRingGlowRadius != newConfig.focusRingGlowRadius
            || old.focusRingAlwaysOn != newConfig.focusRingAlwaysOn {
            configureFocusRing(from: newConfig)
        }
        if old.compositorEnabled != newConfig.compositorEnabled {
            refreshCompositorBackend()
        }
        guard !paused else { return }
        if old.ignoreBundleIDs != newConfig.ignoreBundleIDs {
            applyIgnoreListChange(from: old.ignoreBundleIDs, to: newConfig.ignoreBundleIDs)
        } else if old.layoutSpec != newConfig.layoutSpec {
            // 布局参数变化直接平滑重排。不能只靠 reconcile：它在 sticky 宽限期 /
            // 动画运行中会整趟跳过 retile，设置改动会一直不生效。
            retile(animated: true)
        }
    }

    /// 忽略列表运行时变更：新增忽略的 App 立即释放其全部窗口，取消忽略的立即收编。
    private func applyIgnoreListChange(from old: Set<String>, to new: Set<String>) {
        let added = new.subtracting(old)
        let removed = old.subtracting(new)
        if !added.isEmpty {
            for (pid, app) in apps where app.bundleID.map(added.contains) == true {
                releaseApp(pid: pid, app: app)
            }
        }
        if !removed.isEmpty {
            for running in NSWorkspace.shared.runningApplications
            where running.bundleIdentifier.map(removed.contains) == true {
                adoptApp(running)
            }
        }
        reconcile()
    }

    /// 释放一个 App：停观察者、清窗口状态。与 appTerminated 相同语义，但 App 仍在运行。
    private func releaseApp(pid: pid_t, app: AXApplication) {
        apps.removeValue(forKey: pid)
        app.stopObserving()
        let goneIDs = windows.values.filter { $0.pid == pid }.map(\.windowID)
        for id in goneIDs { handleWindowGone(id) }
        Log.info("忽略列表：释放 App pid=\(pid) \(app.bundleID ?? "?")（\(goneIDs.count) 窗）")
    }

    // MARK: - 状态

    var statusSummary: String {
        "\(strip.count) 列 · 焦点 \(strip.focusedID.map(String.init) ?? "-")"
    }
}

// MARK: - AX 回调（C convention，经单例转发主线程逻辑）

private let axEventCallback: AXObserverCallback = { _, element, notification, refcon in
    WindowManager.shared?.handleAXEvent(
        notification: notification as String,
        element: element,
        refcon: refcon
    )
}

// MARK: - 几何辅助

extension CGRect {
    func approximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
