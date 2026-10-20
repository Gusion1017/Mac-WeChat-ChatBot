#!/usr/bin/env bash
# Download a pinned Frida Gadget build, verify it, and ad-hoc sign it for local injection.
#
# 固定版本：Frida Gadget 17.8.0（macOS universal）
#   - 压缩包与解压后的 dylib 都校验 SHA256（仅固定版本；覆盖 FRIDA_GADGET_VERSION 时跳过）
#   - 已存在且大于 10MB 时跳过下载，只做架构/签名自检
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${FRIDA_GADGET_VERSION:-17.8.0}"
DEST="$ROOT_DIR/hook/gadget/FridaGadget.dylib"

# 固定版本的校验值（2026-10-21 从官方 release 下载后计算）。
PINNED_VERSION="17.8.0"
PINNED_XZ_SHA256="4cf5433452e745e8b283c7a2e79518c2cd6295e85869589dc3c171d5689e6b8c"
PINNED_DYLIB_SHA256="fa67242fa0cee16e80a803703991e81381cd05f7823a4151515460339c942f9f"

URL="https://github.com/frida/frida/releases/download/${VERSION}/frida-gadget-${VERSION}-macos-universal.dylib.xz"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
fail() { echo "❌ $*" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"

EXISTING=0
if [ -f "$DEST" ] && [ "$(stat -f%z "$DEST")" -gt 10000000 ]; then
  EXISTING=1
  echo "Gadget already present: $DEST"
fi

if (( EXISTING == 0 )); then
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  echo "Downloading Frida Gadget ${VERSION}..."
  curl -L --fail --retry 3 -o "$TMP/gadget.dylib.xz" "$URL"

  if [ "$VERSION" = "$PINNED_VERSION" ]; then
    actual_xz="$(sha256 "$TMP/gadget.dylib.xz")"
    [ "$actual_xz" = "$PINNED_XZ_SHA256" ] \
      || fail "Frida Gadget 压缩包 SHA256 不匹配（期望 ${PINNED_XZ_SHA256}，实际 ${actual_xz}）"
    echo "sha256(archive): ${actual_xz} ✔"
  else
    echo "⚠️  非固定版本 ${VERSION}，跳过 SHA256 校验"
  fi

  xz -d "$TMP/gadget.dylib.xz"

  if [ "$VERSION" = "$PINNED_VERSION" ]; then
    actual_dylib="$(sha256 "$TMP/gadget.dylib")"
    [ "$actual_dylib" = "$PINNED_DYLIB_SHA256" ] \
      || fail "Frida Gadget dylib SHA256 不匹配（期望 ${PINNED_DYLIB_SHA256}，实际 ${actual_dylib}）"
    echo "sha256(dylib)  : ${actual_dylib} ✔"
  fi

  cp "$TMP/gadget.dylib" "$DEST"
fi

chmod +x "$DEST"
/usr/bin/lipo -info "$DEST"
/usr/bin/codesign -f -s - --timestamp=none "$DEST" 2>/dev/null || true
/usr/bin/codesign --verify --strict "$DEST" 2>/dev/null && echo "codesign: ad-hoc OK" || true
echo "sha256: $(sha256 "$DEST")（签名后）"
echo "Frida Gadget ready: $DEST"
