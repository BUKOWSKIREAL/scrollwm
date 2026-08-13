import AppKit
import ApplicationServices
import ScrollCore

// MARK: - AXWindow

/// 单个窗口的 AX 句柄。坐标一律为顶左原点全局坐标（AX 原生坐标系）。
final class AXWindow {
    let element: AXUIElement
    let windowID: CGWindowID
    let pid: pid_t

    init?(element: AXUIElement, pid: pid_t) {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        self.element = element
        self.windowID = wid
        self.pid = pid
        // 防挂死：单窗口 AX 消息超时 1s（系统默认 6s，会拖死主线程）
        AXUIElementSetMessagingTimeout(element, 1.0)
    }

    // MARK: 属性读取

    private func copyAttribute(_ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    private func stringAttribute(_ name: String) -> String? {
        copyAttribute(name) as? String
    }

    private func boolAttribute(_ name: String) -> Bool {
        (copyAttribute(name) as? Bool) ?? false
    }

    var role: String? { stringAttribute(kAXRoleAttribute) }
    var subrole: String? { stringAttribute(kAXSubroleAttribute) }
    var title: String { stringAttribute(kAXTitleAttribute) ?? "" }
    var isMinimized: Bool { boolAttribute(kAXMinimizedAttribute) }
    /// 公开常量未导出该字符串，属性名为固定值 "AXFullScreen"
    var isFullscreen: Bool { boolAttribute("AXFullScreen") }

    var isStandard: Bool {
        role == kAXWindowRole && subrole == kAXStandardWindowSubrole
    }

    /// 尺寸不可设置的窗口（固定大小面板等）无法平铺，自动浮动
    var isSizeSettable: Bool {
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    // MARK: 几何

    func frame() -> CGRect? {
        guard let posRef = copyAttribute(kAXPositionAttribute),
              let sizeRef = copyAttribute(kAXSizeAttribute),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// 纯平移专用：单次 RPC，动画热路径
    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return .illegalArgument }
        let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        if err != .success {
            Log.warn("setPosition 失败 #\(windowID) err=\(err.rawValue) 目标=(\(Int(point.x)),\(Int(point.y))) pid=\(pid)")
        }
        return err
    }

    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return .illegalArgument }
        let err = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        if err != .success {
            Log.warn("setSize 失败 #\(windowID) err=\(err.rawValue) 目标=(\(Int(size.width))x\(Int(size.height))) pid=\(pid)")
        }
        return err
    }

    /// 先设尺寸再设位置再补一次尺寸：跨越屏幕边缘移动时 macOS 会钳制尺寸，
    /// 两段式写入是社区验证过的稳妥顺序（Amethyst/yabai 同款）。
    func setFrame(_ rect: CGRect) {
        let e1 = setSize(rect.size)
        let e2 = setPosition(rect.origin)
        let e3 = setSize(rect.size)
        if e1 != .success || e2 != .success || e3 != .success {
            Log.warn("setFrame 失败 #\(windowID) errs=(\(e1.rawValue),\(e2.rawValue),\(e3.rawValue)) pid=\(pid)")
        }
    }

    // MARK: 操作

    /// 置前：AXRaise + 标记主窗口
    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// 点击关闭按钮（等价于用户点红点，让 App 走正常关闭流程）
    func close() {
        guard let buttonRef = copyAttribute(kAXCloseButtonAttribute),
              CFGetTypeID(buttonRef) == AXUIElementGetTypeID()
        else { return }
        AXUIElementPerformAction(buttonRef as! AXUIElement, kAXPressAction as CFString)
    }
}

// MARK: - AXApplication

/// 单个 App 的 AX 句柄 + 事件观察者。
final class AXApplication {
    let pid: pid_t
    let bundleID: String?
    let element: AXUIElement
    private var observer: AXObserver?
    /// 已注册 per-window 通知的窗口，避免重复注册
    private var observedWindows: Set<CGWindowID> = []

    /// App 级通知（element 为窗口，refcon 传 0，pid 由 element 反查）
    private static let appNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    /// 窗口级通知（refcon 携带 windowID，destroyed 时元素已失效只能靠它）
    private static let windowNotifications: [String] = [
        kAXUIElementDestroyedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    init(pid: pid_t, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1.0)
    }

    deinit {
        stopObserving()
    }

    // MARK: 枚举

    func windowElements() -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement]
        else { return [] }
        return array
    }

    func focusedWindow() -> AXWindow? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return AXWindow(element: raw as! AXUIElement, pid: pid)
    }

    // MARK: 观察

    func startObserving(callback: AXObserverCallback) -> Bool {
        guard observer == nil else { return true }
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else {
            Log.debug("AXObserverCreate 失败 pid=\(pid) \(bundleID ?? "?")")
            return false
        }
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        for note in Self.appNotifications {
            AXObserverAddNotification(obs, element, note as CFString, nil)
        }
        return true
    }

    func stopObserving() {
        guard let obs = observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = nil
        observedWindows.removeAll()
    }

    /// 为单个窗口注册窗口级通知，refcon 携带 windowID
    func observeWindow(_ window: AXWindow) {
        guard let obs = observer, !observedWindows.contains(window.windowID) else { return }
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(window.windowID))
        for note in Self.windowNotifications {
            AXObserverAddNotification(obs, window.element, note as CFString, refcon)
        }
        observedWindows.insert(window.windowID)
    }

    func forgetWindow(_ windowID: CGWindowID) {
        observedWindows.remove(windowID)
    }
}

// MARK: - 屏幕坐标转换

enum ScreenGeometry {
    /// 主屏 AppKit maxY。AX 的 (0,0) 是这块屏的顶左；外接屏转换必须用它，不能用当前屏高度。
    static var primaryMaxY: CGFloat {
        let mainID = CGMainDisplayID()
        if let screen = NSScreen.screens.first(where: { displayID(of: $0) == mainID }) {
            return screen.frame.maxY
        }
        return NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func axRect(fromAppKit rect: CGRect) -> CGRect {
        CoordinateConvert.ax(fromAppKit: rect, primaryMaxY: primaryMaxY)
    }

    static func appKitRect(fromAX rect: CGRect) -> CGRect {
        CoordinateConvert.appKit(fromAX: rect, primaryMaxY: primaryMaxY)
    }

    static func axPoint(fromAppKit point: CGPoint) -> CGPoint {
        CoordinateConvert.axPoint(fromAppKit: point, primaryMaxY: primaryMaxY)
    }

    static func axVisible(of screen: NSScreen) -> CGRect {
        axRect(fromAppKit: screen.visibleFrame)
    }

    static func axFull(of screen: NSScreen) -> CGRect {
        axRect(fromAppKit: screen.frame)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    static func screen(containingAX rect: CGRect) -> NSScreen? {
        let cocoa = appKitRect(fromAX: rect)
        let center = CGPoint(x: cocoa.midX, y: cocoa.midY)
        if let exact = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return exact
        }
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(cocoa)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return bestArea >= 1 ? best : nil
    }

    /// Quartz 矩形落在哪块屏上：直接比 `CGDisplayBounds`，不经过 AppKit 转换。
    static func screen(containingQuartz rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let exact = NSScreen.screens.first(where: { CGDisplayBounds(displayID(of: $0)).contains(center) }) {
            return exact
        }
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let inter = CGDisplayBounds(displayID(of: screen)).intersection(rect)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return bestArea >= 1 ? best : nil
    }

    static func screen(containingWindowID id: CGWindowID) -> NSScreen? {
        OnScreenWindows.bounds(of: id).flatMap(screen(containingQuartz:))
    }

    static func appKitRect(fromQuartz rect: CGRect, on screen: NSScreen) -> CGRect {
        CoordinateConvert.appKit(
            fromQuartz: rect,
            displayBounds: CGDisplayBounds(displayID(of: screen)),
            screenFrame: screen.frame
        )
    }

    static func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -8, dy: -8).contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return point }
        return CoordinateConvert.quartzPoint(
            fromAppKit: point,
            displayBounds: CGDisplayBounds(displayID(of: screen)),
            screenFrame: screen.frame
        )
    }

    /// 焦点窗所在屏 → 键盘焦点屏 → 主屏。外接显示器工作时必须跟窗口走，不能写死 screens[0]。
    static func activeScreen(preferredAXFrame: CGRect?) -> NSScreen? {
        if let preferredAXFrame, let screen = screen(containingAX: preferredAXFrame) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 窗口与该屏是否有可见交集（含停靠在边缘外、只露纸边的列）
    static func intersects(_ axFrame: CGRect, screen: NSScreen) -> Bool {
        let vis = axFrame.intersection(axFull(of: screen))
        return !vis.isNull && vis.width >= 1 && vis.height >= 1
    }
}

// MARK: - 当前在屏窗口集合

enum OnScreenWindows {
    /// 当前 Space 中可见的普通层级窗口 ID 集合。
    /// 只读取 ID 和 layer，不需要屏幕录制权限。
    static func ids() -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var result: Set<CGWindowID> = []
        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber as String] as? UInt32
            else { continue }
            result.insert(number)
        }
        return result
    }

    /// Quartz 全局顶左坐标，与 AX 同空间，用作焦点框的落位校对。
    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = info.first,
              let dict = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict)
        else { return nil }
        return rect
    }

    /// 最前的普通窗口（跳过本进程的焦点框 overlay）。坐标为 Quartz 顶左。
    static func id(atQuartz point: CGPoint) -> CGWindowID? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for entry in info {
            if let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == selfPID { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber as String] as? UInt32,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.contains(point)
            else { continue }
            return number
        }
        return nil
    }
}
