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
    private var currentWindowID: CGWindowID?
    private var currentPID: pid_t?
    private var currentAXFrame: CGRect?
    private var attachedScreenID: CGDirectDisplayID?
    private var foregroundGuard: Timer?

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
        // 与目标窗口同级，再用 relativeTo 排到它正上方。不能用 .floating，
        // 否则 Finder 保存框、浏览器弹窗会被焦点边框穿透覆盖。
        panel.level = .normal
        // transient 会在 Mission Control / Exposé 自动隐藏；stationary 会固定在桌面原位，
        // 造成窗口缩略图移动后留下贯穿屏幕的独立紫线。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.minSize = .zero
        panel.maxSize = NSSize(width: 20000, height: 20000)

        foregroundGuard = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            guard let pid = self.currentPID,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            else {
                self.hide()
                return
            }
        }
    }

    func configure(enabled: Bool, width: CGFloat, glowRadius: CGFloat) {
        self.enabled = enabled
        ringView.configure(width: width, glowRadius: glowRadius)
        if enabled, let id = currentWindowID, let pid = currentPID, let frame = currentAXFrame {
            show(windowID: id, pid: pid, axFrame: frame)
        } else if !enabled {
            hide()
        }
    }

    /// `axFrame` 必须是 Accessibility / 布局空间（主屏顶左、点）。
    func show(windowID: CGWindowID, pid: pid_t, axFrame: CGRect, reorder: Bool = false) {
        let targetChanged = currentWindowID != windowID
        currentWindowID = windowID
        currentPID = pid
        currentAXFrame = axFrame
        guard enabled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              axFrame.width > 1, axFrame.height > 1,
              let screen = ScreenGeometry.screen(containingWindowID: windowID)
                ?? ScreenGeometry.screen(containingAX: axFrame)
        else {
            hidePanelOnly()
            return
        }

        let cocoa = ScreenGeometry.appKitRect(fromAX: axFrame)
        let screenFrame = screen.frame
        let local = cocoa.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        guard local.width > 1, local.height > 1 else {
            hidePanelOnly()
            return
        }

        let displayID = ScreenGeometry.displayID(of: screen)
        let screenChanged = attachedScreenID != displayID
        attachedScreenID = displayID

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if screenChanged || abs(panel.frame.minX - screenFrame.minX) > 0.5
            || abs(panel.frame.minY - screenFrame.minY) > 0.5
            || abs(panel.frame.width - screenFrame.width) > 0.5
            || abs(panel.frame.height - screenFrame.height) > 0.5
        {
            panel.setFrame(screenFrame, display: true)
        }
        ringView.syncContentsScale(from: panel)
        ringView.setWindowRect(local)
        CATransaction.commit()

        if !panel.isVisible || targetChanged || reorder || screenChanged {
            panel.alphaValue = 1
            panel.order(.above, relativeTo: Int(windowID))
            panel.setFrame(screenFrame, display: true)
            ringView.setWindowRect(local)
        }
    }

    func hide() {
        currentWindowID = nil
        currentPID = nil
        currentAXFrame = nil
        attachedScreenID = nil
        hidePanelOnly()
    }

    func forget(_ windowID: CGWindowID) {
        if currentWindowID == windowID { hide() }
    }

    private func hidePanelOnly() {
        if panel.isVisible { panel.orderOut(nil) }
    }
}

private final class FocusRingView: NSView {
    private let glowLayer = CAShapeLayer()
    private let gradientLayer = CAGradientLayer()
    private let gradientMask = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()

    private var ringWidth: CGFloat = 3
    private var glowRadius: CGFloat = 9
    /// 相对本 view（铺满那块屏）的窗口矩形，AppKit 底左。
    private var windowRect: CGRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        glowLayer.fillColor = NSColor.clear.cgColor
        glowLayer.strokeColor = NSColor(calibratedRed: 0.30, green: 0.25, blue: 0.70, alpha: 0.55).cgColor
        glowLayer.shadowColor = NSColor(calibratedRed: 0.24, green: 0.36, blue: 0.72, alpha: 1).cgColor
        glowLayer.shadowOpacity = 0.38
        glowLayer.lineCap = .round
        glowLayer.lineJoin = .round
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

        highlightLayer.fillColor = NSColor.clear.cgColor
        highlightLayer.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        highlightLayer.lineCap = .round
        highlightLayer.lineJoin = .round
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

    func setWindowRect(_ rect: CGRect) {
        windowRect = rect
        updateLayers()
    }

    private func updateLayers() {
        let strokeInset = ringWidth / 2 + 0.5
        let strokeRect = windowRect.insetBy(dx: strokeInset, dy: strokeInset)
        guard strokeRect.width > 2, strokeRect.height > 2 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let cornerRadius = min(16, max(8, strokeRect.width * 0.018))
        let path = CGPath(
            roundedRect: strokeRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        glowLayer.frame = bounds
        glowLayer.path = path
        glowLayer.lineWidth = ringWidth + 1
        // 不设置 shadowPath：闭合 shadowPath 会把整个窗口内部当成实心阴影染色。
        // 让 CA 从透明填充 + stroke 的 alpha 自动推导，只发光描边本身。
        glowLayer.shadowPath = nil
        glowLayer.shadowRadius = glowRadius
        glowLayer.shadowOffset = .zero

        gradientLayer.frame = bounds
        gradientMask.frame = bounds
        gradientMask.path = path
        gradientMask.fillColor = NSColor.clear.cgColor
        gradientMask.strokeColor = NSColor.white.cgColor
        gradientMask.lineWidth = ringWidth

        highlightLayer.frame = bounds
        highlightLayer.path = path
        highlightLayer.lineWidth = max(0.75, ringWidth * 0.28)

        CATransaction.commit()
    }
}
