# CosyVoice3 本地旁路（可选高保真 TTS）

> 状态：**开发态已跑通；App 集成与安装/下载 UI 已接入。** 2026-10-27
> 目标：给「Kokoro 不够像真人」提供第二条本地路线，同时保持 Kokoro 为默认、零依赖、快启动。
> 相关：[`voice.md`](voice.md)、[`core-services.md`](core-services.md)、[`architecture.md`](architecture.md)

## 1. 定位

- **不是默认引擎**：Kokoro 仍是默认（365 MB、零 Python 依赖、启动快）。
- CosyVoice3 是**可选高保真引擎**：`Fun-CosyVoice3-0.5B-2512`（Apache-2.0，24 kHz，零样本克隆），
  音色更自然、可克隆，但需要 Python 3.10 + PyTorch 运行环境和约 5–7 GB 模型。
- 首次使用由用户在设置页显式下载/安装；未安装、服务未启动或合成失败时**自动回退 Kokoro**，
  Kokoro 也失败才改发文字。
- **App 包不内置任何音色**：不打包参考音频、`prompt.txt`、`voices.json`。普通用户安装后
  音色列表为空，需要在 App 内「管理音色」导入自己的 5–30s 参考音。

## 2. 架构

```
SwiftUI App
  VoiceSynthesisService (.cosyVoice)
    → CosyVoiceClient (HTTP, 127.0.0.1:5051)
      → Python sidecar: devtools/cosyvoice/server.py (FastAPI/uvicorn)
        → Fun-CosyVoice3-0.5B-2512 (PyTorch CPU/MPS)
        → 24 kHz mono 16-bit WAV
    → 统一时长/截断/淡入淡出/写 WAV
  → bridge POST /send_voice (24k WAV)
    → 官方 SILK SDK 24 kHz → 微信
```

- sidecar 只监听回环地址；App 的 endpoint 只接受 `127.0.0.1` / `localhost` / `::1`。
- 音色清单以本机 `voices/voices.json` 为准；服务启动时提取 prompt 特征并缓存，新增/修改后
  `POST /voices/reload` 增量更新，不重载大模型。App 包本身不携带任何音色。
- 服务串行合成；App 不做并发 `/tts`。

## 3. 安装

### 3.1 App 内（推荐）

1. 机器人 → 语音 → 语音引擎与音色 → 选择 **CosyVoice3**；
2. 点「下载并安装 CosyVoice3」，确认体积（运行环境约 2–3 GB + 模型约 5–7 GB）；
3. 安装脚本依次：创建 Python 3.10 venv → clone CosyVoice → 安装推理依赖 → 下载模型 →
   创建空 `voices/` + 空 `voices.json` → 写 `.installed` 标记；
4. 安装完成后音色列表为空，先点「管理音色…」导入自己的 5–30s 参考音，再点「启动」，
   等待 `/health` 就绪（首次 30–90s，含 import 与模型加载）。

> **分发包边界**：安装脚本默认**不生成任何音色**，App 包不包含参考音频/`prompt.txt`。
> 普通用户安装后音色列表为空，需自行添加；本机已有的 `voices/` 不会被安装/重装删除。

安装目录（源码运行时）：

```
_local/cosyvoice/
  venv/                  # Python 3.10（uv 创建）
  repo/                  # FunAudioLLM/CosyVoice（含 Matcha-TTS 子模块）
  models/Fun-CosyVoice3-0.5B-2512/
  voices/<voice-id>/{prompt.wav,prompt.txt,meta.json}
  voices/voices.json
  .installed
```

打包后的 `.app` 没有仓库目录时，使用：

```
~/Library/Application Support/WeChatAI/cosyvoice/
```

可用 `WECHATAI_COSYVOICE_HOME` 覆盖；脚本位置可用
`WECHATAI_COSYVOICE_INSTALL_SCRIPT` / `WECHATAI_COSYVOICE_SCRIPT` 覆盖。

### 3.2 命令行（开发/排障）

```bash
# 安装（幂等；每步输出 PROGRESS 0..1 中文说明；默认不生成音色）
scripts/install_cosyvoice.sh

# 启动服务（前台；App 也用同一脚本）
scripts/run_cosyvoice.sh --port 5051 --host 127.0.0.1

# 健康检查 / 音色 / 合成
curl -s http://127.0.0.1:5051/health | jq
curl -s http://127.0.0.1:5051/voices | jq
curl -s -X POST http://127.0.0.1:5051/tts \
  -H 'Content-Type: application/json' \
  -d '{"text":"今天天气不错，我们出去走走吧。","voice_id":"YOUR_VOICE_ID","speed":1.0}' \
  -o /tmp/voice.wav
```

前置条件：macOS + Xcode Command Line Tools、`uv`（推荐）或 `conda`、`ffmpeg`、约 8–10 GB 磁盘。
脚本会显式搜索 `/opt/homebrew/bin`、`/usr/local/bin`、`/opt/anaconda3/bin`，不依赖 GUI 进程的 PATH。

## 4. 音色（只存本机）

> **分发包边界**：仓库与 App 包不包含任何参考音频、`prompt.txt`、`voices.json`。
> 每个用户需要自行导入自己的参考音；请勿把个人音色目录或音频提交/分享。

- 参考文本必须与参考音**逐字对应**；缺少 `prompt.txt` 时服务回退到 `cross_lingual`（只克隆音色）。
- 音色只存本机；清单/导出 JSON 保留 `personal_use_only: true` 字段（内部元数据，App 不展示提醒）。

### 4.1 新增与管理音色（App 内）

入口：机器人 → 语音 → CosyVoice3 → 音色 →「管理音色…」。

- 列表：本机已有音色 + 自定义音色；显示名称、简介、时长、是否有参考文本；
  支持试听、设为当前、编辑、删除（仅自定义）。
- 新增：
  1. 名称（必填，≤30 字）、简介（可选）；
  2. 参考音频（wav / m4a / aiff，建议 5–30s、单人、干净无伴奏；**不支持 mp3**）；
  3. 参考文本（必须与音频逐字对应；可「自动转写」后手动修正；留空则用 `cross_lingual` 只克隆音色）；
  4. 保存后写入 `voices/<id>/prompt.wav|txt|meta.json` 并更新 `voices.json`；服务运行中就调用
     `POST /voices/reload` 立即生效，未运行则下次启动生效。
- 编辑：预置音色只允许改名称/简介/参考文本；自定义音色可替换参考音频。
- 删除：只允许自定义音色；预置音色不可删除。
- 校验：音频必须可解码、单声道；5–30s；保存时统一转 24k mono 16-bit 并做峰值归一，避免削波。
- **导出自定义音色（本人备份）**：Manager 里自定义音色行有「导出…」，工具栏有「导出全部自定义音色…」；
  导出为 `.zip`，包含 `<id>/prompt.wav`、`prompt.txt`、`meta.json`、`voice.json`（`personal_use_only:true`、
  `exported_at`、`app`）与中性 `README.txt`（备份内容/恢复方式），根目录 `export.json`。
  预置音色不可导出；自定义音色可导出为 zip 备份，不提供任何网络上传/分享入口。

`voices.json` 条目：

```json
{"id":"custom-xxx","name":"我的音色","description":"","prompt_wav":"custom-xxx/prompt.wav",
 "prompt_text":"参考文本","mode":"zero_shot",
 "personal_use_only":true,"builtin":false,"source":"user-import"}
```

## 5. 设置项

`BotSettings.voice` 新增：

- `engine`：`kokoro` / `zipvoiceClone` / `cosyVoice`；
- `cosyVoiceVoiceID`：本机 `voices.json` 中的音色 id；未选择/音色库为空时显示「未选择音色」；
  音色清单以服务端 `voices.json` 为准，App 只保存当前选择；
- `cosyVoiceEndpoint`：默认 `http://127.0.0.1:5051`（只允许回环）；
- `cosyVoiceAutoStart`：默认 `true`（选中 CosyVoice 且已安装时，启动 App 后自动拉起服务）；
- `cosyVoiceSpeed`：0.5–2.0，默认 1.0（独立于 Kokoro 语速）。

回退链：CosyVoice → Kokoro → 文字。回退原因写入运行日志。

## 6. HTTP 契约

完整字段、错误码与 curl 示例见 [`devtools/cosyvoice/CONTRACT.md`](../devtools/cosyvoice/CONTRACT.md)。
摘要：

- `GET /health`：200 就绪；503 加载中；500 加载失败；
- `GET /voices`：`{"ok":true,"voices":[{"id","name","description","mode","duration_s",
  "personal_use_only","builtin"}]}`；
- `POST /voices/reload`：重新读取 `voices.json` 并重建 prompt 缓存（不重载大模型），
  返回与 `/voices` 相同结构；写盘后由 App 调用；
- `POST /tts`：`{"text","voice_id","speed","instruct"}` → `audio/wav` 24k mono 16-bit；
  错误 JSON（`invalid_request` / `empty_text` / `text_too_long` / `unknown_voice` /
  `not_ready` / `synthesis_failed` 等）。

## 7. 性能与限制

- 首次启动：Python import（约 20–25 s）+ 模型加载（约 10–60 s）+ 预热，总计约 30–90 s；
  App 健康轮询上限 90 s。
- CPU 推理（Apple Silicon）：**当前实测偏慢**，20–50 字回复可能需要十几秒；具体 RTF 见 §7.1。
  这不是“实时语音”，更适合“高质量/离线生成”；Kokoro 仍是聊天默认。
- 显存/内存：模型常驻约 8–9 GB RSS（CPU），MPS 另计。
- 文本上限 500 字；长文本上游会分句合成，耗时线性增加。
- 打包 `.app` 已把 `scripts/{install,run}_cosyvoice.sh` 与 `devtools/cosyvoice/*.py` 复制到
  `Contents/Resources/cosyvoice/`；Python 环境与模型仍在首次安装时下载，不随包分发。
- App 强杀时子进程可能遗留；正常退出会在 `willTerminate` 终止（见 `CosyVoiceProcessRegistry`）。
- macOS 13/14 不保证可用；目标 macOS 26+（与 App 一致）。

### 7.1 实测（Apple Silicon，38 GB，2026-10-27）

同一句 20 字（约 4.5 s 音频），热态、14 线程：

| 配置 | 总耗时 | flow | LLM | RTF | 备注 |
| --- | ---: | ---: | ---: | ---: | --- |
| CPU，flow 10 步 | 11.7 s | 8.3 s | 3.4 s | 2.59 | 质量优先，最慢 |
| CPU，flow 6 步 | 9.1 s | 5.4 s | 3.7 s | 1.83 | **server 默认 6 步** |
| CPU，flow 4 步 | 6.5 s | 3.2 s | 3.4 s | 1.50 | `COSYVOICE_FLOW_STEPS=4` 速度优先 |
| MPS hybrid，4 步 | 7.1 s | 1.3 s | 5.8 s | 1.43 | flow 变快，但 LLM 在 MPS 上变慢 |

- 启动到 `/health` ready 实测 **22.2 s**（含 import、模型加载与预热）；App 轮询上限 90 s。
- 本机音色 45 字样音 ASR 逐字复核一致；一段 5–10 s 语音在 CPU 6 步下通常 **8–12 s** 出结果，
  **不作为实时聊天承诺**。
- 内存：常驻约 **8.65 GB RSS**（CPU）。
- 结论：**CosyVoice3 定位为“高质量/离线/克隆”模式，不是聊天默认**。如果要实时语音，
  继续用 Kokoro，或后续接云 TTS / 更小模型。`COSYVOICE_FLOW_STEPS=4` 可把延迟压到
  约 6–7 s/条（仍取决于文本长度）。

## 8. 隐私

- 安装后推理全在本机；`/tts` 只监听 127.0.0.1，文本不出设备。
- 日志只记录 `text_len`、音色、耗时、RTF，不打印正文。
- 模型下载是用户显式同意的网络请求；参考音、合成音频只存本机。
- 与云 TTS 的区别：不经过第三方服务器；代价是体积/启动/速度。

## 9. 故障排查

| 现象 | 排查 |
| --- | --- |
| 设置页显示“未安装” | 看安装日志尾部；确认 `uv`/`conda`、`ffmpeg`、磁盘 ≥10 GB、网络可达 Hugging Face |
| `/health` 一直 503 | 模型仍在加载；首次 30–90 s 正常；查 sidecar stderr |
| 端口 5051 被占 | 换端口或停掉旧进程：`lsof -nP -iTCP:5051 -sTCP:LISTEN` |
| 安装脚本找不到 | 源码运行需 `scripts/`；打包 App 看 `Contents/Resources/cosyvoice/`；可用环境变量覆盖 |
| 合成很慢 | 见 §7；先确认设备（CPU/MPS）、flow steps、线程数；必要时切回 Kokoro |
| App 退出后进程仍在 | 手动 `pkill -f devtools/cosyvoice/server.py`；正常退出应自动终止 |
| 新增音色失败 | 确认音频是 wav/m4a/aiff（不支持 mp3）、5–30s、可解码；参考文本必须与音频逐字对应 |
| 新增后列表没出现 | 服务未运行会在下次启动生效；服务运行中应自动 `/voices/reload`，可手动「重新检测」或重启服务 |
| 删除按钮不可用 | 预置音色不可删除；自定义音色才可删 |

## 10. 代码位置

| 层 | 文件 |
| --- | --- |
| App 引擎 dispatch | `app/Sources/WeChatBot/Services/VoiceSynthesisService.swift` |
| App HTTP 客户端 | `app/Sources/WeChatBot/Services/CosyVoiceClient.swift` |
| 服务生命周期 | `app/Sources/WeChatBot/Services/CosyVoiceRuntime.swift` |
| 安装/下载/删除 | `app/Sources/WeChatBot/Services/CosyVoiceInstaller.swift` |
| 音色/健康模型 | `app/Sources/WeChatBot/Models/CosyVoiceVoice.swift` |
| 音色管理（增删改/音频导入） | `app/Sources/WeChatBot/Services/CosyVoiceVoiceStore.swift` |
| 音色管理 UI | `app/Sources/WeChatBot/Views/Components/CosyVoiceVoiceManagerSheet.swift` |
| 设置 UI | `app/Sources/WeChatBot/Views/VoiceSettingsPanel.swift` |
| 试听 | `app/Sources/WeChatBot/Services/VoicePreviewController.swift` |
| Sidecar | `devtools/cosyvoice/server.py`、`patch_repo.py`、`CONTRACT.md` |
| 安装/启动脚本 | `scripts/install_cosyvoice.sh`、`scripts/run_cosyvoice.sh` |
| 打包 | `scripts/build_app.sh`（复制到 `Contents/Resources/cosyvoice/`） |

## 11. 测试与验证状态（2026-10-27）

已完成：

- `GET /health` / `GET /voices` / `POST /tts` 本机音色真实服务 E2E：24k mono WAV 正常；
- App 侧真实服务 E2E（两种路径）：复用已运行服务 + App 托管 `runtime.start/stop`；
  托管路径整段 29.1s（加载 ~22s + 合成 2.96s），停止后 5051 释放、无 `server.py` 残留；
- `scripts/install_cosyvoice.sh --dry-run` 在源码路径与 `--home` 生产路径下均输出正确的
  `LOCAL_DIR/VENV/MODEL_DIR/REFS/MARKER`；打包 `.app` 的 `Contents/Resources/cosyvoice/`
  已实际生成并验证脚本存在；
- `swift test`：**398 项 0 失败（8 跳过）**；`--filter CosyVoice`：**58 项（2 跳过）0 失败**；
- 导出自定义音色 zip 含全部契约文件、`personal_use_only=true`、备份说明；内置拒绝、空列表报错；
- `bash scripts/check.sh --with-go` 通过（Swift + Go + 文档/脚本静态检查）。

未完成/待用户环境验证：

- **真机微信发送 24k SILK**：本次未在运行中的 WeChat 上完成实际发送（需要 App 启动 bot 并捕获
  R3 文本/语音句柄）；bridge 侧 24k WAV 解码与 24k SILK 直接编码已有单测覆盖。
- App 内完整 8GB 下载安装：脚本/路径/安装标记与已安装服务均已验证，但完整下载流程未在 UI 中跑完。
- 流式 `/tts`、wetext 原生文本前端：未做（当前数字/日期读法实测正常）。

## 11.1 测试命令


- `app/Tests/WeChatAITests/CosyVoiceTests.swift`：Codable 兼容、endpoint 校验、client 请求/错误、
  installer 进度解析、runtime 健康轮询、回退计划；
- `swift test --filter CosyVoice`；
- `bash scripts/check.sh`；
- 真机：安装 → 启动 → 本机音色各发一条 → 验证 24k SILK 可播放、失败回退 Kokoro。
