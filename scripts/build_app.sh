#!/usr/bin/env bash
# Build the native SwiftUI app and package it as a self-contained .app bundle.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="WeChat AI"
BUNDLE_ID="com.gusionw.wechatai"
DIST_DIR="$ROOT_DIR/dist"
BUNDLE="$DIST_DIR/$APP_NAME.app"
SCRATCH="$ROOT_DIR/app/.build-release"

say() { echo "[build-app] $*" >&2; }
fail() { echo "[build-app] ERROR: $*" >&2; exit 1; }

command -v swift >/dev/null || fail "swift toolchain not found"
[ -d "$ROOT_DIR/app" ] || fail "app/ directory missing"

# SwiftPM 的 manifest 沙箱会调用 sandbox_apply；在受限沙箱（CI / Agent）内会失败。
# 需要时用 SWIFT_DISABLE_SANDBOX=1 关闭它。
SWIFT_EXTRA_FLAGS=""
if [ "${SWIFT_DISABLE_SANDBOX:-0}" = "1" ]; then
  SWIFT_EXTRA_FLAGS="--disable-sandbox"
  say "SwiftPM sandbox disabled (SWIFT_DISABLE_SANDBOX=1)"
fi

say "compiling SwiftUI app (release)"
cd "$ROOT_DIR/app"
swift build -c release --scratch-path "$SCRATCH" $SWIFT_EXTRA_FLAGS
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path $SWIFT_EXTRA_FLAGS)"
EXECUTABLE="$BIN_DIR/WeChatAI"
[ -x "$EXECUTABLE" ] || fail "executable not produced: $EXECUTABLE"

say "assembling $APP_NAME.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$EXECUTABLE" "$BUNDLE/Contents/MacOS/WeChatAI"
cp "$ROOT_DIR/app/Packaging/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/assets/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"

# UI strings for the in-app language switch (English + Chinese identity table).
for lang in en zh-Hans; do
  strings="$ROOT_DIR/app/Packaging/$lang.lproj/Localizable.strings"
  if [ -f "$strings" ]; then
    mkdir -p "$BUNDLE/Contents/Resources/$lang.lproj"
    cp "$strings" "$BUNDLE/Contents/Resources/$lang.lproj/Localizable.strings"
  fi
done

# Runtime resources (bridge + hook + installer).
RES="$BUNDLE/Contents/Resources"
mkdir -p "$RES/bridge" "$RES/hook/versions" "$RES/hook/gadget" "$RES/tools"
if [ -f "$ROOT_DIR/bridge/onebot" ]; then
  cp "$ROOT_DIR/bridge/onebot" "$RES/bridge/onebot"
  chmod +x "$RES/bridge/onebot"
  /usr/bin/codesign -f -s - --timestamp=none "$RES/bridge/onebot" 2>/dev/null || true
else
  say "WARNING: bridge/onebot missing; app will not be able to start the bot until built"
fi
# hook/script.js 是唯一事实来源(GPL 上游脚本 + 本项目版本化适配 + R3);
# bridge 从当前目录读取 script.js, 因此以 hook/script.js 为准, 旧路径保留兜底。
if [ -f "$ROOT_DIR/hook/script.js" ]; then
  cp "$ROOT_DIR/hook/script.js" "$RES/bridge/script.js"
elif [ -f "$ROOT_DIR/bridge/script.js" ]; then
  cp "$ROOT_DIR/bridge/script.js" "$RES/bridge/script.js"
fi
if compgen -G "$ROOT_DIR/hook/versions/*.json" >/dev/null; then
  cp "$ROOT_DIR"/hook/versions/*.json "$RES/hook/versions/"
else
  say "WARNING: no hook version JSON found; hook install will be unavailable"
fi
if [ -f "$ROOT_DIR/hook/gadget/FridaGadget.dylib" ]; then
  cp "$ROOT_DIR/hook/gadget/FridaGadget.dylib" "$RES/hook/gadget/FridaGadget.dylib"
  chmod +x "$RES/hook/gadget/FridaGadget.dylib"
  /usr/bin/codesign -f -s - --timestamp=none "$RES/hook/gadget/FridaGadget.dylib" 2>/dev/null || true
else
  say "WARNING: FridaGadget.dylib missing; run scripts/fetch_gadget.sh"
fi
cp "$ROOT_DIR/hook/gadget/FridaGadget.config" "$RES/hook/gadget/FridaGadget.config"
cp "$ROOT_DIR/tools/inject_load_dylib.py" "$RES/tools/inject_load_dylib.py"
cp "$ROOT_DIR/tools/manage_wechat.sh" "$RES/tools/manage_wechat.sh"
cp "$ROOT_DIR/tools/install_gadget.sh" "$RES/tools/install_gadget.sh"
chmod +x "$RES/tools/manage_wechat.sh" "$RES/tools/install_gadget.sh"
cp "$ROOT_DIR/LICENSE" "$RES/LICENSE" 2>/dev/null || true
cp "$ROOT_DIR/ThirdPartyNotices.txt" "$RES/ThirdPartyNotices.txt" 2>/dev/null || true
# GPL 合规：bridge 是上游衍生，随包附带 NOTICE 与上游许可证。
cp "$ROOT_DIR/bridge/NOTICE" "$RES/bridge/NOTICE" 2>/dev/null || true
cp "$ROOT_DIR/bridge/LICENSE" "$RES/bridge/LICENSE" 2>/dev/null || true

# 旧版 bridge 会在运行期把日志写进 Contents/Resources/bridge/log/，破坏 ad-hoc
# 签名并导致下次启动被系统杀掉。新版日志外置到 ~/Library/Logs/WeChatAI/bridge/，
# 打包时绝不能把本地调试残留的 log/ 带进 bundle。
rm -rf "$RES/bridge/log"

# Icon sanity (macOS uses AppIcon.icns declared in Info.plist).
[ -s "$RES/AppIcon.icns" ] || say "WARNING: AppIcon.icns missing"

say "ad-hoc signing app bundle"
/usr/bin/xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
/usr/bin/codesign -f -s - --timestamp=none "$BUNDLE"
/usr/bin/codesign --verify --strict "$BUNDLE" || fail "signature verification failed"

say "built: $BUNDLE"
/usr/bin/du -sh "$BUNDLE"
