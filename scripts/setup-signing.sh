#!/usr/bin/env bash
# 创建一个稳定的自签名代码签名身份，让重新构建后辅助功能授权不再失效。
#
# 原理：macOS 的辅助功能（TCC）授权绑定到应用的"代码签名身份"。ad-hoc 签名没有
# 稳定身份，每次重打 CDHash 变化 → 授权失效。用同一张自签名证书持续签名后，
# TCC 认的是证书身份而非哈希，只需首次授权一次，之后重打不掉权限。
#
# 用法：
#   ./scripts/setup-signing.sh          # 创建身份（首次会弹一次钥匙串密码）
#   然后带上环境变量构建：
#   SCROLLWM_SIGN_ID="ScrollWM Self-Signed" ./scripts/make-app.sh
#
# 也可写进 shell 配置：export SCROLLWM_SIGN_ID="ScrollWM Self-Signed"
set -eu

IDENTITY_NAME="ScrollWM Self-Signed"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "签名身份已存在：$IDENTITY_NAME"
  echo "构建时使用： SCROLLWM_SIGN_ID=\"$IDENTITY_NAME\" ./scripts/make-app.sh"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "→ 生成自签名证书..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cfg" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:scrollwm -name "$IDENTITY_NAME" >/dev/null 2>&1

echo "→ 导入登录钥匙串（授权 codesign 使用）..."
security import "$TMP/id.p12" -k "$LOGIN_KEYCHAIN" -P scrollwm -T /usr/bin/codesign

echo "→ 信任该证书用于代码签名（可能需要输入密码）..."
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$TMP/cert.pem" || {
  echo "⚠️  信任设置失败。请打开钥匙串访问，找到 \"$IDENTITY_NAME\"，"
  echo "    双击 → 信任 → 代码签名 设为\"始终信任\"。"
}

echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "完成。签名身份可用：$IDENTITY_NAME"
else
  echo "证书已导入但未被识别为有效签名身份，请按上面提示在钥匙串访问里手动设为\"代码签名: 始终信任\"。"
fi
echo ""
echo "以后这样构建（授权只需一次，重打不再失效）："
echo "  SCROLLWM_SIGN_ID=\"$IDENTITY_NAME\" ./scripts/make-app.sh"
