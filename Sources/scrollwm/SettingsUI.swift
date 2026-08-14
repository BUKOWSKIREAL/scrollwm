import AppKit
import QuartzCore
import ScrollCore
import SwiftUI

// ============================================================
//  数据流（单一事实来源：磁盘上的 config.toml）
//  UI ──update──▶ Config.write() ──onChange──▶ AppDelegate.apply(.ui)
//  磁盘 ──外部手改──▶ ConfigWatcher ─▶ AppDelegate.reloadFromDisk() ─▶ model.syncFromDisk
//  内存 Config 只是缓存；AppDelegate 用 generation 抑制「UI 写入 → 文件监听」的回声。
// ============================================================

// MARK: - Model

final class SettingsModel: ObservableObject {
    @Published private(set) var config: Config
    /// 最近一次落盘失败的提示；成功后自动清除
    @Published private(set) var lastError: String?

    /// UI 写入后的回调，宿主直接应用，无需二次读盘。
    var onChange: ((Config) -> Void)?
    /// 拖动中的实时预览：只应用到运行时，不落盘（松手时 update 落盘）。
    var onPreview: ((Config) -> Void)?

    /// 预览改过内存 config 但尚未落盘
    private var previewDirty = false
    private var lastPreviewAt: CFTimeInterval = 0

    init(config: Config) {
        self.config = config
    }

    /// 去重 → 发布 → 落盘 → 通知宿主
    func update(_ mutate: (inout Config) -> Void) {
        var next = config
        mutate(&next)
        guard next != config || previewDirty else { return }
        previewDirty = false
        config = next
        if next.write() {
            if lastError != nil { lastError = nil }
        } else {
            lastError = L10n.text("settings.saveError", Config.configPath)
        }
        onChange?(next)
    }

    /// 拖动中的轻量预览：节流 ~30Hz，只改内存并让宿主实时应用
    func preview(_ mutate: (inout Config) -> Void) {
        var next = config
        mutate(&next)
        guard next != config else { return }
        let now = CACurrentMediaTime()
        guard now - lastPreviewAt >= 1.0 / 30.0 else { return }
        lastPreviewAt = now
        previewDirty = true
        config = next
        onPreview?(next)
    }

    /// 仅外部手改后由宿主调用
    func syncFromDisk(_ external: Config) {
        previewDirty = false
        guard external != config else { return }
        config = external
    }

    /// 双向绑定：set 即写盘
    func binding<T: Equatable>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    // MARK: 快捷键

    func combos(for action: WMAction) -> [String] {
        config.bindings.filter { $0.value == action }.keys.sorted()
    }

    func bind(_ action: WMAction, to combo: String) {
        update { $0.bindings[combo] = action }
    }

    func unbind(_ combo: String) {
        update { $0.bindings.removeValue(forKey: combo) }
    }
}

// MARK: - Window

/// accessory 进程里唯一的标准窗口：懒创建、复用、关闭不释放。
final class SettingsWindowController: NSObject {
    let model: SettingsModel
    private var window: NSWindow?
    private var hosting: NSViewController?

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let root = SettingsRootView().environmentObject(model)
            let host = NSHostingController(rootView: root)
            host.view.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
            host.view.wantsLayer = true
            host.view.layer?.isOpaque = false
            host.view.layer?.backgroundColor = NSColor.clear.cgColor
            hosting = host

            let w = SettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = L10n.text("settings.title")
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.minSize = NSSize(width: 480, height: 380)
            installGlassBackground(on: w, content: host.view)
            w.setContentSize(NSSize(width: 560, height: 520))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 窗口本身必须透明，毛玻璃才能糊到桌面；SwiftUI Material 只能糊窗口内部。
    private func installGlassBackground(on window: NSWindow, content: NSView) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 0
            glass.style = .regular
            glass.contentView = content
            window.contentView = glass
            return
        }
        let frost = NSVisualEffectView()
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.material = .underWindowBackground
        frost.addSubview(content)
        content.frame = frost.bounds
        content.autoresizingMask = [.width, .height]
        window.contentView = frost
    }
}

/// 无主菜单的 accessory 进程收不到标准 Close 菜单命令：
/// 自己响应 Esc（cancelOperation）与 Cmd+W 关闭窗口。
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Root

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, tools, keys
    var id: String { rawValue }
    var title: String { L10n.text("settings.section.\(rawValue)") }
}

struct SettingsRootView: View {
    @EnvironmentObject var model: SettingsModel
    @State private var section: SettingsSection = .general

    var body: some View {
        VStack(spacing: 14) {
            SlidingPillBar(selection: $section)
                .padding(.top, 4)

            Group {
                switch section {
                case .general: GeneralTab()
                case .tools: ToolsTab()
                case .keys: BindingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transaction { $0.animation = nil }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(Color.clear)
        .frame(minWidth: 480, minHeight: 380)
        .frame(width: 560, height: 520)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(L10n.text("settings.footer.retile")) { WindowManager.shared?.perform(.retile) }
            Button(L10n.text("settings.footer.openConfig")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: Config.configPath))
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(AppFonts.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(error)
            }
            Spacer()
        }
        .controlSize(.regular)
    }
}

/// 系统设置式胶囊分段：选中块在选项间滑动。
private struct SlidingPillBar: View {
    @Binding var selection: SettingsSection
    @Namespace private var pillNS
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SettingsSection.allCases) { item in
                let on = selection == item
                Text(item.title)
                    .font(AppFonts.jbMono(size: 13, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Color.black : unselectedForeground)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 6)
                    .background {
                        if on {
                            Capsule()
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "pill", in: pillNS)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                            selection = item
                        }
                    }
            }
        }
        .padding(4)
        .modifier(LiquidCapsuleChrome())
    }

    private var unselectedForeground: Color {
        scheme == .dark ? Color.white.opacity(0.72) : Color.primary.opacity(0.48)
    }
}

private struct LiquidCapsuleChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
        }
    }
}

// ============================================================
//  共享 UI
// ============================================================

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
    }
}

struct GlassChip: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.55)))
    }
}

/// 滑块 + 数值：拖动中只改本地（可选实时预览），松手才提交落盘，避免高频写盘。
struct NumberSlider: View {
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let value: Double
    let format: (Double) -> String
    /// 拖动中的实时预览（不落盘）；nil 表示只在松手时生效
    var preview: ((Double) -> Void)? = nil
    let commit: (Double) -> Void

    @State private var local: Double = 0
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 88, alignment: .leading)
            Slider(
                value: Binding(
                    get: { isEditing ? local : value },
                    set: { newValue in
                        if isEditing {
                            local = newValue
                            preview?(newValue)
                        } else {
                            // 键盘/滚轮等不触发 editing 回调的输入路径：直接提交
                            local = newValue
                            commit(newValue)
                        }
                    }
                ),
                in: range, step: step
            ) { editing in
                if editing {
                    local = value
                    isEditing = true
                } else {
                    isEditing = false
                    commit(local)
                }
            }
            Text(format(isEditing ? local : value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

struct Pane<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AppFonts.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCard())
    }
}

private struct TabScaffold<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }
}

// ============================================================
//  各段内容
// ============================================================

private struct GeneralTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var newPreset = ""
    @State private var showAdvanced = false

    var body: some View {
        TabScaffold {
            Pane(title: L10n.text("settings.language.title")) {
                Picker("", selection: languageBinding()) {
                    Text(L10n.text("settings.language.system")).tag(AppLanguage.system)
                    Text(L10n.text("settings.language.zhHans")).tag(AppLanguage.simplifiedChinese)
                    Text(L10n.text("settings.language.en")).tag(AppLanguage.english)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
                Text(L10n.text("settings.language.note"))
                    .font(AppFonts.caption).foregroundStyle(.secondary)
            }
            Pane(title: L10n.text("settings.layout.title")) {
                NumberSlider(title: L10n.text("settings.layout.innerGap"), range: 0...48, step: 1,
                             value: model.config.innerGap, format: { "\(Int($0))" },
                             preview: { v in model.preview { $0.innerGap = v } },
                             commit: { v in model.update { $0.innerGap = v } })
                NumberSlider(title: L10n.text("settings.layout.outerGap"), range: 0...64, step: 1,
                             value: model.config.outerGap, format: { "\(Int($0))" },
                             preview: { v in model.preview { $0.outerGap = v } },
                             commit: { v in model.update { $0.outerGap = v } })
                NumberSlider(title: L10n.text("settings.layout.screenMargin"), range: 0...32, step: 1,
                             value: model.config.screenMargin, format: { "\(Int($0))" },
                             preview: { v in model.preview { $0.screenMargin = v } },
                             commit: { v in model.update { $0.screenMargin = v } })
                NumberSlider(title: L10n.text("settings.layout.defaultWidth"), range: 0.1...1.0, step: 0.05,
                             value: model.config.defaultWidth, format: { String(format: "%.2f", $0) },
                             commit: { v in model.update { $0.defaultWidth = v } })
                NumberSlider(title: L10n.text("settings.layout.resizeStep"), range: 0.01...0.5, step: 0.01,
                             value: model.config.resizeStep, format: { String(format: "%.2f", $0) },
                             commit: { v in model.update { $0.resizeStep = v } })
                Text(L10n.text("settings.layout.resizeStepNote"))
                    .font(AppFonts.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(L10n.text("settings.layout.newWindowSide")).frame(width: 88, alignment: .leading)
                    Picker("", selection: model.binding(\.newWindowSide)) {
                        Text(L10n.text("settings.layout.sideLeft")).tag(NewWindowSide.left)
                        Text(L10n.text("settings.layout.sideRight")).tag(NewWindowSide.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Spacer()
                }

                HStack {
                    Text(L10n.text("settings.layout.presets")).frame(width: 88, alignment: .leading)
                    ForEach(model.config.widthPresets, id: \.self) { p in
                        HStack(spacing: 4) {
                            Text(String(format: "%.2f", p)).monospacedDigit()
                            Button { removePreset(p) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(model.config.widthPresets.count <= 1)
                            .help(model.config.widthPresets.count <= 1
                                  ? L10n.text("settings.layout.presetKeepOne")
                                  : L10n.text("common.remove"))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .modifier(GlassChip())
                    }
                    TextField("0.4", text: $newPreset)
                        .textFieldStyle(.roundedBorder).frame(width: 52)
                        .onSubmit(addPreset)
                    Button(L10n.text("common.add"), action: addPreset)
                        .disabled(Double(newPreset) == nil)
                    Spacer()
                }
            }
            Pane(title: L10n.text("settings.animation.title")) {
                Toggle(L10n.text("settings.animation.enabled"), isOn: model.binding(\.animationEnabled))
                Picker(L10n.text("settings.animation.mode"), selection: model.binding(\.animationMode)) {
                    Text(L10n.text("settings.animation.modeSpring")).tag(AnimationMode.spring)
                    Text(L10n.text("settings.animation.modeEasing")).tag(AnimationMode.easing)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Toggle(L10n.text("settings.animation.highFrameRate"), isOn: model.binding(\.animationHighFrameRate))
                    .disabled(!model.config.animationEnabled)
                Text(L10n.text("settings.animation.highFrameRateNote"))
                    .font(AppFonts.caption).foregroundStyle(.secondary)

                DisclosureGroup(L10n.text("settings.animation.advanced"), isExpanded: $showAdvanced) {
                    if model.config.animationMode == .spring {
                        NumberSlider(title: L10n.text("settings.animation.stiffness"), range: 1...5000, step: 10,
                                     value: model.config.springStiffness, format: { "\(Int($0))" },
                                     commit: { v in model.update { $0.springStiffness = v } })
                        NumberSlider(title: L10n.text("settings.animation.damping"), range: 0.1...10, step: 0.05,
                                     value: model.config.springDampingRatio, format: { String(format: "%.2f", $0) },
                                     commit: { v in model.update { $0.springDampingRatio = v } })
                    } else {
                        NumberSlider(title: L10n.text("settings.animation.duration"), range: 0...1000, step: 10,
                                     value: model.config.animationDurationMs, format: { "\(Int($0)) ms" },
                                     commit: { v in model.update { $0.animationDurationMs = v } })
                        Picker(L10n.text("settings.animation.curve"), selection: model.binding(\.animationCurve)) {
                            Text(L10n.text("settings.animation.curveQuint")).tag(Interpolation.Curve.easeOutQuint)
                            Text(L10n.text("settings.animation.curveCubic")).tag(Interpolation.Curve.easeOutCubic)
                            Text(L10n.text("settings.animation.curveExpo")).tag(Interpolation.Curve.easeOutExpo)
                            Text(L10n.text("settings.animation.curveSmooth")).tag(Interpolation.Curve.smoothstep)
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 240, alignment: .leading)
                    }

                }
                .font(AppFonts.subheadline)
            }
        }
    }

    /// 语言切换：立即写 AppleLanguages 并通知菜单栏刷新，同时落盘配置
    private func languageBinding() -> Binding<AppLanguage> {
        Binding(
            get: { model.config.language },
            set: { lang in
                guard lang != model.config.language else { return }
                model.update { $0.language = lang }
                lang.apply()
            }
        )
    }

    private func addPreset() {
        guard let v = Double(newPreset), v > 0.05, v <= 1.0 else { return }
        newPreset = ""
        model.update { cfg in
            var set = Set(cfg.widthPresets)
            set.insert(v)
            cfg.widthPresets = set.sorted()
        }
    }

    private func removePreset(_ p: Double) {
        model.update { cfg in
            let rest = cfg.widthPresets.filter { abs($0 - p) > 0.0001 }
            cfg.widthPresets = rest.isEmpty ? cfg.widthPresets : rest
        }
    }
}

private struct ToolsTab: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        TabScaffold {
            Pane(title: L10n.text("settings.ring.title")) {
                Toggle(L10n.text("settings.ring.enabled"), isOn: model.binding(\.focusRingEnabled))
                Toggle(L10n.text("settings.ring.alwaysOn"), isOn: model.binding(\.focusRingAlwaysOn))
                    .disabled(!model.config.focusRingEnabled)
                Text(model.config.focusRingAlwaysOn
                     ? L10n.text("settings.ring.alwaysOnNoteOn")
                     : L10n.text("settings.ring.alwaysOnNoteOff"))
                    .font(AppFonts.caption).foregroundStyle(.secondary)
                NumberSlider(title: L10n.text("settings.ring.borderWidth"), range: 1...8, step: 1,
                             value: model.config.focusRingWidth, format: { "\(Int($0))" },
                             preview: { v in model.preview { $0.focusRingWidth = v } },
                             commit: { v in model.update { $0.focusRingWidth = v } })
                NumberSlider(title: L10n.text("settings.ring.glow"), range: 0...24, step: 1,
                             value: model.config.focusRingGlowRadius, format: { "\(Int($0))" },
                             preview: { v in model.preview { $0.focusRingGlowRadius = v } },
                             commit: { v in model.update { $0.focusRingGlowRadius = v } })
            }
            AppsTab()
        }
    }
}

private struct AppsTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var showPicker = false
    @State private var showManual = false
    @State private var manualID = ""

    var body: some View {
        let ignored = model.config.ignoreBundleIDs.sorted()
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("settings.apps.title")).font(AppFonts.headline)
            Text(L10n.text("settings.apps.subtitle"))
                .font(AppFonts.subheadline)
                .foregroundStyle(.secondary)

            if ignored.isEmpty {
                Text(L10n.text("settings.apps.empty"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(ignored, id: \.self) { bid in
                    IgnoredAppRow(bundleID: bid) {
                        model.update { $0.ignoreBundleIDs.remove(bid) }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    showPicker = true
                } label: {
                    Label(L10n.text("settings.apps.add"), systemImage: "plus")
                }
                Button(showManual ? L10n.text("settings.apps.manualCollapse") : L10n.text("settings.apps.manual")) {
                    withAnimation(.easeInOut(duration: 0.15)) { showManual.toggle() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }

            if showManual {
                HStack(spacing: 8) {
                    TextField("com.apple.systempreferences", text: $manualID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addManual)
                    Button(L10n.text("common.add"), action: addManual)
                        .disabled(manualID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCard())
        .sheet(isPresented: $showPicker) {
            AppPickerSheet(
                ignored: model.config.ignoreBundleIDs,
                onAdd: { bid in model.update { $0.ignoreBundleIDs.insert(bid) } }
            )
        }
    }

    private func addManual() {
        let bid = manualID.trimmingCharacters(in: .whitespaces)
        guard !bid.isEmpty else { return }
        manualID = ""
        model.update { $0.ignoreBundleIDs.insert(bid) }
    }
}

/// 图标/名称解析走磁盘（urlForApplication + icon(forFile:)），
/// 列表滚动时每帧重复调用会卡顿，这里按 bundleID / path 缓存。
private enum AppInfoCache {
    static let icons = NSCache<NSString, NSImage>()
    private static var resolved: [String: (name: String, icon: NSImage?)] = [:]

    static func icon(forPath path: String) -> NSImage {
        if let hit = icons.object(forKey: path as NSString) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(icon, forKey: path as NSString)
        return icon
    }

    static func resolve(bundleID: String) -> (name: String, icon: NSImage?) {
        if let hit = resolved[bundleID] { return hit }
        let info: (String, NSImage?)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            info = (displayName, icon(forPath: url.path))
        } else {
            info = (bundleID, nil)
        }
        resolved[bundleID] = info
        return info
    }
}

private struct IgnoredAppRow: View {
    let bundleID: String
    var onRemove: () -> Void

    var body: some View {
        let info = AppInfoCache.resolve(bundleID: bundleID)
        HStack(spacing: 10) {
            if let icon = info.icon {
                Image(nsImage: icon)
                    .resizable().interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "app.fill").foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(AppFonts.jbMono(size: 13, weight: .medium)).lineLimit(1)
                Text(bundleID).font(AppFonts.jbMonoMono(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { onRemove() } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct AppEntry: Hashable {
    let bundleID: String
    let name: String
    let url: URL?
}

private struct AppPickerSheet: View {
    var ignored: Set<String>
    var onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var entries: [AppEntry] = []
    @State private var loading = true

    private var filtered: [AppEntry] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return entries }
        let q = query.lowercased()
        return entries.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("settings.apps.pickerTitle")).font(AppFonts.headline)
                    Text(L10n.text("settings.apps.pickerSubtitle"))
                        .font(AppFonts.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("settings.apps.pickerDone")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("settings.apps.pickerSearch"), text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .padding(.horizontal, 16).padding(.vertical, 10)

            if loading {
                VStack(spacing: 10) {
                    ProgressView().scaleEffect(0.9)
                    Text(L10n.text("settings.apps.pickerScanning")).font(AppFonts.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered, id: \.bundleID) { entry in
                            AppPickerRow(
                                entry: entry,
                                isIgnored: ignored.contains(entry.bundleID),
                                onAdd: { onAdd(entry.bundleID) }
                            )
                            Divider().opacity(0.35).padding(.leading, 44)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 520, height: 460)
        .task { await load() }
    }

    private func load() async {
        let apps = await Task.detached(priority: .userInitiated) { Self.scanInstalledApps() }.value
        entries = apps
        loading = false
    }

    nonisolated static func scanInstalledApps() -> [AppEntry] {
        var map: [String: AppEntry] = [:]
        let selfID = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier else { continue }
            if bid == selfID { continue }
            let name = app.localizedName ?? bid
            if map[bid] == nil {
                map[bid] = AppEntry(bundleID: bid, name: name, url: app.bundleURL)
            }
        }
        let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir)
            guard FileManager.default.fileExists(atPath: dir),
                  let enumerator = FileManager.default.enumerator(
                      at: url,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  ) else { continue }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "app" else { continue }
                enumerator.skipDescendants()
                guard let bundle = Bundle(url: fileURL), let bid = bundle.bundleIdentifier else { continue }
                if bid == selfID { continue }
                if map[bid] != nil { continue }
                let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? FileManager.default.displayName(atPath: fileURL.path).replacingOccurrences(of: ".app", with: "")
                map[bid] = AppEntry(bundleID: bid, name: displayName, url: fileURL)
                if map.count > 800 { break }
            }
        }
        return map.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct AppPickerRow: View {
    let entry: AppEntry
    let isIgnored: Bool
    var onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            let icon: NSImage = entry.url.map { AppInfoCache.icon(forPath: $0.path) }
                ?? NSImage(imageLiteralResourceName: NSImage.applicationIconName)
            Image(nsImage: icon)
                .resizable().interpolation(.high)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(AppFonts.jbMono(size: 13, weight: .medium)).lineLimit(1)
                Text(entry.bundleID).font(AppFonts.jbMonoMono(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isIgnored {
                Label(L10n.text("settings.apps.pickerIgnored"), systemImage: "checkmark.circle.fill")
                    .font(AppFonts.caption).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(L10n.text("common.add")) { onAdd() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.clear))
        .contentShape(Rectangle())
    }
}

// MARK: - 快捷键

private struct BindingsTab: View {
    @EnvironmentObject var model: SettingsModel
    @State private var recording: WMAction?

    var body: some View {
        TabScaffold {
            Pane(title: L10n.text("settings.section.keys")) {
                Text(L10n.text("settings.keys.hint"))
                    .font(AppFonts.caption).foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    ForEach(WMAction.allCases.filter { $0 != .unbind }, id: \.self) { action in
                        actionRow(action)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ action: WMAction) -> some View {
        let combos = model.combos(for: action)
        HStack(alignment: .top, spacing: 10) {
            Text(action.title)
                .font(AppFonts.jbMono(size: 13))
                .frame(width: 88, alignment: .leading)
                .padding(.top, 5)
            FlowLayout(spacing: 6) {
                ForEach(combos, id: \.self) { combo in
                    comboChip(combo)
                }
                if combos.isEmpty {
                    Text(L10n.text("settings.keys.unbound"))
                        .font(AppFonts.jbMono(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            recordControls(for: action)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private func comboChip(_ combo: String) -> some View {
        HStack(spacing: 4) {
            Text(KeyComboText.display(combo))
                .font(AppFonts.jbMono(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
            Button {
                model.unbind(combo)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(AppFonts.jbMono(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.text("common.remove"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.55)))
    }

    @ViewBuilder
    private func recordControls(for action: WMAction) -> some View {
        if recording == action {
            HStack(spacing: 6) {
                KeyCaptureView { keyCode, flags in
                    handleKey(action: action, keyCode: keyCode, flags: flags)
                }
                .frame(width: 120, height: 22)
                Button(L10n.text("common.cancel")) { recording = nil }
                    .controlSize(.small)
            }
        } else {
            Button(L10n.text("settings.keys.record")) { recording = action }
                .controlSize(.small)
        }
    }

    private func handleKey(action: WMAction, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        if keyCode == 53 { recording = nil; return } // esc
        guard let keyName = Self.keyCodeName[UInt32(keyCode)] else { return }
        var tokens: [String] = []
        if flags.contains(.option) { tokens.append("alt") }
        if flags.contains(.control) { tokens.append("ctrl") }
        if flags.contains(.shift) { tokens.append("shift") }
        if flags.contains(.command) { tokens.append("cmd") }
        guard !tokens.isEmpty else { return }
        let combo = (tokens + [keyName]).joined(separator: "-")
        model.bind(action, to: combo)
        recording = nil
    }

    static let keyCodeName: [UInt32: String] = {
        let canonical = [
            "a", "s", "d", "f", "h", "g", "z", "x", "c", "v", "b", "q", "w", "e", "r", "y", "t",
            "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
            "equal", "minus", "rightbracket", "leftbracket", "o", "u", "i", "p", "l", "j",
            "quote", "k", "semicolon", "backslash", "comma", "slash", "n", "m", "period",
            "return", "tab", "space", "grave", "escape", "kpplus", "kpminus",
            "left", "right", "down", "up",
        ]
        var map: [UInt32: String] = [:]
        for name in canonical where HotkeyManager.keyCodes[name] != nil {
            map[HotkeyManager.keyCodes[name]!] = name
        }
        for (name, code) in HotkeyManager.keyCodes where map[code] == nil {
            map[code] = name
        }
        return map
    }()
}

/// 快捷键胶囊按可用宽度自动折行，避免挤成一排互相重叠。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(in: bounds.width, subviews: subviews).frames
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + frames[index].minX, y: bounds.minY + frames[index].minY),
                proposal: ProposedViewSize(frames[index].size)
            )
        }
    }

    private func arrange(in maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, maxWidth.isFinite, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}

/// 抢第一响应者、捕获一次 keyDown 的 NSView
private struct KeyCaptureView: NSViewRepresentable {
    var onKey: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onKey = onKey
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onKey = onKey
    }

    final class CaptureView: NSView {
        var onKey: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            onKey?(event.keyCode, event.modifierFlags)
        }
    }
}
