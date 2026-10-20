#!/usr/bin/env bash
#
# 将 dist/ 中打包好的 WeChat AI.app 安装到用户主目录（默认 ~/Applications）。
#
# 用法：
#   bash scripts/install_app.sh                # 安装到 ~/Applications
#   bash scripts/install_app.sh --dest DIR     # 自定义安装目录
#   bash scripts/install_app.sh --no-resign    # 保留构建时的签名，不重新签名
#
# 前置：先运行 bash scripts/build_app.sh 生成 dist/WeChat AI.app。
# 安装后会移除 quarantine 属性并做 ad-hoc 重签，便于本机直接打开。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="WeChat AI"
SRC="${ROOT_DIR}/dist/${APP_NAME}.app"
DEST_DIR="${HOME}/Applications"
RESIGN=1

say() { printf '%s\n' "$*"; }
fail() { printf '❌ %b\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：scripts/install_app.sh [选项]

把 dist/WeChat AI.app 安装到用户主目录。

选项：
  --dest DIR    安装目录（默认 ~/Applications）
  --no-resign   不重新 ad-hoc 签名（默认复制后重签并校验）
  -h, --help    显示本帮助

示例：
  bash scripts/install_app.sh --dest "$HOME/Applications"
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dest)
      [[ $# -ge 2 && -n "$2" ]] || fail "--dest 需要一个目录"
      DEST_DIR="$2"; shift 2 ;;
    --no-resign) RESIGN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "未知参数：$1" ;;
  esac
done

[[ -d "${SRC}" ]] || fail "未找到 ${SRC}\n  先运行：bash scripts/build_app.sh"
[[ -n "${DEST_DIR}" ]] || fail "安装目录不能为空"
DEST_DIR="${DEST_DIR%/}"
[[ "${DEST_DIR}" != "/" ]] || fail "拒绝安装到根目录"

DEST="${DEST_DIR}/${APP_NAME}.app"
say "source : ${SRC}"
say "target : ${DEST}"

mkdir -p "${DEST_DIR}"
rm -rf -- "${DEST}"
/usr/bin/ditto "${SRC}" "${DEST}" || fail "复制失败：${SRC} → ${DEST}"
/usr/bin/xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

if (( RESIGN == 1 )); then
  say "重新 ad-hoc 签名…"
  /usr/bin/codesign -f -s - --timestamp=none "${DEST}"
fi
/usr/bin/codesign --verify --strict "${DEST}" || fail "签名校验失败：${DEST}"

say "✅ 已安装：${DEST}"
say "打开：open \"${DEST}\""
