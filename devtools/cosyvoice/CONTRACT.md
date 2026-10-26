# CosyVoice3 本地旁路服务契约（v1.0）

`devtools/cosyvoice/server.py` 是 App 的本地 TTS sidecar：常驻 Python 进程，预加载
`Fun-CosyVoice3-0.5B-2512`，HTTP 提供本机已导入音色的语音合成。

- 默认地址：`http://127.0.0.1:5051`（只监听回环地址）
- 启动方式：`scripts/run_cosyvoice.sh`（App 用 `Process` 直接 spawn，前台运行）
- 安装方式：`scripts/install_cosyvoice.sh`
- 协议：HTTP/1.1 + JSON；TTS 成功返回二进制 WAV

---

## 0. 启动参数与环境变量

`scripts/run_cosyvoice.sh`（recommended）：

```bash
scripts/run_cosyvoice.sh [--host 127.0.0.1] [--port 5051] \
                         [--model-dir DIR] [--venv DIR] [--refs DIR] \
                         [--device cpu|mps|auto] [--threads N] [--log-level info]
```

| 参数 | 环境变量 | 默认值 |
|---|---|---|
| `--host` | `COSYVOICE_HOST` | `127.0.0.1` |
| `--port` | `COSYVOICE_PORT` | `5051` |
| `--model-dir` | `COSYVOICE_MODEL_DIR` | `_local/cosyvoice/models/Fun-CosyVoice3-0.5B-2512` |
| `--venv` | `COSYVOICE_VENV` | `_local/cosyvoice/venv` |
| `--refs` | `COSYVOICE_REFS` | `_local/cosyvoice/voices` |
| `--device` | `COSYVOICE_DEVICE` | `cpu`（`mps`/`auto` 走 hybrid：llm+flow 上 GPU、hift 留 CPU；失败自动回退 CPU） |
| `--flow-steps` | `COSYVOICE_FLOW_STEPS` | `6`（10=官方默认；4=速度优先；实测见 §7） |
| `--threads` | `COSYVOICE_THREADS` | `0`=自动 |
| `--log-level` | `COSYVOICE_LOG_LEVEL` | `info` |

也可直接运行 `python devtools/cosyvoice/server.py <同上参数>`。

退出码：

| code | 含义 |
|---|---|
| `0` | 正常退出（SIGTERM/SIGINT 优雅停止） |
| `2` | 前置检查失败（仓库/模型/音色目录缺失、模型文件不全、端口被占 `EADDRINUSE`） |
| `3` | 脚本层错误（venv/python 不存在等） |

---

## 1. `GET /health`

健康检查 + 就绪状态。App 启动时轮询本接口；已 `ready` 则复用进程，不要重启。

**就绪 200**

```json
{
  "ok": true,
  "ready": true,
  "version": "1.0.0",
  "model": "Fun-CosyVoice3-0.5B-2512",
  "model_dir": "/…/_local/cosyvoice/models/Fun-CosyVoice3-0.5B-2512",
  "sample_rate": 24000,
  "voices": ["custom-a", "custom-b", "custom-c"],
  "voices_detail": [
    {"id": "custom-a", "name": "我的音色 A", "description": "…", "mode": "zero_shot",
     "duration_s": 20.3, "has_prompt_text": true}
  ],
  "device": "cpu",
  "hybrid": false,
  "flow_steps": 6,
  "state": "ready",
  "progress": "就绪",
  "load_seconds": 42.1,
  "memory_rss_mb": 9512.0,
  "stats": {"requests": 3, "errors": 0, "last_rtf": 0.72, "last_synth_ms": 2100}
}
```

**加载中 503**

```json
{"ok": false, "ready": false, "loading": true,
 "state": "loading", "progress": "加载模型权重 Fun-CosyVoice3-0.5B-2512（约 20~60s）",
 "model": "Fun-CosyVoice3-0.5B-2512", "sample_rate": 24000,
 "voices": ["custom-a", "custom-b", "custom-c"], "voices_detail": []}
```

**加载失败 500**

```json
{"ok": false, "ready": false, "state": "failed", "error": "model_load_failed",
 "detail": "RuntimeError: …", "model": "Fun-CosyVoice3-0.5B-2512"}
```

App 建议：`loading` 时每 0.5–1s 轮询，上限 90s；`failed` 时展示 `detail` 并提供「重试/查看日志」。

---

## 2. `GET /voices`

返回可用音色（即使模型仍在加载也可用，音色由磁盘配置决定）。

> **分发边界**：App 安装包**不内置任何音色**。普通用户安装后 `voices/` 为空，
> `GET /voices` 返回 `"voices": []`；音色由用户在 App 音色管理中添加（写入
> `prompt.wav` + `voices.json` 后调 `POST /voices/reload`）。

```json
{
  "ok": true,
  "voices": [
    {"id": "custom-a", "name": "我的音色", "description": "本机导入的参考音",
     "mode": "zero_shot", "duration_s": 12.0, "has_prompt_text": true,
     "personal_use_only": true, "builtin": false,
     "source": "local-upload"}
  ]
}
```

- `mode`：`zero_shot`（带参考文本）或 `cross_lingual`（无参考文本，仅音色克隆）。
- 排序：预置音色在前，自定义音色按名称/ID 追加。
- `personal_use_only`：内部元数据（默认 `true`）。服务只提供本机合成，**不提供网络导出/打包接口**；
  导出由 App 在本机完成（自定义音色）。
- `builtin`：预置音色为 `true`；用户新增（`custom-*` 等）为 `false`。
- `source`：可选来源说明（仅元数据展示，不包含音频内容）。
- 字段均向后兼容：旧 `voices.json` 缺少这些键时按「`personal_use_only=true`、`builtin` 按 id 判定、`source=""`」补齐。

## 2.1 `POST /voices/reload`

新增/删除/修改自定义音色后，让服务重读音色清单，**不重载大模型**（模型加载约 22s，reload 只需要几十毫秒~2s）。

- 请求：无（`Content-Type` 可为空；带空 JSON `{}` 也接受）
- 成功 200：

```json
{
  "ok": true,
  "voices": ["custom-a", "custom-b", "custom-c", "custom-a"],
  "voices_detail": [
    {"id": "custom-a", "name": "我的音色", "personal_use_only": true, "builtin": false,
     "mode": "zero_shot", "duration_s": 12.9, "has_prompt_text": true, "source": "local-upload"}
  ],
  "added": 1,
  "reused": 3,
  "removed": [],
  "reload_ms": 1843.6
}
```

- `voices`：音色 id 列表；`voices_detail`：完整对象（同 `/voices`）。
- `added`：本次重新提取 prompt 特征的音色数（新增/参考音或文本改动）；`reused`：复用缓存的音色数；
  `removed`：从清单消失的 id；`reload_ms`：总耗时。
- 与 `/tts` 共用同一把锁：reload 期间的合成请求会排队，不会出现「清单与特征缓存错位」。
- 错误：

| HTTP | `error` | 说明 |
|---|---|---|
| 503 | `not_ready` | 模型仍在加载（`detail` 为当前进度） |
| 500 | `reload_failed` | `voices.json` 解析失败 / 没有任何可用音色 / 所有 prompt 特征提取失败；`detail` 是可读原因 |

```bash
# 新增自定义音色后（把 prompt.wav + voices.json 条目写好）触发热重载
curl -s -X POST http://127.0.0.1:5051/voices/reload | jq
```

> 注意：`/voices/reload` 对 `voices.json` 的解析是**严格模式**（坏 JSON 直接 500 `reload_failed`，
> 不会静默降级为目录扫描）；启动加载时仍宽松（坏清单会回退目录扫描，保证服务能起来）。

---

## 3. `POST /tts`

请求体（`Content-Type: application/json`）：

```json
{"text": "今天天气不错，我们出去走走吧。", "voice_id": "custom-a", "speed": 1.0}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `text` | string | 是 | 1–500 字（按 Unicode 字符计；前后空白会被 trim） |
| `voice_id` | string | 否 | 音色 id，默认第一个可用音色 |
| `speed` | number | 否 | 语速倍率 `0.5`–`2.0`，默认 `1.0` |
| `instruct` | string | 否 | 自然语言风格指令（≤200 字），如「用更快的语速说」 |

**成功 200**

- `Content-Type: audio/wav`
- 正文：RIFF/WAVE，**24000 Hz、单声道、16-bit PCM**
- 响应头（便于调试/UI 展示，可忽略）：

| Header | 示例 | 含义 |
|---|---|---|
| `X-CosyVoice-Version` | `1.0.0` | 服务版本 |
| `X-CosyVoice-Voice` | `custom-a` | 实际音色 |
| `X-CosyVoice-Sample-Rate` | `24000` | 采样率 |
| `X-CosyVoice-Duration-Ms` | `3120` | 音频时长 |
| `X-CosyVoice-Synth-Ms` | `1980` | 纯合成耗时 |
| `X-CosyVoice-RTF` | `0.635` | 实时率（越小越快） |
| `X-CosyVoice-Device` | `cpu` / `mps` | 实际推理设备 |

**错误**：JSON，HTTP 4xx/5xx，统一含 `ok: false`、`error`（机器码）、`detail`（可读原因）。

```json
{"ok": false, "error": "unknown_voice", "detail": "未知音色 xx，可选：custom-a, custom-b"}
```

| HTTP | `error` | 触发条件 |
|---|---|---|
| 400 | `invalid_request` | 请求体不是合法 JSON / 字段类型不对 |
| 400 | `empty_text` | `text` 为空 |
| 400 | `text_too_long` | `text` 超过 500 字 |
| 400 | `no_voices` | 服务当前零音色（普通用户安装后尚未添加音色） |
| 400 | `unknown_voice` | `voice_id` 不在 `/voices` 列表 |
| 400 | `invalid_speed` | `speed` 非数字或越界 |
| 400 | `instruct_too_long` | `instruct` 超过 200 字 |
| 503 | `not_ready` | 模型仍在加载（`detail` 为当前进度） |
| 500 | `model_load_failed` | 模型加载失败（仅 `/health`） |
| 500 | `synthesis_failed` | 合成过程异常（`detail` 为异常摘要） |
| 500 | `internal_error` | 未预期异常 |

示例：

```bash
# 健康检查
curl -s http://127.0.0.1:5051/health | jq

# 音色列表
curl -s http://127.0.0.1:5051/voices | jq

# 合成（保存 24k WAV）
curl -s -X POST http://127.0.0.1:5051/tts \
  -H 'Content-Type: application/json' \
  -d '{"text":"今天天气不错，我们出去走走吧。","voice_id":"custom-a","speed":1.0}' \
  -o custom-a.wav -D -

# 带风格指令
curl -s -X POST http://127.0.0.1:5051/tts \
  -H 'Content-Type: application/json' \
  -d '{"text":"你回来啦。","voice_id":"custom-c","instruct":"用温柔但坚定的语气说"}' \
  -o custom-c.wav

# 错误示例
curl -s -X POST http://127.0.0.1:5051/tts \
  -H 'Content-Type: application/json' -d '{"text":"","voice_id":"custom-a"}'
# {"ok":false,"error":"empty_text","detail":"text 不能为空"}
```

---

## 4. 行为约定

- **零音色可启动**：普通用户安装后没有音色，服务仍会 `ready`（`/health` 200、`/voices` 空），
  此时 `/tts` 返回 400 `no_voices`。用户添加音色后 `POST /voices/reload` 即可，无需重启服务。
- **串行合成**：服务端用全局锁排队，同一时刻只合成一条。App 不应并发大量 `/tts`。
- **不记录正文**：日志只记录 `text_len`、音色、耗时、RTF；请求 body 不落日志。
- **音色 prompt 缓存**：每个音色的参考音特征在启动时提取一次并缓存，首次请求无需重复前处理。
- **预热**：启动就绪前会合成一句短音频（约 1–3s），之后首包更稳定。
- **`/tts` 文本分句**：上游会按 ~80 token 自动分句合成后拼接，长文本（如 300 字）单请求耗时较长（CPU 上约 1.5s/字·RTF，即 100 字约 40–70s），App 侧超时建议 ≥180s。
- **性能定位**：CosyVoice3-0.5B 在 M3 Max CPU 上热态 RTF ≈ 1.5（flow 4 步）~2.8（10 步），**不是实时 TTS**；适合作高质量/离线、或长文生成。实时聊天默认仍用 Kokoro，CosyVoice 作为高质量备选。
- **进程生命周期**：只监听回环地址；SIGTERM/SIGINT 后 uvicorn 优雅退出（最多等 5s）。

---

## 5. 音色文件布局

```
_local/cosyvoice/voices/
  voices.json          # 音色清单（缺失时服务会扫描子目录；普通用户安装后为 {"voices": []}）
  <custom-id>/prompt.wav   # 用户新增：24k mono 16-bit，5–30s
  <custom-id>/prompt.txt   # 参考文本（逐字对应；缺失则用 cross_lingual 模式）
```

- **普通安装不生成音色**：`scripts/install_cosyvoice.sh` 默认只创建空 `voices/` + 空 `voices.json`，
  安装成功（`.installed`）≠ 有音色；音色由用户在 App 内导入。
- App 分发包不包含任何参考音频或 `voices/`；服务端只需 `server.py` + repo + 模型即可运行（零音色启动）。

`voices.json`：

```json
{
  "version": 1,
  "voices": [
    {"id": "custom-a", "name": "我的音色", "description": "…", "mode": "zero_shot",
     "prompt_wav": "custom-a/prompt.wav", "prompt_text": "…",
     "personal_use_only": true, "builtin": false, "source": "local-upload"}
  ]
}
```

- 新增自定义音色：建 `voices/custom-<name>/prompt.wav`（5–30s、≥16k、单声道）+ `prompt.txt`，
  在 `voices.json` 追加条目（`id/name/prompt_wav` 必填；`personal_use_only` 默认 `true`，
  `builtin` 默认 `false`），然后 `POST /voices/reload`。**不要重启服务。**
- **本机存储**：音色与参考音仅存本机 `_local/cosyvoice/voices/`（gitignored），
  服务不提供网络导出/打包接口；App 可在本机导出自定义音色。

---

## 7. 实测性能（M3 Max 38GB / macOS 26 / torch 2.3.1）

热态（第二次及以后请求），文本 20 字 → 约 4.5s 音频：

| 配置 | 总耗时 | flow | LLM | hift | RTF |
|---|---|---|---|---|---|
| CPU, flow 10 步 | 11.7s | 8.3s | 3.4s | 0.3s | 2.59 |
| CPU, flow 6 步（默认） | 9.1s | 5.4s | 3.7s | 0.3s | 1.83 |
| CPU, flow 4 步（速度优先） | 6.5s | 3.2s | 3.4s | 0.3s | 1.50 |
| MPS hybrid（llm+flow 在 MPS）4 步 | 7.1s | 1.3s | 5.8s | 0.3s | 1.43 |
| MPS flow-only（仅 flow 在 MPS）4 步 | 9.3s | 2.0s | 7.4s | 0.6s | 1.88 |

- 冷态首包 = 模型加载（约 12s 权重）+ 首次合成（约 2–3 倍热态耗时）；启动到 `ready` 实测见 `_local/cosyvoice/report.md`。
- 常驻 RSS ≈ **8.8GB**（fp32 全量）。
- flow 步数降到 4 时，ASR 复核文本与 10 步完全一致（未见糊/重复），但更低的 2 步未验证，不建议。
- **MPS 不是万能**：flow 在 MPS 上快 2.8x，但 LLM 在 MPS 上反而慢（小 batch 逐 token 开销大），hift 有 float64/stft 限制只能留 CPU。

## 6. 兼容性备注

- 目前是 **HTTP/1.1 非流式**：整段合成完再返回 WAV。若以后需要首包更低，可加
  `stream=1` 分块 WAV/PCM 接口（v1 未实现，App 不要依赖）。
- `instruct` 走 CosyVoice3 的 `inference_instruct2`；会把参考音作为 prompt 并附加
  `You are a helpful assistant. <instruct><|endofprompt|>` 前缀（官方推荐格式）。
- 服务与 App 解耦：App 只需 `GET /health` 判活，不需要知道模型细节。
