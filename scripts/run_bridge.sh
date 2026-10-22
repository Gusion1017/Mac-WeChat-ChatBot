#!/usr/bin/env bash
#
# 手动运行 OneBot bridge（开发/排查用；App 会直接启动 bridge/onebot）。
#
# 从 bridge/ 作为当前工作目录启动（onebot 会读取 ./script.js），
# 并监听 127.0.0.1:<PORT>。HTTP 发送接口要求
#   Authorization: Bearer <TOKEN>
#
# 可用环境变量（命令行参数优先）：
#   WECHAT_CONF  Hook 版本 JSON，默认 <repo>/hook/versions/4_2_0_5_mac.json
#   PORT         监听端口，默认 58080
#   TOKEN        OneBot token；为空时随机生成 32 字节 hex 并打印
#   IMAGE_PATH   微信图片临时目录（必填，且必须已存在）
#   GADGET_ADDR  Frida Gadget 地址，默认 127.0.0.1:27042
#   LOG_LEVEL    debug|info|warn|error，默认 info
#   BRIDGE_BIN   自定义 onebot 路径，默认 <repo>/bridge/onebot
#
# 示例：
#   IMAGE_PATH="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_xxx/temp/2026-10/Img/" \
#     scripts/run_bridge.sh
#
#   scripts/run_bridge.sh --port 58081 --token "$(openssl rand -hex 32)" \
#     --wechat-conf hook/versions/4_2_0_5_mac.json \
#     --image-path "/path/to/xwechat_files/wxid_xxx/temp/2026-10/Img/"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BRIDGE_DIR="${ROOT_DIR}/bridge"

WECHAT_CONF="${WECHAT_CONF:-${ROOT_DIR}/hook/versions/4_2_0_5_mac.json}"
PORT="${PORT:-58080}"
TOKEN="${TOKEN:-}"
IMAGE_PATH="${IMAGE_PATH:-}"
GADGET_ADDR="${GADGET_ADDR:-127.0.0.1:27042}"
LOG_LEVEL="${LOG_LEVEL:-info}"
BRIDGE_BIN="${BRIDGE_BIN:-${BRIDGE_DIR}/onebot}"
TOKEN_GENERATED=0
# 安全默认：即使 Hook 版本 JSON / script.js 允许发送，也强制关闭 4.1.15 主动发送。
# 真机验证 mode C 时显式传 HOOK_SEND_DISABLED=false 覆盖。
HOOK_SEND_DISABLED="${HOOK_SEND_DISABLED:-true}"
export HOOK_SEND_DISABLED

fail() { printf '❌ %b\n' "$*" >&2; exit 1; }
warn() { printf '⚠️  %b\n' "$*" >&2; }

usage() {
  cat <<'EOF'
用法：scripts/run_bridge.sh [选项]

选项：
  --wechat-conf <path>  Hook 版本 JSON（默认 hook/versions/4_2_0_5_mac.json）
  --port <port>         监听端口（默认 58080，仅绑定 127.0.0.1）
  --token <token>       OneBot token（默认随机生成 64 字符 hex）
  --image-path <dir>    微信图片临时目录（必填，必须已存在）
  --gadget-addr <addr>  Frida Gadget 地址（默认 127.0.0.1:27042）
  --log-level <level>   debug|info|warn|error（默认 info）
  --bin <path>          onebot 可执行文件（默认 bridge/onebot）
  -h, --help            显示本帮助

对应环境变量：WECHAT_CONF、PORT、TOKEN、IMAGE_PATH、GADGET_ADDR、
LOG_LEVEL、BRIDGE_BIN、HOOK_SEND_DISABLED（默认 true，强制关闭主动发送）。
命令行参数优先于环境变量。
EOF
}

expand_tilde() {
  case "$1" in
    "~/"*) printf '%s/%s' "${HOME}" "${1#\~/}" ;;
    "~") printf '%s' "${HOME}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# 基于调用时的工作目录转为绝对路径（bridge 启动前会 cd 到自己的目录）。
abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$(pwd)" "$1" ;;
  esac
}

while (( $# > 0 )); do
  case "$1" in
    --wechat-conf)
      [[ $# -ge 2 ]] || fail "$1 需要一个路径"
      WECHAT_CONF="$2"; shift 2 ;;
    --port)
      [[ $# -ge 2 ]] || fail "$1 需要一个端口"
      PORT="$2"; shift 2 ;;
    --token)
      [[ $# -ge 2 ]] || fail "$1 需要一个值"
      TOKEN="$2"; shift 2 ;;
    --image-path)
      [[ $# -ge 2 ]] || fail "$1 需要一个目录"
      IMAGE_PATH="$2"; shift 2 ;;
    --gadget-addr)
      [[ $# -ge 2 ]] || fail "$1 需要一个地址"
      GADGET_ADDR="$2"; shift 2 ;;
    --log-level)
      [[ $# -ge 2 ]] || fail "$1 需要一个级别"
      LOG_LEVEL="$2"; shift 2 ;;
    --bin)
      [[ $# -ge 2 ]] || fail "$1 需要一个路径"
      BRIDGE_BIN="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      usage >&2
      fail "未知参数：$1" ;;
  esac
done

WECHAT_CONF="$(expand_tilde "${WECHAT_CONF}")"
WECHAT_CONF="$(abs_path "${WECHAT_CONF}")"
IMAGE_PATH="$(expand_tilde "${IMAGE_PATH}")"
if [[ -n "${IMAGE_PATH}" ]]; then
  IMAGE_PATH="$(abs_path "${IMAGE_PATH}")"
fi
BRIDGE_BIN="$(expand_tilde "${BRIDGE_BIN}")"
BRIDGE_BIN="$(abs_path "${BRIDGE_BIN}")"
BRIDGE_DIR="$(cd "$(dirname "${BRIDGE_BIN}")" 2>/dev/null && pwd)" \
  || fail "无法定位 onebot 所在目录：${BRIDGE_BIN}"

# ---------- 前置检查 ----------

[[ -x "${BRIDGE_BIN}" ]] || fail "未找到可执行文件：${BRIDGE_BIN}\n  先运行 scripts/build_bridge.sh"
[[ -f "${BRIDGE_DIR}/script.js" ]] || fail "缺少 ${BRIDGE_DIR}/script.js；onebot 从当前工作目录读取它，必须与 onebot 同目录。"
[[ -f "${WECHAT_CONF}" ]] || fail "Hook 版本配置不存在：${WECHAT_CONF}\n  该文件由 hook 成员/App 生成；默认期望 hook/versions/4_2_0_5_mac.json。"
[[ -n "${IMAGE_PATH}" ]] || fail "缺少 IMAGE_PATH。\n  指向微信容器目录：.../xwechat_files/<wxid>/temp/<...>/Img/（App 负责探测/创建）。"
[[ -d "${IMAGE_PATH}" ]] || fail "IMAGE_PATH 不存在或不是目录：${IMAGE_PATH}\n  请先确认微信已运行并创建该临时目录；App 侧会做同样检查。"

if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  fail "PORT 非法：${PORT}（必须是 1-65535 的整数）"
fi

for level in debug info warn error; do
  if [[ "${LOG_LEVEL}" == "${level}" ]]; then LOG_LEVEL_OK=1; fi
done
[[ "${LOG_LEVEL_OK:-0}" == "1" ]] || fail "LOG_LEVEL 非法：${LOG_LEVEL}（可选 debug|info|warn|error）"

if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "端口 127.0.0.1:${PORT} 已被占用。先停止已有 bridge，或使用 --port 指定其他端口。"
fi

if [[ -z "${TOKEN}" ]]; then
  TOKEN="$(openssl rand -hex 32)" || fail "生成随机 token 失败（缺少 openssl）。请通过 --token 提供。"
  TOKEN_GENERATED=1
fi
(( ${#TOKEN} >= 16 )) || warn "TOKEN 只有 ${#TOKEN} 个字符；建议至少 32 字符（App 默认生成 64 字符 hex）。"

# ---------- 启动 ----------

if [[ "${TOKEN_GENERATED}" == "1" ]]; then
  token_display="${TOKEN}"
  token_note="（本次随机生成；App 设置里必须填同一个 token）"
else
  token_display="${TOKEN:0:6}…${TOKEN: -4}"
  token_note="（已提供，含前后 6/4 位）"
fi

cat <<EOF
bridge : ${BRIDGE_BIN}
cwd    : ${BRIDGE_DIR}
listen : 127.0.0.1:${PORT} (WS /ws, HTTP /send_private_msg, /send_group_msg)
gadget : ${GADGET_ADDR}
conf   : ${WECHAT_CONF}
image  : ${IMAGE_PATH}
token  : ${token_display} ${token_note}
send   : HOOK_SEND_DISABLED=${HOOK_SEND_DISABLED}（true=强制关闭主动发送；false=由 Hook/JSON 决定）
log    : ${BRIDGE_DIR}/log/macos.log（轮转 100MB×10，保留 30 天）
EOF

cd "${BRIDGE_DIR}"
exec "${BRIDGE_BIN}" \
  -type=gadget \
  -gadget_addr="${GADGET_ADDR}" \
  -wechat_conf="${WECHAT_CONF}" \
  -receive_host="127.0.0.1:${PORT}" \
  -token="${TOKEN}" \
  -conn_type=websocket \
  -image_path="${IMAGE_PATH}" \
  -log_level="${LOG_LEVEL}"
