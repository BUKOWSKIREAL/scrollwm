import Foundation

/// 可绑定到热键的全部动作，rawValue 即配置文件中的动作名
enum WMAction: String, CaseIterable {
    case focusLeft = "focus-left"
    case focusRight = "focus-right"
    case moveLeft = "move-left"
    case moveRight = "move-right"
    case cycleWidth = "cycle-width"
    case growWidth = "grow-width"
    case shrinkWidth = "shrink-width"
    case toggleFullWidth = "toggle-full-width"
    case centerColumn = "center-column"
    case toggleFloat = "toggle-float"
    case closeWindow = "close-window"
    case retile = "retile"
    /// 伪动作：在配置中把某个默认键位解绑（"alt-q" = "none"）
    case unbind = "none"
}

extension WMAction {
    /// 设置窗口与引导页共用的动作名
    var title: String {
        L10n.text("action.\(rawValue)")
    }

    /// 默认键位里绑到本动作的第一个组合键，供设置页与引导页展示
    var defaultCombo: String? {
        Config.defaultBindingPairs.first { $0.action == self }?.combo
    }
}

/// 把配置里的键位串（"alt-shift-h"）渲染成键帽符号（"⌥⇧H"）
enum KeyComboText {
    static func display(_ combo: String) -> String {
        combo.split(separator: "-").map { token -> String in
            switch token {
            case "alt", "opt", "option": return "⌥"
            case "cmd", "command": return "⌘"
            case "ctrl", "control": return "⌃"
            case "shift": return "⇧"
            case "left": return "←"
            case "right": return "→"
            case "up": return "↑"
            case "down": return "↓"
            case "minus": return "－"
            case "equal", "plus": return "＋"
            case "kpplus": return "Num+"
            case "kpminus": return "Num-"
            case "space": return "Space"
            case "tab": return "Tab"
            case "return", "enter": return "Return"
            case "escape", "esc": return "Esc"
            default: return token.uppercased()
            }
        }.joined()
    }
}
