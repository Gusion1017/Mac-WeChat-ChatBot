# 文档索引

本目录是项目的事实来源（single source of truth）。**接口/行为变更先改文档，再改代码**
（见 [`architecture.md`](architecture.md) §2 写入边界）。

## 文档地图

| 文档 | 内容 | 主要读者 | 类型 |
| --- | --- | --- | --- |
| [`development.md`](development.md) | **开发手册**：环境、仓库地图、构建、测试、调试、常见任务 Recipe、发布 | 全部开发者 / AI 代理 | 操作手册 |
| [`architecture.md`](architecture.md) | 总体架构、目录与写入边界、OneBot 桥接契约 | 全部 | 现行契约 |
| [`core-services.md`](core-services.md) | Swift 核心服务：AppStore、AI/OneBot/记忆/触发判定/调度、防睡眠、并发与错误处理 | swift-core / swift-ui | 现行契约 |
| [`bridge.md`](bridge.md) | Go OneBot 桥接：启动参数、HTTP/WS 接口、frida-core 接入 | bridge | 现行契约 |
| [`memory.md`](memory.md) | 记忆系统：10 条短期窗口、8 条批量总结、同会话早期片段召回、记忆文件夹、综合权重（基础权重可调）与核心记忆作用域 | swift-core / swift-ui | 现行契约 |
| [`ui-design.md`](ui-design.md) | SwiftUI 信息架构、设计 token、组件拆分与交互约定 | swift-ui | 现行契约 |
| [`performance.md`](performance.md) | 稳定性：AppKit 显示周期断言安全阀、崩溃取证（面包屑/crash-*.log）、主线程看门狗与卡顿排查 | 全部 | 现行手册 + 事故记录 |
| [`integration-status.md`](integration-status.md) | 真机集成状态与证据（接收/发送/AI/误路由修复/稳定性） | 全部 | 现状跟踪 |
| [`acceptance.md`](acceptance.md) | 2026-10-20 首版验收报告（历史记录）、功能矩阵、已知限制 | 全部 | 历史记录 |
| [`hook-porting.md`](hook-porting.md) | 4.1.12.53 → 4.1.15.55 地址移植记录与 `addrfind` 流程 | hook-port | 历史记录 + 方法 |
| [`hook-4_1_15-abi.md`](hook-4_1_15-abi.md) | 4.1.15.55 req2buf ABI、注入策略、崩溃分析与历史发送模式 | hook-port | 历史记录 |
| [`hook-r3-native-send.md`](hook-r3-native-send.md) | **R3 原生 task 构造 + slot13 提交（产品默认开，仓库 JSON 默认 off；仅 text；2026-10-20 真机验证通过）** | hook-port | 现行实现 |
| [`hook-contact-directory.md`](hook-contact-directory.md) | **通讯录真实昵称/群名：SQLCipher4 页格式、CommonCrypto key 捕获、进程内解密 + 查询、bridge/App 契约** | hook-port / bridge / swift-core | 现行实现 |

根目录另见：[`README.md`](../README.md)（项目介绍与快速开始）、
[`AGENTS.md`](../AGENTS.md)（AI 编码代理指南）、
[`CHANGELOG.md`](../CHANGELOG.md)（变更日志）、
[`CONTRIBUTING.md`](../CONTRIBUTING.md)（贡献规范）、
[`SECURITY.md`](../SECURITY.md)（安全与隐私报告）。

> **现行 vs 历史**：`architecture.md` / `core-services.md` / `bridge.md` / `memory.md` /
> `ui-design.md` / `hook-r3-native-send.md` / `hook-contact-directory.md` 描述**当前实现**；
> `acceptance.md`、`hook-4_1_15-abi.md`、`hook-porting.md` 与 `hook/diag/` 中的发送模式
> （C1/C2/cgi/replay）是带日期的**历史记录**，其中部分结论已被 R3 推翻。读历史文档时
> 先看文首的状态说明，修改现状请以现行契约为准。

## 快速导航

- 想跑起来：根目录 [`README.md`](../README.md) 的「快速开始」。
- 第一次接手 / 想改代码：[`development.md`](development.md)（文件地图 + 常见任务 Recipe + 排障）。
- 用 AI 代理开发：[`AGENTS.md`](../AGENTS.md)。
- 想安装到主目录：`bash scripts/build_app.sh && bash scripts/install_app.sh`（默认 `~/Applications`）。
- 想改协议：先读 `architecture.md` §3–§4，再读对应模块文档。
- 想移植新微信版本：`hook-porting.md` → `hook-4_1_15-abi.md` → `hook/diag/README.md`。
- 想看 4.1.15 发送新路线：`hook-r3-native-send.md`（真机探针保存在本地 `_research/`，不入库）。
- 想拿真实好友昵称/群名：`hook-contact-directory.md`（SQLCipher 解密 + 进程内查询；密钥缓存注意隐私）。
- App 闪退 / 卡顿排查：先看 `performance.md`（`~/Library/Logs/WeChatAI/` 取证文件、安全阀、看门狗）。
- 只想本地联调（无微信）：[`devtools/README.md`](../devtools/README.md)。
- 提交前自检：`bash scripts/check.sh`；文档链接：`python3 scripts/check_docs.py`。
- 参与开发 / 报告问题：[`CONTRIBUTING.md`](../CONTRIBUTING.md) / [`SECURITY.md`](../SECURITY.md)。

> 仓库不包含界面 / 真机截图。如需本地留存，请放在 `_research/`（已忽略）；
> 不要提交到 `docs/images/`（该目录已 gitignore）。
