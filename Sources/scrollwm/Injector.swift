import CClient
import Darwin
import Foundation

/// 把 payload 注入 Dock 的加载器。
///
/// 主路径：task_for_pid + 远程线程 dlopen（需要 SIP 关闭 + arm64e_preview_abi）。
/// macOS 27 的关键语义（SDK mach/arm/_structs.h 的 get/set_pc 宏）：线程入口 PC
/// 必须由调用方用 process-independent code key + 字符串 discriminator "pc" 预先
/// 签名，内核不再代签裸 PC（裸 PC 会在第一条指令取指时 PAC 崩溃，见
/// DiagnosticReports/Dock-*.ips）。签名在 C 端 inject.c 完成。
///
/// 备路径：把 payload 组装成 scripting addition（osax）放进 /Library/ScriptingAdditions，
/// Dock 在加载 osax 时由 dyld 正常加载 payload（yabai/BetterTouchTool 同款），
/// 无需远程线程。两条路最终都是 payload constructor 注册 mach 服务。
///
/// `--load-sa` 默认 dry-run；`--load-sa --force` 才实际执行。
enum SAInjector {

    /// 版本相关常量集中区
    enum DockInjectionConstants {
        static let payloadBundleName = "ScrollWMSA.osax"
        static let scriptingAdditionsDir = "/Library/ScriptingAdditions"
        static let payloadExecutableName = "ScrollWMSA"
    }

    struct Preconditions {
        var isRoot: Bool
        var sipLikelyDisabled: Bool
        var bootArgSet: Bool
        var dockPID: pid_t?
    }

    // MARK: - 前置检查

    static func checkPreconditions() -> Preconditions {
        Preconditions(
            isRoot: getuid() == 0,
            sipLikelyDisabled: readCSRLikelyDisabled(),
            bootArgSet: readBootArgs().contains("arm64e_preview_abi"),
            dockPID: dockPID()
        )
    }

    static func printCheck() {
        let p = checkPreconditions()
        print("=== scrollwm 合成器注入自检 ===")
        print("root 运行:            \(p.isRoot ? "是" : "否（需 sudo）")")
        print("SIP 部分关闭:         \(p.sipLikelyDisabled ? "疑似是" : "否/未知")")
        print("boot-arg preview_abi: \(p.bootArgSet ? "已设" : "未设")")
        print("Dock PID:             \(p.dockPID.map(String.init) ?? "未找到")")
        print("osax 已安装:          \(installedOsaxPath() != nil ? "是（\(installedOsaxPath()!)）" : "否")")

        // payload 是否已在 Dock 内（通过 mach 服务 ping）
        let mover = CompositorMover()
        let connected = mover.connect()
        print("payload mach 服务:    \(connected ? "已注册（payload 在 Dock 内运行）" : "未注册")")
        print("===============================")
        if !connected {
            print("提示：运行 `sudo scrollwm --load-sa --force` 注入；成功后重启 scrollwm 本体生效。")
        }
    }

    // MARK: - 加载

    /// 主路径：把 payload osax 安装到 /Library/ScriptingAdditions，然后在用户会话里
    /// 用 `launchctl setenv DYLD_INSERT_LIBRARIES` + 重启 Dock 让 dyld 把 payload
    /// 加载进 Dock（macOS 27 上远程线程注入被内核 PAC/代码签名校验封死，此路径
    /// 已实测可行；需要 SIP 关闭）。
    ///
    /// 远程线程（task_for_pid + thread_create_running）在 macOS 27 上已不可行：
    /// 内核对平台签名进程（Dock）的线程入口 PC 做 PAC 校验，外部进程无法伪造
    ///（见 /tmp/pac_probe /tmp/injector 实验与 DiagnosticReports/Dock-*.ips）。
    /// C 端 inject.c 的 PIC 签名 stub 保留作为历史参考，不再被调用。
    ///
    /// `--load-sa` 默认 dry-run；`--load-sa --force` 才实际执行。
    @discardableResult
    static func load(force: Bool) -> Bool {
        let p = checkPreconditions()
        guard p.isRoot else {
            Log.error("安装需要 root：请用 sudo 运行 --load-sa")
            return false
        }
        if !p.sipLikelyDisabled {
            Log.warn("SIP 似乎未关闭，写入 /Library/ScriptingAdditions 会失败。见 docs/COMPOSITOR-SETUP.md")
        }

        guard let osax = sourceOsaxPath() else {
            Log.error("找不到 payload osax：\(DockInjectionConstants.payloadBundleName)（先运行 scripts/build-sa.sh）")
            return false
        }
        Log.info("osax 源：\(osax)")
        let dest = (DockInjectionConstants.scriptingAdditionsDir as NSString)
            .appendingPathComponent(DockInjectionConstants.payloadBundleName)

        let dirWritable = FileManager.default.isWritableFile(atPath: DockInjectionConstants.scriptingAdditionsDir)
        if !dirWritable {
            Log.error("无权限写入 \(DockInjectionConstants.scriptingAdditionsDir)（需要 root + SIP 关闭）")
            return false
        }

        if !force {
            Log.info("dry-run 完成：osax 就绪、目录可写。确认后用 `--load-sa --force` 安装并加载进 Dock。")
            return true
        }

        // 安装：先删旧的（不同签名/架构的旧 payload 会让 dyld 拒绝加载），再拷新的
        try? FileManager.default.removeItem(atPath: dest)
        do {
            try FileManager.default.copyItem(atPath: osax, toPath: dest)
        } catch {
            Log.error("拷贝 osax 失败：\(error.localizedDescription)")
            return false
        }
        Log.info("osax 已安装到 \(dest)")

        return activate()
    }

    /// 把 payload 加载进当前登录用户的 Dock（可在 root 或用户态调用）：
    /// 用户会话 launchd 里临时设 DYLD_INSERT_LIBRARIES → 重启 Dock → dyld 加载
    /// payload → 立即清除变量（只影响 Dock，避免其它新启动的 App 被注入）。
    @discardableResult
    static func activate() -> Bool {
        guard let dylib = installedPayloadDylibPath() else {
            Log.error("payload 未安装：先 `sudo scrollwm --load-sa --force`")
            return false
        }
        Log.info("DYLD 加载路径：\(dylib)")

        let user = ProcessInfo.processInfo.environment["SUDO_USER"] ?? NSUserName()
        let asUser: (String, [String]) -> Void = { cmd, args in
            let task = Process()
            if ProcessInfo.processInfo.environment["SUDO_USER"] != nil {
                task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                task.arguments = ["-u", user, cmd] + args
            } else {
                task.executableURL = URL(fileURLWithPath: cmd)
                task.arguments = args
            }
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }

        asUser("/bin/launchctl", ["setenv", "DYLD_INSERT_LIBRARIES", dylib])
        Log.info("已设置 DYLD_INSERT_LIBRARIES，重启 Dock…")
        asUser("/usr/bin/killall", ["Dock"])
        Thread.sleep(forTimeInterval: 1.5)
        asUser("/bin/launchctl", ["unsetenv", "DYLD_INSERT_LIBRARIES"])
        Log.info("已清除环境变量。等 Dock 起来后用 `--check-sa` 确认服务注册。")
        return true
    }

    static func unload() {
        // 移除 osax 并重启 Dock（清理 DYLD 注入只影响当下 Dock；重启后不再加载）
        let dest = (DockInjectionConstants.scriptingAdditionsDir as NSString)
            .appendingPathComponent(DockInjectionConstants.payloadBundleName)
        try? FileManager.default.removeItem(atPath: dest)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
        task.waitUntilExit()
        Log.info("已移除 osax 并重启 Dock（合成器后端将回退 AX）")
    }

    // MARK: - 环境探测

    private static func dockPID() -> pid_t? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "Dock"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first,
            let pid = pid_t(s) else { return nil }
        return pid
    }

    private static func readCSRLikelyDisabled() -> Bool {
        let out = runCapture("/usr/bin/csrutil", ["status"])
        return out.contains("disabled") || out.contains("unknown") || out.contains("Custom")
    }

    private static func readBootArgs() -> String {
        runCapture("/usr/sbin/nvram", ["boot-args"])
    }

    private static func runCapture(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - osax（备路径）

    /// 已安装到 /Library/ScriptingAdditions 的 osax（用于自检）
    private static func installedOsaxPath() -> String? {
        let path = (DockInjectionConstants.scriptingAdditionsDir as NSString)
            .appendingPathComponent(DockInjectionConstants.payloadBundleName)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// 待安装的 osax：优先 App 内 Resources，其次 cwd 的 dist
    private static func sourceOsaxPath() -> String? {
        let name = DockInjectionConstants.payloadBundleName
        let candidates: [String?] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)").path,
            FileManager.default.currentDirectoryPath + "/dist/\(name)",
            installedOsaxPath(),
        ]
        return candidates.compactMap { $0 }.first {
            let exec = ($0 as NSString).appendingPathComponent("Contents/MacOS/\(DockInjectionConstants.payloadExecutableName)")
            return FileManager.default.fileExists(atPath: exec)
        }
    }

    /// 已安装 payload 的 Mach-O dylib（DYLD_INSERT_LIBRARIES 用）
    private static func installedPayloadDylibPath() -> String? {
        guard let osax = installedOsaxPath() else { return nil }
        let exec = (osax as NSString).appendingPathComponent("Contents/MacOS/\(DockInjectionConstants.payloadExecutableName)")
        return FileManager.default.fileExists(atPath: exec) ? exec : nil
    }

    // MARK: - 自动加载状态

    private static let autoLoadKey = "scrollwm.compositor.autoloaded"
    private static let autoLoadDateKey = "scrollwm.compositor.autoloaded.date"

    /// osax 是否已安装到 /Library/ScriptingAdditions（WindowManager 自动加载用）
    static func installedOsaxPresent() -> Bool {
        installedOsaxPath() != nil
    }

    /// 本次登录是否已经尝试过自动加载（避免每次重载配置都重启 Dock）
    static func isAutoLoadingCompositor() -> Bool {
        UserDefaults.standard.bool(forKey: autoLoadKey)
    }

    static func markAutoLoadingCompositor() {
        UserDefaults.standard.set(true, forKey: autoLoadKey)
    }
}
