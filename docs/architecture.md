# WeChat AI ChatBot — 架构与接口契约

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
│   ├─ OneBotClient (WS + HTTP, 127.0.0.1:58080)                   │
│   ├─ AIService (URLSession, OpenAI 兼容, 流式)                    │
│   ├─ MemoryStore (SQLite, ~/Library/Application Support/WeChatAI) │
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
- 日志环形缓冲（App 内 2000 条），落盘按天切割，避免无界增长。
- 防睡眠默认关闭；仅在用户选择「接入电源时 / 始终」后持有 IOKit 空闲睡眠断言，
  不轮询、不阻止合盖睡眠。

## 2. 目录与写入边界

| 目录 | 归属 | 说明 |
| --- | --- | --- |
| `app/Sources/WeChatBot/Models/` | Lead | 共享数据模型 / 设置，改动需先沟通 |
| `app/Sources/WeChatBot/Core/` | swift-core | AppStore、运行时编排、服务协议 |
| `app/Sources/WeChatBot/Services/` | swift-core | OneBot/AI/记忆/触发判定/调度/Hook 服务 |
| `app/Sources/WeChatBot/DesignSystem/` | swift-ui | 主题、组件、玻璃效果 |
| `app/Sources/WeChatBot/Views/` | swift-ui | 所有页面与弹窗 |
| `app/Sources/WeChatBot/WeChatBotApp.swift` | swift-ui | App 场景（窗口/菜单栏/设置） |
| `app/Tests/WeChatAITests/` | swift-core | 核心服务单元测试 |
| `bridge/` | bridge | OneBot Go 源码与脚本（`proto/` 为微信协议定义） |
| `hook/` | hook-port | script.js、版本 JSON、Gadget 配置与诊断说明 |
| `tools/` | hook-port / Lead | Mach-O 注入、微信备份/安装/还原、指针反查（addrfind 来自上游，未随仓库分发） |
| `scripts/` | Lead / bridge | 构建、打包、安装、运行、清理脚本 |
| `devtools/` | Lead | 本地 Mock AI/OneBot 与 Frida 探针（不参与打包） |
| `assets/` | Lead | App 图标源文件与 `.icns` |
| `docs/` | Lead | 架构、契约、研究记录与验收报告 |
| `_research/` | hook-port | Hook 移植证据/日志/候选 JSON（git 忽略，仅本地保留） |

> 「归属」列记录的是 2026-10 并行开发期的任务名（Lead / swift-core / swift-ui / bridge /
> hook-port），用于说明**改动的主要责任面**，不是人员权限。日常维护按目录职责理解；
> 跨目录改动先读 [`development.md`](development.md) 的「改动定位」与
> [`AGENTS.md`](../AGENTS.md) 的写盘边界。

## 3. OneBot 桥接契约（已按上游 v0.0.18 源码核对）

### 3.1 启动参数

```bash
bridge/onebot \
  -type=gadget \
  -gadget_addr=127.0.0.1:27042 \
  -wechat_conf=/path/to/hook/versions/4_1_15_55_mac.json \
  -receive_host=127.0.0.1:58080 \
  -token=<随机 32 字节十六进制> \
  -conn_type=websocket \
  -self_id=<当前登录 wxid> \
  -log_file=$HOME/Library/Logs/WeChatAI/bridge/macos.log \
  -image_path=/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/<wxid>/temp/<...>/Img/
```

- `onebot` 从**当前工作目录**读取 `script.js`，因此 App 启动进程时 `currentDirectoryURL` 必须指向 bridge 资源目录。
- `-log_file` **必须**指向 app bundle 之外。旧实现固定写 `./log/macos.log`，而 cwd 在 bundle 内，
  运行期会往 bundle 里追加文件、破坏 ad-hoc 签名，导致下次启动被系统以
  `Launch Constraint Violation` 杀掉。App 现在传 `~/Library/Logs/WeChatAI/bridge/macos.log`。
- `-self_id` 是当前登录账号的权威来源（App 已知时传入）；缺失时 bridge 才从 `image_path`
  的 `xwechat_files/<wxid>_xxxx/` 推导。多账号目录下 App 取最近有活动的账号。
- `-wechat_conf` 由 App **运行期生成**：读取 `hook/versions/<version>_mac.json` 后合并 App 设置
  （4.1.15.55 为 R3 发送开关），写入
  `~/Library/Application Support/WeChatAI/runtime/hook-<version>-<build>.json` 再传给 bridge；
  仓库 JSON 始终保持默认 `off`，产品行为只由设置决定（见 [`hook-r3-native-send.md`](hook-r3-native-send.md)）。
- `image_path` 用于图片/视频临时目录；不存在时上游会报错，App 负责创建/探测。
- 鉴权：HTTP 发送接口要求 `Authorization: Bearer <token>`；WS 无鉴权，仅监听 127.0.0.1。

### 3.2 WebSocket 事件（bridge → App）

连接 `ws://127.0.0.1:58080/ws`。bridge 推送的 JSON（`WechatMessage`，字段可能缺省）：

```json
{
  "self_id": "wxid_xxx",
  "user_id": "wxid_target",
  "group_id": "123456@chatroom",
  "sender": { "user_id": "wxid_target", "nickname": "昵称" },
  "time": 1760000000,
  "message_id": "123",
  "message": [
    { "type": "text", "data": { "text": "你好" } },
    { "type": "image", "data": { "url": "file:///...", "text": "<xml...>" } },
    { "type": "record", "data": { "url": "file:///..." } },
    { "type": "face", "data": { "url": "file:///..." } }
  ],
  "raw_message": "你好",
  "message_type": "group"
}
```

解析规则：
- `group_id` 非空 → 群聊；否则私聊。
- 发送者身份以 `sender.user_id` 为准，缺失时用 `user_id`。
- `message` 可能是字符串或数组（上游 `Message` 结构），解析时容错。
- 自消息方向（2026-10-21 起）：
  - hook 额外上报 `from_wxid` / `to_wxid` / `sender_wxid`；bridge 用
    `-self_id`（App 传入，缺失时从 `image_path` 推导）判定发送者是否自己；
  - 自己发出的消息带 `is_self:true`，`self_id`/`sender.user_id` 是当前账号，
    私聊另带 `target_id=<对方 wxid>`，群聊 `target_id=<群 ID>`；
  - App 的 `conversationID`：群 → `group_id`；私聊自消息 → `target_id`；
    其余 → `user_id`。方向由 `is_self` 决定，不能再用 `self_id == user_id` 兜底
    判断私聊自消息（会把它记进「自己 wxid」的会话）。
- App 连接后主动发 `get_login_info`，把返回的 `data.user_id` 作为 selfID 的
  权威来源；事件启发式仅作为旧 bridge 的兜底。
- 媒体字段：`data.url` 为 `file://` 本地路径时复制到 App 媒体目录；`data.file` 可能为 base64。

### 3.3 WebSocket 动作（App → bridge）

```json
{ "action": "send_private_msg", "echo": "uuid", "params": { "user_id": "wxid_x", "message": "文本" } }
{ "action": "send_private_msg", "echo": "uuid", "params": { "user_id": "wxid_x", "message": [ { "type": "text", "data": { "text": "hi" } } ] } }
{ "action": "send_group_msg", "echo": "uuid", "params": { "group_id": "xxx@chatroom", "message": [ { "type": "at", "data": { "qq": "wxid_x" } }, { "type": "text", "data": { "text": " hi" } } ] } }
{ "action": "get_login_info", "echo": "uuid", "params": {} }
{ "action": "get_group_member_info", "echo": "uuid", "params": { "group_id": "xxx@chatroom", "user_id": "wxid_x" } }
```

- 上游对 `send_*` 动作**不回 echo**（当前实现）；App 以 HTTP 接口作为发送主通道并等待 `{"status":"ok"}`，WS 只用于收事件，避免“假成功”。
- HTTP 发送：`POST http://127.0.0.1:58080/send_private_msg`（或 `send_group_msg`），
  Header `Authorization: Bearer <token>`，body：
  `{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}`
  返回 `{"status":"ok"}` 或 5xx/`{"status":"failed","error":...}`。
- 图片/语音/视频/文件：`message` 数组元素 `{"type":"image","data":{"file":"base64://..."}}`。
  单条消息过长时 App 应自行分段。

## 4. App 内部关键类型

- `AppStore`（`Core/AppStore.swift`）：`@MainActor @Observable`，持有 settings/conversations/messages/logs/hookStatus/stats；UI 只读并调用其方法。
- `SleepPreventionCenter`（`Services/SleepPreventionService.swift`，`@MainActor @Observable`）：
  `general.sleepPrevention` 的运行时执行者，持有/释放 IOKit `PreventUserIdleSystemSleep` 断言，
  监听电源适配器变化；纯决策函数 `shouldPreventSleep(mode:onExternalPower:)` 可单测。
- `AppSettings`/`Conversation`/`ChatMessage`/`AIProvider`/`Persona`/`ScheduledTask`/`HookStatus`/`BotStats`（`Models/Models.swift`，Lead 所有）。
- 服务协议建议：
  ```swift
  protocol OneBotTransport: AnyObject { func start() async throws; func stop(); func send(...) async throws }
  protocol AIChatService { func complete(messages:[AIMessage], provider:AIProvider) async throws -> String }
  protocol MemoryStoring { func conversations() throws -> [Conversation]; func messages(...) throws -> [ChatMessage]; ... }
  ```
  具体协议由 swift-core 在 `Core/` 定义，UI 不直接依赖具体实现。

## 5. 配置与密钥

- 配置：`~/Library/Application Support/WeChatAI/config.json`（`AppSettings`，JSON）。
  通用设置中的 `general.sleepPrevention`（`never` / `externalPowerOnly` / `always`，默认 `never`）
  通过自定义 Codable 兼容旧版缺失字段；其它设置的旧字段同理不会因新增键而重置。
- 数据库：同目录 `chatbot.sqlite`（WAL）。
- API Key：macOS Keychain，service = `com.gusionw.wechatai`，account = `provider.apiKeyReference`。
- 配置中**禁止**出现明文 Key；`AIProvider.apiKeyReference` 仅存 Keychain account 名。

## 6. Hook 版本契约

- 版本文件：`hook/versions/<version_with_underscores>_mac.json`，字段与上游一致：
  `structVer, sendFuncAddr, req2bufEnterAddr, req2bufExitAddr, buf2RespAddr, blrX8Addr,
   autoBufferWriteFunc, uploadImageAddr, cdnGetServiceAddr, cdnManagerGetterAddr,
   cndOnCompleteAddr, uploadGetCallbackWrapperAddr, uploadGetCallbackWrapperFuncAddr,
   uploadOnCompleteFuncAddr, uploadOnCompleteAddr, startDownloadMedia,
   downloadImagAddr, downloadFileAddr, downloadVideoAddr`。
- 当前目标：WeChat 4.1.15.55 (270135)，arm64，`/Applications/WeChat.app/Contents/Resources/wechat.dylib`。
- 4.1.15.55 发送附加键（R3，仓库默认 `enableSend=false` / `req2bufSendMode=off`）：
  `classAVtable, globalServiceHolder, defaultScopeString, stringCtorAddr, serviceScopeAddr,
   newSendMsgTaskCtorAddr, newSendMsgTaskVtable, r3ClosureVtable, slot13Addr, operatorNewAddr,
   newsendmsgUrl, r3ClosureCapture, r3Slot13Capture, r3QueueUntilSeed, r3MaxClones`。
  App 在 4.1.15.55 上按设置合并出 `enableSend=true, req2bufSendMode=r3, r3Slot13Capture=true,
  r3QueueUntilSeed=true`（默认开启，可在设置中关闭）；首次使用需本机微信手动发一条消息以捕获种子闭包。
- 任何偏移变更必须 runtime 验证文本收发 + 图片上传后才能标记 `matchedVersion = true`。
- 安装 Gadget 流程：完整备份 → 注入 load command → 复制 Gadget/配置 → ad-hoc 重签整个 App → 校验。
- 恢复：从备份 zip 还原整个 `/Applications/WeChat.app` 并重签（或直接用备份替换）。

## 7. 验收标准（首版）

1. App 原生窗口可启动；总览/会话/机器人/AI/人格/记忆/定时/日志/设置 **九个页面齐全**，Apple 风格统一。
2. 首次启动向导：检测微信版本 → 备份并安装 Gadget → 配置 AI → 启动机器人。
3. 微信收到私聊/群消息 → App 实时显示 → 按触发设置与人设生成回复 → 微信实际发出（非 dry-run）。
4. 群聊仅在被 @/关键词/前缀时回复；白/黑名单、冷却、频率限制生效。
5. 重启 App/微信后能恢复连接；日志可查；数据本地持久化。
6. 空闲时 App 内存占用低（目标 < 150MB），bridge < 80MB；无忙轮询。

## 8. 运行时资源布局与安装契约（App bundle）

`scripts/build_app.sh` 产物：

```
WeChat AI.app/Contents/Resources/
  bridge/onebot
  bridge/script.js        # 由 hook/script.js 复制（单一事实来源）
  hook/versions/4_1_15_55_mac.json
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

- Frida hook **通用 Message 终结器** `base+0x4cbc3ac`（antirecall 已对 270135 验证）；
  `x1==1` 表示新收到的网络消息。
- 字段布局（270135）：
  `type=+0x0C`、`from=+0x18`(std::string)、`to=+0x30`(std::string)、
  `serverId=+0xF8`、`created=+0x114`、`content=+0x130`(std::string)。
- JS 读取后发送 `incoming_message` 给 Go bridge；Go 的 `incoming.go` 转成 OneBot
  事件并经 WebSocket/HTTP 推送。App 的 OneBotClient 消费。
- 群聊 `from` 以 `@chatroom` 结尾；文本 `content` 可能以 `sender_wxid:\n` 前缀，
  JS 会剥离并把 sender 作为 user_id。

安全：Message finalizer hook 为**只读**，不修改寄存器/内存；发送注入默认关闭
（`HOOK_SEND_DISABLED=true`），避免再次触发 4.1.15 skip-erase 路径。
