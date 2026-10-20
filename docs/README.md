# 文档索引

本目录是项目的事实来源（single source of truth）。**接口/行为变更先改文档，再改代码**
（见 [`architecture.md`](architecture.md) §2 写入边界）。

| 文档 | 内容 | 主要读者 |
| --- | --- | --- |
| [`architecture.md`](architecture.md) | 总体架构、目录与写入边界、OneBot 桥接契约 | 全部 |
| [`core-services.md`](core-services.md) | Swift 核心服务：AppStore、AI/OneBot/记忆/触发判定/调度、防睡眠、并发与错误处理 | swift-core / swift-ui |
| [`bridge.md`](bridge.md) | Go OneBot 桥接：启动参数、HTTP/WS 接口、frida-core 接入 | bridge |
| [`hook-porting.md`](hook-porting.md) | 4.1.12.53 → 4.1.15.55 地址移植记录与 `addrfind` 流程 | hook-port |
| [`hook-4_1_15-abi.md`](hook-4_1_15-abi.md) | 4.1.15.55 req2buf ABI、注入策略、崩溃分析与发送模式 | hook-port |
| [`hook-r3-native-send.md`](hook-r3-native-send.md) | **R3 原生 task 构造 + slot13 提交（产品默认开，仓库 JSON 默认 off；仅 text；2026-10-20 真机验证通过）** | hook-port |
| [`memory.md`](memory.md) | 记忆系统：10 条短期窗口、20 条批量总结、会话文件夹、综合权重与核心记忆 | swift-core / swift-ui |
| [`ui-design.md`](ui-design.md) | SwiftUI 信息架构、设计 token、组件拆分与交互约定 | swift-ui |
| [`integration-status.md`](integration-status.md) | 真机集成状态与证据（接收/发送/AI） | 全部 |
| [`acceptance.md`](acceptance.md) | 最终验收报告、功能矩阵、已知限制 | 全部 |

## 快速导航

- 想跑起来：根目录 [`README.md`](../README.md) 的「快速开始」。
- 想安装到主目录：`bash scripts/build_app.sh && bash scripts/install_app.sh`（默认 `~/Applications`）。
- 想改协议：先读 `architecture.md` §3–§4，再读对应模块文档。
- 想移植新微信版本：`hook-porting.md` → `hook-4_1_15-abi.md` → `hook/diag/README.md`。
- 想看 4.1.15 发送新路线：`hook-r3-native-send.md`（真机探针保存在本地 `_research/`，不入库）。
- 只想本地联调（无微信）：[`devtools/README.md`](../devtools/README.md)。
- 参与开发 / 报告问题：[`CONTRIBUTING.md`](../CONTRIBUTING.md) / [`SECURITY.md`](../SECURITY.md)。

> 仓库不包含界面 / 真机截图。如需本地留存，请放在 `_research/`（已忽略）；不要提交到 `docs/images/`。
