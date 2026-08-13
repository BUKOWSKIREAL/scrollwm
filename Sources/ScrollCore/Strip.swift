import CoreGraphics

public typealias WindowID = UInt32

public enum HDirection: Sendable {
    case left, right
}

/// 纸带上的一列。MVP 中一列恰好承载一个窗口。
public struct Column: Equatable, Sendable {
    public let id: WindowID
    /// 列宽占视口宽度的分数，(0, 1]
    public var fraction: Double
    /// 进入全宽前保存的原分数，用于切回
    public var savedFraction: Double?

    public init(id: WindowID, fraction: Double) {
        self.id = id
        self.fraction = fraction
        self.savedFraction = nil
    }
}

/// 无限横向纸带模型：有序列 + 焦点 + 视口滚动位置。
/// 纯值类型，所有几何计算见 LayoutEngine。
public struct Strip: Equatable, Sendable {
    public private(set) var columns: [Column] = []
    public private(set) var focusedID: WindowID?
    /// 视口左缘在纸带坐标系中的 x 偏移
    public var viewportOffset: CGFloat = 0

    public init() {}

    // MARK: - 查询

    public var isEmpty: Bool { columns.isEmpty }
    public var count: Int { columns.count }

    public func index(of id: WindowID) -> Int? {
        columns.firstIndex { $0.id == id }
    }

    public func contains(_ id: WindowID) -> Bool {
        index(of: id) != nil
    }

    public var focusedIndex: Int? {
        focusedID.flatMap { index(of: $0) }
    }

    public var focusedColumn: Column? {
        focusedIndex.map { columns[$0] }
    }

    public var windowIDs: [WindowID] { columns.map(\.id) }

    // MARK: - 增删

    /// 在焦点列右侧插入并聚焦（niri 语义：新窗口开在焦点右边）
    public mutating func insertAdjacentToFocused(
        id: WindowID, fraction: Double, savedFraction: Double? = nil
    ) {
        guard !contains(id) else { return }
        var column = Column(id: id, fraction: fraction)
        column.savedFraction = savedFraction
        if let fi = focusedIndex {
            columns.insert(column, at: fi + 1)
        } else {
            columns.append(column)
        }
        focusedID = id
    }

    /// 批量收编时追加到尾部，不改变焦点
    public mutating func append(id: WindowID, fraction: Double, savedFraction: Double? = nil) {
        guard !contains(id) else { return }
        var column = Column(id: id, fraction: fraction)
        column.savedFraction = savedFraction
        columns.append(column)
        if focusedID == nil { focusedID = id }
    }

    /// 移除列。焦点规则：被移除列若是焦点，焦点给右邻（原索引位置），无右邻给左邻。
    @discardableResult
    public mutating func remove(id: WindowID) -> Bool {
        guard let idx = index(of: id) else { return false }
        let wasFocused = (focusedID == id)
        columns.remove(at: idx)
        if wasFocused {
            if columns.isEmpty {
                focusedID = nil
            } else {
                focusedID = columns[min(idx, columns.count - 1)].id
            }
        }
        return true
    }

    // MARK: - 焦点

    @discardableResult
    public mutating func focus(id: WindowID) -> Bool {
        guard contains(id) else { return false }
        focusedID = id
        return true
    }

    /// 焦点移到相邻列，返回新焦点 id；已到边缘返回 nil
    @discardableResult
    public mutating func focusAdjacent(_ dir: HDirection) -> WindowID? {
        guard let fi = focusedIndex else {
            // 无焦点时聚焦端点列
            guard let column = (dir == .left ? columns.last : columns.first) else { return nil }
            focusedID = column.id
            return column.id
        }
        let target = dir == .left ? fi - 1 : fi + 1
        guard columns.indices.contains(target) else { return nil }
        focusedID = columns[target].id
        return focusedID
    }

    /// 焦点列与相邻列换位，返回是否发生移动
    @discardableResult
    public mutating func moveFocused(_ dir: HDirection) -> Bool {
        guard let fi = focusedIndex else { return false }
        let target = dir == .left ? fi - 1 : fi + 1
        guard columns.indices.contains(target) else { return false }
        columns.swapAt(fi, target)
        return true
    }

    /// 把一列挪到目标下标（niri Mod+拖动落点）。`toIndex` 是挪完后的最终位置。
    @discardableResult
    public mutating func move(id: WindowID, toIndex: Int) -> Bool {
        guard let from = index(of: id), !columns.isEmpty else { return false }
        let dest = min(max(toIndex, 0), columns.count - 1)
        guard dest != from else { return false }
        let column = columns.remove(at: from)
        columns.insert(column, at: min(dest, columns.count))
        focusedID = id
        return true
    }

    // MARK: - 宽度

    public mutating func setFraction(id: WindowID, fraction: Double, minFraction: Double) {
        guard let idx = index(of: id) else { return }
        columns[idx].fraction = fraction.clamped(minFraction, 1.0)
        columns[idx].savedFraction = nil
    }

    public mutating func adjustFocusedWidth(by delta: Double, minFraction: Double) {
        guard let fi = focusedIndex else { return }
        columns[fi].fraction = (columns[fi].fraction + delta).clamped(minFraction, 1.0)
        columns[fi].savedFraction = nil
    }

    /// 循环切换到下一个更宽的预设，超过最宽则回到最窄（niri Mod+R 语义）
    public mutating func cycleFocusedWidth(presets: [Double], minFraction: Double) {
        guard let fi = focusedIndex, !presets.isEmpty else { return }
        let sorted = presets.map { $0.clamped(minFraction, 1.0) }.sorted()
        let current = columns[fi].fraction
        let next = sorted.first { $0 > current + 0.01 } ?? sorted[0]
        columns[fi].fraction = next
        columns[fi].savedFraction = nil
    }

    /// 进入全宽并记住原宽。已是全宽则不变（保留已有 savedFraction）。
    public mutating func enterFullWidth(id: WindowID) {
        guard let idx = index(of: id) else { return }
        guard columns[idx].fraction < 0.999 else { return }
        columns[idx].savedFraction = columns[idx].fraction
        columns[idx].fraction = 1.0
    }

    /// 全宽开关：进入时记住原宽，退出时恢复；无记录时回退到 fallback
    public mutating func toggleFocusedFullWidth(fallback: Double) {
        guard let fi = focusedIndex else { return }
        if columns[fi].fraction >= 0.999 {
            columns[fi].fraction = columns[fi].savedFraction ?? fallback
            columns[fi].savedFraction = nil
        } else {
            enterFullWidth(id: columns[fi].id)
        }
    }
}

extension Double {
    public func clamped(_ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(self, lo), hi)
    }
}

extension CGFloat {
    public func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lo), hi)
    }
}
