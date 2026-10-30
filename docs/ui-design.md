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

主窗口左侧为自定义侧边栏，分三段共 8 个页面（首次向导为独立全屏流程，不计入侧边栏）：

| 分组 | 页面 | 职责 |
| --- | --- | --- |
| 常用 | 总览 `dashboard` | 健康状态、今日统计、快捷操作、最近活动/会话 |
| 常用 | 会话 `conversations` | 会话列表 + 聊天详情 + 手动发送 |
| 自动化 | 机器人 `bot` | 7 个子栏目：常规（状态/基础开关/默认人格）、触发（群聊触发/关键词）、互动（唤醒窗口/拍一拍）、名单（白/黑名单）、节奏（频率/工作时间/拟人化）、定时（定时任务，2026-10-28 从侧边栏移入）、语音 |
| 自动化 | AI 模型 `ai` | 多通道增删改、Keychain 密钥、连接测试、默认通道与请求策略 |
| 自动化 | 人格设定 `personas` | 人格卡片网格 + 编辑 sheet |
| 系统 | 记忆库 `memory` | 记忆卡：角色列表（含全局共享）、记忆卡、全量记录/导出、记忆设置、旧记忆导入；入口仅显示列表，聚合需显式点击；人格统一由人格设定维护。聊天记录清理在具体会话内 |
| 系统 | 运行日志 `logs` | 实时流、级别/来源过滤、暂停、清空、导出 |
| 系统 | 设置 `settings` | 通用/外观/通知/Hook/OneBot/数据与备份（当前微信账号、已保存账号、重新检测）/关于 |

附加入口：

- 菜单栏图标（可在设置中关闭）：**左键开合状态面板**（含打开主窗口、快捷启停、会话 / 机器人 /
  设置直达与退出）；右键 / Control-左键不执行操作。
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
│  └─ PageRouter → 8 个页面（首次向导另计）
├─ Settings scene → SettingsView (880×640)
└─ MenuBarController：NSStatusItem + 左键 NSPopover (272pt)
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
- `DashboardSystemVitalsCard`「设备与账户」：左栏本机电池（电量百分比、电量条、充电/已接电源状态、
  剩余或充满时间，30 秒刷新）；右栏 DeepSeek 余额（总额、赠送/充值、可用状态与更新时间；
  启动查询后每 5 分钟刷新，可手动刷新）。未配置 DeepSeek 通道/Key 时给出去「AI 模型」的入口，
  请求失败显示原因与「重试」，不伪造金额；台式机无电池时显示「未检测到电池」。
- 四张 `MetricTile`：今日收到、今日回复、失败、AI 平均延迟（`contentTransition(.numericText())`）。
- `SectionCard` 快捷操作（3 列）：安装 Hook、测试 AI、设置、首次向导、日志、记忆库；
  启动/停止与刷新只保留在工具栏，避免同页重复入口；位于最近活动/最近会话双栏之上。
- 双栏 `SectionCard`：最近活动（日志）与最近会话（点击跳转会话页）。
- 运行中安装 Hook 显示 `ProgressPanel`（onProgress 回调）。
- 未连接 OneBot 时底部显示 warning `InlineNotice`。
- **微信账号已切换提示**（2026-10-27）：`store.accountSwitchNotice` 非空时，在页面顶部显示
  `InlineNotice(kind: .info, title: "微信账号已切换")`，正文说明当前账号或旧数据归入哪个账号；
  右侧「知道了」调用 `store.dismissAccountSwitchNotice()` 关闭。运行中切号会同时停止机器人，
  用户需要重新启动机器人；提示不阻塞其它操作。

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
- 详情头部：会话标题/类型/ID、**唯一的 AI 自动回复开关**、人格/置顶/标记已读/删除聊天菜单（已移除免打扰设置）、
  实时回复状态徽标 `ReplyStatusBadge`（AI 生成中 · 已等待时长 / N 秒后发送 / 发送中 / 已发送 / 失败）。
- **删除聊天**：详情头部菜单「会话 → 删除聊天…」删除本机聊天（会话列表不提供右键删除），
  二次确认说明会删除会话、聊天记录与相关记忆（不影响微信端聊天记录），确认后回到空状态。
- **清理聊天记录（在具体会话内操作）**：打开某个会话 → 详情头部「More（会话设置）」菜单 →
  「清理聊天记录…」→ `ChatCleanupSheet`；**只清理当前会话，没有“全部会话”选项**。
  只删除该会话本地 `messages`（及旧 `memory_state` 游标），**不删除**记忆卡与 `interactions`
  全量记录，也不影响微信端消息；确认框条数来自账号库 `messageCount` 的真实总数。
- 会话工作时间：菜单可选「跟随全局 / 自定义时段 / 此会话不限制」；自定义弹窗编辑星期与起止时间，
  设置随会话写入数据库。详情头部常驻实时状态徽标 `WorkingHoursBadge`：
  「工作时段 / 非工作时段 / 不限时段」，按会话覆盖优先的生效时段判定，每分钟自动刷新；
  悬停显示时段来源（全局 / 会话）与摘要（如「工作日 09:00–18:00」）。
  该状态与 `RuleEngine` 的工作时段拦截口径一致：非工作时段不自动回复，手动发送不受限制。
- 消息区：`DateSeparator`（超过 5 分钟插入）+ `MessageBubble`；底部锚定；新消息自动滚动。
- 气泡类型：文本、图片（本地 `NSImage` / 远程 `AsyncImage` / 占位）、语音（时长 + 转写）、表情、文件、视频、链接、
  系统通知；发送状态：生成中（三点）、待发送、已发送、失败。
- 入站图片（2026-10-23）：收到图片消息先显示「图片」占位气泡；该会话生效的「获取图片」
  开启时（会话详情 → 菜单 →「媒体」），App 后台串行请求 bridge（`POST /fetch_image`），
  成功后把返回的本地路径写入消息 `mediaPath`，气泡自动切换为真实图片；关闭或获取失败时
  保留占位（不弹错误，只在运行日志 debug 记录原因）。开关按会话保存，关闭后该会话不再
  发起新的获取请求；新会话/未设置时跟随旧全局默认（开启）。
- 识图（2026-10-23）：启用「AI 模型 → 识图模型」后，图片消息的识别描述以 caption 形式
  显示在图片下方（眼睛图标 + 最多 3 行，可右键「复制识图描述」）；未识别/未开启时不显示。
- appmsg 卡片（2026-10-22）：引用回复、链接、文件、表情、聊天记录、转账、视频号等统一以文本气泡
  展示；引用为「回复正文换行 `【引用 发送者：原文摘要】`」，不再出现笼统的 `[链接/文件]`
  （历史数据启动时按同一解析器重算）。拍一拍仍显示为「… 拍了拍 …」。
- 引用图片（2026-10-23）：气泡仍显示 `[图片]` 摘要；生成回复时 App 按 `refermsg.svrid`
  找回原图，在提示词末尾附加「（引用图片内容：…）」（不写数据库、不改气泡）。
- 输入区：多行 `TextField`、⌘↩ 发送、服务未连接时禁用发送并提示；AI 开关只在详情头部出现一次。
- **回复处理倒计时**（`ReplyProgressBar`，输入区上方）：收到消息并触发自动回复后实时展示流水线阶段，
  用户无需翻日志即可判断卡在哪一步：
  - `generating`：AI 请求已发出，显示「已等待 N 秒」（生成耗时不可预知，因此正向计时）与通道 · 模型；
  - `waitingToSend`：拟人化随机延迟，显示真实的「N 秒后发送」倒计时与随倒计时收缩的进度条；
  - `sending`：等待 bridge 发送回执，显示回执等待时长；4.1.15.55 / 4.2.0.5 / 4.2.0.9 R3 未拿到发送句柄时
    直接显示「R3 发送句柄未就绪（微信重启后需在本机微信手动发一条消息）」或队列条数
    （App/bridge 重启会从缓存自动恢复句柄，不再要求手动发送）；
  - `completed`：显示总用时与「已发送 N 段」，3 秒后自动收起；
  - `failed`：显示错误原因并保留，可点 × 手动收起（60 秒后也会自动清理）。
- 空状态：无会话 / 未选中会话（包括再次点击当前会话行后收起对话）/ 会话无消息。

### 5.3 机器人

- 页面拆成 7 个子栏目，工具栏下方是 **sticky 分栏条**（`PageTabBar`）：常规 / 触发 / 互动 / 名单 / 节奏 / 定时 / 语音。
  分栏条不随内容滚动；切换子栏目时内容回到顶部；子栏目选择按窗口记忆
  （`@SceneStorage("bot.subTab")`），离开再回到机器人页仍停留在上次的子栏目。
  启动/停止与「保存设置」始终在页面顶部工具栏（本页唯一启停入口）。
- 「常规」：状态卡 + 基础开关 + 默认人格。
  - 状态卡：大圆角渐变图标、运行状态、真实/演练模式、配置停用提示、OneBot/Hook 连接状态。
  - 「基础开关」：演练模式（全页唯一入口）、私聊自动回复、忽略自己、忽略公众号。
  - 「默认人格」：默认人格 Picker；系统提示词只在「人格设定」页维护，Bot 页不再提供全局提示词；
    默认 AI 通道只在「AI 模型 → 默认通道」设置一处（Bot 页不重复提供 Picker）。
- 「触发」：群聊触发方式多选 chips（@ / 关键词 / 拍一拍 / 引用机器人 可组合，「所有消息」与其它方式互斥）、
  群聊关键词 chips 编辑器（勾选「关键词」后生效）；命令前缀仅保留给历史配置。
  - 「引用机器人」（2026-10-22 新增，默认关闭）：别人引用机器人发过的消息时唤醒，正文无需 @/关键词；
    判定用 refermsg 的结构化发送者 wxid（`<chatusr>`，私聊形态回退 `<fromusr>`），不看昵称；
    chip 悬停提示「引用机器人：别人引用机器人发的消息时唤醒机器人（正文无需 @ 或关键词）」，
    被引用原文仍只作为 AI 上下文，不参与 @/关键词触发。
  - 群聊 @ 判定只认结构化 `at` 段且目标为机器人本人；@ 其他人、或文本里出现 `@`
    都不会触发（避免群收款/卡片等 appmsg 误回复）。
- 「互动」：唤醒后免唤醒词 + 拍一拍回复。
  - 「唤醒后免唤醒词」（2026-10-23 新增，默认关闭）：开关 + 1–60 分钟 Slider 与
    1/3/5/10/30/60 分钟快捷 chips（默认 5 分钟）。群聊被任一触发方式唤醒后，**同一发送者**
    在窗口内继续发言无需再次 @ / 关键词 / 引用 / 拍一拍；每条被放行的消息都会续期（滑动窗口）。
    仅群聊生效（私聊本来就不需要唤醒词）；与会话开关、白黑名单、工作时段、冷却与每分钟上限
    同时生效时，窗口只放宽触发判定，不绕过其它门槛。
  - 「拍一拍回复」（默认关闭）：开启后显示——
    - 「发送自定义文字」：AI 前文字 / AI 后文字（留空不发送，支持 `{name}` 占位符）；
    - 「附带 AI 回复」：使用普通回复的 persona/provider/model；
    - 「群聊被拍后 @ 拍的人」（默认关闭）：仅群聊生效。真实 @ 以 OneBot `at` 段交给 bridge
      （`<atuserlist>` 与群昵称由 bridge 解析），附在第一条回复前——自定义前文字 / AI 首段 /
      自定义后文字中谁先发出就 @ 谁那条，避免多条回复重复 @；
    - 发送顺序提示：自定义文字（前）→ AI 回复 → 自定义文字（后）；AI 失败时仍发送文字。
    全部内容都未发出而回退普通 AI 回复时，@ 同样只附在回退回复的第一条。
    拍一拍判定只认 `pat_target_wxid == 机器人 wxid`；群里拍别人不触发。
    回拍已移除，设置页不再出现「仅回拍」「回拍位置」等选项。bridge 解析不到群昵称时，
    该条退化为不带 @ 的普通文本发送，不阻断回复。
- 「名单」：「白名单 / 黑名单」统一为两个 `IDListEditor`，条目可以是会话 ID 或用户 wxid；
  chips 可删、可从会话选择；白名单为空表示全部允许，重叠时显示 warning（黑名单优先）。
- 「节奏」：频率与上下文 + 工作时间 + 拟人化。
  - 「频率与上下文」：冷却 Slider、每分钟回复数、短期上下文条数 Stepper；
    文案提示窗口外旧消息会进入记忆卡全量记录，由后台按批次提取生成记忆（不再批量总结）。
  - 「工作时间」：开关、星期 chips、起止时间 `DatePicker`（分钟整数绑定）；全局默认时段，
    可在「会话」页为单个会话设置独立时段或取消限制。
  - 「拟人化」：开关、随机延迟双 Slider（自动保持 min ≤ max）、分段开关/段数、输入中状态。
- 「语音」：复用共用组件 `VoiceSettingsPanel`；这是 App 内唯一的语音设置入口。
  - 转写：三个开关 + 「转写资源」行内状态/下载/刷新。
  - 回复：总开关默认收起策略项（概率、对等、短回复阈值、最长时长、超限处理、
    语音回复免拟人化延迟）。
  - 语音引擎与音色：只保留 CosyVoice3 一组行（引擎选择器已移除，CosyVoice3 是唯一 TTS 引擎）：
    - 本地服务：状态（运行中/启动中/未运行/异常/未检测）+ 启动/停止 + 重新检测；
    - 运行环境与模型：下载并安装…/取消/重新安装…/删除…（合计约 8GB），失败可重试；
    - 音色：本机音色菜单 + 「管理音色…」（无音色时「添加音色…」；App 不内置任何音色）；
      音色列表行显示参考音频条数；管理 sheet 的参考音频/文本为 1–5 条片段卡片
      （新增音色不再预置空卡片：可拖入或多选批量导入；片段可上移/下移调整合并顺序、更换、
      删除；逐条或「自动转写全部」；显示 N/5、单条时长、字符计数与合并总时长；多条文本需
      同时填写或同时留空；cross-lingual 开关保留且不锁死文本输入，手动输入/转写会自动关闭；
      内置音色只读展示全部片段），导出 zip 含 `refs/` 原始片段；
    - 语速：0.5×–2.0× 滑杆，默认 1.0×；
    - 自动启动：开关；仅在「允许语音回复」开启、该开关开启、已安装且有音色时，
      启动 App / 打开语音面板拉起本地服务，面板内仍可手动启动；
    - 服务地址：默认 `http://127.0.0.1:5051`（仅回环）。
  - 试听：共享 `VoicePreviewController`，走本地 CosyVoice3 HTTP 服务播放真实合成结果，不发往微信；
    服务未启动或未选音色时提示先安装/启动。
  - 发送状态：仅开启「允许语音回复」时显示，单行摘要 + 重新检测 + 「查看步骤…」。
- 所有修改即时写回 `store.settings`，保存按钮 + 离开页面时 `persist()`。

### 5.4 AI 模型

- 顶部：通道数量/默认通道摘要、添加通道。
- `ProviderRow`：类型图标、名称、类型/默认/停用徽标、baseURL host、模型、Keychain 状态、
  输出上限/超时/有效流式状态、测试按钮（idle/testing/success/failure，成功耗时与失败原因直接展开）、
  启用开关、编辑、删除（确认；至少保留一个）。
  有 Key 的官方通道显示「密钥已登记」，缺少 Key 的 DeepSeek/OpenAI 显示「缺少 API Key」，
  Ollama 显示「无需密钥」，自定义端点显示「密钥可选」；全局流式关闭时显示「流式已暂停」。
  行内不再重复提供「编辑/测试」菜单项。
- `ProviderEditorSheet`（600×660）：名称、类型（切换时自动填入该类型的默认地址与模型，
  不覆盖用户手改的值）、Base URL（按类型给示例）、模型；
  API Key（SecureField + 显示切换）按类型区分「需密钥 / 可选」，已有密钥时提示「留空保持不变」，
  可清除已保存密钥（二次确认）；「生成参数」默认折叠为「高级参数」摘要，
  内含回复最大长度、请求超时与通道级流式开关，全局流式关闭时明确提示该开关当前不生效。
  字段级校验（名称 / URL / 模型）显示在对应输入框下，错误提示固定在 footer 上方，不会滚出视野。
  **启用/停用只在通道列表行操作**，编辑 sheet 不重复提供开关；默认通道只在「默认通道」卡设置。
- 「默认通道」：Picker 始终选中一个具体通道，不再提供会静默回退到第一个通道的「无」选项；
  默认通道停用或缺少 API Key 时显示 warning 和可行动说明。
- 「请求策略」：流式总开关（关闭后所有通道非流式；开启时跟随各通道的流式设置）、
  失败重试（额外重试次数，0 = 不重试）。**已移除从未生效的全局请求超时**，真实超时按通道配置。
- 「模型温度」：按模型名列出通道/人格中实际使用的模型，以及已保存自定义温度的历史模型
  （避免旧模型的自定义温度不可见），每个模型可单独设置 0–2 的温度或恢复模型默认；
  未配置时请求不发送 `temperature`；有自定义温度时提供「全部恢复默认」。
- 「识图模型」（2026-10-23）：启用开关、识图通道 Picker（「跟随默认通道」+ 全部通道）、
  识图模型覆盖（留空跟随通道模型，需支持 OpenAI 兼容 `image_url` 输入）。
  行内说明识图结果仅保存在本机、会作为后续回复的上下文；关闭时通道/模型行禁用；
  无通道时提示先添加通道并填写模型名称。
- 「密钥与安全」：Keychain 策略说明、测试行为说明、Ollama 说明、删除通道同时删除其 Keychain 条目、
  配置文件路径（可复制）。
- 删除通道需确认；删除后同时删除该通道在 Keychain 中的密钥，默认通道自动回退到第一个通道。

### 5.5 人格设定

- 自适应网格（`LazyVGrid`，280–420pt）；`PersonaCard`：渐变头像、名称/默认徽标、
  简介、提示词预览、模型覆盖、编辑按钮、更多菜单（设为默认/删除）。
- `PersonaEditorSheet`：名称、简介、系统提示词 `TextEditor`、可选模型覆盖；不再设置回复风格
  或温度（温度按模型在 AI 模型页配置）；校验名称/提示词。
- 默认人格联动 `settings.bot.defaultPersonaID`；删除默认人格自动回退。
- **人格设定是唯一来源**：会话按 `personaID ?? 默认人格` 绑定，不复制人设卡；页面提示
  「人格是模板」——修改后立即对所有使用该人格的会话生效，记忆页不再提供人设卡编辑器。

### 5.6 记忆库

- 记忆库页只有**记忆卡**模式（2026-10-28 移除页内「聊天记录」分段/浏览/清理）；
  聊天记录清理在具体会话的头部菜单（见 §5.2），记忆页不再提供数据库浏览或清理入口。
- **入口不自动打开聚合**：进入记忆库（含再次点击侧边栏「记忆库」）只显示左栏角色列表；
  右栏显示「选择一个角色」空状态与「查看全部角色」按钮，**不自动加载/展示任何角色或
  聚合页**。只有点击左栏「全部角色」或该按钮才打开聚合；点击全局/会话行切换选择。
  刷新、创建卡、删除卡后保持无选择，不自动跳回聚合。
- 记忆页只展示**当前微信账号**的角色目录；换账号后角色列表与记忆卡都切到该账号，
  不同会话之间不共享记忆。账号切换见 [`accounts.md`](accounts.md)，
  记忆卡契约见 [`memory.md`](memory.md) §10。
- 记忆卡模式（2026-10-28 记忆 v2）：左栏角色列表 + 右栏记忆卡（双栏）。
  - 左栏：`全部角色`（聚合）+ **固定「全局共享 / 所有会话共享」行**（globe 图标，位于
    会话角色之上）+ 各微信会话的角色行（标题/类型/人格名/记忆数/重要数/待办数），
    支持按标题/人格名搜索；还没有任何记忆卡时整页空状态提供「为现有会话创建记忆卡」，
    建卡后后台补总结最近一批旧聊天（最多 500 条），更早历史仍可手动导入。
  - 右栏顶部：会话标题/类型、人格名（来自**人格设定**）、更新时间；全局行显示
    「全局共享」+「注入所有会话」；聚合 header 为「聚合 N 个会话角色 · 全局记忆同时并入」。
    **没有「人设卡」按钮/sheet，也没有每会话自定义提示词，也没有重复的统计行**
    （记忆/最近/重要/待办/归档）。总数只在工具栏副标题
    （`N 个记忆卡 · N 条生效记忆`，包含全局卡），各筛选数量只在筛选 chip 上。
    按钮：`全量记录`、`导出`、`更多`（预览注入 / 导入旧记忆 / 为缺失会话创建记忆卡 /
    删除记忆卡）；记忆设置入口是工具栏齿轮；聚合视图隐藏或禁用角色专属按钮。
    **全局卡禁用「全量记录」（无 interactions）与「删除记忆卡」**，但可导出与手动维护记忆。
  - 筛选：全部 / 最近 72h / 重要 / 待办 / 事实 / 决策 / 经验 / 已归档 / 已被取代；
    排序：综合权重（默认）/ 最近更新 / 重要度；搜索正文与关键词。
  - 卡片：正文、类别徽标（事实/决策/待办/经验）、置顶/重要徽标、重要度、权重、
    合并次数、召回次数、来源（自动提取/手写/旧记忆导入）与「已被取代」徽标；
    菜单：编辑、置顶/取消、归档/恢复、压缩、取消取代、删除（二次确认）。
  - 新增记忆：预填当前会话，类别默认 `fact`、来源 `manual`；普通提取记忆正文 ≤300 字，
    手动新增可到 2000 字。
  - 注入预览/召回测试（[`memory.md`](memory.md) §8.3）：输入一句模拟消息，显示按当前会话
    生成的记忆上下文与字符估算。
- **人格不在此页编辑**：姓名/摘要/系统提示词/模型统一在「人格设定」页维护，修改后所有使用
  该人格的会话下一轮回复立即生效；记忆页只读展示人格名。
- 全量记录 sheet：`interactions` 列表（时间/方向/发言人/正文），搜索、上限 1000 条；
  首次查看角色时自动补齐最多 5000 条历史互动，之后增量同步；
  主工具栏「导出」包含全部互动记录；sheet 内不提供删除（随记忆卡删除）。
- 导出：Markdown / JSON，使用 `NSSavePanel`；全局卡也可导出（用当前人格设定/默认人格），
  但不含全量记录。Markdown 含角色信息、人设（人格设定：摘要/
  系统提示词/模型）、分类记忆（重要项带标记）、已归档/已被取代与全量互动；
  JSON 含 `format`、`exportedAt`、`character`、`memories`、`interactions`；`character` 含
  `conversationID`/`title`/`kind`/`personaID`/`name`/`summary`/`model`/`systemPrompt`/
  `personaSource = "persona-settings"`，不含每会话人设卡字段/时间戳。
- 记忆设置 sheet：记忆开关、提取批量、最近窗口、普通/重要半衰期、重要阈值、合并阈值、
  归档天数、召回条数/字数等；保存到当前账号 `profile.json` 的 `bot.memory`
  （字段/默认值见 [`memory.md`](memory.md) §11）。
- 「导入旧记忆」：只读旧 `memories` 表，把本会话 + 全局旧记忆拆分/启发式分类后导入当前记忆卡
  （来源 `legacy-import`、核心记忆置顶）；不自动执行，需用户点击。
- 删除记忆卡：二次确认，整个角色目录移到废纸篓；**人格设定不受影响**，该会话下一条消息
  （或下次回复）按当前人格设定重建记忆卡并重新补总结最近历史（见
  [`memory.md`](memory.md) §7.2）。全局共享卡不可删除（按钮禁用，运行时拒绝）。
  删除会话沿用现有确认，同时把角色目录移到废纸篓。
- 工具栏副标题显示「本地 SQLite」与记忆卡/生效记忆数；账号库与角色目录的完整路径在
  「设置 → 数据与备份」，避免用户误以为所有账号共用一份记忆。
- 微信侧不提供 `/记忆` 指令；查看/编辑/置顶/压缩/导出只在 App 记忆面板进行。
- 空状态区分「还没有记忆卡」「记忆卡还是空的」「这个角色还没有记忆」「全局记忆还是空的」
  （后两者提供「新增记忆」；全局卡说明只支持手动维护、注入所有会话）、「当前筛选为空」
  「搜索无结果」；有卡但 0 条不是读取错误。
- 错误（DB/目录读写失败）用 Toast + 日志提示，不静默吞掉，面板保持可用。

### 5.7 定时任务（机器人 → 定时）

- 2026-10-28 起从侧边栏移入机器人页，作为「定时」子栏目（`SchedulesPanel`）；
  侧边栏不再单列该页面。
- 卡片头部：任务数/启用数、新建任务。
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
| 通用 | 登录启动、退出确认、**防睡眠（永不/接入电源时/始终 + 当前状态）**、语言、重新打开向导；窗口/Dock 行为只做说明（Dock 图标随主窗口显隐，无开关） |
| 外观 | 系统/浅色/深色分段选择 + 三个外观缩略预览；减少动态效果与动态字体状态；设计说明 |
| 通知 | 通知开关、声音开关、系统权限说明 |
| Hook | 微信版本/进程/Gadget/Bridge/网关/版本匹配、**CLT 状态/安装/重新检测**、**R3 发送句柄状态**、安装/还原/刷新、进度、风险提示、路径/端口/自动启动/**R3 原生发送开关（4.1.15.55 / 4.2.0.5 / 4.2.0.9，默认开；首次需本机手动发一条消息）** |
| OneBot | Host/Port/连接类型/Token（安全显示+复制）、Bridge 路径、图片目录、WS 地址 |
| 数据与备份 | **当前微信账号（mask/账号数据目录/账号配置/会话数据库/角色目录/媒体目录）**、**已保存的账号**、**重新检测微信账号**；全局配置 `config.json`、备份目录、运行日志目录（`~/Library/Logs/WeChatAI/`）；导出配置、打开目录、重新加载、日志清空 |
| 关于 | 图标、版本/Build、Bundle ID、系统版本、架构、资源路径、**运行信息**、**技术栈与许可**（每项写明本项目中的用途）、**自研能力概述**（版本适配、收发送、通讯录读取、安全边界与分析工具链；不展示地址、结构偏移或密钥细节）、上游开源项目 GitHub 链接与许可（重新打开向导只在「通用」页提供） |

「数据与备份」多微信账号区域（2026-10-27）：

- **当前微信账号**卡片（只读，值来自 `AccountProfile` / `AppStore`）：
  - 账号：`store.activeAccountID` 的 mask（`AccountProfile.maskedActiveID`）；未识别时显示
    「未识别（等待微信登录）」并显示 warning「临时档案」徽标，已识别显示「当前」徽标；
  - 账号数据目录：`accounts/<id>/`；账号配置：`accounts/<id>/profile.json`；
    会话数据库：`accounts/<id>/chatbot.sqlite`（旧记忆表只读）；角色目录（记忆 v2）：
    `accounts/<id>/characters/`；媒体目录：`accounts/<id>/media/`；
  - 全局配置：`config.json`；备份目录：`backups/`；运行日志目录：
    `~/Library/Logs/WeChatAI/`（崩溃与 bridge 日志同级）；
  - 每个路径提供复制与「在 Finder 中显示」，路径用 `.monospaced`；
  - 卡片下方用 `InlineNotice(kind: .info, title: "数据隔离")` 说明账号级与全局数据的边界。
- **已保存的账号**列表：
  - 数据来自 `store.savedWeChatAccounts`（`AccountProfile.savedAccounts(limit:)`，按最近使用倒序；
    不含 `_unassigned`）；
  - 行显示 mask、最近使用时间、当前账号徽标与「在 Finder 中显示」；
  - 不提供点击切号——切号只跟随微信登录；help 说明「换微信账号后会自动切到对应数据」；
  - 无账号档案时显示空状态；只有当前账号时追加「登录其他微信后点『重新检测微信账号』即可建立
    独立档案」的说明，不伪造历史账号。
- **「重新检测微信账号」按钮**：
  - 调用 `await store.refreshWeChatAccount()`；`store.isSwitchingAccount` 为 true 时显示
    ProgressView 并禁用；总览/菜单栏的启动按钮在切号期间同样禁用；
  - 完成切换 → toast「已切换到当前微信账号的数据」；
  - 仍未识别到账号 → error toast「仍未识别到微信账号，请先登录微信后重试」；
  - 检测到但切换未生效 → error toast（展示 `store.lastAccountSwitchError` 的失败原因，并回退到原账号）；
  - 机器人启动中检测到变化 → info toast「机器人正在启动，完成后会自动切换账号数据」；
  - 没有变化 → info toast「未检测到账号变化」；
  - 不提供「手动选择数据库/账号档案」入口：UI 不直接调用 `AccountProfile` 的切换接口。
- 说明文案（与 [`accounts.md`](accounts.md) §1–§2 一致）：聊天、记忆卡（角色目录）、会话设置、机器人配置、
  人格、定时任务与新媒体随微信账号切换；AI 通道/Keychain、Hook、OneBot、CosyVoice3 安装与音色、
  日志文件全局共享；
  旧版媒体保留在原目录。删除当前账号的聊天不会影响其它账号，也不能在 App 内删除账号档案。

「Hook 安装前置」交互（设置页与首启向导共用同一张环境检查卡）：

- 卡片顶部显示 Xcode Command Line Tools 状态：已安装 / 未安装 / 检测中 / 检测失败，
  附版本或路径摘要；完整 Xcode 同样视为就绪。
- 未就绪时提供「安装 Command Line Tools」按钮（执行 `xcode-select --install`，由系统弹出安装面板）
  与「重新检测」按钮；安装完成后自动轮询并刷新状态，无需重启 App。
- CLT 未就绪时禁用「安装 Hook」按钮，并用 `InlineNotice` 说明原因；
  微信版本不匹配、路径不存在或 `/Applications/WeChat.app` 不可写时同样禁用并给出原因，
  避免安装到一半失败。

「节能与睡眠」交互：

- 三档 segmented Picker：永不 / 接入电源时 / 始终；附当前档说明。
- 「当前状态」PillLabel：已关闭 / 已生效（阻止空闲睡眠）/ 未生效（使用电池）；
  IOKit 失败时在区块下方显示 warning `InlineNotice`，不阻塞其它设置。
- 修改后立即 `SleepPreventionCenter.apply(mode:)` 并持久化；footer 说明仅阻止系统空闲睡眠，
  不阻止合盖/手动睡眠，也不保持显示器常亮。
- 同页同一设置只保留一个入口（例如启动开关只在工具栏、UI 开关只在对应列表行/详情头）。

「获取图片」交互（会话级）：

- 会话详情头部 `Menu` 新增「媒体」Section：一项可勾选的「获取图片（已开启 / 已关闭）」，
  点击即切换并写库（`Conversation.imageFetchEnabled`），同时 toast 提示。
- 生效值 = 会话覆盖 → 旧全局 `bot.imageFetchEnabled`（默认开启）；新会话/未设置时跟随默认。
- 关闭后该会话不再发起新的获取请求；已获取过的图片仍显示。全局设置页不再暴露该开关。
- 识图（视觉模型）在「AI 模型 → 识图模型」单独配置；会话级开关只控制是否获取图片，
  未获取或获取失败时没有图片可识别，气泡继续显示占位。

「语音」交互（语音设置统一在「机器人 → 语音」，设置页不再提供「语音」分类）：

- 语音转写与语音回复只在「机器人 → 语音」提供全局开关，会话详情菜单不再提供会话级覆盖；
  关闭转写后不再入队新的语音下载/转写，已有转写仍显示；关闭语音回复后只发文字。
- 首次开启「允许语音回复」时自动检测文本/语音发送句柄，未就绪则弹出捕获引导；
  bridge 启动后若已开启语音回复且句柄缺失，也会自动提示一次。弹窗展示当前状态与原因
  （bridge 未连接、R3 原生发送未开启、微信版本不支持、登录预热中）。
- 概率、对等、仅短回复、音色与语速均由全局语音设置控制；已确定改发语音时默认
  跳过拟人化随机延迟（可在语音设置关闭），语音回复的进度条不再出现「N 秒后发送」倒计时。

### 5.10 首次启动向导

4 步 sheet（720×620），顶部步骤指示器 + 跳过；右上角「语言 / Language」选择
跟随系统 / 简体中文 / English，切换即时生效（与设置 → 通用 → 界面语言同步）。

1. **欢迎**：品牌图标、隐私/本地优先/多模型说明、微信版本与风险提示。
2. **微信 Hook**：顶部环境检查卡显示 CLT 状态（已安装 / 未安装 / 检测中 / 检测失败），
   未安装时提供「安装 Command Line Tools」按钮（`xcode-select --install`）与「重新检测」，
   CLT 未就绪时禁用 Hook 安装；其下为微信路径/版本/进程/Gadget 状态、检测微信、备份并安装
   （`ConfirmSheet` 二次确认 + 备份/重签/风险说明）、`installHook(onProgress:)` 进度、失败错误、跳过说明。
3. **AI 模型**：默认通道 Picker、Base URL/模型摘要、API Key（Keychain）、保存并测试连接、
   无通道时可创建默认 DeepSeek、测试结果内联展示。
4. **启动**：微信/Hook/AI 检查清单、启动后立即运行开关、完成并启动。

底部：上一步（禁用态）、步骤 n/4、下一步/完成并开始；安装中禁止交互与关闭 sheet。

### 5.11 菜单栏

自绘 `NSStatusItem` + SwiftUI `NSPopover`（272pt，`Core/MenuBarController.swift`）：

- **左键单击图标（按下即响应）：开合状态面板**（不再打开主窗口，也不再提供右键菜单）；
  **右键 / Control-左键不执行操作**。左键由常驻 local 鼠标监视器在事件分发前拦截并吞掉事件，
  避免与 `.transient` 的系统自动收起重复处理；右键事件同样被吞掉且不触发任何动作。
  面板内导航或「打开主窗口」后自动收起。
- 收起由系统与本 App 分工：面板使用 `.transient`，点击面板外（其它 App、桌面、其它状态栏
  图标）由系统自动收起，不依赖需要辅助功能权限的全局事件监视器；本 App 其它窗口上的点击
  由 local 点击监视器立即收起。Esc、应用失活（Cmd-Tab）、应用隐藏与系统菜单开始跟踪也会收起。
  **不再使用 `clickCount`、双击时间窗或同次点击抑制启发式**；
  点击意图由纯映射 `MenuBarClickIntent` 决定：左键 → 开合，右键 / Control-左键 → 忽略，
  其它修饰键不改变左键语义，未知/合成事件按左键兜底（VoiceOver 场景）。
- 主窗口的其它打开路径（Finder/LaunchServices 重开、⌘1…⌘0、面板内入口）走 `MainWindowRegistry.show()`，
  会先调用 `MenuBarController.shared.dismissPanel()` 收起面板，避免主窗口与弹层同时出现。
- 面板内容：头部品牌与运行状态胶囊；带描边的状态卡（微信、Hook、AI、电量、DeepSeek 余额、
  今日收到/回复/延迟）；快捷操作按「启动/停止 → 打开主窗口 → 会话 / 机器人 / 设置」分层；
  底部版本与退出（⌥⌘Q）。启停不收起面板，导航/打开主窗口后收起。
- 图标：模板 SF Symbol 随机器人运行状态切换填充/轮廓
  （`bubble.left.and.bubble.right.fill` / `bubble.left.and.bubble.right`），不叠加颜色或状态点，
  也不为图标跑动画；状态栏图标不显示鼠标悬停 tooltip，仅保留无障碍值（`机器人运行中` /
  `机器人已停止`）与 VoiceOver 帮助，在启停与界面语言切换时刷新。
- 性能：`NSPopover` + `NSHostingController` 首次构建后缓存复用；状态栏图标出现后延迟（约 1s）
  预热，预热阶段用 `sizeThatFits(in:)` 量出面板高度并固定 `contentSize`
  （`sizingOptions = []`；离屏 `fittingSize` 恒为 0，不用它），
  余额/统计/电量等数据刷新不再触发 popover 自动重排；语言切换时
  释放缓存。内容层不叠加 `regularMaterial`（popover 自带材质），悬停只对 `opacity` 做
  ≤0.15s 过渡，「减少动态效果」开启时不做动画。
- 菜单栏图标是 App 唯一常驻入口，**始终存在**（`showInMenuBar` 设置已移除）：不再使用
  `MenuBarExtra` 场景，因此也没有 `isInserted` 写回循环。
- 主窗口关闭按钮与 ⌘W 改为隐藏窗口（`orderOut`），随后 `ActivationPolicyController`
  把进程退回 `.accessory`：Dock 图标消失、仅保留菜单栏图标，App 隐藏并把焦点交还前台 App。
  可从菜单栏左键（面板内「打开主窗口」）、Finder/LaunchServices 重开或 `applicationShouldHandleReopen`
  重新显示；显示前先切到 `.regular`，窗口才能被台前调度识别。退出不再绑定 ⌘Q，仅保留 ⌥⌘Q
  与菜单/面板的退出入口。
- 辅助功能：状态栏条目保留 `WeChat AI` 无障碍标签/值与 VoiceOver 帮助（不显示鼠标悬停
  tooltip）；面板内状态行合并 label/value，按钮带 accessibility 标签与 help。

### 5.12 设置场景

`Settings { SettingsView() }`，系统自动绑定 ⌘,；复用同一套设置页面与分类侧边栏。

## 6. 组件清单

### DesignSystem

| 文件 | 组件 |
| --- | --- |
| `Theme.swift` | 颜色/字体/尺寸 token、`PageBackground`、`UIFormat`、`Theme.hookColor` 等 |
| `Surfaces.swift` | `GlassCard`、`SectionCard`、`GlassToolbar`、`ScrollingPage`、`IconTile`、`AvatarView`、`StatusDot`、`PillLabel`、`SectionHeader`、`MetricTile` |
| `Controls.swift` | `FlowLayout`、`FilterChip`、`TagChip`、`IconActionButton`、`CopyButton`、`FormField`、`KeyValueRow`、`PathRow`、`InlineNotice`/`NoticeKind`、`SearchField`、`SettingsSection`/`SettingsRow`/`SettingsDivider`、`UnavailableLabel`、`PageTabBar`/`PageTabItem` |
| `Feedback.swift` | `EmptyState`、`LoadingState`、`SkeletonBlock`、`ProgressPanel`、`ConfirmSheet`、`ToastCenter`/`ToastView`/`ToastOverlay` |

### Views/Components

| 组件 | 用途 |
| --- | --- |
| `StatusCard` / `QuickActionButton` | 总览健康状态、快捷动作 |
| `DashboardSystemVitalsCard` | 总览「设备与账户」：本机电量 + DeepSeek 余额（独立刷新状态，避免电量轮询重绘整页） |
| `SessionRow` | 会话列表行（AI 关闭时显示状态标记，开关在详情头部；回复处理中显示阶段计时） |
| `WorkingHoursBadge` | 会话详情头部实时工作时间状态（工作时段 / 非工作时段 / 不限时段，悬停看来源与摘要） |
| `ReplyProgressBar` / `ReplyStatusBadge` / `ReplyMiniStatus` | 回复流水线状态条、详情头部徽标、会话行计时（AI 生成 / 拟人化发送倒计时 / 发送回执 / 失败） |
| `MessageBubble` / `SystemNoticeRow` / `TypingIndicator` / `DateSeparator` | 聊天消息 |
| `ChatCleanupSheet` | 具体会话内的聊天记录清理：只删该会话本地 `messages`，不动记忆卡与全量记录 |
| `ProviderRow` / `ProviderTestState` | AI 通道行与测试状态 |
| `ProviderEditorSheet` | AI 通道编辑 |
| `PersonaCard` | 人格卡片 |
| `ScheduleRow` / `ScheduleMath` | 定时任务行与下次时间估算 |
| 记忆 v2：角色列表 / 记忆卡行 / 全量记录 sheet / 记忆设置 sheet | 记忆卡模式（左栏角色、右栏记忆卡；人格来自人格设定，无每会话人设卡；导入旧记忆与 Markdown/JSON 导出） |
| `LogRow` | 日志行 |
| `GlassToolbar` / `Toast` / `EmptyState` / `ConfirmSheet` | 见 DesignSystem |

## 7. 交互约定

### 键盘快捷键

| 快捷键 | 行为 |
| --- | --- |
| ⌘1 … ⌘7 | 总览、会话、机器人、AI 模型、人格设定、记忆库、运行日志 |
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
- 破坏性操作（删除通道/人格/任务/记忆卡、清理聊天记录、清空日志、安装/还原 Hook）均二次确认。
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
- 机器人页分栏条（`PageTabBar`）按 `isSelected` 暴露选中状态，分栏按钮带 `accessibilityLabel` 与 `.help` 说明。
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
│  ├─ SchedulesPanel.swift    # 机器人 → 定时（2026-10-28 移入）
│  ├─ LogsView.swift
│  ├─ SettingsView.swift
│  ├─ OnboardingView.swift
│  ├─ MenuBarView.swift
│  └─ Components/               # 13 个复用组件/编辑 sheet（含 ReplyProgressBar、DashboardSystemVitalsCard）
├─ Core/
│  ├─ AppStore.swift / AppStore+Runtime.swift
│  ├─ AppLifecycle.swift        # 主窗口注册表、关闭即隐藏、AppDelegate
│  └─ MenuBarController.swift   # NSStatusItem：左键开合状态面板（右键不执行操作）
└─ WeChatBotApp.swift           # Window / Settings / Commands / MenuBarController 装配
```

## 10. 与 Core 的边界

UI 只读 `AppStore` 状态并调用既有方法，不直接访问数据库/网络/进程：

- 状态：`settings/providers/personas/schedules/conversations/messages/logs/hookStatus/stats/batteryStatus/deepSeekBalance/isBalanceRefreshing/activeAccountID/activeAccountIsUnassigned/accountSwitchNotice/savedWeChatAccounts/isSwitchingAccount`
- 运行时：`startBot/stopBot/refreshStatus/refreshSystemVitals/installHook(onProgress:)/restoreWeChatBackup/testProvider/
  sendManualMessage/clearMessages/deleteMessage/saveAPIKey/apiKey/deleteAPIKey/persist/reload/appendLog/clearLogs/
  refreshWeChatAccount/dismissAccountSwitchNotice`
- 账号：设置页只调用 `store.refreshWeChatAccount()` 与 `store.dismissAccountSwitchNotice()`，
  不直接调用 `AccountProfile.activate` / `MemoryStore.switchDatabase`，也不提供手动切库入口；
  账号路径只读展示。契约见 [`accounts.md`](accounts.md)。
- 记忆卡页：只通过 AppStore 暴露的记忆 v2 方法读取/编辑/置顶/压缩/导出（内部走
  `CharacterStore` / `MemoryEngine`），不直接打开 `memory.sqlite`；记忆设置保存到当前账号
  `profile.json` 的 `bot.memory`。人格只通过「人格设定」页维护，记忆页不读写人设副本。
  契约见 [`memory.md`](memory.md) §3、§10–§11。
- 配置集合（providers/personas/schedules）由 UI 修改数组后调用 `persist()`；Core 不提供
  冲突的 CRUD，避免重复实现。

## 11. 验证与已知限制

已验证：

- `cd app && SWIFT_DISABLE_SANDBOX=1 swift test` **525 项执行（523 通过 / 2 项按环境跳过：真实 CosyVoice3 服务 E2E）
  （含批量记忆、压缩器、权重强化、旧库迁移、防睡眠配置兼容与三档决策、回复进度倒计时、
  自消息路由修复、通讯录标题补全、拍一拍回复、唤醒后免唤醒词窗口、appmsg 引用/链接/文件等分类与历史文本修复、
  入站帧单次解析与历史修复 trusted 语义、微信 4.2.0.5 R3 版本门禁/运行期配置合并、识图设置/多模态请求/图片编码与描述落库/引用图片说明）。
- 微信 4.2.0.5 (270341) 真机 E2E（2026-10-22）：Gadget 注入 + ad-hoc 重签后微信正常启动、
  gadget 27042 监听；私聊/自消息入站、通讯录解密读取、R3 文本发送（含 bridge 重启后句柄恢复）
  通过；群聊 @ / 拍一拍沿用既有逻辑，本轮未单独复测；图片获取链路已实现（CDN 触发下载待复测）。
- 8 个侧边栏页面、首次向导、设置场景、菜单栏均可导航；浅色/深色截图核对通过。
- 菜单栏点击语义：左键开合状态面板，右键 / Control-左键不执行操作（不弹右键菜单）；
  面板内导航/打开主窗口后收起，菜单栏条目始终常驻（不再提供显示开关）。
  2026-10-27 在 macOS 26.7.1 本机安装版（`~/Applications/WeChat AI.app`）走查：左键开合、
  右键确认不再弹菜单、Esc、点本 App 其它窗口、点其它 App 均能收起；面板内「设置」快捷条
  可导航并收起；272pt 面板的位置/尺寸/浅色外观正常。`MenuBarClickTests` 覆盖左键、右键/
  Control 忽略、其它修饰键、未知事件兜底与图标状态映射；**首开耗时尚未用 Instruments 量化**。
- 空闲 CPU（关闭脉冲动画后）约 2–3%；旧版 MenuBarExtra `isInserted` 写回循环曾导致 100%，
  改为 `NSStatusItem` 后不再存在该循环。
- 会话三栏、全部气泡类型、过滤/暂停/导出、表单校验均已人工走查。
- 回复进度倒计时：`ReplyProgress` 的倒计时剩余/比例/计时格式化有单测覆盖；会话页在不同阶段
  （AI 生成 / 拟人化等待 / 发送中 / 完成 / 失败）渲染状态条、头部徽标与会话行计时，构建通过。
- 会话收起：再次点击当前选中行或侧边栏「会话」入口会取消选中并显示空状态；
  列表保持可见，选中其它行可重新打开。
- 窗口与 Dock 图标：bundle 声明 `LSUIElement=true`，以菜单栏 agent 启动。启动时显示主窗口，
  `applicationWillFinishLaunching` 先把进程提升为 `.regular`，因此启动窗口也有 Dock 图标并
  可被台前调度识别；关闭主窗口（关闭按钮 / ⌘W / 面板外路径）后 `orderOut` 并把进程退回
  `.accessory`，Dock 图标消失、App 隐藏，仅保留菜单栏图标；从菜单栏面板重新打开时再切回
  `.regular`。旧配置里的 `showDockIcon` 键会被忽略，新配置不再写入。设置页只保留行为说明。
- 台前调度：只在主窗口打开期间（`.regular`）把 App 纳入台前调度应用条；关闭窗口后退回
  `.accessory`，App 从应用条移除，符合“仅菜单栏常驻”的取舍。`CFPreferences` 对
  `com.apple.WindowManager.GloballyEnabled` 的探测与设置页提示文案已随 Dock 开关一起移除。
- 群聊 @ 误触发回归：appmsg/群收款卡片中对别人的 at 段曾触发「群聊·@」并回复；
  现仅 `at` 目标等于机器人 wxid 才触发。
- 引用消息可见性回归（2026-10-22）：hook 只认拍一拍，引用回复曾显示为 `[链接/文件]`，
  回复正文与被引用原文对 AI/规则引擎不可见。App 现已从 `raw_message` 还原
  「回复正文 + `【引用 发送者：原文摘要】`」，链接/文件/表情/聊天记录/转账/视频号带类型前缀；
  真机历史数据中受影响的 appmsg 消息可全部还原，重复修复幂等（二次修复无变更），群聊关键词可命中引用正文，
  被引用原文不参与 @ / 关键词触发（避免引用旧消息重复唤醒），拍一拍与结构化 `at` 段不受影响
  （`WeChatAppmsgTests` / `AppmsgRoutingTests` 覆盖）。
- 白/黑名单合并：旧四列表迁移为两个统一列表（会话 ID / 用户 wxid）。
- 人格设置移除「回复风格」；温度改为「AI 模型 → 模型温度」按模型配置，
  未配置的模型请求中不发送 `temperature`。
- 同页重复入口清理：Bot 演练/启动、会话 AI 开关、Dashboard 启停/刷新、AI 默认通道与
  通道启用开关、设置页向导、Provider 默认通道均已收敛为单一入口（列表行仅保留状态标记）。
- 防睡眠：`GeneralSettings` 旧配置缺字段可加载；`shouldPreventSleep` 三档决策表通过单测；
  IOKit assertion / 电源监听为事件驱动实现，构建通过。
- 记忆 v2：每会话角色目录只有记忆卡、四类记忆、最近/重要/相关召回、0.92 折叠与
  supersede、批量提取/本地兜底、全量互动与 Markdown/JSON 导出按 §5.6 设计；人格统一来自
  人格设定，记忆页已移除人设卡 sheet/按钮；旧 `MemoryStore` 记忆方法与旧单测保留只读兼容，
  运行时不再展示旧长期记忆页（旧记忆需手动导入）。
- 记忆页清理/统计收敛（2026-10-28）：聊天记录浏览/清理移出记忆页，改由具体会话头部菜单 +
  `ChatCleanupSheet`（只删该会话本地 `messages`，不动记忆卡/全量记录）；记忆页头部统计行删除，
  计数只来自工具栏副标题与筛选 chip；`CharacterSummary` 只保留记忆/重要/待办计数。
- 全局共享记忆（2026-10-28）：左栏固定「全局共享」行，全局记忆注入所有会话；聚合视图并入
  全局记忆，工具栏总数包含全局卡；全局卡禁用全量记录/删除记忆卡。
- 记忆库入口（2026-10-28）：进入/再次点击侧边栏只显示角色列表 + 「选择一个角色」占位，
  不自动打开聚合；「全部角色」/「查看全部角色」显式打开；刷新/建卡/删卡保持无选择。

限制 / 外部依赖：

- 系统通知服务尚未接入：设置页开关持久化，但不会弹系统通知。
- 登录项尚未接入 `SMAppService`：设置页开关持久化，但不会注册系统登录项。
- 窗口/Dock 行为通过 `NSApplication.ActivationPolicy` 实现（`.regular` ⇄ `.accessory`），
  窗口可见性是唯一决定因素：主窗口打开（含启动窗口）时 `.regular`，关闭后退回 `.accessory`
  并隐藏 App；菜单栏图标始终存在，不再有用户开关。
  `app/Packaging/Info.plist` 声明 `LSUIElement=true`，避免 AppKit 在菜单栏激活时把隐藏模式
  永久重置回 regular；`applicationDidBecomeActive` / 空间切换后按窗口状态重新确认策略。
- 台前调度只在窗口打开期间可用：accessory 状态的 App 不会出现在台前调度应用条，这是
  “关闭窗口后仅保留菜单栏”的已知取舍；窗口可从菜单栏图标恢复。2026-10-29 已用隔离副本
  （独立 bundle id + 临时 `CFFIXED_USER_HOME`）配合 `lsappinfo` 走查启动 / 关闭 / 从
  Finder 重开时的 `.regular ⇄ .accessory` 切换、窗口显隐与台前调度缩略图；安装版
  （`~/Applications`）上的最终交付走查（Dock 图标视觉、关闭后焦点归还）待补。
- 「拍一拍」：4.1.15.55 真机实测为 **appmsg（type=49，`<appmsg><type>62</type><title>…拍了拍…</title>`）**。
  Hook 会把 `<title>` 提取为消息文本（聊天列表直接显示「… 拍了拍 …」），原始 XML 保留在
  `raw_message`；规则层按「拍了拍」文本、`<type>62</type>`、`sysmsg type="pat"` 多路径匹配。
  4.1.12 及更早仍兼容 localType 10000 / sysmsg 形态。4.2.0.5 沿用同一形态与解析逻辑，本轮未单独复测拍一拍。
- 本次新增的防睡眠状态与重复入口清理已通过构建/单测；防睡眠插拔电源后的状态刷新尚未在
  窗口内人工走查，建议下轮 UI QA 补截图。防睡眠断言在真机睡眠行为上的验证（合盖不阻止、
  空闲时阻止）同理留待真机确认。
- 记忆卡页（角色列表/筛选/全量记录/导出/旧记忆导入）随 2026-10-28 记忆 v2 实现；
  真实窗口走查、导出文件核对与各空状态/错误 Toast 待合并后补验，不把界面截图写入仓库。
- Hook 安装进度依赖 Core 的 `onProgress` 回调；失败信息透传。
- 从源码直接启动（非 `.app`）时 `Bundle` 版本号为开发回退值；正式版本由打包脚本注入。
- 观察到的 Core `ProcessRunner` 启动/退出偶发异常
  （`-[NSConcreteTask terminationStatus]: task still running`）与 UI 无关，已同步 swift-core。
- 多账号 UI（设置 → 数据与备份的「当前微信账号 / 已保存的账号 / 重新检测」，总览切号提示）
  随 2026-10-27 功能新增；窗口内真实切号走查、成功/未变化/失败三种 toast 与英文文案
  待集成后补验，不把界面截图写入仓库。
- 开发期截图位于 `/tmp/wechatai-*.png`、`/tmp/shot-*.png`、`/tmp/demo-*.png`，不纳入仓库。

> 语音设置统一在「机器人 → 语音」提供，复用共用组件 `VoiceSettingsPanel`；设置页已不再提供「语音」分类。
> 会话页只保留全局语音设置，不提供会话级覆盖。
> 首次开启语音回复或运行时启动检测到句柄缺失时会自动弹出捕获引导。CosyVoice3 的安装/启动、
> 音色选择与试听见 [`voice.md`](voice.md) §4.1。
