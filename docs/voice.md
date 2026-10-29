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
| 出站 TTS | **CosyVoice3 是唯一引擎**：本地 Python 旁路（Fun-CosyVoice3-0.5B-2512，24 kHz，零样本克隆），App 通过回环 HTTP 调用；文本清洗后一次请求合成 | ✅ 单测 + 本机样本；需用户显式安装（约 8GB），非实时（见 §6） |
| 出站发送 | App 传 CosyVoice3 原生 24k WAV（兼容旧 16k WAV/裸 PCM）→ bridge 按 WAV 头识别采样率（16k 才重采样）→ **官方 SILK SDK（-tencent）编码** → CDN 上传 → R3 `uploadvoice` 任务（0x7F / WxSendVoiceMsg） | ✅ 2026-10-26 真机：TTS 5s 语音正常播放；关键是从 go-silk 换成官方 24k SILK 编码 |
| 语音长度设置 | 全局设置，默认上限 30s（5–60），超限改文字或按句截断 | ✅ 设置与单测 |
| 语音回复策略 | 全局开关、概率、对等、仅短回复（全局设置） | ✅ 决策纯函数 + 单测 |

> 一句话：**入站转写与出站语音发送都已真机打通。**
> 入站关键是语音下载 `fileType=15`；出站关键是官方 SILK SDK 的 24k WeChat 兼容编码 +
> `uploadvoice` 任务（header/voiceFileId 已按真实请求对齐）。
> 出站 TTS 只保留 CosyVoice3（本地 Python 旁路）；未安装、服务未启动或合成失败时，本条改发文字。
> 中文语音资源缺失时，「机器人 → 语音」提供“下载中文语音资源”按钮；下载后无需重启系统即可转写。

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
AI 回复文本 → decideVoiceReply（开关/概率/对等/短回复/CosyVoice3 就绪）
 → 已确定语音：跳过拟人化随机延迟（「语音回复免拟人化延迟」，默认开）
 → VoiceSynthesisService（CosyVoice3，HTTP 127.0.0.1:5051）→ 24k WAV
 → POST /send_voice {"user_id"/"group_id","pcm16k","duration_ms"}
 → bridge 官方 SILK SDK（`bridge/silkenc`）编码 24k Tencent SILK → uploadvoice → send_voice
 → 任一环节失败（CosyVoice3 未安装/服务未启动/合成失败/voice_send_unsupported）→ 本条改发文字，不重试语音
```

### 提示词里的语音标注与出站清洗（2026-10-26）

- `[语音 Ns] 转写` 只是**入站**语音在提示词里的系统标注，让模型知道「对方发的是语音、
  时长多少、说了什么」。
- AI 自己发出的 TTS 语音回复进入历史时**只保留正文**，不加 `[语音 Ns]`：否则模型会把
  标注当成自己的回复格式照抄，下一轮文字回复就以 `[语音 8s]` 开头发到微信（真机复现，
  见 §7.3）。
- 回复出站前统一清洗：模型误抄的 `[语音 Ns]` / `[语音]` / `[语音，转写失败]`（含全角括号）
  会被删除，再收敛多余空白；清洗后只剩标注时按「空回复」处理（重试/报错），不会发给任何人。
- 记忆提取同理：关闭「转写写入记忆」时只有入站语音退化为 `[语音 Ns]` 标签，
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

> 语音设置面板只位于「机器人 → 语音」，复用共用组件 `VoiceSettingsPanel`；设置页不再提供「语音」分类。
> **会话详情菜单不提供语音设置**：转写、语音回复、概率、对等、仅短回复、音色与语速均为全局设置。

> 语音发送复用「R3 原生发送」开关。首次启用后，App 会要求捕获文本/语音句柄、显示启动倒计时；
> 未就绪或发送失败时自动降级文字。首次启用后，请先在本机微信手动发一条文字 + 一条语音捕获句柄。
> 开启「允许语音回复」时立即检测句柄并弹出捕获引导；bridge 启动后若已开启语音回复但句柄缺失，
> 也会自动提示一次（同一 App 会话最多一次）。

### 4.1 界面（2026-10-29 收敛为 CosyVoice3）

- **语音转写**：三个开关 + 「转写资源」行；资源未安装时在行内直接「下载」，不再额外占一块提醒。
- **语音回复**：默认只显示总开关；开启后才展开概率、对等、短回复阈值、最长时长、超限处理
  与「语音回复免拟人化延迟」。
- **语音引擎与音色**：只剩 CosyVoice3 一组行（引擎选择器已移除，CosyVoice3 是唯一 TTS 引擎）：
  - 本地服务：状态（运行中/启动中/未运行/异常/未检测）+ 「启动」/「停止」+「重新检测」；
  - 运行环境与模型：安装/重新安装/删除，合计约 8GB（运行环境约 2–3GB + 模型约 5–7GB）；
    首次安装弹确认框，安装中可取消、失败可重试；
  - 音色：本机音色菜单 + 「管理音色…」（无音色时显示「添加音色…」）；**App 不内置音色**，
    普通用户安装后为空，导入 1–5 条参考音（每条 5–30s，合计 ≤30s）新增自定义音色、编辑/删除
    （内置不可删）、自动转写参考文本与试听；多条参考文本需同时填写或同时留空（全空即
    `cross_lingual`，只克隆音色）；自定义音色可导出 `.zip` 备份（含 `refs/` 原始片段，内置不可导出）；
  - 语速：0.5×–2.0×（步进 0.05），默认 1.0×；
  - 自动启动：开关；**仅当「允许语音回复」开启、本开关开启、CosyVoice3 已安装且有音色时**，
    启动 App / 打开语音面板会拉起本地服务；面板内仍可手动「启动」；
  - 服务地址：默认 `http://127.0.0.1:5051`，只接受回环地址；
- **试听**：直接调用同一个本地 CosyVoice3 HTTP 服务（同音色/语速/原生 24k WAV），本地 `AVAudioPlayer`
  播放，不发往微信、不联网；切换音色/语速、离开页面或再次点按即停止。全局只保留一个播放器。
  CosyVoice3 试听走本地 HTTP 服务，服务未启动或未选音色时先提示安装/启动。
- **语音发送状态**：只在开启「允许语音回复」时出现；去掉与状态摘要重复的两行句柄明细。
- **句柄引导**：开启「允许语音回复」时先刷新 `/voice_status`，未就绪即弹 `VoiceHandleSetupSheet`；
  bridge 启动后若已开启语音回复且文本/语音句柄缺失，自动提示一次（同一 App 会话最多一次）。
  bridge 刚启动、hook 尚未连接时会最多等待约 60 秒再判断，避免检测太早漏报。
  弹窗展示当前状态与原因（bridge 未连接、R3 未开启、版本不支持、登录预热中），并提供「重新检测」。

`BotSettings.voice`（可选结构，缺键默认；旧配置完全兼容）：

- 入站：`transcriptionEnabled`（默认开）、`showTranscriptInBubble`（开）、`saveTranscriptToMemory`（开）
- 回复：`replyEnabled`（默认关）、`replyProbability`（0.3）、`mirrorIncomingVoice`、`shortReplyOnly`（开）、
  `shortReplyMaxChars`（80）、`maxVoiceSeconds`（30，5–60）、`overLimit`（text/truncate）、
  `skipHumanizeDelayForVoiceReply`（默认开）
- CosyVoice3：`cosyVoiceVoiceID`（本机 `voices.json` 中的音色 id；未导入时为空）、
  `cosyVoiceEndpoint`（默认 `http://127.0.0.1:5051`，仅回环）、
  `cosyVoiceAutoStart`（默认 true）、`cosyVoiceSpeed`（0.5–2.0，默认 1.0）
- 旧键 `engine` / `kokoroSpeakerID` / `kokoroSpeed` / `cloneID` / `modelDownloadConsent`
  在解码时被忽略，保存时不再写入（旧 `config.json` 仍可正常加载）。

语音开关全部为全局设置（`BotSettings.voice.transcriptionEnabled` / `replyEnabled` 等）：
关闭转写后不再发起新的语音下载与转写，已有转写仍可显示并参与上下文；关闭语音回复后只发文字。
概率、对等、短回复、音色与语速同样由全局设置控制。

`skipHumanizeDelayForVoiceReply` 默认开启：`decideVoiceReply` 命中语音后直接进入 TTS 合成，
不再叠加 `[minDelayMs, maxDelayMs]` 的随机等待（否则「合成耗时 + 拟人化延迟」会让用户等两次）；
关闭后恢复与文字回复一致的拟人化节奏。文字回复不受该设置影响。

## 5. 语音模型

- **唯一 TTS 引擎是 CosyVoice3**：模型 `Fun-CosyVoice3-0.5B-2512` 与 Python 3.10 + PyTorch
  运行环境由 App 内的独立安装器管理，保存在
  `~/Library/Application Support/WeChatAI/cosyvoice/`（源码运行时为 `_local/cosyvoice/`），
  与 App 分发包分离；安装细节见 [`cosyvoice.md`](cosyvoice.md)。
- **安装需用户显式确认**：在「机器人 → 语音 → 语音引擎与音色 → 运行环境与模型」点「下载并安装…」，
  确认框写明体积（合计约 8GB：运行环境约 2–3GB + 模型约 5–7GB）；安装中可取消，失败可重试，
  已安装可删除。App 不再有「模型下载同意」（`modelDownloadConsent`）与「下载全部」，
  也不再下载旧引擎的模型；旧 `~/Library/Application Support/WeChatAI/models/` 目录不再由 App 使用。
- 资源体积：
  | 资源 | 体积 | 用途 |
  | --- | --- | --- |
  | `Fun-CosyVoice3-0.5B-2512` | 约 5–7 GB | 唯一 TTS 引擎（本地 Python 旁路，零样本克隆） |
  | CosyVoice 运行环境（Python 3.10 + PyTorch） | 约 2–3 GB | CosyVoice3 推理服务，随安装器独立部署 |
- **音色**：App 不内置任何音色，安装后音色列表为空；在「管理音色…」导入 1–5 条单人参考
  音频（每条 5–30s、合计 ≤30s；wav/m4a/aiff，不支持 mp3）新增自定义音色。参考音频可拖入或
  一次多选批量导入，导入时即校验格式与时长；片段可上移/下移调整合并顺序。每条参考音频配一段
  逐字对应的参考文本（可逐条或「自动转写全部」后修正），多条文本必须同时填写或同时留空；
  全部留空即 `cross_lingual`（只克隆音色）。保存时 App 按顺序把多条音频拼接为一条 `prompt.wav`
  （片段间 0.25s 静音）、各条文本用换行连接为 `prompt.txt`，原始片段保存在 `refs/`；服务端
  仍按单条 prompt 合成。**CosyVoice3 的 speech tokenizer 硬限制参考音 ≤30 秒**（含间隔静音），
  超过会合成失败，App 保存时会拦截；导入前可先裁掉首尾静音。旧单参考音色继续可用，音色只存本机。
- **数字/日期/电话**：旧引擎依赖的 `rule_fsts`（`date-zh` / `phone-zh` / `number-zh`）随旧引擎
  一并移除，不再有 FST 文件；CosyVoice3 侧的数字/日期读法实测正常。
  语音文本清洗仍在：Markdown/emoji/URL、`[语音 Ns]` 标注、`%` → 百分之、货币口语化等（见 §2）。
- **系统中文语音资源**：转写依赖系统语音资源，部分机器需先在 系统设置 → 辅助功能 → 朗读内容
  下载中文语音；「机器人 → 语音」也提供「下载中文语音资源」按钮（调用 `AssetInventory`）。
  系统语音资源与上表 TTS 资源是两套独立资源。
- 失败降级：CosyVoice3 未安装、运行环境/模型缺失、服务未启动、合成失败、发送句柄未就绪或
  微信侧拒绝时，自动改发文字，不重试语音；不影响文本回复。可在「机器人 → 语音」重试安装或启动服务。
- 模型、参考音频、转写与合成音频都只存本机，不上传、无遥测；详见 §8。
- 许可：`Fun-CosyVoice3-0.5B-2512` 为 Apache-2.0（模型卡）；CosyVoice 上游代码与运行依赖
  许可以各自仓库为准。

## 6. 性能与限制

- STT：9.2s → 0.23s；46.6s → 0.51s（RTF 0.011–0.043）；峰值内存约 22 MB；完全离线。
- TTS（CosyVoice3，本地 Python 旁路，**非实时**）：启动到 `/health` ready 实测约 22s
  （含 import、模型加载与预热）；常驻 RSS 约 8.65GB；20 字（约 4.5s 音频）热态 CPU 6 步
  RTF≈1.83、4 步≈1.50（约 9.1s / 6.5s）；5–10s 语音在 CPU 6 步下通常 8–12s 出结果。
  `COSYVOICE_FLOW_STEPS=4` 可换速度（质量略降）。详见 [`cosyvoice.md`](cosyvoice.md) §7。
- 长回复会显著拉长合成时间：极端长文本（>300 字）仍建议用 `maxVoiceSeconds`/短回复策略限制。
- 输出：CosyVoice3 原生 24k 单声道 16-bit WAV 直通（16k 输入才由 bridge 线性重采样），
  首尾 5 ms 淡入淡出避免 WAV 边界爆音。
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

## 8. 隐私与安全

- 音频、转写、参考音频（含 `refs/` 原始片段与合并 prompt）只存本机；日志不打印转写原文、音频字节、aeskey、CDN key。
- 转写展示/记忆可分别关闭；删除消息/会话时随本地存储清理。
- 首次启用或微信重启后需捕获发送句柄；默认 `replyEnabled=false`，句柄/倒计时未就绪时失败自动降级文字。
- CosyVoice3 安装与模型下载是用户显式确认后的网络请求，不上传任何用户数据。

## 9. 代码位置

| 层 | 文件 |
| --- | --- |
| Hook | `hook/script.js`（语音下载触发与 R3 发送任务入口） |
| Bridge | `bridge/voice.go`、`bridge/voice_test.go`、`bridge/incoming.go`、`bridge/http.go`、`bridge/main.go`、`bridge/param.go` |
| STT | `app/Sources/WeChatBot/Services/VoiceTranscriptionService.swift`、`VoiceFetcher.swift` |
| 回复决策 | `app/Sources/WeChatBot/Services/VoiceReplyDecision.swift` |
| TTS | `app/Sources/WeChatBot/Services/VoiceSynthesisService.swift`、`VoiceSynthesisAudio.swift`、`VoiceSynthesisText.swift`（唯一引擎 CosyVoice3，HTTP 客户端见 CosyVoice3 行） |
| 音色/试听 | `Services/VoicePreviewController.swift`（共享试听播放器，走本地 CosyVoice3 HTTP 服务） |
| CosyVoice3 | `Services/CosyVoice{Client,Runtime,Installer}.swift`、`Models/CosyVoiceVoice.swift`、`Models/CosyVoiceReference.swift`、`Services/CosyVoiceVoiceStore.swift`、`Views/Components/CosyVoiceVoiceManagerSheet.swift`、`devtools/cosyvoice/`、`scripts/{install,run}_cosyvoice.sh`；详见 [`cosyvoice.md`](cosyvoice.md) |
| UI | `Views/VoiceSettingsPanel.swift`、`Views/Components/MessageBubble.swift`、`Views/ConversationsView.swift` |
| 数据 | `Models/Models.swift`、`Services/MemoryStore.swift`、`Core/AppStore+Runtime.swift` |

## 10. 测试

```bash
bash scripts/check.sh --with-go        # 静态 + Swift 全量 + Go
cd app && SWIFT_DISABLE_SANDBOX=1 swift test --scratch-path .build-lead
```

当前：Swift 567 项执行（565 通过 / 2 项按环境跳过：真实 CosyVoice3 服务 E2E；含 CosyVoice 集成、语音合成/发送回归、记忆 v2）；
Go 64 顶层 / 76 子测试通过；release App 约 168MB（不再静态链接 sherpa-onnx，二进制约 17MB）。
语音实现与测试细节见 `bridge/voice.go`、`bridge/voice_test.go`；入站/出站契约与限制见本文件与 [`bridge.md`](bridge.md)。
