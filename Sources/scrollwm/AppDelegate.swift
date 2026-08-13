import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusController = StatusItemController()
    private var windowManager: WindowManager?
    private var hotkeys: HotkeyManager?
    private var configWatcher: ConfigWatcher?
    private var permissionTimer: Timer?
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?
    /// 重播引导时暂时让出 Carbon 全局热键，交给引导窗口练习真实组合键。
    private var welcomeSuspendedHotkeys = false
    /// 上次注册给 HotkeyManager 的键位；只有真正变化才重注册，避免 Carbon 反复卸载/注册
    private var lastAppliedBindings: [String: WMAction] = [:]

    /// 抑制「设置窗口写盘 → ConfigWatcher 回声」：generation 递增，
    /// 而不是 timeInterval（1s 窗口在用户连续拖滑块时会把后续外部手改误抑制）。
    private var configGeneration: UInt64 = 0
    private var suppressedGeneration: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController.onQuit = { NSApp.terminate(nil) }
        statusController.onCheckPermission = { [weak self] in self?.checkPermissionFromMenu() }
        statusController.onOpenSettings = { AppDelegate.openAccessibilitySettings() }
        statusController.onOpenAppSettings = { [weak self] in self?.settingsWindow?.show() }
        statusController.onShowWelcome = { [weak self] in self?.presentWelcome() }
        statusController.install()

        // 设置窗口在等待辅助功能授权期间也要可用（改的是磁盘配置，boot 时会重新读盘）。
        let (config, warnings) = Config.load()
        warnings.forEach { Log.warn($0) }
        let model = SettingsModel(config: config)
        model.onChange = { [weak self] newConfig in
            self?.applyConfig(newConfig, source: .ui)
        }
        model.onPreview = { [weak self] newConfig in
            self?.applyRuntimeConfig(newConfig)
        }
        settingsWindow = SettingsWindowController(model: model)

        // 首次运行：引导页自己会在合适的时机请求授权，别让系统弹窗抢在它前面
        // `--welcome` 是可重复的预览 / 回归测试入口；菜单栏重播仍是普通用户入口。
        let firstRun = !WelcomeState.hasSeen || CommandLine.arguments.contains("--welcome")
        if firstRun { presentWelcome() }

        if AXIsProcessTrusted() {
            // 已有授权但首次见引导（重装 / 引导版本升级）时，先别在背景里突然
            // 重排桌面。引导关闭后 onDismiss 会补 boot。
            if !firstRun { boot() }
            statusController.refresh()
            return
        }
        if !firstRun {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        Log.warn("等待辅助功能授权：系统设置 → 隐私与安全性 → 辅助功能（bundle: \(Bundle.main.bundleIdentifier ?? "-"))。已在菜单栏提供“检查授权/打开设置”")
        startPermissionWatch()
        statusController.refresh()
    }

    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                Log.info("辅助功能已授权，进入管理")
                timer.invalidate()
                self?.permissionTimer = nil
                // 用户刚从系统设置切回来时先让引导完整收尾，避免桌面窗口在
                // 最后一幕背后突然移动；关闭引导后再启动管理器。
                if self?.welcomeWindow == nil {
                    self?.boot()
                }
                self?.statusController.refresh()
            } else {
                self?.statusController.refresh()
            }
        }
    }

    // MARK: - 引导

    private func presentWelcome() {
        if let welcomeWindow {
            welcomeWindow.bringToFront()
            return
        }
        if let hotkeys {
            hotkeys.unregisterAll()
            welcomeSuspendedHotkeys = true
        }
        let controller = WelcomeWindowController()
        controller.model.onRequestPermission = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            AppDelegate.openAccessibilitySettings()
        }
        controller.onDismiss = { [weak self] in
            guard let self else { return }
            self.welcomeWindow = nil
            self.restoreHotkeysAfterWelcome()
            // 引导期间用户可能刚授权完；此时还没 boot 的话立刻补上
            if AXIsProcessTrusted(), self.windowManager == nil {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.boot()
                self.statusController.refresh()
            }
        }
        welcomeWindow = controller
        controller.show()
    }

    private func restoreHotkeysAfterWelcome() {
        guard welcomeSuspendedHotkeys else { return }
        welcomeSuspendedHotkeys = false
        guard let hotkeys else { return }
        let bindings = settingsWindow?.model.config.bindings ?? Config.load().config.bindings
        lastAppliedBindings = bindings
        hotkeys.register(bindings: bindings).forEach { Log.warn($0) }
    }

    private func checkPermissionFromMenu() {
        if AXIsProcessTrusted() {
            Log.info("检查：辅助功能已授权")
            permissionTimer?.invalidate()
            permissionTimer = nil
            if windowManager == nil { boot() }
            statusController.refresh()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Log.warn("检查：仍未授权，请到 系统设置 → 隐私与安全性 → 辅助功能 勾选 ScrollWM（当前 bundle: \(Bundle.main.bundleIdentifier ?? "-"))")
    }

    private static func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
    }

    // MARK: - Boot

    private func boot() {
        // 等待授权期间用户可能已在设置窗口改过配置（直接落盘），以磁盘为准
        let (config, warnings) = Config.load()
        warnings.forEach { Log.warn($0) }
        settingsWindow?.model.syncFromDisk(config)

        let wm = WindowManager(config: config)
        windowManager = wm
        wm.onStateChange = { [weak self] in self?.statusController.refresh() }

        let hk = HotkeyManager { action in WindowManager.shared?.perform(action) }
        hk.register(bindings: config.bindings).forEach { Log.warn($0) }
        lastAppliedBindings = config.bindings
        hotkeys = hk

        let watcher = ConfigWatcher(path: Config.configPath) { [weak self] in
            Log.info("配置文件变更，自动重载")
            self?.reloadFromDisk()
        }
        watcher.start()
        configWatcher = watcher

        wm.start()
        statusController.refresh()
        Log.info("scrollwm 就绪")
    }

    // MARK: - Config 应用

    private enum ConfigSource { case ui, disk }

    /// 来自设置窗口：直接应用内存 Config，不读盘；同时抑制下一次文件监听回声
    private func applyConfig(_ config: Config, source: ConfigSource) {
        guard source == .ui else { return }
        configGeneration &+= 1
        suppressedGeneration = configGeneration
        applyRuntimeConfig(config)
        // 注意：不 sync 到 model，model 已经是最新
    }

    /// 把配置应用到运行时组件（热键差异化重注册 + WM）。滑块预览也走这里，必须廉价。
    private func applyRuntimeConfig(_ config: Config) {
        if let hotkeys, !welcomeSuspendedHotkeys, config.bindings != lastAppliedBindings {
            lastAppliedBindings = config.bindings
            hotkeys.register(bindings: config.bindings).forEach { Log.warn($0) }
        }
        windowManager?.updateConfig(config)
        statusController.refresh()
    }

    /// 来自 ConfigWatcher（外部手改或 UI 回声）：读盘 + 去重 + 同步
    private func reloadFromDisk() {
        let (config, warnings) = Config.load()
        warnings.forEach { Log.warn($0) }

        // UI 刚刚写入触发的回声：跳过，避免无谓重载和 UI 闪动
        if suppressedGeneration == configGeneration, config == settingsWindow?.model.config {
            suppressedGeneration = 0 // 只抑制一次
            return
        }
        suppressedGeneration = 0

        applyRuntimeConfig(config)
        settingsWindow?.model.syncFromDisk(config)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregisterAll()
        configWatcher?.stop()
        Log.info("scrollwm 退出（窗口保持当前位置）")
    }
}
