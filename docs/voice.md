# 语音能力（入站转写 / 出站合成）

> 状态：**入站转写与出站语音发送均已在微信 4.2.0.5 真机打通（2026-10-26）。**
> 出站采用官方 SILK SDK 的 24k WeChat 兼容编码，TTS 语音可正常播放；首次启用/微信重启后仍需捕获
> 文本/语音句柄（bridge 重启自动恢复）。
> 目标微信：4.2.0.9 (270345)（2026-10-27 适配，文本链路已真机验证；语音发送沿用 4.2.0.5 同一链路，本轮未复测，首次使用需手动发一条语音捕获句柄；历史 4.2.0.5 (270341) 已验证）
> · macOS 26+ · 本地处理、数据不出设备
> 相关：[`architecture.md`](architecture.md)、[`bridge.md`](bridge.md)、[`core-services.md`](core-services.md)、[`ui-design.md`](ui-design.md)

## 1. 能力与现状

| 能力 | 实现 | 真机状态 |
| --- | --- | --- |
| 入站语音事件 | Hook `msg_type=34` → bridge 解析 `<voicemsg>`、登记下载元数据、把 `[语音]` 替换为 `{"type":"voice","data":{"duration_ms":N}}` | ✅ 真机收到事件、时长正确 |
| 入站音频获取 | `POST /fetch_voice`：`triggerDownload(fileType=15)` → AES-ECB → SILK 校验 → 落盘 `.silk` + 16k WAV | ✅ 2026-10-26 真机验证：3 条真实语音全部成功（含 3.8s/7.0s/4.2s），fileType **15 (0x0F)** 是关键 |
| 语音转写 | `VoiceTranscriptionService`（SpeechAnalyzer / SpeechTranscriber，zh_CN，本地、离线） | ✅ 真机端到端验证：入站 WAV 正常转写；系统语音资源可由 App 内按钮直接下载 |
| 语音气泡/记忆/引用 | 转写落库、气泡展示、可关闭、进上下文/长期记忆、引用语音带转写 | ✅ 单测覆盖；真机待音频链路 |
| 出站 TTS | sherpa-onnx 静态链接 + Kokoro multi-lang v1_1（内置音色）+ ZipVoice distill int8（零样本克隆）；`rule_fsts` 数字/日期/电话规范化 + 整段一次合成 | ✅ 单测 + 本机样本；Kokoro 默认、ZipVoice 克隆较慢（见 §6） |
| 出站发送 | App 传引擎原生 24k WAV（兼容旧 16k WAV/裸 PCM）→ bridge 按 WAV 头识别采样率（16k 才重采样）→ **官方 SILK SDK（-tencent）编码** → CDN 上传 → R3 `uploadvoice` 任务（0x7F / WxSendVoiceMsg） | ✅ 2026-10-26 真机：TTS 5s 语音正常播放；关键是从 go-silk 换成官方 24k SILK 编码 |
| 语音长度设置 | 全局设置，默认上限 30s（5–60），超限改文字或按句截断 | ✅ 设置与单测 |
| 语音回复策略 | 全局开关、概率、对等、仅短回复（全局设置） | ✅ 决策纯函数 + 单测 |

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
 → VoiceSynthesisService（Kokoro / ZipVoice / CosyVoice）→ 24k WAV
 → POST /send_voice {"user_id"/"group_id","pcm16k","duration_ms"}
 → bridge 官方 SILK SDK（`bridge/silkenc`）编码 24k Tencent SILK → uploadvoice → send_voice
 → 失败（含 voice_send_unsupported）→ 自动改发文字，不重试语音
```

### 提示词里的语音标注与出站清洗（2026-10-26）

- `[语音 Ns] 转写` 只是**入站**语音在提示词里的系统标注，让模型知道「对方发的是语音、
  时长多少、说了什么」。
- AI 自己发出的 TTS 语音回复进入历史时**只保留正文**，不加 `[语音 Ns]`：否则模型会把
  标注当成自己的回复格式照抄，下一轮文字回复就以 `[语音 8s]` 开头发到微信（真机复现，
  见 §7.3）。
- 回复出站前统一清洗：模型误抄的 `[语音 Ns]` / `[语音]` / `[语音，转写失败]`（含全角括号）
  会被删除，再收敛多余空白；清洗后只剩标注时按「空回复」处理（重试/报错），不会发给任何人。
- 长期记忆总结同理：关闭「转写写入记忆」时只有入站语音退化为 `[语音 Ns]` 标签，
  出站语音仍保留正文，避免记忆里出现只有标注的「我：」行。

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
{"user_id":"wxid_x","pcm16k":"<base64 16k 单声道 s16le、或 16k/24k 单声道 16-bit WAV>","duration_ms":1000}
```

- 裸 PCM 仍按 16k 处理（旧契约）；带 RIFF 头的 WAV 以 `fmt ` 块采样率为准，只接受 16k/24k。
- 24k 输入直接进 SILK；16k 输入仍走 16k→24k 线性插值。

成功：`{"ok":true,"duration_ms":N}`（实际时长按 SILK 帧计算）。
未支持/失败：`{"ok":false,"error":"voice_send_unsupported"}` 或可读中文原因。

## 4. 设置

> 语音设置面板同时位于「机器人 → 语音」和「设置 → 语音」；两处复用同一组件。
> **会话详情菜单不提供语音设置**：转写、语音回复、概率、对等、仅短回复、引擎与音色均为全局设置。

> 语音发送复用「R3 原生发送」开关。首次启用后，App 会要求捕获文本/语音句柄、显示启动倒计时；
> 未就绪或发送失败时自动降级文字。首次启用后，请先在本机微信手动发一条文字 + 一条语音捕获句柄。
> 开启「允许语音回复」时立即检测句柄并弹出捕获引导；bridge 启动后若已开启语音回复但句柄缺失，
> 也会自动提示一次（同一 App 会话最多一次）。

### 4.1 界面（2026-10-27 精简）

- **语音转写**：三个开关 + 「转写资源」行；资源未安装时在行内直接「下载」，不再额外占一块提醒。
- **语音回复**：默认只显示总开关；开启后才展开概率、对等、短回复阈值、最长时长与超限处理。
- **语音引擎与音色**（原「语音引擎（TTS）」+「语音模型与克隆音色」合并）：
  - 引擎：Kokoro / ZipVoice 克隆 / CosyVoice3（本地旁路，可选下载）；Kokoro 仍为默认；
  - 音色：Kokoro 使用官方 103 个内置音色的 **sid → name** 映射（中文女声 55 / 中文男声 45 /
    英文女声 3），支持搜索、分组与逐项试听；ZipVoice 用克隆档案菜单选择，不再手填档案 ID；
    CosyVoice3 使用本机 `voices.json` 里的音色（**App 不内置音色**，
    普通用户安装后为空），并提供「管理音色…」：可导入 5–30s 参考音新增自定义音色、
    编辑/删除（内置不可删）、自动转写参考文本与试听；自定义音色可导出 `.zip` 备份（内置不可导出）；
  - 语速：Kokoro 提供 1.0× / 1.25× / 1.5× 三档快捷（默认 1.25×，0.5×–2.0× 仍可由设置写入）；
    整段合成下 1.5× 会偏快，1.25× 是自然度优先的默认值；
  - 模型：只展示当前引擎真正需要的那份（Kokoro 1 个；ZipVoice = 主模型 + 声码器），
    同一行下载/取消/重试/删除；首次下载弹确认框（记录 `modelDownloadConsent`），
    去掉「下载全部」与逐模型行；
- **试听**：复用真实 `VoiceSynthesisService`（同引擎/音色/语速/原生 24k WAV），本地 `AVAudioPlayer`
  播放，不发往微信、不联网；切换音色/语速、离开页面或再次点按即停止。全局只保留一个播放器。
   CosyVoice3 试听走本地 HTTP 服务，服务未启动时先提示安装/启动。
- **语音发送状态**：只在开启「允许语音回复」时出现；去掉与状态摘要重复的两行句柄明细。
- **句柄引导**：开启「允许语音回复」时先刷新 `/voice_status`，未就绪即弹 `VoiceHandleSetupSheet`；
  bridge 启动后若已开启语音回复且文本/语音句柄缺失，自动提示一次（同一 App 会话最多一次）。
  bridge 刚启动、hook 尚未连接时会最多等待约 60 秒再判断，避免检测太早漏报。
  弹窗展示当前状态与原因（bridge 未连接、R3 未开启、版本不支持、登录预热中），并提供「重新检测」。

`BotSettings.voice`（可选结构，缺键默认；旧配置完全兼容）：

- 入站：`transcriptionEnabled`（默认开）、`showTranscriptInBubble`（开）、`saveTranscriptToMemory`（开）
- 回复：`replyEnabled`（默认关）、`replyProbability`（0.3）、`mirrorIncomingVoice`、`shortReplyOnly`（开）、
  `shortReplyMaxChars`（80）、`maxVoiceSeconds`（30，5–60）、`overLimit`（text/truncate）
- 引擎：`engine`（kokoro/zipvoiceClone/cosyVoice）、`kokoroSpeakerID`（0–102，读取/保存时收敛）、
  `kokoroSpeed`（默认 1.25）、`cloneID`、`modelDownloadConsent`
- CosyVoice3：`cosyVoiceVoiceID`（本机 voices.json 中的音色 id；未导入时为空）、`cosyVoiceEndpoint`
  （默认 `http://127.0.0.1:5051`）、`cosyVoiceAutoStart`（默认 true）；模型/运行环境单独下载，
  不占用 sherpa `modelDownloadConsent`

语音开关全部为全局设置（`BotSettings.voice.transcriptionEnabled` / `replyEnabled` 等）：
关闭转写后不再发起新的语音下载与转写，已有转写仍可显示并参与上下文；关闭语音回复后只发文字。
概率、对等、短回复、引擎与音色同样由全局设置控制。

## 5. 语音模型

- 目录：`~/Library/Application Support/WeChatAI/models/`（不入库、不打包）。
- **首次下载需在语音设置中确认并联网下载**；全部模型合计约 **528MB**
  （Kokoro≈365MB + ZipVoice≈109MB + vocoder≈54MB），只启用所需引擎时体积更小。
- **模型不会自动下载**：启动 App、打开语音页、收到语音消息都不会触发联网；只有用户点「下载」并确认后才开始。
- 下载入口按当前引擎聚合：Kokoro 只需 365MB；ZipVoice 需要主模型 + 声码器约 163MB。
  确认框会写明本次下载的模型与体积，同意后写入 `modelDownloadConsent`；
  下载中可取消，失败可重试，已就绪的模型不会重复下载。模型行右侧菜单可删除当前引擎模型，
  不会误删另一个引擎的文件。
- 「允许下载语音模型」只约束下载入口；模型文件已就绪（如重装 App、恢复配置）时直接使用，
  不要求重新同意，也不会再次下载。
- 模型体积：
  | 模型 | 体积 | 用途 |
  | --- | --- | --- |
  | `kokoro-multi-lang-v1_1` | 约 365 MB | 默认引擎，103 个内置音色（官方 sid → name 映射） |
  | `sherpa-onnx-zipvoice-distill-int8-zh-en-emilia` | 约 109 MB | 零样本克隆（参考音频 + 参考文本） |
  | `vocos_24khz.onnx` | 约 54 MB | ZipVoice 声码器 |
  | `Fun-CosyVoice3-0.5B-2512` | 约 5–7 GB | 可选高保真引擎（本地 Python 旁路，零样本克隆） |
  | CosyVoice 运行环境（Python 3.10 + PyTorch） | 约 2–3 GB | CosyVoice3 推理服务，独立安装 |
- **数字/日期/电话**：Kokoro 模型目录自带 `date-zh.fst` / `phone-zh.fst` / `number-zh.fst`，
  App 会把它们按 `date → phone → number` 的顺序传给 `rule_fsts`。顺序不能反：`phone` 必须在
  `number` 前面，否则手机号会被读成“一百三十八亿…”。`%` 不在 FST 处理范围内，进 TTS 前会先转
  成“百分之 N”。
- **CosyVoice3**：模型与运行环境由独立安装器管理（设置页「下载/安装」），不写入
  `modelDownloadConsent`、不进入 sherpa 模型清单；模型缺失或服务未启动时回退 Kokoro。
- 模型就绪判定按实际文件（Kokoro 的 model/voices/tokens、ZipVoice 的 tokens/encoder/decoder），
  不再只看解包目录；tar 中途失败留下的半截目录会被视为未就绪，下载不会跳过。
- 下载失败、磁盘不足或模型缺失时，语音回复自动降级为文字，不影响文本回复；可在设置中重试下载。
- **系统中文语音资源**：转写依赖系统语音资源，部分机器需先在 系统设置 → 辅助功能 → 朗读内容
  下载中文语音；语音设置页也提供「下载中文语音资源」按钮（调用 `AssetInventory`）。
  系统语音资源与上表 TTS 模型是两套独立资源。
- 失败降级：TTS 模型缺失、合成失败、发送句柄未就绪或微信侧拒绝时，自动改发文字，不重试语音。
- 下载后校验 SHA256（`scripts/fetch_sherpa.sh` 负责运行库；模型由 App 下载）。
- 模型、参考音频、转写与合成音频都只存本机，不上传、无遥测；详见 §8。
- 克隆：导入 10–30s 单人参考音频（wav/m4a），App 用本地 STT 自动生成参考文本（可修正）；
  ZipVoice 要求参考文本与音频严格对应。
- 许可：sherpa-onnx Apache-2.0；Kokoro/ZipVoice 权重许可以 model card 为准，发行前需复核；
  Fun-CosyVoice3-0.5B-2512 为 Apache-2.0。

## 6. 性能与限制

- STT：9.2s → 0.23s；46.6s → 0.51s（RTF 0.011–0.043）；峰值内存约 22 MB；完全离线。
- TTS（debug 构建、4 线程、模型已缓存）：Kokoro RTF≈0.43（5.8s 音频约 2.5s）、ZipVoice distill int8 RTF≈0.92（3.2s 音频约 3.0s）；首次加载额外 1–3s，release 会更快。
- 整段合成（关闭内部按标点切分）会比逐段合成略慢：49 字回复 Kokoro 仍约 2–3s；换来的是
  句内语气连续、停顿自然。极端长文本（>300 字）仍建议用 `maxVoiceSeconds`/短回复策略限制。
- CosyVoice3（本地 Python 旁路，可选）：启动到 ready 约 22s，常驻 RSS 约 8.65GB；
  CPU 6 步热态 RTF≈1.83、4 步≈1.50，5–10s 语音通常 8–12s 出结果；**定位高质量/离线，
  不是实时聊天默认**。详见 [`cosyvoice.md`](cosyvoice.md)。
- SILK：5.2s/16k PCM → 9,921 B；编码约 0.04s、解码约 0.005s（pilk 实测）；bridge 静态链接官方 SILK SDK（`bridge/silkenc`），无 ffmpeg/pilk 运行时依赖。
- 微信语音消息限制 60s；超限按设置改文字/截断。
- 语音回复不保留系统「@ 提及」；群聊带 @ 时直接走文字（避免丢失提及）。AI 自己写进正文的
  开头 `@昵称` 会在朗读稿清洗时去掉，不再念出昵称。
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
- 实现：官方 SILK SDK 以 cgo 包 `bridge/silkenc` 静态编入 bridge；TTS 24k PCM 直通（旧 16k 输入才先线性重采样到 24k）、
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

### 7.3 回复带上 `[语音 Ns]`（已解决：提示词把标注喂给了模型）

- 真机现象（2026-10-26 21:45，微信 4.2.0.5）：文字回复以 `[语音 8s] …` 开头发到了群里。
- 根因：上一轮 TTS 语音回复在短期历史里被渲染成 assistant 内容
  `[语音 10s] <正文>`（`ChatEngine.promptText` 对所有语音消息一律加时长标注），
  模型把这条标注当成自己的回复格式照抄；而回复出站前没有任何清洗。
- 修复（三层）：
  1. 标注只用于入站语音；出站语音进提示词/记忆时只保留正文，占位回显直接跳过；
  2. system 提示明确「标注是系统加的，回复里绝对不要输出」；
  3. 回复进入发送计划前统一清洗 `[语音 Ns]` 等标注，清洗后为空按空回复处理。
- 回归测试：`VoiceReadTests` 覆盖出站语音提示词、记忆转录与回复清洗；
  `CoreServicesTests` 覆盖 `buildMessages` 里出站语音历史不带标注、system 提示禁止输出。

### 7.4 语音“不连贯/吞字”（2026-10-27 已修）

真机聆听与本地可控 A/B 定位到三个叠加问题：

1. **数字整段被吞**：Kokoro 词表没有 ASCII 数字，App 没有传 `rule_fsts`，
   `3`/`2026`/`13800138000`/`85%` 全部被当作 OOV **静默跳过**（不是读错，是没读）。
   修复：`VoiceModelStore.kokoroConfig()` 把模型目录里的 `date-zh.fst`、`phone-zh.fst`、
   `number-zh.fst` 按 `date → phone → number` 传入 `SherpaOnnxOfflineTtsConfig.rule_fsts`。
   `phone` 必须在 `number` 之前，否则手机号会读成“一百三十八亿…”；`%` 不在 FST 内，
   由朗读稿清洗先转成“百分之 N”。
2. **按标点碎片化合成**：Kokoro 默认按 `。！？，；：` 切句、`min_words=5`/`max_words=20`
   （中文每字算 1 word），49 字回复被切成 4 段独立合成后首尾相接，每段重新起调、句尾拖长。
   修复：generation `extra` 覆盖为 `min_words_in_sentence=10000`、`max_words_in_sentence=10000`，
   整段一次合成；ZipVoice 同步改成 `min/max_words_in_sentence`（旧 `min_char_in_sentence`
   在 v2.0.0 已不是有效键）。
3. **停顿被压没/采样率往返**：`silence_scale=0.2` 把句读停顿压到 20%，逐段拼接时又靠碎片拖长
   掩盖；App 强制 16k 再由 bridge 线性插值回 24k。修复：`silence_scale=0.8`、Kokoro 默认
   语速改 1.25×（1.0/1.25/1.5 三档）、App 直接输出引擎原生 24k WAV，bridge 以 WAV 头采样率
   为准（16k 才重采样），并加 5ms 淡入淡出。

证据（`_local/voice-lab/`，gitignored）：

- 4 个碎片单独合成 1.66+2.30+1.44+1.77 = **7.17s**，与整段拼接 7.18s 吻合；
- 同一句“3点半到2026年10月26日，电话13800138000，涨了85%”现状只读出“点半到年月日，电话，
  涨了”（3.25s）；修复后 9.92s，读出“三点半/二零二六年十月二十六日/幺三八…/百分之八十五”；
- 整段 + `speed 1.25 + silence 0.8` 实测约 6.2 字/秒、停顿 200–540ms；`speed 1.5 + silence 0.2`
  会到 10.4 字/秒、无停顿。

回归测试：`VoiceSynthesisTests` 覆盖朗读稿清洗（@前缀/百分号/货币/破折号）、24k WAV、
FST 顺序与整段合成的参数；bridge `voice_test.go` 覆盖 16k/24k WAV 解码与编码。

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
| 音色/试听 | `Models/KokoroVoiceCatalog.swift`（官方 sid → name）、`Services/VoicePreviewController.swift`（共享试听播放器） |
| CosyVoice3 | `Services/CosyVoice{Client,Runtime,Installer}.swift`、`Models/CosyVoiceVoice.swift`、`devtools/cosyvoice/`、`scripts/{install,run}_cosyvoice.sh`；详见 [`cosyvoice.md`](cosyvoice.md) |
| UI | `Views/VoiceSettingsPanel.swift`、`Views/Components/MessageBubble.swift`、`Views/ConversationsView.swift` |
| 数据 | `Models/Models.swift`、`Services/MemoryStore.swift`、`Core/AppStore+Runtime.swift` |

## 10. 测试

```bash
bash scripts/check.sh --with-go        # 静态 + Swift 全量 + Go
cd app && SWIFT_DISABLE_SANDBOX=1 swift test --scratch-path .build-lead
```

当前：Swift 398 项通过（8 项按环境跳过：模型未下载/联网/真实 E2E；含音色目录、CosyVoice 集成、语音合成/发送回归）；
Go 62 顶层 / 159 用例通过；release App 约 189MB。
语音实现与测试细节见 `bridge/voice.go`、`bridge/voice_test.go`；入站/出站契约与限制见本文件与 [`bridge.md`](bridge.md)。
