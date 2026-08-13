import Foundation
import ScrollCore
import TOMLKit

enum AnimationMode: String, Equatable {
    case spring
    case easing
}

/// 用户配置。缺省值即为推荐配置，配置文件可只覆盖关心的字段。
struct Config: Equatable {
    var innerGap: Double = 6
    var outerGap: Double = 12
    var screenMargin: Double = 6
    var widthPresets: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    var defaultWidth: Double = 0.5
    var resizeStep: Double = 0.05
    var animationEnabled: Bool = true
    var animationMode: AnimationMode = .spring
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
    var compositorEnabled: Bool = false
    var ignoreBundleIDs: Set<String> = []
    var bindings: [String: WMAction] = Config.defaultBindings

    static let defaultBindings: [String: WMAction] = [
        "alt-left": .focusLeft,
        "alt-right": .focusRight,
        // Vim 风格别名保留兼容；用户可在 [bindings] 中用 "none" 解绑。
        "alt-h": .focusLeft,
        "alt-l": .focusRight,
        "alt-shift-h": .moveLeft,
        "alt-shift-l": .moveRight,
        "alt-r": .cycleWidth,
        "alt-minus": .shrinkWidth,
        "alt-equal": .growWidth,
        // Ctrl+加号/减号 窗口放大缩小（加号即 = 键；平铺列调宽，浮动窗等比缩放）
        "ctrl-equal": .growWidth,
        "ctrl-shift-equal": .growWidth,
        "ctrl-kpplus": .growWidth,
        "ctrl-minus": .shrinkWidth,
        "ctrl-kpminus": .shrinkWidth,
        "alt-f": .toggleFullWidth,
        "alt-c": .centerColumn,
        "alt-t": .toggleFloat,
        "alt-q": .closeWindow,
        "alt-shift-r": .retile,
    ]

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
            return (Config(), ["无法读取 \(path)，使用默认配置"])
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
            return (Config(), ["TOML 解析失败：\(error)，使用默认配置"])
        }

        func number(_ value: TOMLValueConvertible?) -> Double? {
            if let d = value?.tomlValue.double { return d }
            if let i = value?.tomlValue.int { return Double(i) }
            return nil
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
                    warnings.append("width_presets 为空或非法，保留默认")
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
        }

        if let animation = table["animation"]?.tomlValue.table {
            if let enabled = animation["enabled"]?.tomlValue.bool {
                config.animationEnabled = enabled
            }
            if let name = animation["mode"]?.tomlValue.string {
                if let mode = AnimationMode(rawValue: name) {
                    config.animationMode = mode
                } else {
                    warnings.append("未知 animation.mode \"\(name)\"，可选：spring / easing")
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
                        "未知 animation.curve \"\(name)\"，可选：ease-out-quint / ease-out-cubic / ease-out-expo / smoothstep"
                    )
                }
            }
            if let v = number(animation["damping_ratio"]), v >= 0.1, v <= 10 {
                config.springDampingRatio = v
            } else if animation["damping_ratio"] != nil {
                warnings.append("animation.damping_ratio 必须在 0.1...10 之间")
            }
            if let v = number(animation["stiffness"]), v >= 1, v <= 5000 {
                config.springStiffness = v
            } else if animation["stiffness"] != nil {
                warnings.append("animation.stiffness 必须在 1...5000 之间")
            }
            if let v = number(animation["epsilon"]), v >= 0.00001, v <= 0.1 {
                config.springEpsilon = v
            } else if animation["epsilon"] != nil {
                warnings.append("animation.epsilon 必须在 0.00001...0.1 之间")
            }
        }

        if let focusRing = table["focus_ring"]?.tomlValue.table {
            if let enabled = focusRing["enabled"]?.tomlValue.bool {
                config.focusRingEnabled = enabled
            }
            if let v = number(focusRing["width"]), v >= 1, v <= 8 {
                config.focusRingWidth = v
            } else if focusRing["width"] != nil {
                warnings.append("focus_ring.width 必须在 1...8 之间")
            }
            if let v = number(focusRing["glow_radius"]), v >= 0, v <= 24 {
                config.focusRingGlowRadius = v
            } else if focusRing["glow_radius"] != nil {
                warnings.append("focus_ring.glow_radius 必须在 0...24 之间")
            }
        }

        if let compositor = table["compositor"]?.tomlValue.table {
            if let enabled = compositor["enabled"]?.tomlValue.bool {
                config.compositorEnabled = enabled
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
                    warnings.append("键位 \(key) 的动作不是字符串，忽略")
                    continue
                }
                guard let action = WMAction(rawValue: name) else {
                    warnings.append("未知动作 \"\(name)\"（键位 \(key)），忽略")
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

        return (config, warnings)
    }

    // MARK: - 默认模板

    private static func writeDefaultTemplate(to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? defaultTemplate.write(toFile: path, atomically: true, encoding: .utf8)
        Log.info("已生成默认配置：\(path)")
    }

    static let defaultTemplate = """
    # scrollwm 配置文件（保存后自动热重载）

    [gaps]
    inner = 6           # 列间距（可自由调整）
    outer = 12          # 屏幕外边距
    screen_margin = 6   # 视口外停靠列露出的细纸边宽度

    [layout]
    width_presets = [0.33333, 0.5, 0.66667]  # cycle-width 循环的宽度预设
    default_width = 0.5                       # 新窗口默认列宽
    resize_step = 0.05                        # grow/shrink-width 步长

    [animation]
    enabled = true
    mode = "spring"
    # niri horizontal-view-movement 默认：最快到位且不回弹
    damping_ratio = 1.0
    stiffness = 800
    epsilon = 0.0001
    # mode = "easing" 时使用下面两项
    duration_ms = 240
    curve = "ease-out-quint"

    [focus_ring]
    enabled = true
    width = 3
    glow_radius = 9

    [apps]
    # 不接管的 App（bundle id）
    ignore = []
    # 示例：ignore = ["com.apple.systempreferences"]

    # 键位格式："修饰键-...-键名" = "动作"
    # 修饰键：alt / cmd / ctrl / shift；键名：字母、数字、minus、equal（即加号键）、
    # plus（等同 equal）、kpplus/kpminus（数字小键盘）、方向键 left/right/up/down、space、tab 等
    # 语义：默认键位始终生效，此处条目按键覆盖；写 "none" 可解绑某个默认键位。
    [bindings]
    # 默认键位（无需重复，仅作参考）：
    # "alt-left" = "focus-left"       "alt-right" = "focus-right"
    # "alt-h" = "focus-left"          "alt-l" = "focus-right"   # Vim 风格别名
    # "alt-shift-h" = "move-left"     "alt-shift-l" = "move-right"
    # "alt-r" = "cycle-width"         "alt-f" = "toggle-full-width"
    # "alt-minus" = "shrink-width"    "alt-equal" = "grow-width"
    # "ctrl-minus" = "shrink-width"   "ctrl-equal" = "grow-width"   # Ctrl+加号/减号 放大缩小
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
    private var debounce: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // 文件暂不存在：稍后重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
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
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
