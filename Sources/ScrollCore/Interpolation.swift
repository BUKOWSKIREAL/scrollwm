import CoreGraphics

/// 动画插值工具：纯函数，供帧动画器逐 tick 计算
public enum Interpolation {

    /// 缓动曲线（窗口管理场景避免 overshoot，防止越过屏幕钳位）
    public enum Curve: String, Sendable, CaseIterable {
        /// 经典三次缓出：稳妥，略肉
        case easeOutCubic = "ease-out-cubic"
        /// 五次缓出：前段更快、尾段更黏，更像 niri/高级 WM
        case easeOutQuint = "ease-out-quint"
        /// 指数缓出：起手更冲、收尾更软
        case easeOutExpo = "ease-out-expo"
        /// 平滑步进（smoothstep 三次）：中段匀、两端柔
        case smoothstep = "smoothstep"

        public static let `default`: Curve = .easeOutQuint

        public func value(_ t: Double) -> Double {
            switch self {
            case .easeOutCubic: return Interpolation.easeOutCubic(t)
            case .easeOutQuint: return Interpolation.easeOutQuint(t)
            case .easeOutExpo: return Interpolation.easeOutExpo(t)
            case .smoothstep: return Interpolation.smoothstep(t)
            }
        }
    }

    /// easeOutCubic：起步快收尾缓，适合滚动定位类动画
    public static func easeOutCubic(_ t: Double) -> Double {
        let clamped = t.clamped(0, 1)
        let inv = 1 - clamped
        return 1 - inv * inv * inv
    }

    /// easeOutQuint：比 cubic 更“高级”——前 40% 几乎到位，尾段细腻贴合
    public static func easeOutQuint(_ t: Double) -> Double {
        let clamped = t.clamped(0, 1)
        let inv = 1 - clamped
        return 1 - inv * inv * inv * inv * inv
    }

    /// easeOutExpo：起手更冲；t=0/1 精确端点
    public static func easeOutExpo(_ t: Double) -> Double {
        let clamped = t.clamped(0, 1)
        if clamped <= 0 { return 0 }
        if clamped >= 1 { return 1 }
        return 1 - pow(2, -10 * clamped)
    }

    /// smoothstep：两端导数为 0，适合短距离微调
    public static func smoothstep(_ t: Double) -> Double {
        let clamped = t.clamped(0, 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    public static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }

    public static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
    }

    public static func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(
            x: lerp(a.minX, b.minX, t),
            y: lerp(a.minY, b.minY, t),
            width: lerp(a.width, b.width, t),
            height: lerp(a.height, b.height, t)
        )
    }
}
