import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print("scrollwm 0.1.0")
    exit(0)
}

if arguments.contains("--check") {
    // 只报告权限状态，不启动管理（安全的冒烟检查入口）
    let trusted = AXIsProcessTrusted()
    print(trusted ? "accessibility: granted" : "accessibility: NOT granted")
    print("config: \(Config.configPath)")
    exit(trusted ? 0 : 1)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    scrollwm - niri 式 macOS 卷轴平铺窗口管理器

    用法:
      scrollwm             启动守护进程（需辅助功能权限）
      scrollwm --check     检查辅助功能授权状态后退出
      scrollwm --version   打印版本
    """)
    exit(0)
}

// 语言覆盖：在创建任何 UI 之前根据配置设置 AppleLanguages，
// 让本次启动全程使用所选语言（system / en / zh-hans，设置里可改）。
// Config.load() 在文件缺失时会写出默认模板，与 AppDelegate 后续行为一致。
let (bootConfig, _) = Config.load()
bootConfig.language.apply()
AppFonts.register()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
