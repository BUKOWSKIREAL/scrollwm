import XCTest
@testable import ScrollCore

final class SpringTests: XCTestCase {
    func testNiriDefaultParameters() {
        let p = SpringParameters.niriDefault
        XCTAssertEqual(p.dampingRatio, 1)
        XCTAssertEqual(p.stiffness, 800)
        XCTAssertEqual(p.epsilon, 0.0001)
        XCTAssertEqual(p.damping, 2 * sqrt(800), accuracy: 1e-12)
    }

    func testCriticalSpringStartsAtFromAndSettlesAtTarget() {
        let spring = ScalarSpring(from: 0, to: 1000)
        XCTAssertEqual(spring.value(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(spring.velocity(at: 0), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(spring.settlingDuration, 0.3)
        XCTAssertLessThan(spring.settlingDuration, 0.35)
        XCTAssertEqual(spring.value(at: spring.settlingDuration), 1000, accuracy: 1.2)
    }

    func testCriticalSpringDoesNotOvershoot() {
        let spring = ScalarSpring(from: -200, to: 500)
        var previous = spring.value(at: 0)
        for millisecond in 1...500 {
            let value = spring.value(at: Double(millisecond) / 1000)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-9)
            XCTAssertLessThanOrEqual(value, 500 + 1e-9)
            previous = value
        }
    }

    func testRetargetCanInheritVelocity() {
        let first = ScalarSpring(from: 0, to: 1000)
        let time = 0.08
        let position = first.value(at: time)
        let velocity = first.velocity(at: time)
        XCTAssertGreaterThan(velocity, 0)

        let redirected = ScalarSpring(
            from: position,
            to: 2000,
            initialVelocity: velocity
        )
        XCTAssertEqual(redirected.value(at: 0), position, accuracy: 1e-9)
        XCTAssertEqual(redirected.velocity(at: 0), velocity, accuracy: 1e-9)
        XCTAssertGreaterThan(redirected.value(at: 0.001), position)
    }

    func testUnderdampedSpringOvershoots() {
        let parameters = SpringParameters(dampingRatio: 0.7, stiffness: 800, epsilon: 0.0001)
        let spring = ScalarSpring(from: 0, to: 1, parameters: parameters)
        let values = (0...500).map { spring.value(at: Double($0) / 1000) }
        XCTAssertTrue(values.contains { $0 > 1 })
    }
}
