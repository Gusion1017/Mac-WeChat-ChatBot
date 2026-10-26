# 贡献指南

感谢参与改进本项目。这是一个 macOS 个人自用工具：通过 Frida Gadget 注入官方微信，
把消息桥接到本地 SwiftUI App 与 Go OneBot bridge，并接入 AI 模型生成回复。
项目遵循 **GPL-3.0**，提交前请先阅读 [`README.md`](README.md) 与 [`docs/README.md`](docs/README.md)；
架构、契约与模块说明见 [`docs/architecture.md`](docs/architecture.md)、
[`docs/core-services.md`](docs/core-services.md) 与 [`docs/bridge.md`](docs/bridge.md)。
参与本项目即表示同意遵守 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)；提问与支持渠道见
[`SUPPORT.md`](SUPPORT.md)。

## 1. 环境要求

| 项目 | 要求 | 说明 |
| --- | --- | --- |
| 硬件 | Apple Silicon（arm64） | Intel Mac 不在支持范围 |
| macOS | 26 或更高 | `app/Packaging/Info.plist` 中 `LSMinimumSystemVersion = 26.0` |
| Xcode | 27 | Swift 6.2 工具链；`app/Package.swift` 使用 Swift 5 语言模式 |
| Go | 1.25 | 仅构建 bridge 需要；`scripts/build_bridge.sh` 固定使用 Go 1.25.14 |
| Frida Gadget | 17.8.0 | 用 `bash scripts/fetch_gadget.sh` 下载并校验 SHA256 |
| 微信 | 4.2.0.9 (270345)、4.2.0.5 (270341)、4.1.15.55 (270135) 或 4.1.12.53 (269365) | 仅真机验证需要；其他版本未验证 |
| Python 3 | 可选 | `devtools/` Mock 与 `tools/` 辅助脚本 |

## 2. 本地构建与测试

```bash
# 1. 首次准备 Frida Gadget（下载到 hook/gadget/，已被 git 忽略）
bash scripts/fetch_gadget.sh

# 2. 构建 OneBot bridge（写入 bridge/onebot；默认运行 bridge 测试）
bash scripts/build_bridge.sh
BRIDGE_SKIP_TESTS=1 bash scripts/build_bridge.sh   # 需要跳过测试时

# 3. 构建并打包 SwiftUI App（输出 dist/WeChat AI.app）
bash scripts/build_app.sh

# 4. 安装到 ~/Applications 并打开（可选）
bash scripts/install_app.sh
open "$HOME/Applications/WeChat AI.app"
```

只改 Swift 时：

```bash
cd app
swift build
swift test                                  # 当前 128 项
swift test --scratch-path .build-verify     # 并行开发时避免构建锁冲突
```

只改 Go 时：

```bash
# 推荐：脚本会准备固定 Go/Frida 工具链并跑测试
bash scripts/build_bridge.sh

# 已自行准备 Go 1.25 + frida-core-devkit 时
cd bridge
go test ./... && gofmt -l .
```

提交前跑质量门禁（脚本语法、文档链接、hook/bridge 副本一致性、Swift 测试）：

```bash
bash scripts/check.sh            # 静态 + Swift
bash scripts/check.sh --docs     # 只查文档/脚本
bash scripts/check.sh --with-go  # 额外构建并测试 bridge
```

常用命令也可以走根目录 `Makefile`（`make help` 查看全部目标）。

无需微信 / Frida / 真实 API Key 的本地联调（Mock OneBot + Mock AI）：

```bash
python3 devtools/mock_ai.py --port 8787
python3 devtools/mock_onebot.py --port 58080 --token wechatai-local-token --demo
```

详见 [`devtools/README.md`](devtools/README.md)。受限沙箱（CI / Agent）内构建 App 时，
可加 `SWIFT_DISABLE_SANDBOX=1 bash scripts/build_app.sh`。

清理可再生文件（默认只预览，`--yes` 才执行）：

```bash
bash scripts/clean.sh
bash scripts/clean.sh --yes
```

## 3. 文档优先（docs-first）

- [`docs/`](docs/) 是项目的**唯一事实来源**。接口、行为、Hook 适配或数据结构的改动，
  必须**先更新文档，再改代码**，并在 PR 中链接对应文档。
- 新增文档要在 [`docs/README.md`](docs/README.md) 的索引表登记；相对链接需通过
  `python3 scripts/check_docs.py`。
- **截图不入库**：仓库不包含界面 / 真机截图（`docs/images/` 已被 gitignore）。本地留存请放
  `_research/`，不要提交；如确需随文档发布，先开 issue 讨论脱敏与体积问题。
- Hook 适配结论必须注明微信版本、验证日期与验证方式；未在真机验证的地址不要标记为“可用”。
  **具体地址、结构偏移、密钥派生与发送任务构造不写入公开文档**（见 [`docs/architecture.md`](docs/architecture.md) 的安全边界）。
- 接口契约以 [`docs/architecture.md`](docs/architecture.md) 为准；模块细节见
  [`core-services.md`](docs/core-services.md)、[`bridge.md`](docs/bridge.md)。

## 4. 提交规范

使用 [Conventional Commits](https://www.conventionalcommits.org/)：

```
<type>[(scope)]: <一句话说明做了什么>
```

- 常用 type：`feat`、`fix`、`docs`、`refactor`、`test`、`chore`、`build`、`ci`、`perf`。
- 标题写清“做了什么”，不要只写“update”；正文可以用中文，说明动机、验证方式与影响范围。
- 一个提交只做一件事，避免把格式化、重命名和功能改动混在一起。
- 提交信息与 PR 描述请使用中文（代码标识符与命令保持原文）。

## 5. 代码风格

- **Swift**：4 空格缩进；保持现有 Swift 5 语言模式；UI 遵循 [`docs/ui-design.md`](docs/ui-design.md)
  的设计 token 与组件边界；新增并发代码注意 `@MainActor` / `Sendable` 约束；不引入 WebView / Electron
  类重依赖。
- **Go**：以 `gofmt` 为准；提交前跑 `go vet` / `go test`；新增 HTTP 接口必须保持
  `127.0.0.1` 绑定与 Bearer 鉴权。
- **Frida JS**：`hook/script.js` 是唯一事实来源；`bridge/script.js` 是 bridge 运行时从当前目录
  读取的副本，修改后必须运行 `bash scripts/sync_hook_script.sh`（`--check` 校验一致性），
  App 打包时也优先使用 `hook/script.js`。改动需注明目标微信版本并附真机日志。
- **Shell**：`bash` + `set -euo pipefail`；脚本需可重复执行；删除类操作默认 dry-run，
  必须显式 `--yes` 才执行。
- **Markdown**：中文、相对链接、表格优先；不要插入含真实隐私信息的截图。

## 6. 禁止入库清单

以下内容一律不要提交（已在 [`.gitignore`](.gitignore) 中尽量拦截）：

- 构建产物与缓存：`app/.build*`、`app/.swiftpm/`、`bridge/onebot`、`bridge/onebot.dSYM/`、
  `dist/`、`log/`、`bridge/log/`、`__pycache__/`
- 运行时依赖：`hook/gadget/FridaGadget.dylib`（用 `scripts/fetch_gadget.sh` 重新下载）
- 数据与归档：`*.sqlite` / `*.sqlite-shm` / `*.sqlite-wal`、`*.zip` / `*.dmg`、`*.dSYM/`、
  `DerivedData/`、`*.xcarchive` / `*.xcresult`
- 本地研究证据：`_research/`、`_research/archive/`、`/versions/`
- 密钥与凭据：`.env`、API Key、OneBot token 导出、Cookie、证书、登录二维码截图
- 真实微信数据：聊天记录备份、数据库文件、导出文件、界面截图

## 7. 隐私红线

- 不提交真实 **wxid**、昵称 + 头像组合、手机号、群名、聊天原文 / 截图、登录二维码。
- 不提交 **API Key、OneBot token、Cookie、Frida 捕获的会话数据**；AI Key 只保存在
  macOS Keychain，配置文件中只存引用名。
- 日志粘贴前先脱敏：删除 wxid、消息内容、文件路径中的用户名与 IP；截图给昵称 / 头像 /
  消息打码。
- 演示与测试请使用 `devtools/` Mock，或专用测试账号；不要用他人账号、真实聊天记录做演示。
- 提交即表示你确认内容不含上述信息；维护者会拒绝相关 PR，必要时要求重写历史。

## 8. PR 流程

1. 先开 issue 讨论：Bug 用 [Bug 模板](.github/ISSUE_TEMPLATE/bug_report.yml)，
   功能用 [功能模板](.github/ISSUE_TEMPLATE/feature_request.yml)。文档 / 拼写类小改动可直接 PR。
2. Fork 仓库并新建分支：`feat/xxx`、`fix/xxx`、`docs/xxx`。
3. 先改文档，再改代码；补充或更新测试；本地跑通对应的构建 / 测试命令。
4. 按 [PR 模板](.github/PULL_REQUEST_TEMPLATE.md) 填写变更摘要、文档影响、测试方式与检查清单。
5. 确认 `git status` 干净，PR 只包含本主题相关文件；不要提交生成文件或无关格式化。
6. 维护者 review；Hook / 真机相关改动需要附微信版本与验证证据，无法验证的改动可能被拒绝。

## 9. 许可与第三方

- 贡献的代码按 **GPL-3.0** 授权（见 [`LICENSE`](LICENSE)）。
- 新增第三方代码或依赖前请确认许可兼容，并同步更新 [`ThirdPartyNotices.txt`](ThirdPartyNotices.txt)。
- 本项目与腾讯、Apple 无关联；仅供学习研究，请遵守微信用户协议与当地法律。
