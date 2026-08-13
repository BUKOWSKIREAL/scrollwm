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
