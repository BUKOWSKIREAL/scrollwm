import ApplicationServices

/// 唯一使用的私有函数（与 AeroSpace 相同）：
/// 从 AXUIElement 解析出 CGWindowID。除此之外全部使用公开 Accessibility API。
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
