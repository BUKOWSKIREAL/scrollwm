import AppKit
import Darwin
import CoreGraphics

/// 读取目标窗口的系统圆角。macOS 26+ 按标题栏/工具栏变化，不能写死一个半径。
enum WindowChrome {
    private static let fallbackRadius: CGFloat = 10
    private static var cache: (id: CGWindowID, radius: CGFloat, at: CFTimeInterval)?

    private static let slsMainConnectionID = dlsymFunc("SLSMainConnectionID", type: (@convention(c) () -> Int32).self)
    private static let slsWindowQueryWindows = dlsymFunc(
        "SLSWindowQueryWindows",
        type: (@convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?).self
    )
    private static let slsCopyIterator = dlsymFunc(
        "SLSWindowQueryResultCopyWindows",
        type: (@convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?).self
    )
    private static let slsIteratorAdvance = dlsymFunc(
        "SLSWindowIteratorAdvance",
        type: (@convention(c) (CFTypeRef) -> Bool).self
    )
    private static let slsGetCornerRadii = dlsymFunc(
        "SLSWindowIteratorGetCornerRadii",
        type: (@convention(c) (CFTypeRef) -> Unmanaged<CFArray>?).self
    )
    private static let slsGetResolvedCornerRadii = dlsymFunc(
        "SLSWindowIteratorGetResolvedCornerRadii",
        type: (@convention(c) (CFTypeRef) -> Unmanaged<CFArray>?).self
    )

    static func cornerRadius(for windowID: CGWindowID) -> CGFloat {
        let now = CFAbsoluteTimeGetCurrent()
        if let cache, cache.id == windowID, now - cache.at < 0.4 {
            return cache.radius
        }
        let queried = querySkyLight(windowID)
        let radius = min(40, max(4, queried > 0.5 ? queried : fallbackRadius))
        cache = (windowID, radius, now)
        return radius
    }

    private static func querySkyLight(_ windowID: CGWindowID) -> CGFloat {
        guard let slsMainConnectionID,
              let slsWindowQueryWindows,
              let slsCopyIterator,
              let slsIteratorAdvance
        else { return 0 }

        var raw = Int32(windowID)
        guard let idNum = CFNumberCreate(nil, .sInt32Type, &raw) else { return 0 }
        let ids = [idNum] as CFArray
        guard let query = slsWindowQueryWindows(slsMainConnectionID(), ids, 0)?.takeRetainedValue() else {
            return 0
        }
        defer { /* query released by takeRetainedValue */ }
        guard let iterator = slsCopyIterator(query)?.takeRetainedValue(),
              slsIteratorAdvance(iterator)
        else { return 0 }

        if let resolved = slsGetResolvedCornerRadii?(iterator)?.takeRetainedValue(),
           let value = firstPositiveRadius(in: resolved) {
            return value
        }
        if let ints = slsGetCornerRadii?(iterator)?.takeRetainedValue(),
           let value = firstPositiveRadius(in: ints) {
            return value
        }
        return 0
    }

    private static func firstPositiveRadius(in array: CFArray) -> CGFloat? {
        let count = CFArrayGetCount(array)
        guard count > 0 else { return nil }
        var best: CGFloat = 0
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let any = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(any) == CFNumberGetTypeID() else { continue }
            let num = unsafeBitCast(any, to: CFNumber.self)
            var value: CGFloat = 0
            if !CFNumberGetValue(num, .cgFloatType, &value) {
                var asInt: Int32 = 0
                guard CFNumberGetValue(num, .sInt32Type, &asInt) else { continue }
                value = CGFloat(asInt)
            }
            if value > best { best = value }
        }
        return best > 0.5 ? best : nil
    }

    private static func dlsymFunc<T>(_ name: String, type: T.Type) -> T? {
        guard let symbol = dlsym(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY), name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}
