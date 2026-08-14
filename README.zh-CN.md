# scrollwm

[English](README.md) | [简体中文](README.zh-CN.md)

niri 式的 macOS **卷轴平铺窗口管理器**（scrollable tiling，PaperWM 范式）。

窗口排成一条无限横向"纸带"，每个窗口占一列：新窗口插在焦点列旁（默认右侧，可改），焦点移动时视口
最小滚动露出焦点列，滚出视口的列停靠在屏幕边缘露出一条"纸边"。键盘驱动，TOML 配置。

- 纯公开 Accessibility API（仅一个无害私有函数 `_AXUIElementGetWindow` 取窗口 ID）
- **不需要关闭 SIP**，不注入任何进程
- Swift 实现：布局引擎为纯函数库 `ScrollCore`（53 个单元测试），守护进程 `scrollwm`

## MVP 边界

单显示器（主屏）、单工作区（当前 Space）、无触控板手势、一列一窗。
列内堆叠（consume/expel）、多工作区、多显示器、平滑手势滚动在路线图上。

## 构建与运行

要求：macOS 14+，Xcode 命令行工具（Swift 5.10+）。

### 方式一：打包成 App（推荐日常使用）

```bash
cd scrollwm
./scripts/make-app.sh           # 构建 + 组装 + 签名 dist/ScrollWM.app
mv dist/ScrollWM.app /Applications/
open /Applications/ScrollWM.app
```

菜单栏应用（无 Dock 图标），自带应用图标；菜单里有**开机自启**开关
（SMAppService，系统"登录项"中可见）。授权跟随 bundle，重新打包后一般无需重新授权。

### 方式二：裸二进制（适合开发调试）

```bash
./scripts/build.sh              # 构建 release 并 ad-hoc 签名
# 输出 BINARY=<二进制路径>

<二进制路径> --check            # 查看辅助功能授权状态
<二进制路径>                    # 前台启动（日志打到 stderr）
```

### 辅助功能授权

- 从终端启动时，进程继承终端的辅助功能权限：若终端 App 已授权，直接可用（适合开发调试）。
- 独立运行：首次启动会弹出系统授权引导，到
  系统设置 → 隐私与安全性 → 辅助功能，把二进制加入并勾选。
- 重新构建后系统可能要求重新授权（ad-hoc 签名的已知限制，脚本已用固定
  identifier `com.scrollwm.daemon` 尽量减少这种情况）。

### 开机自启（可选）

App 形式：直接用菜单栏里的"开机自启"开关。

裸二进制形式：保存为 `~/Library/LaunchAgents/com.scrollwm.daemon.plist` 后
`launchctl load ~/Library/LaunchAgents/com.scrollwm.daemon.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.scrollwm.daemon</string>
    <key>ProgramArguments</key>
    <array><string>/绝对路径/scrollwm</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
```

## 默认键位

Alt(Option) 为默认 Mod 键，全部可在配置中改：

- `alt-left` / `alt-right`：焦点移到左列 / 右列（自动滚动露出）
- `alt-h` / `alt-l`：同上，Vim 风格别名；可在配置中解绑
- `alt-shift-h` / `alt-shift-l`：焦点列向左 / 右挪位
- **Command + 拖动窗口**（niri Super+拖动）：按住 ⌘ 拖动平铺窗口，松手后按落点重排列序；不按 ⌘ 的拖动仍会回弹到纸带并吸收宽度
- `alt-r`：循环宽度预设（1/3 → 1/2 → 2/3 → 回绕）
- `alt-minus` / `alt-equal`：连续缩窄 / 加宽（步长 `resize_step`）；浮动窗口围绕中心缩放约 `2 × resize_step`
- `alt-f`：列全宽开关（再按恢复原宽）
- `alt-c`：焦点列在视口居中
- `alt-t`：浮动豁免开关（浮出/收回纸带）
- `alt-q`：关闭窗口（等价点红点）
- `alt-shift-r`：全量重扫并重排

菜单栏图标提供逃生门：暂停/恢复管理、设置窗口（窗口底部有「立即重排」和「打开配置文件」）、退出。授权相关项只在未授权时出现。

## 配置

`~/.config/scrollwm/config.toml`，首次启动自动生成默认模板，保存后自动热重载。

### 设置窗口

菜单栏 → **设置…** 打开设置窗口，覆盖全部配置项：布局间距/列宽、动画、焦点环、合成器、忽略的 App、快捷键（按下即录入）、**语言**（默认跟随 macOS 系统语言，内置简体中文与英文）。改动即时写回 `config.toml` 并热重载生效，没有"保存"按钮；手改配置文件依然完全支持，外部改动会同步回开着的窗口。注意：从设置窗口保存会按规范格式重写整个文件，值全部保留，但你手写的注释可能被替换为默认注释。

手动配置：

```toml
[general]
language = "system"   # 界面语言：system（跟随 macOS）/ zh-hans / en

[gaps]
inner = 6           # 列间距，可自由调整
outer = 12          # 屏幕外边距
screen_margin = 6   # 停靠列只露细纸边，避免看起来像窗口重叠

[layout]
width_presets = [0.33333, 0.5, 0.66667]
default_width = 0.5
resize_step = 0.05
new_window_side = "right"   # "left" 则新窗口开在焦点列左侧

[animation]
enabled = true
mode = "spring"
# 与 niri horizontal-view-movement 默认值一致：临界阻尼、无回弹
# 连续改目标时会继承当前速度。
damping_ratio = 1.0
stiffness = 800
epsilon = 0.0001
# 兼容固定曲线：mode = "easing" 时使用
# duration_ms = 240
# curve = "ease-out-quint"

[focus_ring]
enabled = true
width = 3          # 蓝紫渐变亮边宽度（1...8）
glow_radius = 9    # 外辉光半径（0...24）

[compositor]
enabled = false     # 合成器级动画（SkyLight）。需关闭 SIP 并注入 Dock，
                    # 见 docs/COMPOSITOR-SETUP.md；payload 未就绪时自动回退 AX

[apps]
ignore = []         # 不接管的 bundle id，如 ["com.apple.systempreferences"]

[bindings]
# 默认键位 + 用户覆盖；可绑定任意已支持的组合，"none" 解绑默认键位。
"alt-left" = "focus-left"
"alt-right" = "focus-right"
"alt-h" = "none"             # 示例：解绑内置 Vim 风格别名
"alt-w" = "cycle-width"      # 示例：增加一个自定义键位
"alt-q" = "none"             # 示例：解绑默认的关窗键
# 动作名：focus-left/right, move-left/right, cycle-width, grow-width,
# shrink-width, toggle-full-width, center-column, toggle-float,
# close-window, retile, none
# 键名补充：equal 即加号键（plus 为其别名），kpplus/kpminus 为数字小键盘加减
```

## 行为约定

- 只接管标准窗口（`AXStandardWindow`）；对话框、面板、PIP、原生全屏一律不碰。
- 尺寸不可调的窗口自动浮动豁免。
- 用户拖动窗口：松手后位置回弹到纸带布局；**手动调宽会被吸收为列宽**（niri 交互式调宽语义）。
- 最小化窗口离开纸带，还原后按「新窗口位置」回到焦点旁。
- Space 切换 / App 隐藏时自动对账（当前 Space 之外的窗口不管理）。
- 退出时窗口保持当前位置，不做恢复。

## 手动 QA 清单

构建后建议走一遍（TextEdit / 终端 / 浏览器开 5+ 窗口）：

1. 启动后既有窗口按从左到右顺序入列，布局立即生效
2. 新开窗口插在焦点列旁（设置里可选左/右）并获得焦点，视口滚动露出
3. `alt-left/right`（或 `alt-h/l`）沿纸带走焦点，跨出视口时发生最小滚动；点击/Cmd-Tab 聚焦停靠列同样触发滚动
4. `alt-shift-h/l` 挪列，焦点跟随
5. `alt-r` 宽度循环；`alt-minus/equal` 连续调宽；`alt-f` 全宽往返；`alt-c` 居中
6. 关闭窗口（`alt-q` 或红点）：列移除，焦点交给右邻
7. 拖动窗口松手回弹；手动拉宽窗口 → 列宽吸收
8. 弹出对话框（如保存面板）不被接管
9. `alt-t` 浮动豁免往返
10. 改配置保存 → 自动重载（gaps 变化立即可见）；菜单栏暂停/恢复
11. 最小化 → 列消失；从 Dock 还原 → 回到纸带
12. 挂起一个 App（`kill -STOP`）：其余窗口操作不被拖死（1s 超时兜底）

## 动画实现说明

AX API 没有原生动画能力（真合成器动画需要关 SIP 注入，本项目不做），动画由 60Hz
缓动插值驱动，几项关键工程手段保证流畅：

- 写操作走 **per-App 并行串行队列**：不同 App 同时动，tick 成本是最慢 App 而非总和
- 纯平移只发 `setPosition`（1 次 RPC），避免 `setFrame` 的三连调用
- 尺寸变化动画开始时一次到位，之后只动位置（连续 resize 会让 App 反复重排）
- 自适应丢帧：慢 App 上一笔未返回就跳过本 tick，自动降帧不拖累他人
- 最后一帧强制精确落位；批量对账（启动/切 Space）直接瞬时布局

个别重排慢的 App（浏览器、Electron）动画帧率天然低于轻量 App，属预期行为；
不喜欢动画可在配置 `[animation]` 中关闭。

### 合成器级动画（可选，需关闭 SIP）

若追求 niri 那种真正丝滑的动画，可走 SkyLight 合成器方案：部分关闭 SIP，把
payload 注入 `Dock.app`，用 Dock 的特权连接以单个 `SLSTransaction` 原子批量移动
窗口——所有窗口同帧一起动，彻底消除 AX 的"逐窗口跳"。

代价与前提请务必先读 [docs/COMPOSITOR-SETUP.md](docs/COMPOSITOR-SETUP.md)：
永久降低系统安全性、每次 macOS 大版本更新后大概率需要重新逆向调试、需要你本人在
恢复模式关 SIP。相关命令：`scrollwm --check-sa`、`sudo scrollwm --load-sa [--force]`。
未就绪时自动回退 AX 动画，不影响正常使用。

## 已知限制

- macOS 不允许窗口完全出屏，停靠列会在屏幕边缘露出 `screen_margin` 宽的边（这也是
  视觉提示，PaperWM 同款行为）
- 副显示器上的窗口不接管；原生 Spaces 之间的纸带状态不保留顺序
- 个别自绘窗口 App（部分 Electron/Java）事件延迟较大，偶尔需要 `alt-shift-r` 手动重排

## 架构速览

```
Sources/ScrollCore/        纯布局引擎（无 AppKit 依赖，可单测）
  Strip.swift              纸带模型：列/焦点/滚动位置 + 全部变换操作
  LayoutEngine.swift       几何：列宽/滚动钳制/最小露出/边缘停靠
Sources/scrollwm/
  AXLayer.swift            AXWindow/AXApplication 封装 + 屏幕坐标转换 + 在屏窗口集
  WindowManager.swift      编排器:事件回路、全量对账、差异下发、回声抑制、拖拽结算
  Hotkeys.swift            Carbon 全局热键（不拦截事件流）
  Config.swift             TOML 解析 + 写回序列化 + 默认模板 + 文件监听热重载
  SettingsUI.swift         SwiftUI 设置窗口（即时写回 config.toml）
  StatusItem.swift         菜单栏逃生门
  AppDelegate.swift        授权引导与装配
Tests/ScrollCoreTests/     引擎单元测试（53 个）
```

参考实现：[AeroSpace](https://github.com/nikitabobko/AeroSpace)（AX 架构）、
[PaperWM.spoon](https://github.com/mogenson/PaperWM.spoon)（卷轴语义与停靠技巧）、
[niri](https://github.com/YaLTeR/niri)（交互范式）。

## 许可证

[GPL-3.0](LICENSE)。
