#!/usr/bin/env bash
#
# 保持 hook/script.js 与 bridge/script.js 一致。
#
# hook/script.js 是唯一事实来源（GPL 上游脚本 + 本项目版本化适配 + R3）；
# bridge/script.js 是 bridge 运行时从「当前工作目录」读取的副本，两者不一致时
# 会出现「源码改了但真机行为没变」的假象。
#
# 用法：
#   bash scripts/sync_hook_script.sh           # 把 hook/script.js 复制到 bridge/script.js
#   bash scripts/sync_hook_script.sh --check   # 只校验，不一致时退出码 1
#   bash scripts/sync_hook_script.sh --quiet   # 校验/同步成功时不打印
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT_DIR}/hook/script.js"
DST="${ROOT_DIR}/bridge/script.js"

MODE="sync"
QUIET=0

usage() {
  cat <<'EOF'
用法：scripts/sync_hook_script.sh [选项]

选项：
  --check   只校验两个文件是否一致（不一致退出 1），不做修改
  --quiet   成功时不输出
  -h, --help
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --check) MODE="check" ;;
    --quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "未知参数：${arg}" >&2; exit 2 ;;
  esac
done

[[ -f "${SRC}" ]] || { echo "❌ 缺少 ${SRC}（唯一事实来源）" >&2; exit 1; }
[[ -f "${DST}" ]] || { echo "❌ 缺少 ${DST}（bridge 运行时副本）" >&2; exit 1; }

# macOS 自带 shasum；Linux CI 上回退到 sha256sum。
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "❌ 缺少 shasum 或 sha256sum，无法校验脚本副本" >&2
    exit 1
  fi
}

src_sha="$(sha256_file "${SRC}")"
dst_sha="$(sha256_file "${DST}")"

if [[ "${MODE}" == "check" ]]; then
  if [[ "${src_sha}" == "${dst_sha}" ]]; then
    (( QUIET )) || echo "✅ hook/script.js 与 bridge/script.js 一致（${src_sha}）"
    exit 0
  fi
  echo "❌ hook/script.js 与 bridge/script.js 不一致：" >&2
  echo "   hook  : ${src_sha}" >&2
  echo "   bridge: ${dst_sha}" >&2
  echo "   修复  : bash scripts/sync_hook_script.sh" >&2
  exit 1
fi

if [[ "${src_sha}" == "${dst_sha}" ]]; then
  (( QUIET )) || echo "✅ 已一致，无需同步（${src_sha}）"
  exit 0
fi

cp -p "${SRC}" "${DST}"
chmod 644 "${DST}"
dst_sha="$(sha256_file "${DST}")"
[[ "${src_sha}" == "${dst_sha}" ]] || { echo "❌ 同步后校验失败" >&2; exit 1; }
(( QUIET )) || echo "✅ 已同步 bridge/script.js ← hook/script.js（${src_sha}）"
