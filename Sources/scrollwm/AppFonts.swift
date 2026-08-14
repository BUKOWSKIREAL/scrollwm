import AppKit
import CoreText
import SwiftUI

// ============================================================
//  全局英文字体：JetBrainsMono Nerd Font
//  中文会通过系统字体回退（Cascade）自动兜底，不会出现豆腐块。
// ============================================================

enum AppFonts {
    private static var didRegister = false

    /// 在进程启动时调用一次；把打包进 App 的 ttf 注册到当前进程。
    /// 同时兼容 SwiftPM 的 scrollwm_scrollwm.bundle 与最终 .app 的 Resources/Fonts。
    static func register() {
        guard !didRegister else { return }
        didRegister = true

        var urls: [URL] = []

        // 1) 主 Bundle 直属（.app/Contents/Resources 或开发时的可执行同目录）
        if let found = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) {
            urls.append(contentsOf: found)
        }
        if let found = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") {
            urls.append(contentsOf: found)
        }
        // 显式探查 Resources/Fonts 目录（ATSApplicationFontsPath 指向这里）
        let fontsDir = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Fonts", isDirectory: true)
        if let enumerator = FileManager.default.enumerator(at: fontsDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "ttf" {
                urls.append(url)
            }
        }
        let fontsDir2 = Bundle.main.bundleURL.appendingPathComponent("Resources/Fonts", isDirectory: true)
        if let enumerator = FileManager.default.enumerator(at: fontsDir2, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "ttf" {
                urls.append(url)
            }
        }

        // 2) SwiftPM 资源 bundle（swift run / swift build 时）
        if let resBundleURL = Bundle.main.url(forResource: "scrollwm_scrollwm", withExtension: "bundle"),
           let resBundle = Bundle(url: resBundleURL) {
            if let found = resBundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) {
                urls.append(contentsOf: found)
            }
            if let found = resBundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") {
                urls.append(contentsOf: found)
            }
        }
        // 备用：通过当前类的 Bundle 找
        let thisBundle = Bundle(for: _BundleAnchor.self)
        if let found = thisBundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) {
            urls.append(contentsOf: found)
        }
        if let found = thisBundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") {
            urls.append(contentsOf: found)
        }

        // 去重
        let unique = Array(Set(urls))
        guard !unique.isEmpty else {
            // 系统已安装字体时，即使没有打包也能通过家族名匹配到
            return
        }
        for url in unique {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private class _BundleAnchor {}

    // MARK: - PostScript name 映射

    static func psName(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: return "JetBrainsMonoNF-Thin"
        case .thin: return "JetBrainsMonoNF-Thin"
        case .light: return "JetBrainsMonoNF-Light"
        case .regular: return "JetBrainsMonoNF-Regular"
        case .medium: return "JetBrainsMonoNF-Medium"
        case .semibold: return "JetBrainsMonoNF-SemiBold"
        case .bold: return "JetBrainsMonoNF-Bold"
        case .heavy: return "JetBrainsMonoNF-ExtraBold"
        case .black: return "JetBrainsMonoNF-ExtraBold"
        default: return "JetBrainsMonoNF-Regular"
        }
    }

    static func psNameNS(for weight: NSFont.Weight) -> String {
        switch weight {
        case .ultraLight: return "JetBrainsMonoNF-Thin"
        case .thin: return "JetBrainsMonoNF-Thin"
        case .light: return "JetBrainsMonoNF-Light"
        case .regular: return "JetBrainsMonoNF-Regular"
        case .medium: return "JetBrainsMonoNF-Medium"
        case .semibold: return "JetBrainsMonoNF-SemiBold"
        case .bold: return "JetBrainsMonoNF-Bold"
        case .heavy: return "JetBrainsMonoNF-ExtraBold"
        case .black: return "JetBrainsMonoNF-ExtraBold"
        default: return "JetBrainsMonoNF-Regular"
        }
    }

    // MARK: - SwiftUI 入口

    /// 英文主字体（比例版本，含 Nerd Icons 变体，图标可直接用）
    static func jbMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(psName(for: weight), size: size)
    }

    /// 等宽 Mono 版本（图标与字符严格等宽，适合 bundleID / 数值列）
    static func jbMonoMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Mono 家族的 PostScript 多为 JetBrainsMonoNFM-*，但常规权重与比例版同名逻辑
        // 若 Mono 权重缺失，自动回退到比例版
        let monoCandidates: [String] = {
            switch weight {
            case .ultraLight, .thin: return ["JetBrainsMonoNFM-Thin", psName(for: weight)]
            case .light: return ["JetBrainsMonoNFM-Light", psName(for: weight)]
            case .regular: return ["JetBrainsMonoNFM-Regular", psName(for: weight)]
            case .medium: return ["JetBrainsMonoNFM-Medium", psName(for: weight)]
            case .semibold: return ["JetBrainsMonoNFM-SemiBold", psName(for: weight)]
            case .bold: return ["JetBrainsMonoNFM-Bold", psName(for: weight)]
            case .heavy, .black: return ["JetBrainsMonoNFM-ExtraBold", psName(for: weight)]
            default: return [psName(for: weight)]
            }
        }()
        for name in monoCandidates where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .custom(psName(for: weight), size: size)
    }

    // 语义化快捷方式（对齐系统 .caption/.headline 等量级，全部走 JB Mono）
    static var caption: Font { jbMono(size: 11, weight: .regular) }
    static var caption2: Font { jbMono(size: 11, weight: .regular) }
    static var footnote: Font { jbMono(size: 11, weight: .regular) }
    static var subheadline: Font { jbMono(size: 13, weight: .regular) }
    static var headline: Font { jbMono(size: 13, weight: .semibold) }

    // MARK: - AppKit 入口（菜单/非 SwiftUI 场景备用）

    static func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name = psNameNS(for: weight)
        if let f = NSFont(name: name, size: size) { return f }
        // 回退：系统字体至少保证中文可见
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - 全局注入：让 SwiftUI Text 默认走 JB Mono（英文），中文由系统回退

private struct JBFontEnvironmentModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // 将环境字体设为 JB Mono；具体尺寸由各 Text 自身覆盖
            // 这里只提供一个兜底，真正字号仍以 Font.jbMono 指定为准
            .environment(\.font, AppFonts.jbMono(size: 13))
    }
}

extension View {
    /// 在根视图调用一次即可让全树英文默认走 JetBrainsMono Nerd Font
    func jbMonoDefault() -> some View { modifier(JBFontEnvironmentModifier()) }
}
