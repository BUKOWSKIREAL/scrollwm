import AppKit
import ScrollCore
import SwiftUI

// ============================================================
//  首次运行的交互式引导。
//  纸带演示直接跑 ScrollCore 的 LayoutEngine，屏幕上看到的就是真实布局行为。
//  配乐由 OnboardingAudio 实时合成，不打包音频资源。
// ============================================================

// MARK: - 持久状态

enum WelcomeState {
    private static let versionKey = "scrollwm.welcome.version"
    private static let soundKey = "scrollwm.welcome.sound"
    /// 引导内容有实质更新时 +1，老用户会再看到一次
    static let currentVersion = 1

    static var hasSeen: Bool {
        UserDefaults.standard.integer(forKey: versionKey) >= currentVersion
    }

    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    static var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: soundKey) }
    }
}

// MARK: - 章节

enum WelcomeChapter: Int, CaseIterable, Identifiable {
    case overture, strip, width, ring, keys, ready

    var id: Int { rawValue }

    /// 这三章共用同一块纸带舞台，转场时舞台不重建，内容连贯
    var usesStage: Bool { self == .strip || self == .width || self == .ring }

    var accent: Color {
        switch self {
        case .overture: return WelcomePalette.indigo
        case .strip: return WelcomePalette.blue
        case .width: return WelcomePalette.violet
        case .ring: return WelcomePalette.magenta
        case .keys: return WelcomePalette.violet
        case .ready: return WelcomePalette.teal
        }
    }

    var title: String {
        switch self {
        case .overture: return ""
        case .strip: return "纸带，而不是网格"
        case .width: return "宽度是可以商量的"
        case .ring: return "焦点始终看得见"
        case .keys: return "手不用离开键盘"
        case .ready: return "最后一步"
        }
    }

    var body: String {
        switch self {
        case .overture:
            return ""
        case .strip:
            return "窗口一列一列向右排开，永远不会互相遮挡。焦点走到哪里，视口就跟到哪里；够不着的列停在屏幕边缘，只露出一道纸边。"
        case .width:
            return "每一列都有自己的宽度。在预设之间循环，或者一点一点调，直到刚好。"
        case .ring:
            return "当前列外面有一圈渐变亮边，跟着窗口一起动。切到别的 App 时它会让路，也可以让它一直亮着。"
        case .keys:
            return "所有动作都能绑定快捷键，下面是默认的一套。想改的话，在设置里点「录入」，按一下新组合就行。"
        case .ready:
            return "ScrollWM 需要辅助功能权限才能移动别的 App 的窗口。授权之后它就住在菜单栏里，安静接管一切。"
        }
    }

    var hint: String {
        switch self {
        case .overture: return "按 Enter 开始"
        case .strip: return "按 ⌥← / ⌥→ 移动焦点，或直接点一个窗口"
        case .width: return "按 ⌥－ / ⌥＋ 微调，⌥R 切换预设"
        case .ring: return "拨一下开关，看看两种效果"
        case .keys: return "把鼠标放到键帽上"
        case .ready: return ""
        }
    }

    var previous: WelcomeChapter? { WelcomeChapter(rawValue: rawValue - 1) }
    var next: WelcomeChapter? { WelcomeChapter(rawValue: rawValue + 1) }
}

// MARK: - 配色

enum WelcomePalette {
    static let ink = Color(red: 0.035, green: 0.038, blue: 0.052)
    static let indigo = Color(red: 0.36, green: 0.42, blue: 0.92)
    static let blue = Color(red: 0.27, green: 0.55, blue: 0.95)
    static let violet = Color(red: 0.49, green: 0.38, blue: 0.93)
    static let magenta = Color(red: 0.72, green: 0.36, blue: 0.88)
    static let teal = Color(red: 0.25, green: 0.72, blue: 0.70)

    /// 与 FocusRingView 完全同色，演示里看到的就是真实亮边
    static let ring = LinearGradient(
        colors: [
            Color(red: 0.22, green: 0.48, blue: 0.76),
            Color(red: 0.38, green: 0.29, blue: 0.74),
            Color(red: 0.55, green: 0.27, blue: 0.72),
            Color(red: 0.22, green: 0.48, blue: 0.76),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - 模型

final class WelcomeModel: ObservableObject {
    @Published private(set) var chapter: WelcomeChapter = .overture
    @Published private(set) var demo = Strip()
    @Published private(set) var explored: Set<WelcomeChapter> = []
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published var ringOn = true

    @Published var soundOn: Bool = WelcomeState.soundEnabled {
        didSet {
            guard soundOn != oldValue else { return }
            WelcomeState.soundEnabled = soundOn
            audio.isMuted = !soundOn
            if soundOn { audio.tick() }
        }
    }

    let audio = OnboardingAudio()

    var onFinish: (() -> Void)?
    var onRequestPermission: (() -> Void)?
    /// 用户在系统设置里勾选完权限后，把引导窗口重新叫到前面
    var onPermissionGranted: (() -> Void)?

    private var permissionTimer: Timer?

    /// 演示舞台的布局参数：比真实屏幕紧凑，其余语义完全一致。
    /// 列宽取约 1/3，让默认视口刚好放下三扇完整窗口，右侧两列只露纸边，
    /// 避免一上来就看到被舞台裁掉的半扇窗。
    static let spec = LayoutSpec(
        innerGap: 12,
        outerGap: 22,
        screenMargin: 10,
        widthPresets: [1.0 / 3.0, 0.5, 2.0 / 3.0],
        defaultWidth: 1.0 / 3.0,
        minFraction: 0.2
    )

    static let demoApps: [(id: WindowID, name: String, tint: Color)] = [
        (1, "编辑器", Color(red: 0.36, green: 0.55, blue: 0.95)),
        (2, "终端", Color(red: 0.34, green: 0.74, blue: 0.62)),
        (3, "浏览器", Color(red: 0.62, green: 0.42, blue: 0.94)),
        (4, "音乐", Color(red: 0.92, green: 0.44, blue: 0.55)),
        (5, "备忘录", Color(red: 0.94, green: 0.72, blue: 0.36)),
    ]

    init() {
        let fractions: [Double] = [0.322, 0.318, 0.324, 0.320, 0.322]
        for (index, app) in Self.demoApps.enumerated() {
            demo.append(id: app.id, fraction: fractions[index])
        }
        demo.focus(id: Self.demoApps[0].id)
    }

    // MARK: 生命周期

    func begin() {
        audio.isMuted = !soundOn
        audio.start()
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = AXIsProcessTrusted()
            guard now != self.trusted else { return }
            self.trusted = now
            if now {
                self.audio.success()
                self.onPermissionGranted?()
            }
        }
    }

    func end() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        audio.stop()
    }

    // MARK: 导航

    func go(to target: WelcomeChapter) {
        guard target != chapter else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            chapter = target
        }
        Log.debug("引导章节：\(target.rawValue)")
        audio.chime(step: target.rawValue)
    }

    func advance() {
        guard let next = chapter.next else {
            finish()
            return
        }
        go(to: next)
    }

    func retreat() {
        guard let previous = chapter.previous else { return }
        go(to: previous)
    }

    func skip() {
        finish()
    }

    private func finish() {
        audio.finale()
        onFinish?()
    }

    func requestPermission() {
        audio.tick()
        onRequestPermission?()
    }

    // MARK: 演示交互

    func focusNeighbor(_ direction: HDirection) {
        guard demo.focusAdjacent(direction) != nil else { return }
        audio.tick()
        markExplored()
    }

    func focus(id: WindowID) {
        guard demo.focusedID != id, demo.focus(id: id) else { return }
        audio.tick()
        markExplored()
    }

    func nudgeWidth(by delta: Double) {
        demo.adjustFocusedWidth(by: delta, minFraction: Self.spec.minFraction)
        audio.tick()
        markExplored()
    }

    func cycleWidthPreset() {
        demo.cycleFocusedWidth(presets: Self.spec.widthPresets, minFraction: Self.spec.minFraction)
        audio.tick()
        markExplored()
    }

    func setFocusedWidth(_ fraction: Double) {
        guard let id = demo.focusedID else { return }
        demo.setFraction(id: id, fraction: fraction, minFraction: Self.spec.minFraction)
        audio.tick()
        markExplored()
    }

    func toggleFullWidth() {
        demo.toggleFocusedFullWidth(fallback: Self.spec.defaultWidth)
        audio.tick()
        markExplored()
    }

    func toggleRing() {
        ringOn.toggle()
        audio.tick()
        markExplored()
    }

    func noteHover() {
        audio.tick()
    }

    private func markExplored() {
        guard !explored.contains(chapter) else { return }
        explored.insert(chapter)
    }

    var hasExploredCurrent: Bool { explored.contains(chapter) }

    /// 纯函数：不改发布状态，只按当前纸带算出这一帧的窗口位置。
    /// 类型要限定命名空间：SDK 里也有个同名的 WindowPlacement。
    func placements(in size: CGSize) -> [ScrollCore.WindowPlacement] {
        guard size.width > 1, size.height > 1 else { return [] }
        var strip = demo
        let screen = CGRect(origin: .zero, size: size)
        let viewport = LayoutEngine.viewport(screen: screen, spec: Self.spec)
        strip.viewportOffset = LayoutEngine.revealOffset(
            strip, viewportWidth: viewport.width, spec: Self.spec
        )
        return LayoutEngine.computeLayout(strip, viewport: viewport, screen: screen, spec: Self.spec)
    }

    // MARK: 键盘

    /// 返回 true 表示已消费，不再传给系统
    func handleKey(_ event: NSEvent) -> Bool {
        let rawFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // AppKit 会给方向键附带 .numericPad（有些键盘还带 .function），它们是
        // 键位来源信息，不是用户按下的修饰键；不能因此拦掉 ← / →。
        let flags = rawFlags.subtracting([.numericPad, .function, .capsLock])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            skip()
            return true
        }

        // 交互章节使用 ScrollWM 的真实默认快捷键，而不是教学专用按键。
        if flags == .option {
            switch (chapter, Int(event.keyCode)) {
            case (.strip, 123):        // ⌥←
                focusNeighbor(.left)
                return true
            case (.strip, 124):        // ⌥→
                focusNeighbor(.right)
                return true
            case (.width, 27):         // ⌥－
                nudgeWidth(by: -0.06)
                return true
            case (.width, 24):         // ⌥＋（物理 = 键）
                nudgeWidth(by: 0.06)
                return true
            case (.width, 15):         // ⌥R
                cycleWidthPreset()
                return true
            default:
                return false
            }
        }

        guard flags.isEmpty else { return false }

        switch Int(event.keyCode) {
        case 53:                       // esc
            skip()
            return true
        case 36, 76, 49:               // return / 小键盘 enter / space
            advance()
            return true
        case 123:                      // ←
            // 在交互章节中，裸方向键不伪装成真实 WM 快捷键。
            guard chapter != .strip, chapter != .width else { return false }
            retreat()
            return true
        case 124:                      // →
            guard chapter != .strip, chapter != .width else { return false }
            advance()
            return true
        default:
            return false
        }
    }
}

// MARK: - 窗口

/// 无边框圆角面板。accessory 进程没有主菜单，键盘全靠本地事件监视器兜。
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    let model = WelcomeModel()
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var dismissed = false
    private var previousPolicy: NSApplication.ActivationPolicy?

    var onDismiss: (() -> Void)?

    private static let size = NSSize(width: 900, height: 640)

    override init() {
        super.init()
        model.onFinish = { [weak self] in self?.dismiss() }
        model.onPermissionGranted = { [weak self] in self?.bringToFront() }
    }

    func show() {
        if window == nil { build() }
        // accessory 进程在启动时抢不到激活权，窗口会被当前前台 App 盖住。
        // 引导期间临时当个正经前台应用，键盘也才能立刻用上。
        if previousPolicy == nil {
            previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
        }
        installKeyMonitor()
        model.begin()
        bringToFront()
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeMain()
    }

    private func build() {
        let host = NSHostingView(rootView: WelcomeRootView().environmentObject(model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.layer?.cornerRadius = 22
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        let panel = WelcomeWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.center()
        window = panel
        Log.info("引导页已打开")
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            return self.model.handleKey(event) ? nil : event
        }
    }

    private func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        WelcomeState.markSeen()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        model.end()
        guard let window else {
            restorePolicy()
            onDismiss?()
            return
        }
        // 收尾和弦还在响，窗口跟着一起淡出
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.window = nil
            self?.restorePolicy()
            self?.onDismiss?()
        }
    }

    /// 引导结束后退回菜单栏驻留，Dock 图标随之消失
    private func restorePolicy() {
        guard let previousPolicy else { return }
        self.previousPolicy = nil
        NSApp.setActivationPolicy(previousPolicy)
    }
}

private final class WelcomeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 根视图

struct WelcomeRootView: View {
    @EnvironmentObject var model: WelcomeModel

    var body: some View {
        ZStack {
            WelcomeBackdrop(accent: model.chapter.accent)
            VStack(spacing: 0) {
                topBar
                if model.chapter == .overture {
                    OvertureScene()
                        .transition(.opacity.combined(with: .scale(scale: 0.975)))
                } else {
                    stageArea
                    copyArea
                }
                footer
            }
        }
        .frame(width: 900, height: 640)
        .ignoresSafeArea()
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.18), .white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .preferredColorScheme(.dark)
    }

    // MARK: 顶部

    private var topBar: some View {
        HStack(spacing: 14) {
            ChapterProgress()
            Spacer(minLength: 8)
            SoundToggle()
            GlyphButton(symbol: "xmark") { model.skip() }
                .help("跳过（Esc）")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    // MARK: 主视觉

    private var stageArea: some View {
        ZStack {
            if model.chapter.usesStage {
                // 三章共用同一个实例，切章时舞台不重建，窗口保持在原位
                StripStage()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if model.chapter == .keys {
                KeyCapGrid()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                PermissionCard()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(height: 274, alignment: .top)
        .clipped()
        .padding(.horizontal, 54)
        .padding(.top, 18)
    }

    // MARK: 文案与本章控件

    private var copyArea: some View {
        ZStack {
            ChapterCopy(chapter: model.chapter)
                .id(model.chapter)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 16)),
                        removal: .opacity.combined(with: .offset(y: -12))
                    )
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 54)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            if model.chapter.previous != nil {
                GhostButton(title: "上一步") { model.retreat() }
            } else {
                Text("Esc 跳过")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.28))
            }
            Spacer()
            HStack(spacing: 10) {
                WelcomeKeycap(label: "Enter")
                    .opacity(0.9)
                PrimaryButton(
                    title: model.chapter == .ready ? "开始使用" : "继续",
                    accent: model.chapter.accent
                ) {
                    model.advance()
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 22)
    }
}

// MARK: - 背景

/// 近黑底 + 两团随章节换色、极慢漂移的光晕。刷新率压到 24fps，肉眼看不出、也不烧电。
private struct WelcomeBackdrop: View {
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                WelcomePalette.ink
                glow(color: accent, radius: 460)
                    .offset(x: CGFloat(sin(t * 0.06)) * 150 - 190, y: CGFloat(cos(t * 0.045)) * 80 - 120)
                glow(color: WelcomePalette.violet, radius: 380)
                    .offset(x: CGFloat(cos(t * 0.037)) * 130 + 240, y: CGFloat(sin(t * 0.052)) * 70 + 150)
            }
            .animation(.easeInOut(duration: 0.9), value: accent)
        }
        .overlay(
            // 边缘压暗，视线自然收到中间
            RadialGradient(
                colors: [.clear, .black.opacity(0.55)],
                center: .center, startRadius: 240, endRadius: 620
            )
        )
    }

    private func glow(color: Color, radius: CGFloat) -> some View {
        RadialGradient(
            colors: [color.opacity(0.34), color.opacity(0.06), .clear],
            center: .center, startRadius: 0, endRadius: radius
        )
        .frame(width: radius * 2, height: radius * 2)
        .blendMode(.plusLighter)
    }
}

// MARK: - 进度

private struct ChapterProgress: View {
    @EnvironmentObject var model: WelcomeModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WelcomeChapter.allCases) { chapter in
                let isCurrent = chapter == model.chapter
                Capsule()
                    .fill(fill(for: chapter, isCurrent: isCurrent))
                    .frame(width: isCurrent ? 34 : 16, height: 3)
                    .contentShape(Capsule().inset(by: -8))
                    .onTapGesture { model.go(to: chapter) }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: model.chapter)
    }

    private func fill(for chapter: WelcomeChapter, isCurrent: Bool) -> AnyShapeStyle {
        if isCurrent {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [chapter.accent, chapter.accent.opacity(0.55)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
        }
        let seen = chapter.rawValue < model.chapter.rawValue
        return AnyShapeStyle(Color.white.opacity(seen ? 0.34 : 0.12))
    }
}

// MARK: - 控件

struct WelcomeKeycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.7)
            )
    }
}

private struct SoundToggle: View {
    @EnvironmentObject var model: WelcomeModel
    @State private var hovering = false

    var body: some View {
        Button {
            model.soundOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(model.soundOn ? "关闭配乐" : "打开配乐")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.58))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(hovering ? 0.12 : 0.05)))
        }
        .buttonStyle(.plain)
        .help(model.soundOn ? "关闭配乐" : "打开配乐")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: model.soundOn)
    }
}

private struct GlyphButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.5))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0.05)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct PrimaryButton: View {
    let title: String
    var accent: Color = WelcomePalette.blue
    var symbol = "arrow.right"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.16)))
                    .offset(x: hovering ? 2 : 0)
                    .scaleEffect(hovering ? 1.06 : 1)
            }
            .foregroundStyle(.white)
            .padding(.leading, 19)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [accent.opacity(hovering ? 1 : 0.92), accent.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.8))
            .shadow(color: accent.opacity(hovering ? 0.55 : 0.32), radius: hovering ? 16 : 10, y: 5)
            .scaleEffect(hovering ? 1.03 : 1)
        }
        .buttonStyle(WelcomePressStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
    }
}

private struct WelcomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct GhostButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.5))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(.white.opacity(hovering ? 0.1 : 0.04)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
