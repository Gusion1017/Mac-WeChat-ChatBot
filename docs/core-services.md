# Core 服务层设计与契约（swift-core）

> 对应 `app/Sources/WeChatBot/Services/*` 与 `Core/AppStore.swift` / `Core/AppStore+Runtime.swift`。
> 本文件描述**已实现**的服务能力、并发模型、错误与重连策略、安全边界，供 UI / bridge / hook 协作。
> 总体架构见 [architecture.md](architecture.md)。

## 1. 文件清单

| 文件 | 职责 |
| --- | --- |
| `Core/AppStore.swift` | 共享状态骨架（`@MainActor @Observable`，UI 只读；运行时方法在扩展中） |
| `Core/AppStore+Runtime.swift` | 运行时编排 + 对 UI 暴露的全部运行时 API |
| `Services/SettingsPersistence.swift` | 配置 JSON 原子写、串行化、合并写入 |
| `Services/KeychainStore.swift` | API Key 的 Keychain 读写/删除/存在性 |
| `Services/MemoryStore.swift` | SQLite（WAL）持久化：会话/消息/日志/定时任务/长期记忆/KV |
| `Services/SleepPreventionService.swift` | 通用防睡眠：IOKit 空闲睡眠断言 + 电源适配器监听（事件驱动，不轮询） |
| `Services/ActivationPolicyController.swift` | Dock 图标与 `NSApplication.ActivationPolicy` 同步（用户设置优先，台前调度不覆盖；bundle 以 `LSUIElement` 启动，仅在设置页用于提示文案） |
| `Services/OneBotClient.swift` | WS 收事件、HTTP 发送、媒体落地、事件解析、去重、重连 |
| `Services/AIClient.swift` | OpenAI 兼容 `/chat/completions`，SSE 流式 / 非流式 / 超时 / 错误映射 |
| `Services/RuleEngine.swift` | 白黑名单、私聊/群触发、冷却、频率、工作时段 |
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
  6. ChatReplyPlan：按拟人化延迟/分段逐条 HTTP 发送
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
    UI 据此渲染真实的「N 秒后发送」倒计时与收缩进度条；
  - 提交 OneBot HTTP 前 → `.sending`（UI 显示回执等待时长；R3 未就绪时由 UI 叠加提示）；
  - 投递完成 → `.completed`（约 3 秒后自动清理）；AI / 发送失败 → `.failed`（保留错误，可手动关闭，
    60 秒后兜底清理）。
  同一会话开始新一轮回复会刷新进度令牌，旧状态条的自动清理任务不会误删新进度；
  bot 停止、运行时关闭、会话删除都会清空对应快照。

## 4. 并发与线程模型

| 组件 | 隔离方式 | 说明 |
| --- | --- | --- |
| `AppStore` | `@MainActor @Observable` | UI 只读；所有状态回主线程更新 |
| `RuntimeCoordinator` | `@MainActor` | 编排、事件处理、统计；等待服务用 `await` 让出主线程 |
| `MemoryStore` | `actor` + SQLite `FULLMUTEX` | 所有 SQL 串行；UI/服务层都 `await` |
| `SettingsPersistence` | `actor` | 编码、原子替换、合并写 |
| `SchedulerService` | `actor` | 单循环 + `CheckedContinuation` 唤醒，无轮询 |
| `OneBotClient` | 私有串行 `DispatchQueue` + `URLSessionWebSocketTask` 接收 `Task` | 网络/解析不在主线程；回调由运行时 hop 回 MainActor |
| `AIClient` | 无共享可变状态，`URLSession` async | 请求/SSE 解析在后台 |
| `RuleEngine` | `NSLock` 保护冷却/频率状态 | 纯内存判定，无 IO |
| `ChatEngine` | 无共享可变状态 | 只依赖 `MemoryStore`/`AIClient` |
| `HookManager` | `@MainActor`；`ProcessRunner` 后台读管道 | 脚本/bridge 输出行流式回主线程更新状态 |
| `LogPipeline` | 内部锁 + 200ms 批量刷新 | 后台线程可写；批量合并 UI/SQLite 更新，避免逐行失效 |
| `CrashReporter` / `MainThreadWatchdog` | 锁保护快照；看门狗独立线程 | 异常与卡顿取证不经过 MainActor，避免死锁 |

禁止事项（已遵守）：MainActor 上无阻塞文件/DB/脚本 IO；无忙轮询；无 `sleep` 轮询循环。
`SchedulerService` 只在下一个 `nextFireAt` 到来或 `update/stop` 唤醒时继续，属于事件驱动定时器。

## 5. 服务协议要点

### 5.1 MemoryStore（SQLite）

- 路径：`~/Library/Application Support/WeChatAI/chatbot.sqlite`；`journal_mode=WAL`、
  `synchronous=NORMAL`、`busy_timeout=3000`、`foreign_keys=ON`。
- 表：`conversations`、`messages`、`logs`、`schedules`、`settings`（KV）。
  消息表主键 `id`，`INSERT ... ON CONFLICT(id) DO UPDATE`，可安全重复投递；
  索引：`(conversation_id, timestamp DESC)`、`(timestamp DESC)`、`logs(date DESC)`。
- 批量写：`upsertMessages` / `appendLogs` / `upsertConversations` / `replaceSchedules`
  均在单事务内复用 prepared statement。
- 分页：`fetchMessages(conversationID:limit:before:)` 返回页内时间正序，`before` 向前翻页；
  `fetchConversations(limit:offset:)` 置顶优先、最近活跃优先。
- 搜索：`searchMessages(query:)` 对消息文本做 `LIKE`（转义 `% _ \`），关联会话标题；
  本地数据规模下足够，后续可升级 FTS5。
- 日志环形：App 内存最多 2000 条；DB 每累计 100 条 `pruneLogs(keep: 5000)`。
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
- 自消息去重：进程内 `message_id` LRU（1024）；HTTP 发送成功后登记
  `(conversationID, text, time)`，20s 内 WS 出现同文本的 self 事件时标记
  `isEchoOfLocal`，运行时把本地 pending 消息更新为 sent 而非重复插入。
- 媒体：`file://` 复制、`base64://`/裸 base64 解码，落地
  `~/Library/Application Support/WeChatAI/media/<yyyy-MM-dd>/<uuid>.<ext>`；
  单文件上限 40MB；http(s) URL 仅保存 `mediaURL` 不下载。
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
  当前时间/会话类型/会话名 + `conversation.note`（会话备注）+ 长期记忆注入 + 本会话早期片段召回。
- 群聊：每条 incoming 消息（含历史 user 消息与当前消息）拼成「昵称(wxid)：内容」，
  `senderName` 为空时直接「wxid：内容」（`ChatEngine.attributedUserText` /
  `promptSpeakerLabel`）；私聊不加前缀；自己的消息仍作为 `assistant` 原文。
  群聊 system prompt 说明消息格式，要求**以括号内 wxid 对照长期记忆**
  （记忆里的人员关系是「wxid：称呼」），找不到该 wxid 时不要套用其他人的称呼，
  回复不输出 wxid。昵称会变、会重名，wxid 是消息与记忆之间唯一稳定的连接键。
- 近期上下文：`history.suffix(maxContextMessages)`（上限 10），按方向映射 user/assistant，
  同角色相邻消息合并；确保当前消息在末尾。
- 早期片段召回：只在**当前会话**内按关键词 `LIKE` 检索，排除短期窗口内消息、当前消息、
  系统消息与晚于当前消息的内容；最多 3 条、每条截断 120 字；发出标「我」，
  私聊收到标「对方」，群聊收到标发言人（`promptSpeakerLabel`，缺失时「对方」）；
  标题为「本会话较早的相关片段（可能已过时，仅供参考）」；不再检索其它会话原文。
- 拟人化：`humanize.enabled && splitMessages` 时按句末标点/长度切分，
  合并过短片段，`maxSegments` 封顶，单段最长 600 字；每段随机延迟
  `[minDelayMs, maxDelayMs]`（`ChatReplyPlan.delaysMs`，由运行时执行）。
- dry-run 时不分段/不延迟，只产出计划文本。
- 长期记忆召回：只注入「当前会话 + 全局」记忆，核心记忆同样遵守作用域
  （其它会话的核心记忆不注入）；按核心 → 手写 → 自动总结的优先级、同层按**综合权重**降序，
  默认最多 6 条（`ChatEngine.longTermMemoryLimit`，核心记忆优先占用名额）；
  综合权重 = 基础权重 × 内容重要度 × 使用强化 × 30 天半衰期，其中基础权重可由用户
  在记忆编辑器中自由调整（0.1~10×），核心记忆之间也按该权重排序；提示词注明核心/手写优先、
  自动总结仅供参考、冲突时以核心/手写为准；召回后 `MemoryStore.recordMemoryAccess(ids:)`
  以 best-effort 累加访问次数。
- 批量总结：短期窗口（10 条）外的未总结消息**攒够 8 条**才调用一次 AI，
  单批最多 40 条；12 条不总结、18 条总结 8 条、26 条再总结 8 条。
  AI 提示要求结构化（人物与称呼 / 偏好 / 约定与待办 / 其他），最多 5 条要点、
  总长 ≤600 字，不编造、不罗列成员 wxid 清单；同会话手写记忆作为「权威参考」传入
  合并提示、不被覆盖；结果经 `MemorySummaryCompactor` 强制 ≤600 字符；
  无 Key/AI 失败时本地兜底同样压缩；同一会话只保留一条自动滚动总结，
  历史遗留的多条自动总结会先合并清理。详见 [memory.md](memory.md)。
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
   -receive_host=<host>:<port> -token=<token> -conn_type=websocket -image_path=<真实临时目录>`。
  `image_path` 优先用户配置；否则扫描
  `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/*/temp/`；
  找不到时阻止启动并提示先登录微信。
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
- 实现：`IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, On, …)`
  持有最多一个断言；`IOPSNotificationCreateRunLoopSource` 监听电源适配器变化，
  回调跳回主线程重算，事件驱动、不轮询。
- 决策：纯函数 `shouldPreventSleep(mode:onExternalPower:)`：
  `never` 永不；`externalPowerOnly` 仅外接电源；`always` 始终。
  桌面 Mac / 读取失败（nil 电源信息）按外接电源处理，保证 `.externalPowerOnly` 可用。
- 失败只写 `lastError`（UI 显示 warning），不崩溃、不影响聊天；
  断言只阻止**系统空闲睡眠**，不阻止合盖、手动睡眠或显示器休眠。

## 6. 错误处理策略

| 场景 | 行为 |
| --- | --- |
| 配置损坏 | `SettingsStore.load` 备份 `config.corrupt-*.json` 后回退默认值 |
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
- 媒体仅从本地 `file://`/base64 复制，限制 40MB，文件名使用 UUID，不跟随符号链接路径。

## 8. 自检与测试

### 8.1 `swift test`（推荐，无需 UI）

测试 target 位于 `app/Tests/WeChatAITests/`（`CoreServicesTests.swift`（44）、
`SleepPreventionTests.swift`（9）、`MessageRoutingTests.swift`（12）、
`NativeSendConfigTests.swift`（5）、`ConversationNameTests.swift`（8）、`WorkingHoursStatusTests.swift`（5）、
`ContactDirectoryTests.swift`（15）、`PatMessageTests.swift`（20）、`PatReplySettingsTests.swift`（7）、
`HookSelfIDTests.swift`（4）、`WeChatAppmsgTests.swift`（25）、`AppmsgRoutingTests.swift`（20），共 174 项）：

```bash
cd app
swift test --scratch-path .build-verify
# Executed 174 tests, with 0 failures（2026-10-22）
```

覆盖：MemoryStore 建表/批量写/分页/before 翻页/搜索/KV、消息溢出游标与 8 条批量阈值
（12/18/26 条场景）、长期记忆作用域（当前会话 + 全局，核心不注入其它会话）、
同会话早期片段召回（排除窗口内/当前消息，最多 3 条）、群聊发言人标注
（`senderName` 优先、回退 `senderID`）、手写记忆作为权威参考合并且不被覆盖、
长期记忆滚动合并与历史多条合并、`MemorySummaryCompactor` 去重/600 字上限、
`accessCount` 权重强化与 `sourceCount` 对数增长、`baseWeight` 可调（范围收敛/持久化/
核心记忆按权重排序与超额时的注入优先级）、旧库 v2→v4 迁移；
防睡眠旧配置兼容/三档标签/决策表；OneBot 事件解析（群/@/私聊/非法帧）、
appmsg 分类（引用 57 / 链接 5 / 文件 6 / 表情 8 / 聊天记录 19 / 转账 2000 / 视频号 51、
嵌套引用与摘要截断）与实时/历史归一化（占位替换、拍一拍不回归、修复幂等、预览刷新）、
RuleEngine 默认触发+黑名单+关键词冷却、Scheduler daily/once nextFireAt、
ChatEngine 分段/角色合并/中英分词/流式总开关、SettingsPersistence 原子写/幂等/无明文密钥、
AIClient endpoint/请求体/无 Key 字段、ProcessRunner 输出收集，
以及**取消回归**：启动 `/bin/sleep 5` 后立即取消流，进程被终止且不崩溃、事件流及时结束；
另有「`.terminated` 事件只在进程退出后发出」的不变量测试（避免再次出现
`terminationStatus: task still running`）。

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
**174/174 通过**（见 8.1；2026-10-22 实测）。另外用 CLI runtime harness 验证了 `AppStore` 初始化 → SQLite →
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
