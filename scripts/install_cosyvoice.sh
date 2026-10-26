#!/usr/bin/env bash
# CosyVoice3 本地旁路 —— 幂等安装脚本（macOS arm64 优先，Linux 亦可）。
#
# 分工：
#   1. Python 3.10 venv（uv 优先，conda/python3.10 兜底）
#   2. clone FunAudioLLM/CosyVoice（含 third_party/Matcha-TTS submodule）
#   3. 打 macOS 补丁（modelscope/pyworld 惰性导入）并安装推理依赖
#   4. 下载 Fun-CosyVoice3-0.5B-2512 最小推理权重（约 5.4GB）
#   5. 音色：**不内置任何音色**，只创建空 voices/ + 空 voices.json，
#      由用户在 App 音色管理里自行添加
#   6. 校验（venv/模型）并写 .installed 标记（安装成功 ≠ 有音色）
#
# 输出契约（App 逐行解析）：每步一行 `PROGRESS <0.00-1.00> <中文说明>`（stdout）。
# 人类可读的诊断写 stderr；失败时 stderr 有明确原因 + 非 0 退出码。
#
# 用法：
#   scripts/install_cosyvoice.sh [选项]
#     --home DIR        安装根目录（App 生产路径；推导 model/venv/refs/repo）
#     --model-dir DIR   --venv DIR   --refs DIR   --repo DIR
#     --skip-model      --skip-deps  --dry-run  --force
#   （同名环境变量：COSYVOICE_MODEL_DIR / COSYVOICE_VENV / COSYVOICE_REFS /
#     COSYVOICE_REPO / COSYVOICE_LOCAL_DIR）
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# App 是 GUI 启动的，Process 继承的 PATH 往往只有 /usr/bin:/bin:/usr/sbin:/sbin，
# 没有 Homebrew / anaconda。这里统一补齐，并优先用绝对路径探测工具。
export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/anaconda3/bin:$HOME/.local/bin:$PATH"

find_tool() {
  # find_tool <name> [candidate_abs_paths...] -> 打印绝对路径
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

# 路径解析：--home（App 生产路径）> 显式 flag > 环境变量 > 仓库内 _local 默认
HOME_DIR_ARG=""
VENV_ARG=""
MODEL_DIR_ARG=""
REFS_ARG=""
CV_REPO_ARG=""
MODEL_ID="FunAudioLLM/Fun-CosyVoice3-0.5B-2512"
REPO_URL="https://github.com/FunAudioLLM/CosyVoice"

SKIP_MODEL=0
SKIP_DEPS=0
DRY_RUN=0
FORCE=0
say() { printf '%s\n' "$*" >&2; }
die() { local _code="${2:-1}"; printf 'ERROR: %s\n' "$1" >&2; exit "$_code"; }
progress() { printf 'PROGRESS %.2f %s\n' "$1" "$2"; }

CURRENT_PID=""
on_signal() {
  say ""
  say "收到中断信号，正在停止当前步骤（已下载内容会保留，重跑即可续传）……"
  if [[ -n "$CURRENT_PID" ]]; then
    kill -TERM "$CURRENT_PID" 2>/dev/null || true
    wait "$CURRENT_PID" 2>/dev/null || true
  fi
  exit 143
}
trap on_signal TERM INT

# 在后台跑命令并 wait，这样能立刻响应 SIGTERM（App 取消 = terminate）
run_step() {
  "$@" &
  CURRENT_PID=$!
  wait "$CURRENT_PID"
  local rc=$?
  CURRENT_PID=""
  return $rc
}

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home) HOME_DIR_ARG="${2:?}"; shift 2 ;;
    --model-dir) MODEL_DIR_ARG="${2:?}"; shift 2 ;;
    --venv) VENV_ARG="${2:?}"; shift 2 ;;
    --refs) REFS_ARG="${2:?}"; shift 2 ;;
    --repo) CV_REPO_ARG="${2:?}"; shift 2 ;;
    --skip-model) SKIP_MODEL=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（--help 查看用法）" ;;
  esac
done

LOCAL_DIR="${HOME_DIR_ARG:-${COSYVOICE_HOME:-${COSYVOICE_LOCAL_DIR:-$REPO_ROOT/_local/cosyvoice}}}"
VENV="${VENV_ARG:-${COSYVOICE_VENV:-$LOCAL_DIR/venv}}"
MODEL_DIR="${MODEL_DIR_ARG:-${COSYVOICE_MODEL_DIR:-$LOCAL_DIR/models/Fun-CosyVoice3-0.5B-2512}}"
REFS="${REFS_ARG:-${COSYVOICE_REFS:-$LOCAL_DIR/voices}}"
CV_REPO="${CV_REPO_ARG:-${COSYVOICE_REPO:-$LOCAL_DIR/repo}}"
MARKER="$LOCAL_DIR/.installed"
PY="$VENV/bin/python"
CV_DEVTOOLS="${COSYVOICE_SERVER_DIR:-$REPO_ROOT/devtools/cosyvoice}"
# 打包版 App：脚本与 server.py 同目录（Contents/Resources/cosyvoice/），
# 手动在 bundle 里运行时也能找到，不依赖 App 注入 COSYVOICE_SERVER_DIR。
if [[ ! -f "$CV_DEVTOOLS/server.py" && -f "$SCRIPT_DIR/server.py" ]]; then
  CV_DEVTOOLS="$SCRIPT_DIR"
fi
export COSYVOICE_SERVER_DIR="$CV_DEVTOOLS"

# server.py / patch_repo.py 是安装与运行必需。
for tool in server.py patch_repo.py; do
  [[ -f "$CV_DEVTOOLS/$tool" ]] || die "找不到 ${tool}（COSYVOICE_SERVER_DIR=${CV_DEVTOOLS}）"
done

# --------------------------------------------------------------------------- #
# 0. 环境检查
# --------------------------------------------------------------------------- #
progress 0.00 "检查安装环境"
say "=============================================================="
say " CosyVoice3 本地旁路安装"
say "   仓库根   : $REPO_ROOT"
say "   venv     : $VENV"
say "   模型目录 : $MODEL_DIR"
say "   音色目录 : $REFS"
say "   CosyVoice: $CV_REPO"
say "=============================================================="

[[ -d "$REPO_ROOT" ]] || die "仓库根不存在：$REPO_ROOT"

FFMPEG_BIN="$(find_tool ffmpeg /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg || true)"
[[ -n "$FFMPEG_BIN" ]] || die "找不到 ffmpeg。请先安装：brew install ffmpeg（或放到 PATH）"
export FFMPEG_BIN
export PATH="$(dirname "$FFMPEG_BIN"):$PATH"

GIT_BIN="$(find_tool git /usr/bin/git /opt/homebrew/bin/git || true)"
[[ -n "$GIT_BIN" ]] || die "找不到 git（macOS 自带 /usr/bin/git；若缺失请安装 Xcode CLT）"

UV_BIN="$(find_tool uv /opt/homebrew/bin/uv /usr/local/bin/uv || true)"
PY310="$(find_tool python3.10 /opt/homebrew/bin/python3.10 /usr/local/bin/python3.10 || true)"
CONDA_BIN="$(find_tool conda /opt/anaconda3/bin/conda /opt/homebrew/bin/conda || true)"
if [[ -z "$UV_BIN" && -z "$PY310" && -z "$CONDA_BIN" ]]; then
  die "找不到 uv / python3.10 / conda。请先安装其一：
  - 推荐：brew install uv
  - 或：brew install python@3.10
  - 或：安装 Miniconda 后用 conda 创建 python=3.10 环境"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  say "   --- 最终解析路径（App 会用这些路径判定已安装）---"
  say "   LOCAL_DIR = $LOCAL_DIR"
  say "   VENV      = $VENV"
  say "   MODEL_DIR = $MODEL_DIR"
  say "   REFS      = $REFS"
  say "   CV_REPO   = $CV_REPO"
  say "   MARKER    = $MARKER"
  say "   SERVER_DIR= $CV_DEVTOOLS"
  say "   PY        = $PY"
  say "   ---------------------------------------------"
  progress 0.05 "[dry-run] 将创建 venv：${VENV}（Python 3.10）"
  progress 0.15 "[dry-run] 将 clone $REPO_URL -> $CV_REPO"
  progress 0.20 "[dry-run] 将安装推理依赖（约 2GB，跳过 gradio/tensorboard/deepspeed/modelscope/pyworld）"
  [[ $SKIP_MODEL -eq 1 ]] && progress 0.55 "[dry-run] --skip-model：跳过下载" \
                           || progress 0.55 "[dry-run] 将下载 ${MODEL_ID}（约 5.4GB）-> $MODEL_DIR"
  progress 0.85 "[dry-run] 将创建空音色目录（不内置音色）-> $REFS"
  progress 1.00 "演练完成（未做任何修改）"
  exit 0
fi

if [[ $FORCE -eq 0 && -f "$MARKER" && -x "$PY" ]]; then
  if "$PY" - "$MARKER" "$MODEL_DIR" "$REFS" <<'PY' >/dev/null 2>&1
import json, pathlib, sys
marker, model_dir, refs = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
# 「已安装」= venv 可执行 + 模型齐全；音色不是必需（普通用户安装后为空）
data = json.loads(marker.read_text()) if marker.is_file() else {}
need = ["llm.pt", "flow.pt", "hift.pt", "speech_tokenizer_v3.onnx", "campplus.onnx", "cosyvoice3.yaml"]
if not all((model_dir / n).is_file() for n in need):
    sys.exit(1)
PY
  then
    progress 1.00 "已安装（$MARKER 校验通过），无需重装"
    say "已安装且校验通过。需要重装请加 --force。"
    exit 0
  fi
  say "已有 .installed 但校验不通过，继续修复式安装。"
fi

mkdir -p "$LOCAL_DIR" "$(dirname "$MODEL_DIR")" "$REFS" "$LOCAL_DIR/logs"

# --------------------------------------------------------------------------- #
# 1. venv
# --------------------------------------------------------------------------- #
progress 0.03 "准备 Python 3.10 虚拟环境"
if [[ -x "$PY" ]] && "$PY" -c 'import sys; assert sys.version_info[:2] == (3, 10)' 2>/dev/null; then
  say "复用已有 venv：$VENV ($("$PY" -V 2>&1))"
else
  if [[ -n "$UV_BIN" ]]; then
    "$UV_BIN" venv --python 3.10 "$VENV" || die "uv venv 创建失败（${VENV}）"
  else
    "$PY310" -m venv "$VENV" || die "python3.10 -m venv 创建失败（${VENV}）"
  fi
fi
[[ -x "$PY" ]] || die "venv 里没有 python：$PY"
say "Python: $("$PY" -V 2>&1)"

# --------------------------------------------------------------------------- #
# 2. CosyVoice repo
# --------------------------------------------------------------------------- #
progress 0.08 "获取 CosyVoice 仓库（含 Matcha-TTS 子模块）"
if [[ -d "$CV_REPO/.git" ]]; then
  say "复用已有仓库：$CV_REPO"
  if [[ ! -f "$CV_REPO/third_party/Matcha-TTS/matcha/utils/audio.py" ]]; then
    say "子模块缺失，补齐 third_party/Matcha-TTS …"
    "$GIT_BIN" -C "$CV_REPO" submodule update --init --recursive || die "子模块更新失败"
  fi
else
  run_step "$GIT_BIN" clone --recursive --depth 1 "$REPO_URL" "$CV_REPO" || die "git clone 失败（网络？）"
fi

progress 0.12 "给仓库打 macOS 兼容补丁（modelscope/pyworld 惰性导入）"
"$PY" "$CV_DEVTOOLS/patch_repo.py" --repo "$CV_REPO" \
  || die "仓库补丁失败（上游结构可能已变，见 devtools/cosyvoice/patch_repo.py）"

# --------------------------------------------------------------------------- #
# 3. 依赖
# --------------------------------------------------------------------------- #
if [[ $SKIP_DEPS -eq 1 ]]; then
  progress 0.18 "--skip-deps：跳过依赖安装"
else
  progress 0.16 "安装推理依赖（约 2GB，首次约 3–10 分钟）"
  PIP=("$PY" -m pip)
  if [[ -n "$UV_BIN" ]]; then PIP=("$UV_BIN" pip); fi
  if [[ "${PIP[0]}" == *uv ]]; then
    PIP_CMD=("${PIP[0]}" pip install --python "$PY")
  else
    PIP_CMD=("$PY" -m pip install)
  fi

  CORE=(
    "torch==2.3.1" "torchaudio==2.3.1" "numpy==1.26.4"
    "onnxruntime==1.18.0" "transformers==4.51.3" "x-transformers==2.11.24" "conformer==0.3.2"
    "diffusers==0.29.0" "lightning==2.2.4" "librosa==0.10.2" "soundfile==0.12.1" "inflect==7.3.1"
    "matplotlib==3.7.5" "networkx==3.1" "tqdm" "rich==13.7.1" "pyyaml" "hyperpyyaml==1.2.3"
    "omegaconf==2.3.0" "hydra-core==1.3.2"
    "fastapi==0.115.6" "uvicorn==0.30.0" "pydantic==2.7.0" "protobuf==4.25" "onnx==1.16.0"
    "grpcio==1.57.0" "grpcio-tools==1.57.0" "pyarrow==18.1.0" "scipy"
    "gdown==5.1.0" "wget==3.2" "setuptools<81" "edge-tts"
  )
  # 说明：不装 gradio / tensorboard / deepspeed / tensorrt / modelscope / pyworld / ttsfrd
  #      （gradio、tensorboard 只服务官方 webui；deepspeed/tensorrt 是 CUDA/Linux 专用；
  #        modelscope/pyworld 用 patch_repo.py 惰性化；ttsfrd 是可选文本前端）
  run_step "${PIP_CMD[@]}" "${CORE[@]}" || die "核心依赖安装失败（见上方 pip 输出）"
  progress 0.34 "安装 openai-whisper（sdist 编译，需 setuptools<81）"
  run_step "${PIP_CMD[@]}" --no-build-isolation "openai-whisper==20231117" \
    || die "openai-whisper 安装失败（CosyVoice 前端日志梅尔谱依赖它）"
  progress 0.42 "安装 kaldifst（wetext 文本前端依赖，可选）"
  run_step "${PIP_CMD[@]}" "kaldifst" || say "WARN: kaldifst 安装失败，跳过 wetext（文字归一化退化为内置）"
  # wetext 0.0.4 需要 modelscope 在 import 时提供 snapshot_download；我们不用 modelscope，
  # 因此默认不装 wetext，文本前端用仓库自带 fallback（数字读法可能不如 wetext 精确）。
  "$PY" - <<'PY' >/dev/null 2>&1 || true
import torch, torchaudio, transformers, onnxruntime, whisper
PY
  progress 0.45 "依赖安装完成"
fi

# --------------------------------------------------------------------------- #
# 4. 模型
# --------------------------------------------------------------------------- #
MODEL_FILES=(
  "config.json" "configuration.json" "cosyvoice3.yaml"
  "campplus.onnx" "flow.pt" "hift.pt" "llm.pt" "speech_tokenizer_v3.onnx"
  "CosyVoice-BlankEN/config.json" "CosyVoice-BlankEN/generation_config.json"
  "CosyVoice-BlankEN/merges.txt" "CosyVoice-BlankEN/model.safetensors"
  "CosyVoice-BlankEN/tokenizer_config.json" "CosyVoice-BlankEN/vocab.json"
)

model_complete() {
  local f
  for f in "${MODEL_FILES[@]}"; do
    [[ -f "$MODEL_DIR/$f" ]] || return 1
  done
  # llm.pt/flow.pt 只下载到一半时大小会远小于阈值
  [[ $(stat -f%z "$MODEL_DIR/llm.pt" 2>/dev/null || stat -c%s "$MODEL_DIR/llm.pt" 2>/dev/null || echo 0) -gt 1500000000 ]] || return 1
  [[ $(stat -f%z "$MODEL_DIR/flow.pt" 2>/dev/null || stat -c%s "$MODEL_DIR/flow.pt" 2>/dev/null || echo 0) -gt 1000000000 ]] || return 1
  return 0
}

if [[ $SKIP_MODEL -eq 1 ]]; then
  progress 0.55 "--skip-model：跳过模型下载"
elif model_complete; then
  progress 0.55 "模型已存在且完整：$MODEL_DIR"
else
  progress 0.55 "下载模型 ${MODEL_ID}（约 5.4GB，跳过 llm.rl.pt / batch onnx / TRT onnx）"
  HF_ARGS=("$MODEL_ID" "--local-dir" "$MODEL_DIR" "${MODEL_FILES[@]}")
  HF_CMD=()
  HF_BIN="$(find_tool hf /opt/homebrew/bin/hf /usr/local/bin/hf /opt/anaconda3/bin/hf || true)"
  HFCLI_BIN="$(find_tool huggingface-cli /opt/homebrew/bin/huggingface-cli /usr/local/bin/huggingface-cli /opt/anaconda3/bin/huggingface-cli || true)"
  if [[ -n "$HF_BIN" ]]; then
    HF_CMD=("$HF_BIN" download)
  elif [[ -n "$HFCLI_BIN" ]]; then
    HF_CMD=("$HFCLI_BIN" download)
  elif [[ -n "$UV_BIN" ]]; then
    HF_CMD=("$UV_BIN" tool run --from huggingface_hub hf download)
  else
    die "找不到 hf / huggingface-cli / uv，无法下载模型。可手动把模型放到 $MODEL_DIR"
  fi

  mkdir -p "$MODEL_DIR"
  "${HF_CMD[@]}" "${HF_ARGS[@]}" &
  CURRENT_PID=$!
  # 轮询下载体积，输出 0.55 -> 0.83 的进度（总量按已见 5.6GB 估算）
  TARGET_BYTES=5600000000
  while kill -0 "$CURRENT_PID" 2>/dev/null; do
    sleep 3
    done_bytes=$(du -sk "$MODEL_DIR" 2>/dev/null | awk '{print $1 * 1024}')
    [[ -z "${done_bytes:-}" ]] && done_bytes=0
    pct=$(( done_bytes * 100 / TARGET_BYTES ))
    [[ $pct -gt 100 ]] && pct=100
    # 0.55 + 0.28 * pct%
    step=$(awk -v p="$pct" 'BEGIN{printf "%.2f", 0.55 + 0.28 * p / 100}')
    progress "$step" "下载模型 ${pct}%（$(awk -v b="$done_bytes" 'BEGIN{printf "%.2f", b/1073741824}') GB / ~5.4GB）"
  done
  wait "$CURRENT_PID"
  rc=$?
  CURRENT_PID=""
  [[ $rc -eq 0 ]] || die "模型下载失败（exit ${rc}），可直接重跑本脚本续传"
  model_complete || die "模型下载完成但文件不全：${MODEL_DIR}（请重跑）"
  progress 0.83 "模型下载完成"
fi

# --------------------------------------------------------------------------- #
# 5. 音色（不内置；用户在 App 音色管理里添加）
# --------------------------------------------------------------------------- #
mkdir -p "$REFS"
export COSYVOICE_REPO_ROOT="$REPO_ROOT"
progress 0.86 "创建空音色目录（不内置音色，由用户在 App 内添加）"
if [[ ! -f "$REFS/voices.json" ]]; then
  printf '{\n  "version": 1,\n  "voices": []\n}\n' > "$REFS/voices.json"
  say "已写空清单：$REFS/voices.json"
else
  say "已存在音色清单，保留不动：$REFS/voices.json"
fi
if [[ -d "$REFS/girl" || -d "$REFS/loli" || -d "$REFS/onee" ]]; then
  say "检测到本机已有音色目录，保留不动。"
fi

# --------------------------------------------------------------------------- #
# 6. 校验 + 标记
# --------------------------------------------------------------------------- #
progress 0.94 "校验安装结果（venv/模型；音色可为空）"
"$PY" - "$REPO_ROOT" "$VENV" "$MODEL_DIR" "$REFS" <<'PY' || die "安装校验失败（见上）"
import json, pathlib, sys
repo_root, venv, model_dir, refs = (pathlib.Path(x) for x in sys.argv[1:5])
errors = []
need_model = ["llm.pt", "flow.pt", "hift.pt", "speech_tokenizer_v3.onnx",
              "campplus.onnx", "cosyvoice3.yaml"]
for name in need_model:
    p = model_dir / name
    if not p.is_file():
        errors.append(f"模型文件缺失: {p}")
if not (venv / "bin" / "python").is_file():
    errors.append(f"venv python 缺失: {venv / 'bin' / 'python'}")
if errors:
    print("校验失败：", file=sys.stderr)
    for e in errors:
        print(" -", e, file=sys.stderr)
    sys.exit(1)
# 音色不是安装成功条件（分发边界：普通用户安装后为空）；有清单则做一次可读校验
voice_ids = []
manifest = refs / "voices.json"
if manifest.is_file():
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        voice_ids = [item["id"] for item in data.get("voices", [])]
    except Exception as exc:
        print(f"WARN: 音色清单解析失败（不影响安装，可在 App 内重建）：{exc}", file=sys.stderr)
print(f"校验通过：venv/模型齐全；音色 {len(voice_ids)} 个 {voice_ids}", file=sys.stderr)
PY

progress 0.97 "写入安装标记"
"$PY" - "$MARKER" "$MODEL_DIR" "$VENV" "$REFS" <<'PY'
import datetime, json, pathlib, sys
marker, model_dir, venv, refs = (pathlib.Path(x) for x in sys.argv[1:5])
voice_ids = []
manifest = refs / "voices.json"
if manifest.is_file():
    try:
        voice_ids = [v["id"] for v in json.loads(manifest.read_text(encoding="utf-8")).get("voices", [])]
    except Exception:
        voice_ids = []
data = {
    "version": 1,
    "installed_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "model": model_dir.name,
    "model_dir": str(model_dir),
    "venv": str(venv),
    "voices_dir": str(refs),
    # 安装成功 ≠ 有音色：普通用户安装后为空，由 App 内添加
    "voices": voice_ids,
    "python": "3.10",
    "platform": sys.platform,
}
tmp = marker.with_suffix(".tmp")
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tmp.replace(marker)
print(f"已写入 {marker}", file=sys.stderr)
PY

progress 1.00 "安装完成，可运行 scripts/run_cosyvoice.sh 启动服务"
say ""
say "安装完成。启动：scripts/run_cosyvoice.sh --wait-health"
say "标记文件：$MARKER"
say "音色：未内置。请在 App 音色管理中添加后调用 POST /voices/reload。"
exit 0
