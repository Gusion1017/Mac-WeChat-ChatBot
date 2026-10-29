# CosyVoice3 本地 TTS（devtools）

Fun-CosyVoice3-0.5B-2512 的本地推理运行时与 HTTP sidecar，也是 App 唯一的语音引擎。
**仓库不提供任何音色或参考音频**，用户需在 App 的「语音 → 语音引擎与音色 → 管理音色…」中
导入自己的 5–30s 参考音。

```
devtools/cosyvoice/
  server.py           # FastAPI/uvicorn 服务：预加载模型，/health /voices /voices/reload /tts（24k WAV）
                      # 零音色可启动（ready + /voices 空 + /tts 400 no_voices）
  CONTRACT.md         # HTTP 契约（App 对接以此为准）
  test_server.py      # 音色元数据解析单测（标准库 unittest，无 torch/fastapi 依赖）
  patch_repo.py       # 幂等打上游 macOS 补丁（modelscope/pyworld 惰性导入、flow 步数可配置）
  bench.py            # smoke / 本机音色样音 / 性能基准
  perf.py             # 性能探针：CPU/MPS(hybrid)、flow 步数、LLM/flow/hift 分项
  README.md           # 本文件
```

安装与启动在仓库级脚本：

```bash
scripts/install_cosyvoice.sh                 # 幂等安装（venv/repo/依赖/模型），输出 PROGRESS
scripts/run_cosyvoice.sh                     # 前台 exec 启动（App 用；零音色也能启动）
scripts/run_cosyvoice.sh --wait-health       # 启动并等 /health 就绪（人类/CI）
scripts/run_cosyvoice.sh --require-voices    # 零音色直接报错退出（默认只警告并继续）
```

**分发边界**：App 安装包**不内置音色**，也不包含参考音频、`prompt.txt`、`refs/` 或 `voices.json`。
普通用户安装后 `voices/` 为空、服务零音色启动（`/voices` 空、`/tts` 400 `no_voices`），
在 App 音色管理添加后 `POST /voices/reload` 即可生效。

## 运行时事实（Apple Silicon / macOS 26 / torch 2.3.1）

| 项目 | 值 |
|---|---|
| 模型 | `Fun-CosyVoice3-0.5B-2512`，最小推理集 **5.1GB**（不含 llm.rl.pt / batch onnx / TRT onnx） |
| venv | Python 3.10.21，依赖约 **3.4GB**（含 torch 2.3.1、onnxruntime 1.18、transformers 4.51.3） |
| 输出 | 24kHz mono 16-bit PCM WAV |
| 常驻内存 | 模型加载后 **~8.8GB** RSS（CPU 全量 fp32） |
| iOS/ANE | 无；macOS 上 ONNX Runtime 只用到 CPU EP（CoreML EP 未启用） |
| TensorRT / vLLM | 仅 CUDA，macOS 不可用 |

热态性能（20 字 → 约 4.5s 音频）：

| 配置 | 总耗时 | RTF |
|---|---|---|
| CPU + flow 10 步（官方默认） | 11.7s | 2.59 |
| **CPU + flow 6 步（server 默认）** | 9.1s | 1.83 |
| CPU + flow 4 步（`COSYVOICE_FLOW_STEPS=4`，速度优先） | 6.5s | 1.50 |
| MPS hybrid（llm+flow GPU） | 7.1s | 1.43 |

结论：**不是实时 TTS**，适合高质量/离线生成；它也是 App 唯一的语音引擎，合成不可用时该条回复
自动改发文字。
MPS 只在 flow 上有收益（2.8x），LLM 放 MPS 反而更慢；hift 有 `float64` + `torch.stft` 限制只能留 CPU。
ASR 复核 flow 4/6/8/10 步输出文本一致。

## macOS 坑与 workaround

| 坑 | 处理 |
|---|---|
| `modelscope` 顶层 import（本地模型目录不需要） | `patch_repo.py` 改 try/except + 可读错误 |
| `pyworld` 顶层 import 但只在训练期 `compute_f0` 用，且无 macOS arm64 wheel | `patch_repo.py` 惰性化（置 None） |
| `openai-whisper==20231117` 仅 sdist，新 setuptools 无 `pkg_resources` | 先装 `setuptools<81`，再 `--no-build-isolation` 编译 |
| `wetext`（原生文本归一化）依赖 modelscope + 启动时拉 ModelScope FST | 默认不装，文本前端走仓库 fallback；数字读法由 server 轻量规范化兜底 |
| `gradio/tensorboard` 只服务官方 webui | 跳过 |
| `deepspeed/tensorrt/vllm` CUDA/Linux 专用 | 跳过 |
| `matcha`（yaml 的 `!name:matcha.utils.audio.mel_spectrogram`） | 不安装，`sys.path` 加 `third_party/Matcha-TTS`（官方 example.py 同做法） |
| MPS 不支持 `float64`（hift）与 `torch.stft` | hybrid：llm+flow 走 MPS，hift 留 CPU；`PYTORCH_ENABLE_MPS_FALLBACK=1` 兜底 |
| `tqdm` 进度条污染 App 日志 / 上游 INFO 日志会打印合成正文 | `TQDM_DISABLE=1` + `logging.getLogger("cosyvoice")` 压到 WARNING |

## 音色与重载

- `/voices` 每个音色带 `personal_use_only`（默认 `true`，内部元数据）、`builtin`、`source`、
  `reference_count`（参考音频条数，1–5）字段。
- **多条参考音频（v2）**：一个音色可保存 1–5 条参考音频（每条 5–30s，合并总时长 ≤30s）。
  服务端**不做运行时拼接**：App 保存时按顺序合并为单条 `prompt.wav`（片段间 0.25s 静音），
  文本用 `\n` 连接写入 `prompt.txt`；`refs/ref-N.wav|txt` 只是原始片段的 authoring 副本，
  `/tts` 始终只读合并后的 `prompt.wav`。旧音色（无 `refs/`、无 `references`）视为 1 条。
- 服务只做本机合成，不提供网络导出/打包接口；App 可在本机导出自定义音色做备份。
- 新增音色：放 `voices/custom-<name>/prompt.wav` + `prompt.txt`，在 `voices.json` 追加条目
  （`id` 自定义、`personal_use_only` 默认 true、`builtin` 默认 false），然后
  `curl -X POST http://127.0.0.1:5051/voices/reload` 热重载，**无需重启服务**。
- `POST /voices/reload` 与 `/tts` 串行；实测：清单无变化 ~0.3ms，新增 1 个音色 ~1.8s（提取 prompt 特征），
  大模型不重新加载。

## 常用命令

```bash
# 冒烟（repo 自带 prompt，官方 zero_shot）
_local/cosyvoice/venv/bin/python devtools/cosyvoice/bench.py smoke --device cpu

# 本机音色样音 + 冷/热 RTF（输出 _local/cosyvoice/samples/）
_local/cosyvoice/venv/bin/python devtools/cosyvoice/bench.py voices --device cpu

# 性能探针：flow 步数扫描
COSYVOICE_FLOW_STEPS=6 _local/cosyvoice/venv/bin/python devtools/cosyvoice/perf.py \
  --mode cpu --steps 10,8,6,4 --chars 20 --runs 2

# 服务端音色元数据单测（标准库 unittest，无 torch/fastapi/numpy 依赖）
python3 devtools/cosyvoice/test_server.py
```

## 目录（运行时数据，均 gitignore）

```
_local/cosyvoice/
  venv/  repo/  models/Fun-CosyVoice3-0.5B-2512/
  voices/<id>/{prompt.wav,prompt.txt,meta.json,refs/ref-*.wav,refs/ref-*.txt} + voices.json
  bench/  samples/  logs/  .installed
```

`prompt.wav` / `prompt.txt` 是合并后的合成用 prompt，`refs/` 是多条参考音频的原始片段
（编辑/导出/回放用，服务端不读取）。
