# 变更日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与
[语义化版本](https://semver.org/lang/zh-CN/)。日期格式：YYYY-MM-DD。
Hook / 微信版本相关的变更会注明目标微信版本与验证方式。

## [Unreleased] — 2026-10-21

### 新增

- **稳定性与崩溃取证**：`CrashReporter`（未捕获异常报告、会话面包屑、主线程看门狗）、
  `AppKitLayoutGuard`（显示周期断言安全阀），详见 `docs/performance.md`。
- **回复进度倒计时**：`ReplyProgressBar`，会话详情头部、输入区与会话行同步显示
  AI 生成 / 拟人化等待 / 发送中 / 完成 / 失败状态。
- **日志批量管道** `LogPipeline`：200ms 批量刷新、ANSI 清理、UI 与 SQLite 节流。
- **自消息方向字段**：hook 上报 `from_wxid` / `to_wxid` / `sender_wxid`，bridge 输出
  `is_self` / `target_id`；App 用权威 selfID 归位会话，并新增
  `MemoryStore.repairSelfRoutedMessages` 一次性修复历史误路由。
- **bridge**：`incoming.go` 入站事件归一化、`r3seed.go` 发送句柄按微信 PID 持久化；
  新增 `incoming_msg_test.go`、`incoming_normalize_test.go`、`MessageRoutingTests`。
- **文档**：新增 `docs/development.md`（开发手册）、`AGENTS.md`（AI 代理指南）、
  `docs/performance.md`、本变更日志；`scripts/check.sh`、`scripts/check_docs.py`、
  `scripts/sync_hook_script.sh`、根 `Makefile`。

### 变更

- **记忆**：窗口外批量总结阈值从 20 条调整为 8 条，总结上限 600 字并自动压缩；
  核心记忆按所属会话/全局作用域生效，手写编辑不被自动总结覆盖（`docs/memory.md`）。
- **bridge 日志外置**：写到 `~/Library/Logs/WeChatAI/bridge/macos.log`，不再写入 app bundle
  （避免 ad-hoc 签名失效导致下次启动被杀）。
- **发送延迟**：bridge `-send_interval` 收紧到 100ms；R3 文本发送不再等待 buf2resp，
  避免「已送达却返回 send timeout」的误报。
- **脚本**：`fetch_gadget.sh` 对 Frida Gadget 17.8.0 校验压缩包与 dylib 的 SHA256；
  `clean.sh` 修正 `dist/` 保留语义并新增 `__pycache__` 清理；Go/Hook 构建产物一致性检查
  统一到 `scripts/check.sh`。
- **文档数字与索引**：Swift 测试 58 项、Go 14 项；`docs/README.md` 增加开发手册与
  AI 代理指南入口；`bridge/NOTICE` 更新为实际修改/新增文件清单。

### 修复

- **私聊自消息误路由**：手机同步/历史回放的自消息不再进入「自己 wxid」会话，
  私聊/群聊均按 `target_id` 归位，历史数据启动时幂等修复。
- **群聊 @ 漏触发**：兼容 `<atuserlist>` 的 CDATA/嵌套格式，bridge 显式保留
  `mentions` / `msg_type`，App 用机器人群昵称做纯文本 @ 兜底。
- **设置窗口闪退**：设置场景缺少 `ToastCenter` 环境对象导致 `EXC_BREAKPOINT`（已修复）。
- **拍一拍**：`from/to` 均为群 ID 的 appmsg 不再被误判为「自己发出」，并提取 `<title>` 文本。
- **R3 误报失败**：跳过 buf2resp 等待后不再返回 HTTP 500 send timeout；接收链路不受影响。

### 安全

- 运行期 Hook 配置与仓库版本 JSON 分离：仓库保持 `enableSend=false` / `req2bufSendMode=off`，
  R3 只由 App 设置开启。
- 新增 `.gitignore` 与文档层面的隐私检查（真实 wxid / 聊天记录 / 截图 / Key 不入库）。

## [1.0.0] — 2026-10-20

### 新增

- macOS 原生 SwiftUI 微信 AI 助手：Frida Gadget 注入官方微信（唯一实例），
  Go OneBot bridge + `hook/script.js` 底层收发，OpenAI 兼容模型生成拟人化回复。
- 10 个页面（总览/会话/机器人/AI 模型/人格/记忆/定时任务/日志/设置/首次向导）、
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

[Unreleased]: https://github.com/your-org/ChatBot/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/your-org/ChatBot/releases/tag/v1.0.0
