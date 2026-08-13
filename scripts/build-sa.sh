#!/usr/bin/env bash
# 编译注入 Dock 的 scripting addition payload 为一个可 dlopen 的 bundle。
# 产物：dist/ScrollWMSA.bundle（make-app.sh 会拷进 App 的 Resources）
set -eu

cd "$(dirname "$0")/.."

SRC="Support/CompositorSA/payload.c"
OUT_DIR="dist/ScrollWMSA.bundle/Contents/MacOS"
OUT="$OUT_DIR/ScrollWMSA"

mkdir -p "$OUT_DIR"

# arm64e：注入 Dock（arm64e 进程）要求 payload 也是 arm64e
ARCH="${SCROLLWM_SA_ARCH:-arm64e}"

clang -dynamiclib -arch "$ARCH" \
  -framework Foundation -framework CoreGraphics \
  -I Sources/CClient/include \
  -o "$OUT" "$SRC"

cat > "dist/ScrollWMSA.bundle/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.scrollwm.sa</string>
    <key>CFBundleName</key><string>ScrollWMSA</string>
    <key>CFBundleExecutable</key><string>ScrollWMSA</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
</dict>
</plist>
EOF

# payload 需与注入器同一自签名身份，且带 disable-library-validation 才能被 Dock 加载
SIGN_ID="${SCROLLWM_SIGN_ID:--}"
codesign --force --sign "$SIGN_ID" \
  --entitlements Support/scrollwm.entitlements \
  "$OUT" 2>/dev/null || codesign --force --sign "$SIGN_ID" "$OUT"

echo "SA=$PWD/dist/ScrollWMSA.bundle"
echo "架构=$ARCH  签名=$SIGN_ID"
