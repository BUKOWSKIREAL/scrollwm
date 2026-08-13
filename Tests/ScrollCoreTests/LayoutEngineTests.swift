import XCTest
@testable import ScrollCore

final class LayoutEngineTests: XCTestCase {

    // 屏幕可用区 1600x1000（顶左坐标），spec 默认: innerGap 12, outerGap 12, margin 24
    let screen = CGRect(x: 0, y: 38, width: 1600, height: 1000)
    let spec = LayoutSpec()

    var viewport: CGRect { LayoutEngine.viewport(screen: screen, spec: spec) }

    func makeStrip(_ fractions: [Double], focus: Int? = nil) -> Strip {
        var strip = Strip()
        for (i, f) in fractions.enumerated() {
            strip.append(id: WindowID(i + 1), fraction: f)
        }
        if let focus { strip.focus(id: WindowID(focus + 1)) }
        return strip
    }

    // MARK: - 视口推导

    func testViewportInsets() {
        let vp = viewport
        XCTAssertEqual(vp.minX, 12)   // 可见窗口只受 outerGap 影响
        XCTAssertEqual(vp.minY, 50)   // 38 + outerGap 12
        XCTAssertEqual(vp.width, 1600 - 2 * 12)
        XCTAssertEqual(vp.height, 1000 - 2 * 12)
    }

    // MARK: - 宽度与纸带长度

    func testColumnWidthsRounding() {
        let strip = makeStrip([1.0 / 3.0, 0.5])
        let widths = LayoutEngine.columnWidths(strip, viewportWidth: viewport.width)
        XCTAssertEqual(widths[0], (viewport.width / 3).rounded())
        XCTAssertEqual(widths[1], (viewport.width / 2).rounded())
    }

    func testStripLengthIncludesGaps() {
        let widths: [CGFloat] = [100, 200, 300]
        XCTAssertEqual(LayoutEngine.stripLength(widths: widths, gap: 12), 600 + 24)
        XCTAssertEqual(LayoutEngine.stripLength(widths: [], gap: 12), 0)
    }

    // MARK: - 滚动数学

    func testRevealKeepsVisibleColumnStill() {
        var strip = makeStrip([0.5, 0.5], focus: 0)
        strip.viewportOffset = 0
        XCTAssertEqual(LayoutEngine.revealOffset(strip, viewportWidth: viewport.width, spec: spec), 0,
                       "焦点列已可见则视口不动")
    }

    func testRevealScrollsRightMinimally() {
        var strip = makeStrip([0.5, 0.5, 0.5], focus: 2)
        strip.viewportOffset = 0
        let widths = LayoutEngine.columnWidths(strip, viewportWidth: viewport.width)
        let origins = LayoutEngine.columnOrigins(widths: widths, gap: spec.innerGap)
        let expected = origins[2] + widths[2] - viewport.width
        XCTAssertEqual(LayoutEngine.revealOffset(strip, viewportWidth: viewport.width, spec: spec),
                       expected, accuracy: 0.5,
                       "最小滚动：焦点列右缘贴视口右缘")
    }

    func testRevealScrollsLeftToColumnOrigin() {
        var strip = makeStrip([0.5, 0.5, 0.5], focus: 0)
        strip.viewportOffset = 800
        XCTAssertEqual(LayoutEngine.revealOffset(strip, viewportWidth: viewport.width, spec: spec), 0,
                       "向左滚动到列起点")
    }

    func testRevealFullWidthColumnAlignsLeft() {
        var strip = makeStrip([0.5, 1.0], focus: 1)
        strip.viewportOffset = 0
        let widths = LayoutEngine.columnWidths(strip, viewportWidth: viewport.width)
        let origins = LayoutEngine.columnOrigins(widths: widths, gap: spec.innerGap)
        XCTAssertEqual(LayoutEngine.revealOffset(strip, viewportWidth: viewport.width, spec: spec),
                       origins[1], accuracy: 0.5, "全宽列对齐左缘")
    }

    func testClampOffsetShortStrip() {
        XCTAssertEqual(LayoutEngine.clampOffset(500, stripLength: 400, viewportWidth: 1000), 0,
                       "内容比视口短时贴左")
        XCTAssertEqual(LayoutEngine.clampOffset(-50, stripLength: 4000, viewportWidth: 1000), 0)
        XCTAssertEqual(LayoutEngine.clampOffset(99999, stripLength: 4000, viewportWidth: 1000), 3000)
    }

    func testCenteredOffset() {
        var strip = makeStrip([0.5, 0.5, 0.5], focus: 1)
        strip.viewportOffset = 0
        let widths = LayoutEngine.columnWidths(strip, viewportWidth: viewport.width)
        let origins = LayoutEngine.columnOrigins(widths: widths, gap: spec.innerGap)
        let ideal = origins[1] - (viewport.width - widths[1]) / 2
        let length = LayoutEngine.stripLength(widths: widths, gap: spec.innerGap)
        let expected = LayoutEngine.clampOffset(ideal, stripLength: length, viewportWidth: viewport.width)
        XCTAssertEqual(LayoutEngine.centeredOffset(strip, viewportWidth: viewport.width, spec: spec),
                       expected, accuracy: 0.5)
    }

    // MARK: - 布局与停靠

    func testLayoutVisibleColumns() {
        var strip = makeStrip([0.5, 0.5], focus: 0)
        strip.viewportOffset = 0
        let placements = LayoutEngine.computeLayout(strip, viewport: viewport, screen: screen, spec: spec)
        XCTAssertEqual(placements.count, 2)
        XCTAssertEqual(placements[0].park, ParkSide.none)
        XCTAssertEqual(placements[0].frame.minX, viewport.minX)
        XCTAssertEqual(placements[0].frame.minY, viewport.minY)
        XCTAssertEqual(placements[0].frame.height, viewport.height)
        // 第二列在第一列右侧 gap 处，部分可见（0.5+0.5+gap > 1 视口）
        XCTAssertEqual(placements[1].frame.minX,
                       viewport.minX + placements[0].frame.width + spec.innerGap)
    }

    func testLayoutParksLeftColumn() {
        var strip = makeStrip([0.5, 0.5, 0.5], focus: 2)
        strip.viewportOffset = LayoutEngine.revealOffset(strip, viewportWidth: viewport.width, spec: spec)
        let placements = LayoutEngine.computeLayout(strip, viewport: viewport, screen: screen, spec: spec)
        XCTAssertEqual(placements[0].park, ParkSide.left, "完全滚出左侧的列停靠左缘")
        XCTAssertEqual(placements[0].frame.maxX, screen.minX + spec.screenMargin,
                       "左停靠列右缘露出 screenMargin 宽")
        XCTAssertEqual(placements[2].park, ParkSide.none)
        XCTAssertEqual(placements[2].frame.maxX, viewport.maxX, accuracy: 0.5)
    }

    func testLayoutParksRightColumn() {
        var strip = makeStrip([1.0, 0.5], focus: 0)
        strip.viewportOffset = 0
        let placements = LayoutEngine.computeLayout(strip, viewport: viewport, screen: screen, spec: spec)
        XCTAssertEqual(placements[0].park, ParkSide.none)
        XCTAssertEqual(placements[0].frame.width, viewport.width)
        XCTAssertEqual(placements[1].park, ParkSide.right, "全宽列占满时第二列停靠右缘")
        XCTAssertEqual(placements[1].frame.minX, screen.maxX - spec.screenMargin)
    }

    func testLayoutEmptyStrip() {
        let strip = Strip()
        XCTAssertTrue(LayoutEngine.computeLayout(strip, viewport: viewport, screen: screen, spec: spec).isEmpty)
    }

    // MARK: - 组合场景：模拟完整交互序列

    func testScenarioInsertScrollFocusBack() {
        var strip = Strip()
        // 依次打开 4 个窗口
        for id: WindowID in [1, 2, 3, 4] {
            strip.insertAdjacentToFocused(id: id, fraction: 0.5)
            strip.viewportOffset = LayoutEngine.revealOffset(strip, viewportWidth: viewport.width, spec: spec)
        }
        XCTAssertEqual(strip.windowIDs, [1, 2, 3, 4])
        XCTAssertEqual(strip.focusedID, 4)

        // 焦点回到最左：视口应滚回 0
        strip.focus(id: 1)
        strip.viewportOffset = LayoutEngine.revealOffset(strip, viewportWidth: viewport.width, spec: spec)
        XCTAssertEqual(strip.viewportOffset, 0)

        let placements = LayoutEngine.computeLayout(strip, viewport: viewport, screen: screen, spec: spec)
        XCTAssertEqual(placements[0].park, ParkSide.none)
        XCTAssertEqual(placements[3].park, ParkSide.right)
    }
}
