#!/usr/bin/env bash
#
# 构建并打包可直接上传 GitHub Releases 的 App 压缩包。
#
# 用法：
#   bash scripts/package_release.sh                # 构建 → 打包 → 计算 SHA256
#   bash scripts/package_release.sh --skip-build   # 复用 dist/ 中已有 App
#
# 产物：
#   dist/WeChat-AI-<version>.zip
#   dist/WeChat-AI-<version>.zip.sha256
#
# 前置：
#   bash scripts/fetch_gadget.sh
#   bash scripts/build_bridge.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="WeChat AI"
BUNDLE="$ROOT_DIR/dist/${APP_NAME}.app"
SKIP_BUILD=0

say() { printf '%s\n' "$*"; }
fail() { printf '❌ %b\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "${arg}" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) fail "未知参数：${arg}（可用：--skip-build / --help）" ;;
  esac
done

[[ -f "$ROOT_DIR/hook/gadget/FridaGadget.dylib" ]] \
  || fail "缺少 hook/gadget/FridaGadget.dylib；先运行 bash scripts/fetch_gadget.sh"
[[ -x "$ROOT_DIR/bridge/onebot" ]] \
  || fail "缺少 bridge/onebot；先运行 bash scripts/build_bridge.sh"
[[ -f "$ROOT_DIR/hook/script.js" ]] || fail "缺少 hook/script.js"

if (( SKIP_BUILD == 0 )); then
  bash "$ROOT_DIR/scripts/build_app.sh"
fi

[[ -d "$BUNDLE" ]] || fail "未找到 ${BUNDLE}；先运行 bash scripts/build_app.sh"

for required in \
  "Contents/MacOS/WeChatAI" \
  "Contents/Resources/bridge/onebot" \
  "Contents/Resources/bridge/script.js" \
  "Contents/Resources/hook/gadget/FridaGadget.dylib" \
  "Contents/Resources/LICENSE" \
  "Contents/Resources/bridge/NOTICE"
do
  [[ -e "$BUNDLE/$required" ]] || fail "App 包缺少 ${required}"
done

/usr/bin/codesign --verify --strict "$BUNDLE" || fail "签名校验失败：${BUNDLE}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$ROOT_DIR/app/Packaging/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$ROOT_DIR/app/Packaging/Info.plist")"
ZIP="$ROOT_DIR/dist/WeChat-AI-${VERSION}.zip"

rm -f "$ZIP" "$ZIP.sha256"
say "打包 ${APP_NAME}.app（version ${VERSION}, build ${BUILD}）…"
/usr/bin/ditto -c -k --norsrc --keepParent "$BUNDLE" "$ZIP"
( cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

say ""
say "✅ 已生成："
say "  ${ZIP}  ($(du -h "$ZIP" | awk '{print $1}'))"
say "  ${ZIP}.sha256"
say ""
say "SHA256："
cat "$ZIP.sha256"
say ""
say "下一步：把 zip 与 .sha256 上传到 GitHub Releases，并在说明中写清"
say "  - 支持 Apple Silicon / macOS 26+ / 微信 4.2.0.5、4.1.15.55 或 4.1.12.53"
say "  - ad-hoc 签名、未公证；首次需右键打开或移除 quarantine"
say "  - 安装 Hook 会修改微信，存在账号风控与签名失效风险"
say "  - 按 GPL-3.0 提供对应源码（仓库地址）"
