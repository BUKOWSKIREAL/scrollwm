import Foundation

/// 本地化文案入口：从 SwiftPM 资源包（scrollwm_scrollwm.bundle）读取
/// 当前语言的 Localizable.strings。默认跟随系统语言；用户可在设置里
/// 覆盖（写 AppleLanguages，运行时立即作用于后续求值的文案）。
///
/// 自管语言解析而非依赖 Bundle.preferredLocalizations：后者的结果会被
/// 缓存且在不同宿主下行为不稳定（实测对非主 bundle 不理会 AppleLanguages），
/// 自管解析保证「启动时覆盖」与「设置里即时切换」都按预期工作。
enum L10n {
    private final class Marker {}

    /// 支持的本地化，顺序即优先级（都未命中时回退到第一个）
    static let supportedLanguages = ["zh-Hans", "en"]
    private static let fallbackLanguage = "en"

    /// 依次尝试：.app 资源目录（打包后）、主 bundle 根、可执行文件所在目录
    /// （swift run 开发态），找到 scrollwm_scrollwm.bundle 即返回。
    private static let resourceBundle: Bundle = {
        let bundleName = "scrollwm_scrollwm"
        var candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: Marker.self).resourceURL,
            Bundle.main.bundleURL,
        ]
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent())
        }
        for candidate in candidates {
            guard let url = candidate?.appendingPathComponent(bundleName + ".bundle"),
                  let bundle = Bundle(url: url)
            else { continue }
            return bundle
        }
        return .main
    }()

    private static var loadedTables: [String: [String: String]] = [:]

    /// 当前应使用的语言：AppleLanguages 覆盖优先（设置里写入），
    /// 否则取系统首选语言列表里第一个命中的支持语言。
    static func currentLanguage() -> String {
        let prefs = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
            ?? NSLocale.preferredLanguages
        for pref in prefs {
            for supported in supportedLanguages where Self.matches(pref, supported) {
                return supported
            }
        }
        return fallbackLanguage
    }

    /// "zh-Hans-CN" → "zh-Hans"、"en-GB" → "en"、"zh" → "zh-Hans"
    private static func matches(_ preferred: String, _ supported: String) -> Bool {
        if preferred.caseInsensitiveCompare(supported) == .orderedSame { return true }
        if preferred.lowercased().hasPrefix(supported.lowercased() + "-") { return true }
        if supported.lowercased().hasPrefix(preferred.lowercased() + "-") { return true }
        return false
    }

    /// 取文案；"%@" 占位符按参数顺序替换。缺 key 时回退英文表，再缺则原样返回 key。
    static func text(_ key: String, _ args: CVarArg...) -> String {
        let table = table(for: currentLanguage()) ?? table(for: fallbackLanguage) ?? [:]
        var text = table[key] ?? key
        for arg in args {
            guard let range = text.range(of: "%@") else { break }
            text.replaceSubrange(range, with: "\(arg)")
        }
        return text
    }

    /// 按语言加载文案表并缓存；语言切换后 currentLanguage 变化会自然换表。
    private static func table(for language: String) -> [String: String]? {
        if let cached = loadedTables[language] { return cached }
        guard let path = resourceBundle.path(
            forResource: "Localizable", ofType: "strings",
            inDirectory: nil, forLocalization: language
        ),
        let table = NSDictionary(contentsOfFile: path) as? [String: String]
        else { return nil }
        loadedTables[language] = table
        return table
    }
}

extension Notification.Name {
    /// 语言设置变更（设置窗口或配置热重载触发），菜单栏等长驻 UI 监听后刷新文案
    static let scrollWMLanguageChanged = Notification.Name("scrollwm.language-changed")
}
