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
    private var mouseUpMonitor: Any?

    // 帧动画器（也承担 per-App 并行写队列与"当前帧"缓存）
    private let animator = FrameAnimator()
    private let focusRing = FocusRingController()

    // 合成器后端（SkyLight）。仅当 payload 已注入 Dock 且配置开启时启用，
    // 否则动画走 AX（batchSink 为 nil）。
    private let compositor = CompositorMover()

    // 去抖
    private var retileWork: DispatchWorkItem?
    private var reconcileWork: DispatchWorkItem?

    var onStateChange: (() -> Void)?

    private var spec: LayoutSpec { config.layoutSpec }

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
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == self.windows[id]?.pid
            else { return }
            guard let window = self.windows[id] else { return }
            self.focusRing.show(windowID: id, pid: window.pid, axFrame: rect)
        }
        animator.onConstrainedFrame = { [weak self] id, rect in
            self?.absorbConstrainedFrame(id, rect: rect)
        }
        configureAnimator(from: config)
        configureFocusRing(from: config)
    }

    private func configureAnimator(from config: Config) {
        animator.mode = config.animationMode
        animator.curve = config.animationCurve
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
            glowRadius: CGFloat(config.focusRingGlowRadius)
        )
        refreshFocusRing()
    }

    private func refreshFocusRing() {
        guard !paused, let id = strip.focusedID, let window = windows[id],
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
        else {
            focusRing.hide()
            return
        }
        // 动画期间 onVisualFrame 是权威；静止时优先用 CGWindow 几何，
        // 避免 AX 与外接屏 AppKit 坐标不一致时亮边缩在窗口内部。
        let frame: CGRect?
        if animator.hasTarget(for: id) {
            frame = animator.lastSent[id]
        } else {
            frame = OnScreenWindows.bounds(of: id) ?? window.frame()
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

        // 拖拽结束后统一处理外部改动
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.mouseDidRelease()
        }

        for app in NSWorkspace.shared.runningApplications {
            adoptApp(app)
        }
        refreshCompositorBackend()
        reconcile()
        // 若恰好在 Mission Control/锁屏状态启动，optionOnScreenOnly 会暂时返回空集合；
        // 界面恢复后再扫一次即可收编，无需重启守护进程。
        scheduleReconcile(after: 2.0)
        Log.info("窗口管理已启动：\(strip.count) 列")
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

        // 登记既有窗口的观察者（收编交给 reconcile 统一做）
        for element in app.windowElements() {
            if let window = AXWindow(element: element, pid: pid) {
                registerWindow(window, app: app)
            }
        }
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
    private func isTileable(_ window: AXWindow, on screen: NSScreen? = nil) -> Bool {
        guard window.isStandard, !window.isMinimized, !window.isFullscreen else { return false }
        guard let frame = window.frame() else { return false }
        let target = screen ?? ScreenGeometry.screen(containingAX: frame) ?? layoutScreen()
        guard let target else { return false }
        // 停靠列的大部分窗口在屏外，只露 screenMargin 宽纸边；重启后仍必须重新收编。
        return ScreenGeometry.intersects(frame, screen: target)
    }

    // MARK: - 全量对账

    /// 幂等的全量重扫：候选集与纸带对齐（增删），并同步观察者。
    func reconcile() {
        guard !paused else { return }
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

        // 移除已消失/不再合格的列
        for id in strip.windowIDs where tileable[id] == nil {
            Log.info("对账：移除列 #\(id)")
            strip.remove(id: id)
        }
        floating = floating.filter { id in
            windows[id] != nil && onScreen.contains(id)
        }

        // 新窗口按当前几何位置从左到右追加，保持视觉顺序
        let newIDs = tileable.keys
            .filter { !strip.contains($0) && !floating.contains($0) }
            .sorted { a, b in
                let fa = tileable[a]?.frame()?.minX ?? 0
                let fb = tileable[b]?.frame()?.minX ?? 0
                return fa < fb
            }
        for id in newIDs {
            Log.info("对账：新窗口入列 #\(id)")
            strip.append(id: id, fraction: config.defaultWidth)
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

        // 批量对账瞬时落位，不做动画
        retile(animated: false)
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
        guard !paused else { return }
        guard let nsScreen = layoutScreen() else { return }
        let screen = ScreenGeometry.axVisible(of: nsScreen)
        let viewport = LayoutEngine.viewport(screen: screen, spec: spec)

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
        Log.debug("retile(animated=\(animated))：\(placements.count) 个目标帧")

        // 差异收集：正常操作优先用写缓存避免全量 AX 读；切 Space/解锁后
        // lastSent 已在 spaceChanged 入口处全部作废，故会自然回落到 AX 实读，
        // 避免 stale 缓存把"已在目标"误判而跳过下发导致重叠。
        var transitions: [FrameAnimator.Transition] = []
        var targets: [CGWindowID: CGRect] = [:]
        for placement in placements {
            guard let window = windows[placement.id] else { continue }
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
            if let cached = animator.lastSent[placement.id] {
                if cached.approximatelyEqual(to: placement.frame, tolerance: 1.5) {
                    if let actual = window.frame(),
                       !actual.approximatelyEqual(to: placement.frame, tolerance: 1.5) {
                        targets[placement.id] = placement.frame
                        transitions.append(FrameAnimator.Transition(window: window, from: actual, to: placement.frame))
                    }
                    continue
                }
                let from: CGRect
                if let actual = window.frame(), abs(actual.minX - cached.minX) > 8 {
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

        guard !transitions.isEmpty else {
            Log.debug("retile：全部在位，无下发")
            onStateChange?()
            return
        }
        Log.info("retile(animated=\(animated))：下发 \(transitions.count) 帧")

        let animationHasDuration = config.animationMode == .spring || config.animationDurationMs > 0
        if animated, config.animationEnabled, animationHasDuration {
            configureAnimator(from: config)
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
            for transition in transitions {
                animator.applyInstantly(window: transition.window, rect: transition.to)
            }
        }
        onStateChange?()
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
        retileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.retile(reveal: reveal, animated: animated)
        }
        retileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleReconcile(after delay: TimeInterval = 0.3) {
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
              let app = apps[pid],
              let window = AXWindow(element: element, pid: pid)
        else { return }

        registerWindow(window, app: app)
        guard !paused, isTileable(window, on: layoutScreen()), !strip.contains(window.windowID) else { return }

        if window.isSizeSettable {
            strip.insertAdjacentToFocused(id: window.windowID, fraction: config.defaultWidth)
            Log.debug("新窗口入列 #\(window.windowID) \(window.title)")
            scheduleRetile(after: 0.03)
        } else {
            floating.insert(window.windowID)
            Log.debug("固定尺寸窗口浮动 #\(window.windowID) \(window.title)")
        }
    }

    private func handleFocusChanged(element: AXUIElement) {
        var wid: CGWindowID = 0
        var pid: pid_t = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0,
              AXUIElementGetPid(element, &pid) == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else {
            focusRing.hide()
            return
        }
        lastFocusedID = wid
        guard !paused else {
            focusRing.hide()
            return
        }
        guard strip.contains(wid) else {
            // 保存框、偏好设置、微信子窗口等非纸带窗口获得焦点时，不让旧亮边穿过它。
            focusRing.hide()
            // 焦点跑到另一块屏上的普通窗口：重建该屏纸带，避免外接屏继续用主屏几何。
            if let window = windows[wid], isTileable(window) {
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
        windows.removeValue(forKey: id)
        floating.remove(id)
        focusRing.forget(id)
        pendingFrames.removeValue(forKey: id)
        externallyTouched.remove(id)
        animator.forget(id)
        for app in apps.values { app.forgetWindow(id) }
        if strip.remove(id: id) {
            Log.debug("窗口离场 #\(id)")
            scheduleRetile(after: 0.05)
        }
    }

    private func handleWindowRestored(_ id: CGWindowID) {
        guard !paused, let window = windows[id], isTileable(window, on: layoutScreen()),
              !strip.contains(id), !floating.contains(id)
        else { return }
        strip.insertAdjacentToFocused(id: id, fraction: config.defaultWidth)
        scheduleRetile(after: 0.05)
    }

    /// moved/resized 事件：区分回声、用户拖拽、外部改动
    private func handleExternalFrameChange(_ id: CGWindowID) {
        guard let window = windows[id] else { return }

        // 动画进行中产生的事件全部视为回声
        if animator.hasTarget(for: id) { return }

        if let pending = pendingFrames[id] {
            if let current = window.frame(),
               current.approximatelyEqual(to: pending.rect, tolerance: 2.0) {
                pendingFrames.removeValue(forKey: id)
                return  // 我们下发的帧已落位
            }
            if CACurrentMediaTime() - pending.timestamp < 1.0 {
                return  // 还在落位过程中的中间帧
            }
            pendingFrames.removeValue(forKey: id)
        }

        guard !paused, strip.contains(id) else { return }

        // 外部真实改动：作废写缓存，后续布局读取真实帧
        animator.invalidate(id)

        if NSEvent.pressedMouseButtons & 0x1 != 0 {
            // 用户拖拽中：不抢，松手后统一结算
            externallyTouched.insert(id)
            return
        }
        adoptExternalWidth(id)
        scheduleRetile(after: 0.08)
    }

    private func mouseDidRelease() {
        guard !externallyTouched.isEmpty else { return }
        for id in externallyTouched {
            adoptExternalWidth(id)
        }
        externallyTouched.removeAll()
        // 位置回弹到纸带布局，宽度已被吸收进列分数
        scheduleRetile(after: 0.05)
    }

    /// 用户手动改了窗口宽度 → 吸收为列宽分数（niri 交互式调宽的精神）
    private func adoptExternalWidth(_ id: CGWindowID) {
        guard let window = windows[id], let frame = window.frame() else { return }
        absorbWidth(id, width: frame.width, tolerance: 0.02)
    }

    /// App 拒绝请求尺寸（例如 Music 最小宽度）后，把真实宽度反馈给纸带模型。
    /// 否则后续列仍按较小的请求宽度排列，视觉上必然互相覆盖。
    private func absorbConstrainedFrame(_ id: CGWindowID, rect: CGRect) {
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
        // App 的 AX 树就绪需要时间，延迟收编 + 再对账兜底
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.adoptApp(app)
            self?.scheduleReconcile(after: 1.0)
        }
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
            focusRing.hide()
            return
        }

        // App 激活通知先于 AX focusedWindow 就绪很常见。任何不确定状态先隐藏旧边框，
        // 再尝试即时收编；稍后 focused-window 通知/对账会恢复正确边框。
        focusRing.hide()
        let axApp = apps[app.processIdentifier] ?? adoptApp(app)
        guard let focused = axApp?.focusedWindow() else {
            scheduleReconcile(after: 0.15)
            return
        }
        lastFocusedID = focused.windowID
        guard strip.contains(focused.windowID) else {
            focusRing.hide()
            if isTileable(focused) {
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
        pendingFrames.removeAll()
        externallyTouched.removeAll()
        // 系统的 Space 切场动画约 0.5s，activeSpaceDidChange 在动画结束后才发，
        // 但 AX frame / CGWindowList 仍有短暂滞后，安排两段对账兜底。
        scheduleReconcile(after: 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.reconcileLogged("spaceChanged+0.9s")
            self?.logLayoutSnapshot("spaceChanged+0.9s")
        }
    }

    @objc private func appVisibilityChanged(_ note: Notification) {
        animator.cancel()
        animator.invalidateAll()
        pendingFrames.removeAll()
        scheduleReconcile(after: 0.2)
    }

    @objc private func sessionBecameActive(_ note: Notification) {
        focusRing.hide()
        animator.cancel()
        animator.invalidateAll()
        pendingFrames.removeAll()
        scheduleReconcile(after: 0.5)
    }

    @objc private func screenChanged(_ note: Notification) {
        Log.info("屏幕参数变化：\(NSScreen.screens.count) 屏")
        animator.cancel()
        animator.invalidateAll()
        pendingFrames.removeAll()
        focusRing.hide()
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

    /// 放大缩小：焦点是浮动窗则围绕中心等比缩放；平铺窗则调列宽
    private func resizeTarget(by delta: Double) {
        if let target = lastFocusedID, floating.contains(target) {
            scaleFloatingWindow(target, by: delta)
        } else {
            strip.adjustFocusedWidth(by: delta, minFraction: 0.15)
            retile()
            refreshFocusRing()
        }
    }

    private func scaleFloatingWindow(_ id: CGWindowID, by delta: Double) {
        guard let window = windows[id], let frame = window.frame(),
              let nsScreen = layoutScreen()
        else { return }
        let screen = ScreenGeometry.axVisible(of: nsScreen)
        let factor = 1.0 + delta * 2  // resize_step 0.05 → 每按一次 ±10%
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
                strip.insertAdjacentToFocused(id: target, fraction: config.defaultWidth)
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
        config = newConfig
        configureAnimator(from: newConfig)
        configureFocusRing(from: newConfig)
        refreshCompositorBackend()
        guard !paused else { return }
        reconcile()
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
