import AppKit
import ServiceManagement

/// 菜单栏逃生门：暂停/恢复、立即重排、重载配置、开机自启、退出
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let pauseItem = NSMenuItem(title: "暂停管理", action: #selector(togglePause), keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "启动中…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLoginItem), keyEquivalent: "")
    private let checkItem = NSMenuItem(title: "检查辅助功能授权", action: #selector(checkPermission), keyEquivalent: "")
    private let accessibilitySettingsItem = NSMenuItem(title: "打开系统设置 → 辅助功能", action: #selector(openSettings), keyEquivalent: "")

    var onQuit: (() -> Void)?
    var onCheckPermission: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// 打开 scrollwm 自己的设置窗口（区别于 onOpenSettings 的系统辅助功能设置）
    var onOpenAppSettings: (() -> Void)?
    /// 重播首次运行的引导
    var onShowWelcome: (() -> Void)?
    /// 授权等待态的提示条（占位，会在 refresh 中更新文案）
    private let permissionHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// 是否以 .app bundle 形式运行（SMAppService 只在 bundle 下可用）
    private var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.menuBarImage()
            button.image?.isTemplate = true
            button.toolTip = "ScrollWM"
        }

        // 精简菜单：状态 → 暂停/恢复 → 设置… → 开机自启 → 退出。
        // 授权相关项仅在未授权时显示；重排/打开配置文件移入设置窗口。
        let menu = NSMenu()
        // 默认 autoenablesItems 会按 target/action 覆盖手动 isEnabled，
        // 导致未授权时"暂停管理"看起来仍可点；必须自己管理。
        menu.autoenablesItems = false
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        permissionHintItem.isEnabled = false
        permissionHintItem.isHidden = true
        menu.addItem(permissionHintItem)

        checkItem.target = self
        checkItem.isHidden = true
        menu.addItem(checkItem)

        accessibilitySettingsItem.target = self
        accessibilitySettingsItem.isHidden = true
        menu.addItem(accessibilitySettingsItem)

        menu.addItem(.separator())

        pauseItem.target = self
        menu.addItem(pauseItem)

        let appSettingsItem = NSMenuItem(title: "设置…", action: #selector(openAppSettings), keyEquivalent: "")
        appSettingsItem.target = self
        menu.addItem(appSettingsItem)

        let welcomeItem = NSMenuItem(title: "欢迎介绍…", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)

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

    /// 菜单栏模板图：两侧细纸边 + 中间焦点列，对应横向纸带布局。
    private static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()

            func column(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat) {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r).fill()
            }

            // 18pt 画布：左/右停靠纸边略矮，中间列为焦点窗口
            column(x: 1.5, y: 4, w: 3, h: 10, r: 1)
            column(x: 6, y: 2.5, w: 6, h: 13, r: 1.5)
            column(x: 13.5, y: 4, w: 3, h: 10, r: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ScrollWM"
        return image
    }

    func refresh() {
        // 授权相关项只在未授权时露出，授权后菜单自动瘦身
        let trusted = AXIsProcessTrusted()
        checkItem.isHidden = trusted
        accessibilitySettingsItem.isHidden = trusted

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

    @objc private func openAppSettings() {
        onOpenAppSettings?()
    }

    @objc private func showWelcome() {
        onShowWelcome?()
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
