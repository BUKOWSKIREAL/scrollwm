import AppKit
import QuartzCore

/// 覆盖在焦点窗口上的蓝紫渐变亮边。
/// 使用独立、鼠标穿透的 NSPanel，因为 AX 没有修改其他 App 窗口装饰的 API。
///
/// Overlay 铺满窗口所在屏的 `NSScreen.frame`，亮边在屏内本地坐标绘制。
/// 这样 `setFrame` 不会落到错误的屏上，backing scale 也跟那块屏一致。
/// 窗口矩形走 AX / 布局的点坐标（`primaryMaxY`），不要用 `CGDisplayBounds`
/// 再缩一次：那会把点坐标当成像素，外接屏上整框错位。
final class FocusRingController {
    private let panel: NSPanel
    private let ringView: FocusRingView
    private var enabled = true
    private var alwaysOn = false
    private var currentWindowID: CGWindowID?
    private var currentPID: pid_t?
    private var currentAXFrame: CGRect?
    private var currentCornerRadius: CGFloat = 10
    private var attachedScreenID: CGDirectDisplayID?
    private var foregroundGuard: Timer?
    private var frontmostMismatchTicks = 0
    private var frontmostGraceUntil: CFTimeInterval = 0

    init() {
        ringView = FocusRingView(frame: .zero)
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = ringView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        // 比普通窗口高一级：点击提窗不会把亮边盖住，也就不必再 order 回去（那一下就是闪）。
        // 仍低于 .floating / 菜单 / 保存框，那些弹层会从透明区域透出来，或走 hide。
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) + 1)
        // transient 会在 Mission Control / Exposé 自动隐藏；stationary 会固定在桌面原位，
        // 造成窗口缩略图移动后留下贯穿屏幕的独立紫线。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.minSize = .zero
        panel.maxSize = NSSize(width: 20000, height: 20000)

        foregroundGuard = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.panel.isVisible else {
                self?.frontmostMismatchTicks = 0
                return
            }
            if self.alwaysOn { return }
            if CACurrentMediaTime() < self.frontmostGraceUntil {
                self.frontmostMismatchTicks = 0
                return
            }
            let pid = self.currentPID
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let pid, front == pid {
                self.frontmostMismatchTicks = 0
                return
            }
            // activate 完成前 frontmost 会对不上；连续对不上才藏，避免切窗口抽一帧。
            self.frontmostMismatchTicks += 1
            if self.frontmostMismatchTicks >= 3 {
                self.frontmostMismatchTicks = 0
                self.hide()
            }
        }
    }

    /// 键盘/点击切焦点后，忽略短暂的 frontmost 滞后。
    func beginFrontmostGrace(_ seconds: TimeInterval = 0.45) {
        frontmostGraceUntil = CACurrentMediaTime() + seconds
        frontmostMismatchTicks = 0
    }

    func configure(enabled: Bool, width: CGFloat, glowRadius: CGFloat, alwaysOn: Bool = false) {
        self.enabled = enabled
        self.alwaysOn = alwaysOn
        ringView.configure(width: width, glowRadius: glowRadius)
        if enabled, let id = currentWindowID, let pid = currentPID, let frame = currentAXFrame {
            show(windowID: id, pid: pid, axFrame: frame, cornerRadius: currentCornerRadius)
        } else if !enabled {
            hide()
        }
    }

    /// `axFrame` 必须是 Accessibility / 布局空间（主屏顶左、点）。
    func show(windowID: CGWindowID, pid: pid_t, axFrame: CGRect, reorder: Bool = false) {
        _ = reorder
        let radius = WindowChrome.cornerRadius(for: windowID)
        show(windowID: windowID, pid: pid, axFrame: axFrame, cornerRadius: radius)
    }

    private func show(
        windowID: CGWindowID,
        pid: pid_t,
        axFrame: CGRect,
        cornerRadius: CGFloat
    ) {
        let alreadyShowing = panel.isVisible && currentWindowID == windowID
        let targetChanged = currentWindowID != windowID
        let frameUnchanged = currentAXFrame.map { rectsClose($0, axFrame) } ?? false
        let radiusUnchanged = abs(currentCornerRadius - cornerRadius) < 0.5
        currentWindowID = windowID
        currentPID = pid
        currentAXFrame = axFrame
        currentCornerRadius = cornerRadius
        guard enabled, axFrame.width > 1, axFrame.height > 1 else {
            if !alreadyShowing { hidePanelOnly() }
            return
        }
        if !alwaysOn,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
           CACurrentMediaTime() >= frontmostGraceUntil,
           !panel.isVisible {
            return
        }
        guard let screen = ScreenGeometry.screen(containingWindowID: windowID)
                ?? ScreenGeometry.screen(containingAX: axFrame)
        else {
            if !alreadyShowing { hidePanelOnly() }
            return
        }

        let cocoa = ScreenGeometry.appKitRect(fromAX: axFrame)
        let screenFrame = screen.frame
        let local = cocoa.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        guard local.width > 1, local.height > 1 else {
            if !alreadyShowing { hidePanelOnly() }
            return
        }

        let displayID = ScreenGeometry.displayID(of: screen)
        let screenChanged = attachedScreenID != displayID
        attachedScreenID = displayID

        if panel.isVisible, !targetChanged, !screenChanged, frameUnchanged, radiusUnchanged {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !panel.isVisible || screenChanged
            || abs(panel.frame.minX - screenFrame.minX) > 0.5
            || abs(panel.frame.minY - screenFrame.minY) > 0.5
            || abs(panel.frame.width - screenFrame.width) > 0.5
            || abs(panel.frame.height - screenFrame.height) > 0.5
        {
            panel.setFrame(screenFrame, display: true)
        }
        ringView.syncContentsScale(from: panel)
        ringView.setWindowRect(local, cornerRadius: cornerRadius)
        CATransaction.commit()

        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func rectsClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    func hide() {
        currentWindowID = nil
        currentPID = nil
        currentAXFrame = nil
        currentCornerRadius = 10
        attachedScreenID = nil
        frontmostMismatchTicks = 0
        hidePanelOnly()
    }

    /// “跟随前台”的隐藏：常驻开启时不灭，真正要灭的地方请用 hide()
    func hideIfNotAlwaysOn() {
        if alwaysOn { return }
        hide()
    }

    func forget(_ windowID: CGWindowID) {
        if currentWindowID == windowID { hide() }
    }

    private func hidePanelOnly() {
        if panel.isVisible { panel.orderOut(nil) }
    }
}

private final class FocusRingView: NSView {
    private let glowLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let gradientMask = CALayer()
    private let highlightLayer = CALayer()

    private var ringWidth: CGFloat = 3
    private var glowRadius: CGFloat = 9
    /// 相对本 view（铺满那块屏）的窗口矩形，AppKit 底左。
    private var windowRect: CGRect = .zero
    private var cornerRadius: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        glowLayer.backgroundColor = NSColor.clear.cgColor
        glowLayer.borderColor = NSColor(calibratedRed: 0.30, green: 0.25, blue: 0.70, alpha: 0.55).cgColor
        glowLayer.shadowColor = NSColor(calibratedRed: 0.24, green: 0.36, blue: 0.72, alpha: 1).cgColor
        glowLayer.shadowOpacity = 0.38
        glowLayer.masksToBounds = false
        layer?.addSublayer(glowLayer)

        gradientLayer.colors = [
            NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.76, alpha: 0.88).cgColor,
            NSColor(calibratedRed: 0.38, green: 0.29, blue: 0.74, alpha: 0.90).cgColor,
            NSColor(calibratedRed: 0.55, green: 0.27, blue: 0.72, alpha: 0.88).cgColor,
            NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.76, alpha: 0.88).cgColor,
        ]
        gradientLayer.locations = [0, 0.38, 0.72, 1]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        gradientLayer.mask = gradientMask
        layer?.addSublayer(gradientLayer)

        highlightLayer.backgroundColor = NSColor.clear.cgColor
        highlightLayer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        highlightLayer.masksToBounds = false
        layer?.addSublayer(highlightLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncContentsScale(from: window)
        updateLayers()
    }

    func syncContentsScale(from window: NSWindow?) {
        let scale = window?.backingScaleFactor ?? 1
        layer?.contentsScale = scale
        glowLayer.contentsScale = scale
        gradientLayer.contentsScale = scale
        gradientMask.contentsScale = scale
        highlightLayer.contentsScale = scale
    }

    func configure(width: CGFloat, glowRadius: CGFloat) {
        ringWidth = width.clamped(1, 8)
        self.glowRadius = glowRadius.clamped(0, 24)
        updateLayers()
    }

    func setWindowRect(_ rect: CGRect, cornerRadius: CGFloat) {
        if abs(windowRect.minX - rect.minX) < 0.5,
           abs(windowRect.minY - rect.minY) < 0.5,
           abs(windowRect.width - rect.width) < 0.5,
           abs(windowRect.height - rect.height) < 0.5,
           abs(self.cornerRadius - cornerRadius) < 0.5 {
            return
        }
        windowRect = rect
        self.cornerRadius = cornerRadius
        updateLayers()
    }

    private func updateLayers() {
        guard windowRect.width > 2, windowRect.height > 2 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let radius = min(cornerRadius, min(windowRect.width, windowRect.height) / 2)

        applyRingStyle(glowLayer, frame: windowRect, radius: radius, borderWidth: ringWidth)
        glowLayer.shadowRadius = glowRadius
        glowLayer.shadowOffset = .zero
        glowLayer.shadowPath = nil

        gradientLayer.frame = bounds
        applyRingStyle(gradientMask, frame: windowRect, radius: radius, borderWidth: ringWidth)
        gradientMask.borderColor = NSColor.white.cgColor

        applyRingStyle(
            highlightLayer,
            frame: windowRect,
            radius: radius,
            borderWidth: max(0.75, ringWidth * 0.28)
        )

        CATransaction.commit()
    }

    private func applyRingStyle(_ layer: CALayer, frame: CGRect, radius: CGFloat, borderWidth: CGFloat) {
        layer.frame = frame
        layer.backgroundColor = NSColor.clear.cgColor
        layer.borderWidth = borderWidth
        layer.cornerRadius = radius
        // 系统窗口圆角是普通圆弧；.continuous 会更鼓，四角对不齐。
        layer.cornerCurve = .circular
        layer.masksToBounds = false
        layer.allowsEdgeAntialiasing = true
    }
}
