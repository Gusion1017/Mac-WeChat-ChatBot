# 多微信账号数据隔离（账号档案）

> 2026-10-27 起，App 以**当前登录的微信账号**为边界保存聊天与机器人数据：同一台 Mac 上换一个
> 微信账号登录，聊天记录、记忆卡（角色目录）、会话设置、机器人配置、人格与定时任务自动切到该账号自己的档案；
> AI 模型、Hook、OneBot、Keychain、CosyVoice3 安装与音色等「本机能力」仍全局共享。
>
> 对应实现：`Services/WeChatAccountResolver.swift`（识别当前微信账号）、
> `Services/AccountProfile.swift`（账号档案路径/状态/旧版迁移）、
> `Models/AppSettings.swift` + `Services/SettingsPersistence.swift`（全局配置与账号配置双文件）、
> `Core/AppStore+Runtime.swift`（启动、切号与 `MemoryStore` 换库）。
> 总体架构见 [architecture.md](architecture.md)，记忆库细节见 [memory.md](memory.md)，UI 见
> [ui-design.md](ui-design.md)。
>
> 本文是账号档案的行为契约：改存储布局、识别规则、切号顺序或迁移策略时，先改这里，再改代码。

## 1. 行为定义

### 1.1 按微信账号隔离（随账号切换）

- **SQLite 数据库**：会话、消息、旧版长期记忆/`memory_state`（只读兼容）、日志、通讯录缓存、
  统计与 KV（包括 `onebot.self_id` / `onebot.self_id_source`）。
- **角色目录（记忆 v2）**：`accounts/<id>/characters/<会话 key>/memory.sqlite`，
  每微信会话一个目录，随账号目录整体复制/认领；另有固定 `characters/c-__global__/memory.sqlite`
  全局共享记忆（手动维护、注入所有会话，每账号一份）。人格不放在角色目录，统一来自
  `profile.json` 的人格设定（见 [memory.md](memory.md) §3、§4.4）。
- **`profile.json`**：`bot`（触发方式、白/黑名单、节奏、互动、语音偏好、默认人格与默认通道、
  `memory` 记忆设置）、`personas`、`schedules`。
- **新产生的媒体文件**：入站图片/语音、TTS 输出等，写入 `accounts/<id>/media/`。

### 1.2 全局共享（不随账号切换）

- `config.json` 中的 `general`（外观/菜单栏/开机启动/语言/防睡眠等）、`hook`、`onebot`、`ai`、
  `providers`。
- Keychain API Key（service = `com.gusionw.wechatai`，account = `AIProvider.apiKeyReference`）。
- CosyVoice3 安装、运行环境、模型与音色（`cosyvoice/`）。
- 崩溃日志与面包屑（`~/Library/Logs/WeChatAI/`）、bridge 运行日志
  （`~/Library/Logs/WeChatAI/bridge/`）、微信 App 官方备份（`backups/`）。

### 1.3 升级遗留的旧媒体

旧版单库时代写在 `~/Library/Application Support/WeChatAI/media/` 的媒体文件**原样保留**：
旧消息里的绝对路径仍然可读，App 不会移动、复制或删除该目录。升级后新账号的新媒体只写
`accounts/<id>/media/`；旧目录不再写入，也不参与新账号的媒体清理。

## 2. 隔离矩阵

| 数据 / 能力 | 实际位置 | 随微信账号切换 | 说明 |
| --- | --- | --- | --- |
| 会话、消息、日志、统计、通讯录缓存、KV | `accounts/<id>/chatbot.sqlite` | ✅ | 当前账号库；WAL 模式 |
| 角色目录（只有 `memory.sqlite`） | `accounts/<id>/characters/` | ✅ | 每会话一个目录 + 固定 `c-__global__` 全局共享卡；人格不复制，来自账号 `profile.json`；随账号目录整体复制/认领，见 [memory.md](memory.md) §4.4 |
| 旧版长期记忆、`memory_state` | `accounts/<id>/chatbot.sqlite` | ✅ | v1 表只读兼容，运行时不写入、不召回 |
| 机器人 `bot` 设置 | `accounts/<id>/profile.json` | ✅ | 触发/名单/节奏/互动/语音偏好/默认人格与通道 |
| 人格 `personas` | 同上 | ✅ | 每个账号可维护自己的人格设定；是会话人格的唯一来源，不按会话复制 |
| 定时任务 `schedules` | 同上 | ✅ | 只有当前账号的任务参与调度 |
| 会话级设置（AI 开关、工作时段、备注、置顶、图片获取等） | 当前账号库 | ✅ | 存在 `conversations` / `messages` 等表 |
| 新媒体（图片/语音/TTS 输出） | `accounts/<id>/media/` | ✅ | bridge `-media_dir` 指向当前账号目录 |
| 旧版媒体 | `~/Library/Application Support/WeChatAI/media/` | ❌（只读保留） | 旧消息绝对路径继续有效，不迁移、不删除 |
| 通用设置 `general` | `config.json` | ❌ | 外观/菜单栏/语言/防睡眠等本机偏好 |
| Hook / OneBot / AI 通道设置 | `config.json` | ❌ | `hook`、`onebot`、`ai`、`providers` |
| API Key | macOS Keychain | ❌ | 删账号档案不会删除 Keychain 条目 |
| CosyVoice3 安装、运行环境、模型与音色 | `cosyvoice/` | ❌ | 约 8GB，按本机共享 |
| 崩溃日志 / bridge 日志 | `~/Library/Logs/WeChatAI/` | ❌ | 文件日志不区分账号 |
| 微信官方备份 | `backups/` | ❌ | 安装 Hook 前的完整备份 |
| 账号指针 | `account-state.json` | 全局 | 只记录当前/最近账号，不存业务数据 |
| 运行期 Hook 配置 | `runtime/` | ❌ | 由全局 Hook 设置生成 |

> **注意**：记忆 v2 按会话隔离，不同会话之间不共享记忆卡；旧版的「全局记忆」只保留在只读旧表里，
> 可在记忆面板手动导入到某个会话的记忆卡。人格设定在同一账号内是全局模板（修改对所有使用该
> 人格的会话生效），但不会跨微信账号共享。换账号后看到的是新账号自己的角色目录与人格设定。

## 3. 存储布局

### 3.1 目录树

```
~/Library/Application Support/WeChatAI/
├── config.json                     # 全局设置（完整 AppSettings 镜像，兼容旧版回滚）
├── account-state.json              # 全局账号指针
├── accounts/
│   ├── _unassigned/                # 尚未识别微信账号时的临时档案（保留名）
│   │   ├── chatbot.sqlite
│   │   ├── profile.json
│   │   ├── characters/             # 每会话 + 全局共享卡
│   │   └── media/
│   └── <wxid>/
│       ├── chatbot.sqlite (+ -wal / -shm)
│       ├── profile.json            # 当前账号的 bot / personas / schedules
│       ├── characters/             # 每会话 c-<key>/memory.sqlite + c-__global__/ 全局共享
│       ├── media/                  # 该账号的新媒体
│       ├── logs/                   # 预留（当前为空；App 内日志仍在账号库）
│       ├── legacy-migration.json   # 仅旧版迁移目标有：标记旧数据已归入本账号
│       └── unassigned-claim.json   # 仅从 _unassigned 认领过的账号有
├── media/                          # 旧版遗留媒体（只读保留，不迁移、不删除）
├── backups/                        # 微信 App 官方备份（全局）
├── runtime/                        # 运行期 Hook 配置（全局）
├── cosyvoice/                      # CosyVoice3 安装：运行环境、模型与音色（全局）
└── chatbot.sqlite                  # 旧版单库（迁移后保留，不删除）
```

### 3.2 关键文件

| 文件 | 所有者 | 说明 |
| --- | --- | --- |
| `config.json` | `SettingsStore` / `SettingsPersistence` | 全局设置，保持旧路径与旧格式；同时保留 `bot`/`personas`/`schedules` 字段作为旧版回滚镜像，运行时由 `profile.json` 覆盖 |
| `account-state.json` | `AccountProfile` | `{"schemaVersion":1,"lastAccountID":"wxid_xxx","updatedAt":<Unix 秒>,"legacyMigrationDone":true}`；启动早期只读，`activate`/迁移后原子写。`legacyMigrationDone` 只有旧库迁移真正完成后才为 `true`，切号/回滚不会替它置位 |
| `accounts/<id>/chatbot.sqlite` | `MemoryStore` | 当前账号的会话/消息/日志/KV（旧 `memories` / `memory_state` 只读兼容）；切换账号即关闭旧库、打开新库 |
| `accounts/<id>/characters/` | `CharacterStore` | 记忆 v2 的每会话角色目录（只有 `memory.sqlite`）+ 固定 `c-__global__` 全局共享卡；人格来自账号 `profile.json`，不写 `persona.md`；随账号目录复制/认领 |
| `accounts/<id>/profile.json` | `SettingsStore` | `ProfileSettings`：`schemaVersion`、`bot`（含 `memory` 设置）、`personas`、`schedules`；缺失时用默认值 |
| `accounts/<id>/media/` | `OneBotClient` / 语音流水线 | 该账号新媒体的落盘目录，按日期分子目录（`<yyyy-MM-dd>/`） |
| `accounts/<id>/logs/` | 预留 | 预留给未来按账号切分文件日志；当前账号库内 `logs` 表才是 App 内日志 |
| `accounts/<id>/legacy-migration.json` | `AccountProfile` | 旧版迁移标记；存在表示该账号接收了旧单库数据；内容以供排查为主，不是业务配置 |
| `chatbot.sqlite`（根） | 旧版 | 迁移后保留；应用不再写入，供回滚或人工核对 |
| `media/`（根） | 旧版 | 旧媒体只读保留 |

### 3.3 JSON 形态

`account-state.json`（示例，wxid 为占位符）：

```json
{
  "schemaVersion": 1,
  "lastAccountID": "wxid_xxx",
  "updatedAt": 1761000000,
  "legacyMigrationDone": true
}
```

`profile.json`（示例，省略具体人格/任务内容）：

```json
{
  "schemaVersion": 1,
  "bot": { "enabled": false, "replyToDirect": true, "keywords": ["AI"] },
  "personas": [ { "id": "persona-default", "name": "默认助手", "isDefault": true } ],
  "schedules": []
}
```

`ProfileSettings.schemaVersion` 当前为 `1`；`BotSettings`/`Persona`/`ScheduledTask` 仍按各自
Codable 兼容旧键。旧 `config.json` 缺少新字段时不会导致 profile 解码失败。

### 3.4 写入与原子性

- `AccountProfile` 的静态状态（activeID、pendingNotice 等）由 `NSLock` 保护；
  `preparePaths()` 可重复调用。
- 所有 JSON/状态写入使用 `Data.write(options: .atomic)`（或临时文件 + replace）；
  目录创建幂等。
- 除迁移「复制」外，不 `removeItem` 用户数据目录；旧单库、旧媒体、旧 `config.json` 一律保留。
- 账号 ID 同时用作目录名，不做额外编码：校验规则见 §4.2，已排除路径穿越。

## 4. 账号识别算法

### 4.1 识别优先级

`WeChatAccountResolver.resolve()` 只读文件系统元数据（`stat`/JSON），不打开 SQLite。
微信 Documents 根默认是：

```
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/
```

按以下优先级识别：

1. **登录标记 mtime（source = `loginMarker`）**
   - `app_data/login/<wxid>/key_info.dat`
   - `xwechat_files/all_users/login/<wxid>/key_info.db`（含 `-wal`）
   - 取两类文件最近修改时间的**最大值**；只接受在 `xwechat_files/<wxid>_<suffix>/` 下确实有
     数据目录的账号，避免把已卸载/残留登录标记当作当前账号。
2. **账号目录活动（source = `accountActivity`）**
   - 取 `xwechat_files/<wxid>_<suffix>/` 本身、`temp/`、`db_storage/`、
     `db_storage/session/session.db`、`db_storage/message/message_0.db` 的 mtime 最大值。
   - 等价于旧 `AppResources.imageDirectory()` 的启发式，用于登录标记不可读/不新鲜的场景。
3. **都没有** → 返回 `nil`。

多个账号 mtime 相同时按账号字典序稳定排序，结果可重复。
识别成功时通过 `WeChatAccountResolution.imageDirectory` 带回该账号的
`xwechat_files/<dir>/temp`（存在时），用于 bridge `-image_path`。

### 4.2 账号 ID 与 mask 显示

- 合法账号 ID：`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`。
- `_unassigned` 是保留名（不是合法微信 wxid，只表示「尚未识别」），不能作为真实账号目录
  （合法 ID 的首字符必须是字母或数字）。
- `AppAccount.maskedID`：
  - `_unassigned` → `未识别`；
  - 长度 ≤ 10 → 原样；
  - 否则 → 前 9 个字符 + `…` + 后 4 个字符。
- UI、日志、文档示例只展示 mask 后的值或 `wxid_xxx` 占位符，不写真实 wxid。

### 4.3 权威确认：bridge `get_login_info`

resolver 是启动/启动机器人时的账号判定来源；它不是绝对事实（微信未登录、历史账号目录、
登录标记滞后都会影响），因此 bridge 启动后 App 还会主动请求 `get_login_info` 做确认：

- 已识别账号时，App 会把当前档案的 `AccountProfile.activeID` 传给 bridge（`-self_id`），
  正常情况下 `get_login_info` 回包与档案一致；
- 若 bridge 回包与当前档案不一致（例如 `-self_id` 未被采用、显式 `onebot.imagePath` 指向了
  另一个账号目录、或当前仍是 `_unassigned`），以回包为准走切号流程（§5.3）；
- 与档案一致 → 记录 `onebot.self_id` 与 `onebot.self_id_source=login`，历史修复可以信任它、
  跳过历史事件反推；
- 不一致 → 绝不在旧账号库上按新账号 selfID 做「修复」（否则会污染两个账号的数据）；
- 返回值不满足账号 ID 校验（无法安全用作目录名）→ 记 warning 并忽略，不落盘。

> 因此「换号」的常规判定发生在启动/启动机器人前（resolver + 登录标记）；bridge 回包是
> 运行期确认与兜底。两者冲突时以回包为准，但不会拿它去改写其它账号的库。

### 4.4 `preparePaths()` 的行为

`AccountProfile.preparePaths()` 在 App 启动早期、`SettingsStore.load()` **之前**同步调用，
只做 `stat`/JSON 读取，不打开 SQLite：

1. 用 resolver 检测微信账号；
2. 读 `account-state.json`（缺失/损坏按无状态处理）；
3. provisional activeID：
   - 若 `state.lastAccountID == _unassigned`、`_unassigned/` 已有数据库/`profile.json`、
     且 resolver 检测到真实账号 → **保持 active = `_unassigned`**，不写 state；
     由 bootstrap 在开库前认领（§5.1、§7.2）；
   - 否则 resolver 检测到的账号；
   - 否则 `state.lastAccountID`（若合法）；
   - 否则 `_unassigned`；
   - 旧库 owner 不在这里读取——只有 `state` 缺失/不可用、需要迁移时才由迁移读取（§6）；
4. 除上述“等待认领”情况外，若检测到的账号与 `state.lastAccountID` 都存在且不同：
   设置 `pendingNotice = "检测到微信账号已切换"`，并把 detected 原子写回
   `account-state.json`（只写 JSON，`legacyMigrationDone` 沿用旧值）：
   这样下次启动即使微信已退出/检测失败，也不会回退到旧账号或重复提示；
5. 设置 active，调用 `ensureDirectories(for:)`。

`runLegacyMigrationIfNeeded()` 之后可能把 active 改成旧库 owner，调用方需要重新加载设置（§5.1）。

## 5. 切号流程

切号只有一个入口：`RuntimeCoordinator.switchAccount(to:reason:)`。所有路径（启动检测、
启动机器人前检测、运行中 `get_login_info` 不一致、设置页「重新检测」）最终都收敛到它，
避免出现多套「部分切库」逻辑。

### 5.1 启动时（App 启动）

```
AppStore.init
  └─ AccountProfile.preparePaths()          # 只读 stat/JSON，决定 provisional active
  └─ SettingsStore.load()                   # config.json + 当前 active 的 profile.json
RuntimeCoordinator.bootstrapIfNeeded / performBootstrap
  └─ AppPaths.ensureDirectories()
  └─ Task.detached { AccountProfile.runLegacyMigrationIfNeeded() }   # 后台阻塞 IO
  └─ 若 active 变化或迁移写了 profile 种子：store.applyLoadedSettings(SettingsStore.load())
                     store.refreshAccountObservables(notice:)
                     active 变化时清空运行时 selfID
  └─ Task.detached { AccountProfile.claimUnassignedForStartup(detectedAccountID:) }
                     # _unassigned 有数据且已识别账号时，在开库前归入目标账号
                     # 成功后重新 load profile / 刷新 observables
  └─ memory.open()                          # 打开最终 active 的账号库（此前禁止隐式 open）
  └─ characterStore.activate()              # 指向该账号 characters/，按需打开角色记忆卡
  └─ LogPipeline.attach(...)                # 迁移/认领完成、库打开后才接日志落库
  └─ 启动期修复（自消息/伪群/appmsg/引用）只在该账号库内执行
  └─ loadPersistedState / stats / refreshStatus
startRuntime（用户点「启动机器人」）
  └─ resolver 再检测一次；账号变化则先 switchAccount
  └─ bridge 的 -self_id / -image_path / -media_dir 使用当前账号
```

- 迁移与 `_unassigned` 认领必须在 `memory.open()` 之前完成，否则会打开旧单库/临时库，
  或让“已存在的目标库”被迁移误判为已完成。
- `MemoryStore.shared` 在 bootstrap 前禁止隐式 `ensureOpen`，`LogPipeline` 也延后到
  最终账号库打开后 attach；避免启动日志提前创建目标库。
- 迁移/认领是阻塞文件 IO，必须放在 `Task.detached`，不能占用主线程。
- 角色目录跟随账号目录（`accounts/<id>/characters/`）：`characterStore.activate()` 在
  `memory.open()` 之后、载入角色列表之前执行；切号 `suspend()` 后禁止打开记忆卡（best-effort）。
- 启动阶段 bridge 回报的账号若与档案不一致，先记 `pendingAccountSwitch`，
  等 `startRuntime` 收尾后由 `consumePendingAccountSwitchIfNeeded()` 切换。

### 5.2 启动机器人前

`startRuntime()` 在启动 bridge 前调用 `AccountProfile.detectedAccountID()` 再检测一次：

- 检测到的账号与当前档案不同 → 先 `switchAccount(to:reason:.detectedBeforeStart)`，
  再读取新账号的 `profile`、拼接 bridge 参数；
- 已识别账号时，`-self_id` 使用 `AccountProfile.activeID`（不信任旧库可能被污染的 selfID）；
  未识别时沿用运行时 `selfID`（可能为空），等 `get_login_info` 确认后再认领/切换；
- `-image_path` / `-media_dir` 强制使用当前账号目录：已识别账号时忽略全局
  `onebot.imagePath` 用户配置（该值可能来自上一个账号），图片目录取
  `xwechat_files/<dir>/temp`、媒体目录取 `accounts/<当前账号>/media`；
- 当前账号的图片临时目录不存在时**显式阻止启动**并提示先登录微信/打开图片，
  不再回退到按 mtime 猜账号的 `AppResources.imageDirectory()`；
- 未识别账号（`_unassigned`）时才沿用旧的显式 `onebot.imagePath`/自动探测行为。

这样即使「上次 App 启动后才换的微信账号」，也不会把 A 的消息先写进 B 的库再补救。

### 5.3 运行中登录不一致

bridge 返回 `get_login_info` 后，`RuntimeCoordinator.adoptSelfID(_:)`：

- `id == activeID` 且 active 不是 `_unassigned` → 记录权威 selfID 与来源，
  在**当前账号库**内补跑历史修复；
- `id != activeID` 或 active 为 `_unassigned` → 调
  `switchAccount(to: id, reason: .loginMismatch)`，而不是直接在当前库改 selfID；
- 若此时 `startRuntime` 正在逐段启动（bridge → WS → scheduler），先挂起
  `pendingAccountSwitch`，等启动收尾后再切，避免拆到一半的运行时。

`switchAccount` 的顺序：

1. 若机器人/运行时在跑，先停止（bridge、OneBot、调度、媒体队列；停止过程中 flush 日志、
   设置与统计）；
2. drain 旧账号后台写入任务（记忆维护、长记忆总结、群昵称回填、统计落盘、消息预取：
   cancel + await），关键 await 后比对 `accountEpoch`，防止 A 的提取结果写进 B；
3. `characterStore.suspend()`（关闭全部角色记忆卡连接）；
4. `memory.suspend()`（close + 禁止 `ensureOpen` 隐式重开，保证认领前库保持关闭）；
5. `claimUnassigned(by:)`（若 active 仍为 `_unassigned`）或 `AccountProfile.activate(id)`；
6. `memory.switchToActiveAccountDatabase()` 打开新账号库；
7. `characterStore.activate()` 指向新账号的 `characters/`；
8. `SettingsStore.load()` / `store.applyLoadedSettings()` 应用新账号 `profile`；
9. 清空内存中的会话、消息、角色与记忆状态、日志、统计、选中会话、回复进度；
10. 从新库载入会话/消息/状态；
11. `store.persist()`（profile 写回新账号）；
12. 更新 `activeAccountID` / `activeAccountIsUnassigned` / `savedWeChatAccounts` /
    `accountSwitchNotice`，`store.settings.bot.enabled = false`、`isBotRunning = false`。

切号期间 `isSwitchingAccount = true`：设置页「重新检测」和总览/菜单栏的启动按钮都会禁用；
`startBot` / `startRuntime` / `reconcileWeChatAccount` 也会拒绝并发启动，避免 bridge 用旧档案身份启动。

切换失败时尽力 `activate(previousID)` 并重新打开原库，同时把 `isBotRunning` / `bot.enabled`
复位为 false（避免按钮仍显示“运行中”而无法重试）、记录失败原因并提示重试，
不会把两个账号的数据写进同一库。

**切换后不会自动重启机器人**：运行中的切号会停止机器人，由用户在总览或菜单栏重新启动；
这避免用户没注意到切号就自动用新账号回复。

### 5.4 三条路径对比

| 触发时机 | 检测方式 | 对 active 的处理 | 用户可见结果 |
| --- | --- | --- | --- |
| App 启动 | `preparePaths` + 旧版迁移 + `_unassigned` 认领 | provisional →（迁移可能改为旧库 owner）→ 认领临时档案 → 打开最终库 | 启动后直接是正确账号；若检测到变化/认领显示提示 |
| 点「启动机器人」前 | resolver 再检测 | 启动 bridge 前切到检测到的账号 | 新账号的聊天/配置；bridge 用新账号 selfID 与媒体目录 |
| 运行中换微信账号 | bridge `get_login_info` 权威值 | 停止运行时 → 切库/配置 → 提示 | 机器人停止、数据切换、总览提示；需手动重新启动机器人 |

设置页「重新检测微信账号」调用 `store.refreshWeChatAccount()`：
仅当 resolver 检测到的账号与当前档案不同才切库，返回是否真的切换。检测不到、无变化或
`managesAccountProfiles == false`（测试/诊断注入设置）时返回 `false`，不触碰本机账号目录。

### 5.5 失败处理

- 任一步失败都不得把两个账号的数据写进同一库：切换在停运行时之后才 `activate` /
  换库，失败时保持运行时停止，写错误日志并提示用户重试。
- 重新检测、重新启动 App 或再次启动机器人都可以重试；不要手动把 `account-state.json`
  改成别的账号来「救数据」——这会让 App 打开错误档案。

## 6. 旧版迁移

### 6.1 触发条件

升级后首次启动时：

- `account-state.json` 不存在/不可用，或存在但 `legacyMigrationDone=false`；
- 且根目录存在旧版单库 `chatbot.sqlite`（或只剩旧 `config.json` 的账号级设置）；
- 没有旧单库时也会写 state（`legacyMigrationDone=true`）并把“只剩配置”的 profile 种下。

迁移在 `performBootstrap` 中通过 `Task.detached` 调用
`AccountProfile.runLegacyMigrationIfNeeded()`，同步返回 `LegacyMigrationOutcome`：

```swift
struct LegacyMigrationOutcome {
    var activeAccountID: String
    var didMigrate: Bool
    var legacyOwnerAccountID: String?
    var notice: String?      // 可展示给用户的中文说明；nil = 无需提示
}
```

### 6.2 确定旧数据的 owner

- 用 SQLite 打开旧库（仅执行 SELECT / Backup API，不写业务数据）查询：
  `select value from settings where key='onebot.self_id'`。
  注意：旧库通常是 WAL 模式，旧 App 干净退出后可能只剩主库、没有 `-wal`/`-shm`；
  此时 READONLY 连接会 CANTOPEN，必须用 READWRITE 连接让 SQLite 恢复 WAL 辅助文件。
- owner = 该值通过 `AppAccount.isValidID` 校验的账号；否则视为无 owner。
- target = `owner`（有效）或当前 provisional active（resolver 结果，或 `_unassigned`）。

> 旧库的 `onebot.self_id` 是旧版运行时从 bridge/历史事件学到的账号，最接近旧数据的真实归属。
> 不读旧 `config.json` 猜 owner；旧配置只用于 seed profile。

### 6.3 迁移动作（只 copy，不删除）

- **数据库**：用 **SQLite Backup API** 打开旧库（READWRITE，仅备份）、复制成目标目录里的一致快照，再移动到
  `accounts/<target>/chatbot.sqlite`；**仅当目标主库不存在时复制**。
  目标库已存在说明之前迁移过，不再覆盖。不裸 copy `-wal`/`-shm`——Backup API 已包含 WAL 中
  已提交的内容，避免并发写下复制到不一致的库。
- **profile 种子**：仅当 `accounts/<target>/profile.json` 不存在，且旧 `config.json` 顶层
  确实有 `bot` / `personas` / `schedules` 时，写入 `ProfileSettings` 种子。
  旧配置缺失这些键时保留 `.default`。若旧库已不存在但旧配置还在（「只剩配置」升级），
  当前 active 是真实账号时也会只做 profile 种子，不复制数据库。
- **角色目录**：`characters/` 不单独迁移，登录后收到消息（或首次回复）按人格设定新建记忆卡
  （只有 `memory.sqlite`，不写 `persona.md`、不生成初始记忆；首次维护补总结最近 500 条
  建卡前历史互动，见 [`memory.md`](memory.md) §7.2）。旧版本每会话的 `persona.md`
  不再读取，会在该会话创建/加载记忆卡时 best-effort 移到废纸篓，未迁移的自定义正文不会采用。
  打开旧 `memory.sqlite` 时还会执行 2026-10-28 起点迁移：生成型 `kind='origin'` 行删除，
  用户编辑过的转普通置顶手写记忆（见 [`memory.md`](memory.md) §4.3）。
  旧库里的 `memories` 表随 `chatbot.sqlite` 快照保留只读，不自动写入记忆卡。
  需要旧记忆时由用户在记忆面板手动「导入旧记忆」（见 [`memory.md`](memory.md) §3.3、§13）。
- **目标已有空库**：若目标库存在、迁移 marker 不存在且库内
  `conversations/messages/memories/settings` 全为空，则用旧库快照原子替换
  （兼容旧实现“迁移前提前开库”留下的空壳）；目标库有任何业务数据则绝不覆盖。
- **迁移标记**：写 `accounts/<target>/legacy-migration.json`，记录
  `schemaVersion` / `migratedAt` / `targetAccountID` / `legacyOwnerAccountID`（有 owner 时）/
  `legacyDatabasePath` / `copiedDatabase` / `seededProfile`，便于排查与后续幂等判断。
- 旧 `chatbot.sqlite`、旧 `config.json`、旧 `media/` **全部保留**；旧库的 `-wal`/`-shm`
  也原样保留（不再被新 App 打开）。
- 迁移完成后写 `account-state.json`，记录最终 active、`updatedAt` 与
  `legacyMigrationDone=true`。

### 6.4 最终 active 与提示

`finalActive` 规则：

1. 当前 active 不是 `_unassigned` → 保持当前 active（例如用户已经登录了新账号，
   旧数据仍归 owner，不把新账号的当前会话切走）；
2. 否则 owner 有效 → owner；
3. 否则 target（即当前 active）。

`notice` 优先说明「旧版本数据已归入账号 <maskedID>」；没有迁移/无需提示时为 `nil`。
UI 在总览用 `InlineNotice` 展示，见 [ui-design.md](ui-design.md)。

### 6.5 幂等与重试

- `account-state.json` 已存在、`lastAccountID` 可用且 `legacyMigrationDone=true`
  → 直接返回当前 active，`didMigrate = false`，不再读旧库、不再复制。
- state 存在但 `legacyMigrationDone=false`（迁移失败后切过号/回滚过）→ 仍会重试迁移；
  `activate`/`preparePaths` 写 state 时沿用旧 flag，绝不替迁移“盖章”。
- 没有旧单库时也会写 `account-state.json`（active = 当前 active）；若旧 `config.json`
  仍有账号级设置且当前已是真实账号，会先补 profile 种子（`didMigrate = true`）。
- 目标库已存在 → 跳过数据库复制；目标 profile 已存在 → 跳过 seed。
- 迁移中途失败（磁盘满、权限、旧库损坏）→ 不把 `legacyMigrationDone` 置 true
  （可能已有 state 但 flag=false），下次启动重试；已复制的文件不会覆盖目标，
  也不会删除旧数据。
- 迁移只在 `legacyMigrationDone=false` 时执行；成功后任何重启都不再执行。

### 6.6 旧媒体与回滚

- 旧 `media/` 不迁移：旧消息 `mediaPath` 是绝对路径，继续指向旧目录即可显示；
  新账号的新媒体写入 `accounts/<id>/media/`。
- `config.json` 保留完整 `AppSettings` 镜像（含 `bot`/`personas`/`schedules`），
  即使旧版 App 回滚也能读到一份可用的旧配置；当前版本以 `profile.json` 为准。
- 旧媒体目录在未来也不会被自动清理；删除账号目录或旧 `media/` 会破坏对应旧消息的媒体显示。

### 6.7 迁移边界情况

| 情况 | 行为 |
| --- | --- |
| 没有旧单库 | 写 `account-state.json`（active = 当前 active）；若旧 config 仍有账号级设置且 active 是真实账号，只补 profile 种子，`didMigrate` 反映是否恢复 |
| 旧库没有 `settings` 表 / 没有 `onebot.self_id` | owner 无效 → 归当前 active |
| owner 有效但当前已登录另一个账号 | 旧库归 owner；active 保持当前账号（不混库） |
| owner 等于当前 active | 直接复制到该账号档案 |
| 复制中断 | 下次启动重试；只补缺失文件，不覆盖已有目标库 |
| 用户手动删过旧库 | 视为没有旧单库，不再复制数据库；旧媒体仍在 |
| `_unassigned` 有数据、首次登录 | 通过 `claimUnassigned` 认领（§7），不走旧库迁移 |

### 6.8 迁移验收清单

- [ ] 升级前旧库 `settings.onebot.self_id = A`；启动后 `accounts/A/chatbot.sqlite` 存在且
      会话/消息/记忆条数与旧库一致。
- [ ] 根目录旧 `chatbot.sqlite`（含 `-wal`/`-shm`）、旧 `config.json`、旧 `media/` 仍在。
- [ ] `accounts/A/profile.json` 含旧 `config.json` 的 `bot`/`personas`/`schedules` 种子；
      再次启动不重复写。
- [ ] `account-state.json.lastAccountID = A`，`accounts/A/legacy-migration.json` 存在。
- [ ] 第二次启动（删除/保留 state 两种）幂等：不重复复制、不覆盖已有 profile。
- [ ] 旧消息里的旧媒体路径仍可打开，新消息媒体落在 `accounts/A/media/`。

## 7. `_unassigned` 与认领

### 7.1 何时使用 `_unassigned`

首次安装、或启动时 resolver 无法识别账号（微信未登录、容器不可读、登录标记未生成）时，
active = `_unassigned`。此时聊天、记忆、配置都写入 `accounts/_unassigned/`，
不会丢弃，也不会猜一个账号归属。

### 7.2 认领（claim）

bridge `get_login_info` 确认真实账号 `<id>` 后：

- 启动阶段（`performBootstrap`，开库前）：`claimUnassignedForStartup(detectedAccountID:)`
  会在 state 已停在 `_unassigned` 或 active 暂未识别时自动认领；成功后 `activate(id)`。
- 运行中（`switchAccount`）：`AccountProfile.claimUnassigned(by:)`。
- 条件：目标 `accounts/<id>/chatbot.sqlite` 不存在，或只是“空壳库”
  （`conversations/messages/memories/settings` 全空）；目标已有业务数据时不复制、返回 `false`。
- 动作：调用方先 `CharacterStore.suspend()` / `MemoryStore.suspend()`（close + 禁止隐式 open），
  再把 `_unassigned/` 内容先复制到 `accounts/` 下的 staging 目录，随后逐项 move 到目标账号目录
  （数据库文件单独 staged + 原子替换；`characters/` 角色目录随目录整体复制）；
  写 `unassigned-claim.json` 标记。
- `_unassigned/` 原样保留，不删除、不改名；中断/磁盘满时下次启动重试。

### 7.3 为什么要保留 `_unassigned`

- 微信未登录时产生的消息/记忆可能是真实数据，不能因为「还没识别」就丢弃；
- 保留原目录便于排查「第一次登录前写的消息去了哪」；
- `_unassigned` 是保留名，不会与真实 wxid 冲突，也不出现在「已保存的账号」列表中。

## 8. 边界与限制

1. **同一时间只有一个 active 账号库**。App 一次只服务一个微信登录；换账号 = 关旧库、开新库，
   不是两个库同时在线。
2. **不能手动切库**。UI 不提供「选择数据库/账号档案」入口；切号只由微信登录状态（resolver）
   与 bridge `get_login_info` 驱动。手动改 `account-state.json` 或目录名不在支持范围内。
3. **未登录账号的数据保留**。退出微信账号、换号、删除某账号的聊天都不会删除其它账号档案；
   账号目录也只能由用户自行决定是否清理。App 不提供「删除账号档案」按钮。
4. **删除聊天只删当前账号**。`clearMessages` / `deleteConversation` 作用于当前 active 的
   `MemoryStore`，不会跨账号删除；删除会话仍会删除该会话的旧长期记忆与总结游标，并把该会话的
   角色目录移到废纸篓（见 [memory.md](memory.md) §10）。
5. **Keychain、CosyVoice3 安装与音色、崩溃与 bridge 日志全局**。换账号不会更换 API Key、
   不会重新安装 CosyVoice3 运行环境/模型，也不会切换日志目录；排查问题时注意日志是全局的，
   业务数据是分账号的。
6. **旧媒体路径保留**。旧版 `media/` 不迁移；新账号的新媒体在账号目录。手动移动/删除旧目录
   会使旧消息中的媒体失效。
7. **首次升级可能需要额外磁盘**。旧单库是「复制」而非移动，升级后新旧数据同时存在；
   请预留与旧库同量级的磁盘空间。确认无误前不要删除旧库。
8. **机器人不会自动重启**。运行中切号后 `isBotRunning = false`；需要用户手动启动机器人。
9. **历史修复只作用于当前账号库**。启动期自消息/伪群/appmsg/引用修复在打开 active 库后执行；
   切换账号后不会拿新账号 selfID 去修旧账号库。
10. **profile 保存按账号隔离**。`persist()` 在调用时捕获 `profileURL`；切号后延迟到达的旧
    快照仍写回旧账号 profile，不会把 A 的机器人配置写进 B。
11. **账号目录名必须可安全用于路径**。非法/异常登录 ID 被忽略并记 warning；
    不要手动创建不符合 §4.2 规则的目录。
12. **多开微信不支持**。App/bridge 仍按单微信实例设计；同时登录多个微信账号会产生不可预测的
    数据归属。

## 9. UI 入口与文案

### 9.1 设置 → 数据与备份

新增「当前微信账号」区块：

- 账号（`AccountProfile.maskedActiveID`，未识别时显示「未识别（等待微信登录）」与「临时档案」徽标）；
- 账号数据目录（`accounts/<id>/`）；
- 账号配置（`accounts/<id>/profile.json`）；
- 会话数据库（`accounts/<id>/chatbot.sqlite`，旧记忆表只读）；
- 角色目录（记忆 v2，`accounts/<id>/characters/`）；
- 媒体目录（`accounts/<id>/media/`）；
- 全局配置（`config.json`）、备份目录（`backups/`）、
  运行日志目录（`~/Library/Logs/WeChatAI/`，与 bridge/崩溃日志同级）；
- 说明文案：哪些随账号切换、哪些全局共享（与 §1/§2 一致）。

「已保存的账号」列表：

- 数据来自 `AccountProfile.savedAccounts(limit:)`，按最近使用倒序；
- 显示 `maskedID`、最近使用时间、当前账号标记，并提供「在 Finder 中显示」；
- 不显示 `_unassigned`；没有其它账号时可只显示当前账号或空状态；
- 不提供点击切号：列表仅用于查看与定位目录。

「重新检测微信账号」按钮：

- 调用 `await store.refreshWeChatAccount()`，期间按 `store.isSwitchingAccount` 禁用；
- 机器人启动中检测到变化 → 先排队（`store.accountSwitchPending`），toast 提示
  「机器人正在启动，完成后会自动切换账号数据」；
- 切换成功 → toast「已切换到当前微信账号的数据」；
- 仍未识别到账号 → error toast「仍未识别到微信账号，请先登录微信后重试」；
- 检测到但切换未生效 → error toast（展示 `store.lastAccountSwitchError` 的失败原因，并回退到原账号）；
- 没有变化 → info toast「未检测到账号变化」；
- 不伪造成功。

### 9.2 总览

`store.accountSwitchNotice` 非空时，总览顶部显示
`InlineNotice(kind: .info, title: "微信账号已切换")`，正文为 notice（例如旧数据归入哪个账号），
右侧「知道了」调用 `store.dismissAccountSwitchNotice()`。运行中切号还会伴随 `isBotRunning = false`，
用户需要重新启动机器人。

### 9.3 文案与本地化

- 中文是源语言；新增 `L("…")` 需要同步 `app/Packaging/en.lproj/Localizable.strings` 与
  zh-Hans 身份表（由 UI 任务维护）。
- 不在 UI 中展示完整 wxid；账号列表、日志与路径展示用 mask 或完整路径（路径本身就是本机文件）。

## 10. 契约与不变式

关键接口（详见 `Services/AccountProfile.swift` 与 [architecture.md](architecture.md) §5）：

```swift
struct AccountLayout {
    let root: URL                         // AppPaths.supportDirectory
    var accountsDirectory: URL
    var stateFile: URL                    // root/account-state.json
    var legacyDatabaseFile: URL           // root/chatbot.sqlite
    var legacyMediaDirectory: URL         // root/media
    var legacyConfigFile: URL             // root/config.json
    func directory(for id: String) -> URL
    func databaseFile(for id: String) -> URL
    func profileFile(for id: String) -> URL
    func charactersDirectory(for id: String) -> URL   // 记忆 v2 角色目录
    func mediaDirectory(for id: String) -> URL
    func logsDirectory(for id: String) -> URL
    func ensureDirectories(for id: String)            // 含 characters/
}

enum AccountProfile {
    static var layout: AccountLayout { get }
    static var activeID: String { get }
    static var activeDirectory: URL { get }
    static var databaseFile: URL { get }
    static var profileFile: URL { get }
    static var charactersDirectory: URL { get }   // accounts/<id>/characters/
    static var mediaDirectory: URL { get }
    static var logsDirectory: URL { get }
    static var isUnassigned: Bool { get }
    static var maskedActiveID: String { get }
    static func preparePaths()
    static func activate(_ id: String) throws
    @discardableResult
    static func claimUnassigned(by id: String) throws -> Bool
    static func claimUnassignedForStartup(detectedAccountID: String?) -> UnassignedClaimOutcome
    static func runLegacyMigrationIfNeeded() -> LegacyMigrationOutcome
    static func savedAccounts(limit: Int = 10) -> [SavedWeChatAccount]
    static func detectedAccountID() -> String?
    static func activeImageDirectory() -> URL?
}
```

必须保持的不变式：

1. `AccountProfile.preparePaths()` 早于 `SettingsStore.load()`；它不读 SQLite。
2. `runLegacyMigrationIfNeeded()` 早于 `MemoryStore.open()`，且只在后台线程执行。
3. 旧版迁移只 copy，不删除任何旧文件；`account-state.json` 的
   `legacyMigrationDone=true` 才是幂等门禁，`activate` 不得隐式置位。
4. `claimUnassigned*` / 迁移必须在 `MemoryStore.suspend()` 或未开库时执行；
   目标已有业务数据时不覆盖；`_unassigned` 源保留。
5. 所有切号收敛到 `RuntimeCoordinator.switchAccount(to:reason:)`；先停运行时、drain 后台任务、
   suspend 库，再认领/激活/换库；切号期间禁止启动机器人。
6. `SettingsStore.load()` = 读 `config.json` 完整设置后 `applyProfile(profile.json)`；
   profile 缺失 → `.default`，损坏 → 备份 `profile.corrupt-<ts>.json` 后默认。
7. `SettingsPersistence.save(_:profileURL:)` 在 `profileURL != nil` 时双写 config + profile；
   `profileURL == nil`（包括旧 `save(_:)`，无论 shared 还是 `init(fileURL:)` 测试实例）只写 config；
   两边都按编码字节去重（profile 目标路径变化时强制写）、原子 replace。
8. `AppPaths.databaseFile` / `profileFile` / `charactersDirectory` / `mediaDirectory` 委托
   `AccountProfile`；`AppPaths.ensureDirectories()` 创建 root、bridgeLog、backups、runtime
   与当前账号目录（含 `characters/`），不再把新媒体写入根 `media/`。
9. `MemoryStore` 的 `databaseURL` 在 `open()` 时解析；`shared` 在 bootstrap 前禁止隐式
   `ensureOpen`；切号用 `suspend()` → `switchDatabase(to:)` / `switchToActiveAccountDatabase()`，
   `path` 是 actor 内属性。
10. `account-state.json`、`profile.json` 与迁移文件原子写；目录创建幂等。

## 11. 测试与验收

### 11.1 自动化测试范围

新增/更新测试至少覆盖：

- **识别**：登录标记优先于目录活动；回退目录活动；多个账号稳定排序；非法/不存在目录返回 `nil`；
  无登录标记时回退正确。
- **mask**：`_unassigned` →「未识别」；≤10 字符原样；长 ID 前 9…后 4。
- **布局**：`AccountLayout` 各路径、`ensureDirectories` 幂等、账号 ID 校验。
- **`preparePaths`**：检测账号优先、state 回退、`_unassigned` 兜底、检测到切换时 pendingNotice。
- **迁移**：无旧库、owner 有效、owner 无效、owner == active、owner != active、幂等、
  profile seed、旧文件保留、旧媒体不动。
- **认领**：`_unassigned` 复制到目标、目标已有库不覆盖、`_unassigned` 不删除、调用前 close。
- **配置双文件**：`SettingsStore.load()` 合并 config + profile；profile 缺失/损坏回退；
  `SettingsPersistence` 双写、去重、`profileURL == nil` 只写 config。
- **记忆库切换**：A/B 账号库的会话/消息/旧长期记忆/日志/KV 互不可见；切回 A 数据仍在。
- **角色目录隔离**：A/B 账号的 `characters/` 角色目录/记忆卡互不可见；全局共享卡
  `c-__global__` 也按账号隔离；人格各自来自账号 `profile.json`；切回 A 角色列表与记忆卡完整；
  `_unassigned` 认领/旧版迁移后 `characters/` 随账号目录整体复制。
- **WAL 迁移回归**：旧库为 WAL 模式且 `-wal`/`-shm` 已删除时，owner 读取与 Backup API
  仍能成功（READONLY 会 CANTOPEN）；迁移出完整会话/消息。
- **回归（2026-10-28 审查修复）**：`_unassigned` 有数据时 preparePaths 保持 active 并等待
  启动认领；启动认领复制 DB/profile/media 且不删源、不覆盖已有目标；空壳目标库可被迁移/认领替换；
  `legacyMigrationDone=false` 时迁移会重试、activate 不置位；`MemoryStore.suspend()` 后
  隐式 open 被拒绝、切库后恢复写入。
- **运行时切号（集成/手工验收，未放入 XCTest）**：启动前检测、运行中 `adoptSelfID`
  不一致走切号、切换后机器人停止、`refreshWeChatAccount()` 返回值与设置页状态。
  这组路径依赖运行中的 bridge/微信与 AppStore 全局静态状态，放在 §11.2 手工验收，
  不伪装成单元测试；可在未登录微信的 Mac 上走 `_unassigned` → 识别 → 切号流程。

测试使用临时目录/独立 `MemoryStore`，不触碰真实 `~/Library/Application Support/WeChatAI`；
注入 `AppSettings` 的 AppStore 测试不得调用 `preparePaths`/迁移（`managesAccountProfiles == false`）。

### 11.2 手工验收

- [ ] 全新安装、微信未登录：数据写到 `accounts/_unassigned/`；登录 A 后认领到 `accounts/A/`，
      `_unassigned` 保留。
- [ ] A 账号聊天/记忆/人格/定时任务存在；退出微信、登录 B 后启动机器人：B 显示空数据，
      总览提示账号已切换；切回 A 数据完整。
- [ ] A 账号记忆卡（角色目录/记忆卡）存在；登录 B 后记忆页只显示 B 自己的角色，人格名来自
      B 的人格设定；切回 A 恢复；旧 `memories` 表数据仍在但 v2 默认不展示（需手动导入）。
- [ ] 旧版本留下的每会话 `persona.md`：首次创建/加载该会话记忆卡后被移到废纸篓，
      人格仍按当前人格设定生效。
- [ ] A 账号的全局共享记忆（`characters/c-__global__/`）注入 A 的所有会话；切到 B 后只看到
      B 自己的全局记忆，A 的全局记忆不会被注入。
- [ ] 运行中退出 A 登录 B：机器人自动停止、数据切到 B、提示可见；手动启动后以 B 身份回复。
- [ ] 设置 → 数据与备份：账号 mask、目录、profile、库、媒体、全局路径与「已保存账号」列表正确；
      「重新检测」在无变化/切换/失败三种情况下提示符合预期。
- [ ] 升级旧版：旧库与旧媒体仍存在；数据出现在旧 `self_id` 所属账号；profile 种子正确。
- [ ] 旧消息里的旧媒体仍显示；新消息媒体在 `accounts/<id>/media/`。
- [ ] 删除当前账号的聊天不影响其它账号数据，也不删除账号目录。

### 11.3 命令

```bash
cd app && SWIFT_DISABLE_SANDBOX=1 swift test --disable-sandbox
python3 scripts/check_docs.py
bash scripts/check.sh --docs
```

当前基线：`swift test` 525 项执行（523 通过 / 2 项按环境跳过：真实 CosyVoice3 服务 E2E）。

## 12. 排障

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| 账号显示「未识别」 | 微信未登录、容器无权限、登录标记未生成 | 登录微信后重启 App，或在设置 → 数据与备份点「重新检测」；检查 系统设置 → 隐私与安全性 → App 数据 |
| 数据出现在错误账号 | 旧库 `onebot.self_id` 与预期不同、或运行中切号提示未注意 | 查看 `account-state.json`、`accounts/*/legacy-migration.json` 与 bridge 日志；不要手动改名/合并目录，先备份再排查 |
| 升级后旧聊天「消失」 | 旧数据已归入旧 `self_id` 所属账号，而当前登录的是另一个账号 | 切回原微信账号；确认 `accounts/<旧账号>/chatbot.sqlite` 与 `legacy-migration.json` |
| 升级后旧聊天/记忆为空，但旧 `chatbot.sqlite` 仍在 | 2026-10-28 前的构建在旧库为 WAL 模式、且 `-wal/-shm` 已删除时，READONLY 迁移失败后打开了空库 | 升级到修复版；停止 App，备份并移走空 `accounts/<id>/` 与 `account-state.json`（或把 `legacyMigrationDone` 置 false），重新启动让迁移重跑；旧库/旧媒体不要删 |
| 换号后机器人不回复 | 切号会停止机器人，且不自动重启 | 确认总览提示；手动启动机器人 |
| 新消息图片仍指向旧目录 | 旧消息的 `mediaPath` 是历史绝对路径 | 属预期；旧媒体保留在根 `media/`，不自动迁移 |
| `profile` 反复回默认 | `accounts/<id>/profile.json` 解码失败，已备份为 `profile.corrupt-<ts>.json` | 查看备份与日志；修复 JSON 后重启，勿删除账号库 |
| 切换后仍写旧库 | 运行时未真正停止或切换失败 | 停止机器人/重启 App 重试；检查日志中 `switchAccount` 与 `memory.open` 的报错 |

## 13. 相关文档

- [architecture.md](architecture.md)：总体数据流、bridge `-self_id` / 媒体目录契约、配置与密钥。
- [core-services.md](core-services.md)：启动顺序、`SettingsStore`/`SettingsPersistence` 双文件、
  `MemoryStore` 换库与切号 API。
- [memory.md](memory.md)：记忆系统 v2（每会话记忆卡、全局共享记忆、人格设定单一来源）与旧记忆只读兼容。
- [ui-design.md](ui-design.md)：设置 → 数据与备份的账号区块、总览切号提示。
- [install.md](install.md)：换微信账号相关 FAQ。
