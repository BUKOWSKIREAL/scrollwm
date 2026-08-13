# 合成器级动画（SkyLight）接入与 SIP 配置

> ⚠️ 本方案需要**部分关闭 SIP**并把代码注入系统的 `Dock.app`。这会永久降低本机
> 安全等级，且**在每次 macOS 大版本更新后大概率失效**（注入依赖逆向出的、随版本
> 变化的偏移量）。你当前是 **macOS 27.0（build 26A5406e）/ Apple Silicon**，属于
> 最新版本，社区尚无现成的注入特征码，需要我们自己逐步调通。请在完全理解风险后再继续。

## 为什么必须这样

macOS 没有任何公开或私有 API 允许普通进程平滑地移动"别的 App 的窗口"。窗口的
所有权由 WindowServer 的连接鉴权（`connection_holds_rights_on_window`）。只有
`Dock.app` 的连接被标记为"万能所有者"，能修改任意窗口。因此要做合成器级动画，
唯一可行路径（yabai 同款）是：

1. 部分关闭 SIP → 允许 `task_for_pid` 拿到 Dock 的 task port；
2. 把一个 payload 注入 Dock 进程；
3. payload 在 Dock 内用 Dock 的特权连接，通过私有 `SLSTransaction` 批量、
   原子地移动窗口——所有窗口在同一帧一起动，提交耗时亚毫秒，于是 60fps 平滑动画
   成为可能（这正是 AX 方案做不到的：AX 每窗口一次 10–50ms 的同步 RPC，只能一个个跳）。

## 一次性配置（Apple Silicon / macOS 27）

### 1. 进入恢复模式部分关闭 SIP

关机 → 长按电源键直到出现"正在载入启动选项" → 选"选项" → 继续 → 选管理员账户。
打开 终端（左上角"实用工具"菜单），执行：

```bash
csrutil enable --without fs --without debug --without nvram
```

> 这是 Apple Silicon macOS 13+ 的**部分**关闭形式（保留大部分保护，仅放开注入所需
> 的文件系统保护、调试限制、NVRAM 保护）。打印的告警可忽略。

### 2. 设置启动安全策略为"许可"

仍在恢复模式，终端执行（`<disk>` 一般是 `disk3s1`，用 `diskutil list` 确认系统卷）：

```bash
# 也可用 GUI：实用工具 → 启动安全性实用工具 → 选系统卷 → 降低安全性
#   勾选"允许用户管理来自已认证开发者的内核扩展" + "允许使用降级/未签名 arm64e ABI"
bputil -a          # 查看当前策略
```

优先用 GUI"启动安全性实用工具"设为**降低安全性（Reduced Security）**并勾选允许
非 Apple 签名/预览 arm64e。`bputil` 是底层工具，不熟勿用。

### 3. 重启回正常系统，设置 boot-arg

```bash
sudo nvram boot-args=-arm64e_preview_abi
sudo reboot
```

> 该 boot-arg 让系统允许加载非 Apple 的 arm64e 二进制（注入 payload 必需）。
> 若报 `Error setting variable ... not permitted`，说明第 2 步的安全策略没设到位。

### 4. 重启后验证

```bash
csrutil status          # 期望：部分/ disabled（新版可能显示 unknown）
nvram boot-args         # 期望：-arm64e_preview_abi
```

### 5. 授权注入器（sudoers 免密加载）

注入器需要 root 跑 `task_for_pid(Dock)`。加一条 sudoers（用 `sudo visudo`）：

```
你的用户名 ALL=(root) NOPASSWD: sha256:<scrollwm二进制哈希> /path/to/scrollwm --load-sa
```

（构建脚本会打印当前二进制路径与哈希。）

### 6. 稳定签名 + 调试器 entitlement（必需）

`task_for_pid` 要求注入器带 `com.apple.security.cs.debugger` entitlement 且签名稳定。
先建自签名身份（见根目录 README「稳定签名」一节 / `scripts/setup-signing.sh`），
之后带 entitlement 打包：

```bash
./scripts/setup-signing.sh
SCROLLWM_SIGN_ID="ScrollWM Self-Signed" ./scripts/make-app.sh
```

`Support/scrollwm.entitlements` 已包含 `cs.debugger` 与 `cs.disable-library-validation`。

## 加载与自检

```bash
# 编译注入 payload（scripting addition）
./scripts/build-sa.sh

# 加载到 Dock（需 root）
sudo /path/to/ScrollWM.app/Contents/MacOS/scrollwm --load-sa

# 自检：确认 payload 已在 Dock 内、mach 服务已注册
/path/to/scrollwm --check-sa
```

加载成功后，把配置里的合成器后端打开：

```toml
[compositor]
enabled = true        # 用 SkyLight 批量事务做动画；关闭则回退 AX
```

## 当前状态与 bring-up 计划

- 代码骨架（SkyLight 桥接 `SkyLight.swift`、注入器 `Injector.swift`、payload
  `Support/CompositorSA/payload.c`、mach IPC、动画后端抽象）已就位并可编译。
- **注入特征码/偏移量针对 macOS 27 尚未验证**，集中在 `Injector.swift` 顶部的
  `DockInjectionConstants`，并带详细 stderr 日志（`SCROLLWM_LOG=debug`）。
- Bring-up 迭代：你完成上面 1–6 步并重启后，运行 `sudo scrollwm --load-sa`，
  把 `Console.app` 里过滤 `scrollwm` 的输出发我，我据此调偏移量，直到
  `--check-sa` 通过、动画切到合成器后端。

## 出问题时的回退

- 配置 `[compositor] enabled = false` 立即回到 AX 动画，不受注入影响。
- 卸载：`sudo scrollwm --unload-sa`（移除 Dock 内 payload；重启 Dock 亦可）。
- 想恢复安全：恢复模式执行 `csrutil enable`，并 `sudo nvram -d boot-args`。
