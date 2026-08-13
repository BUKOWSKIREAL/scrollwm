import CClient
import Darwin
import Foundation

/// 把 payload 注入 Dock 的加载器。
///
/// ⚠️ 这是整套方案里**唯一随 macOS 版本变化**的部分。注入依赖 `task_for_pid` +
/// 远程线程 + 解析目标进程内 `dlopen` 地址。这些在 SIP 关闭 + boot-arg 设置正确时
/// 才可能成功；且 arm64 bootstrap 的正确性需在真机 bring-up 时用日志逐步验证。
///
/// 为避免把未验证的机器码写进 Dock 导致其崩溃，`load()` 默认 **dry-run**：
/// 只做到"拿到 task port + 解析出 dlopen 地址"并汇报，不真正写入/执行远程代码。
/// 用 `--load-sa --force` 才会实际注入（bring-up 验证通过后再用）。
enum SAInjector {

    /// 版本相关常量集中区（bring-up 时按日志调整）
    enum DockInjectionConstants {
        static let payloadBundleName = "ScrollWMSA.bundle"
        static let rtldNow: UInt64 = 2
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

        // payload 是否已在 Dock 内（通过 mach 服务 ping）
        let mover = CompositorMover()
        let connected = mover.connect()
        print("payload mach 服务:    \(connected ? "已注册（payload 在 Dock 内运行）" : "未注册")")
        print("===============================")
        if !connected {
            print("提示：若前三项就绪但服务未注册，运行 `sudo scrollwm --load-sa` 加载 payload。")
        }
    }

    // MARK: - 加载

    @discardableResult
    static func load(force: Bool) -> Bool {
        let p = checkPreconditions()
        guard p.isRoot else {
            Log.error("注入需要 root：请用 sudo 运行 --load-sa")
            return false
        }
        guard let dock = p.dockPID else {
            Log.error("未找到 Dock 进程")
            return false
        }
        if !p.sipLikelyDisabled || !p.bootArgSet {
            Log.warn("SIP 似乎未部分关闭或 boot-arg 未设置，task_for_pid 很可能失败。见 docs/COMPOSITOR-SETUP.md")
        }

        // 阶段 1：拿 Dock 的 task port（SIP 配置是否到位的真正试金石）
        var dockTask: task_t = 0
        let kr = task_for_pid(mach_task_self_, dock, &dockTask)
        guard kr == KERN_SUCCESS else {
            Log.error("task_for_pid(Dock=\(dock)) 失败 kr=\(kr)。通常意味着 SIP/boot-arg/entitlement 未就位。")
            return false
        }
        Log.info("阶段1 ✓ 取得 Dock task port")

        // 阶段 2：解析 Dock 内的 dlopen 地址（= 本进程 dlopen + 两进程共享缓存 slide 差）
        guard let localSlide = sharedCacheSlide(task: mach_task_self_),
              let remoteSlide = sharedCacheSlide(task: dockTask),
              let localDlopen = localDlopenAddress() else {
            Log.error("阶段2 ✗ 无法解析共享缓存 slide 或本地 dlopen 地址")
            return false
        }
        let remoteDlopen = localDlopen &+ (remoteSlide &- localSlide)
        Log.info(String(format: "阶段2 ✓ dlopen 本地=0x%llx 远程=0x%llx (slide 本地=0x%llx 远程=0x%llx)",
                        localDlopen, remoteDlopen, localSlide, remoteSlide))

        guard let payloadPath = payloadBundlePath() else {
            Log.error("找不到 payload：\(DockInjectionConstants.payloadBundleName)（先运行 scripts/build-sa.sh）")
            return false
        }
        Log.info("payload 路径：\(payloadPath)")

        if !force {
            Log.info("dry-run 完成：前置条件与地址解析均就绪。确认无误后用 `--load-sa --force` 实际注入。")
            return true
        }

        // 阶段 3：分配远程内存，写入 payload 路径 + arm64 bootstrap，起远程线程
        return injectRemoteThread(task: dockTask, dlopen: remoteDlopen, payloadPath: payloadPath)
    }

    static func unload() {
        // payload 常驻 Dock；最干净的卸载是重启 Dock（会丢失注入，符合预期）
        Log.info("卸载：重启 Dock 即可移除 payload。执行 `killall Dock`（Dock 会自动重启）。")
    }

    // MARK: - 远程线程注入（C 辅助处理 arm64e ptrauth，Swift 只做分配与路径写入）

    private static func injectRemoteThread(task: task_t, dlopen: UInt64, payloadPath: String) -> Bool {
        let pathBytes = Array(payloadPath.utf8) + [0]
        let codeWords = 11          // 4+1+4+1+1 条指令（由 C 端生成）
        let codeSize = codeWords * 4
        let pathOffset = (codeSize + 15) & ~15
        let totalSize = pathOffset + pathBytes.count

        var remoteMem: vm_address_t = 0
        guard vm_allocate(task, &remoteMem, vm_size_t(totalSize), VM_FLAGS_ANYWHERE) == KERN_SUCCESS else {
            Log.error("阶段3 ✗ vm_allocate 失败")
            return false
        }
        let pathAddr = UInt64(remoteMem) + UInt64(pathOffset)

        // 路径串写入远端（代码由 C 端 vm_write + vm_protect 以避免 Swift ptrauth 问题）
        let pathOK = pathBytes.withUnsafeBytes { raw in
            vm_write(task, vm_address_t(pathAddr), vm_offset_t(bitPattern: raw.baseAddress),
                     mach_msg_type_number_t(raw.count)) == KERN_SUCCESS
        }
        guard pathOK else { Log.error("阶段3 ✗ 路径 vm_write 失败"); return false }

        // 带 ptrauth 的线程创建 + 代码保护由 C 完成
        let kr = scrollwm_create_remote_dlopen_thread(task, remoteMem, vm_size_t(totalSize),
                                                       dlopen, pathAddr, DockInjectionConstants.rtldNow)
        guard kr == KERN_SUCCESS else {
            Log.error("阶段3 ✗ thread_create_running 失败 kr=\(kr) (2=KERN_PROTECTION_FAILURE: 权限/签名问题)")
            return false
        }
        Log.info("阶段3 ✓ 远程线程已启动，payload 应在 Dock 内加载。用 `--check-sa` 确认服务注册。")
        return true
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

    private static func localDlopenAddress() -> UInt64? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dlopen") else { return nil }
        // arm64e: 高位是 PAC 签名，Swift 没有 ptrauth_strip，只能按 VA 位宽截断
        // 使用 T1SZ 感知：高 16 位清零，低 48 位保留（比 40 更保守，避免误截）
        let raw = UInt64(UInt(bitPattern: sym))
        return raw & 0x000000FFFFFFFFFF // 40-bit VA，去掉 PAC 占用的高位（实测 0x800.../0xc4 均在 40 位外）
    }

    /// 读取指定 task 的 dyld 共享缓存 slide
    private static func sharedCacheSlide(task: task_t) -> UInt64? {
        var info = task_dyld_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intptr in
                task_info(task, task_flavor_t(TASK_DYLD_INFO), intptr, &count)
            }
        }
        guard kr == KERN_SUCCESS, info.all_image_info_addr != 0 else { return nil }

        // 从 dyld_all_image_infos 读 sharedCacheSlide。对本进程与 Dock 用**同一偏移**
        // 读取，remote dlopen = local dlopen + (远程 slide - 本地 slide)：只要偏移在两个
        // 进程里指向同一字段，差值即为真实 slide 差，无需该偏移绝对正确。
        // 偏移随 macOS 版本可能变化，bring-up 时用日志核对 kSharedCacheSlideOffset。
        return readSharedCacheSlide(task: task, allImageInfoAddr: info.all_image_info_addr)
    }

    /// dyld_all_image_infos.sharedCacheSlide 的字段偏移（经 offsetof 实测 152 = 0x98）
    private static let kSharedCacheSlideOffset: mach_vm_address_t = 152

    private static func readSharedCacheSlide(task: task_t, allImageInfoAddr: mach_vm_address_t) -> UInt64? {
        var value: UInt64 = 0
        var outSize: mach_vm_size_t = 0
        let kr = withUnsafeMutablePointer(to: &value) { ptr -> kern_return_t in
            mach_vm_read_overwrite(task, allImageInfoAddr + kSharedCacheSlideOffset,
                                   mach_vm_size_t(MemoryLayout<UInt64>.size),
                                   mach_vm_address_t(UInt(bitPattern: ptr)), &outSize)
        }
        guard kr == KERN_SUCCESS else { return nil }
        return value
    }

    private static func payloadBundlePath() -> String? {
        let name = DockInjectionConstants.payloadBundleName
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)").path,
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(name).path,
            FileManager.default.currentDirectoryPath + "/dist/\(name)",
            FileManager.default.currentDirectoryPath + "/.build/\(name)",
        ]
        guard let base = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        // dlopen 需要指向 Mach-O 文件本身，而不是 .bundle 目录
        if base.hasSuffix(".bundle") {
            let exec = (base as NSString).appendingPathComponent("Contents/MacOS/ScrollWMSA")
            if FileManager.default.fileExists(atPath: exec) { return exec }
        }
        return base
    }
}
