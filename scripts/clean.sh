#!/usr/bin/env bash
#
# 清理仓库内可再生的构建产物、缓存与运行日志。
#
# 默认只预览（dry-run），不改动任何文件；确认后加 --yes 执行。
#
# 用法：
#   bash scripts/clean.sh                  # 预览将删除的内容
#   bash scripts/clean.sh --yes            # 清理缓存与产物（保留 dist/）
#   bash scripts/clean.sh --yes --keep-dist
#   bash scripts/clean.sh --yes --all      # 额外删除 Frida Gadget（需重新下载）
#
# 不会触碰源码、hook/versions、assets、docs、_research 与 git 历史。
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSUME_YES=0
KEEP_DIST=0
DEEP=0

say() { printf '%s\n' "$*"; }
fail() { printf '❌ %b\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：scripts/clean.sh [选项]

清理仓库内可再生的构建产物、缓存与运行日志（默认 dry-run）。

选项：
  -y, --yes        执行删除（默认只预览）
  --keep-dist      保留 dist/ 打包产物
  --all            额外删除 hook/gadget/FridaGadget.dylib（需重新下载）
  -h, --help       显示本帮助

清理范围：app/.build*、app/.swiftpm、bridge/onebot、dist/、log/、bridge/log/、
仓库内的 .DS_Store。重新构建见 README「快速开始」。
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --keep-dist) KEEP_DIST=1; shift ;;
    --all) DEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "未知参数：$1" ;;
  esac
done

# ---------- 收集目标 ----------

# 只允许删除仓库根目录之下的路径，避免误删仓库外文件。
safe_path() {
  case "$1" in
    "${ROOT_DIR}"/*) ;;
    *) fail "拒绝操作仓库之外的路径：$1" ;;
  esac
}

TARGETS=()
TARGET_COUNT=0
add_target() {
  [[ -e "$1" ]] || return 0
  safe_path "$1"
  # macOS 自带 bash 3.2 在 set -u 下不允许展开空数组，这里用显式下标 + 计数器。
  TARGETS[TARGET_COUNT]="$1"
  TARGET_COUNT=$((TARGET_COUNT + 1))
}

# 1) SwiftPM 构建缓存（含并行开发用的 .build-* 临时目录）
add_target "${ROOT_DIR}/app/.build"
for path in "${ROOT_DIR}"/app/.build-*; do
  add_target "${path}"
done
add_target "${ROOT_DIR}/app/.swiftpm"

# 2) bridge 可执行文件与调试符号
add_target "${ROOT_DIR}/bridge/onebot"
add_target "${ROOT_DIR}/bridge/onebot.dSYM"

# 3) 打包产物
if (( KEEP_DIST == 0 )); then
  add_target "${ROOT_DIR}/dist"
fi

# 4) 运行日志
add_target "${ROOT_DIR}/log"
add_target "${ROOT_DIR}/bridge/log"

# 5) 可选：运行时依赖（可重新下载）
if (( DEEP == 1 )); then
  add_target "${ROOT_DIR}/hook/gadget/FridaGadget.dylib"
fi

# .DS_Store（遍历整个仓库，跳过 .git）
DS_STORES=()
DS_COUNT=0
while IFS= read -r path; do
  DS_STORES[DS_COUNT]="${path}"
  DS_COUNT=$((DS_COUNT + 1))
done < <(find "${ROOT_DIR}" -name .DS_Store -type f -not -path "${ROOT_DIR}/.git/*" 2>/dev/null || true)

# ---------- 汇总 ----------

total_kb=0
detail=""
if (( TARGET_COUNT > 0 )); then
  for path in "${TARGETS[@]}"; do
    size="$(du -sk "${path}" 2>/dev/null | awk '{print $1}')"
    [[ -n "${size}" ]] || size=0
    total_kb=$((total_kb + size))
    rel="${path#"${ROOT_DIR}"/}"
    detail+="$(printf '  %-44s %s\n' "${rel}" "$(du -sh "${path}" 2>/dev/null | awk '{print $1}')")"$'\n'
  done
fi
if (( DS_COUNT > 0 )); then
  detail+="$(printf '  %-44s %s\n' ".DS_Store ×${DS_COUNT}" "少量")"$'\n'
fi

human_total="$(awk -v kb="${total_kb}" 'BEGIN {
  split("B KB MB GB TB", unit, " ");
  value = kb; i = 2;
  while (value >= 1024 && i < 5) { value /= 1024; i++ }
  printf "%.1f %s", value, unit[i]
}')"

if (( TARGET_COUNT == 0 && DS_COUNT == 0 )); then
  say "✅ 没有需要清理的内容（已保持干净）。"
  exit 0
fi

say "清理范围（${TARGET_COUNT} 个项目录/文件 + ${DS_COUNT} 个 .DS_Store）："
printf '%s' "${detail}"
say "预计回收：${human_total}"

if (( ASSUME_YES == 0 )); then
  say ""
  say "ℹ️  当前为预览模式。确认后执行：bash scripts/clean.sh --yes"
  exit 0
fi

# ---------- 执行 ----------

say ""
if (( TARGET_COUNT > 0 )); then
  for path in "${TARGETS[@]}"; do
    rm -rf -- "${path}"
    say "  ✔ 已删除 ${path#"${ROOT_DIR}"/}"
  done
fi

if (( DS_COUNT > 0 )); then
  for path in "${DS_STORES[@]}"; do
    rm -f -- "${path}"
  done
  say "  ✔ 已删除 ${DS_COUNT} 个 .DS_Store"
fi

say ""
say "✅ 清理完成，回收约 ${human_total}。"
say ""
say "重新构建："
say "  bash scripts/build_bridge.sh   # 生成 bridge/onebot"
say "  bash scripts/build_app.sh      # 生成 dist/WeChat AI.app"
if (( DEEP == 1 )); then
  say "  bash scripts/fetch_gadget.sh   # 重新下载 Frida Gadget"
fi
