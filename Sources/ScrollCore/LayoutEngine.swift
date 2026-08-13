import CoreGraphics

/// 引擎所需的布局参数（由守护进程从配置转换而来）
public struct LayoutSpec: Equatable, Sendable {
    /// 列与列之间的间隙
    public var innerGap: CGFloat
    /// 视口与屏幕可用区之间的外边距（上下左右统一）
    public var outerGap: CGFloat
    /// 屏幕左右两侧停靠"纸边"的可见宽度
    public var screenMargin: CGFloat
    /// 宽度预设分数
    public var widthPresets: [Double]
    /// 新列默认宽度分数
    public var defaultWidth: Double
    /// 列宽分数下限
    public var minFraction: Double

    public init(
        innerGap: CGFloat = 12,
        outerGap: CGFloat = 12,
        screenMargin: CGFloat = 24,
        widthPresets: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0],
        defaultWidth: Double = 0.5,
        minFraction: Double = 0.15
    ) {
        self.innerGap = innerGap
        self.outerGap = outerGap
        self.screenMargin = screenMargin
        self.widthPresets = widthPresets
        self.defaultWidth = defaultWidth
        self.minFraction = minFraction
    }
}

/// 停靠状态：视口外的列被钳制在屏幕边缘（macOS 不允许窗口完全出屏）
public enum ParkSide: Equatable, Sendable {
    case none, left, right
}

public struct WindowPlacement: Equatable, Sendable {
    public let id: WindowID
    /// 顶左原点坐标系（与 AX API 一致）
    public let frame: CGRect
    public let park: ParkSide

    public init(id: WindowID, frame: CGRect, park: ParkSide) {
        self.id = id
        self.frame = frame
        self.park = park
    }
}

/// 纯几何计算，全部无副作用。坐标一律为顶左原点（AX 坐标系）。
public enum LayoutEngine {

    /// 各列像素宽度
    public static func columnWidths(_ strip: Strip, viewportWidth: CGFloat) -> [CGFloat] {
        strip.columns.map { column in
            (viewportWidth * CGFloat(column.fraction)).rounded().clamped(1, viewportWidth)
        }
    }

    /// 各列在纸带坐标系中的 x 起点（前缀和）
    public static func columnOrigins(widths: [CGFloat], gap: CGFloat) -> [CGFloat] {
        var origins: [CGFloat] = []
        var x: CGFloat = 0
        for w in widths {
            origins.append(x)
            x += w + gap
        }
        return origins
    }

    /// 纸带总长
    public static func stripLength(widths: [CGFloat], gap: CGFloat) -> CGFloat {
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
    }

    /// 滚动位置钳制：不许滚出内容范围；内容比视口短时贴左
    public static func clampOffset(_ offset: CGFloat, stripLength: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        let maxOffset = Swift.max(0, stripLength - viewportWidth)
        return offset.clamped(0, maxOffset)
    }

    /// 最小滚动露出焦点列（niri 语义）：
    /// 焦点列已完整可见则不动；否则平移最短距离使其完整进入视口。
    /// 焦点列比视口宽时对齐其左缘。
    public static func revealOffset(_ strip: Strip, viewportWidth: CGFloat, spec: LayoutSpec) -> CGFloat {
        let widths = columnWidths(strip, viewportWidth: viewportWidth)
        let origins = columnOrigins(widths: widths, gap: spec.innerGap)
        let length = stripLength(widths: widths, gap: spec.innerGap)
        guard let fi = strip.focusedIndex else {
            return clampOffset(strip.viewportOffset, stripLength: length, viewportWidth: viewportWidth)
        }
        let colX = origins[fi]
        let colW = widths[fi]
        var offset = strip.viewportOffset
        if colW >= viewportWidth || colX < offset {
            offset = colX
        } else if colX + colW > offset + viewportWidth {
            offset = colX + colW - viewportWidth
        }
        return clampOffset(offset, stripLength: length, viewportWidth: viewportWidth)
    }

    /// 焦点列在视口中居中（niri center-column 语义），仍受内容范围钳制
    public static func centeredOffset(_ strip: Strip, viewportWidth: CGFloat, spec: LayoutSpec) -> CGFloat {
        let widths = columnWidths(strip, viewportWidth: viewportWidth)
        let origins = columnOrigins(widths: widths, gap: spec.innerGap)
        let length = stripLength(widths: widths, gap: spec.innerGap)
        guard let fi = strip.focusedIndex else {
            return clampOffset(strip.viewportOffset, stripLength: length, viewportWidth: viewportWidth)
        }
        let target = origins[fi] - (viewportWidth - widths[fi]) / 2
        return clampOffset(target, stripLength: length, viewportWidth: viewportWidth)
    }

    /// 计算所有列的屏幕帧。
    /// - viewport: 平铺区域（screen 内缩 outerGap 及左右各 screenMargin 后）
    /// - screen: 屏幕可用区（visibleFrame 的顶左坐标版本），用于停靠位置
    public static func computeLayout(
        _ strip: Strip,
        viewport: CGRect,
        screen: CGRect,
        spec: LayoutSpec
    ) -> [WindowPlacement] {
        let widths = columnWidths(strip, viewportWidth: viewport.width)
        let origins = columnOrigins(widths: widths, gap: spec.innerGap)

        var placements: [WindowPlacement] = []
        placements.reserveCapacity(strip.count)

        for (i, column) in strip.columns.enumerated() {
            let w = widths[i]
            let idealX = viewport.minX + (origins[i] - strip.viewportOffset)
            let ideal = CGRect(x: idealX, y: viewport.minY, width: w, height: viewport.height)

            let placement: WindowPlacement
            if ideal.maxX <= viewport.minX + 0.5 {
                // 完全滚出左侧 → 停靠屏幕左缘，露 screenMargin 宽的纸边
                let frame = CGRect(
                    x: screen.minX + spec.screenMargin - w,
                    y: viewport.minY, width: w, height: viewport.height
                )
                placement = WindowPlacement(id: column.id, frame: frame, park: .left)
            } else if ideal.minX >= viewport.maxX - 0.5 {
                // 完全滚出右侧 → 停靠屏幕右缘
                let frame = CGRect(
                    x: screen.maxX - spec.screenMargin,
                    y: viewport.minY, width: w, height: viewport.height
                )
                placement = WindowPlacement(id: column.id, frame: frame, park: .right)
            } else {
                placement = WindowPlacement(id: column.id, frame: ideal, park: .none)
            }
            placements.append(placement)
        }
        return placements
    }

    /// 由屏幕可用区推导平铺视口。
    /// screenMargin 只控制视口外列停靠时露出的纸边，不应成为可见窗口的固定内边距。
    public static func viewport(screen: CGRect, spec: LayoutSpec) -> CGRect {
        screen.insetBy(dx: spec.outerGap, dy: spec.outerGap)
    }
}
