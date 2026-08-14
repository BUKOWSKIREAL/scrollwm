#!/usr/bin/env bash
# 组装并签名 ScrollWM.app（标准菜单栏应用 bundle）
set -eu

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/scrollwm"

APP="dist/ScrollWM.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/scrollwm"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 图标缺失时生成（需要 python3 + PIL；失败不阻断打包）
if [ ! -f Support/Assets.car ] || [ ! -f Support/AppIcon.icns ]; then
  python3 scripts/gen-icon.py || echo "图标生成失败，App 将使用现有/默认图标"
fi
if [ -f Support/AppIcon.icns ]; then
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# 深色外观图标变体（Asset Catalog；icns 不支持深色）
if [ -f Support/Assets.car ]; then
  cp Support/Assets.car "$APP/Contents/Resources/Assets.car"
  # 同时存在 icns 键时系统可能优先用无深色变体的 icns，摘掉让它走 Assets.car
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# 本地化资源包（SwiftPM 生成的 scrollwm_scrollwm.bundle，含 zh-Hans/en 文案）
RES_BUNDLE="$(swift build -c "$CONFIG" --show-bin-path)/scrollwm_scrollwm.bundle"
if [ -d "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/scrollwm_scrollwm.bundle"
fi

# 合成器 payload（可选）：存在则一并打进 App，供 --load-sa 注入 Dock
if [ -d dist/ScrollWMSA.bundle ]; then
  cp -R dist/ScrollWMSA.bundle "$APP/Contents/Resources/ScrollWMSA.bundle"
fi

# 优先用稳定自签名身份，避免每次 ad-hoc 重打后辅助功能授权失效。
SIGN_ID="-"
if [ -n "${SCROLLWM_SIGN_ID:-}" ]; then
  SIGN_ID="$SCROLLWM_SIGN_ID"
elif security find-identity -v -p codesigning 2>/dev/null | grep -F "ScrollWM Self-Signed" >/dev/null; then
  SIGN_ID="ScrollWM Self-Signed"
fi

set +e
codesign --force --deep --options runtime \
  --entitlements Support/scrollwm.entitlements \
  --sign "$SIGN_ID" "$APP"
sign_status=$?
if [ "$sign_status" -ne 0 ]; then
  codesign --force --deep --sign "$SIGN_ID" "$APP"
  sign_status=$?
fi
set -e
if [ "$sign_status" -ne 0 ]; then
  echo "签名失败（身份: $SIGN_ID）" >&2
  exit 1
fi
if [ "$SIGN_ID" = "-" ]; then
  echo "ad-hoc signature: accessibility permission will reset on rebuild"
else
  echo "signed with ${SIGN_ID}; accessibility permission should persist across rebuilds"
fi

echo ""
echo "APP=$PWD/$APP"
echo "建议移入 /Applications 后启动；首次运行到 系统设置 → 隐私与安全性 → 辅助功能 勾选 ScrollWM"
