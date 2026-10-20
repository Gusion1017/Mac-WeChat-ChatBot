#!/usr/bin/env bash
#
# 本地质量门禁：一条命令跑完「脚本语法 + hook/bridge 脚本一致性 + 文档链接 + Swift 测试」。
#
# 用法：
#   bash scripts/check.sh              # 快速检查（约 10s，需已构建过 SwiftPM 缓存）
#   bash scripts/check.sh --docs       # 只检查文档、脚本与 Hook 副本一致性
#   bash scripts/check.sh --with-go    # 额外构建 bridge 并跑 Go 测试（较慢）
#
# 环境变量：
#   SWIFT_DISABLE_SANDBOX=1  在受限沙箱（CI / Agent）里关闭 SwiftPM 的 manifest 沙箱
#   CHECK_SKIP_SWIFT=1       跳过 Swift 测试（只做静态检查）
#
# 退出码：0 = 全部通过；1 = 有检查失败。
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_ONLY=0
WITH_GO=0

say()  { printf '%s\n' "$*"; }
 section_header() { printf '\n=== %s ===\n' "$*"; }
fail() { printf '❌ %b\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "${arg}" in
    --docs) DOCS_ONLY=1 ;;
    --with-go) WITH_GO=1 ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) fail "未知参数：${arg}（可用：--docs / --with-go / --help）" ;;
  esac
done

FAILED=0
step() { section_header "$*"; }

# ---------- 1. Shell 语法 ----------
if (( DOCS_ONLY == 0 )); then
  step "Shell 脚本语法"
  for script in "${ROOT_DIR}"/scripts/*.sh "${ROOT_DIR}"/tools/*.sh; do
    [[ -f "${script}" ]] || continue
    if bash -n "${script}"; then
      say "  ✔ $(basename "${script}")"
    else
      say "  ✘ $(basename "${script}")"
      FAILED=1
    fi
  done
fi

# ---------- 2. hook / bridge script.js 一致性 ----------
step "hook/script.js ↔ bridge/script.js"
if bash "${ROOT_DIR}/scripts/sync_hook_script.sh" --check; then
  :
else
  FAILED=1
fi

# ---------- 3. 文档链接 ----------
step "Markdown 相对链接"
if python3 "${ROOT_DIR}/scripts/check_docs.py"; then
  :
else
  FAILED=1
fi

# ---------- 4. Hook 版本 JSON 可解析 ----------
step "hook/versions/*.json"
json_ok=1
for json in "${ROOT_DIR}"/hook/versions/*.json; do
  [[ -f "${json}" ]] || continue
  if python3 -m json.tool "${json}" >/dev/null 2>&1; then
    say "  ✔ $(basename "${json}")"
  else
    say "  ✘ $(basename "${json}")"
    json_ok=0
    FAILED=1
  fi
done
(( json_ok )) || true

if (( DOCS_ONLY == 1 )); then
  step "结果"
  if (( FAILED == 0 )); then say "✅ 静态检查全部通过"; else say "❌ 有检查失败"; fi
  exit "${FAILED}"
fi

# ---------- 5. Swift 测试 ----------
if [[ "${CHECK_SKIP_SWIFT:-0}" == "1" ]]; then
  step "Swift 测试（CHECK_SKIP_SWIFT=1，已跳过）"
else
  step "Swift 测试（app/）"
  SWIFT_ARGS=()
  if [[ "${SWIFT_DISABLE_SANDBOX:-0}" == "1" ]]; then
    SWIFT_ARGS+=(--disable-sandbox)
    say "  SwiftPM sandbox disabled (SWIFT_DISABLE_SANDBOX=1)"
  fi
  if ( cd "${ROOT_DIR}/app" && swift test "${SWIFT_ARGS[@]}" 2>&1 | tail -8 ); then
    :
  else
    say "  ✘ swift test 失败"
    FAILED=1
  fi
fi

# ---------- 6. 可选：Go bridge ----------
if (( WITH_GO == 1 )); then
  step "Go bridge（构建 + 测试）"
  if bash "${ROOT_DIR}/scripts/build_bridge.sh"; then
    :
  else
    say "  ✘ build_bridge.sh 失败"
    FAILED=1
  fi
fi

# ---------- 结果 ----------
step "结果"
if (( FAILED == 0 )); then
  say "✅ 全部检查通过"
else
  say "❌ 有检查失败，请先修复再提交"
fi
exit "${FAILED}"
