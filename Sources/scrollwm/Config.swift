import Foundation
import ScrollCore
import TOMLKit

enum AnimationMode: String, Equatable {
    case spring
    case easing
}

enum NewWindowSide: String, Equatable {
    case left
    case right
}

/// 界面语言：默认跟随系统；可覆盖为英文或简体中文（下次启动生效）。
enum AppLanguage: String, Equatable, CaseIterable {
    case system = "system"
    case english = "en"
    case simplifiedChinese = "zh-hans"

    /// 对应的 AppleLanguages 语言代码；跟随系统时为 nil
    var appleCode: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        }
    }

    /// 立即应用：写/清 AppleLanguages，并通知长驻 UI（菜单栏等）刷新文案
    func apply() {
        if let code = appleCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        NotificationCenter.default.post(name: .scrollWMLanguageChanged, object: nil)
    }
}

/// 用户配置。缺省值即为推荐配置，配置文件可只覆盖关心的字段。
struct Config: Equatable {
    var innerGap: Double = 6
    var outerGap: Double = 12
    var screenMargin: Double = 6
    var widthPresets: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    var defaultWidth: Double = 0.5
    var resizeStep: Double = 0.05
    var newWindowSide: NewWindowSide = .right
    var language: AppLanguage = .system
    var animationEnabled: Bool = true
    var animationMode: AnimationMode = .spring
    /// 实验性：动画期间把显示链路锁定在屏幕最大刷新率，更流畅但更耗电。
    var animationHighFrameRate: Bool = false
    /// easing 兼容模式参数
    var animationDurationMs: Double = 240
    var animationCurve: Interpolation.Curve = .default
    /// niri horizontal-view-movement 默认参数
    var springDampingRatio: Double = 1.0
    var springStiffness: Double = 800
    var springEpsilon: Double = 0.0001
    var focusRingEnabled: Bool = true
    var focusRingWidth: Double = 3
    var focusRingGlowRadius: Double = 9
    var focusRingAlwaysOn: Bool = false
    var ignoreBundleIDs: Set<String> = []
    var bindings: [String: WMAction] = Config.defaultBindings

    /// 默认键位的有序形式：序列化按此顺序输出，注释语义与原实现一致
    static let defaultBindingPairs: [(combo: String, action: WMAction)] = [
        ("alt-left", .focusLeft),
        ("alt-right", .focusRight),
        // Vim 风格别名保留兼容；用户可在 [bindings] 中用 "none" 解绑。
        ("alt-h", .focusLeft),
        ("alt-l", .focusRight),
        ("alt-shift-h", .moveLeft),
        ("alt-shift-l", .moveRight),
        ("alt-r", .cycleWidth),
        ("alt-minus", .shrinkWidth),
        ("alt-equal", .growWidth),
        ("alt-f", .toggleFullWidth),
        ("alt-c", .centerColumn),
        ("alt-t", .toggleFloat),
        ("alt-q", .closeWindow),
        ("alt-shift-r", .retile),
    ]

    static let defaultBindings: [String: WMAction] = Dictionary(
        uniqueKeysWithValues: defaultBindingPairs.map { ($0.combo, $0.action) }
    )

    var layoutSpec: LayoutSpec {
        LayoutSpec(
            innerGap: CGFloat(innerGap),
            outerGap: CGFloat(outerGap),
            screenMargin: CGFloat(screenMargin),
            widthPresets: widthPresets,
            defaultWidth: defaultWidth,
            minFraction: 0.15
        )
    }

    static var configPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/scrollwm/config.toml")
    }

    // MARK: - 加载

    /// 从磁盘加载；文件缺失时写出默认模板。解析失败返回默认配置 + 警告。
    static func load() -> (config: Config, warnings: [String]) {
        let path = configPath
        if !FileManager.default.fileExists(atPath: path) {
            writeDefaultTemplate(to: path)
            return (Config(), [])
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (Config(), [L10n.text("config.warn.unreadable", path)])
        }
        return parse(toml: text)
    }

    static func parse(toml text: String) -> (config: Config, warnings: [String]) {
        var config = Config()
        var warnings: [String] = []

        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch {
            return (Config(), [L10n.text("config.warn.toml", "\(error)")])
        }

        func number(_ value: TOMLValueConvertible?) -> Double? {
            if let d = value?.tomlValue.double { return d }
            if let i = value?.tomlValue.int { return Double(i) }
            return nil
        }

        if let general = table["general"]?.tomlValue.table {
            if let name = general["language"]?.tomlValue.string {
                if let lang = AppLanguage(rawValue: name) {
                    config.language = lang
                } else {
                    warnings.append(L10n.text("config.warn.unknownLanguage", name))
                }
            }
        }

        if let gaps = table["gaps"]?.tomlValue.table {
            if let v = number(gaps["inner"]) { config.innerGap = max(0, v) }
            if let v = number(gaps["outer"]) { config.outerGap = max(0, v) }
            if let v = number(gaps["screen_margin"]) { config.screenMargin = max(0, v) }
        }

        if let layout = table["layout"]?.tomlValue.table {
            if let arr = layout["width_presets"]?.tomlValue.array {
                let presets = arr.compactMap { number($0) }.filter { $0 > 0.05 && $0 <= 1.0 }
                if presets.isEmpty {
                    warnings.append(L10n.text("config.warn.presetsEmpty"))
                } else {
                    config.widthPresets = presets.sorted()
                }
            }
            if let v = number(layout["default_width"]), v > 0.05, v <= 1.0 {
                config.defaultWidth = v
            }
            if let v = number(layout["resize_step"]), v > 0, v <= 0.5 {
                config.resizeStep = v
            }
            if let name = layout["new_window_side"]?.tomlValue.string {
                if let side = NewWindowSide(rawValue: name) {
                    config.newWindowSide = side
                } else {
                    warnings.append(L10n.text("config.warn.newWindowSide", name))
                }
            }
        }

        if let animation = table["animation"]?.tomlValue.table {
            if let enabled = animation["enabled"]?.tomlValue.bool {
                config.animationEnabled = enabled
            }
            if let v = animation["high_frame_rate"]?.tomlValue.bool {
                config.animationHighFrameRate = v
            }
            if let name = animation["mode"]?.tomlValue.string {
                if let mode = AnimationMode(rawValue: name) {
                    config.animationMode = mode
                } else {
                    warnings.append(L10n.text("config.warn.animationMode", name))
                }
            }
            if let v = number(animation["duration_ms"]), v >= 0, v <= 1000 {
                config.animationDurationMs = v
            }
            if let name = animation["curve"]?.tomlValue.string {
                if let curve = Interpolation.Curve(rawValue: name) {
                    config.animationCurve = curve
                } else {
                    warnings.append(
                        L10n.text("config.warn.animationCurve", name)
                    )
                }
            }
            if let v = number(animation["damping_ratio"]), v >= 0.1, v <= 10 {
                config.springDampingRatio = v
            } else if animation["damping_ratio"] != nil {
                warnings.append(L10n.text("config.warn.damping"))
            }
            if let v = number(animation["stiffness"]), v >= 1, v <= 5000 {
                config.springStiffness = v
            } else if animation["stiffness"] != nil {
                warnings.append(L10n.text("config.warn.stiffness"))
            }
            if let v = number(animation["epsilon"]), v >= 0.00001, v <= 0.1 {
                config.springEpsilon = v
            } else if animation["epsilon"] != nil {
                warnings.append(L10n.text("config.warn.epsilon"))
            }
        }

        if let focusRing = table["focus_ring"]?.tomlValue.table {
            if let enabled = focusRing["enabled"]?.tomlValue.bool {
                config.focusRingEnabled = enabled
            }
            if let v = number(focusRing["width"]), v >= 1, v <= 8 {
                config.focusRingWidth = v
            } else if focusRing["width"] != nil {
                warnings.append(L10n.text("config.warn.ringWidth"))
            }
            if let v = number(focusRing["glow_radius"]), v >= 0, v <= 24 {
                config.focusRingGlowRadius = v
            } else if focusRing["glow_radius"] != nil {
                warnings.append(L10n.text("config.warn.ringGlow"))
            }
            if let v = focusRing["always_on"]?.tomlValue.bool {
                config.focusRingAlwaysOn = v
            }
        }

        if let apps = table["apps"]?.tomlValue.table,
           let arr = apps["ignore"]?.tomlValue.array {
            config.ignoreBundleIDs = Set(arr.compactMap { $0.tomlValue.string })
        }

        // 合并语义：从默认键位出发，用户条目逐键覆盖；"none" 解绑默认键位。
        // 这样配置里只需写差异，新版默认键位也能自动生效。
        if let bindingsTable = table["bindings"]?.tomlValue.table {
            var bindings = Config.defaultBindings
            for key in bindingsTable.keys {
                guard let name = bindingsTable[key]?.tomlValue.string else {
                    warnings.append(L10n.text("config.warn.bindingNotString", key))
                    continue
                }
                guard let action = WMAction(rawValue: name) else {
                    warnings.append(L10n.text("config.warn.unknownAction", name, key))
                    continue
                }
                let combo = key.lowercased()
                if action == .unbind {
                    bindings.removeValue(forKey: combo)
                } else {
                    bindings[combo] = action
                }
            }
            config.bindings = bindings
        }

        retireLegacyResizeBindings(&config.bindings)

        return (config, warnings)
    }

    /// zoom-in/out 与加宽/减窄重复，已合并移除；⌘/⌃ +/- 的旧绑定一并清掉，把 ⌘+/- 还给 App。
    private static func retireLegacyResizeBindings(_ bindings: inout [String: WMAction]) {
        let retired: [(combo: String, action: WMAction)] = [
            ("cmd-equal", .growWidth),
            ("cmd-shift-equal", .growWidth),
            ("cmd-plus", .growWidth),
            ("cmd-minus", .shrinkWidth),
            ("ctrl-equal", .growWidth),
            ("ctrl-shift-equal", .growWidth),
            ("ctrl-kpplus", .growWidth),
            ("ctrl-minus", .shrinkWidth),
            ("ctrl-kpminus", .shrinkWidth),
            ("cmd-kpplus", .growWidth),
            ("cmd-kpminus", .shrinkWidth),
        ]
        for item in retired where bindings[item.combo] == item.action {
            bindings.removeValue(forKey: item.combo)
        }
    }

    // MARK: - 写回（设置窗口保存用）

    /// 序列化为带注释的 TOML 文本。支持的全部键都会完整写出，
    /// 与 parse 往返一致：解绑的默认键位写 "none"，其余按键位名字典序。
    func serialize() -> String {
        var lines: [String] = []
        lines.append("# \(L10n.text("config.header"))")
        lines.append("")
        lines.append("[general]")
        lines.append("language = \"\(language.rawValue)\"   # \(L10n.text("config.general.language"))")
        lines.append("")
        lines.append("[gaps]")
        lines.append("inner = \(Self.toml(innerGap))           # \(L10n.text("config.gaps.inner"))")
        lines.append("outer = \(Self.toml(outerGap))          # \(L10n.text("config.gaps.outer"))")
        lines.append("screen_margin = \(Self.toml(screenMargin))   # \(L10n.text("config.gaps.screenMargin"))")
        lines.append("")
        lines.append("[layout]")
        lines.append("width_presets = [\(widthPresets.map(Self.toml).joined(separator: ", "))]  # \(L10n.text("config.layout.presets"))")
        lines.append("default_width = \(Self.toml(defaultWidth))                       # \(L10n.text("config.layout.defaultWidth"))")
        lines.append("resize_step = \(Self.toml(resizeStep))                        # \(L10n.text("config.layout.resizeStep"))")
        lines.append("new_window_side = \"\(newWindowSide.rawValue)\"                  # \(L10n.text("config.layout.newWindowSide"))")
        lines.append("")
        lines.append("[animation]")
        lines.append("enabled = \(animationEnabled)")
        lines.append("mode = \"\(animationMode.rawValue)\"")
        lines.append("damping_ratio = \(Self.toml(springDampingRatio))")
        lines.append("stiffness = \(Self.toml(springStiffness))")
        lines.append("epsilon = \(Self.toml(springEpsilon))")
        lines.append("duration_ms = \(Self.toml(animationDurationMs))   # \(L10n.text("config.animation.easing"))")
        lines.append("curve = \"\(animationCurve.rawValue)\"  # \(L10n.text("config.animation.easing"))")
        lines.append("high_frame_rate = \(animationHighFrameRate)   # \(L10n.text("config.animation.highFrameRate"))")
        lines.append("")
        lines.append("[focus_ring]")
        lines.append("enabled = \(focusRingEnabled)")
        lines.append("width = \(Self.toml(focusRingWidth))")
        lines.append("glow_radius = \(Self.toml(focusRingGlowRadius))")
        lines.append("always_on = \(focusRingAlwaysOn)   # \(L10n.text("config.ring.alwaysOn"))")
        lines.append("")
        lines.append("[apps]")
        let ignored = ignoreBundleIDs.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        lines.append("ignore = [\(ignored)]   # \(L10n.text("config.apps.ignore"))")
        lines.append("")
        lines.append("[bindings]")
        lines.append("# \(L10n.text("config.bindings.format"))")
        for combo in Config.defaultBindingPairs.map(\.combo) {
            if let action = bindings[combo] {
                lines.append("\"\(combo)\" = \"\(action.rawValue)\"")
            } else {
                lines.append("\"\(combo)\" = \"none\"")
            }
        }
        for (combo, action) in bindings.sorted(by: { $0.key < $1.key })
        where Config.defaultBindings[combo] == nil {
            lines.append("\"\(combo)\" = \"\(action.rawValue)\"")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// 原子写回磁盘。写完由 ConfigWatcher 触发热重载生效。
    /// 返回是否成功，设置窗口据此提示用户（内存态已生效但没有持久化）。
    @discardableResult
    func write(to path: String = Config.configPath) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try serialize().write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.error("配置文件写入失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 整数不带小数点（6 而非 6.0），其余取 Double 的最短十进制表示
    private static func toml(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1_000_000_000 {
            return String(Int(v))
        }
        return String(v)
    }

    // MARK: - 默认模板

    private static func writeDefaultTemplate(to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? defaultTemplate.write(toFile: path, atomically: true, encoding: .utf8)
        Log.info("已生成默认配置：\(path)")
    }

    static let defaultTemplate = """
    # \(L10n.text("config.templateHeader"))

    [general]
    language = "system"   # \(L10n.text("config.general.language"))

    [gaps]
    inner = 6           # \(L10n.text("config.gaps.inner"))
    outer = 12          # \(L10n.text("config.gaps.outer"))
    screen_margin = 6   # \(L10n.text("config.gaps.screenMargin"))

    [layout]
    width_presets = [0.33333, 0.5, 0.66667]  # \(L10n.text("config.layout.presets"))
    default_width = 0.5                       # \(L10n.text("config.layout.defaultWidth"))
    resize_step = 0.05                        # \(L10n.text("config.layout.resizeStep"))
    new_window_side = "right"                 # \(L10n.text("config.layout.newWindowSide"))

    [animation]
    enabled = true
    mode = "spring"
    # \(L10n.text("config.template.spring"))
    damping_ratio = 1.0
    stiffness = 800
    epsilon = 0.0001
    # \(L10n.text("config.template.easing"))
    duration_ms = 240
    curve = "ease-out-quint"
    # \(L10n.text("config.animation.highFrameRate"))
    high_frame_rate = false

    [focus_ring]
    enabled = true
    width = 3
    glow_radius = 9
    always_on = false   # \(L10n.text("config.ring.alwaysOn"))

    [apps]
    # \(L10n.text("config.apps.ignore"))
    ignore = []
    # \(L10n.text("config.apps.example"))

    # \(L10n.text("config.bindings.format"))
    # \(L10n.text("config.bindings.modifiers"))
    # \(L10n.text("config.bindings.semantics"))
    [bindings]
    # \(L10n.text("config.bindings.defaults"))
    # "alt-left" = "focus-left"       "alt-right" = "focus-right"
    # "alt-h" = "focus-left"          "alt-l" = "focus-right"   # \(L10n.text("config.bindings.vimAliases"))
    # "alt-shift-h" = "move-left"     "alt-shift-l" = "move-right"
    # "alt-r" = "cycle-width"         "alt-f" = "toggle-full-width"
    # "alt-minus" = "shrink-width"    "alt-equal" = "grow-width"
    # "alt-c" = "center-column"       "alt-t" = "toggle-float"
    # "alt-q" = "close-window"        "alt-shift-r" = "retile"
    """
}

// MARK: - 配置文件监听（热重载）

/// 监听配置文件变更。编辑器普遍用原子替换保存（rename），
/// 因此 rename/delete 后需要重新挂监听。
final class ConfigWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchWorkItem?
    private var debounce: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        source?.cancel()
        source = nil
        retry?.cancel()
        retry = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // 文件暂不存在：稍后重试
            let work = DispatchWorkItem { [weak self] in
                self?.retry = nil
                self?.start()
            }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.scheduleChange()
            if flags.contains(.rename) || flags.contains(.delete) {
                // 原子保存后旧 fd 失效，重新挂监听
                self.start()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        retry?.cancel()
        retry = nil
        debounce?.cancel()
        debounce = nil
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.debounce = nil
            self?.onChange()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
