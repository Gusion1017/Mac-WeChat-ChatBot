#!/usr/bin/env bash
# Manage the local WeChat.app Frida Gadget patch.
#
#   manage_wechat.sh status  [--app PATH]
#   manage_wechat.sh backup  [--app PATH]
#   manage_wechat.sh install [--app PATH] [--force]
#   manage_wechat.sh restore [--app PATH]
#
# The installer:
#   1. refuses to touch a running WeChat,
#   2. keeps a full official .app backup (zip) before the first modification,
#   3. injects LC_LOAD_DYLIB for Frida Gadget and copies the gadget next to it,
#   4. re-signs ONLY the main app ad-hoc with its ORIGINAL entitlements
#      (sandbox stays intact; hardened runtime is gone so the gadget can load),
#   5. verifies signature + load command.
#
# No sudo is required because /Applications/WeChat.app is owned by the current
# user on this machine. The script intentionally never deletes anything outside
# the target .app path and the backup directory.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/WeChat.app"
GADGET_SRC="${WECHAT_GADGET_SRC:-$ROOT_DIR/hook/gadget/FridaGadget.dylib}"
CONFIG_SRC="${WECHAT_GADGET_CONFIG:-$ROOT_DIR/hook/gadget/FridaGadget.config}"
INJECTOR="$ROOT_DIR/tools/inject_load_dylib.py"
BACKUP_ROOT="${WECHAT_BACKUP_DIR:-$HOME/Library/Application Support/WeChatAI/backups}"
SUPPORTED_VERSION="${WECHAT_SUPPORTED_VERSION:-4.2.0.9}"
SUPPORTED_BUILD="${WECHAT_SUPPORTED_BUILD:-270345}"
# 已知可用版本（version:build），首个为默认目标。未显式设置 WECHAT_SUPPORTED_VERSION/BUILD 时，
# 历史版本仍可安装，避免新增默认版本后旧版向导/Hook 安装被误拒。
KNOWN_VERSION_PAIRS="4.2.0.9:270345 4.2.0.5:270341 4.1.15.55:270135 4.1.12.53:269365"
LOAD_PATH="@executable_path/../Frameworks/FridaGadget.dylib"

ACTION="${1:-status}"
shift || true
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --backup-dir) BACKUP_ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

PLIST="$APP/Contents/Info.plist"
MAIN_EXE="$APP/Contents/MacOS/WeChat"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "[wechat-hook] $*" >&2; }

bundle_version() {
  /usr/libexec/PlistBuddy -c 'Print :WeChatBundleVersion' "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null
}
bundle_build() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null
}

version_is_known_supported() {
  local v="$1" b="$2" pair
  for pair in $KNOWN_VERSION_PAIRS; do
    [ "${pair%%:*}" = "$v" ] || continue
    [ "${pair##*:}" = "$b" ] && return 0
  done
  return 1
}
is_running() {
  /usr/bin/pgrep -x WeChat >/dev/null 2>&1
}
gadget_installed() {
  [ -f "$MAIN_EXE" ] || return 1
  /usr/bin/otool -L "$MAIN_EXE" 2>/dev/null | /usr/bin/grep -Fq "FridaGadget.dylib"
}
backup_path() {
  local v b
  v="$(bundle_version || true)"; b="$(bundle_build || true)"
  echo "$BACKUP_ROOT/WeChat-${v:-unknown}-${b:-unknown}-official.zip"
}
entitlements_path() {
  local v b
  v="$(bundle_version || true)"; b="$(bundle_build || true)"
  echo "$BACKUP_ROOT/WeChat-${v:-unknown}-${b:-unknown}-entitlements.plist"
}

print_status() {
  /usr/bin/python3 - "$APP" "$GADGET_SRC" "$BACKUP_ROOT" "$SUPPORTED_VERSION" "$SUPPORTED_BUILD" <<'PY'
import json, os, plistlib, subprocess, sys

app, gadget_src, backup_root, supported_version, supported_build = sys.argv[1:6]
plist = os.path.join(app, "Contents", "Info.plist")
main = os.path.join(app, "Contents", "MacOS", "WeChat")
gadget = os.path.join(app, "Contents", "Frameworks", "FridaGadget.dylib")
version = build = ""
if os.path.exists(plist):
    try:
        with open(plist, "rb") as f:
            info = plistlib.load(f)
        version = info.get("WeChatBundleVersion") or info.get("CFBundleShortVersionString") or ""
        build = str(info.get("CFBundleVersion") or "")
    except Exception:
        pass

def run(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return out.stdout + out.stderr
    except Exception as exc:
        return str(exc)

running = subprocess.run(["/usr/bin/pgrep", "-x", "WeChat"], capture_output=True).returncode == 0
load = run(["/usr/bin/otool", "-L", main]) if os.path.exists(main) else ""
installed = "FridaGadget.dylib" in load and os.path.exists(gadget)
verify = run(["/usr/bin/codesign", "--verify", "--strict", app]) if os.path.exists(app) else ""
signature_valid = os.path.exists(app) and "valid on disk" not in verify and "code object is not signed" not in verify
# codesign --verify prints nothing on success
signature_valid = os.path.exists(app) and verify.strip() == ""
dv = run(["/usr/bin/codesign", "-dv", "--verbose=2", app])
sandbox = "app-sandbox" in run(["/usr/bin/codesign", "-d", "--entitlements", "-", app])
team = ""
for line in dv.splitlines():
    if line.startswith("TeamIdentifier="):
        team = line.split("=", 1)[1]
backup = os.path.join(backup_root, f"WeChat-{version}-{build}-official.zip") if version and build else ""
payload = {
    "app": app,
    "exists": os.path.exists(app),
    "version": version,
    "build": build,
    "supportedVersion": supported_version,
    "supportedBuild": supported_build,
    "matched": version == supported_version and build == supported_build,
    "running": running,
    "gadgetInstalled": installed,
    "gadgetPresent": os.path.exists(gadget),
    "gadgetSourcePresent": os.path.exists(gadget_src),
    "signatureValid": signature_valid,
    "sandboxEntitled": sandbox,
    "teamIdentifier": team,
    "backupPath": backup,
    "backupExists": bool(backup and os.path.exists(backup) and os.path.getsize(backup) > 0),
    "loadCommand": [l.strip() for l in load.splitlines() if "FridaGadget" in l],
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

ensure_backup() {
  mkdir -p "$BACKUP_ROOT"
  local backup ent
  backup="$(backup_path)"
  ent="$(entitlements_path)"
  if [ ! -s "$backup" ]; then
    note "creating full backup: $backup"
    local tmp="$backup.part"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$tmp"
    mv "$tmp" "$backup"
    note "backup size: $(du -h "$backup" | awk '{print $1}')"
  else
    note "backup exists: $backup"
  fi
  if [ ! -s "$ent" ]; then
    /usr/bin/codesign -d --entitlements :- "$APP" > "$ent" 2>/dev/null || true
    if [ ! -s "$ent" ]; then
      # Some codesign builds need the plist redirected from stderr.
      /usr/bin/codesign -d --entitlements - "$APP" > "$ent" 2>/dev/null || true
    fi
  fi
  [ -s "$backup" ] || die "backup was not created"
}

do_backup() {
  [ -d "$APP" ] || die "WeChat.app not found: $APP"
  ensure_backup
  echo "Backup: $(backup_path)"
}

do_install() {
  [ -d "$APP" ] || die "WeChat.app not found: $APP"
  [ -x "$MAIN_EXE" ] || die "WeChat executable not found: $MAIN_EXE"
  [ -f "$GADGET_SRC" ] || die "Frida Gadget missing: $GADGET_SRC (run scripts/fetch_gadget.sh)"
  [ -f "$CONFIG_SRC" ] || die "Frida Gadget config missing: $CONFIG_SRC"
  [ -f "$INJECTOR" ] || die "Mach-O injector missing: $INJECTOR"

  if [ "$APP" = "/Applications/WeChat.app" ] && is_running; then
    die "WeChat is running. Quit WeChat completely, then retry."
  fi

  local v b
  v="$(bundle_version || true)"; b="$(bundle_build || true)"
  if [ "$v" != "$SUPPORTED_VERSION" ] || [ "$b" != "$SUPPORTED_BUILD" ]; then
    if [ -z "${WECHAT_SUPPORTED_VERSION:-}" ] && [ -z "${WECHAT_SUPPORTED_BUILD:-}" ] \
      && version_is_known_supported "$v" "$b"; then
      note "installing on known supported historical WeChat $v ($b)"
    elif [ "$FORCE" -ne 1 ]; then
      die "unsupported WeChat version ${v:-?} (${b:-?}); expected ${SUPPORTED_VERSION} (${SUPPORTED_BUILD}) or a known pair in: ${KNOWN_VERSION_PAIRS}. Set WECHAT_SUPPORTED_VERSION/WECHAT_SUPPORTED_BUILD or use --force to override."
    else
      note "WARNING: forcing install on unsupported version $v ($b)"
    fi
  fi

  ensure_backup

  local ent
  ent="$(entitlements_path)"
  note "installing Frida Gadget into $APP"
  mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources"
  /usr/bin/ditto "$GADGET_SRC" "$APP/Contents/Frameworks/FridaGadget.dylib"
  chmod +x "$APP/Contents/Frameworks/FridaGadget.dylib"
  # A plain JSON file directly under Frameworks is treated as nested code by
  # codesign. Keep the real config in Resources (sealed as a resource) and place
  # a relative symlink next to the gadget, which is where Frida looks for it.
  /usr/bin/ditto "$CONFIG_SRC" "$APP/Contents/Resources/FridaGadget.config"
  rm -f "$APP/Contents/Frameworks/FridaGadget.config"
  ln -s "../Resources/FridaGadget.config" "$APP/Contents/Frameworks/FridaGadget.config"
  /usr/bin/codesign -f -s - --timestamp=none "$APP/Contents/Frameworks/FridaGadget.dylib"

  if ! gadget_installed; then
    /usr/bin/python3 "$INJECTOR" "$MAIN_EXE" "$LOAD_PATH"
  else
    note "load command already present"
  fi

  # Re-sign only the main app; keep the original entitlements (sandbox stays on),
  # but drop the hardened runtime flags so the injected dylib can be loaded.
  if [ -s "$ent" ]; then
    /usr/bin/codesign -f -s - --timestamp=none --entitlements "$ent" "$APP"
  else
    note "WARNING: original entitlements unavailable; signing without entitlements"
    /usr/bin/codesign -f -s - --timestamp=none "$APP"
  fi

  /usr/bin/codesign --verify --strict "$APP" || die "signature verification failed after install"
  gadget_installed || die "load command injection failed"
  note "disabling Sparkle automatic update checks (best effort)"
  /usr/bin/defaults write com.tencent.xinWeChat SUEnableAutomaticChecks -bool false 2>/dev/null || true
  /usr/bin/defaults write com.tencent.xinWeChat SUAutomaticallyUpdate -bool false 2>/dev/null || true

  note "OK. Launch WeChat, then start the bridge."
  print_status
}

do_restore() {
  [ -d "$APP" ] || die "WeChat.app not found: $APP"
  if [ "$APP" = "/Applications/WeChat.app" ] && is_running; then
    die "WeChat is running. Quit WeChat completely, then retry."
  fi
  local backup
  backup="$(backup_path)"
  [ -s "$backup" ] || die "no backup found: $backup"
  note "restoring official WeChat from $backup"
  rm -rf "$APP"
  /usr/bin/ditto -x -k "$backup" "$(dirname "$APP")"
  /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  /usr/bin/codesign --verify --strict "$APP" || die "restored app failed signature verification"
  note "restore complete: official signature is back."
  print_status
}

case "$ACTION" in
  status) print_status ;;
  backup) do_backup ;;
  install) do_install ;;
  restore) do_restore ;;
  *) die "unknown action: $ACTION (status|backup|install|restore)" ;;
esac
