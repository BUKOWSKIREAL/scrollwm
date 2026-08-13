#!/usr/bin/env bash
# 构建并 ad-hoc 签名（固定 identifier，尽量减少重新构建后辅助功能授权失效）
set -eu

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

# 兼容新旧 SwiftPM 构建系统（.build/release 与 .build/out/Products/Release）
BIN="$(swift build -c "$CONFIG" --show-bin-path)/scrollwm"
if [ -n "${SCROLLWM_SIGN_ID:-}" ]; then
  SIGN_ID="$SCROLLWM_SIGN_ID"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "ScrollWM Self-Signed"; then
  SIGN_ID="ScrollWM Self-Signed"
else
  SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" --identifier com.scrollwm.daemon "$BIN"

echo ""
echo "BINARY=$BIN"
echo "首次运行请授予辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能"
