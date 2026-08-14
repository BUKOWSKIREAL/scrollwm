import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Carbon 全局热键管理。
/// 选 RegisterEventHotKey 而非 CGEventTap：不拦截事件流、不吞键、
/// 除辅助功能外无需额外权限，系统级去重也更稳。
final class HotkeyManager {
    static private(set) var shared: HotkeyManager?

    private var hotkeyRefs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: WMAction] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private let dispatch: (WMAction) -> Void

    // 长按重复：可重复动作（加宽/减窄）按住时自动连发，模拟键盘 repeat。
    private static let repeatableActions: Set<WMAction> = [.growWidth, .shrinkWidth]
    private var keyInfoByID: [UInt32: UInt32] = [:] // id -> keyCode
    private var repeatTimer: Timer?
    private var repeatAction: WMAction?
    private var repeatKeyCode: UInt32?

    private static let signature: OSType = {
        // "SCRL" 四字符码
        "SCRL".utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()

    init(dispatch: @escaping (WMAction) -> Void) {
        self.dispatch = dispatch
        HotkeyManager.shared = self
    }

    // MARK: - 注册

    /// 按配置重新注册全部键位，返回警告列表（非法键位不阻断其余注册）
    @discardableResult
    func register(bindings: [String: WMAction]) -> [String] {
        unregisterAll()
        installHandlerIfNeeded()

        var warnings: [String] = []
        for (combo, action) in bindings.sorted(by: { $0.key < $1.key }) {
            guard action != .unbind else { continue }
            guard let (keyCode, modifiers) = Self.parse(combo: combo) else {
                warnings.append("无法解析键位 \"\(combo)\"，跳过")
                continue
            }
            var ref: EventHotKeyRef?
            let hotkeyID = EventHotKeyID(signature: Self.signature, id: nextID)
            let status = RegisterEventHotKey(
                keyCode, modifiers, hotkeyID, GetEventDispatcherTarget(), 0, &ref
            )
            guard status == noErr, let ref else {
                warnings.append("注册 \"\(combo)\" 失败（可能与系统或其他 App 冲突）")
                continue
            }
            hotkeyRefs.append(ref)
            actionsByID[nextID] = action
            keyInfoByID[nextID] = keyCode
            nextID += 1
        }
        Log.info("热键注册完成：\(actionsByID.count) 个")
        return warnings
    }

    func unregisterAll() {
        for ref in hotkeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()
        actionsByID.removeAll()
        keyInfoByID.removeAll()
        stopRepeating()
    }

    fileprivate func handle(id: UInt32) {
        guard let action = actionsByID[id] else { return }
        Log.debug("热键触发：\(action.rawValue)")
        dispatch(action)
        if Self.repeatableActions.contains(action), let code = keyInfoByID[id] {
            startRepeating(action: action, keyCode: code)
        } else {
            stopRepeating()
        }
    }

    // MARK: - 长按重复

    private func startRepeating(action: WMAction, keyCode: UInt32) {
        stopRepeating()
        repeatAction = action
        repeatKeyCode = keyCode
        let t = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            self?.repeatTick()
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func repeatTick() {
        guard let action = repeatAction, let code = repeatKeyCode else { return }
        guard CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) else {
            stopRepeating()
            return
        }
        dispatch(action)
        let t = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: false) { [weak self] _ in
            self?.repeatTick()
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatAction = nil
        repeatKeyCode = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C 回调，不能捕获上下文，经单例转发
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID
            )
            if status == noErr {
                HotkeyManager.shared?.handle(id: hotkeyID.id)
            }
            return noErr
        }, 1, &eventType, nil, nil)
        handlerInstalled = true
    }

    // MARK: - 键位解析

    /// "alt-shift-h" → (keyCode, carbonModifiers)
    static func parse(combo: String) -> (UInt32, UInt32)? {
        let tokens = combo.lowercased().split(separator: "-").map(String.init)
        guard tokens.count >= 2 else { return nil }

        var modifiers: UInt32 = 0
        for token in tokens.dropLast() {
            switch token {
            case "alt", "opt", "option": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            default: return nil
            }
        }
        guard modifiers != 0, let key = tokens.last, let code = keyCodes[key] else { return nil }
        return (code, modifiers)
    }

    /// ANSI 布局虚拟键码表
    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "equal": 24, "plus": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29,
        "rightbracket": 30, "o": 31, "u": 32, "leftbracket": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "quote": 39, "k": 40, "semicolon": 41,
        "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47,
        "tab": 48, "space": 49, "grave": 50, "backtick": 50,
        "escape": 53, "esc": 53,
        "kpplus": 69, "kpminus": 78,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
