# 变更日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与
[语义化版本](https://semver.org/lang/zh-CN/)。日期格式：YYYY-MM-DD。
Hook / 微信版本相关的变更会注明目标微信版本与验证方式。

## [Unreleased]

### 新增

- **通讯录真实昵称 / 群名**：hook 在微信进程内解密 `contact.db`（SQLCipher 4 页格式，
  捕获 CommonCrypto 页操作密钥）后返回联系人目录，bridge 暴露 OneBot `get_contact_directory`，
  App 用真实昵称/群名替换 wxid 标题，并在群成员缓存未命中时回退通讯录昵称。
  详见 [`docs/hook-contact-directory.md`](docs/hook-contact-directory.md)。
- **稳定性与崩溃取证**：`CrashReporter`（未捕获异常报告、会话面包屑、主线程看门狗）、
  `AppKitLayoutGuard`（显示周期断言安全阀），详见 `docs/performance.md`。
- **回复进度倒计时**：`ReplyProgressBar`，会话详情头部、输入区与会话行同步显示
  AI 生成 / 拟人化等待 / 发送中 / 完成 / 失败状态。
- **会话重命名**：会话详情菜单「重命名会话…」（`ConversationRenameSheet`），
  可给微信只下发 wxid 的会话起名，留空恢复自动名称。
- **会话工作时段状态**：会话详情头部新增 `WorkingHoursBadge`，实时显示
  「工作时段 / 非工作时段 / 不限时段」，按会话覆盖优先判定并每分钟刷新；
  悬停可查看时段来源与摘要，非工作时段与 `RuleEngine` 的拦截口径一致。
- **核心记忆权重可调**：记忆编辑器新增基础权重滑块（0.1~10.0×，步长 0.1，
  含 0.5×/1×/2×/3×/5× 预设与重置）和保存后综合权重估算；核心记忆之间也按综合权重排序，
  超出注入名额时高权重核心优先；卡片在权重被调整后显示「基础 ×N.N」徽标
  （`docs/memory.md` §5–§6）。
- **拍一拍回复**：只响应「别人拍的是机器人」的事件；机器人页可开启拍一拍回复
  （默认关闭），配置 AI 前/后自定义文字（支持 `{name}`）和/或 AI 回复。
  群聊新增「被拍后 @ 拍的人」（`bot.pat.mentionPatterInGroup`，默认关闭）：
  回复的第一条消息（自定义前文字 → AI 首段 → 自定义后文字中先发出者）携带 OneBot
  `at` 段，由 bridge 解析群昵称并写入 `<atuserlist>` 生成真实 @；私聊不 @，
  昵称解析失败时退化为普通文本。新增 `PatMessage.replyMention` 与单测。
- **拍一拍目标识别**：hook 解析 appmsg/patinfo 或 sysmsg 的 `pattedusername`，
  上报 `pat_from_wxid` / `pat_chat_wxid` / `pat_target_wxid`，拍别人不会唤醒机器人。
- **日志批量管道** `LogPipeline`：200ms 批量刷新、ANSI 清理、UI 与 SQLite 节流。
- **自消息方向字段**：hook 上报 `from_wxid` / `to_wxid` / `sender_wxid`，bridge 输出
  `is_self` / `target_id`；App 用权威 selfID 归位会话，并新增
  `MemoryStore.repairSelfRoutedMessages` 一次性修复历史误路由。
- **bridge**：`incoming.go` 入站事件归一化、`r3seed.go` 发送句柄按微信 PID 持久化；
  新增 `incoming_msg_test.go`、`incoming_normalize_test.go`、`MessageRoutingTests`。
- **文档**：新增 `docs/development.md`（开发手册）、`AGENTS.md`（AI 代理指南）、
  `docs/performance.md`、`docs/hook-contact-directory.md`、本变更日志；新增
  `scripts/check.sh`、`scripts/check_docs.py`、`scripts/sync_hook_script.sh`、根 `Makefile`。

### 变更

- **移除原生「拍一拍」回拍**：App 删除 `sendPat` 与「仅回拍 / 回拍位置」设置及相关测试，
  不再发送 `pat` 消息段。bridge/hook 中保留的 sendpat 历史代码保持默认关闭
  （`r3PatSend=false`、App 不调用），仅作逆向记录。拍一拍设置收敛为「拍一拍回复」；
  旧配置的 `beforeText` / `afterText` 自动沿用为自定义文字，`patOnly` / `aiPosition` 忽略。
- **记忆**：窗口外批量总结阈值从 20 条调整为 8 条，总结上限 600 字并自动压缩；
  核心记忆按所属会话/全局作用域生效，手写编辑不被自动总结覆盖（`docs/memory.md`）。
- **bridge 日志外置**：写到 `~/Library/Logs/WeChatAI/bridge/macos.log`，不再写入 app bundle
  （避免 ad-hoc 签名失效导致下次启动被杀）。
- **发送延迟**：bridge `-send_interval` 收紧到 100ms；R3 文本发送不再等待 buf2resp，
  避免「已送达却返回 send timeout」的误报。
- **脚本**：`fetch_gadget.sh` 对 Frida Gadget 17.8.0 校验压缩包与 dylib 的 SHA256；
  `clean.sh` 修正 `dist/` 保留语义并新增 `__pycache__` 清理；Go/Hook 构建产物一致性检查
  统一到 `scripts/check.sh`；`check.sh` 兼容 macOS 自带 bash 3.2（空数组在 `set -u` 下
  不再报 unbound variable）；`sync_hook_script.sh` 在 Linux 上回退 `sha256sum`，便于 CI 校验。
- **发布准备**：清理构建产物、运行日志与 `.DS_Store`；新增发布前检查清单（见
  [`README.md`](README.md)「清理、打包与分享」）；文档中的测试数字统一为
  **Swift 126 项 / Go 60 项**；`docs/README.md` 增加开发手册、AI 代理指南与
  通讯录文档入口；`bridge/NOTICE` 更新为实际修改/新增文件清单。
- **GitHub 仓库配置**：本地研究证据（截图 / 数据库备份 / 探针日志）移出仓库；新增
  [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)、[`SUPPORT.md`](SUPPORT.md)、
  `.github/release.yml` 与 Linux CI 仓库卫生检查（阻止构建产物、日志、DB、截图入库）。

### 修复

- **同一好友被拆成两个会话（2026-10-21 第二轮）**：私聊拍一拍的
  `<patinfo><chatusername>` 是 wxid，旧 hook 把它当群 ID 写入 `group_id`，于是好友的
  拍一拍被放进一个以自己 wxid 为 ID 的伪「群聊」；另外旧版 `self_id` 污染曾把机器人的
  群回复写进字面量 `wxid_self` 会话。修复：hook 只在 `from` / `to` 是 `@chatroom`
  时判群、私聊拍一拍 `pat_chat_wxid` 为空；bridge 清洗非法 `group_id` / `pat_chat_wxid`
  并给群自消息补群 ID；App 只把 `@chatroom` 当群，且新增
  `MemoryStore.repairMisroutedConversations` 在启动时把可确定目标的历史消息归位、
  删除空会话（幂等）。
- **私聊自消息误路由**：手机同步/历史回放的自消息不再进入「自己 wxid」会话，
  私聊/群聊均按 `target_id` 归位，历史数据启动时幂等修复。
- **会话名显示 wxid**：4.1.15 入站事件只带 wxid，而 App 曾把 `sender.nickname` 直接写成标题
  （群聊标题也会被写成「群聊 &lt;id&gt;」）。现在只在昵称可读时学习标题、自己消息不参与命名；
  展示层统一兜底为系统账号中文名或 `群聊 / 微信好友 / 公众号 · 尾号`，
  历史 ID 标题在启动时由 `MemoryStore.repairPlaceholderConversationTitles` 清理。
- **群聊 @ 漏触发**：兼容 `<atuserlist>` 的 CDATA/嵌套格式，bridge 显式保留
  `mentions` / `msg_type`，App 用机器人群昵称做纯文本 @ 兜底。
- **设置窗口闪退**：设置场景缺少 `ToastCenter` 环境对象导致 `EXC_BREAKPOINT`（已修复）。
- **拍一拍**：`from/to` 均为群 ID 的 appmsg 不再被误判为「自己发出」，并提取 `<title>` 文本。
- **拍一拍误唤醒（2026-10-21）**：不再把「群里 A 拍了拍 B」或普通聊天正文里的「拍了拍」
  当成唤醒；现在以 `<patinfo>` 的 `pattedusername` 为准，只有拍的是机器人本身才触发。
  私聊保留「拍了拍我」兜底，群聊需正文含 selfID 或已学到的群昵称。
- **拍一拍不触发（2026-10-21 真机）**：持久化的 `onebot.self_id` 被历史/Mock 事件污染后
  会通过 `-self_id` 覆盖 bridge 的真实账号，使 `get_login_info` 与 `pat_target_wxid`
  对不上。现在启动 bridge 前用 `image_path` 的 `xwechat_files/<账号>_xxx` 校验 selfID，
  不一致就不传、由 bridge 重新推导；入站事件只在 selfID 为空时兜底学习。
- **原生回拍真机失败（2026-10-21）**：`newsendmsg` 种子任务构造的 sendappmsg 请求
  显示提交成功（`slot13 -> 0`、worker result=1），但收件端收不到拍一拍；该能力已整体移除，
  详见「变更」中的「移除原生拍一拍回拍」。
- **设置兼容**：拍一拍设置放在可选 `bot.pat` 结构中，旧 `config.json` 缺键不会导致
  整份配置解码失败/重置。
- **R3 误报失败**：跳过 buf2resp 等待后不再返回 HTTP 500 send timeout；接收链路不受影响。
- **微信上滑历史卡顿**：`hook/script.js` 的 `isReadablePointer` 不再调用
  `Process.findRangeByAddress`（每轮都会枚举进程内存映射，微信里单次 20–50ms），改为
  试读 1 字节；Message finalizer 先去重再读字符串、私聊跳过群专用字段、逐条 `console.log`
  改为 `HOOK_DEBUG` 开关。历史回放从约 1 条/秒恢复到成批到达，详见 `docs/performance.md` §7。
- **R3 重启后状态误报**：bridge/App 重启时发送句柄已从 `r3-seed.json` 恢复，但 App 只解析
  「捕获闭包」日志，Hook 卡片仍显示「R3 等待信号」并提示手动发消息；现解析恢复/过期日志、
  同步 `r3Seeded` 与提示文案（仅微信重启后需要手动发送），见 `docs/hook-r3-native-send.md` §10.8。

### 安全

- 运行期 Hook 配置与仓库版本 JSON 分离：仓库保持 `enableSend=false` / `req2bufSendMode=off`，
  R3 只由 App 设置开启。
- 通讯录密钥只在内存与 bridge 缓存文件中出现，不写日志；日志只打印 salt 前 8 位与是否命中。
- 新增 `.gitignore` 与文档层面的隐私检查（真实 wxid / 聊天记录 / 截图 / Key 不入库）。

## [1.0.0] — 2026-10-20

### 新增

- macOS 原生 SwiftUI 微信 AI 助手：Frida Gadget 注入官方微信（唯一实例），
  Go OneBot bridge + `hook/script.js` 底层收发，OpenAI 兼容模型生成拟人化回复。
- 9 个侧边栏页面（总览/会话/机器人/AI 模型/人格/记忆/定时任务/日志/设置）+ 首次向导、
  菜单栏面板、Dock 图标开关、关闭窗口即隐藏。
- 私聊自动回复、群聊 @ / 关键词 / 拍一拍触发、统一白/黑名单、冷却、限流、工作时段。
- 记忆系统：10 条短期窗口 + 批量长期总结 + 记忆文件夹 + 核心记忆作用域。
- 多 AI 通道（DeepSeek / OpenAI / Ollama / 自定义兼容）、Keychain 保存 Key。
- 定时主动消息、实时会话看板、运行日志、防睡眠（三档）。
- 微信 4.1.12.53 legacy 收发；4.1.15.55 Message finalizer 接收 + R3 原生发送（文本私聊真机验证）。
- 安装/备份/重签工具链、App 打包脚本、ad-hoc 签名、Mock 联调工具、GPL-3.0 合规说明。

### 已知限制

- 4.1.12 的图片/文件下载 hook 缺失，媒体下载链路未完成；只支持单条回复（多段默认关闭）。
- 发送绕过微信本地 DB，Mac 端不回显；R3 首次使用需本机手动发一条消息捕获句柄。
- 仅支持微信 4.1.12.53 / 4.1.15.55 与 Apple Silicon + macOS 26+。

[Unreleased]: https://github.com/<owner>/ChatBot/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/<owner>/ChatBot/releases/tag/v1.0.0
