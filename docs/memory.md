# 记忆系统（短期窗口 + 批量长期总结）

记忆系统由两部分组成：

- **短期记忆**：每个会话最近 10 条消息，进入当轮提示词；
- **长期记忆**：短期窗口之外的旧消息攒够一批后由 AI（或本地兜底）总结，
  以「记忆文件夹」的形式在记忆页浏览、编辑和标记核心。

数据全部保存在本地 SQLite（`AppPaths.databaseFile`），不依赖云端。

## 1. 短期记忆窗口

- 每个会话的短期窗口固定为 **最多 10 条消息**（`ChatEngine.shortTermMemoryLimit`）。
- `ChatEngine.buildMessages` 取历史 `suffix(min(settings.bot.maxContextMessages, 10))`；
  设置页 `maxContextMessages` 上限同样是 10。
- 超出 10 条的旧消息不进入本轮提示词，由后台批量总结写入长期记忆。

## 2. 批量总结策略（核心修复）

相关常量（`ChatEngine`）：

| 常量 | 值 | 含义 |
| --- | --- | --- |
| `shortTermMemoryLimit` | 10 | 短期窗口保留条数 |
| `overflowBatchThreshold` | 20 | 攒够多少条窗口外旧消息才触发一次总结 |
| `maxOverflowBatch` | 40 | 单次总结的消息上限 |
| `summaryCharacterLimit` | 600 | 长期记忆正文长度上限 |

### 2.1 游标与批量判定

`MemoryStore.pendingMemoryOverflow(conversationID:keep:minOverflow:maxMessages:)`：

- 用 `messages.rowid` 保留最近 `keep`（默认 10）条消息，得到 cutoff；
- `memory_state.last_summarized_rowid` 记录每个会话的总结游标，避免重复总结；
- 统计游标与 cutoff 之间**未总结消息总数**：
  - 若 `未总结数 < minOverflow` → 返回 `nil`，本次不总结；
  - 否则按 rowid 升序返回最多 `maxMessages` 条，`lastRowID` 用于推进游标；
- 游标推进后，剩下的窗口外消息继续累积，等攒够下一个批量阈值再总结。

`ChatEngine.summarizeOverflow` 使用 `minOverflow = overflowBatchThreshold`、
`maxMessages = maxOverflowBatch`，因此：

- **12 条消息**：窗口外只有 2 条，不足 20 条，不总结；
- **30 条消息**：一次总结最早的 **20 条**，剩余 10 条留在短期窗口；
- **50 条消息**：再总结下一批 **20 条**（累计 40 条），自动记忆仍然只有 1 条；
- 之后约每新增 20 条窗口外消息触发一次 AI 调用，单次最多 40 条。

### 2.2 滚动合并与历史清理

- 同一会话只保留一条自动记忆（`source = "summary"` 且 `is_core = 0`）：
  `sourceCount` 累加、`updatedAt` 刷新、摘要滚动更新。
- 总结前若发现同一会话存在**多条**历史自动总结（旧版本遗留）：
  - 累加它们的 `sourceCount`；
  - 用 `MemorySummaryCompactor` 合并摘要；
  - 保留最新一条，删除其余（best-effort，失败只记日志、不阻塞总结）。
- 用户编辑过的记忆会转为 `source = "manual"`，后续自动总结不会覆盖手写内容；
  核心记忆（`isCore`）始终加入上下文，独立于自动滚动记忆。
- `MemoryStore.autoMemories(conversationID:)` 返回同一会话的全部自动总结
  （按 `updated_at` 降序，正常情况下只有一条）。

### 2.3 AI 提示与本地兜底

AI 提示要求：

- 最多 **5 条要点**，总长不超过 **300 字**；
- 与已有记忆**合并去重**；
- 保留事实、偏好、称呼、约定和未完成事项；
- 删除已解决或过时的细节；不要编造；
- 以会话标题/类型（如「小林（私聊）」）作为上下文。

无 Key 或 AI 失败时使用本地兜底 `ChatEngine.localSummary(existing:transcript:)`：
已有摘要 + 新对话拼接后交给 `MemorySummaryCompactor`，同样不超过 600 字符，
**不再截取 1800 字原文**。

日志会写清批量条数与累计条数，例如：

```
长期记忆已更新（小林，批量合并 20 条旧消息（单批上限 40），累计 40 条，权重 1.82）
```

## 3. 记忆压缩器 MemorySummaryCompactor

确定性的摘要压缩器（`Services/ChatEngine.swift`），AI 结果与本地兜底都会经过它：

- **去重**：忽略空白与大小写差异，保留首次出现的要点；
- **去空行 / 规范空白**：合并连续空白（含全角空格、制表符），去掉首尾空白；
- **按行组织**：每条要点统一输出为 `- ` 开头的行；输入里的
  `-` / `*` / `•` / `·` 前缀和 `1.` / `1)` 等有序列表序号会被去掉后重新排版；
- **限长**：输出强制 `<= maxCharacters`（默认 600）。超长时保留**尾部最新内容**，
  并在开头插入「…（早期细节已压缩）」提示；单条要点就超长时硬截断尾部兜底。

## 4. 综合权重

```
importanceFactor = 1 + 0.12 × log2(1 + max(0, sourceCount))
usageFactor      = 1 + 0.02 × min(max(0, accessCount), 20)
decayAnchor      = max(updatedAt, lastAccessedAt ?? .distantPast)
timeWeight       = max(0.0001, baseWeight × importanceFactor × usageFactor
                                × 0.5^(距 decayAnchor 天数 / 30))
```

- **重要度**：随合并消息条数对数增长、逐渐饱和，常用范围内约 1~2.2；
- **使用强化**：每次召回 +2%，最多 20 次（+40%）；
- **时间衰减**：30 天半衰期；衰减锚点取「最近更新」与「最近召回」中较晚者，
  更新或召回都会让权重回升，避免每次滚动更新都把旧记忆刷成满权重；
- `timeWeight(now:)` / `weightLabel` 接口保留，记忆页与提示词展示综合权重。

召回与访问记录：

- `ChatEngine.recallLongTermMemory` 在把长期记忆拼进提示词后，best-effort 调用
  `MemoryStore.recordMemoryAccess(ids:at:)`；
- 该方法只做 `access_count + 1` 并刷新 `last_accessed_at`，
  **不修改摘要、`updated_at` 或 `source_count`**；
- `fetchMemories` / `fetchMemoriesForPrompt` 先核心优先，再按新综合权重降序排序；
  提示词默认最多 6 条（核心 + 当前会话 + 全局）。

## 5. 记忆文件夹（记忆页 · 长期记忆模式）

- 页面改为**左侧文件夹栏 + 右侧记忆列表**（与「聊天记录」模式的双栏结构一致）。
- 文件夹：
  - **全部记忆**：所有长期记忆；默认选中；
  - **全局记忆**：`conversation_id` 为空的全局记忆；
  - **按会话分组**：只显示有记忆的会话，按会话类型分为「私聊 / 群聊 / 公众号」小节；
  - **未关联会话**：会话已被删除、但记忆仍残留的兜底文件夹（显示原始会话 ID）。
- 每个文件夹行显示文件夹名、长期记忆条数、核心记忆条数（星标）；选中项高亮。
- 选中文件夹后消失（例如删掉最后一条记忆）时自动回退到「全部记忆」。
- 搜索**跨全部记忆**（忽略当前文件夹），标题提示「跨全部记忆」与结果条数；
  无搜索时按当前文件夹过滤。
- 顶部显示当前文件夹标题、条数、核心数，以及综合权重公式说明。
- 新增记忆：
  - 选中**会话文件夹**时预填该 `conversationID`；
  - **全局文件夹 / 全部文件夹**预填空（全局记忆）；
  - 编辑 sheet 中仍可改关联会话、核心标记与摘要。
- 卡片保留摘要、来源会话/全局、★核心、权重、更新时间；
  新增「合并 N 条」（`sourceCount > 0`）与「召回 N 次」（`accessCount > 0`）信息。
- 原有新增/编辑/删除/核心星标/清理 sheet/聊天记录浏览功能保持不变。

## 6. 数据表与迁移

```sql
memories(id, conversation_id, summary, is_core, base_weight,
         created_at, updated_at, last_accessed_at,
         source_count, source, access_count)
memory_state(conversation_id, last_summarized_rowid, updated_at)
```

迁移（`MemoryStore.migrate`）：

- 新库直接按最新结构建表（`memories.access_count INTEGER NOT NULL DEFAULT 0`）。
- **旧库升级**：
  - `user_version < 2`：初始化 `memory_state` 游标为各会话当前最大 rowid，
    升级前的历史消息不批量补总结，只总结升级后的新消息；
  - `access_count` 列用 `PRAGMA table_info` 做列探测，缺失时
    `ALTER TABLE memories ADD COLUMN access_count INTEGER NOT NULL DEFAULT 0;`
    （旧记忆的召回次数从 0 开始）；
  - 迁移结束 `PRAGMA user_version=4;`。
- 会话 `working_hours` 仍用列探测的方式补列，不需要单独的版本号。

## 7. 验证

单元测试（`app/Tests/WeChatAITests/CoreServicesTests.swift`，使用临时目录/独立
`MemoryStore`，不触碰真实数据库）：

- **批量总结**：12 条不总结；30 条一次总结 20 条；50 条再总结 20 条；
  自动记忆始终 1 条、`sourceCount` 依次为 20/40。
- **游标与阈值**：默认 `minOverflow = 1` 的兼容行为；`minOverflow = 20` 时
  12 条返回 `nil`；游标推进后归零；单批最多 `maxMessages` 条。
- **历史清理**：预置两条自动记忆后触发总结，合并为 1 条，
  `sourceCount = 5 + 7 + 20`，摘要包含双方要点。
- **压缩器**：去重（忽略空白/大小写）、空行、`- ` 要点组织、超长输入与超长单行
  均 `<= 600` 且保留尾部最新内容。
- **权重**：60 天衰减约 0.25；`accessCount` 持久化、召回后权重提升且单次幅度很小；
  使用强化上限 +40%；`sourceCount` 对数增长有界。
- **迁移**：手工创建无 `access_count` 的旧表（`user_version = 2`），
  `open()` 后补列、旧数据可读写，`user_version` 变为 4。
- **模型页总开关**：`ChatEngine.forceStream(for:)` 在「流式回复」关闭时返回
  `false`（所有通道非流式），开启时返回 `nil`（按各 provider 的 `stream`）。

构建检查：

```bash
cd app && swift build --build-tests --scratch-path .build-memory
```

## 8. 限制

- 总结内容由模型生成，可能有压缩误差；可在记忆页直接编辑（编辑后转为手动记忆）。
- 批量总结在消息写入后的后台维护中判定：聊天停止时，窗口外未满 20 条的消息
  不会主动补总结，等下次有新消息时继续累积。
- 升级前的旧历史消息不自动补总结，避免升级瞬间产生大量 AI 调用；
  需要时可在记忆页手动新增核心记忆。
- `accessCount` 只在提示词召回时记录；核心记忆每轮都会加入上下文，
  召回次数会较快到达 +40% 上限，这是有意为之。
- 「未关联会话」文件夹只展示已删除会话残留的记忆，无法恢复会话标题/类型；
  删除会话仍会同时删除该会话的长期记忆与总结游标。
- 搜索基于 SQLite `LIKE`（摘要/会话标题/ID），不是全文索引。
