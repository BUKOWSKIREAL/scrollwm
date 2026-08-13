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

    public static func axPoint(fromAppKit point: CGPoint, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }

    /// 把与 `CGDisplayBounds` / `kCGWindowBounds` 同一空间的矩形映射到某块屏的 AppKit 坐标。
    /// 不要拿 Accessibility / 布局点坐标走这条路径：Retina 上 `CGDisplayBounds` 可能是像素，
    /// 再乘一次缩放会让 overlay 错位。AX 矩形用 `appKit(fromAX:primaryMaxY:)`。
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

    public static func quartzPoint(
        fromAppKit point: CGPoint,
        displayBounds: CGRect,
        screenFrame: CGRect
    ) -> CGPoint {
        let sx = screenFrame.width == 0 ? 1 : displayBounds.width / screenFrame.width
        let sy = screenFrame.height == 0 ? 1 : displayBounds.height / screenFrame.height
        let localX = (point.x - screenFrame.minX) * sx
        let localYFromBottom = (point.y - screenFrame.minY) * sy
        return CGPoint(
            x: displayBounds.minX + localX,
            y: displayBounds.minY + displayBounds.height - localYFromBottom
        )
    }
}
