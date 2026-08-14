import Foundation

/// 简单日志：始终写 stderr 与 ~/.config/scrollwm/scrollwm.log（追加，超 512KB 截断重写）。
/// SCROLLWM_LOG=debug 开启调试级。
enum Log {
    private static let debugEnabled = ProcessInfo.processInfo.environment["SCROLLWM_LOG"] == "debug"

    static let logPath: String =
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/scrollwm/scrollwm.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let fileHandle: FileHandle? = {
        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 简单滚动：超 512KB 直接清空重来
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? Int, size > 512 * 1024 {
            try? FileManager.default.removeItem(atPath: logPath)
        }
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        return FileHandle(forWritingAtPath: logPath).map { handle in
            handle.seekToEndOfFile()
            return handle
        }
    }()

    private static func emit(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(level) \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        fileHandle?.write(data)
    }

    static func info(_ message: String) { emit("INFO ", message) }
    static func warn(_ message: String) { emit("WARN ", message) }
    static func error(_ message: String) { emit("ERROR", message) }
    static func debug(_ message: @autoclosure () -> String) {
        if debugEnabled { emit("DEBUG", message()) }
    }
}
