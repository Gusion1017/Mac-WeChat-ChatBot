# 语音能力（入站转写 / 出站合成）

> 状态：**入站转写与出站语音发送均已在微信 4.2.0.5 真机打通（2026-10-26）。**
> 出站采用官方 SILK SDK 的 24k WeChat 兼容编码，TTS 语音可正常播放；首次启用/微信重启后仍需捕获
> 文本/语音句柄（bridge 重启自动恢复）。
> 目标微信：4.2.0.5 (270341) · macOS 26+ · 本地处理、数据不出设备
> 相关：[`architecture.md`](architecture.md)、[`bridge.md`](bridge.md)、[`core-services.md`](core-services.md)、[`ui-design.md`](ui-design.md)

## 1. 能力与现状

| 能力 | 实现 | 真机状态 |
| --- | --- | --- |
| 入站语音事件 | Hook `msg_type=34` → bridge 解析 `<voicemsg>`、登记下载元数据、把 `[语音]` 替换为 `{"type":"voice","data":{"duration_ms":N}}` | ✅ 真机收到事件、时长正确 |
| 入站音频获取 | `POST /fetch_voice`：`triggerDownload(fileType=15)` → AES-ECB → SILK 校验 → 落盘 `.silk` + 16k WAV | ✅ 2026-10-26 真机验证：3 条真实语音全部成功（含 3.8s/7.0s/4.2s），fileType **15 (0x0F)** 是关键 |
| 语音转写 | `VoiceTranscriptionService`（SpeechAnalyzer / SpeechTranscriber，zh_CN，本地、离线） | ✅ 真机端到端验证：入站 WAV 正常转写；系统语音资源可由 App 内按钮直接下载 |
| 语音气泡/记忆/引用 | 转写落库、气泡展示、可关闭、进上下文/长期记忆、引用语音带转写 | ✅ 单测覆盖；真机待音频链路 |
| 出站 TTS | sherpa-onnx 静态链接 + Kokoro multi-lang v1_1（内置音色）+ ZipVoice distill int8（零样本克隆） | 🟡 引擎与样本可跑；Kokoro 默认、ZipVoice 克隆较慢（见 §6） |
| 出站发送 | bridge 收 16k WAV/PCM → 16k→24k 重采样 → **官方 SILK SDK（-tencent）编码** → CDN 上传 → R3 `uploadvoice` 任务（0x7F / WxSendVoiceMsg） | ✅ 2026-10-26 真机：TTS 5s 语音正常播放；关键是从 go-silk 换成官方 24k SILK 编码 |
| 语音长度设置 | 全局设置，默认上限 30s（5–60），超限改文字或按句截断 | ✅ 设置与单测 |
| 语音回复策略 | 全局开关、概率、对等、仅短回复 | ✅ 决策纯函数 + 单测 |

> 一句话：**入站转写与出站语音发送都已真机打通。**
> 入站关键是语音下载 `fileType=15`；出站关键是官方 SILK SDK 的 24k WeChat 兼容编码 +
> `uploadvoice` 任务（header/voiceFileId 已按真实请求对齐）。
> 中文语音资源缺失时，语音设置页提供“下载中文语音资源”按钮；下载后无需重启系统即可转写。

## 2. 数据流

### 入站（读）

```
微信语音 → Hook 事件（text="[语音]" + raw_message=<voicemsg>）
 → bridge registerIncomingVoice：解析 voiceurl/aeskey/voicelength/length
 → 事件 message[] 替换为 {"type":"voice","data":{"duration_ms":N}}
 → App VoiceFetcher → POST /fetch_voice {"message_id"}
 → bridge 下载分片 → AES-ECB 解密 → SILK 魔数/帧校验 → .silk + 16k WAV
 → App VoiceTranscriptionService（SpeechAnalyzer）→ ChatMessage.voiceTranscript
 → 气泡展示 / 上下文 `[语音 Ns] 转写` / 记忆与搜索
```

### 出站（说）

```
AI 回复文本 → decideVoiceReply（开关/概率/对等/短回复/模型就绪）
 → VoiceSynthesisService（Kokoro 或 ZipVoice）→ 16k WAV
 → POST /send_voice {"user_id"/"group_id","pcm16k","duration_ms"}
 → bridge 官方 SILK SDK（`bridge/silkenc`）编码 24k Tencent SILK → uploadvoice → send_voice
 → 失败（含 voice_send_unsupported）→ 自动改发文字，不重试语音
```

## 3. 接口契约

### 3.1 入站事件

```json
{"type":"voice","data":{"duration_ms":5200}}
```

- 事件不含 aeskey/CDN key；`raw_message` 保持原 XML（与既有图片行为一致）。
- 时长未知时 `data` 为 `{}`。

### 3.2 `POST /fetch_voice`（Bearer）

请求：`{"message_id":"<事件 message_id>"}`

成功（HTTP 200）：

```json
{"ok":true,"path":"file:///…/voice_x_16k.wav","silk_path":"file:///…/voice_x.silk","duration_ms":5200}
```

失败：HTTP 200 `{"ok":false,"error":"…"}`（不返回 500）；超时/下载失败会恢复登记，App 可重试。

### 3.3 `POST /send_voice`（Bearer）

请求：

```json
{"user_id":"wxid_x","pcm16k":"<base64 16k 单声道 s16le 或 16k WAV>","duration_ms":1000}
```

成功：`{"ok":true,"duration_ms":N}`（实际时长按 SILK 帧计算）。
未支持/失败：`{"ok":false,"error":"voice_send_unsupported"}` 或可读中文原因。

## 4. 设置

> 语音设置面板同时位于「机器人 → 语音」和「设置 → 语音」；两处复用同一组件。
> 会话详情里的语音转写/回复/概率覆盖已移除，统一使用全局设置。

> 语音发送复用「R3 原生发送」开关。首次启用后，App 会要求捕获文本/语音句柄、显示启动倒计时；
> 未就绪或发送失败时自动降级文字。首次启用后，请先在本机微信手动发一条文字 + 一条语音捕获句柄。

`BotSettings.voice`（可选结构，缺键默认；旧配置完全兼容）：

- 入站：`transcriptionEnabled`（默认开）、`showTranscriptInBubble`（开）、`saveTranscriptToMemory`（开）
- 回复：`replyEnabled`（默认关）、`replyProbability`（0.3）、`mirrorIncomingVoice`、`shortReplyOnly`（开）、
  `shortReplyMaxChars`（80）、`maxVoiceSeconds`（30，5–60）、`overLimit`（text/truncate）
- 引擎：`engine`（kokoro/zipvoiceClone）、`kokoroSpeakerID`、`kokoroSpeed`、`cloneID`、`modelDownloadConsent`

会话级语音覆盖已移除：语音转写/回复只使用全局设置，避免会话页出现重复配置。

## 5. 语音模型

- 目录：`~/Library/Application Support/WeChatAI/models/`（不入库、不打包）。
- **首次启用需在语音设置中勾选同意并联网下载**；全部模型合计约 **528MB**
  （Kokoro≈365MB + ZipVoice≈109MB + vocoder≈54MB），只启用所需引擎时体积更小。
- 模型体积：
  | 模型 | 体积 | 用途 |
  | --- | --- | --- |
  | `kokoro-multi-lang-v1_1` | 约 365 MB | 默认引擎，中英多音色（sid 选择） |
  | `sherpa-onnx-zipvoice-distill-int8-zh-en-emilia` | 约 109 MB | 零样本克隆（参考音频 + 参考文本） |
  | `vocos_24khz.onnx` | 约 54 MB | ZipVoice 声码器 |
- 下载失败、磁盘不足或模型缺失时，语音回复自动降级为文字，不影响文本回复；可在设置中重试下载。
- **系统中文语音资源**：转写依赖系统语音资源，部分机器需先在 系统设置 → 辅助功能 → 朗读内容
  下载中文语音；语音设置页也提供「下载中文语音资源」按钮（调用 `AssetInventory`）。
  系统语音资源与上表 TTS 模型是两套独立资源。
- 失败降级：TTS 模型缺失、合成失败、发送句柄未就绪或微信侧拒绝时，自动改发文字，不重试语音。
- 下载后校验 SHA256（`scripts/fetch_sherpa.sh` 负责运行库；模型由 App 下载）。
- 模型、参考音频、转写与合成音频都只存本机，不上传、无遥测；详见 §8。
- 克隆：导入 10–30s 单人参考音频（wav/m4a），App 用本地 STT 自动生成参考文本（可修正）；
  ZipVoice 要求参考文本与音频严格对应。
- 许可：sherpa-onnx Apache-2.0；Kokoro/ZipVoice 权重许可以 model card 为准，发行前需复核。

## 6. 性能与限制

- STT：9.2s → 0.23s；46.6s → 0.51s（RTF 0.011–0.043）；峰值内存约 22 MB；完全离线。
- TTS（debug 构建、4 线程、模型已缓存）：Kokoro RTF≈0.43（5.8s 音频约 2.5s）、ZipVoice distill int8 RTF≈0.92（3.2s 音频约 3.0s）；首次加载额外 1–3s，release 会更快。
- SILK：5.2s/16k PCM → 9,921 B；编码约 0.04s、解码约 0.005s（pilk 实测）；bridge 静态链接官方 SILK SDK（`bridge/silkenc`），无 ffmpeg/pilk 运行时依赖。
- 微信语音消息限制 60s；超限按设置改文字/截断。
- 语音回复不保留「@ 提及」；群聊带 @ 时直接走文字（避免丢失提及）。
- 语音发送依赖「R3 原生发送」开关；未开启时自动降级文字。
- 4.2 语音发送为实验路径：失败自动降级文字；filehelper 目标未验证。
- 转写失败/低置信度不会编造内容；静音幻觉由置信度门限过滤。

## 7. 已解决与剩余限制

### 7.1 入站（已解决）

- 4.2 语音下载使用 `triggerDownload(fileType=15)`（0x0F），走 `downloadFile` hook；fileType 5/6 会被拒绝。
- 真机验证：真实入站语音（非自消息）3 条，`/fetch_voice` 全部返回 16k WAV，时长与 XML 一致。
- 可通过请求体 `{"message_id":"…","file_types":[15]}` 覆盖（调试用）；默认已是 `[15]`。

### 7.2 出站（已解决：编码器不兼容）

- 4.2 语音发送 = `WxSendVoiceMsg` + CGI `uploadvoice`（opcode 0x7F，任务类 ctor/size/vtable 已写入
  `hook/versions/4_2_0_5_mac.json`）；上传仍用既有 CDN 上传链路。
- R3 模式会跳过 legacy 的 `setupSendImgMessageDynamic`，必须在 R3 初始化时补回上传 buffer 初始化。
- 真机定位（2026-10-26）：
  - 真实微信 SILK 走同一条上传/发送链路可正常播放，说明问题在编码器；
  - go-silk 输出能被 go-silk 自身解码，但微信无声/不停止；
  - **官方 SILK SDK（`silk-v3-decoder`，`-tencent`，24kHz）编码可正常播放**；
  - proto header 使用真实 17B `session_id`+`device_id`，上传 voiceFileId 使用
    `alita_1_<md5>_15_0_<seq>`，与真实请求一致。
- 实现：官方 SILK SDK 以 cgo 包 `bridge/silkenc` 静态编入 bridge；TTS 16k PCM 先线性重采样到 24k、
  补静音对齐 20ms 帧，再编码。
- 真机验证：TTS 5.1s 语音发送到测试账号，有声音、内容正确、可正常停止。

**使用限制：**

1. 首次启用语音发送或微信重启后，需要在本机微信**手动发一条文字 + 一条语音**捕获句柄；
   bridge 重启会自动恢复（seed 按微信 PID 持久化）。
2. bridge 刚启动的 **60 秒内** CdnManager 可能尚未解析（登录稳定门禁），语音上传会失败并降级文字；
   等待 60s 或先发一张图片即可恢复。
3. 语音发送走 R3 任务构造（`uploadvoice`/0x7F）；失败必须保持自动降级文字，不能重试语音（避免重复发送）。
4. 发送后桌面微信可能不回显（与文本发送一致），以手机/对方客户端为准。

> Hook 发送/下载改动只在 `hook/script.js` 与版本 JSON；公开文档不记录函数地址与偏移。

## 8. 隐私与安全

- 音频、转写、参考音频只存本机；日志不打印转写原文、音频字节、aeskey、CDN key。
- 转写展示/记忆可分别关闭；删除消息/会话时随本地存储清理。
- 首次启用或微信重启后需捕获发送句柄；默认 `replyEnabled=false`，句柄/倒计时未就绪时失败自动降级文字。
- 模型下载是用户显式同意后的网络请求，不上传任何用户数据。

## 9. 代码位置

| 层 | 文件 |
| --- | --- |
| Hook | `hook/script.js`（语音下载触发与 R3 发送任务入口） |
| Bridge | `bridge/voice.go`、`bridge/voice_test.go`、`bridge/incoming.go`、`bridge/http.go`、`bridge/main.go`、`bridge/param.go` |
| STT | `app/Sources/WeChatBot/Services/VoiceTranscriptionService.swift`、`VoiceFetcher.swift` |
| 回复决策 | `app/Sources/WeChatBot/Services/VoiceReplyDecision.swift` |
| TTS | `app/Sources/WeChatBot/Services/VoiceSynthesisService.swift`、`VoiceSynthesisAudio.swift`、`VoiceSynthesisText.swift`、`VoiceModelStore.swift`、`VoiceCloneStore.swift`、`Services/Sherpa/` |
| UI | `Views/Components/MessageBubble.swift`、`Views/SettingsView.swift`、`Views/ConversationsView.swift` |
| 数据 | `Models/Models.swift`、`Services/MemoryStore.swift`、`Core/AppStore+Runtime.swift` |

## 10. 测试

```bash
bash scripts/check.sh --with-go        # 静态 + Swift 全量 + Go
cd app && SWIFT_DISABLE_SANDBOX=1 swift test --scratch-path .build-lead
```

当前：Swift 304 项通过（2 项模型依赖测试按模型是否就绪跳过）；Go 62 顶层 / 159 用例通过；release App 约 189MB。
语音实现与测试细节见 `bridge/voice.go`、`bridge/voice_test.go`；入站/出站契约与限制见本文件与 [`bridge.md`](bridge.md)。
