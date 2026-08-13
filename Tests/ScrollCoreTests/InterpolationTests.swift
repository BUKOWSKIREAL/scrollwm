import XCTest
@testable import ScrollCore

final class InterpolationTests: XCTestCase {

    func testEaseOutCubicEndpoints() {
        XCTAssertEqual(Interpolation.easeOutCubic(0), 0, accuracy: 1e-9)
        XCTAssertEqual(Interpolation.easeOutCubic(1), 1, accuracy: 1e-9)
        XCTAssertEqual(Interpolation.easeOutCubic(-0.5), 0, accuracy: 1e-9, "越界钳制")
        XCTAssertEqual(Interpolation.easeOutCubic(1.5), 1, accuracy: 1e-9, "越界钳制")
    }

    func testEaseOutCubicIsMonotonicAndFrontLoaded() {
        var previous = -1.0
        for i in 0...100 {
            let value = Interpolation.easeOutCubic(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(value, previous, "必须单调递增")
            previous = value
        }
        XCTAssertGreaterThan(Interpolation.easeOutCubic(0.5), 0.5, "缓出曲线前半段应超过线性")
    }

    func testEaseOutQuintIsMoreFrontLoadedThanCubic() {
        XCTAssertEqual(Interpolation.easeOutQuint(0), 0, accuracy: 1e-9)
        XCTAssertEqual(Interpolation.easeOutQuint(1), 1, accuracy: 1e-9)
        // 同一 t 下 quint 应比 cubic 更靠前（更“冲”）
        XCTAssertGreaterThan(
            Interpolation.easeOutQuint(0.4),
            Interpolation.easeOutCubic(0.4)
        )
        var previous = -1.0
        for i in 0...100 {
            let value = Interpolation.easeOutQuint(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testEaseOutExpoEndpointsAndMonotonic() {
        XCTAssertEqual(Interpolation.easeOutExpo(0), 0, accuracy: 1e-9)
        XCTAssertEqual(Interpolation.easeOutExpo(1), 1, accuracy: 1e-9)
        var previous = -1.0
        for i in 0...100 {
            let value = Interpolation.easeOutExpo(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testSmoothstepEndpointsAndDerivativesNearEnds() {
        XCTAssertEqual(Interpolation.smoothstep(0), 0, accuracy: 1e-9)
        XCTAssertEqual(Interpolation.smoothstep(1), 1, accuracy: 1e-9)
        XCTAssertEqual(Interpolation.smoothstep(0.5), 0.5, accuracy: 1e-9)
        // 端点附近导数接近 0：小步长增量应小于线性
        let d0 = Interpolation.smoothstep(0.01) - Interpolation.smoothstep(0)
        let d1 = Interpolation.smoothstep(1) - Interpolation.smoothstep(0.99)
        XCTAssertLessThan(d0, 0.01 * 1.5)
        XCTAssertLessThan(d1, 0.01 * 1.5)
    }

    func testCurveDispatch() {
        XCTAssertEqual(Interpolation.Curve.easeOutCubic.value(0.5), Interpolation.easeOutCubic(0.5), accuracy: 1e-12)
        XCTAssertEqual(Interpolation.Curve.easeOutQuint.value(0.5), Interpolation.easeOutQuint(0.5), accuracy: 1e-12)
        XCTAssertEqual(Interpolation.Curve(rawValue: "ease-out-quint"), .easeOutQuint)
        XCTAssertNil(Interpolation.Curve(rawValue: "nope"))
    }

    func testLerpRect() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 200, y: 100, width: 300, height: 100)
        let mid = Interpolation.lerp(a, b, 0.5)
        XCTAssertEqual(mid.minX, 100)
        XCTAssertEqual(mid.minY, 50)
        XCTAssertEqual(mid.width, 200)
        XCTAssertEqual(mid.height, 100)
        XCTAssertEqual(Interpolation.lerp(a, b, 0), a)
        XCTAssertEqual(Interpolation.lerp(a, b, 1), b)
    }
}
