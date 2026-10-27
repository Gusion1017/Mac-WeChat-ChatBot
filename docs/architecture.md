# 微信 AI 助手（WeChat AI）— 架构与接口契约

> 目标：macOS 原生（SwiftUI）微信 AI 助手。通过 Frida Gadget 注入官方微信（唯一实例），
> 复用开源 Hook 的收发能力，以本地 OneBot 桥接把消息交给原生 App；AI 回复走 OpenAI 兼容接口。
>
> 本文件是并行开发的**唯一接口契约**。改动接口请先改这里，再改代码。

## 1. 进程与数据流

```
┌───────────────────────────── macOS ─────────────────────────────┐
│                                                                  │
│  WeChatAI.app (SwiftUI, 原生)                                    │
│   ├─ UI / 触发判定 / 人格 / 记忆 / 定时任务 / 日志                 │
│   ├─ AccountProfile（多微信账号档案：布局/状态/迁移）              │
│   ├─ OneBotClient (WS + HTTP, 127.0.0.1:58080)                   │
│   ├─ AIService (URLSession, OpenAI 兼容, 流式)                    │
│   ├─ MemoryStore (SQLite, accounts/<当前账号>/chatbot.sqlite)      │
│   └─ HookManager (检测/备份/安装/启动/停止)                        │
│                    │ spawn/HTTP/WS                               │
│                    ▼                                             │
│  bridge/onebot (Go, 轻量；GPL-3.0 衍生)                           │
│   ├─ 连接 Gadget 127.0.0.1:27042，加载 hook/script.js            │
│   ├─ 暴露 WS /ws + HTTP /send_private_msg /send_group_msg        │
│   └─ 媒体上传/下载、事件 JSON 组装                                 │
│                    │ Frida Gadget TCP                            │
│                    ▼                                             │
│  WeChat.app（官方、唯一实例；已注入 FridaGadget.dylib 并 ad-hoc 重签）│
│   └─ hook/script.js 按版本 JSON 偏移 Hook 底层收发函数             │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

低开销原则：
- 原生 SwiftUI，无 WebView/Electron；空闲时仅 App 主进程 + 可选 bridge。
- bridge 仅在机器人开启时运行；AI 请求按需发起，不轮询。
- 消息写入 SQLite（WAL）；UI 列表分页加载，内存中最多保留当前会话。
- 日志环形缓冲（App 内 2000 条），DB 保留最近 5000 条；按天文件切割尚未实现，避免无界增长。
- 防睡眠默认关闭；仅在用户选择「接入电源时 / 始终」后持有 IOKit 空闲睡眠断言，
  不轮询、不阻止合盖睡眠。
- bridge 事件推送立即写出，不受 `-send_interval` 延迟；该参数只节流真正发往微信的消息。
  事件级日志默认在 Debug 级，只输出字节长度 + 截断预览（默认 Info 级零额外分配）。
- hook 的 R3 闭包捕获按需调度：未拿到发送句柄时按 10ms→50ms→250ms 退避扫描，拿到后
  停止周期任务；入站去重表为 4096 条固定窗口（历史回放 / 长时间运行不增长内存）。
- 启动历史修复信任 bridge `get_login_info` 的权威 selfID（`onebot.self_id_source=login`），
  跳过历史事件反推；两个全表 appmsg / 引用文本迁移由 `data.repairs_version` 门禁只执行一次。

## 2. 目录与写入边界

| 目录 | 说明 |
| --- | --- |
| `app/Sources/WeChatBot/Models/` | 共享数据模型 / 设置 |
| `app/Sources/WeChatBot/Core/` | AppStore、运行时编排、生命周期与菜单栏控制器 |
| `app/Sources/WeChatBot/Services/` | OneBot / AI / 记忆 / 账号档案 / 触发判定 / 调度 / Hook 服务 |
| `app/Sources/WeChatBot/DesignSystem/` | 主题、组件、玻璃效果 |
| `app/Sources/WeChatBot/Views/` | 所有页面与弹窗 |
| `app/Sources/WeChatBot/WeChatBotApp.swift` | App 场景（窗口 / 设置 / 命令）与菜单栏控制器装配 |
| `app/Tests/WeChatAITests/` | 核心服务单元测试 |
| `bridge/` | OneBot Go 源码与脚本（`proto/` 为微信协议定义） |
| `hook/` | script.js、版本 JSON 与 Gadget 配置 |
| `tools/` | Mach-O 注入、微信备份 / 安装 / 还原 |
| `scripts/` | 构建、打包、安装、运行、清理脚本 |
| `devtools/` | 本地 Mock AI / OneBot（不参与打包） |
| `assets/` | App 图标源文件与 `.icns` |
| `docs/` | 架构、契约与操作手册 |
| `_research/` | 真机证据 / 日志（git 忽略，仅本地保留） |

### 2.1 运行期数据目录（多微信账号，2026-10-27）

App 的聊天数据、机器人配置与新媒体按**当前登录的微信账号**隔离；AI/Hook/OneBot/Keychain/
语音模型/日志文件仍全局共享。完整行为、隔离矩阵与排障见 [`accounts.md`](accounts.md)。

```
~/Library/Application Support/WeChatAI/
├── config.json                     # 全局设置（完整 AppSettings 镜像，兼容旧版回滚）
├── account-state.json              # {"schemaVersion":1,"lastAccountID":"wxid_xxx","updatedAt":…}
├── accounts/
│   ├── _unassigned/                # 尚未识别微信账号时的临时档案（保留名）
│   │   ├── chatbot.sqlite
│   │   ├── profile.json
│   │   └── media/
│   └── <wxid>/
│       ├── chatbot.sqlite (+ -wal / -shm)
│       ├── profile.json            # {"schemaVersion":1,"bot":{…},"personas":[…],"schedules":[…]}
│       ├── media/                  # 该账号新产生的图片/语音/TTS 输出
│       ├── logs/                   # 预留（当前为空）
│       └── legacy-migration.json   # 仅旧版迁移目标有
├── media/                          # 旧版遗留媒体（只读保留，不迁移、不删除）
├── backups/ runtime/ cosyvoice/ voice-clones/ models/
└── chatbot.sqlite                  # 旧版单库（迁移后保留，不删）
```

- 账号目录名就是 wxid，校验 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`；`_unassigned` 为保留名。
- `config.json` 仍是全局设置入口；运行期的 `bot` / `personas` / `schedules` 以
  `accounts/<当前账号>/profile.json` 为准，`config.json` 中保留一份完整镜像以便旧版回滚。
- 旧版 `chatbot.sqlite` / `media/` / `config.json` 只 copy、不删除；旧媒体里的绝对路径继续有效。
- 启动/切号顺序、迁移与 `_unassigned` 认领见 [`accounts.md`](accounts.md) §5–§7。

## 3. OneBot 桥接契约（已按上游 v0.0.18 源码核对）

### 3.1 启动参数

```bash
bridge/onebot \
  -type=gadget \
  -gadget_addr=127.0.0.1:27042 \
  -wechat_conf=/path/to/hook/versions/4_2_0_5_mac.json \
  -receive_host=127.0.0.1:58080 \
  -token=<随机 32 字节十六进制> \
  -conn_type=websocket \
  -self_id=<当前登录 wxid> \
  -log_file=$HOME/Library/Logs/WeChatAI/bridge/macos.log \
  -image_path=/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/<当前账号>_<suffix>/temp/<...>/Img/ \
  -media_dir="/Users/<user>/Library/Application Support/WeChatAI/accounts/<当前账号>/media"
```

- `onebot` 从**当前工作目录**读取 `script.js`，因此 App 启动进程时 `currentDirectoryURL` 必须指向 bridge 资源目录。
- `-log_file` **必须**指向 app bundle 之外。旧实现固定写 `./log/macos.log`，而 cwd 在 bundle 内，
  运行期会往 bundle 里追加文件、破坏 ad-hoc 签名，导致下次启动被系统以
  `Launch Constraint Violation` 杀掉。App 现在传 `~/Library/Logs/WeChatAI/bridge/macos.log`。
- `-self_id` 是当前登录账号的权威来源（App 已知时传入）；缺失时 bridge 才从 `image_path`
  的 `xwechat_files/<wxid>_xxxx/` 推导。已识别账号时 App 传当前档案的 `AccountProfile.activeID`
  （不信任旧库可能被污染的 selfID）；未识别时沿用运行时 selfID（可能为空）。
  bridge `get_login_info` 返回后用于运行期确认：与档案一致则记录权威 selfID，
  不一致则切到回包账号的数据档案（见 [`accounts.md`](accounts.md) §4.3）。
  多账号目录下 App 取当前账号，不再取「最近有活动」的账号。
- `-wechat_conf` 由 App **运行期生成**：读取 `hook/versions/<version>_mac.json` 后合并 App 设置
  （4.1.15.55 / 4.2.0.5 / 4.2.0.9 为 R3 发送开关），写入
  `~/Library/Application Support/WeChatAI/runtime/hook-<version>-<build>.json` 再传给 bridge；
  仓库 JSON 始终保持默认 `off`，产品行为只由设置决定。
- `image_path` 用于图片/视频临时目录；不存在时上游会报错，App 负责创建/探测。多账号下
  App 传当前账号的 `xwechat_files/<dir>/temp`（`WeChatAccountResolution.imageDirectory`）。
- `-media_dir` 是**入站图片获取**的落盘目录，App 始终传
  `~/Library/Application Support/WeChatAI/accounts/<当前账号>/media`；
  留空（例如手动运行 bridge 调试）时 bridge 回退根 `media/`，仅用于旧版兼容。
  图片只会写入账号目录，不写 app bundle（避免破坏 ad-hoc 签名），也不再新写根 `media/`
  （旧媒体只读保留）。
- 鉴权：HTTP 发送接口与 `/fetch_image` 要求 `Authorization: Bearer <token>`；WS 无鉴权，仅监听 127.0.0.1。

### 3.2 WebSocket 事件（bridge → App）

连接 `ws://127.0.0.1:58080/ws`。事件在 bridge 完成归一化（含入站图片登记）后**立即**写出，
不受 `-send_interval` 延迟；该参数只节流真正发往微信的消息。事件级日志默认在 Debug 级，
只记录字节长度 + 最多 256 字符截断预览。

bridge 推送的 JSON（`WechatMessage`，字段可能缺省）：

```json
{
  "self_id": "wxid_xxx",
  "user_id": "wxid_target",
  "group_id": "123456@chatroom",
  "sender": { "user_id": "wxid_target", "nickname": "昵称" },
  "time": 1760000000000,
  "message_id": "123",
  "message": [
    { "type": "text", "data": { "text": "你好" } },
    { "type": "image", "data": { "url": "file:///...", "text": "<xml...>" } },
    { "type": "record", "data": { "url": "file:///..." } },
    { "type": "face", "data": { "url": "file:///..." } }
  ],
  "raw_message": "你好",
  "message_type": "group",
  "pat_from_wxid": "wxid_patter",
  "pat_chat_wxid": "123456@chatroom",
  "pat_target_wxid": "wxid_bot"
}
```

> `pat_*` 字段仅在「拍一拍」事件出现（2026-10-21 起）。hook 从 4.1.15 appmsg
> `<patinfo>` 或旧版 `<sysmsg type="pat">` 解析：`pat_from_wxid` 是拍的人，
> `pat_chat_wxid` 是群 ID（**私聊为空**），`pat_target_wxid` 是被拍的人，另可能有
> `pat_suffix` / `pat_template`。原始 XML 仍保留在 `raw_message`，App 侧有兜底解析。
> 2026-10-21 修复：私聊拍一拍 `<patinfo><chatusername>` 是 wxid（不是群 ID），
> 旧 hook 曾把它当 `group_id` 写进事件，导致同一好友的拍一拍了拍进独立「群聊」；
> 现在 hook 只在 `pat_chat_wxid` 是 `@chatroom` 时把它当群，bridge 也会清洗非法值。

解析规则：
- 群 ID 契约：微信群 ID 一律以 `@chatroom` 结尾。只有 `group_id` **是合法群 ID** 时才按群聊
  处理；非空但形如 wxid 的脏 `group_id` 会被 bridge 清洗，App 解析时也不会把它当群
  （2026-10-21 修复）。
- hook 判群：`from` 或 `to` 任一以 `@chatroom` 结尾即视为群消息——入站群消息 `from=群`，
  自己发出的群消息 `from=自己`、`to=群`；只有 `from` 是群时才解析群成员/正文前缀。
- 发送者身份以 `sender.user_id` 为准，缺失时用 `user_id`。
- `message` 可能是字符串或数组（上游 `Message` 结构），解析时容错。
- 自消息方向（2026-10-21 起）：
  - hook 额外上报 `from_wxid` / `to_wxid` / `sender_wxid`；bridge 用
    `-self_id`（App 传入，缺失时从 `image_path` 推导）判定发送者是否自己；
  - 自己发出的消息带 `is_self:true`，`self_id`/`sender.user_id` 是当前账号，
    私聊另带 `target_id=<对方 wxid>`，群聊 `target_id=<群 ID>`；旧 hook 的群自消息
    若 `group_id` 缺失而 `to_wxid` 是群 ID，bridge 会补 `group_id=to_wxid` 并置
    `message_type=group`；
  - App 的 `conversationID`：群 → `group_id`；私聊自消息 → `target_id`；
    其余 → `user_id`。方向由 `is_self` 决定，不能再用 `self_id == user_id` 兜底
    判断私聊自消息（会把它记进「自己 wxid」的会话）。
  - 会话归类自愈（2026-10-21）：启动时先跑 `MemoryStore.repairSelfRoutedMessages`
    （旧 hook 把自消息记进自己会话），再跑 `MemoryStore.repairMisroutedConversations`
    （`wxid_self` 占位会话、kind=group 但 ID 非群 ID 的伪群会话、非法群 ID 等）。
    两者都只搬能由 `raw_json` 明确推导目标的消息，幂等，失败/不确定时保持原样。
    历史事件反推 selfID 时会忽略 `wxid_self` / `self` 这类占位值。
    `self_id_source=login`（bridge `get_login_info` 写入）时两处修复直接信任权威 selfID、
    不再反推（2026-10-23）；反推只采样最近 5000 条 `raw_json`，且
    `repairMisroutedConversations` 先用 `conversations` 表筛出嫌疑会话——健康库启动不再
    全表读取并逐行解析历史消息。
- App 连接后主动发 `get_login_info`，把返回的 `data.user_id` 作为 selfID 的
  权威来源；事件启发式仅作为旧 bridge 的兜底。
- 拍一拍触发（2026-10-21 修复）：`pat_target_wxid == self_id` 才算「拍的是机器人」；
  `pat_target_wxid` 缺失时不再用「正文含『拍了拍』」直接命中——私聊按模板
  「拍了拍我 / patted me」判定，群聊只认正文含 selfID 或已学到的机器人群昵称。
  普通文本里出现「拍了拍」不算拍一拍事件。拍别人（target 非 self）不进入自动回复。
- 「引用机器人」触发（2026-10-22 新增，默认关闭）：群聊触发方式新增 `quote`，
  只有用户在「回复策略 → 群聊触发方式」里显式勾选才生效。判定以当前事件 `raw_message`
  的 `<refermsg>` 为准：群聊取 `<chatusr>`、私聊形态/部分客户端回退 `<fromusr>`
  （群 ID 忽略），与 selfID 做大小写不敏感比较；昵称不作为依据。正文不需要 @ 或关键词，
  引用动作本身就是唤醒条件；被引用原文仍只作为 AI 上下文，不参与 @/关键词/前缀匹配。
  历史事件无需补字段：`rawJSON` 已保留原始 appmsg XML，实时与历史消息都可判定。
- 「唤醒后免唤醒词」窗口（2026-10-23 新增，默认关闭）：`bot.wakeWindow`
  （`enabled` + `seconds`，默认 300 秒，UI 1–60 分钟），仅群聊生效。命中任一触发方式后，
  `RuleEngine` 以「会话 ID + 发送者 wxid」记录唤醒时间（内存态，机器人启动时清空）；
  窗口内该发送者的后续消息即使不含 @/关键词/引用也放行，触发标签为「群聊·唤醒窗口」，
  命中即续期（滑动窗口）。窗口只放宽触发判定：会话开关、白黑名单、工作时段、冷却与
  每分钟上限仍优先拦截；其它发送者、其它会话不受影响。旧 config 缺少该键时保持关闭。
- 拍一拍回复（设置可控，默认关闭）：`bot.pat.enabled` 开启且当前拍一拍确实拍的是
  机器人时，App 在规则引擎放行后发送自定义文字和/或 AI 回复。**不再回拍**，
  bridge 出站 `pat` 段与 `OneBotClient.sendPat` 已移除。
  - 自定义文字：`beforeText` / `afterText` 作为 AI 前/后的普通文本发送，支持
    `{name}` 占位符（对方昵称），不依赖 AI；
  - AI 回复：走与普通自动回复相同的 persona/provider/model 与上下文窗口；
    生成失败只跳过 AI 文字，不影响自定义文字。
  - 群聊 @ 拍的人（`bot.pat.mentionPatterInGroup`，默认关闭）：回复的第一条消息以
    `{"type":"at","data":{"qq":<拍的人 wxid>}}` + 文本发送，由 bridge 解析群昵称并写入
    `<atuserlist>` 生成真实 @；私聊不 @。bridge 解析不到昵称时该条不带 @ 照常发送。
  - 发送顺序：AI 前文字 → AI 回复 → AI 后文字；全部未发出时回退普通 AI 回复
    （回退回复的第一条同样带 @）。
- 会话标题（`Conversation.title`）学习规则（2026-10-21 起）：
  - 只在昵称**可读**时才写库：`sender.nickname` 非空、不等于会话 ID / `sender.user_id` /
    selfID、不是 `wxid_*` / `*@chatroom`、不是「我 / 自己」；
  - 自己发出的消息不参与命名；群聊标题不从消息推断（事件里没有群名），只更新副标题；
  - 用户重命名（非占位标题）后不会被后续事件覆盖；
  - 展示层 `ConversationName` 兜底：系统账号中文名 + `群聊 / 微信好友 / 公众号 · 尾号`；
    启动时 `MemoryStore.repairPlaceholderConversationTitles` 幂等清理历史 ID 标题。
- 通讯录真实昵称/群名（2026-10-21 起）：App 连接后请求 `get_contact_directory`；
  bridge 调 hook 在本机**只读**读取通讯录并查询联系人/群，返回 `users` / `groups`
  （`groups[*].members` 为群成员群昵称）。App 只在标题为空/占位时用目录填
  `Conversation.title`；bridge 转发入站事件时覆盖 `sender.nickname`
  （群聊优先群昵称，再回退通讯录显示名；群事件附 `group_name`），群 @ 昵称同样优先群昵称。
- appmsg 展示文本（2026-10-22 修复）：hook 只识别拍一拍（appmsg `<type>62</type>`），
  其它 `msg_type=49` 一律写 `[链接/文件]`，引用回复的正文（`<appmsg><title>`）与被引用
  原文（`<refermsg>`）对 App / 规则引擎 / AI 都不可见。App 在事件解析时从 `raw_message`
  按 appmsg `<type>` 还原可读文本：引用 57 → `回复正文` + 换行 + `【引用 发送者：原文摘要】`；
  链接 5 / 文件 6 / 视频 4 / 表情 8 / 聊天记录 19 / 小程序 33·36 / 转账 2000 / 红包 2001 /
  视频号 51 → `[类型] 标题`（引用摘要 160 字符、卡片内容 200 字符截断）。`raw_message`
  仍是原始 XML，拍一拍结构化字段、`at` 段与媒体段不受影响。旧 bridge（4.1.12 legacy
  路径）把 appmsg XML 原样当正文时同样会还原，非 appmsg 的 XML（图片/语音）保持原样。
  历史消息由
  `MemoryStore.repairAppmsgMessageTexts` 启动时按同一解析器幂等重算（只处理文本以
  `[链接/文件]` 开头的消息，保留结构化 `at` 后缀），并刷新会话预览。
  触发判定只取引用回复的正文（`RuleEngine.triggerText`）：被引用原文仅作为 AI 上下文，
  不会因为「引用了一条 @ 过机器人 / 含关键词的旧消息」而重复唤醒。
- 媒体字段：`data.url` 为 `file://` 本地路径时复制到当前账号媒体目录
  `accounts/<当前账号>/media/`；`data.file` 可能为 base64。旧版根 `media/` 不再新写。
- **入站图片获取（2026-10-23 新增，按需）**：微信 4.1.15 / 4.2.0.5 的图片消息在 hook 里
  只有文本占位 `[图片]`，图片 XML（`<img aeskey=… cdnmidimgurl=… cdnthumburl=… md5=…
  length=… />`）在 `raw_message` 里。bridge 在推送事件前解析该 XML，按 `message_id`
  登记 mid → thumb 两个下载候选，并把 `[图片]` 文本段替换成**无 data 的**
  `{"type":"image","data":{}}` 段（App 据此渲染图片气泡；新增的结构化字段与运行日志不携带 aeskey/CDN key；
  `raw_message` 仍保留 hook 原始图片 XML，与历史行为一致，App 的 `rawJSON` 会照旧入库）。
  XML 里的 `cdnmidimgurl`/`cdnthumburl` 是十六进制 CDN file key（不是 HTTP URL），
  未查看的图片也不会在本地落盘，因此 bridge 只在 App 调用 `POST /fetch_image` 时
  用 Frida 导出 `triggerDownload` 触发微信自己的 CDN 下载，收到分片后用 `aeskey`
  AES-ECB 解密并写入 `-media_dir/<yyyy-MM-dd>/`，返回 `file://` 路径。
  「是否获取」按**会话**控制：`Conversation.imageFetchEnabled`（nil 跟随旧全局默认，默认开启），
  入口是会话详情 → 菜单 →「媒体」→「获取图片」（2026-10-23 从全局设置移入各会话）；
  关闭时**完全不请求**，只显示「图片」占位。该链路已于 2026-10-23 在 4.2.0.5 真机验证
  （优先使用微信自然下载分片，必要时主动触发 → AES-ECB 解密；mid 为 HEVC 时用 JPEG 缩略图）。
  本次只做获取（识图见下条）。只处理实时入站图片，历史消息不回填。
- **识图（视觉模型，2026-10-23 新增，按需）**：自动回复触发且「AI 模型 → 识图模型」启用时，
  App 在生成回复前对上下文内最近 10 分钟、最多 2 张尚未识别的入站图片生成文字描述：
  图片文件未落盘时先等 `POST /fetch_image` 完成（最多 8 秒），再用 ImageIO 缩放/JPEG 编码，
  以 OpenAI 兼容的多模态 `image_url` 内容调用识图通道（DeepSeek 系通道关闭默认 thinking，
  避免推理占用输出额度）。描述写入
  `ChatMessage.imageDescription`（DB 列 `messages.image_description`），之后提示词以
  `[图片：<描述>]` 参与文本上下文；图片本体不进入回复提示词。失败只写 debug 日志，
  未开启识图或图片无法获取时行为与旧版一致。该链路尚未真机验证（需支持图片输入的视觉模型）。
  引用本轮消息所引用的图片时，App 解析 `refermsg` 的 `svrid`（与 `ChatMessage.id` 的
  `ob-<svrid>` 精确对应）找回原图：复用/现场生成识图描述，并以
  「（引用图片内容：…）」附加到本轮提示词，详见 core-services.md §3.3。

### 3.3 WebSocket 动作（App → bridge）

```json
{ "action": "send_private_msg", "echo": "uuid", "params": { "user_id": "wxid_x", "message": "文本" } }
{ "action": "send_private_msg", "echo": "uuid", "params": { "user_id": "wxid_x", "message": [ { "type": "text", "data": { "text": "hi" } } ] } }
{ "action": "send_group_msg", "echo": "uuid", "params": { "group_id": "xxx@chatroom", "message": [ { "type": "at", "data": { "qq": "wxid_x" } }, { "type": "text", "data": { "text": " hi" } } ] } }
{ "action": "get_login_info", "echo": "uuid", "params": {} }
{ "action": "get_group_member_info", "echo": "uuid", "params": { "group_id": "xxx@chatroom", "user_id": "wxid_x" } }
{ "action": "get_contact_directory", "echo": "contact-directory", "params": {} }
```

- 上游对 `send_*` 动作**不回 echo**（当前实现）；App 以 HTTP 接口作为发送主通道并等待 `{"status":"ok"}`，WS 只用于收事件，避免“假成功”。
- HTTP 发送：`POST http://127.0.0.1:58080/send_private_msg`（或 `send_group_msg`），
  Header `Authorization: Bearer <token>`，body：
  `{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}`
  返回 `{"status":"ok"}` 或 5xx/`{"status":"failed","error":...}`。
- 图片/语音/视频/文件：`message` 数组元素 `{"type":"image","data":{"file":"base64://..."}}`。
  单条消息过长时 App 应自行分段。
- **入站图片获取**：`POST http://127.0.0.1:58080/fetch_image`，Header `Authorization: Bearer <token>`，
  body `{"message_id":"<OneBot message_id>"}`。bridge 按需触发微信 CDN 下载（单次总预算约 12 秒），
  成功返回 `{"status":"ok","data":{"file":"file:///.../accounts/<当前账号>/media/<date>/<name>.jpg","message_id":"..."}}`，
  失败返回 `{"status":"failed","error":"中文原因"}`；消息未登记/已过期 400，下载失败 502。
  App 只在该会话生效的「获取图片」开启、消息是图片、`mediaPath`/`mediaURL` 为空时请求
  （会话覆盖 → 旧全局默认 → true）；返回路径写入 `ChatMessage.mediaPath` 并落库。
  错误由 App 写 debug 日志，不进入回复提示词。
- 群聊 @：`{"type":"at","data":{"qq":"wxid_x"}}` 放在文本段之前；bridge 用群成员缓存
  （回退通讯录目录）解析昵称，拼接 `@群昵称\u2005` 并把目标写入 `<atuserlist>`。
  「拍一拍回复 @ 拍的人」复用同一路径（仅群聊，附在回复的第一条消息前）。
- 拍一拍：**App 已移除出站 `pat`**（2026-10-21），不再发送原生拍一拍；bridge/hook 仍保留
  `pat` 解析与 `triggerSendPatMessage` 作为历史路径（`r3PatSend=false`，产品不调用）。
  入站 `pat_*` 字段保留，App 用它触发自定义文字/AI 回复。

## 4. App 内部关键类型

- `AppStore`（`Core/AppStore.swift`）：`@MainActor @Observable`，持有 settings/conversations/messages/logs/hookStatus/stats；UI 只读并调用其方法。多账号字段：`activeAccountID` / `activeAccountIsUnassigned` / `accountSwitchNotice` / `savedWeChatAccounts` / `isSwitchingAccount`（见 §5）。
- `AccountProfile` / `AccountLayout` / `WeChatAccountResolver`（`Services/AccountProfile.swift`、`Services/WeChatAccountResolver.swift`）：
  账号档案布局、`account-state.json`、旧版迁移、`_unassigned` 认领、启动前账号识别。契约见 [`accounts.md`](accounts.md)。
- `SleepPreventionCenter`（`Services/SleepPreventionService.swift`，`@MainActor @Observable`）：
  `general.sleepPrevention` 的运行时执行者，持有/释放 IOKit `PreventUserIdleSystemSleep` 断言，
  监听电源适配器变化；纯决策函数 `shouldPreventSleep(mode:onExternalPower:)` 可单测。
- `AppSettings`/`Conversation`/`ChatMessage`/`AIProvider`/`Persona`/`ScheduledTask`/`HookStatus`/`BotStats`（`Models/Models.swift`，Lead 所有）。
- `ImageFetcher`（`Services/ImageFetcher.swift`，`@MainActor`）：入站图片获取的**串行队列**。
  只按消息入队，不持有 `OneBotClient`/`AppStore`（`fetch` / `onFetched` / `onFailed` 闭包注入）；
  同一 `chatMessageID` 只尝试一次，失败不自动重试；`cancelAll()` 用于停止机器人或关闭设置。
  决策规则集中在纯函数 `ImageFetchPolicy.shouldFetch(...)`，便于单测。
  是否入队由 `Conversation.effectiveImageFetchEnabled(global: settings.bot.fetchImagesEnabled)`
  决定（会话列 `image_fetch_enabled`：NULL 跟随、0 关、1 开）。
- `VisionSupport`（`Services/VisionEngine.swift`，纯静态函数）：识图候选筛选（入站图片、
  无描述、10 分钟内、最多 2 张）、ImageIO 缩放与 JPEG/base64 data URL、多模态请求消息、
  描述清洗。运行时在 `evaluateAndReply` 生成回复前调用；描述写入
  `ChatMessage.imageDescription` 并落库，提示词以 `[图片：<描述>]` 参与文本上下文。
- 服务协议建议：
  ```swift
  protocol OneBotTransport: AnyObject { func start() async throws; func stop(); func send(...) async throws }
  protocol AIChatService { func complete(messages:[AIMessage], provider:AIProvider) async throws -> String }
  protocol MemoryStoring { func conversations() throws -> [Conversation]; func messages(...) throws -> [ChatMessage]; ... }
  ```
  具体协议由 swift-core 在 `Core/` 定义，UI 不直接依赖具体实现。

## 5. 配置与密钥

- 配置：`~/Library/Application Support/WeChatAI/config.json`（`AppSettings`，JSON；全局）。
  通用设置中的 `general.sleepPrevention`（`never` / `externalPowerOnly` / `always`，默认 `never`）
  通过自定义 Codable 兼容旧版缺失字段；其它设置的旧字段同理不会因新增键而重置。
  `config.json` 保留完整 `AppSettings` 镜像（含 `bot`/`personas`/`schedules`）用于旧版回滚；
  当前版本运行时的账号字段以 `accounts/<当前账号>/profile.json` 为准，加载时由
  `SettingsStore.load()` 用 profile 覆盖。
- 账号配置：`accounts/<当前账号>/profile.json`（`ProfileSettings`：`bot`/`personas`/`schedules`）。
  缺失用默认值；解码失败备份为 `profile.corrupt-<ts>.json` 后回退默认，不影响全局配置。
- 账号指针：`account-state.json`（`lastAccountID` / `updatedAt` / `legacyMigrationDone`），
  由 `AccountProfile` 原子写；只有旧库迁移真正完成才把 `legacyMigrationDone` 置 `true`。
- 数据库：`accounts/<当前账号>/chatbot.sqlite`（WAL）；旧版根目录 `chatbot.sqlite` 迁移后保留、
  不再写入。账号切换与旧版迁移见 [`accounts.md`](accounts.md)。
- API Key：macOS Keychain，service = `com.gusionw.wechatai`，account = `provider.apiKeyReference`；
  全局共享，不随微信账号切换。
- 配置中**禁止**出现明文 Key；`AIProvider.apiKeyReference` 仅存 Keychain account 名。

## 6. Hook 版本契约

- 版本文件：`hook/versions/<version_with_underscores>_mac.json`，字段与上游/本项目脚本
  保持一致；**具体键名、地址与发送开关只以文件本身为准，文档不重复**。
- 版本文件是 Hook 地址与开关的唯一数据源；修改必须真机验证并同步 `bridge/NOTICE`。
- 当前目标：WeChat 4.2.0.9 (270345)，arm64，`/Applications/WeChat.app/Contents/Resources/wechat.dylib`；
  历史版本 4.2.0.5 (270341) / 4.1.15.55 (270135) / 4.1.12.53 (269365) 的版本文件保留，安装脚本默认目标为 4.2.0.9。
- 2026-10-22 在 4.2.0.5 (270341) 完成真机验证：Gadget 注入 + ad-hoc 重签（保留 sandbox
  entitlements）后微信正常启动、gadget 27042 监听；私聊/自消息入站、通讯录解密读取、
  R3 文本发送（含 bridge 重启后从本地缓存恢复发送句柄）均通过；版本文件已按真机验证结果
  修正并生效。群聊 @ / 拍一拍沿用既有逻辑，本轮未单独复测；图片获取链路已实现（CDN 触发下载待复测）。
- 2026-10-27 新增 4.2.0.9 (270345) 版本文件 `hook/versions/4_2_0_9_mac.json`：arm64 偏移按
  4.2.0.5 → 4.2.0.9 的差异重新定位（函数为字节级同构，虚表/全局按 chained fixups 与代码
  交叉引用定位）；2026-10-27 在 4.2.0.9 (270345) 完成真机验证：Gadget 注入 + ad-hoc 重签（保留 sandbox entitlements）、WeChat 正常启动且 gadget 27042 监听；hook 基址解析与 classA/service vptr 校验通过；通讯录解密读取（29 联系人 / 1 群 / 10 群成员，DB key 回灌）；入站自消息事件正确；手动发一条文本捕获并持久化 R3 发送句柄后，R3 文本发送到文件传输助手 slot13 返回 0、worker result=1。语音发送沿用同一链路但本轮未复测（需手动发一条语音捕获 voice seed/header）；群聊 @ / 拍一拍与媒体下载未复测。
- 4.1.15.55 / 4.2.0.5 / 4.2.0.9 发送附加配置（R3，仓库默认 `enableSend=false` / `req2bufSendMode=off`）：
  由 App 读取版本 JSON 后按设置合并生成运行期配置；具体键名、运行期参数与地址表只维护在
  `hook/versions/*.json` 与 `hook/script.js`，文档不展开。
  App 默认开启 R3（可在设置中关闭）；首次使用（或微信重启后）需在本机微信手动发一条消息
  以捕获发送上下文，App/bridge 重启会按微信 PID 从本地缓存自动恢复。
- 任何 Hook 适配变更必须在真机验证文本收发后才能标记为可用。
- 安装 Gadget 流程：完整备份 → 注入 load command → 复制 Gadget/配置 → ad-hoc 重签整个 App → 校验。
- 恢复：从备份 zip 还原整个 `/Applications/WeChat.app` 并重签（或直接用备份替换）。

## 7. 验收标准（首版）

1. App 原生窗口可启动；总览/会话/机器人/AI/人格/记忆/定时/日志/设置 **九个页面齐全**，Apple 风格统一。
2. 首次启动向导：检测微信版本 → 备份并安装 Gadget → 配置 AI → 启动机器人。
3. 微信收到私聊/群消息 → App 实时显示 → 按触发设置与人设生成回复 → 微信实际发出（非 dry-run）。
4. 群聊仅在被 @/关键词/前缀时回复；白/黑名单、冷却、频率限制生效。
5. 重启 App/微信后能恢复连接；日志可查；数据本地持久化。
6. 空闲时 App 内存占用低（目标 < 150MB），bridge < 80MB；无忙轮询。
7. 多微信账号：换微信账号后聊天/记忆/会话设置/机器人配置切到该账号档案，AI/Hook/OneBot/
   Keychain/语音模型保持全局；升级旧单库时只 copy 不删；旧媒体路径仍可读。验收细节见
   [`accounts.md`](accounts.md) §11。

## 8. 运行时资源布局与安装契约（App bundle）

`scripts/build_app.sh` 产物：

```
WeChat AI.app/Contents/Resources/
  bridge/onebot
  bridge/script.js        # 由 hook/script.js 复制（单一事实来源）
  hook/versions/4_2_0_5_mac.json
  hook/versions/4_1_15_55_mac.json
  hook/versions/4_1_12_53_mac.json
  hook/gadget/FridaGadget.dylib
  hook/gadget/FridaGadget.config
  tools/install_gadget.sh
  tools/manage_wechat.sh
  tools/inject_load_dylib.py
  AppIcon.icns
  LICENSE / ThirdPartyNotices.txt
```

资源根解析顺序（HookManager）：
1. `Bundle.main.resourceURL` 下存在 `bridge/onebot`；
2. 环境变量 `WECHATAI_ROOT`；
3. 从 `Bundle.main.bundleURL` / 可执行文件路径向上查找 `bridge/onebot`（`swift run` 开发态）；
4. 仍找不到则报明确错误，不崩溃。

### 8.1 安装脚本协议

`tools/install_gadget.sh` 参数：

```bash
tools/install_gadget.sh \
  --wechat-path /Applications/WeChat.app \
  --gadget <FridaGadget.dylib> \
  --config <FridaGadget.config> \
  --backup-dir <dir> [--force] [--json]
```

stdout：
- 默认逐行 `[stage]<0-1>|<message>`；
- `--json` 逐行 `{"progress":0.52,"stage":"..."}`；
- 结束 `OK`（exit 0）或 `ERROR:<message>`（非 0）。

内部流程：版本校验 → 完整备份（`ditto` zip）→ 注入 `LC_LOAD_DYLIB` →
复制 Gadget/配置 → **仅重签主 App**（保留原沙盒 entitlements，去掉 hardened runtime）→
`codesign --verify --strict` + otool 复核。

### 8.2 还原

`tools/manage_wechat.sh restore` 用备份 zip 覆盖 App，恢复 Tencent 官方签名；
必须保证微信已退出。备份路径：
`~/Library/Application Support/WeChatAI/backups/WeChat-<version>-<build>-official.zip`。

### 8.3 本地联调

`devtools/mock_onebot.py` + `devtools/mock_ai.py` 可在无微信/无 API Key 时
跑通「收事件 → 触发判定 → AI → 发送」；详见 `devtools/README.md`。

## 9. 4.1.15 入站消息接收（真机验证）

4.1.15 的旧 `buf2RespAddr` 不再承载普通入站消息。桥接的接收路径改为：

- Frida 在微信进程内挂**只读的 Message 终结器**；具体函数地址与字段布局由
  `hook/versions/*.json` 与 `hook/script.js` 按微信版本维护，**不在公开文档展开**。
  WeChat 4.2.0.5 (270341) 沿用同一路径、使用新增的版本文件；2026-10-22 真机验证私聊与
  自消息入站正常（群聊 @ / 拍一拍未单独复测，解析逻辑未变）。
  WeChat 4.2.0.9 (270345) 沿用同一路径与版本文件机制（`hook/versions/4_2_0_9_mac.json`），
  偏移已按 4.2.0.5 → 4.2.0.9 差异重新定位；2026-10-27 真机验证自消息入站与 R3 文本发送通过
  （群聊 @ / 拍一拍未复测）。
- Hook 读取到新消息后发送 `incoming_message` 给 Go bridge；Go 的 `incoming.go` 转成
  OneBot 事件并经 WebSocket/HTTP 推送。App 的 OneBotClient 消费。
- 群聊 `from` 以 `@chatroom` 结尾；文本可能带 `sender_wxid:` 前缀，JS 会剥离并把
  sender 作为 user_id。
- 消息字段的兼容性处理（群/@/拍一拍/自消息方向）在 `hook/script.js` 与
  `bridge/incoming.go` 中完成，文档只描述对外字段契约（见 §3）。

安全：Message finalizer hook 为**只读**，不修改寄存器/内存。R3 发送由 App 设置控制
（默认开启）；如果绕过 App、直接用 `scripts/run_bridge.sh` 调试，它默认
`HOOK_SEND_DISABLED=true`（只读接收），避免触发 4.1.15 skip-erase 路径。
