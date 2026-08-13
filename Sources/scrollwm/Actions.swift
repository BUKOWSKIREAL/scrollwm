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
    case zoomIn = "zoom-in"
    case zoomOut = "zoom-out"
    case toggleFullWidth = "toggle-full-width"
    case centerColumn = "center-column"
    case toggleFloat = "toggle-float"
    case closeWindow = "close-window"
    case retile = "retile"
    /// 伪动作：在配置中把某个默认键位解绑（"alt-q" = "none"）
    case unbind = "none"
}

extension WMAction {
    /// 设置窗口与引导页共用的中文名
    var title: String {
        switch self {
        case .focusLeft: return "焦点左移"
        case .focusRight: return "焦点右移"
        case .moveLeft: return "列左移"
        case .moveRight: return "列右移"
        case .cycleWidth: return "循环宽度预设"
        case .growWidth: return "加宽"
        case .shrinkWidth: return "减窄"
        case .zoomIn: return "放大窗口"
        case .zoomOut: return "缩小窗口"
        case .toggleFullWidth: return "切换全宽"
        case .centerColumn: return "居中所选列"
        case .toggleFloat: return "切换浮动"
        case .closeWindow: return "关闭窗口"
        case .retile: return "重新平铺"
        case .unbind: return "解绑"
        }
    }

    /// 默认键位里绑到本动作的第一个组合键，供引导页展示
    var defaultCombo: String? {
        Config.defaultBindingPairs.first { $0.action == self }?.combo
    }

    /// 引导页优先展示 ⌘ 组合（放大缩小是 ⌘+/-），没有再退回第一个默认键
    var showcaseCombo: String? {
        let pairs = Config.defaultBindingPairs.filter { $0.action == self }
        return pairs.first { $0.combo.hasPrefix("cmd-") }?.combo ?? pairs.first?.combo
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
