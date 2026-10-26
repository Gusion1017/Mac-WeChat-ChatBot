#!/usr/bin/env bash
# 启动 CosyVoice3 本地旁路 HTTP 服务（默认 127.0.0.1:5051）。
#
# 默认行为（App 用）：前台 `exec` Python，SIGTERM/SIGINT 直接到达 uvicorn，
# 不 daemonize、不写 pid 文件；stdout/stderr 原样透传给调用方。
#
# 人类/CI 想等健康检查再返回，加 --wait-health：脚本会后台起服务、轮询 /health，
# 打印 COSYVOICE_READY 后转为前台监督（Ctrl-C / SIGTERM 会转发给子进程）。
#
# 用法：
#   scripts/run_cosyvoice.sh [--home DIR] [--host 127.0.0.1] [--port 5051]
#                            [--model-dir DIR] [--venv DIR] [--refs DIR]
#                            [--device cpu|mps|auto] [--threads N]
#                            [--log-level info] [--wait-health] [--require-voices]
#   （同名环境变量：COSYVOICE_HOST / COSYVOICE_PORT / COSYVOICE_MODEL_DIR /
#     COSYVOICE_VENV / COSYVOICE_REFS / COSYVOICE_DEVICE / COSYVOICE_THREADS /
#     COSYVOICE_LOCAL_DIR）
#
# 退出码：0 正常；2 前置检查失败/端口占用；3 脚本层错误（venv/server.py 缺失）
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# App 是 GUI 启动的，PATH 可能不含 Homebrew / anaconda；补齐并保留绝对路径优先
export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/anaconda3/bin:$HOME/.local/bin:$PATH"

find_tool() {
  local name="$1"; shift
  local found
  found="$(command -v "$name" 2>/dev/null || true)"
  if [[ -n "$found" && -x "$found" ]]; then printf '%s' "$found"; return 0; fi
  local cand
  for cand in "$@"; do
    if [[ -x "$cand" ]]; then printf '%s' "$cand"; return 0; fi
  done
  return 1
}

HOME_DIR_ARG=""
VENV_ARG=""
MODEL_DIR_ARG=""
REFS_ARG=""
CV_REPO_ARG=""
HOST="${COSYVOICE_HOST:-127.0.0.1}"
PORT="${COSYVOICE_PORT:-5051}"
DEVICE="${COSYVOICE_DEVICE:-cpu}"
THREADS="${COSYVOICE_THREADS:-0}"
LOG_LEVEL="${COSYVOICE_LOG_LEVEL:-info}"
WAIT_HEALTH="${COSYVOICE_WAIT_HEALTH:-0}"
WAIT_TIMEOUT="${COSYVOICE_WAIT_TIMEOUT:-90}"
# 0 = 零音色也启动（普通用户安装后先起服务，再在 App 内添加音色 → /voices/reload）；
# 1 = 零音色直接报错退出（CI/开发机想 fail-fast 时用 --require-voices）
REQUIRE_VOICES="${COSYVOICE_REQUIRE_VOICES:-0}"

say() { printf '%s\n' "$*" >&2; }
die() { local _code="${2:-2}"; printf 'ERROR: %s\n' "$1" >&2; exit "$_code"; }

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home) HOME_DIR_ARG="${2:?}"; shift 2 ;;
    --host) HOST="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --model-dir) MODEL_DIR_ARG="${2:?}"; shift 2 ;;
    --venv) VENV_ARG="${2:?}"; shift 2 ;;
    --refs) REFS_ARG="${2:?}"; shift 2 ;;
    --repo) CV_REPO_ARG="${2:?}"; shift 2 ;;
    --device) DEVICE="${2:?}"; shift 2 ;;
    --threads) THREADS="${2:?}"; shift 2 ;;
    --log-level) LOG_LEVEL="${2:?}"; shift 2 ;;
    --wait-health) WAIT_HEALTH=1; shift ;;
    --wait-timeout) WAIT_TIMEOUT="${2:?}"; shift 2 ;;
    --no-wait-health) WAIT_HEALTH=0; shift ;;
    --require-voices) REQUIRE_VOICES=1; shift ;;
    --allow-empty-voices) REQUIRE_VOICES=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（--help 查看用法）" 3 ;;
  esac
done

LOCAL_DIR="${HOME_DIR_ARG:-${COSYVOICE_HOME:-${COSYVOICE_LOCAL_DIR:-$REPO_ROOT/_local/cosyvoice}}}"
VENV="${VENV_ARG:-${COSYVOICE_VENV:-$LOCAL_DIR/venv}}"
MODEL_DIR="${MODEL_DIR_ARG:-${COSYVOICE_MODEL_DIR:-$LOCAL_DIR/models/Fun-CosyVoice3-0.5B-2512}}"
REFS="${REFS_ARG:-${COSYVOICE_REFS:-$LOCAL_DIR/voices}}"
CV_REPO="${CV_REPO_ARG:-${COSYVOICE_REPO:-$LOCAL_DIR/repo}}"
PY="$VENV/bin/python"
CV_DEVTOOLS="${COSYVOICE_SERVER_DIR:-$REPO_ROOT/devtools/cosyvoice}"
# 打包版 App：脚本与 server.py 同目录（Contents/Resources/cosyvoice/），
# 手动在 bundle 里运行时也能找到，不依赖 App 注入 COSYVOICE_SERVER_DIR。
if [[ ! -f "$CV_DEVTOOLS/server.py" && -f "$SCRIPT_DIR/server.py" ]]; then
  CV_DEVTOOLS="$SCRIPT_DIR"
fi
SERVER="$CV_DEVTOOLS/server.py"
CURL_BIN="$(find_tool curl /usr/bin/curl /opt/homebrew/bin/curl || true)"

# ---------------------------- 前置检查（人类可读错误） ---------------------------- #
if [[ ! -x "$PY" ]]; then
  die "找不到 Python：$PY
CosyVoice3 还没安装。先运行：scripts/install_cosyvoice.sh" 3
fi
if [[ ! -f "$SERVER" ]]; then
  die "找不到服务脚本：${SERVER}（仓库不完整？）" 3
fi
if [[ ! -d "$MODEL_DIR" ]]; then
  die "模型目录不存在：$MODEL_DIR
先运行：scripts/install_cosyvoice.sh   （约 5.4GB 下载）" 2
fi
missing=()
for f in llm.pt flow.pt hift.pt speech_tokenizer_v3.onnx campplus.onnx cosyvoice3.yaml; do
  [[ -f "$MODEL_DIR/$f" ]] || missing+=("$f")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  die "模型文件不全（缺 ${missing[*]}）：$MODEL_DIR
可能没下载完，重跑：scripts/install_cosyvoice.sh" 2
fi
if [[ ! -d "$REFS" ]]; then
  die "音色目录不存在：$REFS
安装不完整，先运行：scripts/install_cosyvoice.sh" 2
fi

# 音色数量：普通用户安装后为 0（App 不内置音色），服务仍应能启动，
# 由用户在 App 音色管理中添加后调用 POST /voices/reload。
VOICE_COUNT="$("$PY" - "$REFS" <<'PY' 2>/dev/null || echo 0
import json, pathlib, sys
refs = pathlib.Path(sys.argv[1])
manifest = refs / "voices.json"
if manifest.is_file():
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        entries = data.get("voices", data) if isinstance(data, dict) else data
        print(len(entries))
        raise SystemExit(0)
    except SystemExit:
        raise
    except Exception:
        pass
print(len([p for p in refs.iterdir() if p.is_dir() and (p / "prompt.wav").is_file()]) if refs.is_dir() else 0)
PY
)"
[[ "$VOICE_COUNT" =~ ^[0-9]+$ ]] || VOICE_COUNT=0
if [[ "$VOICE_COUNT" -eq 0 ]]; then
  say "WARN: 尚未添加音色，请先在 App 音色管理中添加（服务仍会启动；添加后调用 POST /voices/reload 即可，无需重启）"
  if [[ "$REQUIRE_VOICES" == "1" ]]; then
    die "尚未添加音色，请先在 App 音色管理中添加" 2
  fi
else
  say "音色：$VOICE_COUNT 个（${REFS}）"
fi

# macOS 上 MPS 未实现的算子回退 CPU（server.py 也会设置，这里兜底）
if [[ "$DEVICE" == "mps" || "$DEVICE" == "auto" ]]; then
  export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"
fi
export PYTHONUNBUFFERED=1
export TQDM_DISABLE=1

SERVER_ARGS=(
  "$SERVER"
  --host "$HOST" --port "$PORT"
  --model-dir "$MODEL_DIR" --refs "$REFS"
  --repo "$CV_REPO" --venv "$VENV"
  --device "$DEVICE" --threads "$THREADS" --log-level "$LOG_LEVEL"
)

say "CosyVoice3 sidecar: http://$HOST:$PORT （venv=$VENV, device=${DEVICE}）"

if [[ "$WAIT_HEALTH" == "1" ]]; then
  # ---------------- 监督模式：等服务健康后转前台 ----------------
  "$PY" "${SERVER_ARGS[@]}" &
  SERVER_PID=$!
  CHILD=""
  on_signal() {
    say "收到停止信号，转发给服务进程（pid=${SERVER_PID}）……"
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    exit 143
  }
  trap on_signal TERM INT

  READY=0
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  while [[ $(date +%s) -lt $deadline ]]; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      wait "$SERVER_PID"; rc=$?
      die "服务进程提前退出（exit ${rc}），见上方日志" "$rc"
    fi
    body="$("${CURL_BIN:-curl}" -fsS --max-time 2 "http://$HOST:$PORT/health" 2>/dev/null || true)"
    if [[ "$body" == *'"ready":true'* || "$body" == *'"ready": true'* ]]; then
      READY=1
      break
    fi
    sleep 0.5
  done
  if [[ $READY -eq 1 ]]; then
    say "COSYVOICE_READY http://$HOST:$PORT"
    say "健康检查：$("${CURL_BIN:-curl}" -fsS "http://$HOST:$PORT/health" 2>/dev/null | head -c 400)"
  else
    say "WARN: ${WAIT_TIMEOUT}s 内未就绪（模型首次加载可能较慢），继续前台监督；可查看 /health"
  fi
  wait "$SERVER_PID"
  exit $?
fi

# ---------------- 默认：直接 exec，信号直达 Python ----------------
exec "$PY" "${SERVER_ARGS[@]}"
