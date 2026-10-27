# Core 服务层设计与契约（swift-core）

> 对应 `app/Sources/WeChatBot/Services/*` 与 `Core/AppStore.swift` / `Core/AppStore+Runtime.swift`。
> 本文件描述**已实现**的服务能力、并发模型、错误与重连策略、安全边界，供 UI / bridge / hook 协作。
> 总体架构见 [architecture.md](architecture.md)。

## 1. 文件清单

| 文件 | 职责 |
| --- | --- |
| `Core/AppStore.swift` | 共享状态骨架（`@MainActor @Observable`，UI 只读；运行时方法在扩展中） |
| `Core/AppStore+Runtime.swift` | 运行时编排 + 对 UI 暴露的全部运行时 API |
| `Services/SettingsPersistence.swift` | 配置 JSON 原子写、串行化、合并写入（全局 `config.json` + 当前账号 `profile.json` 双写） |
| `Services/WeChatAccountResolver.swift` | 识别微信客户端当前登录账号（登录标记 mtime → 账号目录活动），返回账号 ID 与图片临时目录；mask/校验 |
| `Services/AccountProfile.swift` | 账号档案布局、`account-state.json`、启动早期 `preparePaths`、切号激活、`_unassigned` 认领、旧版单库迁移 |
| `Services/KeychainStore.swift` | API Key 的 Keychain 读写/删除/存在性 |
| `Services/MemoryStore.swift` | SQLite（WAL）持久化：会话/消息/日志/定时任务/长期记忆/KV |
| `Services/SleepPreventionService.swift` | 通用防睡眠：IOKit 空闲睡眠断言 + 电源适配器监听（事件驱动，不轮询） |
| `Services/BatteryStatus.swift` | 本机电池快照：IOKit 电源字典解析（电量/充电/适配器/剩余时间） |
| `Services/DeepSeekBalance.swift` | DeepSeek 账户余额：`/user/balance` 地址推导、容错解析、通道选择 |
| `Services/ActivationPolicyController.swift` | Dock 图标与 `NSApplication.ActivationPolicy` 同步（用户设置优先，台前调度不覆盖；bundle 以 `LSUIElement` 启动，仅在设置页用于提示文案） |
| `Services/OneBotClient.swift` | WS 收事件、HTTP 发送/图片获取、媒体落地、事件解析、去重、重连 |
| `Services/ImageFetcher.swift` | 入站图片获取串行队列 + `ImageFetchPolicy`（设置开关 / 去重 / 取消） |
| `Services/VoiceTranscriptionService.swift` / `VoiceFetcher.swift` | 入站语音转写（SpeechAnalyzer）与 `/fetch_voice` 串行队列 |
| `Services/VoiceSynthesisService.swift` / `VoiceModelStore.swift` / `VoiceCloneStore.swift` | 本地 TTS（sherpa-onnx Kokoro/ZipVoice）、按引擎聚合模型下载、克隆音色 |
| `Services/VoicePreviewController.swift` / `Models/KokoroVoiceCatalog.swift` | 音色试听（共享 AVAudioPlayer，复用合成服务）与 Kokoro 官方 103 音色 sid → name 目录 |
| `Services/CosyVoiceClient.swift` | CosyVoice3 本地 HTTP 合成（health/voices/tts，24k PCM 解码，仅回环 endpoint） |
| `Services/CosyVoiceRuntime.swift` / `CosyVoiceInstaller.swift` | 本地 sidecar 启停/健康轮询/日志；安装脚本执行、`PROGRESS` 解析、取消/删除 |
| `Models/CosyVoiceVoice.swift` | 本机音色目录、health 快照、CosyVoice → Kokoro → 文字回退计划 |
| `Services/VoiceReplyDecision.swift` | 语音回复决策（开关/概率/对等/短回复/模型就绪） |
| `Services/VisionEngine.swift` | 识图支持：候选图片筛选、ImageIO 缩放/JPEG data URL、多模态请求消息、描述清洗 |
| `Services/AIClient.swift` | OpenAI 兼容 `/chat/completions`，SSE 流式 / 非流式 / 超时 / 错误映射 |
| `Services/RuleEngine.swift` | 白黑名单、私聊/群触发、唤醒窗口、冷却、频率、工作时段 |
| `Services/ChatEngine.swift` | 人设/记忆/近期上下文拼装、AI 调用重试、拟人化分段计划 |
| `Services/SchedulerService.swift` | 定时任务事件驱动循环、`nextFireAt` 计算、重启恢复 |
| `Services/HookManager.swift` | 微信/Gadget 检测、安装/恢复脚本、bridge 子进程生命周期 |
| `Services/ProcessRunner.swift` | `Process` 异步行流封装（脚本/bridge 输出） |
| `Services/AppResources.swift` | bundle / 开发树资源定位（bridge/hook/tools） |
| `Services/LogPipeline.swift` | 日志批量刷新、ANSI 清理、过滤与入库节流（200ms 批量，避免主线程逐行失效） |
| `Services/CrashReporter.swift` | AppKit 布局安全阀、未捕获异常报告、会话面包屑、主线程看门狗 |
| `Services/MentionText.swift` | 群聊 @ 文本兜底解析（结构化 `at` 缺失时用群昵称匹配） |
| `Services/ContactDirectory.swift` | 通讯录目录快照、会话标题补全与群昵称解析 |
| `Services/PatMessage.swift` | 拍一拍目标判定与 `{name}` 文本模板 |
| `Services/Diagnostics.swift` | `WECHATAI_SELFTEST=1` 服务层自检 |

本文件聚焦 Services/Core；设置模型、记忆页文件夹与 App 生命周期（防睡眠 apply/release）
的相关改动分别见 [memory.md](memory.md)、[ui-design.md](ui-design.md) 与
[architecture.md](architecture.md) §4。

## 2. AppStore 运行时 API（UI 契约）

```swift
// 生命周期
func startBot() async
func stopBot() async
func refreshStatus() async
func installHook(onProgress: ((Double, String) -> Void)? = nil) async throws
func restoreWeChatBackup() async throws

// AI
func testProvider(_ provider: AIProvider) async -> Result<String, Error>
func saveAPIKey(_ key: String, for providerID: String) throws
func apiKey(for providerID: String) -> String?
func deleteAPIKey(for providerID: String) throws

// 会话 / 消息
func sendManualMessage(conversationID: String, text: String) async
func clearMessages(conversationID: String?) async      // nil = 全部
func deleteMessage(id: String) async
func deleteConversation(id: String) async
@discardableResult
func loadMessages(conversationID: String, limit: Int = 50, before: Date? = nil) async -> [ChatMessage]
func searchMessages(_ query: String, limit: Int = 100) async -> [MemorySearchHit]

// 辅助
func currentSelfID() -> String
func isRuntimeConnected() -> Bool

// 设备与账户（2026-10-26）
func refreshSystemVitals() async
// 只读状态：store.batteryStatus / store.deepSeekBalance / store.isBalanceRefreshing

// 微信账号档案（2026-10-27）
var activeAccountID: String
var activeAccountIsUnassigned: Bool
var accountSwitchNotice: String?
var savedWeChatAccounts: [SavedWeChatAccount]
var isSwitchingAccount: Bool
func dismissAccountSwitchNotice()
func refreshWeChatAccount() async -> Bool   // 仅检测到不同账号才切库；返回是否真的切换
```

约定：

- UI 直接修改 `store.providers / personas / schedules` 后调用 `store.persist()`。
  `persist()` 只做快照，把 JSON 编码与原子写交给 `SettingsPersistence` actor，
  并通知运行时刷新调度任务/微信路径；**不会**在 MainActor 上写文件。
- 首次运行时（providers/personas 为空、默认 ID 失效）补默认 DeepSeek provider 与默认 persona，
  已有用户配置绝不覆盖。
- Keychain：`service = com.gusionw.wechatai`，`account = AIProvider.apiKeyReference`。
  `saveAPIKey` 会把 `apiKeyReference` 设为 `providerID`；`deleteAPIKey` 清空引用，
  因此 `provider.hasAPIKey` 能正确反映 UI 状态。`config.json` 中只出现引用名。
- `clearMessages(nil)` 清空全部消息并重置所有会话预览；指定会话时仅清该会话。
- 已删除 `AppStore.swift` 里的运行时 stub；所有运行时方法在 `AppStore+Runtime.swift`
  通过扩展实现，公开属性语义不变（`isBotRunning` 仅在启动成功后为 true）。

### 2.1 启动顺序与账号档案（2026-10-27）

多微信账号隔离后，启动顺序与旧版不同，**账号路径必须在读配置/开库之前确定**：

```
AppStore.init
  ├─ AccountProfile.preparePaths()     # 仅 stat/JSON，不打开 SQLite；决定 provisional active
  ├─ SettingsStore.load()              # config.json（全局）+ 当前 active 的 profile.json
  └─ activeAccountID / accountSwitchNotice / savedWeChatAccounts → observable

RuntimeCoordinator.performBootstrap
  1. AppPaths.ensureDirectories()      # root + accounts/<id>/{media,logs} + bridgeLog/backups/runtime
  2. await Task.detached { AccountProfile.runLegacyMigrationIfNeeded() }   # 旧版迁移，阻塞 IO
  3. active 变化或迁移写入了 profile 种子时：
                     store.applyLoadedSettings(SettingsStore.load())
                     store.refreshAccountObservables(notice: outcome.notice)
                     active 变化时 selfID = ""（等 bridge 重新确认）
  4. await Task.detached { AccountProfile.claimUnassignedForStartup(...) }
                     # _unassigned 有数据且已识别账号：开库前认领并切到该账号
  5. memory.open()                     # 打开最终 active 的 accounts/<id>/chatbot.sqlite
  6. LogPipeline.attach(store:memory:) # 迁移/认领完成后才接日志落库
  7. 启动期历史修复（自消息/伪群/appmsg/引用）只在当前账号库内执行
  8. loadPersistedState / loadStats / refreshStatus

RuntimeCoordinator.startRuntime
  0. bootstrapIfNeeded
  1. resolver 再检测：detected != active → switchAccount(to:reason:.detectedBeforeStart)
  2. bridgeIdentity()：-self_id / -image_path / -media_dir 全部取当前账号
  3. bridge 回报 get_login_info → adoptSelfID：与 active 不一致 → switchAccount(.loginMismatch)
```

不变式：

- `preparePaths()` 早于 `SettingsStore.load()`，且不读 SQLite；旧库 owner 只在迁移时读取。
  `state.lastAccountID == _unassigned` 且临时档案有数据时保持 `_unassigned`，等 bootstrap 认领，
  不能提前改 active/state。
- 旧版迁移与 `_unassigned` 认领都早于 `memory.open()`，放在后台线程（`Task.detached`）；
  `MemoryStore.shared` 在 bootstrap 前禁止隐式 open，`LogPipeline` 延后 attach。
- 注入 `AppSettings` 的测试/诊断（`AppStore(settings:)`）不触碰本机账号目录：
  `managesAccountProfiles == false`，不打开真实账号库、不 attach 日志落库、不调用
  `preparePaths`/迁移，也不允许 UI 手动切号。
- 所有切号（启动、启动机器人前、运行中、设置页重新检测）统一走
  `RuntimeCoordinator.switchAccount(to:reason:)`，不允许在旧库上直接改 selfID 或局部换路径。
- 旧版迁移、`_unassigned` 认领、账号识别细节见 [`accounts.md`](accounts.md) §4–§7。

### 2.2 设置持久化（全局 `config.json` + 账号 `profile.json`）

| 文件 | 内容 | 加载 | 保存 |
| --- | --- | --- | --- |
| `config.json` | 完整 `AppSettings`（`general/hook/onebot/ai/bot/providers/personas/schedules` 镜像） | `SettingsStore.load()` 先解码它，沿用旧的损坏备份/默认值逻辑 | `SettingsPersistence.save(...)` 写完整 `AppSettings`（含账号字段镜像，供旧版回滚）；账号字段运行时以 profile 为准 |
| `accounts/<id>/profile.json` | `ProfileSettings`：`schemaVersion` / `bot` / `personas` / `schedules` | `SettingsStore.loadProfile(profileURL:)`，缺失 `.default`，损坏备份 `profile.corrupt-<ts>.json` 后默认 | `SettingsPersistence.save(_:profileURL:)` 在 `profileURL != nil` 时双写；按编码字节去重，原子 replace |

- `SettingsStore.load()` = 解码 `config.json` 得到完整 `AppSettings` → `settings.applyProfile(loadProfile(...))`；
  即**全局字段来自 config，账号字段以 profile 为准**。
- `SettingsPersistence.shared = SettingsPersistence(configURL: AppPaths.configFile)`；
  保留 `init(fileURL:)`（测试、仅 config）并新增 `init(configURL:)`（应用、双写当前 profile）。
- `save(_:profileURL:)`：显式 `profileURL == nil` 时只写 config；非 nil 时 config 与 profile
  都按编码字节去重、各自原子写，profile 目标路径变化（切号）时强制写，返回任一文件是否变化。
  旧 `save(_:)` 等价于 `profileURL == nil`，只写 config（shared 与 `init(fileURL:)` 一致）；
  应用 `persist()` 显式传当前账号 profile 路径。
- `AppStore.persist()` 在调用时捕获 `AppPaths.profileFile` 再交给 SettingsPersistence；
  切号后延迟执行的旧快照仍写回旧账号 profile，不会串号。
- `AppPaths` 委托 `AccountProfile`：`databaseFile` / `profileFile` / `mediaDirectory` /
  `logsDirectory` 都指向当前账号；`ensureDirectories()` 不再把新媒体写入根 `media/`。

## 3. 事件流水线

```
bridge WS ──► OneBotClient.receive
                │  解析容错 → 媒体落地 → message_id 去重 + 自消息 echo 匹配
                ▼
        onEvent（后台线程）──► Task @MainActor
                ▼
RuntimeCoordinator.handle(event)
  1. 自消息 echo：把本地 pending 消息标为 sent，不重复入库
  2. 会话 upsert（标题/预览/unread/lastMessageAt）+ 消息 upsert（SQLite 批量事务）
  3. BotStats.receivedToday++
  4. RuleEngine.evaluate（白/黑名单 → 触发方式 → 冷却/频率/工作时段）
  5. 命中：取 provider/persona → ChatEngine.generateReply（含重试、记忆召回）
  6. ChatReplyPlan：文字按拟人化延迟/分段逐条 HTTP 发送；已确定改发语音时默认跳过延迟
  7. 发送成功：消息状态 pending→sent、会话预览、冷却记账、统计/日志
```

- 回复生成按会话串行（`inFlightConversations`），同一会话不会并发产生多条 AI 回复；
  不同会话可并行。
- dry-run：仍调用 AI 生成，但只写入一条 `direction = .system` 的“将回复”记录并打日志，不发送。
- 手动发送/定时任务复用同一发送路径（pending → sent/failed，含 DB 与统计）。
- **回复进度（UI 可见）**：命中回复后，`RuntimeCoordinator` 在关键节点写入
  `AppStore.replyProgress[conversationID]`（`ReplyProgress`，仅内存、不持久化）：
  - 进入 AI 请求前 → `.generating`（记录通道名 / 模型，UI 正向计时「已等待 N 秒」）；
  - 每段发送前若启用拟人化 → `.waitingToSend`，同时写入 `countdownEnd` / `countdownTotal`，
    UI 据此渲染真实的「N 秒后发送」倒计时与收缩进度条；本次已确定改发语音且开启
    「语音回复免拟人化延迟」时跳过该阶段，直接进入 `.sending`；
  - 提交 OneBot HTTP 前 → `.sending`（UI 显示回执等待时长；R3 未就绪时由 UI 叠加提示）；
  - 投递完成 → `.completed`（约 3 秒后自动清理）；AI / 发送失败 → `.failed`（保留错误，可手动关闭，
    60 秒后兜底清理）。
  同一会话开始新一轮回复会刷新进度令牌，旧状态条的自动清理任务不会误删新进度；
  bot 停止、运行时关闭、会话删除都会清空对应快照。

### 3.1 入站图片获取（2026-10-23）

```
bridge 事件 image（message_id, 无 url）
  → RuntimeCoordinator.handle(event) 入库后
  → ImageFetchPolicy.shouldFetch(...)（该会话生效开关 / 非自消息 / kind=image / 无 mediaPath,mediaURL / message_id 非空）
  → ImageFetcher.enqueue（串行、同一 chatMessageID 只尝试一次）
  → OneBotClient.fetchImage(messageID)  → POST /fetch_image（Bearer，30s 超时）
  → 成功：更新 store.messages 中该消息的 mediaPath → memory.upsertMessages → MessageBubble 显示图片
  → 失败：debug 日志（不弹窗、不重试、不影响 AI 回复）
```

- 开关按**会话**保存：`Conversation.imageFetchEnabled`（DB 列 `image_fetch_enabled`，
  NULL=跟随旧全局默认、0=关、1=开）；生效值 = 会话覆盖 → `bot.imageFetchEnabled`（默认 true）。
  入口是会话详情 → 菜单 →「媒体」；关闭时 `ImageFetchPolicy` 直接返回 false，
  **不会发出任何请求**，因此 bridge 也不会下载。
- `ImageFetcher` 是 `@MainActor` 串行队列，闭包注入 `fetch`/`onFetched`/`onFailed`；
  `stopRuntime()` 与设置关闭都会调用 `cancelAll()`，取消后不再回调。
- 只用原始 `OneBotEvent.messageID` 请求 bridge（`ChatMessage.id` 带 `ob-` 前缀，不可混用）。
- 2026-10-23 已在微信 4.2.0.5 真机验证：入站图片 → 优先使用微信自然下载分片
  （必要时触发）→ 分片完整（JPEG EOI / PNG IEND 校验）→ AES-ECB 解密并保存；
  mid 为 HEVC 时回退 JPEG 缩略图（实测完整 JPEG 图片）。不按 XML
  `length` 截断，避免切掉图片尾部。
- 本节只做「获取」；图片内容识别、描述注入与视觉模型路由见 §3.2。

### 3.2 识图（视觉模型，2026-10-23）

```
自动回复触发（evaluateAndReply）且 settings.ai.vision.enabled == true
  → VisionSupport.candidates：最近 10 条上下文中「入站图片 + 无 imageDescription +
    10 分钟内」，按消息时间最新优先，最多 2 张
  → 图片尚未落盘时等待 ImageFetcher 完成（最多 8 秒）
  → ImageIO 缩放到最长边 1280 → JPEG(0.8) → base64 data URL
  → 用「识图通道/模型」发一次非流式 /chat/completions
    （content 为 text + image_url 多段；图片本身不进入回复提示词）
  → 描述清洗（空白折叠、400 字上限）→ 消息 imageDescription 落库 + 内存更新
  → ChatEngine 提示词：kind=image 且有描述时输出 [图片：<描述>]
```

- 设置：`AISettings.vision`（`VisionSettings?`，旧 config 缺键 = nil = 关闭）：
  `enabled` / `providerID`（nil 跟随「默认通道」）/ `model`（空跟随通道模型）/
  `prompt`（空使用 `VisionSettings.defaultPrompt`）。
  请求使用通道副本：非流式、超时 ≤30 秒、`max_tokens` ≤800，避免识图把整轮回复拖慢。
- DeepSeek 系通道（`kind == .deepSeek` 或 baseURL 含 `deepseek`）的识图请求显式发送
  `{"thinking":{"type":"disabled"}}`：`deepseek-flash` 默认开启思考模式，推理 token
  会占用输出额度，短描述场景容易出现 `content` 为空（2026-10-23 真机日志已复现）。
  其它通道不发送该扩展字段，避免严格 OpenAI 端点报未知参数。
- **按需识别**：只有「本轮需要生成回复」才识别上下文里的近期图片，单纯收到图片不产生费用。
  同一消息在本次运行内最多尝试一次；失败只写 debug 日志，不阻断回复；10 分钟前的图片不再识别。
- 图片不直接进入回复提示词：主回复始终是文本请求，避免把默认文本通道变成多模态请求；
  `[图片]` 占位在未开启识图/识别失败时保持不变。
- 数据：`ChatMessage.imageDescription`，DB 列 `messages.image_description TEXT`
  （旧库幂等补列；所有消息 SELECT 列表与 upsert 同步）。
- UI：AI 模型 →「识图模型」可启用/选通道/覆盖模型；图片气泡在图片下方展示识图描述。
- 状态：2026-10-23 实现，单元测试覆盖请求体/候选/编码/落库；**尚未真机验证**
  （需先配置支持 OpenAI 兼容 `image_url` 输入的视觉模型）。

### 3.3 引用图片（2026-10-23）

- 微信引用消息的 `refermsg` 带 `<svrid>`（服务端消息 ID）与 `[图片]` 摘要。`svrid` 与 bridge
  的 `message_id` 相同，对应 App 的 `ChatMessage.id = ob-<svrid>`（2026-10-23 用真实引用图片核对）；
  `WeChatAppmsg.Quote` 解析 `svrid` / `isImage` / `imageMessageID`。
- 生成回复前，`prepareQuotedImageNote` 只处理**本轮消息**引用的图片：按 `svrid` 从内存/数据库
  找回原图；已有 `imageDescription` 直接复用；未描述但有 `mediaPath` 时现场识别（只识别这一张，
  **不受最近 10 分钟限制**，因为用户明确引用了它）；随后在本轮用户消息文本末尾追加
  「（引用图片内容：…）」，原图找不到/无法识别时追加「（引用的图片内容暂不可用）」。
  该说明只进入提示词，不写数据库，会话气泡保持原样。
- 未开启识图且原图没有旧描述时不追加说明，旧行为不变。
- `ChatEngine` system prompt 会说明该标记是图片画面描述、不是本轮新发言，避免模型猜图。

### 3.4 切号（运行中与启动阶段，2026-10-27）

启动/启动机器人时由 resolver 判定账号档案；`bridge` 的 `get_login_info` 用于运行期确认与兜底
（回包与档案不一致时切号，见 [accounts.md](accounts.md) §4.3）。`adoptSelfID(_:)` 收到账号后：

```
id 非法（不满足账号 ID 校验）→ warning，忽略，不落盘
id == active 且 active != _unassigned
  → 写 self_id / self_id_source=login；在当前账号库内补跑历史修复
id != active 或 active == _unassigned
  ├─ runtimeStarting == true
  │    → 记 pendingAccountSwitch，不立刻拆运行时
  │    → startRuntime 收尾后 consumePendingAccountSwitchIfNeeded() 再切
  └─ 否则 → switchAccount(to: id, reason: .loginMismatch)
```

`switchAccount(to:reason:)` 的顺序固定：

1. 若机器人在跑，先停止 bridge / OneBot / 调度 / 媒体队列（停止过程 flush 日志/设置/统计）；
2. drain 后台写入任务（长记忆总结/群昵称回填/统计落盘：cancel + await）；
3. `memory.suspend()`（close + 禁止 `ensureOpen` 隐式重开）；
4. `claimUnassigned(by:)`（active 仍为 `_unassigned`）或 `AccountProfile.activate(id)`；
5. `memory.switchToActiveAccountDatabase()`；
6. 应用新账号 `profile`（`SettingsStore.load()` / `applyLoadedSettings`）；
7. 清空内存中的会话/消息/长期记忆/日志/统计/选中会话/回复进度；
8. 从新库载入数据，`store.persist()` 把 profile 写回新账号；
9. 更新 `activeAccountID` / `activeAccountIsUnassigned` / `savedWeChatAccounts` /
   `accountSwitchNotice`，关闭 `settings.bot.enabled`、`isBotRunning = false`。

切号期间 `isSwitchingAccount=true`：`startBot`/`startRuntime`/`reconcileWeChatAccount` 互斥，
总览与菜单栏启动按钮禁用；避免 bridge 用旧档案身份启动。

- 运行中切号**不自动重启机器人**，由用户重新启动；避免用户没注意就自动用新账号回复。
- 启动机器人前检测到换号（`startRuntime` 里的 resolver 复检）同样走 `switchAccount`，
  然后才拼接 bridge 的 `-self_id` / `-image_path` / `-media_dir`。
- 设置页「重新检测」调用 `AppStore.refreshWeChatAccount()` → `RuntimeCoordinator.reconcileWeChatAccount()`，
  只在检测到不同账号时切库；返回是否真的切换。
- 切换失败时尽力回到原账号库，保持运行时停止、复位 `isBotRunning`/`bot.enabled`
  并提示重试；不会把两个账号的数据写进同一库。

## 4. 并发与线程模型

| 组件 | 隔离方式 | 说明 |
| --- | --- | --- |
| `AppStore` | `@MainActor @Observable` | UI 只读；所有状态回主线程更新 |
| `RuntimeCoordinator` | `@MainActor` | 编排、事件处理、统计；等待服务用 `await` 让出主线程 |
| `MemoryStore` | `actor` + SQLite `FULLMUTEX` | 所有 SQL 串行；UI/服务层都 `await` |
| `AccountProfile` | 静态状态 + `NSLock` | 账号解析/状态读写串行；迁移是阻塞 IO，调用方必须在后台线程执行 |
| `SettingsPersistence` | `actor` | 编码、原子替换、合并写；config/profile 双写 |
| `SchedulerService` | `actor` | 单循环 + `CheckedContinuation` 唤醒，无轮询 |
| `OneBotClient` | 私有串行 `DispatchQueue` + `URLSessionWebSocketTask` 接收 `Task` | 网络/解析不在主线程；回调由运行时 hop 回 MainActor |
| `ImageFetcher` | `@MainActor` 串行队列 + 可取消 `Task` | 一次只请求一张图；同一消息只尝试一次；停止/关闭设置即取消 |
| `VisionSupport` | 纯静态函数（无状态） | 候选筛选/图片编码/请求消息/描述清洗可单测；网络调用复用 `AIClient` |
| `AIClient` | 无共享可变状态，`URLSession` async | 请求/SSE 解析在后台 |
| `RuleEngine` | `NSLock` 保护冷却/频率状态 | 纯内存判定，无 IO |
| `ChatEngine` | 无共享可变状态 | 只依赖 `MemoryStore`/`AIClient` |
| `HookManager` | `@MainActor`；`ProcessRunner` 后台读管道 | 脚本/bridge 输出行流式回主线程更新状态 |
| `LogPipeline` | 内部锁 + 200ms 批量刷新 | 后台线程可写；批量合并 UI/SQLite 更新，避免逐行失效 |
| `CrashReporter` / `MainThreadWatchdog` | 锁保护快照；看门狗独立线程 | 异常与卡顿取证不经过 MainActor，避免死锁 |

禁止事项（已遵守）：MainActor 上无阻塞文件/DB/脚本 IO；无忙轮询；无 `sleep` 轮询循环。
`SchedulerService` 只在下一个 `nextFireAt` 到来或 `update/stop` 唤醒时继续，属于事件驱动定时器。
日志页（500ms）与总览「最近活动」（750ms）仍用低频采样把日志追加与 SwiftUI 失效解耦，但采样
先比较 `AppStore.logRevision`（`appendLogBatch` / `replaceLogs` / `clearLogs` 各自 +1）；
revision 未变化时直接跳过，空闲时不做 O(n) 复制 / 遍历 2000 条日志。

## 5. 服务协议要点

### 5.1 MemoryStore（SQLite）

- 路径：当前微信账号的 `accounts/<id>/chatbot.sqlite`（`AppPaths.databaseFile`）；`journal_mode=WAL`、
  `synchronous=NORMAL`、`busy_timeout=3000`、`foreign_keys=ON`。
  `MemoryStore(databaseURL: nil)` 在 `open()` 时才解析路径（旧版单库迁移/切号可以先定 activeID）；
  `MemoryStore(databaseURL:)` 仍可注入固定路径给单测。
- 切库：`switchDatabase(to:)` / `switchToActiveAccountDatabase()` 关闭旧库并打开当前账号库；
  `path` 是 actor 内属性，避免从后台线程读到半更新路径。切号前由 Runtime 先关闭库，
  认领/激活完成后再打开，不能同时打开两个账号库。
- 旧版根目录 `chatbot.sqlite` 迁移后保留，但不再被打开/写入；旧媒体同理。
- 表（每个账号库独立）：`conversations`、`messages`、`logs`、`schedules`、`settings`（KV），
  以及长期记忆的 `memories` / `memory_state` 等。
  消息表主键 `id`，`INSERT ... ON CONFLICT(id) DO UPDATE`，可安全重复投递；
  索引：`(conversation_id, timestamp DESC)`、`(timestamp DESC)`、`logs(date DESC)`。
- 批量写：`upsertMessages` / `appendLogs` / `upsertConversations` / `replaceSchedules`
  均在单事务内复用 prepared statement。
- 分页：`fetchMessages(conversationID:limit:before:)` 返回页内时间正序，`before` 向前翻页；
  `fetchConversations(limit:offset:)` 置顶优先、最近活跃优先。
- 搜索：`searchMessages(query:)` 对消息文本做 `LIKE`（转义 `% _ \`），关联会话标题；
  本地数据规模下足够，后续可升级 FTS5。
- 启动历史修复（2026-10-23 性能优化）：
  `repairSelfRoutedMessages(selfID:trusted:)` / `repairMisroutedConversations(selfID:trusted:)`
  在 `trusted: true`（`self_id_source=login`，selfID 来自 bridge `get_login_info`）时完全跳过
  历史事件反推；未 trusted 时反推也只采样最近 5000 条 `raw_json`（走 `idx_messages_time`）。
  `repairMisroutedConversations` 先用 `conversations` 表廉价筛出嫌疑会话（自己 / 占位 / 伪群），
  为空即返回；推断出不同账号才重算嫌疑集合。健康库启动不再全表读取并逐行 JSON 解析历史消息。
- 一次性文本迁移：`repairAppmsgMessageTexts`（`text LIKE '[链接/文件]%'`）与
  `rerenderLegacyQuoteTexts`（`text LIKE '%[引用 %'`）由设置键 `data.repairs_version` 门禁，
  两项都成功后写版本，之后启动永久跳过；失败不写版本、下次重试。
- 日志环形：App 内存最多 2000 条；DB 每累计 100 条 `pruneLogs(keep: 5000)`。
  UI 采样以 `logRevision` 为门禁（见 §4），未变化不重算。
- 日期统一存 Unix 秒（`Double`），枚举存 rawValue 字符串。
- 会话删除级联删除消息；`clearMessages` 同步重置会话预览/unread。

### 5.2 OneBotClient

- WS：`ws://host:port/ws`，仅监听本机；无鉴权（架构约定）。
- HTTP：`POST http://host:port/send_private_msg|send_group_msg`，
  `Authorization: Bearer <token>`，body `{user_id|group_id, message:[{type,data}]}`；
  2xx 且 `status in {ok, async}` 视为成功，否则抛 `OneBotError.sendFailed`。
- 重连：指数退避 `base * 2^n`（默认 1s 起，30s 上限，+0~0.35s 抖动），
  收到 `didClose` / 接收错误 / ping 失败 / 连接超时均触发；`stop()` 停止重连。
  ping 每 20s 一次（`sendPing`），用于发现半开连接。
- 连接超时 15s；HTTP 请求超时 20s。
- 解析容错：`message` 可为字符串或段数组；缺字段用默认值；支持 `sender.user_id` 缺失时回退
  `user_id`；支持事件被 `{"data": {...}}` 包裹；未知帧忽略并打 debug 日志。
- 入站帧解析（2026-10-23）：`handleInbound` 每帧只 `JSONSerialization` 一次，
  动作回包（通讯录 / 登录信息）与消息事件共用同一对象；`OneBotEventParser.parse(object:rawText:)`
  直接复用已解析对象，单事件 `rawJSON` 等于原始帧文本，不再二次解析 / 重新序列化。
  数组帧按旧行为逐元素解析（`rawText: nil`），`parse(data:)` API 与旧行为保留。
- 自消息去重：进程内 `message_id` LRU（1024）；HTTP 发送成功后登记
  `(conversationID, text, time)`，20s 内 WS 出现同文本的 self 事件时标记
  `isEchoOfLocal`，运行时把本地 pending 消息更新为 sent 而非重复插入。
- 媒体：`file://` 复制、`base64://`/裸 base64 解码，落地
  `~/Library/Application Support/WeChatAI/media/<yyyy-MM-dd>/<uuid>.<ext>`；
  单文件上限 40MB；http(s) URL 仅保存 `mediaURL` 不下载。
- 入站图片获取（2026-10-23）：`fetchImage(messageID:)` → `POST /fetch_image`
  （Bearer、`{"message_id":…}`、超时 30s）；2xx + `status=="ok"` + `data.file`
  才返回本地路径（`file://` 反向百分号解码），失败/404/缺字段抛 `OneBotError.badResponse`，
  404 额外提示 bridge 需更新。请求与响应解析拆成两个静态纯函数供单测。
- 事件模型：`OneBotEvent`（纯值类型）→ 运行时转 `Conversation`/`ChatMessage`；
  `at` 段与 `mentions` 收集 @ 目标，RuleEngine 优先精确匹配机器人 wxid；
  结构化 at 缺失时可用从历史事件学到的「群昵称」做文本 @ 兜底。
- appmsg（`msg_type=49`）归一化（2026-10-22）：hook 对拍一拍以外的 appmsg 只写
  `[链接/文件]`，`OneBotEventParser` 用 `WeChatAppmsg.parse`（`Services/WeChatAppmsg.swift`）
  从 `raw_message` 还原展示文本——引用 57 → `回复正文` + 换行 +
  `【引用 发送者：原文摘要】`；链接 5 / 文件 6 / 视频 4 / 表情 8 / 聊天记录 19 / 小程序 33·36 /
  转账 2000 / 红包 2001 / 视频号 51 → `[类型] 标题`。只替换占位文本（以及 hook 误把引用
  当拍一拍时写入的 title、旧 bridge 原样透传的 appmsg XML、旧 bridge 已渲染的
  `[引用 发送者]` 定界符文本），拍一拍、`at` 段与媒体段保持原样。

### 5.3 AIClient

- Endpoint：`baseURL` 去尾 `/`，若不以 `/chat/completions` 结尾则追加；
  空 baseURL 用 provider kind 默认值；非法 URL → `AIError.invalidBaseURL`。
- 鉴权：`apiKeyReference` → Keychain；DeepSeek/OpenAI 必须有 Key；
  Ollama/自定义允许无 Key（本地服务）。
- 请求体：`model, messages, max_tokens, stream`；`temperature` 仅在
  `ai.modelTemperatures[model]` 有配置时发送（0...2），否则省略、由模型使用自身默认值。
  不包含任何 Key 字段。
- 响应：非流式解析 `choices[0].message.content`（兼容 `reasoning_content` 与
  content parts 数组）；流式逐行解析 `data:` SSE，处理 `[DONE]`、`usage`、`finish_reason`。
- 超时：请求 `timeoutInterval = provider.timeoutSeconds`；流式另有总时长看门狗
  `TaskGroup` 竞速，超时抛 `.timedOut` 并取消读取。
- 错误映射：401/403 鉴权、404 地址/模型、429 限流、5xx/网络/超时标记可重试；
  返回 `AICompletionResult`（文本、model、usage、latencyMs、streamed）。
- ChatEngine 按 `AISettings.retryCount` 对可重试错误做 400ms 递增退避重试。

### 5.4 RuleEngine

引用消息（2026-10-22）：触发判定只取回复正文（`RuleEngine.triggerText` 去掉
`WeChatAppmsg` 生成的 `【引用 …】` 行，兼容旧 `[引用 …]`）；被引用原文仍进入 AI 上下文，但不参与
@ / 关键词 / 前缀匹配，避免「引用旧消息」重复唤醒。真实结构化 `at` 段不受影响。

硬门槛顺序：

1. `conversation.aiEnabled == false` / 公众号忽略 / 自己的消息忽略；
2. 统一黑名单 `effectiveBlacklist` 命中会话 ID 或发送者 wxid 即拒绝；
3. 统一白名单 `effectiveWhitelist` 非空时要求会话或发送者命中；
4. 工作时段（`WorkingHours.contains`）不满足即拒绝（免打扰已从产品移除，`isMuted` 仅保留数据库兼容字段）；
5. 触发判定：私聊看 `replyToDirect`；群聊看 `effectiveGroupTriggers`
   （@ / 关键词 / 拍一拍 / 引用机器人 可多选，「所有消息」独占；旧版 `groupTrigger`
   自动回退），关键词取 `bot.keywords`，前缀取 `bot.commandPrefix`；
   命中后按会话/机器人默认解析 persona/provider/model；
6. 冷却与每分钟上限按会话记账；**只有发送成功后**才 `noteReply` 消耗冷却，
   AI 失败不会误占冷却；运行时对同会话生成做串行化，避免并发穿透。

唤醒后免唤醒词（2026-10-23 新增，默认关闭）：`bot.wakeWindow.enabled && seconds > 0` 时，
群聊命中任一触发方式后按「会话 ID + 发送者 wxid」记录唤醒时间（内存态，`resetThrottles`
与机器人启动时清空）。窗口内同一发送者的消息即使没有 @/关键词/引用也放行，标签为
「群聊·唤醒窗口」；每条被放行的消息都会续期（滑动窗口，最长 60 分钟）。窗口判定发生在
硬门槛之后、冷却之前，因此只放宽触发方式，不绕过会话开关、白黑名单、工作时段、
冷却与每分钟上限；其它发送者与其它会话不受影响。私聊本来无需唤醒词，行为不变。

引用机器人（2026-10-22 新增，默认关闭）：`TriggerMode.quote`，群聊触发方式多选新增项。
`isQuotingBot` 解析 `WeChatAppmsg.parse(eventJSON: rawJSON)?.quote?.senderID` 并与
`selfID` 比较：`<chatusr>` 优先、`<fromusr>` 回退（群 ID 忽略），昵称不参与判定；
正文无需 @/关键词，命中标签为「群聊·引用」。只在显式勾选时生效，升级不会改变既有触发行为。

拍一拍（2026-10-21 修复）：`PatMessage.event(from: rawJSON)` 优先解析 hook 的
`pat_*` 结构化字段，回退解析 `raw_message` 里的 `<patinfo>` / `<pat>` XML。
`.pat` 触发只在 `pat_target_wxid == selfID` 时命中；没有结构化 target 时，
私聊按「拍了拍我 / patted me」、群聊按正文含 selfID 或已学到的群昵称兜底。
普通文本里出现「拍了拍」（例如「我刚才拍了拍他」）不再算拍一拍。

拍一拍回复（`bot.pat.enabled`，默认关闭）：规则引擎放行后，若当前消息确实拍的是
机器人，运行期进入 `handlePatReply`。**不再回拍**，只发送：

- `bot.pat.fixedTextEnabled` + `beforeText` / `afterText`：AI 前/后的自定义文字
  （`PatTextTemplate.render` 支持 `{name}` → 对方昵称；空串不发送）；
- `bot.pat.aiReplyEnabled`：用与普通回复相同的 persona/provider/model 生成 AI 文字；
  生成失败只跳过 AI，不影响自定义文字；
- `bot.pat.mentionPatterInGroup`（默认关闭）：群聊拍一拍回复时，把真实 @（OneBot
  `at` 段，`qq` = 拍的人 wxid）附在**第一条**发出的消息前。自定义前文字 → AI 首段 →
  自定义后文字，哪条先发出就 @ 哪条，最多一次；私聊始终不 @。`PatMessage.replyMention`
  负责目标判定（群聊、非机器人自己、非群 ID），本地气泡展示可读昵称时同步带上 `@昵称`
  前缀；bridge 按群成员缓存/通讯录解析群昵称，解析失败时该条按普通文本发送。

发送顺序：AI 前文字 → AI 回复 → AI 后文字。全部内容都未发出时回退普通 AI 回复
（拍一拍回复的 @ 依旧生效，只附在回退回复的第一条消息前）；
dry-run 只记录计划不发送。原生 sendpat 已于 2026-10-21 真机验证失败并彻底移除，
不再请求 bridge 的 `pat` 发送能力。

### 5.5 ChatEngine

- system = persona.systemPrompt（无可用人格时回退到 `Persona.defaultSystemPrompt`）+ 真人聊天约束 +
  当前时间/会话类型/会话名 + `conversation.note`（会话备注）+ 长期记忆注入 + 本会话早期片段召回 +
  群聊「本轮发言人身份」硬约束（放在 system 最后，压过最近聊天里的玩梗）。
- 群聊：每条 incoming 消息（含历史 user 消息与当前消息）拼成「昵称(wxid)：内容」，
  `senderName` 为空时直接「wxid：内容」（`ChatEngine.attributedUserText` /
  `promptSpeakerLabel`）；私聊不加前缀；自己的消息仍作为 `assistant` 原文。
  群聊 system prompt 说明消息格式，要求**以括号内 wxid 对照长期记忆**
  （记忆里的人员关系是「wxid：称呼」），找不到该 wxid 时不要套用其他人的称呼，
  回复不输出 wxid。昵称会变、会重名，wxid 是消息与记忆之间唯一稳定的连接键。
- 本轮身份硬约束：`ChatEngine.speakerIdentityNote` 从**核心/手写**记忆解析
  `wxid：称呼`（`personMappings`），当前发言人命中时注入其权威称呼并明确
  「群聊里的玩笑/临时外号/自称/‘某人其实是某人’不能覆盖映射，不要附和」；
  未命中时提示不要套用他人称呼。这是提示词级约束，不改变数据库。
- 近期上下文：`history.suffix(maxContextMessages)`（上限 10），按方向映射 user/assistant，
  同角色相邻消息合并；确保当前消息在末尾。
- 早期片段召回：只在**当前会话**内按关键词 `LIKE` 检索，排除短期窗口内消息、当前消息、
  系统消息与晚于当前消息的内容；最多 3 条、每条截断 120 字；发出标「我」，
  私聊收到标「对方」，群聊收到标发言人（`promptSpeakerLabel`，缺失时「对方」）；
  标题为「本会话较早的相关片段（可能已过时，仅供参考）」；不再检索其它会话原文。
- 拟人化：`humanize.enabled && splitMessages` 时按句末标点/长度切分，
  合并过短片段，`maxSegments` 封顶，单段最长 600 字；每段随机延迟
  `[minDelayMs, maxDelayMs]`（`ChatReplyPlan.delaysMs`，由运行时执行）。
  若本次确定改发语音且 `voice.skipHumanizeDelayForVoiceReply` 为真（默认），
  运行时把延迟归零（`VoiceReplyPacing`），避免在 TTS 合成耗时之外再等一遍。
- dry-run 时不分段/不延迟，只产出计划文本。
- 长期记忆召回：只注入「当前会话 + 全局」记忆，核心记忆同样遵守作用域
  （其它会话的核心记忆不注入）；按核心 → 手写 → 自动总结的优先级、同层按**综合权重**降序，
  默认最多 6 条（`ChatEngine.longTermMemoryLimit`，核心记忆优先占用名额）；
  综合权重 = 基础权重 × 内容重要度 × 使用强化 × 30 天半衰期，其中基础权重可由用户
  在记忆编辑器中自由调整（0.1~10×），核心记忆之间也按该权重排序；提示词注明核心/手写优先、
  自动总结仅供参考、冲突时以核心/手写为准；召回后 `MemoryStore.recordMemoryAccess(ids:)`
  以 best-effort 累加访问次数。当本会话存在核心/手写 `wxid：称呼` 映射时，
  自动总结的「人物与称呼」段不注入（`ChatEngine.promptSummary` 剔除），
  避免和权威映射打架；没有权威映射时仍保留自动总结的人物信息作为兜底。
- 批量总结：短期窗口（10 条）外的未总结消息**攒够 8 条**才调用一次 AI，
  单批最多 40 条；12 条不总结、18 条总结 8 条、26 条再总结 8 条。
  AI 提示由 `ChatEngine.summaryPrompt` 纯函数生成：默认结构化（人物与称呼 / 偏好 /
  约定与待办 / 其他），最多 5 条要点、总长 ≤600 字，不编造、不罗列成员 wxid 清单；
  存在本会话核心/手写映射时，要求模型**不输出人物与称呼段**、不记录群聊玩笑/临时外号/
  自称/“某人其实是某人”的玩梗，冲突时以手写记忆为准；传入的「已有自动记忆」会先剔除
  人物段，模型输出与本地兜底结果再经 `removingPersonMappingLines` 兜底。
  核心 + 手写记忆作为「权威参考」传入合并提示、不被覆盖；结果经
  `MemorySummaryCompactor` 强制 ≤600 字符；无 Key/AI 失败时本地兜底同样压缩；
  同一会话只保留一条自动滚动总结，历史遗留的多条自动总结会先合并清理。
  详见 [memory.md](memory.md)。
- 流式总开关：`settings.ai.streamReplies == false` 时所有通道强制非流式；
  开启时按 `provider.stream` 决定（`ChatEngine.forceStream(for:)`）。
- 返回 `ChatReplyPlan`（segments/全文本/provider/persona/model/latency/usage/delays/上下文条数）。

### 5.6 SchedulerService

- `ScheduledTask.nextFireAt` 计算：
  - `once`：未来 fireAt，否则禁用；
  - `daily`：下一个同日时刻；
  - `weekdays`：周一~周五的下一个时刻；
  - `weekly`：`task.weekdays`（Calendar weekday，1=周日）中的下一个时刻。
- 启动/`update` 时 `normalize`：重算 nextFireAt，过期的 `once` 自动禁用（不会补发）。
- 循环：取最早 nextFireAt → `Task.sleep` 到点或 `update/stop` 唤醒；到点后更新
  `lastFiredAt/nextFireAt`，回调 `onFire`（发送）与 `onChange`（持久化 + UI 同步）。
- 运行时把 `settings.schedules` 作为权威源，同时镜像到 `schedules` 表用于崩溃恢复。
- 重启恢复：启动时刷新全部 nextFireAt；已过期任务顺延到下一次，不补发历史。

### 5.7 HookManager / ProcessRunner

- 检测：`Contents/Info.plist` 读版本/build；`NSRunningApplication` + `NSWorkspace` 判断微信运行；
  `Contents/Frameworks/FridaGadget.dylib` 存在 **且** `otool -L Contents/MacOS/WeChat`
  含 `FridaGadget.dylib` 才视为已注入；另调用
  `tools/manage_wechat.sh status` 合并签名/备份路径等详情（失败不致命）。
- 状态映射：未安装/未注入 → `notInstalled`；已注入但微信未运行 → `wechatNotRunning`；
  已注入且微信运行、bridge 未启动 → `installed`；bridge 启动中 →
  `bridgeStarting`；OneBot WS 连接成功 → `connected`；脚本/进程失败 → `failed`。
- 安装：`tools/install_gadget.sh --wechat-path … --gadget … --config … --backup-dir … --json`。
  逐行解析 stdout 的 `{"progress":0..1,"stage":"…"}`（兼容 `[stage]0.52|…`），
  回调 `onProgress`；必须出现 `OK` 且退出码 0，否则抛 `HookError.installFailed`。
  前置校验：微信存在且未运行、Gadget dylib/config 存在、`hook/versions/<版本>_mac.json`
  存在，缺一都会给出明确中文错误（版本文件缺失时提示“Hook 版本文件未就绪”）。
- 恢复：`tools/manage_wechat.sh restore --app … --backup-dir …`；微信运行中拒绝。
- bridge：`Process` 启动 `bridge/onebot`，`currentDirectoryURL = bridge/`（onebot 从 cwd 读
  script.js），参数按 architecture.md §3.1：
  `-type=gadget -gadget_addr=127.0.0.1:<gadgetPort> -wechat_conf=<json>
   -receive_host=<host>:<port> -token=<token> -conn_type=websocket -image_path=<当前账号临时目录>`。
  已识别账号时 Runtime **忽略用户配置的** `onebot.imagePath`，直接传
  `AccountProfile.activeImageDirectory()`（当前账号的 `xwechat_files/<wxid>_*/temp`）与
  `accounts/<当前账号>/media`；找不到图片临时目录时阻止启动并提示先登录微信/打开图片，
  不再回退按 mtime 猜账号。未识别账号（`_unassigned`）时才允许显式 `imagePath`/自动探测。
  `-self_id` 已识别账号时用 `AccountProfile.activeID`，未识别时用运行时 selfID
  （见 architecture.md §3.1）。
- stdout/stderr 行流式打日志（token 自动脱敏），进程退出更新 `bridgeRunning/bridgePID`；
  非 0 退出 → `failed`。App 终止通知会停止 bridge/OneBot/Scheduler 并 flush 日志统计。
- **进程生命周期安全**（QA 连续 kill/重启崩溃回归）：`Process.terminationStatus` 只在
  `Process.terminationHandler` 内读取（Foundation 保证此时进程已退出），
  `onTermination` 只请求 SIGTERM，不读状态；事件流由 `NSLock` 状态机保证
  “两个 pipe reader 均 EOF + terminationHandler 已触发”后只 finish 一次；
  取消发生在启动前/后均安全，启动失败会关闭写端且不启动 reader 线程。
- 资源定位顺序：`Bundle.main.resourceURL` → `WECHATAI_ROOT` → bundle/可执行文件/工作目录
  的上层目录（`swift run` 开发态可找到仓库根）→ 源码 `#filePath` 祖先；全部失败返回 nil，
  调用方给出“未找到应用资源目录”错误而不是崩溃。

### 5.8 SleepPreventionCenter（通用防睡眠）

- 设置：`GeneralSettings.sleepPrevention` ∈ `never / externalPowerOnly / always`，默认 `never`。
  使用自定义 Codable：旧 `config.json` 缺少该字段时回退 `never`，未知 rawValue 同样回退，
  不会导致整份配置解码失败。
- 启动：`AppDelegate.applicationDidFinishLaunching` 读取配置并 `apply(mode:)`；
  退出 `applicationWillTerminate` 调用 `release()`。设置页修改时立即 apply 并 persist。
- **与机器人运行状态绑定（2026-10-28）**：只有机器人运行时才持有断言。`startRuntime` 成功后
  `setRuntimeActive(true)`；`stopRuntime` 调用 `setRuntimeActive(false)` 立即释放断言
  （偏好不变，下次启动恢复）。避免“始终防睡眠”在停止机器人后仍让整机无法空闲睡眠。
- 实现：`IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, On, …)`
  持有最多一个断言；`IOPSNotificationCreateRunLoopSource` 监听电源适配器变化，
  回调跳回主线程重算，事件驱动、不轮询。
- 决策：纯函数 `shouldPreventSleep(mode:onExternalPower:)`：
  `never` 永不；`externalPowerOnly` 仅外接电源；`always` 始终。
  桌面 Mac / 读取失败（nil 电源信息）按外接电源处理，保证 `.externalPowerOnly` 可用。
- 失败只写 `lastError`（UI 显示 warning），不崩溃、不影响聊天；
  断言只阻止**系统空闲睡眠**，不阻止合盖、手动睡眠或显示器休眠。

### 5.9 BatteryReader / DeepSeekBalance（设备与账户）

- 电量：`BatteryReader.current()` 通过 IOKit.ps 读取 `InternalBattery` 的
  Current/Max Capacity、Is Charging/Charged、Power Source State、Time to Empty/Full Charge，
  只读、不修改任何系统电源设置。`RuntimeCoordinator` 启动后立即读一次、之后每 30 秒刷新
  `store.batteryStatus`；台式机/无电池返回 `.unavailable`，UI 显示「未检测到电池」而不是 0%。
- 余额：`DeepSeekBalanceClient` 请求 `GET {API origin}/user/balance`。接口固定在 API 根路径，
  聊天 baseURL 的 `/v1` 会被丢弃（`/v1/user/balance` 会 404）；`Authorization: Bearer` 的 Key
  由 Runtime 从 Keychain 读取，读取放在后台线程（ad-hoc 重签后 Keychain 授权弹窗可能阻塞主线程）。
- 通道选择：默认通道是 DeepSeek 时用它；否则回退第一个已启用且有 Key 的 DeepSeek 通道；
  完全没有 DeepSeek 通道时状态为 `unavailable`（UI 给「前往 AI 模型配置」入口）。
- 刷新节奏：启动查一次、之后每 5 分钟轮询；AI 模型页保存通道/Key 后按配置指纹立即重查；
  总览卡片与 `refreshSystemVitals()` 可手动刷新。成功解析 `is_available` 与 `balance_infos`
  （金额字符串或数字均可）；缺 Key/缺通道属于 `unavailable`，网络/HTTP/解析失败属于 `failed`，
  失败只展示原因并可重试，不伪造金额、不阻断机器人运行。

## 6. 错误处理策略

| 场景 | 行为 |
| --- | --- |
| 配置损坏 | `SettingsStore.load` 备份 `config.corrupt-*.json` 后回退默认值 |
| 账号 profile 损坏 | `SettingsStore.loadProfile` 备份 `profile.corrupt-<ts>.json` 后回退 `.default`；不影响其它账号 |
| 旧版迁移失败 | 不写 `account-state.json`；旧库/旧媒体保持原样，下次启动重试；日志记录原因 |
| 账号切换失败 | 运行时已先停止；保持停止并提示重试，不把两个账号的数据写进同一库 |
| 登录账号 ID 非法 | 记 warning 并忽略，不创建账号目录（防止路径穿越） |
| 配置写失败 | `SettingsPersistence` 抛错，UI 触发方可通过日志看到；不产生半截文件 |
| Keychain 失败 | 明确 `KeychainError`；启动时缺 Key 直接阻止机器人启动 |
| AI 超时/5xx/429 | 标记可重试，ChatEngine 按 retryCount 退避重试；最终失败计入 `failedToday` 并写日志 |
| AI 鉴权/404 | 不可重试，日志指出检查 Key/地址 |
| 发送失败 | 消息标 `failed`，统计 +1，日志错误；不自动重发（避免重复消息） |
| WS 断开 | 指数退避自动重连；Hook 状态回 `bridgeStarting` |
| bridge 退出 | 状态 `failed` + 退出码；不自动重启（避免崩溃循环），用户重新启动机器人 |
| 脚本失败 | 捕获 stderr/stdout 错误行，抛中文错误并写日志；状态 `failed` |
| DB 失败 | 记录 warning 日志，内存态继续可用；下次操作重试 |

## 7. 安全

- API Key 仅存 Keychain（`kSecClassGenericPassword`，`service=com.gusionw.wechatai`），
  `config.json` 只有 account 引用；日志与错误信息不会输出 Key。
- OneBot token 由运行时生成（32 字节 hex，空值时自动生成并持久化），HTTP 发送强制 Bearer；
  bridge stdout 中打印的 token 在 UI 日志里替换为 `<redacted>`。
- bridge/WS 只连接 `127.0.0.1`，不监听外部网卡；无 WebView/Electron。
- 安装/恢复脚本只允许操作 `/Applications/WeChat.app`（或设置中的微信路径）与 App 备份目录；
  安装前强制微信退出并做完整官方备份。
- 媒体仅从本地 `file://`/base64 复制，限制 40MB，文件名使用 UUID，不跟随符号链接路径；
  新媒体写入当前账号 `accounts/<id>/media/`，不再写根 `media/`。
- 账号隔离：账号目录名经过 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$` 校验，`_unassigned` 为保留名；
  UI 与日志展示 mask（见 `AppAccount.maskedID`），公开文档不写真实 wxid。
- 旧版迁移只 copy、不删除旧库/旧媒体/旧配置；`account-state.json` 只存账号指针，不含聊天内容。
- Keychain、语音模型、日志文件与备份全局共享；换账号不会复制或删除 API Key。

## 8. 自检与测试

### 8.1 `swift test`（推荐，无需 UI）

测试 target 位于 `app/Tests/WeChatAITests/`（`CoreServicesTests.swift`（48）、
`SleepPreventionTests.swift`（9）、`MessageRoutingTests.swift`（12）、
`NativeSendConfigTests.swift`（5）、`ConversationNameTests.swift`（8）、`WorkingHoursStatusTests.swift`（5）、
`MenuBarClickTests.swift`（9）、`ContactDirectoryTests.swift`（15）、`PatMessageTests.swift`（20）、
`PatReplySettingsTests.swift`（7）、
`HookSelfIDTests.swift`（4）、`WeChatAppmsgTests.swift`（26）、`AppmsgRoutingTests.swift`（20）、
`WakeWindowTests.swift`（6）、`ImageFetchTests.swift`（16）、`OneBotEventParserTests.swift`（5）、
`DataRepairTrustTests.swift`（2）、`VisionTests.swift`（12）、`SystemVitalsTests.swift`（16），
以及 `VoiceReadTests` / `VoiceSynthesisTests` / `VoiceRuntimeStatusTests` / `VoiceCatalogTests` 等语音测试；
2026-10-27 账号隔离 + 2026-10-28 审查修复后为 470 项（8 项按环境跳过）：

```bash
cd app
swift test --scratch-path .build-verify
# Executed 473 tests, with 8 skipped, 0 failures
```

覆盖：MemoryStore 建表/批量写/分页/before 翻页/搜索/KV、消息溢出游标与 8 条批量阈值
（12/18/26 条场景）、长期记忆作用域（当前会话 + 全局，核心不注入其它会话）、
同会话早期片段召回（排除窗口内/当前消息，最多 3 条）、群聊发言人标注
（`senderName` 优先、回退 `senderID`）、手写记忆作为权威参考合并且不被覆盖、
长期记忆滚动合并与历史多条合并、`MemorySummaryCompactor` 去重/600 字上限、
`accessCount` 权重强化与 `sourceCount` 对数增长、`baseWeight` 可调（范围收敛/持久化/
核心记忆按权重排序与超额时的注入优先级）、旧库 v2→v4 迁移；
防睡眠旧配置兼容/三档标签/决策表；设备与账户（电池字典解析、百分比边界与台式机回退，
DeepSeek 余额地址推导、官方字符串/数字金额解析、401 与畸形响应、通道选择优先级）；OneBot 事件解析（群/@/私聊/非法帧）、
入站帧单次解析（`parse(object:rawText:)` 复用对象与原始帧文本、数组/包装帧兼容）、
历史修复 `trusted:` 语义（权威 selfID 跳过反推、默认参数仍反推并归位）、
appmsg 分类（引用 57 / 链接 5 / 文件 6 / 表情 8 / 聊天记录 19 / 转账 2000 / 视频号 51、
嵌套引用与摘要截断）与实时/历史归一化（占位替换、拍一拍不回归、修复幂等、预览刷新）、
RuleEngine 默认触发+黑名单+关键词冷却+唤醒窗口（同一发送者、滑动续期、旧配置兼容）、
Scheduler daily/once nextFireAt、
ChatEngine 分段/角色合并/中英分词/流式总开关、SettingsPersistence 原子写/幂等/无明文密钥、
AIClient endpoint/请求体/无 Key 字段、ProcessRunner 输出收集，
入站图片获取（会话生效值优先级、旧库补列迁移、DB 往返、`ImageFetchPolicy` 8 个门槛、
`/fetch_image` 请求与响应解析、`ImageFetcher` 串行顺序/去重/失败不重试/取消后不回调），识图（旧配置缺键关闭、通道/模型回退、
多模态请求体 `image_url`、候选图片筛选与 2 张/10 分钟上限、描述清洗、
`image_description` DB 往返与提示词 `[图片：…]`），
以及**取消回归**：启动 `/bin/sleep 5` 后立即取消流，进程被终止且不崩溃、事件流及时结束；
另有「`.terminated` 事件只在进程退出后发出」的不变量测试（避免再次出现
`terminationStatus: task still running`）。
多账号隔离（2026-10-27）新增覆盖：resolver 登录标记优先/目录活动回退/非法目录、mask 规则、
`AccountLayout` 路径与目录创建、`preparePaths` 的 detected/state/`_unassigned` 回退与
pendingNotice、旧版迁移（owner 有效/无效、owner == active、owner != active、无旧库、幂等、
profile seed、旧文件保留）、`claimUnassigned` 只复制不删除/不覆盖已有库、
config + profile 双文件加载/损坏备份/去重双写、`MemoryStore` 切换 A/B 库后会话/记忆/日志/KV
互不可见。2026-10-28 审查修复另加回归：`_unassigned` 启动认领、`legacyMigrationDone` 门禁、
空壳目标库替换、WAL 主库无 `-wal/-shm` 时的迁移、`MemoryStore.suspend()` 禁止隐式 open。
当前 `swift test` 470 项通过
（8 项按环境跳过）。

### 8.2 App 内诊断开关

```bash
cd app
swift build --scratch-path .build-core
WECHATAI_SELFTEST=1 WECHATAI_SELFTEST_EXIT=1 ./.build-core/debug/WeChatAI
```

App 正常启动（有窗口会话）时，`AppStore` 初始化完成后会在 `RuntimeCoordinator.bootstrapIfNeeded`
末尾运行 `Diagnostics.runAll()`；`WECHATAI_SELFTEST_EXIT=1` 会按自检结果退出。
无图形会话的 CI/shell 环境不会创建 SwiftUI Scene，因此该入口在 headless 下不会触发，
请改用 8.1 的 `swift test`。

自检覆盖：配置原子写/不重复编码/无明文密钥、Keychain CRUD（签名环境不可用时降级为 WARN）、
SQLite 建表/会话/批量消息/分页/搜索/日志过滤/定时任务/KV/清空删除、
AI endpoint+请求体+错误映射、OneBot 群/私聊/字符串消息/自消息/非法帧解析、
RuleEngine 白黑名单/@/关键词/冷却、Scheduler 各 repeat 的 nextFireAt、
ChatEngine 分段/角色合并/关键词分词。输出 `[selftest] PASS/FAIL/WARN` 与汇总退出码。

历史 CLI 驱动实测：**63 passed / 0 failed / 0 warnings**；当前 `swift test` 为
**200/200 通过**（见 8.1；2026-10-23 实测）。另外用 CLI runtime harness 验证了 `AppStore` 初始化 → SQLite →
Hook 检测 → `startBot` 失败路径（缺 API Key / 未安装 Gadget）、Keychain 保存/删除、
`config.json` 无明文 Key。

## 9. 已知限制 / 后续 TODO

- **bridge 日志格式未定**：`HookManager` 仅做关键字匹配（HTTP 启动、gadget 连接、panic/失败）；
  gateway 连接状态以 OneBot WS 为准。bridge 若后续输出结构化状态行，可在
  `handleBridgeLine` 增加精确解析。
- **bridge 崩溃不自动重启**：避免崩溃循环；需要自动重启时加限次退避。
- **bridge 快速 stop/start**：`HookManager` 用 `bridgeGeneration` 丢弃旧进程的迟到
  回调/退出事件，避免 QA 连续 kill/重启时新 bridge 状态被旧进程覆盖。
- **“正在输入”指示**：bridge/OneBot v11 未暴露该动作，目前仅记录日志；`humanize.typingIndicator`
  暂不影响网络行为。
- **记忆召回**：长期记忆已做批量 AI 摘要、确定性压缩（≤600 字）与权重强化；
  早期片段只在当前会话内按关键词 `LIKE` 召回（最多 3 条、可能已过时），
  不再检索其它会话的原文；未做向量/语义检索，`memoryTokens` 按 CJK/ASCII 切词，
  长文本召回可能漏召。
- **日志按天切割**：当前 DB 环形裁剪（保留 5000 条）+ App 内存 2000 条；
  `logs/` 目录按天文件切割尚未实现（架构低开销目标不要求首版）。
- **自消息 echo**：bridge 用 `-self_id` 判定发送者并输出 `is_self` + `self_id` +
  `target_id`（私聊=对方、群=群 ID）；App 据此把自消息记进正确会话并标 outgoing。
  旧事件若只有 `self_id == sender.user_id` 的形态，仍按启发式兜底。
  历史数据中已经误路由到「自己 wxid」会话的消息，启动时由
  `MemoryStore.repairSelfRoutedMessages(selfID:)` 一次性归位（幂等）；随后
  `get_login_info` 返回的账号是 selfID 权威来源。
- **会话归类自愈**：启动时在上述修复之后再跑
  `MemoryStore.repairMisroutedConversations(selfID:)`，处理两类历史脏数据：
  「自己 wxid / 字面量 `wxid_self`」会话、以及 `kind=group` 但 ID 不是
  `@chatroom` 的伪群会话（例如旧 hook 把私聊拍一拍的 wxid 当群 ID）。
  只搬能由消息 `raw_json` 明确推导目标（真实群 ID 或对方 wxid）的消息，
  不确定则保留；搬完重算预览并删除空会话，幂等（2026-10-21）。
- **appmsg 展示文本自愈**：启动时在其它修复之后跑 `MemoryStore.repairAppmsgMessageTexts()`：
  只扫描文本以 `[链接/文件]` 开头且带 `raw_json` 的消息，按 `raw_message` 的 appmsg
  `<type>` / `<title>` / `<refermsg>` 重算可读文本（引用＝正文 + `【引用 发送者：原文摘要】`），
  批量更新并刷新受影响会话预览；占位前缀后的结构化 `at` 后缀保留，
  解析不出的消息保持原样；幂等（2026-10-22）。
- **引用定界符迁移**（2026-10-22）：旧引用文本 `正文\n[引用 发送者] 原文` 在启动时由
  `MemoryStore.rerenderLegacyQuoteTexts()` 幂等重排为 `正文\n【引用 发送者：原文】`
  （从 `raw_json` 重新生成、保留 `at` 后缀、刷新预览）；`RuleEngine.triggerText`
  同时兼容新旧定界符，历史消息重排失败也不影响触发判定。
- **历史回放不触发回复**：微信加载历史/补同步会把旧消息重新投递，App 仍入库供检索，
  但超过 120 秒的消息不再触发自动回复，也不会把会话预览/未读回退。
- **白名单语义**：`effectiveWhitelist` / `effectiveBlacklist` 是“会话 ID 或用户 wxid”的统一名单；
  黑名单同时检查会话和发送者，白名单命中任一即可。旧版四列表在首次启动时迁移到
  `whitelistEntries` / `blacklistEntries` 并清空。
- **安装脚本进度**：按 `tools/install_gadget.sh` 的 stdout 进度协议解析；`manage_wechat.sh status`
  用于补充插件/备份信息，失败静默降级。
- **测试 target**：`app/Tests/WeChatAITests` 与 `app/Package.swift` 的 `.testTarget` 已就位；
  并行构建时用独立 scratch path（如 `.build-core-tests` / `.build-core`）避免 SwiftPM 锁冲突。
- **headless 环境限制**：无 WindowServer 的 shell 中直接运行 App 二进制不会创建 SwiftUI Scene，
  因此 `WECHATAI_SELFTEST` 的 App 内入口不会触发；CI 请用 `swift test`。
- **多账号**：同一时间只打开一个账号库；运行中换号会停止机器人且不自动重启。不能手动选择
  账号档案/数据库，切号由 resolver 与 bridge `get_login_info` 驱动。未登录时使用
  `_unassigned`，登录后认领复制（保留原目录）。旧版迁移只复制不删除，首次升级需要额外磁盘。
  详细边界见 [`accounts.md`](accounts.md) §8。
- **账号相关日志**：App 内日志在账号库中（分账号），崩溃/bridge 文件日志全局；
  排查换号问题需要同时看 `account-state.json`、账号目录与 bridge 日志。
