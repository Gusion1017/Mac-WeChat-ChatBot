#!/usr/bin/env bash
# Progress-emitting wrapper used by the SwiftUI app (HookManager).
#
#   install_gadget.sh --wechat-path /Applications/WeChat.app \
#                     --gadget <FridaGadget.dylib> \
#                     --config <FridaGadget.config> \
#                     --backup-dir <dir> [--force] [--json]
#
# Output protocol (stdout):
#   default:  [stage]<0-1>|<message>
#   --json:   {"progress":0.42,"stage":"..."}
# Final line: OK or ERROR:<message> (exit code 0 / non-zero).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="/Applications/WeChat.app"
GADGET="$ROOT_DIR/hook/gadget/FridaGadget.dylib"
CONFIG="$ROOT_DIR/hook/gadget/FridaGadget.config"
BACKUP_DIR="${HOME}/Library/Application Support/WeChatAI/backups"
FORCE=0
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --wechat-path) APP="$2"; shift 2 ;;
    --gadget) GADGET="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
  esac
done

stage() {
  local progress="$1"; shift
  local message="$*"
  if [ "$JSON" -eq 1 ]; then
    /usr/bin/python3 -c 'import json,sys; print(json.dumps({"progress": float(sys.argv[1]), "stage": sys.argv[2]}, ensure_ascii=False))' "$progress" "$message"
  else
    printf '[stage]%s|%s\n' "$progress" "$message"
  fi
}

fail() {
  echo "ERROR: $*" >&2
  echo "ERROR:$*"
  exit 1
}

[ -d "$APP" ] || fail "wechat app not found: $APP"
[ -f "$GADGET" ] || fail "frida gadget not found: $GADGET"
[ -f "$CONFIG" ] || fail "frida gadget config not found: $CONFIG"
[ -f "$ROOT_DIR/tools/inject_load_dylib.py" ] || fail "injector not found"
[ -f "$ROOT_DIR/tools/manage_wechat.sh" ] || fail "manage_wechat.sh not found"

RUNNING=0
if /usr/bin/pgrep -x WeChat >/dev/null 2>&1; then RUNNING=1; fi
if [ "$APP" = "/Applications/WeChat.app" ] && [ "$RUNNING" -eq 1 ]; then
  fail "微信正在运行，请先完全退出微信（包括菜单栏图标）"
fi

stage 0.03 "检查微信版本与文件"
if [ "$FORCE" -ne 1 ]; then
  V="$(/usr/libexec/PlistBuddy -c 'Print :WeChatBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  B="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$V" != "${WECHAT_SUPPORTED_VERSION:-4.1.15.55}" ] || [ "$B" != "${WECHAT_SUPPORTED_BUILD:-270135}" ]; then
    fail "微信版本不匹配：${V:-?} (${B:-?})，当前适配 4.1.15.55 (270135)"
  fi
fi

stage 0.10 "创建官方微信完整备份（约 650MB，请稍候）"
WECHAT_BACKUP_DIR="$BACKUP_DIR" \
WECHAT_GADGET_SRC="$GADGET" \
WECHAT_GADGET_CONFIG="$CONFIG" \
  /bin/bash "$ROOT_DIR/tools/manage_wechat.sh" backup --app "$APP" --backup-dir "$BACKUP_DIR" >/dev/null

stage 0.52 "注入 Frida Gadget 并重签名（保留沙盒 entitlements）"
INSTALL_ARGS=(install --app "$APP" --backup-dir "$BACKUP_DIR")
if [ "$FORCE" -eq 1 ]; then INSTALL_ARGS+=(--force); fi
WECHAT_BACKUP_DIR="$BACKUP_DIR" \
WECHAT_GADGET_SRC="$GADGET" \
WECHAT_GADGET_CONFIG="$CONFIG" \
  /bin/bash "$ROOT_DIR/tools/manage_wechat.sh" "${INSTALL_ARGS[@]}" >/dev/null

stage 0.90 "校验签名与注入结果"
STATUS_JSON="$(WECHAT_BACKUP_DIR="$BACKUP_DIR" /bin/bash "$ROOT_DIR/tools/manage_wechat.sh" status --app "$APP")"
echo "$STATUS_JSON" > "${TMPDIR:-/tmp}/wechatai-manage-status.json"

if ! echo "$STATUS_JSON" | /usr/bin/grep -q '"gadgetInstalled": true'; then
  fail "注入结果校验失败（未找到 gadget load command）"
fi
if ! echo "$STATUS_JSON" | /usr/bin/grep -q '"signatureValid": true'; then
  fail "重签名校验失败"
fi

stage 1.0 "完成：Gadget 已安装，重启微信后生效"
echo "OK"
