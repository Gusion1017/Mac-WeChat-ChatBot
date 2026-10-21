# 微信 AI 助手（WeChat AI）

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](#快速开始)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)](app/Package.swift)
[![Go](https://img.shields.io/badge/Go-1.25-00ADD8.svg)](bridge/go.mod)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)

在 macOS 上通过 **Frida Gadget 注入官方微信**（复用唯一实例，不登录第二个客户端），
把微信消息桥接到本地 **原生 SwiftUI** 应用，由 **DeepSeek / OpenAI 兼容模型** 生成
拟人化回复，并提供总览、会话、人格、记忆、定时任务、日志与设置界面。

> 个人自用 / 学习研究项目，遵循 GPL-3.0。修改微信客户端存在账号风控与签名失效风险，
> 请先阅读[风险与备份](#风险与备份)。本项目与腾讯、Apple 无关联。

## 目录

- [功能](#功能)
- [状态](#状态)
- [架构](#架构)
- [快速开始](#快速开始)
- [手动管理微信 Hook](#手动管理微信-hook)
- [目录结构](#目录结构)
- [开发与测试](#开发与测试)
- [清理、打包与分享](#清理打包与分享)
- [风险与备份](#风险与备份)
- [隐私与安全](#隐私与安全)
- [贡献](#贡献)
- [许可](#许可)

## 功能

- **私聊自动回复**；**群聊触发可多选**（@ / 关键词 / 拍一拍；「所有消息」独占），并支持学习群昵称后的纯文本 @ 兜底；
  拍一拍只认「拍的是机器人」的目标，拍别人不会唤醒；可在机器人页开启「拍一拍回复」（默认关闭），配置 AI 前/后自定义文字和/或 AI 回复；
  群聊回复还可选择「@ 拍的人」（真实 `<atuserlist>` @）。回拍已移除
- **统一白名单 / 黑名单（会话 ID 或用户 wxid）/ 冷却 / 每分钟限流 / 工作时段**，支持按会话覆盖
- **按会话人格**、系统提示词、模型覆盖；温度按模型单独配置
- **记忆系统**：10 条短期窗口 → 窗口外旧消息攒够 8 条批量总结；
  记忆页按会话「文件夹」组织；综合权重 = 基础权重 × 内容重要度 × 召回强化 × 30 天半衰期，
  基础权重可在记忆编辑器自由调整（0.1~10×），核心记忆之间也按权重排序；
  自动总结上限 600 字并自动压缩；核心记忆按所属会话/全局作用域生效，手写编辑不被自动总结覆盖
- **防睡眠**（通用设置）：永不 / 接入电源适配器时 / 始终；仅阻止系统空闲睡眠，不合盖睡眠
- **拟人化**：随机延迟、单条回复（默认）、dry-run；多段发送因 4.1.12 canary 风险默认关闭
- **回复进度倒计时**：收到消息后实时显示 AI 生成耗时、拟人化「N 秒后发送」倒计时、发送回执与
  失败原因；详情头部、输入区与会话列表行同步可见，便于判断卡在哪一步
- **4.1.15.55 原生文本发送（R3）**：设置 → Hook 内开关（默认开）；无发送句柄时消息自动排队，
  在本机微信手动发一条消息后自动重发；仅文本，4.1.12 仍走 legacy，互相隔离
- **通讯录真实昵称 / 群名**：通过本机**只读**的通讯录读取，把入站事件里的 wxid
  映射为真实好友昵称 / 群名；群成员缓存未命中时回退通讯录。数据仅留本机，
  隐私边界见 [通讯录文档](docs/hook-contact-directory.md)
- **多 AI 通道**：DeepSeek 默认，OpenAI / Ollama / 任意 OpenAI 兼容端点
- **图片 / 语音 / 表情 / 文件**：文本 / 表情 / 群 @ 已验证；图片 / 文件下载 hook 在 4.1.12 暂缺（见验收报告）
- **定时主动消息**、**实时会话看板**、**运行日志**
- **原生苹果风格 UI**：Liquid Glass、SF Symbols、浅 / 深色、键盘快捷键、菜单栏；
  关闭 Dock 图标后仍可从菜单栏恢复窗口；同页重复开关 / 设置已收敛为单一入口；
  再次点击当前会话行或侧边栏「会话」可收起聊天详情
- **关闭窗口即隐藏**，可从菜单栏（或 Dock，若启用）恢复；退出仅保留 ⌥⌘Q 与菜单栏入口
- **低开销**：无 WebView / Electron；bridge 仅机器人开启时运行；SQLite WAL；日志环形缓冲

## 状态

| 模块 | 状态 |
| --- | --- |
| SwiftUI App（9 个侧边栏页面 + 首次向导） | ✅ 构建与真机 E2E |
| Swift 核心（OneBot、AI、SQLite 记忆、触发判定、调度） | ✅ 构建 / 126 项测试通过 |
| OneBot bridge（Go + frida-core） | ✅ 构建 / 鉴权 / 真机附加 / 60 项测试通过 |
| 4.1.12.53 接收 + 主动发送 | ✅ 真机全链路，单条自动回复稳定 |
| 4.1.15.55 接收（Message finalizer） | ✅ 历史验证 |
| 4.1.15.55 发送（R3 原生发送） | ✅ 文本私聊真机验证（2026-10-20）；设置内可开关，见 [R3 文档](docs/hook-r3-native-send.md) |
| 通讯录昵称 / 群名（本机只读） | ✅ 4.1.15.55 真机验证（2026-10-21，22 条：21 联系人 + 1 群），见 [通讯录文档](docs/hook-contact-directory.md) |
| 安装 / 备份 / 重签工具链 | ✅ 已在微信副本上校验通过 |
| App 打包脚本 / 图标 / Info.plist | ✅ |
| 首版验收 | ✅ 2026-10-20 通过；未完成项见 [集成状态](docs/integration-status.md) |

目标环境：Apple Silicon、macOS 26+、Xcode 27；支持微信 **4.1.12.53 (269365)**（legacy 收发）
与 **4.1.15.55 (270135)**（Message finalizer 接收 + R3 文本发送；R3 首次使用需在本机微信
手动发一条消息以捕获发送句柄，见 [R3 文档](docs/hook-r3-native-send.md)）。

## 架构

```
WeChatAI.app (SwiftUI)
  ├── UI / 触发判定 / 人格 / 记忆 / 调度 / 日志
  ├── OneBotClient  ── WS/HTTP 127.0.0.1:58080 ──┐
  ├── AIClient (OpenAI-compatible, SSE)          │
  ├── MemoryStore (SQLite WAL)                   │
  ├── SleepPreventionCenter (IOKit assertion)    │
  └── HookManager（检测/备份/安装/启停）           │
                                                 ▼
                                      bridge/onebot (Go)
                                        ├── frida-core → Gadget 127.0.0.1:27042
                                        └── hook/script.js → WeChat 4.x 底层收发
                                                 ▲
                                      WeChat.app（官方唯一实例，ad-hoc 重签）
```

详细契约见 [`docs/architecture.md`](docs/architecture.md)，记忆设计见 [`docs/memory.md`](docs/memory.md)，
开发与排障见 [`docs/development.md`](docs/development.md)，完整文档索引见 [`docs/README.md`](docs/README.md)，
变更历史见 [`CHANGELOG.md`](CHANGELOG.md)。

## 快速开始

> **从 GitHub 下载 ZIP？**
> - **普通用户**：请下载 **Releases** 里的 `WeChat-AI-<版本>.zip`（已编译 App，免 Xcode）；
>   解压后右键打开，首次向导会安装 Hook。完整步骤见 [安装与启动](docs/install.md)。
> - **只有源码 ZIP**：需要 Xcode 27，按本节自行构建；源码包**不含**已编译 App、
>   `bridge/onebot` 与 `FridaGadget.dylib`。

**环境要求**：Apple Silicon、macOS 26+、Xcode 27（含命令行工具）。
Go 1.25 与 Frida Gadget 17.8.0 由脚本按固定版本下载并校验，无需预装。

```bash
# 0. 获取代码
git clone <your-repo-url> ChatBot
cd ChatBot

# 1. 下载 Frida Gadget（写入 hook/gadget/FridaGadget.dylib）
bash scripts/fetch_gadget.sh

# 2. 构建 OneBot bridge（写入 bridge/onebot）
bash scripts/build_bridge.sh

# 3. 构建并打包 SwiftUI App（生成 dist/WeChat AI.app）
bash scripts/build_app.sh

# 4. 安装到 ~/Applications 并打开
bash scripts/install_app.sh
open "$HOME/Applications/WeChat AI.app"

# 5. 首次启动向导：检测微信 → 备份并安装 Gadget → 配置 AI → 启动
```

也可以直接从 `dist/` 运行：`open "dist/WeChat AI.app"`。
受限沙箱（CI / Agent）内构建时，用 `SWIFT_DISABLE_SANDBOX=1 bash scripts/build_app.sh`。

> **只想本地联调、不想碰微信？** 见 [`devtools/README.md`](devtools/README.md)：
> 用 `mock_onebot.py` + `mock_ai.py` 即可跑通「收消息 → 规则/人格 → AI → 发送」全链路。

## 手动管理微信 Hook

```bash
bash tools/manage_wechat.sh status     # 查看版本/运行/注入/备份状态（JSON）
bash tools/manage_wechat.sh backup     # 完整备份官方 App（zip，约 650MB）
bash tools/manage_wechat.sh install    # 注入 Gadget + 保留 entitlements 的 ad-hoc 重签
bash tools/manage_wechat.sh restore    # 还原官方 App
```

`install` 需要先完全退出微信；App 内会先备份再修改，并提供一键还原入口。

## 目录结构

```
ChatBot/
├── app/                     SwiftUI macOS 应用（SwiftPM）
│   ├── Package.swift        平台 macOS 26 / Swift 6.2
│   ├── Sources/WeChatBot/   Models / Core / Services / DesignSystem / Views
│   ├── Tests/WeChatAITests/ 126 项单元测试
│   └── Packaging/Info.plist 打包模板
├── bridge/                  OneBot Go 桥接（GPL-3.0 衍生，含 proto/ 协议）
│   └── NOTICE               上游来源与本项目修改/新增文件清单
├── hook/                    Frida 注入脚本
│   ├── script.js            唯一事实来源（版本适配 + R3）
│   ├── versions/*.json      微信版本地址表
│   ├── gadget/              FridaGadget.config（.dylib 运行时下载，不入库）
│   └── diag/                诊断与指针反查说明
├── tools/                   Mach-O 注入、微信备份/安装/还原、指针反查
├── scripts/                 构建、打包、安装、运行、清理、自检
├── devtools/                本地 Mock（无需微信 / Frida 即可联调）
├── assets/                  App 图标源文件（.iconset / .icns）
├── docs/                    架构、契约、开发手册、Hook 移植、通讯录、性能与验收
├── .github/                 Issue / PR 模板、Release Notes 分类、Docs CI
├── .editorconfig            编码、缩进与换行约定
├── .gitattributes           换行规范化与生成代码标记
├── .gitignore               构建产物、日志与隐私文件忽略规则
├── Makefile                 常用开发命令（make help）
├── LICENSE                  GPL-3.0 全文
├── AGENTS.md                AI 编码代理的仓库指南
├── CHANGELOG.md             变更日志
├── CODE_OF_CONDUCT.md       贡献者行为准则
├── CONTRIBUTING.md          贡献指南
├── SECURITY.md              安全与隐私报告
├── SUPPORT.md               获取帮助与支持渠道
└── ThirdPartyNotices.txt    第三方开源声明
```

以下目录 / 文件**可随时重建，不入库**：`app/.build*`、`bridge/onebot`、`dist/`、`log/`、
`bridge/log/`、`hook/gadget/FridaGadget.dylib`、`_research/`（本地研究证据）。

## 开发与测试

完整开发手册（环境、文件地图、常见任务、排障、发布）见
[`docs/development.md`](docs/development.md)；AI 代理见 [`AGENTS.md`](AGENTS.md)。

```bash
# 一条命令做静态检查 + Swift 测试
bash scripts/check.sh

# Swift：构建 + 单元测试（126/126）
cd app && swift build && swift test

# Go bridge：构建时自动跑 Go 测试（60 项）
bash scripts/build_bridge.sh

# 仅构建 bridge（跳过测试）
BRIDGE_SKIP_TESTS=1 bash scripts/build_bridge.sh

# 改了 hook/script.js 后同步 bridge 运行时副本
bash scripts/sync_hook_script.sh
```

也可以直接用根目录 `Makefile`（`make help`）：`make setup` / `make bridge` / `make app` /
`make test` / `make check` / `make clean`。受限沙箱（CI / Agent）内构建时加
`SWIFT_DISABLE_SANDBOX=1`。

GitHub Actions 只跑可在 Linux 上完成的检查（文档链接、脚本语法、hook/bridge 副本一致、
仓库无构建产物/截图）；Swift 与 Go 构建需要 macOS / 真机环境，请在本地按
[`docs/development.md`](docs/development.md) 执行。

约定：

- **文档优先**：`docs/` 是事实来源，接口 / 行为变更先改文档再改代码（见 `docs/architecture.md` §2）。
- 并行开发使用独立 scratch path（如 `.build-core` / `.build-ui`）避免 SwiftPM 锁冲突。
- Hook 地址必须 runtime 验证文本收发后才能标记为可用。
- 提交前跑 `bash scripts/check.sh` 与 `git status`；不要提交构建产物、二进制和真实会话数据。
- `scripts/check_docs.py` 会校验 Markdown 相对链接；新增文档请在 `docs/README.md` 登记。

## 清理、打包与分享

```bash
bash scripts/clean.sh                      # 预览将删除的构建缓存/产物
bash scripts/clean.sh --yes                # 清理 app/.build*、bridge/onebot、dist/、日志、__pycache__
bash scripts/clean.sh --yes --keep-dist    # 保留 dist/ 打包产物
bash scripts/clean.sh --yes --all          # 额外删除 Frida Gadget（需重新下载）
```

清理只删除可再生文件，不触碰源码、`hook/versions/`、`assets/`、`docs/` 与 `_research/`，
也不影响已安装到 `~/Applications` 的 App；重建见[快速开始](#快速开始)。

导出**仅含 Git 跟踪文件**的源码包（自动排除构建产物、日志、Gadget 与研究数据）：

```bash
git archive --format=zip --prefix=ChatBot/ -o ChatBot-src.zip HEAD
```

### 发布前检查清单

准备上传到 GitHub 时按顺序确认：

- [ ] `bash scripts/check.sh --with-go` 通过（Swift 126 项、Go 60 项、文档链接、脚本语法、副本一致）。
- [ ] `bash scripts/clean.sh --yes` 清理构建缓存、产物与日志（需要保留 `dist/` 时加 `--keep-dist`）。
- [ ] `git status --short` 只包含预期源码与文档，没有 `_research/`、`dist/`、`log/`、`*.sqlite*`、`*.dmg`。
- [ ] `git ls-files | grep -Ei '(\.(dylib|dmg|zip|sqlite|sqlite3|db|log)$|^bridge/onebot$)'` 无输出。
- [ ] 仓库内无真实 wxid / 群 ID / 手机号 / 聊天原文 / 截图 / API Key / OneBot Token。
- [ ] 按目标仓库修改 `.github/ISSUE_TEMPLATE/config.yml` 与本节的 `<owner>` / `<repo>` 占位符。
- [ ] 用上面的 `git archive` 导出并抽查压缩包内容，再创建 GitHub 仓库并 push。

上传 GitHub：

```bash
git remote add origin git@github.com:<owner>/<repo>.git
git push -u origin main
```

> **不要直接压缩整个工作目录分享**：`_research/`（真机探针日志与地址）、`dist/`、`log/` 与 `.git/`
> 可能含真实会话数据或旧历史。分享源码请使用上面的 `git archive` 命令，或只打包被 Git 跟踪的文件。
> 仓库不包含截图；如需本地留存，请放在 `_research/`（已忽略），不要提交到 `docs/images/`。
> 仓库默认不含真实 wxid、群 ID、聊天记录、API Key 或本地路径。

## 风险与备份

- 修改 `/Applications/WeChat.app` 会破坏 Tencent 官方签名，**微信更新后可能失效**；
  脚本会尽力关闭 Sparkle 自动更新，但请在微信更新后重新检测并安装。
- 非官方客户端存在**账号风控风险**；请自行评估，建议仅用于个人测试账号。
- `install` 前会完整备份到 `~/Library/Application Support/WeChatAI/backups/`；
  `restore` 可恢复官方签名与 App。聊天数据位于微信容器内，安装 / 还原不会主动删除。
- 所有本地服务只监听 `127.0.0.1`；API Key 存 macOS Keychain；配置文件不含明文密钥。
- 本项目与腾讯、Apple 无关联。

## 隐私与安全

- **密钥**：仅保存在 macOS Keychain（`service = com.gusionw.wechatai`），`config.json` 只记录引用名。
- **通讯录读取密钥**：只在本机内存与受限缓存（0600）中，不写日志、不入库；
  删除缓存后需重新登录微信采集。仅用于自己的设备与账号。
- **数据**：消息 / 记忆 / 日志全部保存在本机；无遥测、无云端同步、无 WebView。
- **仓库**：不包含真实 wxid、群 ID、聊天记录、CDN 密钥、API Key 或界面 / 真机截图；
  示例文本与测试数据均已脱敏。
- **报告问题**：安全或隐私问题请走 [SECURITY.md](SECURITY.md) 的私密渠道，不要在公开 issue
  中粘贴密钥、wxid 或聊天内容。

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。请遵循 `docs/` 契约优先、Conventional Commits、
以及 `.github/PULL_REQUEST_TEMPLATE.md` 中的检查清单。

参与本项目即表示同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。提问、Bug 与支持渠道
见 [SUPPORT.md](SUPPORT.md)；安全或隐私问题请走私密渠道（[SECURITY.md](SECURITY.md)）。

## 许可

GPL-3.0，见 [`LICENSE`](LICENSE)。基于以下开源工作（详见 [`ThirdPartyNotices.txt`](ThirdPartyNotices.txt)）：

- [yincongcyincong/weixin-macos](https://github.com/yincongcyincong/weixin-macos)（Hook / OneBot / addrfind）
- [xiaoguiwucan/wechat-mac-hook](https://github.com/xiaoguiwucan/wechat-mac-hook)（macOS 4.x 集成与运维）
- [Frida](https://frida.re)（LGPL-2.1）

仅供学习研究；请遵守微信用户协议与当地法律。
