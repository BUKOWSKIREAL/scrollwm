import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusController = StatusItemController()
    private var windowManager: WindowManager?
    private var hotkeys: HotkeyManager?
    private var configWatcher: ConfigWatcher?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController.onQuit = { NSApp.terminate(nil) }
        statusController.onReload = { [weak self] in self?.reloadConfig() }
        statusController.onCheckPermission = { [weak self] in self?.checkPermissionFromMenu() }
        statusController.onOpenSettings = { AppDelegate.openAccessibilitySettings() }
        statusController.install()

        // 先以不弹窗的方式自检：若系统弹窗被关闭后不再自动弹出，带 prompt 的轮询会卡住。
        // 自检失败则每 1.5s 静默轮询一次，一旦授权立即进 boot；用户也可通过菜单手动触发。
        if AXIsProcessTrusted() {
            boot()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        // 只弹一次系统授权弹窗
        _ = AXIsProcessTrustedWithOptions(options)
        Log.warn("等待辅助功能授权：系统设置 → 隐私与安全性 → 辅助功能（bundle: \(Bundle.main.bundleIdentifier ?? "-"))。已在菜单栏提供“检查授权/打开设置”")
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                Log.info("辅助功能已授权，进入管理")
                timer.invalidate()
                self?.permissionTimer = nil
                self?.boot()
                self?.statusController.refresh()
            } else {
                self?.statusController.refresh()
            }
        }
        statusController.refresh()
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
        // 深链直达辅助功能页，失败则退回隐私页
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
    }

    private func boot() {
        let (config, warnings) = Config.load()
        warnings.forEach { Log.warn($0) }

        let wm = WindowManager(config: config)
        windowManager = wm
        wm.onStateChange = { [weak self] in self?.statusController.refresh() }

        let hk = HotkeyManager { action in
            WindowManager.shared?.perform(action)
        }
        hk.register(bindings: config.bindings).forEach { Log.warn($0) }
        hotkeys = hk

        let watcher = ConfigWatcher(path: Config.configPath) { [weak self] in
            Log.info("配置文件变更，自动重载")
            self?.reloadConfig()
        }
        watcher.start()
        configWatcher = watcher

        wm.start()
        statusController.refresh()
        Log.info("scrollwm 就绪")
    }

    private func reloadConfig() {
        guard let wm = windowManager else { return }
        let (config, warnings) = Config.load()
        warnings.forEach { Log.warn($0) }
        hotkeys?.register(bindings: config.bindings).forEach { Log.warn($0) }
        wm.updateConfig(config)
        statusController.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregisterAll()
        configWatcher?.stop()
        Log.info("scrollwm 退出（窗口保持当前位置）")
    }
}
