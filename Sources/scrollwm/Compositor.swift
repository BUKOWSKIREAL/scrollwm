import CClient
import CoreGraphics
import ScrollCore

/// 合成器执行端的 Swift 封装：薄封装 C 客户端（Sources/CClient）。
/// payload 未注入 Dock 时 connect 失败，调用方回退 AX。
final class CompositorMover {
    private(set) var isAvailable = false

    @discardableResult
    func connect() -> Bool {
        isAvailable = scrollwm_client_connect() != 0
        return isAvailable
    }

    func disconnect() {
        scrollwm_client_disconnect()
        isAvailable = false
    }

    /// 发送批量帧。frames: (窗口, 目标矩形, alpha)
    func apply(_ frames: [(id: WindowID, rect: CGRect, alpha: Float)], settle: Bool) {
        guard isAvailable, !frames.isEmpty else { return }
        let cframes = frames.prefix(64).map { f in
            scrollwm_frame_t(
                window_id: f.id,
                x: Float(f.rect.origin.x), y: Float(f.rect.origin.y),
                w: Float(f.rect.width), h: Float(f.rect.height),
                alpha: f.alpha
            )
        }
        let ok = cframes.withUnsafeBufferPointer { buf in
            scrollwm_client_apply(buf.baseAddress, UInt32(buf.count), settle ? 1 : 0) != 0
        }
        if !ok { isAvailable = false }
    }
}
