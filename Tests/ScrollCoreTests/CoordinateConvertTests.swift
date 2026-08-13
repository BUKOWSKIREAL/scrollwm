import XCTest
@testable import ScrollCore

final class CoordinateConvertTests: XCTestCase {
    func testPrimaryScreenRoundTrip() {
        let primaryMaxY: CGFloat = 900
        let ax = CGRect(x: 12, y: 38, width: 800, height: 850)
        let cocoa = CoordinateConvert.appKit(fromAX: ax, primaryMaxY: primaryMaxY)
        XCTAssertEqual(cocoa.origin.x, 12)
        XCTAssertEqual(cocoa.origin.y, 900 - 888)
        XCTAssertEqual(CoordinateConvert.ax(fromAppKit: cocoa, primaryMaxY: primaryMaxY), ax)
    }

    /// 外接屏在主屏右侧、底对齐：外接屏比主屏更高，顶超出主屏。
    func testExternalRightBottomAligned() {
        let primaryMaxY: CGFloat = 900
        // AppKit: 外接屏 (1440, 0, 1920, 1080)
        let windowAppKit = CGRect(x: 1440, y: 80, width: 960, height: 1000)
        let ax = CoordinateConvert.ax(fromAppKit: windowAppKit, primaryMaxY: primaryMaxY)
        XCTAssertEqual(ax.minX, 1440)
        XCTAssertEqual(ax.minY, 900 - 1080) // -180
        XCTAssertEqual(ax.height, 1000)
        let back = CoordinateConvert.appKit(fromAX: ax, primaryMaxY: primaryMaxY)
        XCTAssertEqual(back, windowAppKit)
    }

    func testQuartzToAppKitPrimary1x() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let quartz = CGRect(x: 100, y: 50, width: 400, height: 300)
        let cocoa = CoordinateConvert.appKit(fromQuartz: quartz, displayBounds: display, screenFrame: screen)
        XCTAssertEqual(cocoa, CGRect(x: 100, y: 730, width: 400, height: 300))
    }

    func testQuartzToAppKitExternalRight() {
        let display = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let quartz = CGRect(x: 1440, y: -130, width: 960, height: 1000)
        let cocoa = CoordinateConvert.appKit(fromQuartz: quartz, displayBounds: display, screenFrame: screen)
        XCTAssertEqual(cocoa.origin.x, 1440, accuracy: 0.01)
        XCTAssertEqual(cocoa.origin.y, 30, accuracy: 0.01)
        XCTAssertEqual(cocoa.width, 960, accuracy: 0.01)
        XCTAssertEqual(cocoa.height, 1000, accuracy: 0.01)
    }

    func testQuartzToAppKitRetina2x() {
        let display = CGRect(x: 0, y: 0, width: 3024, height: 1964)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let quartz = CGRect(x: 200, y: 80, width: 800, height: 600)
        let cocoa = CoordinateConvert.appKit(fromQuartz: quartz, displayBounds: display, screenFrame: screen)
        XCTAssertEqual(cocoa.origin.x, 100, accuracy: 0.01)
        XCTAssertEqual(cocoa.width, 400, accuracy: 0.01)
        XCTAssertEqual(cocoa.origin.y, 982 - 40 - 300, accuracy: 0.01)
    }

    func testAXPointFromAppKitOnExternal() {
        let primaryMaxY: CGFloat = 900
        let cocoa = CGPoint(x: 1600, y: 80)
        let ax = CoordinateConvert.axPoint(fromAppKit: cocoa, primaryMaxY: primaryMaxY)
        XCTAssertEqual(ax.x, 1600)
        XCTAssertEqual(ax.y, 820)
    }

    func testQuartzPointRoundTripOnPrimary() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen = display
        let cocoa = CGPoint(x: 100, y: 730)
        let quartz = CoordinateConvert.quartzPoint(fromAppKit: cocoa, displayBounds: display, screenFrame: screen)
        XCTAssertEqual(quartz.x, 100, accuracy: 0.01)
        XCTAssertEqual(quartz.y, 350, accuracy: 0.01)
    }
}
