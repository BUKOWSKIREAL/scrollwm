import XCTest
@testable import ScrollCore

final class StripTests: XCTestCase {

    func makeStrip(_ ids: [WindowID], focus: WindowID? = nil) -> Strip {
        var strip = Strip()
        for id in ids { strip.append(id: id, fraction: 0.5) }
        if let focus { strip.focus(id: focus) }
        return strip
    }

    // MARK: - 插入

    func testInsertAdjacentToFocused() {
        var strip = makeStrip([1, 2, 3], focus: 2)
        strip.insertAdjacentToFocused(id: 9, fraction: 0.5)
        XCTAssertEqual(strip.windowIDs, [1, 2, 9, 3], "新列应插在焦点列右侧")
        XCTAssertEqual(strip.focusedID, 9, "新列应获得焦点")
    }

    func testInsertAdjacentToFocusedOnLeft() {
        var strip = makeStrip([1, 2, 3], focus: 2)
        strip.insertAdjacentToFocused(id: 9, fraction: 0.5, side: .left)
        XCTAssertEqual(strip.windowIDs, [1, 9, 2, 3], "新列应插在焦点列左侧")
        XCTAssertEqual(strip.focusedID, 9, "新列应获得焦点")
    }

    func testInsertIntoEmptyStrip() {
        var strip = Strip()
        strip.insertAdjacentToFocused(id: 7, fraction: 0.5)
        XCTAssertEqual(strip.windowIDs, [7])
        XCTAssertEqual(strip.focusedID, 7)
    }

    func testInsertDuplicateIsNoop() {
        var strip = makeStrip([1, 2], focus: 1)
        strip.insertAdjacentToFocused(id: 2, fraction: 0.5)
        XCTAssertEqual(strip.windowIDs, [1, 2])
    }

    func testInsertAtIndexRestoresOrder() {
        var strip = makeStrip([1, 2, 3], focus: 2)
        strip.insert(id: 9, at: 1, fraction: 0.4, savedFraction: 0.33)
        XCTAssertEqual(strip.windowIDs, [1, 9, 2, 3], "应按指定位置插入")
        XCTAssertEqual(strip.focusedID, 9)
        let column = strip.columns[1]
        XCTAssertEqual(column.fraction, 0.4)
        XCTAssertEqual(column.savedFraction, 0.33)
    }

    func testInsertAtIndexClamps() {
        var strip = makeStrip([1, 2])
        strip.insert(id: 9, at: 99, fraction: 0.5)
        XCTAssertEqual(strip.windowIDs, [1, 2, 9], "越界下标应钳到末尾")
        strip.insert(id: 8, at: -5, fraction: 0.5)
        XCTAssertEqual(strip.windowIDs, [8, 1, 2, 9], "负下标应钳到开头")
    }

    func testInsertAtIndexDuplicateIsNoop() {
        var strip = makeStrip([1, 2], focus: 1)
        strip.insert(id: 2, at: 0, fraction: 0.5)
        XCTAssertEqual(strip.windowIDs, [1, 2])
    }

    func testAppendDoesNotStealFocus() {
        var strip = makeStrip([1], focus: 1)
        strip.append(id: 2, fraction: 0.5)
        XCTAssertEqual(strip.focusedID, 1)
    }

    func testAppendToEmptySetsFocus() {
        var strip = Strip()
        strip.append(id: 4, fraction: 0.5)
        XCTAssertEqual(strip.focusedID, 4)
    }

    // MARK: - 移除与焦点转移

    func testRemoveFocusedGivesFocusToRightNeighbor() {
        var strip = makeStrip([1, 2, 3], focus: 2)
        strip.remove(id: 2)
        XCTAssertEqual(strip.windowIDs, [1, 3])
        XCTAssertEqual(strip.focusedID, 3, "右邻接管焦点")
    }

    func testRemoveFocusedAtTailGivesFocusToLeftNeighbor() {
        var strip = makeStrip([1, 2, 3], focus: 3)
        strip.remove(id: 3)
        XCTAssertEqual(strip.focusedID, 2, "无右邻时左邻接管")
    }

    func testRemoveUnfocusedKeepsFocus() {
        var strip = makeStrip([1, 2, 3], focus: 3)
        strip.remove(id: 1)
        XCTAssertEqual(strip.focusedID, 3)
    }

    func testRemoveLastClearsFocus() {
        var strip = makeStrip([1], focus: 1)
        strip.remove(id: 1)
        XCTAssertNil(strip.focusedID)
        XCTAssertTrue(strip.isEmpty)
    }

    func testRemoveMissingReturnsFalse() {
        var strip = makeStrip([1])
        XCTAssertFalse(strip.remove(id: 99))
    }

    // MARK: - 焦点导航

    func testFocusAdjacent() {
        var strip = makeStrip([1, 2, 3], focus: 2)
        XCTAssertEqual(strip.focusAdjacent(.left), 1)
        XCTAssertEqual(strip.focusAdjacent(.left), nil, "到达左端后不再移动")
        XCTAssertEqual(strip.focusedID, 1)
        XCTAssertEqual(strip.focusAdjacent(.right), 2)
        XCTAssertEqual(strip.focusAdjacent(.right), 3)
        XCTAssertNil(strip.focusAdjacent(.right))
    }

    func testFocusAdjacentWithNoFocusPicksEndpoint() {
        var strip = Strip()
        strip.append(id: 1, fraction: 0.5)
        strip.append(id: 2, fraction: 0.5)
        // append 会给第一个窗口焦点，手工清空模拟异常态
        strip.remove(id: 1)
        strip.remove(id: 2)
        strip.append(id: 3, fraction: 0.5)
        XCTAssertEqual(strip.focusedID, 3)
    }

    // MARK: - 挪列

    func testMoveFocused() {
        var strip = makeStrip([1, 2, 3], focus: 2)
        XCTAssertTrue(strip.moveFocused(.left))
        XCTAssertEqual(strip.windowIDs, [2, 1, 3])
        XCTAssertEqual(strip.focusedID, 2, "焦点跟随被挪的列")
        XCTAssertFalse(strip.moveFocused(.left), "已在最左不能再挪")
        XCTAssertTrue(strip.moveFocused(.right))
        XCTAssertEqual(strip.windowIDs, [1, 2, 3])
    }

    func testMoveToIndex() {
        var strip = makeStrip([1, 2, 3, 4], focus: 3)
        XCTAssertTrue(strip.move(id: 3, toIndex: 0))
        XCTAssertEqual(strip.windowIDs, [3, 1, 2, 4])
        XCTAssertEqual(strip.focusedID, 3)
        XCTAssertTrue(strip.move(id: 3, toIndex: 3))
        XCTAssertEqual(strip.windowIDs, [1, 2, 4, 3])
        XCTAssertFalse(strip.move(id: 3, toIndex: 3), "已在目标下标则不动")
        XCTAssertFalse(strip.move(id: 99, toIndex: 0))
    }

    // MARK: - 宽度

    func testCycleWidthAdvancesToNextPreset() {
        var strip = makeStrip([1], focus: 1)  // fraction 0.5
        let presets = [1.0 / 3.0, 0.5, 2.0 / 3.0]
        strip.cycleFocusedWidth(presets: presets, minFraction: 0.15)
        XCTAssertEqual(strip.focusedColumn!.fraction, 2.0 / 3.0, accuracy: 0.001)
        strip.cycleFocusedWidth(presets: presets, minFraction: 0.15)
        XCTAssertEqual(strip.focusedColumn!.fraction, 1.0 / 3.0, accuracy: 0.001, "超过最宽回绕到最窄")
    }

    func testAdjustWidthClamps() {
        var strip = makeStrip([1], focus: 1)
        strip.adjustFocusedWidth(by: 10, minFraction: 0.15)
        XCTAssertEqual(strip.focusedColumn!.fraction, 1.0)
        strip.adjustFocusedWidth(by: -10, minFraction: 0.15)
        XCTAssertEqual(strip.focusedColumn!.fraction, 0.15)
    }

    func testEnterFullWidthSavesAndIsIdempotent() {
        var strip = makeStrip([1, 2], focus: 2)
        strip.enterFullWidth(id: 1)
        XCTAssertEqual(strip.columns[0].fraction, 1.0)
        XCTAssertEqual(strip.columns[0].savedFraction, 0.5)
        XCTAssertEqual(strip.focusedID, 2, "enterFullWidth 不应改焦点")
        strip.enterFullWidth(id: 1)
        XCTAssertEqual(strip.columns[0].savedFraction, 0.5, "已全宽时不要覆盖 savedFraction")
    }

    func testToggleFullWidthRestoresSavedFraction() {
        var strip = makeStrip([1], focus: 1)
        strip.adjustFocusedWidth(by: 0.1, minFraction: 0.15)  // 0.6
        strip.toggleFocusedFullWidth(fallback: 0.5)
        XCTAssertEqual(strip.focusedColumn!.fraction, 1.0)
        strip.toggleFocusedFullWidth(fallback: 0.5)
        XCTAssertEqual(strip.focusedColumn!.fraction, 0.6, accuracy: 0.001, "恢复进入全宽前的宽度")
    }

    func testToggleFullWidthFallsBackWithoutSaved() {
        var strip = makeStrip([1], focus: 1)
        strip.setFraction(id: 1, fraction: 1.0, minFraction: 0.15)
        strip.toggleFocusedFullWidth(fallback: 0.5)
        XCTAssertEqual(strip.focusedColumn!.fraction, 0.5, "无保存宽度时退回默认")
    }

    func testExternalSetFractionClearsSaved() {
        var strip = makeStrip([1], focus: 1)
        strip.toggleFocusedFullWidth(fallback: 0.5)  // saved = 0.5, fraction = 1.0
        strip.setFraction(id: 1, fraction: 0.4, minFraction: 0.15)
        strip.toggleFocusedFullWidth(fallback: 0.5)
        XCTAssertEqual(strip.focusedColumn!.fraction, 1.0)
        strip.toggleFocusedFullWidth(fallback: 0.5)
        XCTAssertEqual(strip.focusedColumn!.fraction, 0.4, accuracy: 0.001)
    }
}
