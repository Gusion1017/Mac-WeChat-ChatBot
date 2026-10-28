# 微信 AI 助手（WeChat AI）

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](#简体中文)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)](app/Package.swift)
[![Go](https://img.shields.io/badge/Go-1.25-00ADD8.svg)](bridge/go.mod)

macOS 原生微信 AI 助手：用 Frida Gadget 注入官方微信（唯一实例），消息经 Go OneBot bridge
接入 SwiftUI App，由 DeepSeek / OpenAI 兼容模型生成拟人化回复。

A native macOS WeChat AI assistant: injects the official WeChat client with Frida Gadget
(single instance), bridges messages through a Go OneBot bridge into a SwiftUI app, and writes
human-like replies with DeepSeek / any OpenAI-compatible model.

> GPL-3.0 · 个人自用 / 学习研究 · 改微信有签名失效与账号风险 · 与腾讯、Apple 无关联
> GPL-3.0 · personal / learning project · patching WeChat carries signature and account risk · not affiliated with Tencent or Apple

> 本文件含 **简体中文** 与 **English**，向下滚动切换。
> This README ships in **Simplified Chinese and English** — scroll down for English.

---

## 简体中文

### 功能

- **私聊自动回复**；**群聊触发可多选**（@ / 关键词 / 拍一拍 / 引用机器人；拍一拍只认「拍机器人」，
  可 @ 拍的人；「引用机器人」默认可选，别人引用机器人的消息时唤醒）；
  **唤醒后免唤醒词**（默认关闭，同一发送者在 1–60 分钟窗口内继续发言无需再次唤醒）
- **白 / 黑名单**（会话 ID 或 wxid）、冷却、每分钟限流、工作时段，均可按会话覆盖
- **按会话选择人格** / 通道与模型覆盖，温度按模型配置；DeepSeek、OpenAI、Ollama 或任意 OpenAI 兼容端点
- **记忆 v2（2026-10-28）**：一个微信会话一个记忆卡目录（`characters/<会话>/memory.sqlite`）；
  人格统一来自「人格设定」（会话只记录绑定，不再每会话复制 `persona.md`）；
  事实/决策/待办/经验四类记忆，最近 72h/重要/关键词相关
  加权召回（新卡默认空，机器人回复后自动提取）；0.92 相似度自动折叠、冲突 supersede 留档、
  普通 30 天/重要 180 天半衰期与自动归档；
  每 N 条互动后台批量 AI 提取，全量互动永久保存；另有固定**全局共享记忆**
  （`characters/c-__global__/`，手动维护、注入所有会话、不自动提取且不可删除）；
  App 记忆面板支持查看/编辑/置顶/压缩/导出（Markdown/JSON），旧记忆手动导入；
  聊天记录清理在具体会话内操作（只删本地消息，不动记忆卡/全量记录），不开放微信 `/记忆` 指令。
  详见 [`docs/memory.md`](docs/memory.md)
- **多微信账号数据隔离**：聊天记录、记忆卡（角色目录）、会话设置、机器人配置、人格、定时任务与新媒体
  按当前微信账号自动切换；AI 模型、Hook、OneBot、Keychain、语音模型与文件日志全局共享。
  升级旧版时旧单库/旧媒体只复制保留、不删除；运行中换号会停止机器人，需手动重新启动。
  详见 [`docs/accounts.md`](docs/accounts.md)
- **拟人化延迟**、回复进度倒计时、防睡眠、定时主动消息、实时会话看板、会话重命名/置顶/删除聊天（仅本机）、运行日志
- **设备与账户**：总览「设备与账户」卡与菜单栏弹层显示本机电池电量 / 充电状态 / 剩余时间
  （IOKit，30 秒刷新）和 DeepSeek 账户余额（总额、赠送/充值、可用状态；启动查询 + 每 5 分钟刷新，
  可手动刷新；Key 读取自 Keychain 中的 DeepSeek 通道，未配置时给出去 AI 模型页的入口）
- **聊天图片获取**（按会话开关，会话详情 → 菜单 →「媒体」；默认开启，关闭后只显示「图片」占位）：
  收到图片时自动从微信下载、解密并保存到本机媒体目录，会话里直接显示；**识图模型**
  （AI 模型页配置，可单独指定视觉通道/模型）对近期入站图片生成文字描述，作为回复上下文，
  描述显示在图片下方；引用图片时会把被引用原图的内容描述带入本轮回复
- **语音转写（本地）**：收到的语音消息经 Apple 本地 Speech 框架（SpeechAnalyzer）转成文字，
  气泡展示/进上下文与记忆，可逐项关闭；**语音回复（本地 TTS）**：sherpa-onnx + Kokoro
  （官方 103 个内置音色，按中文女声/中文男声/英文女声分组，可搜索与试听）、ZipVoice
  （零样本克隆）或 CosyVoice3（可选本地大模型旁路，需额外安装约 8GB；**App 不内置任何音色**，
  可在「管理音色」导入 5–30s 参考音新增/编辑/删除/试听），
  模型按当前引擎按需下载（确认体积、可取消/重试/删除），支持语速、语音时长/
  概率/对等/短回复设置；已确定改发语音时默认跳过拟人化延迟（可关闭）；语音设置位于「机器人」页。
  > 4.2.0.5 已真机打通语音**下载/转写与发送**；出站使用官方 SILK SDK 的 24k WeChat 兼容编码。
  > 首次启用/微信重启后需手动发一条文字 + 一条语音捕获句柄，bridge 重启自动恢复；
  > 首次开启语音回复或 bridge 启动检测到句柄缺失时会自动弹出捕获引导。详见 [`docs/voice.md`](docs/voice.md)。
- **4.1.15.55 / 4.2.0.5 / 4.2.0.9 R3 原生文本发送**（设置内开关，无句柄时自动排队）；**通讯录真实昵称 / 群名**（本机只读）
- **机器人页 6 个子栏目**：常规 / 触发 / 互动 / 名单 / 节奏 / 语音，工具栏下方 sticky 分栏条，
  切换回填顶部、按窗口记忆上次子栏目
- **首启向导环境检查**：显示 Xcode Command Line Tools 状态，可一键「安装 Command Line Tools」
  （`xcode-select --install`）并「重新检测」；CLT 未就绪时禁用 Hook 安装
- **中 / 英双语界面**；原生 Liquid Glass 风格、菜单栏常驻（**左键开合状态面板**）；无 WebView / Electron

### 状态

| 模块 | 状态 |
| --- | --- |
| SwiftUI App / Swift 核心 | ✅ 504 项测试（8 项按环境跳过：模型未下载/联网/真实 E2E）；4.1.15.55 / 4.2.0.5 文本真机 E2E |
| OneBot bridge（Go） | ✅ 构建 / 鉴权 / 真机附加 / 64 顶层 · 76 子测试通过 |
| 首启向导 / 安装 | ✅ CLT 检测与安装引导、微信版本 / Hook 预检、备份约 665MB（磁盘需 ≥2.5GB） |
| 微信 4.1.12.53 | ✅ legacy 收发 + 主动发送 |
| 微信 4.1.15.55 | ✅ Message finalizer 接收 + R3 文本发送（首次需在本机微信手动发一条消息捕获句柄） |
| 微信 4.2.0.5 | ✅ 真机验证（2026-10-22/23）：私聊/自消息入站、通讯录、R3 文本发送（含 bridge 重启句柄恢复）、**图片获取**（自然分片优先/按需触发 + 解密，HEVC 走缩略图）；群聊 @ / 拍一拍沿用既有逻辑未单独复测 |
| 微信 4.2.0.9 | ✅ 适配并完成文本真机验证（2026-10-27）：新增 `hook/versions/4_2_0_9_mac.json`、版本门禁与脚本默认目标；Gadget 注入/重签、通讯录解密、入站事件、R3 文本发送均通过；语音发送与媒体/群聊 @ 未复测 |

环境：Apple Silicon、macOS 26+；微信须为 4.2.0.9 (270345) / 4.2.0.5 (270341) / 4.1.15.55 (270135) / 4.1.12.53 (269365)
之一，默认位于 `/Applications/WeChat.app` 且当前用户可写；**安装 Hook 需 Xcode Command Line Tools**
（`xcode-select --install`；完整 Xcode 亦可，不需要 Apple 开发者账号）；从源码构建另需 Xcode 27。

### 架构

```
WeChatAI.app (SwiftUI)          bridge/onebot (Go)              WeChat.app
  UI / 规则 / 人格 / 记忆   ←→   frida-core → Gadget 127.0.0.1:27042 →  hook/script.js
  OneBotClient 127.0.0.1:58080                                    （ad-hoc 重签，唯一实例）
```

契约见 [`docs/architecture.md`](docs/architecture.md)，文档索引 [`docs/README.md`](docs/README.md)。

### 快速开始

- **普通用户**：下载 [`WeChat-AI-1.7.0.zip`](https://github.com/Gusion1017/Mac-WeChat-ChatBot/releases/download/v1.7.0/WeChat-AI-1.7.0.zip)
  （约 72 MB，[SHA256](https://github.com/Gusion1017/Mac-WeChat-ChatBot/releases/download/v1.7.0/WeChat-AI-1.7.0.zip.sha256)），
  按下面步骤安装；历史版本见 [Tags](https://github.com/Gusion1017/Mac-WeChat-ChatBot/tags)。

  1. 解压得到 `WeChat AI.app`，拖到 `~/Applications`（当前用户，无需管理员）或 `/Applications`（所有用户）。
  2. 双击启动会被 Gatekeeper 拦截（App 为 ad-hoc 签名、未公证）。**macOS 15 起（含 26）已取消
     “右键 → 打开”的绕过方式**：打开「系统设置 → 隐私与安全性」，在底部点「仍要打开」，
     按提示输入管理员密码 / Touch ID。若列表中没有条目，或在终端移除 quarantine
     （路径换成实际安装位置）：

     ```bash
     xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
     open "$HOME/Applications/WeChat AI.app"

     # 安装在 /Applications 时（需要管理员）：
     # sudo xattr -dr com.apple.quarantine "/Applications/WeChat AI.app"
     # open "/Applications/WeChat AI.app"
     ```
  3. App **默认显示 Dock 图标**，同时常驻菜单栏：**左键单击菜单栏图标开合状态面板**（面板内提供打开主窗口、启动/停止机器人、设置、退出）；
     可在「设置 → 通用」关闭 Dock 图标、改用菜单栏入口。
  4. 首次启动向导：检查 Xcode Command Line Tools（未安装可点「安装 Command Line Tools」并「重新检测」，
     未就绪时 Hook 安装按钮禁用）→ 检测微信（版本须精确匹配）→ 完全退出微信后备份并安装 Hook
     （备份约 665MB、1–2 分钟，磁盘预留 ≥2.5GB）→ 配置 AI → 启动。安装后需**手动打开并登录微信**；
     拒绝「App 数据」授权会导致图片/语音相关功能与 `image_path` 检测失败。
  5. 首次发送（4.1.15.55 / 4.2.0.5 / 4.2.0.9 的 R3 原生发送）：在本机微信手动发一条消息捕获发送句柄
     （语音还需发一条语音），否则回复会排队。完整步骤与还原方式见 [`docs/install.md`](docs/install.md)。

- **从源码构建**（需 Xcode 27）：

```bash
git clone https://github.com/Gusion1017/Mac-WeChat-ChatBot.git && cd Mac-WeChat-ChatBot
bash scripts/fetch_gadget.sh     # Frida Gadget 17.8.0（校验 SHA256）
bash scripts/build_bridge.sh     # Go 1.25 构建 + Go 测试
bash scripts/build_app.sh        # 生成 dist/WeChat AI.app（缺 TTS 静态库时自动 fetch_sherpa）
bash scripts/install_app.sh      # 安装到 ~/Applications（移除 quarantine 并重签）
```

只想本地联调、不碰微信：`devtools/mock_onebot.py --demo` + `mock_ai.py`，见
[`devtools/README.md`](devtools/README.md)。

### 手动管理 Hook

```bash
bash tools/manage_wechat.sh status    # 版本 / 运行 / 注入 / 备份状态
bash tools/manage_wechat.sh backup    # 完整备份官方 App
bash tools/manage_wechat.sh install   # 注入 Gadget + ad-hoc 重签
bash tools/manage_wechat.sh restore   # 还原官方 App
```

`install` 前需完全退出微信（含菜单栏图标），并确保已安装 Xcode Command Line Tools
（提供 `/usr/bin/python3` 与 `/usr/bin/otool`）。安装会先完整备份（约 665MB，磁盘预留 ≥2.5GB），
App 内可在 设置 → Hook → 还原官方微信 一键还原（还原前先退出微信）。
当前脚本默认目标是微信 4.2.0.9 (270345)；历史 4.2.0.5 (270341) / 4.1.15.55 / 4.1.12.53 仍在已知支持列表，
可直接安装（版本文件保留），其他版本可用 `WECHAT_SUPPORTED_VERSION` / `WECHAT_SUPPORTED_BUILD` 覆盖。
修改会破坏微信官方签名，微信升级后可能失效；存在账号风控风险。

### 目录结构

```
app/        SwiftUI App（SwiftPM）+ 504 项测试；app/Vendor/（sherpa-onnx 静态库）不入库
bridge/     Go OneBot 桥接（GPL-3.0 衍生，改动见 NOTICE）；silkenc/ SILK 编码，testdata/ 测试样本
hook/       script.js（唯一事实来源）与版本地址表
tools/      Hook 安装、备份、还原
scripts/    构建、打包、安装、自检（fetch_sherpa.sh 下载 TTS 静态库）
devtools/   本地 Mock（无需微信 / Frida）
docs/       架构、契约、记忆与 UI 设计
LICENSES/   第三方许可全文（Apache-2.0 / SILK SDK / Frida wxWindows 等，随 App 分发）
dist/       发布产物（zip / sha256，不入库）
```

可重建、不入库：`app/.build*`、`app/Vendor/`、`bridge/onebot`、`dist/`、`bridge/log/`、
`hook/gadget/FridaGadget.dylib`、`_research/`、`_local/`。`dist/` 只保留在本地用于发布，不提交到仓库。

### 开发与测试

```bash
bash scripts/check.sh               # 静态检查 + Swift 测试
bash scripts/build_bridge.sh        # Go 构建 + Go 测试
bash scripts/fetch_sherpa.sh        # sherpa-onnx 静态库（build_app 会自动补）
bash scripts/package_release.sh     # Releases 用 zip + sha256
make release                        # 同上：构建 → 打包 → 签名校验 → sha256
```

发布产物为 `dist/WeChat-AI-1.7.0.zip`（约 72MB）与 `.sha256`。打包脚本会自动
`codesign --verify --strict`；`spctl -a -vv` 对 ad-hoc 未公证包预期返回 `rejected`（属正常），
分发前在 `dist/` 内用 `shasum -a 256 -c WeChat-AI-1.7.0.zip.sha256` 校验。

改了 `hook/script.js` 记得跑 `bash scripts/sync_hook_script.sh`。接口 / 行为变更先改 `docs/` 再改代码。
GitHub Actions 只跑 Linux 可完成的检查（文档链接、脚本语法、副本一致、无构建产物）。

### 隐私与安全

- 消息 / 记忆 / 日志只存本机；无遥测、无云端同步；API Key 存 macOS Keychain
- 本地服务只监听 `127.0.0.1`；仓库不含真实 wxid、群 ID、聊天原文、截图或密钥
- 安全与隐私问题请走私密渠道，不要开公开 issue

### 风险

- **语音功能**：入站下载/转写与出站发送均已真机验证；出站用官方 SILK SDK 的 24k WeChat 兼容编码。
  首次启用或微信重启后需手动发一条文字 + 一条语音捕获句柄；bridge 启动 60 秒内 CdnManager 未就绪时会降级。
  首次启用需下载约 528MB 模型（需联网并同意；失败自动降级文字），系统中文语音资源可能需在系统设置下载。
  详见 [`docs/voice.md`](docs/voice.md)。
- **权限**：首次读取微信容器会触发「App 数据」授权，拒绝则图片/语音相关功能与 `image_path` 检测失败；
  修改微信 bundle 可能需要「App 管理」授权。App 不请求麦克风 / 语音识别 / 自动化权限。
- **微信与安装位置**：Hook 只支持 3 个精确版本，默认 `/Applications/WeChat.app`，当前用户需可写；
  App Store 版微信的路径/签名不同，可能不适用。
- **备份与还原**：安装前会完整备份（约 665MB，磁盘预留 ≥2.5GB）；可在 设置 → Hook → 还原官方微信
  （还原前先完全退出微信）。
- **改微信的风险**：修改 `/Applications/WeChat.app` 会破坏官方签名，**微信更新后可能失效**；
  存在账号风控风险，建议仅用个人测试账号。

### 参与贡献

- 贡献流程：[`CONTRIBUTING.md`](CONTRIBUTING.md)
- 行为准则：[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- 私密报告安全问题：[`SECURITY.md`](SECURITY.md)
- 获取帮助：[`SUPPORT.md`](SUPPORT.md) · [Issues](https://github.com/Gusion1017/Mac-WeChat-ChatBot/issues)

### 许可

GPL-3.0，见 [`LICENSE`](LICENSE)。基于
[yincongcyincong/weixin-macos](https://github.com/yincongcyincong/weixin-macos)、
[xiaoguiwucan/wechat-mac-hook](https://github.com/xiaoguiwucan/wechat-mac-hook) 与
[Frida](https://frida.re)（LGPL-2.1），详见 [`ThirdPartyNotices.txt`](ThirdPartyNotices.txt)。
仅供学习研究，请遵守微信用户协议与当地法律。

---

## English

### Features

- **Automatic private-chat replies**; **multi-select group triggers** (@ / keyword / pat-pat / quote —
  only pats on the bot count, and it can @ the person who patted; the optional quote trigger wakes
  the bot when someone quotes its message); **no wake word after wake-up** (off by default; the same
  sender can keep chatting for a 1–60 minute window)
- **Allow / block lists** (conversation ID or wxid), cooldown, per-minute rate limit and working
  hours, all overridable per conversation
- **Per-conversation persona selection** plus channel and model overrides, with temperature
  configured per model; DeepSeek, OpenAI, Ollama or any OpenAI-compatible endpoint
- **Memory v2 (2026-10-28)**: one memory-card directory per WeChat conversation
  (`characters/<conversation-key>/memory.sqlite`); persona comes from the single "Persona"
  settings template (conversations only store the binding — no per-conversation `persona.md`);
  typed memories (fact/decision/todo/lesson) recalled by last 72 h → important → keyword
  relevance (new cards start empty and fill from extracted replies); ≥0.92 similarity auto-merge,
  conflicting memories kept via supersede,
  30/180-day half-lives with auto-archiving; background AI extraction every N messages plus a full
  interaction archive. A fixed **global shared memory** card (`characters/c-__global__/`) is
  manually maintained and injected into every conversation (never auto-extracted, cannot be
  deleted). The App memory panel supports view/edit/pin/compress/export (Markdown/JSON), manual
  legacy import; chat cleanup is per-conversation (local messages only, cards/archive untouched);
  no WeChat `/memory` command. See [`docs/memory.md`](docs/memory.md)
- **Multi-account data isolation**: chats, memory cards (character directories), conversation
  settings, bot config, personas, schedules and new media automatically follow the current WeChat
  account, while AI models, hook, OneBot, Keychain, voice models and file logs stay global.
  Upgrading copies the legacy database/media without deleting them; a running bot stops on account
  switch and must be restarted manually. See [`docs/accounts.md`](docs/accounts.md)
- **Human-like delay**, reply progress countdown, sleep prevention, scheduled messages, live
  conversation board and runtime logs
- **Device & Account**: the Overview card and menu-bar popover show the Mac's battery percentage,
  charging state and remaining time (IOKit, 30 s refresh), plus the DeepSeek account balance (total,
  granted/topped-up amounts, availability; queried at launch, refreshed every 5 minutes and on demand,
  using the DeepSeek channel key from the Keychain; unconfigured states link to AI Models)
- **Chat image fetch** (per-conversation switch under the conversation menu → "Media"; on by
  default, off keeps only the "图片" placeholder): incoming images are downloaded from WeChat,
  decrypted and saved into the local media directory, then shown inline. The **vision model**
  (configured under AI Models, with an optional vision channel/model) describes recent incoming
  images as text for reply context; the description is shown below the image. Quoting an image
  brings the referenced image's description into the current reply.
- **Voice transcription (local)**: incoming voice messages are transcribed on-device with Apple's
  Speech framework (SpeechAnalyzer) for bubbles/context/memory, each part toggleable; **voice replies
  (local TTS)** use sherpa-onnx + Kokoro (103 built-in voices grouped as Chinese female/male and
  English female, with search and preview), ZipVoice (zero-shot cloning) or CosyVoice3 (optional
  local LLM sidecar, ~8 GB extra install; **the app ships no voices** — add your own 5–30s reference
  audio, then edit/delete/preview). Models download per engine on demand (size confirmation,
  cancel/retry/delete) with speed, duration/probability/mirroring settings; voice replies skip the
  humanize delay by default (toggleable in voice settings).
  > Voice download/transcription and sending are verified on WeChat 4.2.0.5. Outbound uses the official SILK SDK
  > with WeChat-compatible 24k encoding. Handle capture is documented in [`docs/voice.md`](docs/voice.md).
- **4.1.15.55 / 4.2.0.5 / 4.2.0.9 R3 native text sending** (toggle in Settings, auto-queues without a send handle);
  **real contact nicknames / group names** (local, read-only)
- **Six bot sub-tabs**: General / Triggers / Interaction / Lists / Pacing / Voice, with a sticky tab bar,
  scroll-to-top on switch and per-window tab memory
- **First-run environment check**: shows Xcode Command Line Tools status, offers an
  "Install Command Line Tools" button (`xcode-select --install`) and "Check Again"; hook installation is
  disabled until CLT is ready
- **Chinese / English UI**; native Liquid Glass look, menu-bar app (**left-click toggles the status panel**); no WebView / Electron

### Status

| Component | Status |
| --- | --- |
| SwiftUI app / Swift core | ✅ 504 tests (8 environment-gated skips: models not downloaded / network / live E2E); text E2E on 4.1.15.55 / 4.2.0.5 |
| OneBot bridge (Go) | ✅ builds / auth / device attach / 64 top-level · 76 subtest cases passing |
| First-run wizard / install | ✅ CLT detection and install guidance, WeChat version / hook preflight, ~665MB backup (needs ≥2.5GB disk) |
| WeChat 4.1.12.53 | ✅ legacy send + receive |
| WeChat 4.1.15.55 | ✅ Message-finalizer receive + R3 text sending (send one message in WeChat once to capture the handle) |
| WeChat 4.2.0.5 | ✅ Real-device verified (2026-10-22/23): private-chat/self-message receive, contact directory, R3 text sending incl. bridge-restart handle recovery, **image fetch** (natural chunks first / on-demand trigger + decryption, thumbnail fallback for HEVC); group @ / pat-pat reuse existing logic and were not separately retested |
| WeChat 4.2.0.9 | ✅ Adapted and text-verified (2026-10-27): new `hook/versions/4_2_0_9_mac.json`, version gates and script defaults updated; Gadget injection/re-sign, contact decryption, inbound events and R3 text sending passed; voice sending, media and group @ were not retested |

Requirements: Apple Silicon, macOS 26+; WeChat must be exactly 4.2.0.9 (270345), 4.2.0.5 (270341),
4.1.15.55 (270135) or 4.1.12.53 (269365), installed at `/Applications/WeChat.app` (default) and writable by the current
user; **hook installation requires Xcode Command Line Tools** (`xcode-select --install`; full Xcode
also works, no Apple Developer account needed). Building from source additionally needs Xcode 27.

### Architecture

```
WeChatAI.app (SwiftUI)          bridge/onebot (Go)              WeChat.app
  UI / rules / personas / memory ←→  frida-core → Gadget 127.0.0.1:27042 →  hook/script.js
  OneBotClient 127.0.0.1:58080                                            (ad-hoc re-signed)
```

Contracts in [`docs/architecture.md`](docs/architecture.md); document index in
[`docs/README.md`](docs/README.md).

### Quick Start

- **Regular users**: download
  [`WeChat-AI-1.7.0.zip`](https://github.com/Gusion1017/Mac-WeChat-ChatBot/releases/download/v1.7.0/WeChat-AI-1.7.0.zip)
  (~72 MB, [SHA256](https://github.com/Gusion1017/Mac-WeChat-ChatBot/releases/download/v1.7.0/WeChat-AI-1.7.0.zip.sha256))
  and follow these steps; older versions are on [Tags](https://github.com/Gusion1017/Mac-WeChat-ChatBot/tags).

  1. Unzip `WeChat AI.app` and drag it to `~/Applications` (current user, no admin) or
     `/Applications` (all users).
  2. Double-clicking is intercepted by Gatekeeper (the app is ad-hoc signed, not notarized).
     **macOS 15+ (including 26) removed the old right-click → Open bypass**: open
     System Settings → Privacy & Security, click "Open Anyway" at the bottom and confirm with an
     admin password / Touch ID. If no entry appears, remove the quarantine flag (use the real path):

     ```bash
     xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
     open "$HOME/Applications/WeChat AI.app"

     # Installed in /Applications (needs admin):
     # sudo xattr -dr com.apple.quarantine "/Applications/WeChat AI.app"
     # open "/Applications/WeChat AI.app"
     ```
  3. The app **shows a Dock icon by default** and also lives in the menu bar: **left-click the menu-bar
     icon to toggle the status panel** (open the main window, start/stop the bot, settings, quit are all
     inside the panel); turn the Dock icon off under Settings → General if you prefer a menu-bar-only app.
  4. First-run wizard: check Xcode Command Line Tools (install it from the wizard and click
     "Check Again"; hook installation stays disabled until CLT is ready) → detect WeChat (exact version
     required) → fully quit WeChat, then back up and install the hook (~665MB backup, 1–2 minutes,
     reserve ≥2.5GB disk) → configure AI → start. Afterwards **open and log in to WeChat manually**;
     denying the "App Data" permission breaks image/voice features and `image_path` detection.
  5. First send (R3 native sending on 4.1.15.55 / 4.2.0.5 / 4.2.0.9): manually send one message in WeChat to
     capture the send handle (send a voice message too for voice replies), otherwise replies queue.
     Full steps and restore instructions are in [`docs/install.md`](docs/install.md).

- **Build from source** (Xcode 27 required):

```bash
git clone https://github.com/Gusion1017/Mac-WeChat-ChatBot.git && cd Mac-WeChat-ChatBot
bash scripts/fetch_gadget.sh     # Frida Gadget 17.8.0 (SHA256 verified)
bash scripts/build_bridge.sh     # Go 1.25 build + Go tests
bash scripts/build_app.sh        # builds dist/WeChat AI.app (fetches sherpa libs if missing)
bash scripts/install_app.sh      # installs to ~/Applications (clears quarantine, re-signs)
```

Local integration testing without WeChat: `devtools/mock_onebot.py --demo` + `mock_ai.py` — see
[`devtools/README.md`](devtools/README.md).

### Managing the Hook Manually

```bash
bash tools/manage_wechat.sh status    # version / running / injected / backup state
bash tools/manage_wechat.sh backup    # full backup of the official app
bash tools/manage_wechat.sh install   # inject Gadget + ad-hoc re-sign
bash tools/manage_wechat.sh restore   # restore the official app
```

Quit WeChat completely (including the menu-bar icon) before `install`, and make sure Xcode Command
Line Tools are installed (`/usr/bin/python3` and `/usr/bin/otool`). The installer backs up the official
app first (~665MB; reserve ≥2.5GB disk), and the app offers one-click restore under
Settings → Hook → Restore Official WeChat (quit WeChat first). Patching breaks WeChat's official
signature and may stop working after a WeChat update; unofficial clients also carry account risk.
The scripts target WeChat 4.2.0.9 (270345) by default; the historical 4.2.0.5 / 4.1.15.55 / 4.1.12.53
remain in the known-supported list and install directly (their version files are kept); use
`WECHAT_SUPPORTED_VERSION` / `WECHAT_SUPPORTED_BUILD` to override for other builds.

### Repository Layout

```
app/        SwiftUI app (SwiftPM) + 504 tests; app/Vendor/ (sherpa-onnx static libs) is not committed
bridge/     Go OneBot bridge (GPL-3.0 derivative, changes listed in NOTICE); silkenc/ official SILK encoder, testdata/
hook/       script.js (single source of truth) and version address tables
tools/      hook install, backup and restore
scripts/    build, package, install, self-check (fetch_sherpa.sh downloads TTS static libs)
devtools/   local mocks (no WeChat / Frida needed)
docs/       architecture, contracts, memory and UI design
LICENSES/   third-party license texts (Apache-2.0 / SILK SDK / Frida wxWindows, bundled with the app)
dist/       release artifacts (zip / sha256, not committed)
```

Rebuildable, never committed: `app/.build*`, `app/Vendor/`, `bridge/onebot`, `dist/`, `bridge/log/`,
`hook/gadget/FridaGadget.dylib`, `_research/`, `_local/`. `dist/` stays local for releases only.

### Build and Test

```bash
bash scripts/check.sh               # static checks + Swift tests
bash scripts/build_bridge.sh        # Go build + Go tests
bash scripts/fetch_sherpa.sh        # sherpa-onnx static libs (build_app fetches if missing)
bash scripts/package_release.sh     # release zip + sha256
make release                        # same: build → package → signature check → sha256
```

The release artifacts are `dist/WeChat-AI-1.7.0.zip` (~72MB) and `.sha256`. Packaging runs
`codesign --verify --strict`; `spctl -a -vv` reports `rejected` for an ad-hoc, non-notarized bundle
(that is expected). Verify before publishing with
`cd dist && shasum -a 256 -c WeChat-AI-1.7.0.zip.sha256`.

After editing `hook/script.js`, run `bash scripts/sync_hook_script.sh`. Change `docs/` before code
for interface or behaviour changes. GitHub Actions only runs Linux-friendly checks (docs links,
script syntax, copy equality, no build artifacts).

### Privacy and Security

- Messages, memory and logs stay on this Mac; no telemetry, no cloud sync; the API key lives in the
  macOS Keychain
- Local services listen on `127.0.0.1` only; the repo holds no real wxid, group ID, chat content,
  screenshots or keys
- Report security or privacy issues privately — never in a public issue

### Risks

- **Voice features**: inbound download/transcription and outbound sending are verified; outbound uses the
  official SILK SDK with WeChat-compatible 24k encoding. Handle capture and the 60s bridge warmup are documented
  in [`docs/voice.md`](docs/voice.md). The first enable downloads ~528MB of models (network + consent;
  failures fall back to text automatically); system Chinese voice assets may need downloading in System Settings.
- **Permissions**: the first read of WeChat's container triggers the "App Data" permission — denying it
  breaks image/voice features and `image_path` detection. Patching the WeChat bundle may require "App
  Management". The app never asks for microphone, speech-recognition or automation access.
- **WeChat and install location**: the hook supports exactly three WeChat versions, expects
  `/Applications/WeChat.app` and needs the current user to have write access; App Store builds use a
  different path/signature and may not work.
- **Backup and restore**: installation backs up the official app first (~665MB; reserve ≥2.5GB);
  restore from Settings → Hook → Restore Official WeChat (quit WeChat first).
- **Patching risks**: modifying `/Applications/WeChat.app` breaks its official signature and **may stop
  working after a WeChat update**; unofficial clients also carry account risk, so use a personal test account.

### Contributing

- Workflow: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Code of Conduct: [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- Report security issues privately: [`SECURITY.md`](SECURITY.md)
- Get help: [`SUPPORT.md`](SUPPORT.md) · [Issues](https://github.com/Gusion1017/Mac-WeChat-ChatBot/issues)

### License

GPL-3.0 — see [`LICENSE`](LICENSE). Built on
[yincongcyincong/weixin-macos](https://github.com/yincongcyincong/weixin-macos),
[xiaoguiwucan/wechat-mac-hook](https://github.com/xiaoguiwucan/wechat-mac-hook) and
[Frida](https://frida.re) (LGPL-2.1); see [`ThirdPartyNotices.txt`](ThirdPartyNotices.txt).
For learning and research only; comply with WeChat's terms of service and local law.
