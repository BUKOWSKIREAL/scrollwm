import AppKit
import ServiceManagement

/// 菜单栏逃生门：暂停/恢复、立即重排、重载配置、开机自启、退出
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let pauseItem = NSMenuItem(title: "暂停管理", action: #selector(togglePause), keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "启动中…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLoginItem), keyEquivalent: "")

    var onQuit: (() -> Void)?
    var onReload: (() -> Void)?
    var onCheckPermission: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// 授权等待态的提示条（占位，会在 refresh 中更新文案）
    private let permissionHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// 是否以 .app bundle 形式运行（SMAppService 只在 bundle 下可用）
    private var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.split.3x1",
                accessibilityDescription: "scrollwm"
            )
            if button.image == nil { button.title = "SW" }
        }

        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        permissionHintItem.isEnabled = false
        permissionHintItem.isHidden = true
        menu.addItem(permissionHintItem)
        menu.addItem(.separator())

        let checkItem = NSMenuItem(title: "检查辅助功能授权", action: #selector(checkPermission), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)

        let settingsItem = NSMenuItem(title: "打开系统设置 → 辅助功能", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        pauseItem.target = self
        menu.addItem(pauseItem)

        let retileItem = NSMenuItem(title: "立即重排", action: #selector(retileNow), keyEquivalent: "")
        retileItem.target = self
        menu.addItem(retileItem)

        menu.addItem(.separator())

        let reloadItem = NSMenuItem(title: "重载配置", action: #selector(reloadConfig), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let openConfigItem = NSMenuItem(title: "打开配置文件", action: #selector(openConfig), keyEquivalent: "")
        openConfigItem.target = self
        menu.addItem(openConfigItem)

        if isBundled {
            menu.addItem(.separator())
            loginItem.target = self
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 scrollwm", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        refresh()
    }

    func refresh() {
        guard let wm = WindowManager.shared else {
            let bid = Bundle.main.bundleIdentifier ?? "com.scrollwm.daemon"
            stateItem.title = "等待辅助功能授权…"
            permissionHintItem.isHidden = false
            permissionHintItem.title = "标识: \(bid)  · 需在 系统设置→隐私→辅助功能 中勾选"
            pauseItem.isEnabled = false
            return
        }
        permissionHintItem.isHidden = true
        pauseItem.isEnabled = true
        stateItem.title = wm.paused ? "已暂停" : "运行中 · \(wm.statusSummary)"
        pauseItem.title = wm.paused ? "恢复管理" : "暂停管理"
        if isBundled {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func togglePause() {
        guard let wm = WindowManager.shared else { return }
        wm.setPaused(!wm.paused)
        refresh()
    }

    @objc private func retileNow() {
        WindowManager.shared?.perform(.retile)
    }

    @objc private func reloadConfig() {
        onReload?()
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.configPath))
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            Log.warn("切换开机自启失败：\(error.localizedDescription)")
        }
        refresh()
    }

    @objc private func checkPermission() {
        onCheckPermission?()
        refresh()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
