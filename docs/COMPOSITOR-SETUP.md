# 合成器级动画（SkyLight）接入与 SIP 配置

> ⚠️ 本方案需要**关闭 SIP**。请理解风险后再继续。

## 工作原理

macOS 没有任何公开或私有 API 允许普通进程平滑地移动"别的 App 的窗口"。窗口的
所有权由 WindowServer 的连接鉴权（`connection_holds_rights_on_window`）。只有
`Dock.app` 的连接被标记为"万能所有者"，能修改任意窗口。因此要做合成器级动画：

1. 关闭 SIP → 允许把 payload 装进 `/Library/ScriptingAdditions`；
2. 通过用户会话 `launchctl setenv DYLD_INSERT_LIBRARIES` + 重启 Dock，让 dyld
   把 payload 加载进 Dock（已实测可行）；
3. payload 在 Dock 内用 Dock 的特权连接，通过私有 `SLSTransaction` 批量、
   原子地移动窗口——所有窗口在同一帧一起动，提交耗时亚毫秒，于是 60fps 平滑动画
   成为可能（这正是 AX 方案做不到的：AX 每窗口一次 10–50ms 的同步 RPC，只能一个个跳）。

## 为什么用 DYLD 注入而不是远程线程

macOS 27（build 26A5406e）上 `task_for_pid` + `thread_create_running` 的远程线程
注入已死：内核会对平台签名进程（Dock）的线程入口 PC 做 PAC 校验，外部进程无法
伪造签名（SDK `mach/arm/_structs.h` 的 `__darwin_arm_thread_state64_set_pc_fptr`
说明入口 PC 必须由进程内钥匙签名）。用 PIC key 签名的 stub 在自进程/跨进程实验里
能跑，但注入 Dock 后线程首条指令即 PAC 崩溃（见 DiagnosticReports/Dock-*.ips）。
`Sources/CClient/inject.c` 的 PIC 签名 stub 保留作为历史参考，不再被调用。

## 一次性配置

### 1. 进入恢复模式关闭 SIP

关机 → 长按电源键直到出现"正在载入启动选项" → 选"选项" → 继续 → 选管理员账户。
打开 终端（左上角"实用工具"菜单），执行：

```bash
csrutil disable
```

重启回正常系统，验证：

```bash
csrutil status          # 期望：disabled
```

### 2. 稳定签名身份（可选但推荐）

```bash
./scripts/setup-signing.sh
```

之后带稳定身份构建（辅助功能授权不会因重打而失效）：

```bash
SCROLLWM_SIGN_ID="ScrollWM Self-Signed" ./scripts/make-app.sh
```

## 加载与自检

```bash
# 编译 payload 并组装为 osax
./scripts/build-sa.sh

# 打包 App（默认 arm64e，与 Dock 一致）
SCROLLWM_SIGN_ID="ScrollWM Self-Signed" ./scripts/make-app.sh

# 安装 osax 到 /Library/ScriptingAdditions，并注入 Dock（需 root）
sudo /path/to/ScrollWM.app/Contents/MacOS/scrollwm --load-sa --force

# 自检：确认 payload 已在 Dock 内、mach 服务已注册
/path/to/ScrollWM.app/Contents/MacOS/scrollwm --check-sa
# 期望：payload mach 服务: 已注册
```

加载成功后，把配置里的合成器后端打开：

```toml
[compositor]
enabled = true        # 用 SkyLight 批量事务做动画；关闭则回退 AX
```

重启 scrollwm，日志出现 `动画后端：合成器（SkyLight，payload 已连接）` 即生效。

## 登录后的自动加载

Dock 重启（重启/重新登录）后 payload 会丢失。scrollwm 启动时若配置了
`compositor.enabled` 且 osax 已安装，会自动重新走一遍 DYLD 注入流程
（设置环境变量 → 重启 Dock → 清除变量），无需手动干预。

## 出问题时的回退

- 配置 `[compositor] enabled = false` 立即回到 AX 动画，不受 payload 影响。
- 卸载：`sudo scrollwm --unload-sa`（移除 osax；重启 Dock 后 payload 消失）。
- 想恢复安全：恢复模式执行 `csrutil enable`。
