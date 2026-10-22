## 变更摘要

<!-- 这个 PR 做了什么、为什么做。关联 issue：Closes # -->

## 变更类型

- [ ] feat：新功能
- [ ] fix：缺陷修复
- [ ] docs：仅文档
- [ ] refactor：重构（不改变行为）
- [ ] test：测试
- [ ] chore / build / ci：构建、脚本、依赖
- [ ] hook：微信 Hook / 版本适配（需附真机证据）

## 影响的文档（docs-first）

> `docs/` 是项目事实来源；接口、行为或 Hook 适配变化必须先改文档，再改代码。
> 地址、结构偏移、密钥派生与发送任务构造不写入公开文档。

- [ ] `docs/architecture.md`
- [ ] `docs/core-services.md`
- [ ] `docs/bridge.md`
- [ ] `docs/memory.md` / `docs/ui-design.md`
- [ ] `docs/install.md`（用户可见安装/升级流程变化时）
- [ ] `docs/README.md` 索引
- [ ] 不需要更新文档（原因：）

## 测试方式

<!-- 粘贴实际执行的命令与关键输出；没有跑的部分请说明原因。 -->

- [ ] `cd app && swift build`
- [ ] `cd app && swift test`
- [ ] `bash scripts/build_bridge.sh`
- [ ] `bash scripts/build_app.sh`
- [ ] 真机验证（微信版本 / 场景 / 结果）：
- [ ] 其他：

## 检查清单

- [ ] 未提交二进制与构建产物（`app/.build*`、`bridge/onebot`、`dist/`、`log/`、`hook/gadget/FridaGadget.dylib`、`*.sqlite`、`*.zip` / `*.dmg`）
- [ ] 未包含密钥、真实 wxid、聊天内容或未脱敏的聊天截图
- [ ] 文档已同步（或确认为纯内部改动）
- [ ] 提交信息符合 Conventional Commits（中文正文可以）
- [ ] `git status` 干净，没有意外的新增 / 删除文件
- [ ] 已自查 diff，确认没有调试残留（临时日志、TODO、注释掉的代码）

## 备注（可选）

<!-- 已知限制、后续工作、需要 reviewer 特别关注的地方。 -->
