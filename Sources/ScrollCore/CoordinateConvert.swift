import CoreGraphics

/// AppKit（底左原点）与 Quartz/AX（顶左原点）之间的坐标转换。
public enum CoordinateConvert {
    public static func appKit(fromAX rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func ax(fromAppKit rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        appKit(fromAX: rect, primaryMaxY: primaryMaxY)
    }

    /// 把 Quartz 全局矩形（与 `CGDisplayBounds` / `kCGWindowBounds` 同一空间）
    /// 映射到某块屏的 AppKit 全局坐标。用该屏 `frame` 与 `CGDisplayBounds` 的比例
    /// 吸收 points vs pixels，避免外接屏上 overlay 缩成一小块。
    public static func appKit(
        fromQuartz rect: CGRect,
        displayBounds: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        let sx = displayBounds.width == 0 ? 1 : screenFrame.width / displayBounds.width
        let sy = displayBounds.height == 0 ? 1 : screenFrame.height / displayBounds.height
        let localX = (rect.minX - displayBounds.minX) * sx
        let localYFromTop = (rect.minY - displayBounds.minY) * sy
        let width = rect.width * sx
        let height = rect.height * sy
        let localY = screenFrame.height - localYFromTop - height
        return CGRect(
            x: screenFrame.minX + localX,
            y: screenFrame.minY + localY,
            width: width,
            height: height
        )
    }
}
