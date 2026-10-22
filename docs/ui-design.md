# 微信 AI 助手（WeChat AI）— UI 设计说明

> 面向 macOS 26（Xcode 27 / Swift 6.2）的原生 SwiftUI 界面。本文描述信息架构、页面结构、
> 组件拆分、设计 token、交互与可访问性约定。实现位于 `app/Sources/WeChatBot/DesignSystem/`
> 与 `app/Sources/WeChatBot/Views/`，App 场景在 `WeChatBotApp.swift`。

## 1. 设计目标

1. **原生 Apple 质感**：`NavigationSplitView` + 隐藏标题栏 + Liquid Glass 卡片 + 系统材质；
   不使用 WebView、不模拟网页控件。
2. **信息密度适中**：桌面级三栏/双栏布局，列表可扫描，表单分组清晰。
3. **状态实时可见**：微信 / Hook / AI / OneBot 四个运行状态在侧边栏、总览、菜单栏保持一致。
4. **服务未接入也可用**：所有页面在 Core 未连接时用禁用态、加载态或「服务未连接」提示兜底，
   不伪造成功。
5. **可访问性优先**：语义字体、VoiceOver 标签、减少动态效果降级、深浅色完整适配。

## 2. 信息架构

主窗口左侧为自定义侧边栏，分三段共 9 个页面（首次向导为独立全屏流程，不计入侧边栏）：

| 分组 | 页面 | 职责 |
| --- | --- | --- |
| 常用 | 总览 `dashboard` | 健康状态、今日统计、快捷操作、最近活动/会话 |
| 常用 | 会话 `conversations` | 会话列表 + 聊天详情 + 手动发送 |
| 自动化 | 机器人 `bot` | 总开关、演练模式、私聊/群聊策略、白/黑名单、频率、工作时间、拟人化 |
| 自动化 | AI 模型 `ai` | 多通道增删改、Keychain 密钥、连接测试、全局请求参数 |
| 自动化 | 人格设定 `personas` | 人格卡片网格 + 编辑 sheet |
| 自动化 | 定时任务 `schedules` | 任务列表、下次执行时间、新建/编辑 |
| 系统 | 记忆库 `memory` | 长期记忆文件夹、搜索、编辑/核心记忆、聊天记录浏览与清理 |
| 系统 | 运行日志 `logs` | 实时流、级别/来源过滤、暂停、清空、导出 |
| 系统 | 设置 `settings` | 通用/外观/通知/Hook/OneBot/数据备份/关于 |

附加入口：

- 菜单栏 `MenuBarExtra`（可在设置中关闭）：状态、快捷启停、打开主窗口、页面直达、退出（⌥⌘Q）。
- 首次启动向导：4 步 sheet，可从设置或菜单重新打开。
- App 设置场景（⌘,）：复用 `SettingsView`。

## 3. 窗口与导航

```
Window("WeChat AI", id: "main")
├─ NavigationSplitView (balanced, hiddenTitleBar)
│  ├─ SidebarView (236pt, 216–286 可调, ultraThinMaterial)
│  │  ├─ 品牌区（避开交通灯，38pt 顶部内边距）
│  │  ├─ 三段导航（常用 / 自动化 / 系统）
│  │  └─ 底部状态胶囊（机器人 + 微信/Hook/AI）+ 版本/设置
│  └─ PageRouter → 9 个页面（首次向导另计）
├─ Settings scene → SettingsView (880×640)
└─ MenuBarExtra (window 样式, 304pt)
```

- 侧边栏选中高亮使用系统语义色 `Color.accentColor`，行高 30pt、圆角 7pt；悬停为 4.5% 主色。
- 窗口隐藏标题栏，内容延伸到交通灯区域；侧边栏顶部预留 `Theme.titlebarInset (38pt)`。
- 页面切换有 0.18s 平滑动画；开启「减少动态效果」时自动关闭。
- 会话页在主窗口内形成第三栏：侧边栏 + 会话列表（304pt）+ 聊天详情。
  再次点击会话列表中当前选中的那一行，或再次点击侧边栏「会话」入口，可收起当前对话
  （详情区回到「选择一个会话」空状态）；会话列表本身始终可见，不折叠。

## 4. 设计 token

定义位置：`DesignSystem/Theme.swift`。

### 4.1 颜色

| Token | 值 / 语义 |
| --- | --- |
| `Theme.accent` | 微信品牌绿 `rgb(51,199,115)`，用于主按钮、选中态、气泡 |
| `Theme.accentStrong` | 深绿，用于渐变端点 |
| `Theme.info` / `success` / `warning` / `danger` / `violet` | 语义状态色 |
| `Theme.hairline` | `Color.primary.opacity(0.07)`，卡片/分隔线 |
| `PageBackground` | 系统窗口底色 + 极淡品牌绿/蓝渐变（深色模式降低透明度） |
| `Color.accentColor` | 侧边栏选中与系统控件，尊重用户系统强调色 |

所有颜色使用语义 `Color`/材质，浅色/深色自动适配；不写死黑白。

### 4.2 字体

统一使用系统字体（SF Pro / 苹方），以语义字号为主，保证 Dynamic Type：

| Token / 用法 | 字体 |
| --- | --- |
| 页面标题 | `.title2.weight(.semibold)` |
| 卡片标题 | `.headline` / `.subheadline.weight(.semibold)` |
| 正文 | `.body` |
| 列表主标题 | `.callout` |
| 辅助信息 | `.caption` / `.caption2` |
| 数字指标 | `.title2/.largeTitle` + `.rounded` + `.monospacedDigit` |
| 日志/ID/路径 | `.caption` + `.monospaced` |

### 4.3 间距、圆角、材质

| Token | 值 |
| --- | --- |
| 侧边栏宽度 | 236pt（216–286） |
| 会话列表宽度 | 304pt |
| 页面内边距 | 24pt |
| 卡片内边距 | 18pt（紧凑卡片 12–15pt） |
| 卡片圆角 | 18pt（小卡片 12–16pt，控件 7–10pt） |
| 区块间距 | 20pt |
| 侧边栏材质 | `.ultraThinMaterial` + 1pt 分隔线 |
| 卡片 | `.glassEffect(.regular.tint(accent 4.5%), in: .rect(cornerRadius: 18))` |
| 工具栏 | `.ultraThinMaterial` + 底部 1pt 分隔线 |
| 日志/设置分组 | `.regularMaterial` + `hairline` 描边 |

### 4.4 动效

- 页面切换：`.smooth(duration: 0.18)`。
- Toast：`.snappy(0.22)` 进出，2.6s 自动消失。
- 进度条/加载：系统 `ProgressView`。
- **不使用 `repeatForever` 动画**：Liquid Glass 背景采样下会持续触发重绘（实测空闲 CPU 升高）。
  「运行中」用静态光晕 + 彩色状态点表达。
- 所有动画经 `@Environment(\.accessibilityReduceMotion)` 开关。

## 5. 页面结构

### 5.1 总览

- `GlassToolbar`：问候语 + 日期；刷新、启动/停止机器人（本页唯一的启停入口）。
- 三张 `StatusCard`：微信（版本/进程）、Hook（状态/版本匹配/桥接）、AI（默认通道/模型/密钥状态）。
- 四张 `MetricTile`：今日收到、今日回复、失败、AI 平均延迟（`contentTransition(.numericText())`）。
- `SectionCard` 快捷操作（3 列）：安装 Hook、测试 AI、设置、首次向导、日志、记忆库；
  启动/停止与刷新只保留在工具栏，避免同页重复入口；位于最近活动/最近会话双栏之上。
- 双栏 `SectionCard`：最近活动（日志）与最近会话（点击跳转会话页）。
- 运行中安装 Hook 显示 `ProgressPanel`（onProgress 回调）。
- 未连接 OneBot 时底部显示 warning `InlineNotice`。

### 5.2 会话

- 左栏：标题/未读汇总、搜索、筛选 chips（全部/未读/AI 开启）、`SessionRow` 列表、连接状态 footer。
  再次点击当前选中的会话行，或再次点击侧边栏「会话」入口，会收起当前对话（取消选中，
  详情回到空状态）；会话列表始终可见，不折叠。
- `SessionRow`：头像占位（首字/群组图标 + 稳定色）、标题、时间、预览、未读徽标、置顶标记；选中会话/进入页面即自动标记已读；
  AI 自动回复关闭时显示 `bolt.slash` 状态标记（不可点击，避免与详情开关重复）。
  当该会话正在生成 / 等待发送 / 发送中时，右上角相对时间改为 `ReplyMiniStatus` 阶段计时
  （如「生成 6s」「3s 后发送」「发送中」「失败」），便于同时处理多个会话时定位。
- **会话命名**：`Conversation.displayTitle` 统一解析展示名，优先级为
  **用户重命名 / 微信真实昵称 → 系统账号中文名 → 可读兜底**
  （`群聊 · 尾号` / `微信好友 · 尾号` / `公众号 · 尾号`）。微信 4.1.15 的入站事件只带 wxid
  （消息对象不含昵称，通讯录是加密 SQLite），因此列表与详情**不再显示裸 wxid / `xxx@chatroom`**；
  详情头部仍用等宽小字展示原始 ID，方便核对。
- **会话重命名**：详情头部菜单「重命名会话…」打开 `ConversationRenameSheet`，保存写入
  `conversations.title`（留空恢复自动名称），并同步到 AI 提示词与日志里的会话名；
  已重命名的会话不会被后续消息里的 wxid 覆盖。旧版本写入的 ID 标题由
  `MemoryStore.repairPlaceholderConversationTitles` 在启动时一次性清理。
- 详情头部：会话标题/类型/ID、**唯一的 AI 自动回复开关**、人格/置顶/标记已读菜单（已移除免打扰设置）、
  实时回复状态徽标 `ReplyStatusBadge`（AI 生成中 · 已等待时长 / N 秒后发送 / 发送中 / 已发送 / 失败）。
- 会话工作时间：菜单可选「跟随全局 / 自定义时段 / 此会话不限制」；自定义弹窗编辑星期与起止时间，
  设置随会话写入数据库。详情头部常驻实时状态徽标 `WorkingHoursBadge`：
  「工作时段 / 非工作时段 / 不限时段」，按会话覆盖优先的生效时段判定，每分钟自动刷新；
  悬停显示时段来源（全局 / 会话）与摘要（如「工作日 09:00–18:00」）。
  该状态与 `RuleEngine` 的工作时段拦截口径一致：非工作时段不自动回复，手动发送不受限制。
- 消息区：`DateSeparator`（超过 5 分钟插入）+ `MessageBubble`；底部锚定；新消息自动滚动。
- 气泡类型：文本、图片（本地 `NSImage` / 远程 `AsyncImage` / 占位）、语音、表情、文件、视频、链接、
  系统通知；发送状态：生成中（三点）、待发送、已发送、失败。
- appmsg 卡片（2026-10-22）：引用回复、链接、文件、表情、聊天记录、转账、视频号等统一以文本气泡
  展示；引用为「回复正文换行 `[引用 发送者] 原文摘要`」，不再出现笼统的 `[链接/文件]`
  （历史数据启动时按同一解析器重算）。拍一拍仍显示为「… 拍了拍 …」。
- 输入区：多行 `TextField`、⌘↩ 发送、服务未连接时禁用发送并提示；AI 开关只在详情头部出现一次。
- **回复处理倒计时**（`ReplyProgressBar`，输入区上方）：收到消息并触发自动回复后实时展示流水线阶段，
  用户无需翻日志即可判断卡在哪一步：
  - `generating`：AI 请求已发出，显示「已等待 N 秒」（生成耗时不可预知，因此正向计时）与通道 · 模型；
  - `waitingToSend`：拟人化随机延迟，显示真实的「N 秒后发送」倒计时与随倒计时收缩的进度条；
  - `sending`：等待 bridge 发送回执，显示回执等待时长；4.1.15.55 / 4.2.0.5 R3 未拿到发送句柄时
    直接显示「R3 发送句柄未就绪（微信重启后需在本机微信手动发一条消息）」或队列条数
    （App/bridge 重启会从缓存自动恢复句柄，不再要求手动发送）；
  - `completed`：显示总用时与「已发送 N 段」，3 秒后自动收起；
  - `failed`：显示错误原因并保留，可点 × 手动收起（60 秒后也会自动清理）。
- 空状态：无会话 / 未选中会话（包括再次点击当前会话行后收起对话）/ 会话无消息。

### 5.3 机器人

- 状态卡：大圆角渐变图标、运行状态、真实/演练模式、配置停用提示、连接状态；
  启动/停止只保留在页面顶部工具栏（本页唯一入口）。
- 「回复策略」：演练模式（本页唯一开关）、私聊自动回复、群聊触发方式多选（@ / 关键词 / 拍一拍 /
  引用机器人 可组合，「所有消息」与其它方式互斥）、关键词 chips 编辑器、忽略自己、忽略公众号。
  命令前缀仅保留给历史配置。
- 「引用机器人」（2026-10-22 新增，默认关闭）：别人引用机器人发过的消息时唤醒，正文无需 @/关键词；
  判定用 refermsg 的结构化发送者 wxid（`<chatusr>`，私聊形态回退 `<fromusr>`），不看昵称；
  chip 悬停提示「引用机器人：别人引用机器人发的消息时唤醒机器人（正文无需 @ 或关键词）」，
  被引用原文仍只作为 AI 上下文，不参与 @/关键词触发。
- 群聊 @ 判定只认结构化 `at` 段且目标为机器人本人；@ 其他人、或文本里出现 `@`
  都不会触发（避免群收款/卡片等 appmsg 误回复）。
- 拍一拍判定只认 `pat_target_wxid == 机器人 wxid`；群里拍别人不触发。回复策略新增
  「拍一拍回复」开关（默认关闭）：开启后显示——
  - 「发送自定义文字」：AI 前文字 / AI 后文字（留空不发送，支持 `{name}` 占位符）；
  - 「附带 AI 回复」：使用普通回复的 persona/provider/model；
  - 「群聊被拍后 @ 拍的人」（默认关闭）：仅群聊生效。真实 @ 以 OneBot `at` 段交给
    bridge（`<atuserlist>` 与群昵称由 bridge 解析），附在第一条回复前——
    自定义前文字 / AI 首段 / 自定义后文字中谁先发出就 @ 谁那条，避免多条回复重复 @；
  - 发送顺序提示：自定义文字（前）→ AI 回复 → 自定义文字（后）；AI 失败时仍发送文字。
  全部内容都未发出而回退普通 AI 回复时，@ 同样只附在回退回复的第一条。
  回拍已移除，设置页不再出现「仅回拍」「回拍位置」等选项。bridge 解析不到群昵称时，
  该条退化为不带 @ 的普通文本发送，不阻断回复。
- 「白名单 / 黑名单」：统一为两个 `IDListEditor`，条目可以是会话 ID 或用户 wxid；
  chips 可删、可从会话选择；白名单为空表示全部允许，重叠时显示 warning（黑名单优先）。
- 「频率与上下文」：冷却 Slider、每分钟回复数、短期上下文条数 Stepper；
  文案提示窗口外旧消息攒够批量阈值（`ChatEngine.overflowBatchThreshold`，当前 8 条）后批量总结。
- 「工作时间」：开关、星期 chips、起止时间 `DatePicker`（分钟整数绑定）。
- 「拟人化」：开关、随机延迟双 Slider（自动保持 min ≤ max）、分段开关/段数、输入中状态。
- 「默认人格」：默认人格 Picker；系统提示词只在「人格设定」页维护，Bot 页不再提供全局提示词；
  默认 AI 通道只在「AI 模型 → 全局请求」设置一处（Bot 页不重复提供 Picker）。
- 所有修改即时写回 `store.settings`，保存按钮 + 离开页面时 `persist()`。

### 5.4 AI 模型

- 顶部：通道数量/默认通道摘要、添加通道。
- `ProviderRow`：类型图标、名称、类型/默认/停用徽标、baseURL host、模型、Keychain 状态、
  token、流式标记、测试按钮（idle/testing/success/failure）、启用开关、编辑、更多菜单
  （编辑/测试/删除；**默认通道只通过「全局请求」Picker 设置**，行内不重复提供入口）。
- `ProviderEditorSheet`：名称、类型、Base URL、模型、API Key（SecureField + 显示切换 + Keychain 说明）、
  最大 token/超时 Stepper、通道级流式开关；温度不在此设置。
  **启用/停用只在通道列表行操作**，编辑 sheet 不重复提供开关。保存前校验 URL/名称/模型。
  已保存密钥可在此清除。
- 「模型温度」：按模型名列出所有实际使用的模型（通道/人格覆盖），每个模型可单独设置
  0–2 的温度或恢复模型默认；未配置时请求不发送 `temperature`。
- 「全局请求」：默认通道 Picker（全页唯一默认通道入口）、流式总开关（关闭后所有通道非流式；
  开启时跟随各通道的流式设置）、超时、失败重试。
- 「密钥与安全」：Keychain 策略说明、测试行为说明、Ollama 说明、配置文件路径（可复制）。
- 删除通道需确认；删除默认通道自动回退到第一个通道。

### 5.5 人格设定

- 自适应网格（`LazyVGrid`，280–420pt）；`PersonaCard`：渐变头像、名称/默认徽标、
  简介、提示词预览、模型覆盖、编辑按钮、更多菜单（设为默认/删除）。
- `PersonaEditorSheet`：名称、简介、系统提示词 `TextEditor`、可选模型覆盖；不再设置回复风格
  或温度（温度按模型在 AI 模型页配置）；校验名称/提示词。
- 默认人格联动 `settings.bot.defaultPersonaID`；删除默认人格自动回退。

### 5.6 记忆库

- 顶部分段：**长期记忆** / **聊天记录**；搜索、在 Finder 显示数据库；聊天记录模式提供清理。
- 长期记忆模式：左侧「文件夹」栏 + 右侧记忆列表（双栏，与聊天记录模式一致）：
  - 文件夹：全部记忆（默认）、全局记忆、按会话类型分节（私聊/群聊/公众号）的会话文件夹、
    「未关联会话」兜底；每行显示记忆条数与核心星标，选中高亮。
  - 搜索跨全部记忆并在标题提示结果数（`PillLabel`「跨全部记忆」）；无搜索时按当前文件夹过滤；
    列表顶栏保留当前文件夹、条数与 ★核心计数。
  - 顶栏右侧新增「仅核心」筛选 `FilterChip`、排序菜单（综合权重 / 最近更新）与权重说明
    （`info.circle` + `help`/`popover`）；顶栏只保留「权重」短标签，不再整行展示超长公式。
    说明面板注明**基础权重可调**（0.1~10×）与核心记忆的注入名额
    （`ChatEngine.longTermMemoryLimit`）。
  - 「仅核心」对文件夹与搜索结果同时生效；筛选后为空时说明原因并提供「显示全部记忆」按钮。
  - 排序：默认「综合权重」核心记忆优先、其余按 `timeWeight()` 降序；「最近更新」按 `updatedAt`
    降序且不强制核心前置；搜索与文件夹过滤逻辑不随排序改变。
  - 新增记忆时按当前文件夹预填关联会话；卡片徽标显示范围（全局/会话）、来源
    （`source == "manual"` →「手写」，否则「自动滚动」）、★核心与综合权重；
    手工调整过基础权重时追加「基础 ×N.N」徽标；活动行保留更新时间、
    「合并 N 条」「召回 N 次」，超过 7 天未更新时追加提示（只读现有字段，不新增模型属性）。
  - `MemoryEditorSheet`：提示「核心记忆在所属会话内优先注入并可自由调整权重；
    关联“全局记忆”时对所有会话生效」；新增**基础权重**控件：滑块 0.1~10.0×（步长 0.1）、
    0.5×/1×/2×/3×/5× 预设与重置，实时显示保存后的综合权重估算，并说明核心记忆之间
    也按权重排序、注入名额最多 `ChatEngine.longTermMemoryLimit` 条；
    编辑已有自动记忆时提示「保存后转为手写记忆：自动总结不再覆盖，并作为后续合并的权威参考」；
    新增记忆按手写记忆处理，说明自动总结不会覆盖。
  - 自动记忆每会话一条滚动摘要，批量总结上限 600 字；历史多条自动记忆会先合并清理。
- 聊天记录模式：左栏会话列表（消息数/最后时间），搜索时按命中过滤；
  右栏消息浏览（发送者、会话、时间、内容；`textSelection`），搜索时跨会话展示命中消息。
- 数据库路径、消息总数、复制路径。
- 长期记忆卡片的删除菜单会弹出 `confirmationDialog`（显示记忆摘要前 40 字），确认后才删除；
  编辑弹窗内的删除同样二次确认，避免误触。
- `MemoryCleanupSheet`：仅当前会话 / 清空全部，二次确认 + 风险说明，调用
  `store.clearMessages(conversationID:)`。
- 空状态区分「记忆库为空」「文件夹为空」「没有核心记忆」和「搜索无结果」；
  涉及短期窗口 / 批量总结阈值的文案引用 `ChatEngine.shortTermMemoryLimit` /
  `ChatEngine.overflowBatchThreshold` 常量，不在界面写死数字。

### 5.7 定时任务

- 顶部：任务数/启用数、新建任务。
- 全部/启用/停用筛选；`ScheduleRow` 左侧突出下次执行时间（时:分 + 今天/明天/星期），
  任务名、重复方式、每周星期、内容、目标会话、下次/上次、启停、编辑、删除。
- `ScheduleEditorSheet`：名称、目标会话（列表选择或手动 ID）、内容、重复方式、星期 chips、
  执行时间 DatePicker、下次执行预览、启用开关；
  校验名称/目标/内容/星期/一次性任务时间。
- 下次时间优先使用 Core 的 `nextFireAt`，否则 UI 用 `ScheduleMath` 估算。

### 5.8 运行日志

- 工具栏：暂停/继续、导出、清空（确认）。
- 过滤：级别 chips（含计数）、来源菜单、搜索、自动滚动、实时/暂停状态、条数统计。
- 日志列表：`LogRow` 等宽时间/级别/来源/消息；错误警告行带浅色底；文本可选。
- 暂停时展示暂停瞬间快照；导出为 `.log`（`NSSavePanel`，UTType plainText）。

### 5.9 设置

左侧分类（应用 / 集成 / 数据）+ 右侧分组卡片：

| 分类 | 内容 |
| --- | --- |
| 通用 | 菜单栏图标、登录启动、Dock 图标、退出确认、**防睡眠（永不/接入电源时/始终 + 当前状态）**、语言、重新打开向导 |
| 外观 | 系统/浅色/深色分段选择 + 三个外观缩略预览；减少动态效果与动态字体状态；设计说明 |
| 通知 | 通知开关、声音开关、系统权限说明 |
| Hook | 微信版本/进程/Gadget/Bridge/网关/版本匹配/**R3 发送句柄状态**、安装/还原/刷新、进度、风险提示、路径/端口/自动启动/**R3 原生发送开关（4.1.15.55 / 4.2.0.5，默认开；首次需本机手动发一条消息）** |
| OneBot | Host/Port/连接类型/Token（安全显示+复制）、Bridge 路径、图片目录、WS 地址 |
| 数据与备份 | 数据目录/配置/数据库/日志/备份/媒体路径（Finder 跳转）、导出配置、打开目录、重新加载、日志清空 |
| 关于 | 图标、版本/Build、Bundle ID、系统版本、架构、资源路径、**运行信息**、**技术栈与许可**（每项写明本项目中的用途）、**自研能力概述**（版本适配、收发送、通讯录读取、安全边界与分析工具链；不展示地址、结构偏移或密钥细节）、上游开源项目 GitHub 链接与许可（重新打开向导只在「通用」页提供） |

「节能与睡眠」交互：

- 三档 segmented Picker：永不 / 接入电源时 / 始终；附当前档说明。
- 「当前状态」PillLabel：已关闭 / 已生效（阻止空闲睡眠）/ 未生效（使用电池）；
  IOKit 失败时在区块下方显示 warning `InlineNotice`，不阻塞其它设置。
- 修改后立即 `SleepPreventionCenter.apply(mode:)` 并持久化；footer 说明仅阻止系统空闲睡眠，
  不阻止合盖/手动睡眠，也不保持显示器常亮。
- 同页同一设置只保留一个入口（例如启动开关只在工具栏、UI 开关只在对应列表行/详情头）。

### 5.10 首次启动向导

4 步 sheet（720×620），顶部步骤指示器 + 跳过；右上角「语言 / Language」选择
跟随系统 / 简体中文 / English，切换即时生效（与设置 → 通用 → 界面语言同步）。

1. **欢迎**：品牌图标、隐私/本地优先/多模型说明、微信版本与风险提示。
2. **微信 Hook**：路径/版本/进程/Gadget 状态、检测微信、备份并安装（`ConfirmSheet` 二次确认 +
   备份/重签/风险说明）、`installHook(onProgress:)` 进度、失败错误、跳过说明。
3. **AI 模型**：默认通道 Picker、Base URL/模型摘要、API Key（Keychain）、保存并测试连接、
   无通道时可创建默认 DeepSeek、测试结果内联展示。
4. **启动**：微信/Hook/AI 检查清单、启动后立即运行开关、完成并启动。

底部：上一步（禁用态）、步骤 n/4、下一步/完成并开始；安装中禁止交互与关闭 sheet。

### 5.11 菜单栏

`MenuBarExtra` window 风格（304pt）：

- 头部：品牌、运行状态、状态点。
- 状态：微信、Hook、AI、今日收到/回复/延迟。
- 操作：启动/停止、打开主窗口、总览/会话/AI 模型/设置、退出（⌥⌘Q）。
- `isInserted` 由 `store.settings.general.showInMenuBar` 驱动；写回加相等性 guard，
  避免 MenuBarExtra 场景循环（实测会导致 100% CPU）。
- 主窗口关闭按钮与 ⌘W 改为隐藏窗口（`orderOut`），可从菜单栏（或 Dock，若启用）重新显示；
  退出不再绑定 ⌘Q，仅保留 ⌥⌘Q 与菜单栏「退出」。

### 5.12 设置场景

`Settings { SettingsView() }`，系统自动绑定 ⌘,；复用同一套设置页面与分类侧边栏。

## 6. 组件清单

### DesignSystem

| 文件 | 组件 |
| --- | --- |
| `Theme.swift` | 颜色/字体/尺寸 token、`PageBackground`、`UIFormat`、`Theme.hookColor` 等 |
| `Surfaces.swift` | `GlassCard`、`SectionCard`、`GlassToolbar`、`ScrollingPage`、`IconTile`、`AvatarView`、`StatusDot`、`PillLabel`、`SectionHeader`、`MetricTile` |
| `Controls.swift` | `FlowLayout`、`FilterChip`、`TagChip`、`IconActionButton`、`CopyButton`、`FormField`、`KeyValueRow`、`PathRow`、`InlineNotice`/`NoticeKind`、`SearchField`、`SettingsSection`/`SettingsRow`/`SettingsDivider`、`UnavailableLabel` |
| `Feedback.swift` | `EmptyState`、`LoadingState`、`SkeletonBlock`、`ProgressPanel`、`ConfirmSheet`、`ToastCenter`/`ToastView`/`ToastOverlay` |

### Views/Components

| 组件 | 用途 |
| --- | --- |
| `StatusCard` / `QuickActionButton` | 总览健康状态、快捷动作 |
| `SessionRow` | 会话列表行（AI 关闭时显示状态标记，开关在详情头部；回复处理中显示阶段计时） |
| `WorkingHoursBadge` | 会话详情头部实时工作时间状态（工作时段 / 非工作时段 / 不限时段，悬停看来源与摘要） |
| `ReplyProgressBar` / `ReplyStatusBadge` / `ReplyMiniStatus` | 回复流水线状态条、详情头部徽标、会话行计时（AI 生成 / 拟人化发送倒计时 / 发送回执 / 失败） |
| `MessageBubble` / `SystemNoticeRow` / `TypingIndicator` / `DateSeparator` | 聊天消息 |
| `ProviderRow` / `ProviderTestState` | AI 通道行与测试状态 |
| `ProviderEditorSheet` | AI 通道编辑 |
| `PersonaCard` | 人格卡片 |
| `ScheduleRow` / `ScheduleMath` | 定时任务行与下次时间估算 |
| `LogRow` | 日志行 |
| `GlassToolbar` / `Toast` / `EmptyState` / `ConfirmSheet` | 见 DesignSystem |

## 7. 交互约定

### 键盘快捷键

| 快捷键 | 行为 |
| --- | --- |
| ⌘1 … ⌘8 | 总览、会话、机器人、AI 模型、人格设定、记忆库、定时任务、运行日志 |
| ⌘0 | 设置页 |
| ⌘, | 打开系统设置场景 |
| ⌘↩ | 会话页发送消息（服务连接时） |
| ⌘W | 隐藏主窗口（不退出、不销毁） |
| ⌥⌘Q | 退出 WeChat AI（⌘Q 已不再绑定退出） |
| Esc | 关闭 sheet / 确认框 |

### 状态与错误

- Core 未连接：发送按钮、清理、测试等操作禁用并显示「服务未连接」；不制造成功结果。
- 异步操作：`ProgressView`/`ProgressPanel`；Hook 安装显示 `onProgress` 百分比。
- 失败：`InlineNotice(.danger)` + Toast；错误不吞掉。
- 破坏性操作（删除通道/人格/任务、清理记忆、清空日志、安装/还原 Hook）均二次确认。
- 配置修改即时持久化；编辑 sheet 保存前校验并展示错误。
- 回复进度：状态条以 `TimelineView` 每 0.25s 刷新计时（仅活动阶段），完成态 3s、失败态 60s
  后自动清理；失败可立即点 × 收起。计时数字使用 `monospacedDigit`，避免跳动。

### 会话收起

- 两个等价触发：再次点击会话列表中当前选中的行，或再次点击侧边栏「会话」入口。
  两者都把 `selectedConversationID` 置为 `nil`，详情区回到「选择一个会话」空状态，
  会话列表保持展开；点击其它行正常切换。`onChange` 不再在 nil 时自动选回第一条。
- 收起只影响当前打开的对话，不改变未读、置顶或会话数据；进入会话页时若没有选中会话，
  仍按原行为自动选中第一条。

## 8. 可访问性

- 所有图标按钮有 `accessibilityLabel` / `.help`。
- 行级组件使用 `.accessibilityElement(children: .combine/.contain)`，会话行提供未读/选中状态。
- 聊天气泡朗读「发送者 + 类型 + 内容 + 时间」。
- 语义字体 + 系统缩放；关键数字使用 `monospacedDigit`。
- 深浅色全部使用语义色/材质；不使用固定黑白色值（除品牌渐变与白色图标）。
- `accessibilityReduceMotion` 关闭页面切换、Toast、骨架脉冲动画。
- 静态状态点代替重复动画，保证低能耗。

## 9. 文件结构

```
app/Sources/WeChatBot/
├─ DesignSystem/
│  ├─ Theme.swift
│  ├─ Surfaces.swift
│  ├─ Controls.swift
│  └─ Feedback.swift
├─ Views/
│  ├─ RootView.swift            # 主窗口 + PageRouter
│  ├─ SidebarView.swift         # 侧边栏 + 状态胶囊
│  ├─ DashboardView.swift
│  ├─ ConversationsView.swift
│  ├─ BotView.swift
│  ├─ AIModelsView.swift
│  ├─ PersonasView.swift
│  ├─ MemoryView.swift
│  ├─ SchedulesView.swift
│  ├─ LogsView.swift
│  ├─ SettingsView.swift
│  ├─ OnboardingView.swift
│  ├─ MenuBarView.swift
│  └─ Components/               # 12 个复用组件/编辑 sheet（含 ReplyProgressBar）
└─ WeChatBotApp.swift           # Window / Settings / MenuBarExtra / Commands
```

## 10. 与 Core 的边界

UI 只读 `AppStore` 状态并调用既有方法，不直接访问数据库/网络/进程：

- 状态：`settings/providers/personas/schedules/conversations/messages/logs/hookStatus/stats`
- 运行时：`startBot/stopBot/refreshStatus/installHook(onProgress:)/restoreWeChatBackup/testProvider/
  sendManualMessage/clearMessages/deleteMessage/saveAPIKey/apiKey/deleteAPIKey/persist/reload/appendLog/clearLogs`
- 配置集合（providers/personas/schedules）由 UI 修改数组后调用 `persist()`；Core 不提供
  冲突的 CRUD，避免重复实现。

## 11. 验证与已知限制

已验证：

- `cd app && swift build --scratch-path .build-verify` 通过；`swift test` **170/170** 通过
  （含批量记忆、压缩器、权重强化、旧库迁移、防睡眠配置兼容与三档决策、回复进度倒计时、
  自消息路由修复、通讯录标题补全、拍一拍回复、appmsg 引用/链接/文件等分类与历史文本修复、
  微信 4.2.0.5 R3 版本门禁/运行期配置合并）。
- 微信 4.2.0.5 (270341) 真机 E2E（2026-10-22）：Gadget 注入 + ad-hoc 重签后微信正常启动、
  gadget 27042 监听；私聊/自消息入站、通讯录解密读取、R3 文本发送（含 bridge 重启后句柄恢复）
  通过；群聊 @ / 拍一拍沿用既有逻辑，本轮未单独复测；媒体下载维持已知缺失。
- 9 个侧边栏页面、首次向导、设置场景、菜单栏均可导航；浅色/深色截图核对通过。
- 空闲 CPU（关闭脉冲动画后）约 2–3%；修复前 MenuBarExtra `isInserted` 写回循环会导致 100%。
- 会话三栏、全部气泡类型、过滤/暂停/导出、表单校验均已人工走查。
- 回复进度倒计时：`ReplyProgress` 的倒计时剩余/比例/计时格式化有单测覆盖；会话页在不同阶段
  （AI 生成 / 拟人化等待 / 发送中 / 完成 / 失败）渲染状态条、头部徽标与会话行计时，构建通过。
- 会话收起：再次点击当前选中行或侧边栏「会话」入口会取消选中并显示空状态；
  列表保持可见，选中其它行可重新打开。
- Dock 图标开关：bundle 声明 `LSUIElement`，`showDockIcon=false` 启动时进程类型为
  `UIElement`（Dock 无图标），`true` 时启动后切换为 `Foreground`（`lsappinfo` 实测）。
  `LSUIElement` 还避免 AppKit 在菜单栏激活时把隐藏模式重置回 regular。
- 群聊 @ 误触发回归：appmsg/群收款卡片中对别人的 at 段曾触发「群聊·@」并回复；
  现仅 `at` 目标等于机器人 wxid 才触发。
- 引用消息可见性回归（2026-10-22）：hook 只认拍一拍，引用回复曾显示为 `[链接/文件]`，
  回复正文与被引用原文对 AI/规则引擎不可见。App 现已从 `raw_message` 还原
  「回复正文 + `[引用 发送者] 原文摘要`」，链接/文件/表情/聊天记录/转账/视频号带类型前缀；
  真机历史数据中受影响的 appmsg 消息可全部还原，重复修复幂等（二次修复无变更），群聊关键词可命中引用正文，
  被引用原文不参与 @ / 关键词触发（避免引用旧消息重复唤醒），拍一拍与结构化 `at` 段不受影响
  （`WeChatAppmsgTests` / `AppmsgRoutingTests` 覆盖）。
- 台前调度：逻辑不再参与激活策略计算。开启台前调度且 `showDockIcon=false` 时进程类型仍为
  `UIElement`，Dock 图标保持隐藏；App 不出现在台前调度应用条，窗口隐藏后从菜单栏图标恢复。
  设置页仅在「台前调度已开启 + 已关闭 Dock 图标」时显示说明。
- 白/黑名单合并：旧四列表迁移为两个统一列表（会话 ID / 用户 wxid）。
- 人格设置移除「回复风格」；温度改为「AI 模型 → 模型温度」按模型配置，
  未配置的模型请求中不发送 `temperature`。
- 同页重复入口清理：Bot 演练/启动、会话 AI 开关、Dashboard 启停/刷新、AI 默认通道与
  通道启用开关、设置页向导、Provider 默认通道均已收敛为单一入口（列表行仅保留状态标记）。
- 防睡眠：`GeneralSettings` 旧配置缺字段可加载；`shouldPreventSleep` 三档决策表通过单测；
  IOKit assertion / 电源监听为事件驱动实现，构建通过。
- 记忆：短期窗口外攒够 `ChatEngine.overflowBatchThreshold` 条旧消息才批量总结（阈值改由常量
  统一控制）；自动记忆始终一条、摘要 ≤600 字；旧库 `user_version=2 → 4` 迁移通过；
  记忆页文件夹结构、搜索、排序与「仅核心」筛选已编译验证。

限制 / 外部依赖：

- 系统通知服务尚未接入：设置页开关持久化，但不会弹系统通知。
- 登录项尚未接入 `SMAppService`：设置页开关持久化，但不会注册系统登录项。
- Dock 图标切换通过 `NSApplication.ActivationPolicy` 接入（`.regular` / `.accessory`），
  用户设置是唯一决定因素，切换后立即生效；关闭 Dock 图标时会保证菜单栏图标作为备用入口。
  `app/Packaging/Info.plist` 声明 `LSUIElement=true`：App 默认以菜单栏 agent 启动，
  设置开启时才在 `applicationWillFinishLaunching` 提升为 `.regular`，避免激活时被重置回 regular。
- 台前调度不再强制 `.regular`：开启台前调度时 accessory App 不会出现在台前调度应用条，
  这是隐藏 Dock 图标的已知取舍；窗口仍可通过菜单栏图标恢复。`CFPreferences` 对
  `com.apple.WindowManager.GloballyEnabled` 的探测只用于设置页提示文案。
- 「拍一拍」：4.1.15.55 真机实测为 **appmsg（type=49，`<appmsg><type>62</type><title>…拍了拍…</title>`）**。
  Hook 会把 `<title>` 提取为消息文本（聊天列表直接显示「… 拍了拍 …」），原始 XML 保留在
  `raw_message`；规则层按「拍了拍」文本、`<type>62</type>`、`sysmsg type="pat"` 多路径匹配。
  4.1.12 及更早仍兼容 localType 10000 / sysmsg 形态。4.2.0.5 沿用同一形态与解析逻辑，本轮未单独复测拍一拍。
- 本次新增的防睡眠状态、记忆文件夹与重复入口清理已通过构建/单测；记忆文件夹的滚动、
  文件夹切换、防睡眠插拔电源后的状态刷新尚未在窗口内人工走查，建议下轮 UI QA 补截图。
  防睡眠断言在真机睡眠行为上的验证（合盖不阻止、空闲时阻止）同理留待真机确认。
- Hook 安装进度依赖 Core 的 `onProgress` 回调；失败信息透传。
- 从源码直接启动（非 `.app`）时 `Bundle` 版本号为开发回退值；正式版本由打包脚本注入。
- 观察到的 Core `ProcessRunner` 启动/退出偶发异常
  （`-[NSConcreteTask terminationStatus]: task still running`）与 UI 无关，已同步 swift-core。
- 开发期截图位于 `/tmp/wechatai-*.png`、`/tmp/shot-*.png`、`/tmp/demo-*.png`，不纳入仓库。
