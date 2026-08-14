#!/usr/bin/env bash
# 编译注入 Dock 的 payload，并组装为 scripting addition（osax）bundle。
#
# 为什么是 osax：macOS 27 上 thread_create_running + KERNEL_SIGNED_PC 的远程线程
# 第一条指令就会 PAC 校验失败（Dock 崩溃，见 Dock-2026-08-14-180121.ips），
# 远程线程注入路线已死。Dock 会在启动时自动 dlopen /Library/ScriptingAdditions 下的
# osax（yabai/BetterTouchTool 同款路径），payload 由 dyld 正常加载，无 PAC 问题。
#
# 产物：dist/ScrollWMSA.osax（--load-sa 会拷到 /Library/ScriptingAdditions）
set -eu

cd "$(dirname "$0")/.."

SRC="Support/CompositorSA/payload.c"
OUT_DIR="dist/ScrollWMSA.osax/Contents/MacOS"
OUT="$OUT_DIR/ScrollWMSA"

mkdir -p "$OUT_DIR"

# Dock 是 arm64e 进程，payload 必须是 arm64e
ARCH="${SCROLLWM_SA_ARCH:-arm64e}"

clang -dynamiclib -arch "$ARCH" \
  -framework Foundation -framework CoreGraphics \
  -I Sources/CClient/include \
  -o "$OUT" "$SRC"

cat > "dist/ScrollWMSA.osax/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.scrollwm.sa</string>
    <key>CFBundleName</key><string>ScrollWMSA</string>
    <key>CFBundleExecutable</key><string>ScrollWMSA</string>
    <key>CFBundlePackageType</key><string>osax</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>OSAXHandlers</key>
    <dict>
        <key>Events</key>
        <dict>
            <key>scwmPing</key>
            <dict>
                <key>Arguments</key>
                <dict/>
                <key>Context</key>
                <string>scrollwm compositor bridge</string>
                <key>Description</key>
                <string>Keep-alive handler for the scrollwm scripting addition.</string>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
EOF

# payload 需与注入器同一自签名身份（SIP 已关时 Dock 对 /Library/ScriptingAdditions 放行）
SIGN_ID="${SCROLLWM_SIGN_ID:--}"
codesign --force --sign "$SIGN_ID" \
  --entitlements Support/scrollwm.entitlements \
  "$OUT" 2>/dev/null || codesign --force --sign "$SIGN_ID" "$OUT"

echo "OSAX=$PWD/dist/ScrollWMSA.osax"
echo "架构=$ARCH  签名=$SIGN_ID"
