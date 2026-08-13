import Foundation

/// 单位质量弹簧参数。默认值与 niri horizontal-view-movement 一致（临界阻尼、无回弹）。
public struct SpringParameters: Equatable, Sendable {
    public var dampingRatio: Double
    public var stiffness: Double
    public var epsilon: Double

    public init(dampingRatio: Double = 1.0, stiffness: Double = 800, epsilon: Double = 0.0001) {
        self.dampingRatio = max(0, dampingRatio)
        self.stiffness = max(0, stiffness)
        self.epsilon = max(0, epsilon)
    }

    public static let niriDefault = SpringParameters()

    public var mass: Double { 1 }
    public var criticalDamping: Double { 2 * sqrt(mass * stiffness) }
    public var damping: Double { dampingRatio * criticalDamping }
}

/// 一维解析式弹簧，解标准阻尼谐振方程（niri/libadwaita 同款，源头不在 niri）：
/// m*x'' + b*x' + k*x = 0。
public struct ScalarSpring: Equatable, Sendable {
    public var from: Double
    public var to: Double
    public var initialVelocity: Double
    public var parameters: SpringParameters

    public init(
        from: Double,
        to: Double,
        initialVelocity: Double = 0,
        parameters: SpringParameters = .niriDefault
    ) {
        self.from = from
        self.to = to
        self.initialVelocity = initialVelocity
        self.parameters = parameters
    }

    public func value(at time: TimeInterval) -> Double {
        to + displacementAndVelocity(at: time).displacement
    }

    public func velocity(at time: TimeInterval) -> Double {
        displacementAndVelocity(at: time).velocity
    }

    /// 衰减包络到达 epsilon 的时刻估计（临界/欠阻尼经典做法，niri 同款）。
    /// 默认参数约 326ms；动画结束时由调用方精确落到目标。
    public var settlingDuration: TimeInterval {
        let beta = parameters.damping / (2 * parameters.mass)
        guard beta.isFinite, beta > Double.ulpOfOne,
              abs(to - from) > Double.ulpOfOne,
              parameters.epsilon > 0
        else { return 0 }

        let omega0 = sqrt(parameters.stiffness / parameters.mass)
        let estimate = -log(parameters.epsilon) / beta
        guard estimate.isFinite, estimate >= 0 else { return 3 }

        // 临界与欠阻尼直接用包络估计（niri 同款做法）。
        if abs(beta - omega0) <= Double(Float.ulpOfOne) || beta < omega0 {
            return min(3, estimate)
        }

        // 过阻尼衰减慢于包络。用小步搜索稳定、有限的落点；该模式并非默认。
        var time = estimate
        let step = 0.001
        while time < 3, abs(to - value(at: time)) > parameters.epsilon {
            time += step
        }
        return min(3, time)
    }

    private func displacementAndVelocity(at rawTime: TimeInterval) -> (displacement: Double, velocity: Double) {
        let time = max(0, rawTime)
        let mass = parameters.mass
        let beta = parameters.damping / (2 * mass)
        let omega0 = sqrt(parameters.stiffness / mass)
        let x0 = from - to
        let v0 = initialVelocity
        let envelope = exp(-beta * time)

        if abs(beta - omega0) <= Double(Float.ulpOfOne) {
            // 临界阻尼：e^-bt * (x0 + (b*x0+v0)t)
            let coefficient = beta * x0 + v0
            let body = x0 + coefficient * time
            return (envelope * body, envelope * (coefficient - beta * body))
        }

        if beta < omega0 {
            // 欠阻尼。
            let omega1 = sqrt(omega0 * omega0 - beta * beta)
            let coefficient = (beta * x0 + v0) / omega1
            let angle = omega1 * time
            let cosAngle = cos(angle)
            let sinAngle = sin(angle)
            let body = x0 * cosAngle + coefficient * sinAngle
            let bodyVelocity = -x0 * omega1 * sinAngle + coefficient * omega1 * cosAngle
            return (envelope * body, envelope * (bodyVelocity - beta * body))
        }

        // 过阻尼。
        let omega2 = sqrt(beta * beta - omega0 * omega0)
        let coefficient = (beta * x0 + v0) / omega2
        let angle = omega2 * time
        let coshAngle = cosh(angle)
        let sinhAngle = sinh(angle)
        let body = x0 * coshAngle + coefficient * sinhAngle
        let bodyVelocity = x0 * omega2 * sinhAngle + coefficient * omega2 * coshAngle
        let displacement = envelope * body
        let velocity = envelope * (bodyVelocity - beta * body)
        if displacement.isFinite, velocity.isFinite {
            return (displacement, velocity)
        }
        return (0, 0)
    }
}
