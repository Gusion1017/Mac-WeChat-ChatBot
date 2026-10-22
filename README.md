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

- **私聊自动回复**；**群聊触发可多选**（@ / 关键词 / 拍一拍，拍一拍只认「拍机器人」，可 @ 拍的人）
- **白 / 黑名单**（会话 ID 或 wxid）、冷却、每分钟限流、工作时段，均可按会话覆盖
- **按会话人格** / 系统提示词 / 模型与温度覆盖；DeepSeek、OpenAI、Ollama 或任意 OpenAI 兼容端点
- **记忆**：10 条短期窗口 + 8 条批量总结；会话文件夹；综合权重 = 基础 × 重要度 × 召回 × 30 天半衰期，基础权重可调
- **拟人化延迟**、回复进度倒计时、防睡眠、定时主动消息、实时会话看板、运行日志
- **4.1.15.55 / 4.2.0.5 R3 原生文本发送**（设置内开关，无句柄时自动排队）；**通讯录真实昵称 / 群名**（本机只读）
- **中 / 英双语界面**；原生 Liquid Glass 风格、菜单栏常驻；无 WebView / Electron

### 状态

| 模块 | 状态 |
| --- | --- |
| SwiftUI App / Swift 核心 | ✅ 128 项测试通过；4.1.15.55 / 4.2.0.5 真机 E2E |
| OneBot bridge（Go） | ✅ 构建 / 鉴权 / 真机附加 / 60 项测试通过 |
| 微信 4.1.12.53 | ✅ legacy 收发 + 主动发送 |
| 微信 4.1.15.55 | ✅ Message finalizer 接收 + R3 文本发送（首次需在本机微信手动发一条消息捕获句柄） |
| 微信 4.2.0.5 | ✅ 真机验证（2026-10-22）：私聊/自消息入站、通讯录、R3 文本发送（含 bridge 重启句柄恢复）；群聊 @ / 拍一拍沿用既有逻辑未单独复测，媒体下载维持已知缺失 |

环境：Apple Silicon、macOS 26+；从源码构建另需 Xcode 27。

### 架构

```
WeChatAI.app (SwiftUI)          bridge/onebot (Go)              WeChat.app
  UI / 规则 / 人格 / 记忆   ←→   frida-core → Gadget 127.0.0.1:27042 →  hook/script.js
  OneBotClient 127.0.0.1:58080                                    （ad-hoc 重签，唯一实例）
```

契约见 [`docs/architecture.md`](docs/architecture.md)，文档索引 [`docs/README.md`](docs/README.md)。

### 快速开始

- **普通用户**：下载 [`WeChat-AI-1.0.0.zip`](https://github.com/Gusion1017/Mac-WeChat-ChatBot/releases/download/v1.0.0/WeChat-AI-1.0.0.zip)
  （63 MB，[SHA256](https://github.com/Gusion1017/Mac-WeChat-ChatBot/releases/download/v1.0.0/WeChat-AI-1.0.0.zip.sha256)），
  解压后**右键 → 打开**；首启向导会安装 Hook。历史版本见 [Releases](https://github.com/Gusion1017/Mac-WeChat-ChatBot/releases)，
  步骤详见 [`docs/install.md`](docs/install.md)。
- **从源码构建**（需 Xcode 27）：

```bash
git clone https://github.com/Gusion1017/Mac-WeChat-ChatBot.git && cd Mac-WeChat-ChatBot
bash scripts/fetch_gadget.sh     # Frida Gadget 17.8.0（校验 SHA256）
bash scripts/build_bridge.sh     # Go 1.25 构建 + 60 项测试
bash scripts/build_app.sh        # 生成 dist/WeChat AI.app
bash scripts/install_app.sh      # 安装到 ~/Applications
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

`install` 前需完全退出微信；安装会先完整备份，App 内可一键还原。
当前脚本默认目标是微信 4.2.0.5 (270341)；历史 4.1.15.55 / 4.1.12.53 仍在已知支持列表，
可直接安装（版本文件保留），其他版本可用 `WECHAT_SUPPORTED_VERSION` / `WECHAT_SUPPORTED_BUILD` 覆盖。

### 目录结构

```
app/        SwiftUI App（SwiftPM）+ 128 项测试
bridge/     Go OneBot 桥接（GPL-3.0 衍生，改动见 NOTICE）
hook/       script.js（唯一事实来源）与版本地址表
tools/      Hook 安装、备份、还原
scripts/    构建、打包、安装、自检
devtools/   本地 Mock（无需微信 / Frida）
docs/       架构、契约、记忆与 UI 设计
```

可重建、不入库：`app/.build*`、`bridge/onebot`、`dist/`、`log/`、`hook/gadget/FridaGadget.dylib`、`_research/`、`_local/`。

### 开发与测试

```bash
bash scripts/check.sh               # 静态检查 + Swift 128 项
bash scripts/build_bridge.sh        # Go 构建 + 60 项测试
bash scripts/package_release.sh     # Releases 用 zip + sha256
```

改了 `hook/script.js` 记得跑 `bash scripts/sync_hook_script.sh`。接口 / 行为变更先改 `docs/` 再改代码。
GitHub Actions 只跑 Linux 可完成的检查（文档链接、脚本语法、副本一致、无构建产物）。

### 隐私与安全

- 消息 / 记忆 / 日志只存本机；无遥测、无云端同步；API Key 存 macOS Keychain
- 本地服务只监听 `127.0.0.1`；仓库不含真实 wxid、群 ID、聊天原文、截图或密钥
- 安全与隐私问题请走私密渠道，不要开公开 issue

### 风险

修改 `/Applications/WeChat.app` 会破坏官方签名，**微信更新后可能失效**；存在账号风控风险，
建议仅用个人测试账号。`install` 前会完整备份，`restore` 可还原。

### 许可

GPL-3.0，见 [`LICENSE`](LICENSE)。基于
[yincongcyincong/weixin-macos](https://github.com/yincongcyincong/weixin-macos)、
[xiaoguiwucan/wechat-mac-hook](https://github.com/xiaoguiwucan/wechat-mac-hook) 与
[Frida](https://frida.re)（LGPL-2.1），详见 [`ThirdPartyNotices.txt`](ThirdPartyNotices.txt)。
仅供学习研究，请遵守微信用户协议与当地法律。

---

## English

### Features

- **Automatic private-chat replies**; **multi-select group triggers** (@ / keyword / pat-pat — only
  pats on the bot count, and it can @ the person who patted)
- **Allow / block lists** (conversation ID or wxid), cooldown, per-minute rate limit and working
  hours, all overridable per conversation
- **Per-conversation personas**, system prompts, model and temperature overrides; DeepSeek, OpenAI,
  Ollama or any OpenAI-compatible endpoint
- **Memory**: 10-message short-term window + batch summaries of 8; conversation folders; combined
  weight = base × importance × recall × 30-day half-life, with an adjustable base weight
- **Human-like delay**, reply progress countdown, sleep prevention, scheduled messages, live
  conversation board and runtime logs
- **4.1.15.55 / 4.2.0.5 R3 native text sending** (toggle in Settings, auto-queues without a send handle);
  **real contact nicknames / group names** (local, read-only)
- **Chinese / English UI**; native Liquid Glass look, menu-bar app; no WebView / Electron

### Status

| Component | Status |
| --- | --- |
| SwiftUI app / Swift core | ✅ 128 tests passing; 4.1.15.55 / 4.2.0.5 real-device E2E |
| OneBot bridge (Go) | ✅ builds / auth / device attach / 60 tests passing |
| WeChat 4.1.12.53 | ✅ legacy send + receive |
| WeChat 4.1.15.55 | ✅ Message-finalizer receive + R3 text sending (send one message in WeChat once to capture the handle) |
| WeChat 4.2.0.5 | ✅ Real-device verified (2026-10-22): private-chat/self-message receive, contact directory, R3 text sending incl. bridge-restart handle recovery; group @ / pat-pat reuse existing logic and were not separately retested; media download remains a known limitation |

Requirements: Apple Silicon, macOS 26+; building from source also needs Xcode 27.

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
  [`WeChat-AI-1.0.0.zip`](https://github.com/Gusion1017/Mac-WeChat-ChatBot/releases/download/v1.0.0/WeChat-AI-1.0.0.zip)
  (63 MB, [SHA256](https://github.com/Gusion1017/Mac-WeChat-ChatBot/releases/download/v1.0.0/WeChat-AI-1.0.0.zip.sha256)), unzip and
  **right-click → Open**; the first-run wizard installs the hook. Older versions are on
  [Releases](https://github.com/Gusion1017/Mac-WeChat-ChatBot/releases); details in [`docs/install.md`](docs/install.md).
- **Build from source** (Xcode 27 required):

```bash
git clone https://github.com/Gusion1017/Mac-WeChat-ChatBot.git && cd Mac-WeChat-ChatBot
bash scripts/fetch_gadget.sh     # Frida Gadget 17.8.0 (SHA256 verified)
bash scripts/build_bridge.sh     # Go 1.25 build + 60 tests
bash scripts/build_app.sh        # builds dist/WeChat AI.app
bash scripts/install_app.sh      # installs to ~/Applications
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

Quit WeChat before `install`; it backs up first, and the app offers one-click restore.
The scripts target WeChat 4.2.0.5 (270341) by default; the historical 4.1.15.55 / 4.1.12.53
remain in the known-supported list and install directly (their version files are kept); use
`WECHAT_SUPPORTED_VERSION` / `WECHAT_SUPPORTED_BUILD` to override for other builds.

### Repository Layout

```
app/        SwiftUI app (SwiftPM) + 128 tests
bridge/     Go OneBot bridge (GPL-3.0 derivative, changes listed in NOTICE)
hook/       script.js (single source of truth) and version address tables
tools/      hook install, backup and restore
scripts/    build, package, install, self-check
devtools/   local mocks (no WeChat / Frida needed)
docs/       architecture, contracts, memory and UI design
```

Rebuildable, never committed: `app/.build*`, `bridge/onebot`, `dist/`, `log/`,
`hook/gadget/FridaGadget.dylib`, `_research/`, `_local/`.

### Build and Test

```bash
bash scripts/check.sh               # static checks + 128 Swift tests
bash scripts/build_bridge.sh        # Go build + 60 tests
bash scripts/package_release.sh     # release zip + sha256
```

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

Patching `/Applications/WeChat.app` breaks its official signature and **may stop working after a
WeChat update**; unofficial clients also carry account risk, so use a personal test account.
`install` backs up first and `restore` brings the official app back.

### License

GPL-3.0 — see [`LICENSE`](LICENSE). Built on
[yincongcyincong/weixin-macos](https://github.com/yincongcyincong/weixin-macos),
[xiaoguiwucan/wechat-mac-hook](https://github.com/xiaoguiwucan/wechat-mac-hook) and
[Frida](https://frida.re) (LGPL-2.1); see [`ThirdPartyNotices.txt`](ThirdPartyNotices.txt).
For learning and research only; comply with WeChat's terms of service and local law.
