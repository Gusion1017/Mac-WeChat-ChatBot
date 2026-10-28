# 变更日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与
[语义化版本](https://semver.org/lang/zh-CN/)。日期格式：YYYY-MM-DD。
Hook / 微信版本相关的变更会注明目标微信版本与验证方式。

## [Unreleased]

## [1.7.0] — 2026-10-28

### 变更

- **记忆系统 v2：会话记忆卡 · 人格设定（2026-10-28）**：记忆系统按「一个微信会话 =
  一个记忆卡目录」重做，每个会话在 `accounts/<id>/characters/<会话 key>/` 下保存
  `memory.sqlite`（记忆卡）。**人格统一采用「人格设定」**：每会话不再复制 `persona.md`，
  会话只记录 `personaID` 绑定；旧副本在创建/加载记忆卡时 best-effort 移到废纸篓，
  记忆页移除人设卡 sheet/按钮，姓名/摘要/系统提示词/模型在人格设定中修改后立即生效。
  **移除起点记忆**：新卡默认空；旧库中生成型 `origin` 行删除，用户编辑过的转普通置顶手写记忆；
  记忆页移除起点筛选/统计/徽标。记忆分事实/决策/待办/经验四类、普通/重要两级，按时间
  （72h 最近窗口）、重要度与使用频率加权，普通/重要半衰期 30/180 天；相似度 ≥0.92 自动折叠，
  冲突 supersede 双方留档
  （旧记忆不召回）；每 N 条新互动（默认 8）后台批量 AI 提取，失败走本地兜底；全量互动文本
  永久保存在 `interactions`（清理聊天记录不删除）。App「记忆库」页改为记忆卡面板：角色列表、
  记忆卡、全量记录/记忆设置 sheet、Markdown/JSON 导出、旧记忆手动导入；空状态提供
  「为现有会话创建记忆卡」；修复记忆页继承的撑高、空状态与全量记录首次回填问题。
  **新增全局共享记忆**：固定伪角色 `__global__`（「全局共享」），目录
  `characters/c-__global__/memory.sqlite`；手动维护、注入所有会话、不自动提取、没有全量记录
  且不可删除；记忆页新增全局行，聚合视图同时并入全局记忆。
  **记忆页移除聊天记录模式与重复统计**；清理聊天记录改为**具体会话头部菜单**
  （`ChatCleanupSheet`，仅该会话，无“全部会话”入口；只删本地 `messages`，不动记忆卡/全量记录，
  条数来自账号库 `messageCount`）；移除无用的旧长期记忆运行时状态/API（旧表只读读取与手动导入仍保留）。
  **记忆库入口不再自动打开聚合页**：进入/再次点击只显示角色列表与「选择一个角色」占位，
  「全部角色」/「查看全部角色」显式打开聚合；刷新、建卡、删卡后保持无选择。
  不开放微信 `/记忆` 指令。旧 `memories` / `memory_state` 表保留只读、不自动迁移，
  旧 MemoryStore 记忆方法与单测保留；新增 `bot.memory` 设置随账号 `profile.json`，
  `characters/` 随账号目录整体复制，切号时 `CharacterStore` suspend/activate。
  `swift test` 504 项通过（8 项按环境跳过）。文档同步更新
  [`docs/memory.md`](docs/memory.md)、[`docs/architecture.md`](docs/architecture.md)、
  [`docs/core-services.md`](docs/core-services.md)、[`docs/accounts.md`](docs/accounts.md)、
  [`docs/ui-design.md`](docs/ui-design.md)、根 `README.md` 与本文。

## [1.6.2] — 2026-10-28

### 安全

- **移除 App 二进制中的编译机路径**：`AppResources.candidateRoots()` 不再使用
  `#filePath`。Swift 会把编译机的绝对源码路径嵌入 release 二进制（含本地用户名与目录），
  他人安装后可用 `strings` 读出；Bundle、进程参数与当前目录已能覆盖打包运行与源码运行，
  移除该回退不影响资源定位。已验证 release 二进制不再包含 `/Users/<user>/...` 源码路径。


## [1.6.1] — 2026-10-28

### 修复

- **主线程冻结（性能/功耗）**：`VoiceModelStore.install` 的 365MB 模型 SHA256 校验与
  `tar -xjf` 解包（含同步 `waitUntilExit`）移到后台线程，下载模型时不再出现 10s+ beachball；
  识图前的解码/缩放/JPEG 重编码 + base64 改走 `VisionSupport.imageDataURLAsync`；
  聊天图片气泡改为后台 ImageIO 下采样解码（最长边 1600px），大图滚动不再卡主线程；
  回复热路径（自动回复/识图/引用图/拍一拍）的 Keychain 读取移出 MainActor
  （`RuntimeCoordinator.credentialStateOffMain`），签名失效授权弹窗不再卡死主线程。
- **工作时段跨午夜判定（逻辑）**：22:00–02:00 这类窗口的后半夜改为按「前一天」的星期判定，
  修复「周一~周五 22:00–02:00」在周六 00:30 静默不生效；新增回归测试。
- **启停机器人重入（并发）**：新增 `AppStore.isBotTransitioning` 并在 `startBot/stopBot/
  startRuntime` 全部入口拦截，双击或仪表盘/菜单栏同时点击不再拉起两个 bridge 与两个
  `OneBotClient`（旧连接事件被静默丢弃）。
- **旧配置解码容错（数据）**：`WorkingHours / HumanizeSettings / BotSettings / AISettings /
  OneBotSettings` 改为逐键 `decodeIfPresent`；`SettingsStore.loadConfig` 整体解码失败时
  按顶层段降级解析。旧 `config.json` 缺新键不再导致 onebot token、`hook.wechatPath`、
  providers 等全局设置被默认值覆盖；新增两条旧配置回归测试。
- **防睡眠泄漏（功耗）**：防睡眠断言与机器人运行状态绑定：`startRuntime` 成功后持有，
  `stopRuntime` 立即释放（偏好保留）。停止机器人后整机不再被阻止空闲睡眠。
- **CosyVoice3 空转轮询（功耗）**：健康轮询自适应，最近 2 分钟有合成活动时 5s/次，
  空闲降到 30s/次（原固定 5s，约 1.7 万次/天无效请求）。
- **TTS 引擎常驻（内存）**：Kokoro/ZipVoice 引擎在最后一次合成后 10 分钟无新请求时自动
  `unloadEngines()`（约 350–700MB / 150–250MB RSS），下次合成重新加载。
- **统计跨日**：统计日期翻转挂到 30s vitals 循环（`rolloverStatsIfNeeded`），
  夜间无新消息时总览不再整夜显示昨天的「今日收到/回复」；vitals 的 30s sleep 补 tolerance。
- **会话语音状态批量更新（性能）**：`markPendingVoiceMessagesDisabled` 先收集再一次性
  `merge`，避免边遍历边写字典导致的整字典/整数组 COW 复制。
- **调度器等待者泄漏**：`SchedulerService.start` 先 `wakeUp()` 唤醒旧等待循环，
  重复 start 不再让旧 `CheckedContinuation` 永久悬空。
- **单测隔离（测试）**：`VoiceCloneStore` 的 CRUD 测试改用临时目录
  （新增 `AppPaths.supportDirectoryOverride`），不再写用户真实音色库，受限沙箱/CI 下
  也不会因权限失败（此前的 `CoreAudio -54` 失败源）。
- **App WS 鉴权兼容**：`OneBotClient` 的 WebSocket 连接改用 `URLRequest` 并在 token 非空时
  携带 `Authorization: Bearer <token>`，配合 bridge 新增的 `/ws` 鉴权；旧 bridge 忽略该头。

### 安全

- **bridge `/ws` 鉴权（2026-10-28）**：WS 握手校验 `Authorization: Bearer <token>` 或
  `?token=`（常量时间比较，`-token` 为空时放行）；已有活动连接时拒绝新连接（HTTP 409）；
  连接句柄改为局部变量 + 互斥保护，退出时只清理自己的连接；读限制 8MB、写超时 5s，
  避免任意本机进程订阅事件流/伪造发送动作。

### bridge / hook 修复

- 上传返回值类型：`triggerUploadImg/Video/Voice` 的 RPC 返回 `float64`，原来与字符串 `"0"`
  比较恒为失败（图片/视频/legacy 语音上传永远报错但消息可能已发出）；统一 `fmt.Sprint` 比较。
- R3 发送句柄持久化文件只在 `stale` 状态删除；`off/fail` 保留，符合「跨 bridge 重启恢复」承诺。
- SIGTERM/SIGINT 正常退出改为退出码 0（原走 `Fatal` 退出码 1，App 会误判崩溃）。
- Frida 回调中的 `.(string)` 断言统一改为安全取值 `str()`，字段缺失不再 panic 丢消息。
- legacy（4.1.12）入站媒体不再写入 app bundle（会破坏 ad-hoc 签名，导致下次启动被杀）：
  优先 `-media_dir`，回退 `~/Library/Application Support/WeChatAI/media/legacy`，并统一
  `MkdirAll`（`SaveAudioFile` 缺目录曾导致入站语音整条被丢弃）。
- `hook/script.js` 固定缓冲区写入前做容量检查（256B 路径 / 5MB 语音音频），超长不再写坏
  微信进程堆；`bridge/script.js` 已同步（sha256 一致）。

### 文档 / 项目结构

- 发布说明入库：`docs/releases/1.6.0.md`（原只在 gitignore 的 `dist/`，清理会丢失）。
- `docs/README.md` 更新 Releases 版本/体积与发布记录索引；`docs/bridge.md` 更新 `/ws` 鉴权与
  单连接语义；`docs/core-services.md` 补防睡眠运行时绑定；`docs/cosyvoice.md` 补轮询自适应；
  `docs/voice.md` 补 TTS 空闲释放。
- 构建/发布产物不改变可再生产方式：`app/.build*`、`dist/`、`bridge/onebot` 仍由
  `make bridge` / `make app` / `make release` 生成。

### 验证

- `swift test`：473 项执行，0 失败（8 项按环境跳过）。
- `scripts/build_bridge.sh`：Go 构建 + 全部单元/契约测试通过。
- `scripts/check.sh --docs`：脚本语法、hook/bridge sha 一致、文档链接、hook 版本 JSON 全绿。

## [1.6.0] — 2026-10-28

### 新增

- **多微信账号数据隔离（2026-10-27）**：换微信账号后，聊天记录、长期记忆、会话设置、机器人配置、
  人格与定时任务自动切到该账号自己的档案，新媒体写入 `accounts/<id>/media/`；
  AI 通道/Keychain、Hook、OneBot、语音模型与音色库、CosyVoice、崩溃日志、bridge 日志与微信备份
  全局共享，不随账号切换。
  - **识别与切号**：`WeChatAccountResolver` 按「登录标记 mtime > 账号目录活动」识别，
    最终以 bridge `get_login_info` 为权威；覆盖启动、点「启动机器人」前、运行中登录不一致
    三种切号路径；运行中切号会先停机器人，切库后不自动重启。未识别时使用
    `accounts/_unassigned/`，首次登录后复制认领、保留原目录。
  - **旧版迁移**：旧单库以 `settings.onebot.self_id` 为 owner 归入对应账号；用 SQLite Backup API
    复制旧库为一致快照（含 WAL 已提交内容，不裸 copy WAL/SHM），并从 `config.json` 的
    `bot`/`personas`/`schedules` 写入 profile 种子，写 `legacy-migration.json` 与
    `account-state.json`；旧库、旧 `config.json`、旧媒体目录全部保留。迁移幂等，重复启动不会
    覆盖已有账号数据。升级后需切回原微信账号才能看到旧聊天。
  - **UI**：设置 → 数据与备份新增「当前微信账号 / 已保存的账号 / 重新检测微信账号」，
    展示账号 mask、账号数据目录、账号配置、记忆数据库、媒体目录与全局配置/备份/日志目录；
    总览在账号切换后显示可关闭的提示。不提供手动选择数据库/账号档案。
  - **边界**：删除聊天只影响当前账号；其它账号数据在重新登录该账号前不可见但保留；
    旧媒体绝对路径继续有效，不迁移、不删除；Keychain/语音模型/日志全局共享；
    首次升级需要与旧库同量级的额外磁盘空间。
  - **文档与测试**：新增 [`docs/accounts.md`](docs/accounts.md)（行为/隔离矩阵/布局/识别/切号/
    迁移/边界/排障），同步更新 `docs/README.md`、`docs/architecture.md`、`docs/core-services.md`、
    `docs/memory.md`、`docs/ui-design.md`、`docs/install.md`、根 `README.md` 与本文；
    新增 resolver、`AccountLayout`、旧版迁移/认领、config+profile 双文件与 `MemoryStore`
    切库隔离测试；`swift test` 470 项通过（8 项按环境跳过）。
  - **修复旧库迁移空复制（2026-10-28）**：旧库是 WAL 模式且旧 App 退出后 `-wal/-shm`
    已被删除时，READONLY 连接在 prepare 阶段会 `SQLITE_CANTOPEN`，导致迁移未复制数据却继续
    打开空库（表现为“聊天记录/记忆没了”）。owner 读取、Backup API、空壳库检查改用 READWRITE
    连接；新增“WAL 主库无 sidecar”回归测试，旧库/旧配置/旧媒体仍全部保留。
  - **审查修复（2026-10-28）**：`_unassigned` 有数据时启动不再被 `preparePaths` 直接改写
    active，改为在开库前认领（保留源目录）；`MemoryStore.suspend()` 禁止切号期间隐式重开，
    `LogPipeline` 延后到迁移/认领完成后 attach；后台记忆总结/群昵称回填/统计落盘在切号前
    cancel + await，回复流水线加账号代次保护；`account-state.json` 增加
    `legacyMigrationDone` 门禁，`activate`/切号不再替迁移“盖章”；迁移/认领可替换提前开库
    留下的空壳库、绝不覆盖已有业务数据；bridge `image_path` 强制取当前账号目录；
    切号失败复位 `isBotRunning` 并禁止启动机器人并发。

## [1.5.2] — 2026-10-27

### 变更

- **移除设置页「语音」分类（2026-10-27）**：设置页不再提供「语音」分类，消除与「机器人 → 语音」的
  重复入口；语音转写、语音回复、引擎与音色等全局设置统一在「机器人 → 语音」，「机器人」页继续复用
  共用组件 `VoiceSettingsPanel`，面板行为与语音功能本身未改动。设置分类现为
  通用 / 外观 / 通知 / Hook / OneBot / 数据与备份 / 关于。

## [1.5.1] — 2026-10-27

### 变更

- **菜单栏交互、图标与首开性能重构（2026-10-27）**：菜单栏继续使用自绘 `NSStatusItem`
  （不使用 SwiftUI `MenuBarExtra`），本轮重新定义点击语义并移除旧的启发式逻辑。
  - **交互**：左键单击（按下即响应）开合 272pt 的 `NSPopover` 状态面板，打开主窗口、
    启停机器人、会话/机器人/设置与退出全部收进左键面板；**右键 / Control-左键不再执行
    操作，原生 `NSMenu` 右键菜单已移除**。左右键都由常驻 local 鼠标监视器在分发前拦截并
    吞掉事件：左键直接开合面板，右键/Control-左键吞掉后什么都不做。
    面板使用 `.transient`：点面板外（其它 App / 桌面 / 其它状态栏图标）由系统自动收起，
    不依赖需要辅助功能权限的全局事件监视器；本 App 其它窗口由 local 点击监视器立即收起；
    Esc、应用失活、应用隐藏与系统菜单开始跟踪也会收起。**删除 `clickCount`、双击时间窗、
    同次点击抑制等启发式**（`MenuBarPanelToggleDecision` 及其单测一并移除），点击意图改由
    纯映射 `MenuBarClickIntent` 决定（左键 → 开合；右键/Control-左键 → 忽略；其它修饰键
    保持左键语义；未知事件兜底为左键）。
    主窗口的其它打开路径（Dock 重开、⌘1…⌘0、面板入口）也会先收起面板。
  - **图标与提示**：模板 SF Symbol 随机器人运行状态切换填充/轮廓
    （`bubble.left.and.bubble.right.fill` ↔ `bubble.left.and.bubble.right`），不叠加颜色、
    不跑状态动画；状态栏图标不显示鼠标悬停 tooltip，仅保留无障碍值与 VoiceOver 帮助，
    在启停或界面语言切换时刷新。
  - **首开与渲染性能**：状态栏图标出现后延迟预构建并缓存 `NSPopover` +
    `NSHostingController`，预热阶段用 `sizeThatFits(in:)` 预先量出面板高度；
    固定 contentSize（`sizingOptions = []`；离屏 `fittingSize` 恒为 0，不用它），
    余额/统计/电量等数据刷新不再触发 popover 自动重排；
    语言切换或关闭菜单栏图标时丢弃缓存。内容层不再叠加 `regularMaterial`（popover 自带材质），
    移除品牌图标阴影；悬停只对 `opacity` 做 ≤0.15s 过渡，「减少动态效果」时不做动画。
  - **视觉与操作层级**：面板宽度 272pt，头部彩色运行状态胶囊、带描边玻璃卡片的状态区、
    带分隔线的三列统计条；操作区重排为「启动/停止 → 打开主窗口 → 会话/机器人/设置」，
    底部保留版本与退出。面板内导航/打开主窗口后自动收起。
  - 新增 `MenuBarClickTests` 覆盖点击意图分流与图标状态映射；2026-10-27 已在 macOS 26.7.1
    本机安装版走查左键开合、右键确认不再弹菜单、Esc、点其它窗口/其它 App 收起与面板内导航；
    首开耗时未用 Instruments 量化，相关性能描述仅为实现方式，不包含实测数字。
- **语音回复免拟人化延迟（2026-10-27）**：当本条回复已确定改发语音时，默认跳过
  「节奏 → 拟人化」的随机延迟，直接进入 TTS 合成与发送，避免「合成耗时 + 延迟」让用户
  等两次；文字回复节奏不变。新增语音设置「语音回复免拟人化延迟」
  （`VoiceSettings.skipHumanizeDelayForVoiceReply`，默认开启，可关闭回到原节奏）；
  发送日志改为记录实际等待的拟人化延迟，语音回复的进度条不再显示等待倒计时。
  新增发送节奏单测与旧配置缺键默认值断言。

## [1.5.0] — 2026-10-27

### 新增

- **CosyVoice3 可选高保真引擎（2026-10-27）**：新增 `.cosyVoice` 引擎与本地 Python sidecar
  （`devtools/cosyvoice/`，`Fun-CosyVoice3-0.5B-2512`，Apache-2.0，24 kHz）；设置页可安装/下载
  （运行环境约 2–3 GB + 模型约 5–7 GB，可取消/重试/删除）、启动/停止、查看日志与试听；
  本机音色由用户自行导入；Kokoro 仍为
  默认，CosyVoice 未安装/服务未启动/合成失败时自动回退 Kokoro，再失败才改发文字。新增
  `CosyVoiceTests`、`docs/cosyvoice.md`；打包时把安装/启动脚本复制到 `Contents/Resources/cosyvoice/`。
  实测 CPU 热态 RTF≈1.5（4 步）/1.83（6 步），启动到 ready≈22s、RSS≈8.65GB，**不承诺实时**；
  默认 Kokoro，CosyVoice 仅作高质量/离线可选。Swift 396 项测试通过（8 跳过）。
- **Kokoro 语速 1.0/1.25/1.5 三档快捷（2026-10-27）**：默认 1.25×，仍可用滑杆 0.5×–2.0× 微调；
  整段合成下 1.5× 会偏快，1.25× 是自然度优先的默认值。
- **会话页删除聊天（2026-10-27）**：会话详情「会话设置 → 会话 → 删除聊天…」可删除本机保存的聊天
  （会话列表不提供右键删除）；二次确认明确「删除会话、聊天记录与相关记忆，不影响微信端聊天记录」，
  删除后自动回到空状态；若之后收到新消息，会话会重新出现。

### 变更

- **移除会话级语音设置（2026-10-27）**：会话详情「会话设置 → 语音」整体移除，语音转写与语音回复
  只保留「机器人 → 语音」全局开关。运行时不再读取旧库里的会话级覆盖字段，`Conversation` 的
  `voiceTranscriptionEnabled` / `voiceReplyEnabled` / `voiceReplyProbability`、数据库映射与相关单测同步删除。
- **语音回复首次开启/启动时检测发送句柄（2026-10-27）**：开启「允许语音回复」后立即向 bridge 检测
  文本/语音句柄并弹出捕获引导（不再要求 bridge 已配置/已运行）；bridge 启动后若已开启语音回复但
  句柄缺失，也会自动提示一次（同一 App 会话最多一次）。引导弹窗新增当前状态与原因说明
  （bridge 未连接、R3 原生发送未开启、微信版本不支持、登录预热中），避免步骤一直「待完成」却不知道原因。

### 新增（音色管理）

- **CosyVoice3 音色管理与个人使用声明（2026-10-27）**：所有用户新增音色标记
  `personal_use_only=true`（内部元数据），UI 不再显示个人使用徽标/提醒，新增/编辑无需勾选；新增「管理音色…」sheet：可导入 5–30s 的 wav/m4a/aiff 参考音、自动转写或手填参考文本、
  命名/简介、试听、编辑、删除（内置不可删）；音频统一转 24k mono 16-bit 并峰值归一；写入
  `voices.json` + `<id>/prompt.wav|txt|meta.json`，服务运行中调用 `POST /voices/reload` 即时生效，
  未运行则下次启动生效。服务端 `GET /voices` 返回 `personal_use_only`/`builtin`。
  **App 包不内置任何音色/参考音频/`voices.json`**；普通用户安装后音色列表为空，需自行添加。
  自定义音色支持导出 `.zip` 备份（内置不可导出，导出物为音色文件 + 中性备份说明，不提供网络上传/分享）。

- **语音合成管线（2026-10-27）**：Kokoro 传入 `date-zh/phone-zh/number-zh` 三个 `rule_fsts`
  （`phone` 在 `number` 前，避免手机号被读成基数）；关闭 Kokoro/ZipVoice 内部按标点切分
  （`min/max_words_in_sentence` 整段合成）；`silence_scale` 0.2 → 0.8；App 直接输出引擎原生
  24 kHz WAV（不再强制 16k），bridge 按 WAV 头识别 16k/24k（16k 才重采样）；合成后加 5 ms
  淡入淡出；ZipVoice 的旧 `min_char_in_sentence` 改为 v2.0.0 有效的 `min/max_words_in_sentence`。
- **朗读稿清洗（2026-10-27）**：去掉开头的 `@昵称`，`——/—` 转逗号，`85%` 转「百分之85」，
  `¥120` / `$20` 转「120元」/「20美元」；数字仍交给 FST。
- **微信 4.2.0.9 (270345) 适配（2026-10-27）**：新增 `hook/versions/4_2_0_9_mac.json`；App 的
  R3 发送版本门禁（`NativeSendVersionSupport`）与 `tools/install_gadget.sh` / `tools/manage_wechat.sh`
  的默认目标、已知版本对同步更新为 4.2.0.9 (270345)，历史 4.2.0.5 / 4.1.15.55 / 4.1.12.53 继续可安装；
  arm64 偏移按 4.2.0.5 → 4.2.0.9 的差异重新定位（函数为字节级同构，虚表/全局按 chained fixups
  与代码交叉引用定位）。`README` 与 `docs/install.md` / `docs/architecture.md` / `docs/bridge.md` /
  `docs/voice.md` / `docs/ui-design.md` 同步更新。2026-10-27 在 4.2.0.9 (270345) 完成真机验证：Gadget 注入 + ad-hoc 重签（保留 sandbox entitlements）、WeChat 正常启动且 gadget 27042 监听；hook 基址解析与 classA/service vptr 校验通过；通讯录解密读取（29 联系人 / 1 群 / 10 群成员，DB key 回灌）；入站自消息事件正确；手动发一条文本捕获并持久化 R3 发送句柄后，R3 文本发送到文件传输助手 slot13 返回 0、worker result=1。语音发送沿用同一链路但本轮未复测（需手动发一条语音捕获 voice seed/header）；群聊 @ / 拍一拍与媒体下载未复测。

### 修复

- **语音吞数字（2026-10-27）**：不传 `rule_fsts` 时 `3`/`2026`/`13800138000`/`85%` 被 sherpa
  当 OOV 静默跳过（不是读错，是没读）；现在数字/日期/电话按中文读法输出，手机号按位读。
- **语音按逗号断句（2026-10-27）**：49 字回复原先被切成 4 段独立合成再硬拼接；现在整段一次
  合成，句内语气连续、停顿自然（实测 4 碎片 7.17s ≈ 拼接 7.18s；整段后 6–8s 且停顿 200–500ms）。
- **24k 语音被降 16k 再插值回 24k（2026-10-27）**：改为 24k 直通；`/send_voice` 兼容旧 16k
  WAV/裸 PCM，新增 24k WAV 单测。

### 文档

- 新增 [`docs/cosyvoice.md`](docs/cosyvoice.md)；更新 `docs/voice.md`（FST/整段/24k/性能/质量修复）、
  `docs/ui-design.md`（CosyVoice 设置区/语速三档）、`docs/core-services.md`（CosyVoice 文件）。

- **语音音色选择与试听（2026-10-27）**：Kokoro 内置 103 个音色按官方 sid → name 固化
  （中文女声 55 / 中文男声 45 / 英文女声 3），机器人 → 语音新增音色选择 sheet（搜索、分组、
  逐行试听）；主面板也可直接试听当前音色。试听与真实回复共用 `VoiceSynthesisService`，
  合成后在本地用 `AVAudioPlayer` 播放，不发往微信；全局只保留一个播放器，切换音色/语速自动停止。
  新增 8 项 `VoiceCatalogTests`；Swift 335 项测试通过（2 项模型依赖测试跳过）。

### 变更

- **机器人语音设置精简（2026-10-27）**：把「语音引擎（TTS）」与「语音模型与克隆音色」合并为
  「语音引擎与音色」；Kokoro 音色不再用 0–200 裸编号 Stepper，克隆音色不再手填档案 ID；
  模型只展示当前引擎需要的文件（Kokoro 365MB；ZipVoice 主模型 + 声码器 163MB），
  行内下载/取消/重试，删除收进菜单，去掉「下载全部」、三个模型行与「允许下载语音模型」开关
  （首次下载改为体积确认框）；「语音回复」未开启时收起策略项，「语音发送状态」仅在开启后显示，
  去掉重复的两行句柄明细；发送状态轮询从每秒请求 bridge 改为每 5 秒一次（倒计时仍按本地 tick 更新）；
  删除 `SettingsView` 中已废弃的整份语音设置副本（约 600 行）。

### 修复

- **已下载语音模型被半截目录误判为就绪（2026-10-27）**：`VoiceModelStore.isModelReady` 原先只看
  解包目录是否存在，tar 中途失败会留下半截目录，导致下载按钮跳过、合成时才报模型不完整；
  现在按实际文件校验（Kokoro 的 model/voices/tokens、ZipVoice 的 tokens/encoder/decoder）。
- **手改配置的超界音色编号（2026-10-27）**：`kokoroSpeakerID` 在解码/保存与合成前统一收敛到
  0–102，避免 UI 显示越界编号或引擎侧静默落到别的音色。

## [1.4.0] — 2026-10-26

### 新增

- **总览「设备与账户」：本机电量 + DeepSeek 余额（2026-10-26）**：总览状态卡下方新增一张双栏卡片，
  左侧显示 Mac 电池电量、充电/已接电源状态与剩余或充满时间（IOKit，30 秒刷新；台式机显示
  「未检测到电池」），右侧显示 DeepSeek 账户余额：总额、赠送/充值金额、可用状态与更新时间。
  余额请求固定为 `GET https://api.deepseek.com/user/balance`（自动丢弃聊天 baseURL 的 `/v1`），
  Key 从 Keychain 中默认/已配置的 DeepSeek 通道读取并在后台线程访问；启动查一次、每 5 分钟
  自动刷新，AI 模型页保存通道后立即重查，卡片右上角可手动刷新。缺通道/缺 Key 时显示
  「前往 AI 模型配置」入口，网络或解析失败显示原因与「重试」，不伪造金额。
  菜单栏弹层同步增加「电量」「余额」两行状态；中/英双语文案随语言切换。
  新增 16 项 `SystemVitalsTests`（电池字典解析/百分比边界、余额地址推导与容错解析、通道选择），
  Swift 测试 325 项通过（2 项模型依赖测试跳过）。
- **会话级语音开关（2026-10-26）**：会话详情「会话设置 → 语音」新增「接收转译语音」与「语音回复」
  两个会话级开关（跟随全局 / 开启 / 关闭），选择后立即写库。运行时按「会话覆盖 → 全局」取生效值：
  关闭转写的会话不再发起新的语音下载与转写，关闭语音回复的会话只发文字；概率、对等、仅短回复、
  TTS 引擎/音色仍由全局语音设置控制。

### 变更

- **AI 模型页与通道编辑重做（2026-10-26）**：通道编辑 sheet 改为「基本信息 / API Key / 高级参数」
  三层结构；切换类型时自动填入默认地址与模型（不覆盖用户手改值），按类型区分 Key 必填/可选，
  已有密钥明确提示「留空保持不变」。回复最大长度、请求超时与通道级流式收进默认折叠的
  「高级参数」并在折叠时保留摘要；名称/URL/模型改为字段级校验，错误提示固定在 footer 上方。
  通道行直接展开测试耗时或失败原因，Key 状态区分「缺少 API Key / 无需密钥 / 密钥可选」，
  并显示有效的流式状态（全局关闭时「流式已暂停」）、输出上限与超时；移除行内重复的
  「编辑/测试」菜单项，删除改为带确认的垃圾桶按钮。页面把含糊的「全局请求」拆成「默认通道」
  与「请求策略」：默认通道 Picker 不再提供会静默回退到第一个通道的「无」选项，默认通道停用或
  缺少 Key 时显示 warning；**移除从未生效的全局请求超时设置**（`AISettings.requestTimeoutSeconds`，
  真实超时一直按通道配置）；删除通道时同步删除该通道在 Keychain 中的密钥。
  新增 2 项模型/配置兼容测试；Swift 测试 327 项通过（2 项模型依赖测试跳过）。

### 修复

- **文字回复带上 `[语音 8s]` 前缀（2026-10-26）**：上一轮 TTS 语音回复在短期历史里被渲染成
  assistant 内容 `[语音 10s] <正文>`，模型把系统标注当成自己的回复格式照抄，下一轮文字回复
  便以 `[语音 8s]` 开头发到了微信（真机复现 21:45）。现在时长标注只用于入站语音，出站语音
  在提示词/长期记忆里只保留正文；system 提示禁止输出该类标注；回复进入发送计划前再统一清洗
  `[语音 Ns]` / `[语音]` / `[语音，转写失败]`，清洗后为空按空回复处理（不重试发送标注）。
- **已下载语音模型却始终不发语音（2026-10-26）**：`sendOutgoingVoice` 误把「允许下载语音模型」
  当成使用门槛。模型已就绪、语音回复已开启时，决策命中后仍被「尚未同意下载语音模型」拦下并
  逐条降级文字。现在只在模型未就绪时降级；下载同意仍只在下载入口校验，已下载模型直接使用。

## [1.3.0] — 2026-10-26

### 新增

- **首启向导环境检查：CLT 检测与安装引导 + Hook 预检（2026-10-26）**：首启向导与「设置 → Hook」
  新增环境检查卡，显示 Xcode Command Line Tools 状态（已安装 / 未安装 / 检测中 / 检测失败），
  提供「安装 Command Line Tools」（执行 `xcode-select --install`）与「重新检测」；安装完成后自动轮询刷新。
  CLT 未就绪时禁用「备份并安装 Hook」并说明原因；Hook 预检（CLT / 微信版本 / 运行状态）
  在进入备份与注入前返回可行动错误，避免安装到一半才失败。CLT 仅用于 `/usr/bin/python3` 与
  `/usr/bin/otool`，不需要 Apple 开发者账号。
- **语音能力：本地转写 + 本地 TTS/克隆（2026-10-26）**：新增入站语音事件归一化
  （`[语音]` → `{"type":"voice","data":{"duration_ms":N}}`）、`POST /fetch_voice`（AES 解密 +
  SILK 校验 + 16k WAV）、Apple `SpeechAnalyzer` 本地转写（气泡/上下文/记忆/引用语音，可关闭）、
  `POST /send_voice`（官方 SILK SDK 静态编码，无 ffmpeg/pilk 运行时依赖）、sherpa-onnx 静态链接 + Kokoro/ZipVoice
  本地 TTS 与克隆音色、语音时长/概率/对等/每会话设置及失败自动降级文字。模型按需下载
  （Kokoro≈365MB、ZipVoice≈109MB、vocoder≈54MB），音频/转写/参考音频均只存本机。
  **真机验证（2026-10-26，4.2.0.5）**：入站语音下载使用 `triggerDownload(fileType=15)`，3 条真实
  语音全部成功解密/解码；出站走官方 SILK SDK（`silk-v3-decoder`，`-tencent`，24kHz）编码 + CDN 上传 +
  R3 `uploadvoice` 任务（opcode 0x7F），TTS 5.1s 语音在测试账号正常播放、内容正确、可停止。
  go-silk 输出能被自身解码但微信无声，是本次定位的关键。
  **使用限制**：首次启用或微信重启后需手动发一条文字 + 一条语音捕获句柄；bridge 启动 60 秒内
  CdnManager 未就绪时会降级文字。Swift 304 项测试通过；Go 测试通过（新增 `/voice_status` 与官方
  SILK 编码依赖）。
- **语音转写修复 + 语音设置移入机器人页（2026-10-26）**：系统语音资源状态为
  `supported` 时 App 原先误判为不可用；现在 `.supported` 也会实际尝试转写，并在
  语音设置中提供「下载中文语音资源」按钮（直接调用 `AssetInventory`，无需手动去
  系统设置）。完整语音设置面板同时加入「机器人」页，设置页的「语音」分类复用同一面板；
  会话详情里冗余的「语音转写/语音回复/回复概率」覆盖已移除，统一使用机器人页的全局设置。
- **引用图片时让 AI 知道是哪张图（2026-10-23）**：微信引用消息只带 `<svrid>` 与 `[图片]` 摘要，
  回复模型看不到被引用图片。现在解析 refermsg 的 `svrid`（与 `ChatMessage.id` 的
  `ob-<svrid>` 精确对应），生成回复前按 ID 找回原图：已有识图描述直接复用；尚未描述但
  本地有图片时借用识图通道现场识别（引用场景不受「最近 10 分钟」限制）；随后在本轮用户
  消息末尾附「（引用图片内容：…）」，找不到/无法识别时附「（引用的图片内容暂不可用）」。
  system prompt 会说明该标记是图片描述而不是新发言，避免模型猜图。旧配置（未开启识图）
  且原图无描述时行为不变。
- **图片识图 / 视觉模型（2026-10-23）**：AI 模型页新增「识图模型」：可启用识图、指定识图通道
  （默认跟随默认通道）与模型覆盖。自动回复触发时按需识别上下文内最近 10 分钟、每次最多 2 张
  尚未识别的入站图片：先用 ImageIO 缩放/JPEG 编码为 data URL，再以 OpenAI 兼容的
  `image_url` 多模态请求调用识图通道；描述清洗后写入消息与数据库
  （`messages.image_description`），后续提示词以 `[图片：描述]` 参与文本上下文与长期记忆摘要。
  图片本身不进入回复提示词；识图请求非流式、超时 ≤30 秒、输出 ≤800 tokens；同一消息每次
  运行最多尝试一次，失败只写 debug 日志、不阻断回复；未开启或识别失败时行为与旧版一致。
  图片气泡在图片下方展示识图描述。该链路 2026-10-23 实现并通过单元测试，**尚未真机验证**
  （需配置支持 `image_url` 的视觉模型）。
- **聊天图片获取（2026-10-23，4.2.0.5 真机验证）**：微信 4.1.15.55 / 4.2.0.5 的入站图片
  此前只有 `[图片]` 占位。现在 bridge 在推送前从 `raw_message` 解析 `<img>` 的
  `aeskey` / `cdnmidimgurl` / `cdnthumbaeskey` / `cdnthumburl` / `md5` / `length`，
  按 `message_id` 登记下载候选（mid → thumb），并把文本占位替换成无 data 的
  `{"type":"image","data":{}}`（新增结构化字段与日志不携带 aeskey / CDN key；
  `raw_message` 仍保留 hook 原始图片 XML，与历史行为一致）。App 在该会话开关开启时
  调用新增的 `POST /fetch_image`（Bearer）按需触发微信自身 CDN 下载；bridge 收到分片后
  用 `aeskey` AES-ECB 解密、校验图片魔数，写入 `-media_dir/<yyyy-MM-dd>/`
  （默认 `~/Library/Application Support/WeChatAI/media`），返回 `file://` 路径，App 更新
  `mediaPath` 并落库，会话气泡即显示图片。真机实测：新图片 → 自动触发下载 → 分片解密得到有效 JPEG。App 侧新增 `ImageFetcher` 串行队列（同一消息只尝试一次、失败不重试、
  停止即取消），失败只写 debug 日志。本次只做**获取**，识图（视觉模型）见上一条；
  只处理实时入站图片，历史消息不回填。
- **通讯录真实昵称 / 群名**：hook 在本机**只读**读取通讯录后返回联系人目录，
  bridge 暴露 OneBot `get_contact_directory`，App 用真实昵称/群名替换 wxid 标题，
  并在群成员缓存未命中时回退通讯录昵称（契约见 `docs/architecture.md` §3）。
- **中 / 英双语界面**：首次向导右上角与「设置 → 通用 → 界面语言」可切换
  跟随系统 / 简体中文 / English；内建 `en.lproj/Localizable.strings`，静态 `Text`
  与 `L()` 组件/枚举标签均覆盖，切换即时生效。
- **稳定性与崩溃取证**：`CrashReporter`（未捕获异常报告、会话面包屑、主线程看门狗）、
  `AppKitLayoutGuard`（显示周期断言安全阀）。
- **回复进度倒计时**：`ReplyProgressBar`，会话详情头部、输入区与会话行同步显示
  AI 生成 / 拟人化等待 / 发送中 / 完成 / 失败状态。
- **会话重命名**：会话详情菜单「重命名会话…」（`ConversationRenameSheet`），
  可给微信只下发 wxid 的会话起名，留空恢复自动名称。
- **会话工作时段状态**：会话详情头部新增 `WorkingHoursBadge`，实时显示
  「工作时段 / 非工作时段 / 不限时段」，按会话覆盖优先判定并每分钟刷新；
  悬停可查看时段来源与摘要，非工作时段与 `RuleEngine` 的拦截口径一致。
- **核心记忆权重可调**：记忆编辑器新增基础权重滑块（0.1~10.0×，步长 0.1，
  含 0.5×/1×/2×/3×/5× 预设与重置）和保存后综合权重估算；核心记忆之间也按综合权重排序，
  超出注入名额时高权重核心优先；卡片在权重被调整后显示「基础 ×N.N」徽标
  （`docs/memory.md` §5–§6）。
- **拍一拍回复**：只响应「别人拍的是机器人」的事件；机器人页可开启拍一拍回复
  （默认关闭），配置 AI 前/后自定义文字（支持 `{name}`）和/或 AI 回复。
  群聊新增「被拍后 @ 拍的人」（`bot.pat.mentionPatterInGroup`，默认关闭）：
  回复的第一条消息（自定义前文字 → AI 首段 → 自定义后文字中先发出者）携带 OneBot
  `at` 段，由 bridge 解析群昵称并写入 `<atuserlist>` 生成真实 @；私聊不 @，
  昵称解析失败时退化为普通文本。新增 `PatMessage.replyMention` 与单测。
- **拍一拍目标识别**：hook 解析 appmsg/patinfo 或 sysmsg 的 `pattedusername`，
  上报 `pat_from_wxid` / `pat_chat_wxid` / `pat_target_wxid`，拍别人不会唤醒机器人。
- **日志批量管道** `LogPipeline`：200ms 批量刷新、ANSI 清理、UI 与 SQLite 节流。
- **自消息方向字段**：hook 上报 `from_wxid` / `to_wxid` / `sender_wxid`，bridge 输出
  `is_self` / `target_id`；App 用权威 selfID 归位会话，并新增
  `MemoryStore.repairSelfRoutedMessages` 一次性修复历史误路由。
- **bridge**：`incoming.go` 入站事件归一化、`r3seed.go` 发送句柄按微信 PID 持久化；
  新增 `incoming_msg_test.go`、`incoming_normalize_test.go`、`MessageRoutingTests`。
- **文档**：新增 `docs/install.md`（安装与启动）、架构/契约文档与本变更日志；
  新增 `scripts/check.sh`、`scripts/check_docs.py`、
  `scripts/sync_hook_script.sh`、根 `Makefile`。

### 性能

- **历史信息获取与空闲等待（2026-10-23）**：围绕「打开/回放历史消息」和「空闲等待入站消息」
  两条链路做性能、效率与能耗优化，协议与 UI 行为不变：
  - **hook**：R3 闭包捕获从常驻 `setInterval(10ms)`（100Hz 唤醒 + 每 tick 最多 96 节点堆遍历）
    改为按需 one-shot 调度：未解析 classA 时 500ms 重试；已解析但未拿到发送句柄时按
    10ms→50ms→250ms 退避扫描，发送入口缺句柄触发 5s 快扫；拿到句柄后停止一切周期任务。
    日志 / seed 持久化不再等待轮询，改为 0ms 合并 flush。微信空闲时不再持续读堆。
  - **hook 内存**：入站去重表 `incomingMessageSeen` 改为 4096 条环形窗口，长时间运行或
    历史回放（同一条消息被重复 finalize）不再单调增长；窗口外重复由 App `message_id`
    去重 + SQLite upsert 兜底。
  - **bridge**：入站事件推送删除固定 `send_interval` sleep（App 运行期传 100ms；旧路径
    每条事件延迟一次并多一次定时器唤醒），事件完成归一化/图片登记后立即写 WS/HTTP；
    `-send_interval` 只约束真正发往微信的消息。事件级完整 JSON 日志降为 Debug，只保留
    字节长度 + ≤256 字符预览；默认 `-log_level=info` 下零额外字符串分配。
  - **App 启动历史修复**：`get_login_info` 写入的 selfID 标记 `onebot.self_id_source=login`，
    两处历史修复传 `trusted: true` 完全跳过「全表读取 `raw_json` 并逐行 JSON 解析」的账号反推；
    未 trusted 时反推只采样最近 5000 条，`repairMisroutedConversations` 先用 `conversations`
    表廉价筛选嫌疑会话。`repairAppmsgMessageTexts` / `rerenderLegacyQuoteTexts` 两个全表
    LIKE 迁移改由 `data.repairs_version` 门禁，只成功执行一次，失败下次重试。
  - **App 空闲刷新**：`AppStore.logRevision` 记录日志缓冲代数，日志页（500ms）与总览
    「最近活动」（750ms）采样未变化时直接跳过，空闲时不再每 tick 复制/遍历 2000 条日志。
  - **App 入站解析**：每帧只 `JSONSerialization` 一次；`OneBotEventParser.parse(object:rawText:)`
    复用已解析对象与原帧文本，单事件 `rawJSON` 不再重新序列化（数组/包装帧兼容）。
  - **测试**：Swift 200 → 207（新增 `OneBotEventParserTests` 5 项、`DataRepairTrustTests` 2 项），
    Go 仍为 95 项；`scripts/check.sh` 与 `scripts/build_bridge.sh` 全绿。

### 变更

- **第三方许可合规与仓库清洁（2026-10-26）**：新增 `LICENSES/`（Apache-2.0、MIT、BSD-3-Clause、
  ISC、Frida wxWindows Library Licence 3.1、Skype SILK SDK），并在打包时随 App 分发；修正
  `ThirdPartyNotices.txt` 中 SILK SDK（Skype 许可，而非 MIT）、Frida（wxWindows 3.1，而非 LGPL）、
  go-silk（BSD-3-Clause）、Vocos（MIT）等表述；`bridge/testdata` 补充合成样本出处与 SHA256；
  `.gitignore` 补齐音频/模型规则，`.gitattributes` 标记 vendored 源码与二进制；移除公开文件中
  的本机研究目录引用。
- **安装文档修正（2026-10-26）**：重写 `README.md` 与 `docs/install.md` 的环境要求与安装步骤，
  补充 Xcode Command Line Tools 前置与 `xcode-select --install`、macOS 15+（含 26）已取消
  「右键 → 打开」后的正确 Gatekeeper 流程（系统设置 → 隐私与安全性 → 仍要打开，或
  `xattr -dr com.apple.quarantine`，区分 `~/Applications` 与 `/Applications` 两种路径）、
  默认显示 Dock 图标、App 数据/App 管理授权、微信版本与属主/写权限、备份约 665MB 与磁盘 ≥2.5GB、
  R3 首次手发消息、还原入口与语音模型约 528MB；`docs/README.md` 索引描述同步。
- **机器人页拆分子栏目（2026-10-26）**：机器人页由单页长列表改为 6 个子栏目
  （常规 / 触发 / 互动 / 名单 / 节奏 / 语音），工具栏下方新增 sticky 分栏条（`PageTabBar`），
  切换子栏目时内容回到顶部，子栏目选择按窗口记忆（`@SceneStorage`）。
  「保存设置」与启动/停止仍在页面顶部；所有设置项、默认值与存储结构不变。
- **「获取图片」改为按会话设置（2026-10-23）**：删除设置页的全局开关，改为
  `Conversation.imageFetchEnabled`（会话详情 → 菜单 →「媒体」）；数据库 `conversations`
  新增 `image_fetch_enabled INTEGER`（NULL=跟随旧全局默认、0=关、1=开，启动时幂等补列）。
  旧的 `bot.imageFetchEnabled` 仅作为未设置会话的回退值（默认开启）。
- **bridge 新增 `-media_dir` 与 `/fetch_image`**：入站图片获取落盘目录由 App 传入
  （默认 `~/Library/Application Support/WeChatAI/media`，只写该目录，不写 app bundle）；
  `/fetch_image` 要求与其他 HTTP 接口相同的 Bearer 鉴权，单次预算约 12 秒、并发上限 2，
  触发 Frida 下载带 10 秒超时，失败返回中文原因。`msg.go` 增加下载代次记录，用于匹配
  触发后新出现的下载分片。
- **仓库精简**：下线仅供开发期使用的文档与工具（AI 代理指南、开发手册、Hook 移植/ABI/R3/通讯录方法文档、
  集成状态与验收报告、性能事故记录、Frida 反查探针、指针归属工具、Issue/PR 模板与协作文件），
  相关内容保留在本机 `_local/`（已 gitignore）；公开仓库只保留用户视角文档与运行所需代码。
- **移除原生「拍一拍」回拍**：App 删除 `sendPat` 与「仅回拍 / 回拍位置」设置及相关测试，
  不再发送 `pat` 消息段。bridge/hook 中保留的 sendpat 历史代码保持默认关闭
  （`r3PatSend=false`、App 不调用），仅作逆向记录。拍一拍设置收敛为「拍一拍回复」；
  旧配置的 `beforeText` / `afterText` 自动沿用为自定义文字，`patOnly` / `aiPosition` 忽略。
- **记忆**：窗口外批量总结阈值从 20 条调整为 8 条，总结上限 600 字并自动压缩；
  核心记忆按所属会话/全局作用域生效，手写编辑不被自动总结覆盖（`docs/memory.md`）。
- **bridge 日志外置**：写到 `~/Library/Logs/WeChatAI/bridge/macos.log`，不再写入 app bundle
  （避免 ad-hoc 签名失效导致下次启动被杀）。
- **发送延迟**：bridge `-send_interval` 收紧到 100ms；R3 文本发送不再等待 buf2resp，
  避免「已送达却返回 send timeout」的误报。
- **脚本**：`fetch_gadget.sh` 对 Frida Gadget 17.8.0 校验压缩包与 dylib 的 SHA256；
  `clean.sh` 修正 `dist/` 保留语义并新增 `__pycache__` 清理；Go/Hook 构建产物一致性检查
  统一到 `scripts/check.sh`；`check.sh` 兼容 macOS 自带 bash 3.2（空数组在 `set -u` 下
  不再报 unbound variable）；`sync_hook_script.sh` 在 Linux 上回退 `sha256sum`，便于 CI 校验。
- **发布准备**：清理构建产物、运行日志与 `.DS_Store`；新增发布前检查清单（见
  [`README.md`](README.md)「清理、打包与分享」）；文档中的测试数字统一为
  **Swift 164 项 / Go 60 项**；`docs/README.md` 重新整理文档入口；
  `bridge/NOTICE` 更新为实际修改/新增文件清单。
- **发布打包**：新增 `scripts/package_release.sh`（构建 + 校验签名 + 生成
  `dist/WeChat-AI-<version>.zip` / `.sha256`）与 `make release`；
  `build_app.sh` 随包附带 `bridge/NOTICE` 与上游许可证，满足 GPL 合规。
- **发布 1.3.0（build 11，2026-10-26）**：发布包约 71MB；构建按
  `fetch_gadget → build_bridge → fetch_sherpa → build_app → package_release` 顺序执行，
  产出 `dist/WeChat-AI-1.3.0.zip` 与 `.sha256`（`shasum -a 256 -c` 校验）。
  README 下载链接、体积与测试数字同步为 v1.3.0；旧 `dist/WeChat-AI-1.2.5.zip` 不再作为发布包。
- **GitHub 仓库配置**：本地研究证据（截图 / 数据库备份 / 探针日志）移出仓库；新增
  `.github/release.yml` 与 Linux CI 仓库卫生检查（阻止构建产物、日志、DB、截图入库）。

### 修复

- **识图返回空内容 / 回复说看不到图片（2026-10-23）**：`deepseek-flash` 默认开启思考模式，
  识图请求的 400 token 输出额度被推理内容耗尽，最终 `content` 为空，App 报「AI 返回了空内容」，
  图片描述从未写入，回复模型只能看到 `[图片]` 占位。现在 DeepSeek 系识图通道显式发送
  `{"thinking":{"type":"disabled"}}`，输出上限 400→800 tokens、超时 20→30 秒；其它通道不发送
  该扩展字段。空内容失败改为 warning 日志，提示检查识图模型是否支持图片输入。
- **4.2.0.5 图片获取失败（2026-10-23）**：四个叠加问题已修复并在真机验证：
  ① `downloadImag`/`downloadFile` 的版本地址指向调用指令而非调用前的取参指令，Frida
  无法拦截；改为可挂载的 Hook 点。② 下载请求里变长字符串只换了指针、没换长度/容量，
  194 字符的 CDN file key 被旧长度截断；已按实际长度写入并标记长字符串。③ 登录稳定
  标记改为消息 finalizer 命中即置位，避开 bridge 启动 60 秒内触发下载被拒绝。
  ④ bridge 在触发前删除了已到达的自然下载分片，且触发被拒后直接放弃；现在优先使用
  微信自然下载的分片，触发失败也继续等待。⑤ 不再按 XML 的 `length`/`cdnthumblength`
  截断图片（该字段不总是真实明文长度，会切掉 JPEG 的 EOI 尾部导致半张图）；改为按
  JPEG EOI / PNG IEND 等结束标记裁掉 AES 补齐字节，不完整时继续等分片增长、不落盘。
  另：4.2 的 mid 图常为 HEVC（`hevc_mid_size`/`cdnmidheight=0`），没有 HEVC 解码时
  自动改用 JPEG 缩略图；入站图片事件经 `HandleMsg` 转发时空 image 段不再被 legacy
  XML 解析丢弃。真机结果：新图片自动落盘为完整 JPEG 并写入会话。
- **群聊身份被聊天玩梗覆盖（2026-10-22）**：补上消息 wxid 之后仍可能出现
  「群里多人说某人是某某，机器人跟着改口」。现在群聊每轮在 system prompt 末尾追加
  「本轮发言人身份」硬约束：由本会话核心/手写记忆解析 `wxid：称呼`，明确禁止模型
  附和群聊里的玩笑、临时外号、自称或“某人其实是某人”的说法；当前 wxid 不在映射表时
  提示不要套用他人称呼。自动总结也加了防污染：有本会话核心/手写映射时不再写
  「人物与称呼」段，传入模型的已有自动记忆先剔除人物段，模型输出与本地兜底
  再经 `removingPersonMappingLines` 兜底，避免把群聊玩梗固化成长期记忆。
- **英文小字补全**：相对时间、星期、时长、状态标签、计数、错误前缀与图表说明统一
  经 `L()` / `Lf()` 输出；新增 175 条服务层状态/错误文案，并为计数、日期、错误等
  动态拼接增加格式回退，英文界面不再混杂中文小字。
- **同一好友被拆成两个会话（2026-10-21 第二轮）**：私聊拍一拍的
  `<patinfo><chatusername>` 是 wxid，旧 hook 把它当群 ID 写入 `group_id`，于是好友的
  拍一拍被放进一个以自己 wxid 为 ID 的伪「群聊」；另外旧版 `self_id` 污染曾把机器人的
  群回复写进字面量 `wxid_self` 会话。修复：hook 只在 `from` / `to` 是 `@chatroom`
  时判群、私聊拍一拍 `pat_chat_wxid` 为空；bridge 清洗非法 `group_id` / `pat_chat_wxid`
  并给群自消息补群 ID；App 只把 `@chatroom` 当群，且新增
  `MemoryStore.repairMisroutedConversations` 在启动时把可确定目标的历史消息归位、
  删除空会话（幂等）。
- **私聊自消息误路由**：手机同步/历史回放的自消息不再进入「自己 wxid」会话，
  私聊/群聊均按 `target_id` 归位，历史数据启动时幂等修复。
- **会话名显示 wxid**：4.1.15 入站事件只带 wxid，而 App 曾把 `sender.nickname` 直接写成标题
  （群聊标题也会被写成「群聊 &lt;id&gt;」）。现在只在昵称可读时学习标题、自己消息不参与命名；
  展示层统一兜底为系统账号中文名或 `群聊 / 微信好友 / 公众号 · 尾号`，
  历史 ID 标题在启动时由 `MemoryStore.repairPlaceholderConversationTitles` 清理。
- **群聊 @ 漏触发**：兼容 `<atuserlist>` 的 CDATA/嵌套格式，bridge 显式保留
  `mentions` / `msg_type`，App 用机器人群昵称做纯文本 @ 兜底。
- **设置窗口闪退**：设置场景缺少 `ToastCenter` 环境对象导致 `EXC_BREAKPOINT`（已修复）。
- **拍一拍**：`from/to` 均为群 ID 的 appmsg 不再被误判为「自己发出」，并提取 `<title>` 文本。
- **拍一拍误唤醒（2026-10-21）**：不再把「群里 A 拍了拍 B」或普通聊天正文里的「拍了拍」
  当成唤醒；现在以 `<patinfo>` 的 `pattedusername` 为准，只有拍的是机器人本身才触发。
  私聊保留「拍了拍我」兜底，群聊需正文含 selfID 或已学到的群昵称。
- **拍一拍不触发（2026-10-21 真机）**：持久化的 `onebot.self_id` 被历史/Mock 事件污染后
  会通过 `-self_id` 覆盖 bridge 的真实账号，使 `get_login_info` 与 `pat_target_wxid`
  对不上。现在启动 bridge 前用 `image_path` 的 `xwechat_files/<账号>_xxx` 校验 selfID，
  不一致就不传、由 bridge 重新推导；入站事件只在 selfID 为空时兜底学习。
- **原生回拍真机失败（2026-10-21）**：原生拍一拍发送在真机未送达，继续合成还会导致
  微信崩溃；该能力已整体移除，详见「变更」中的「移除原生拍一拍回拍」。
- **设置兼容**：拍一拍设置放在可选 `bot.pat` 结构中，旧 `config.json` 缺键不会导致
  整份配置解码失败/重置。
- **R3 误报失败**：跳过 buf2resp 等待后不再返回 HTTP 500 send timeout；接收链路不受影响。
- **微信上滑历史卡顿**：`hook/script.js` 的 `isReadablePointer` 不再调用
  `Process.findRangeByAddress`（每轮都会枚举进程内存映射，微信里单次 20–50ms），改为
  试读 1 字节；Message finalizer 先去重再读字符串、私聊跳过群专用字段、逐条 `console.log`
  改为 `HOOK_DEBUG` 开关。历史回放从约 1 条/秒恢复到成批到达。
- **R3 重启后状态误报**：bridge/App 重启时发送句柄已从 `r3-seed.json` 恢复，但 App 只解析
  「捕获闭包」日志，Hook 卡片仍显示「R3 等待信号」并提示手动发消息；现解析恢复/过期日志、
  同步 `r3Seeded` 与提示文案（仅微信重启后需要手动发送）。

### 安全

- 运行期 Hook 配置与仓库版本 JSON 分离：仓库保持 `enableSend=false` / `req2bufSendMode=off`，
  R3 只由 App 设置开启。
- 通讯录读取密钥只在内存与本机受限缓存中出现，不写日志、不下发 App。
- 公开文档、变更日志与「关于」页收敛敏感实现细节：不再描述 Hook 地址、结构偏移、
  密钥派生或发送任务构造，只保留行为、开关与安全边界。
- 新增 `.gitignore` 与文档层面的隐私检查（真实 wxid / 聊天记录 / 截图 / Key 不入库）。

## [1.2.4] — 2026-10-23

### 新增

- **唤醒后免唤醒词**：机器人设置「回复策略」新增唤醒窗口（`bot.wakeWindow`，默认关闭，
  默认 5 分钟，可用滑块或 1/3/5/10/30/60 分钟快捷 chip 在 1–60 分钟间调整）。
  群聊被 @ / 关键词 / 拍一拍 / 引用机器人唤醒后，
  **同一发送者**在窗口内继续发言无需再次唤醒，命中消息会滑动续期；仅群聊生效，
  不绕过白黑名单、工作时段、冷却与每分钟上限；旧配置缺省保持关闭。

## [1.2.3] — 2026-10-23

### 变更

- **群聊发言人身份硬约束（2026-10-23）**：群聊 system prompt 在最后追加本轮发言人的
  权威身份说明，由核心/手写记忆中的 `wxid：称呼` 映射生成；明确群聊玩笑、临时外号、
  自称或「某人其实是某人」不能覆盖映射，不得附和。消息正文继续使用
  「昵称(wxid)：内容」，方便模型精确对齐。

### 修复

- **自动总结人物段污染**：本会话存在核心/手写 `wxid：称呼` 映射时，自动总结的
  「人物与称呼」段不注入提示词，也不写回长期记忆；模型输出与本地兜底摘要都会再经过
  人物段过滤。新总结提示要求不记录群聊玩笑/临时外号，冲突时以手写/核心记忆为准。
  这样群昵称被改、被开玩笑或重名时，模型不会把别人的称呼套到当前发言人身上。

## [1.2.2] — 2026-10-22

### 变更

- **引用消息定界符（2026-10-22）**：被引用内容从 `[引用 发送者] 原文` 调整为
  `【引用 发送者：原文】`（整体括起来，AI 更容易区分「本轮回复」与「被引用的历史消息」）。
  System prompt 增加格式说明；历史引用消息启动时由
  `MemoryStore.rerenderLegacyQuoteTexts()` 幂等重排（从 `raw_json` 重新生成、
  保留结构化 `at` 后缀、刷新会话预览）；`RuleEngine.triggerText` 同时兼容新旧定界符，
  触发判定语义不变。

### 修复

- **群聊认错人（2026-10-22）**：长期记忆以 wxid 记录「wxid：称呼」的人员关系，
  但群聊提示词只拼群昵称，模型无法把发言人与记忆对齐，会套用记忆里其他人的称呼
  （真机上把某位群友叫成了另一位群友的别名）。修复：群聊消息改为
  「昵称(wxid)：内容」（无昵称时「wxid：内容」），system prompt 要求以括号内 wxid
  对照长期记忆、找不到时不要套用他人称呼；历史回放中旧 bridge 已渲染的
  `正文\n[引用 发送者] 原文` 在事件入口统一重排为 `【引用 发送者：原文】`，
  避免被引用内容里的旧称呼被模型当成当前发言人说的话。

## [1.2.1] — 2026-10-22

### 新增

- **引用机器人唤醒（2026-10-22）**：机器人设置「群聊触发方式」新增「引用机器人」
  （`TriggerMode.quote`，默认关闭，需显式勾选）。别人引用机器人发过的消息时唤醒，
  正文无需 @ 或关键词；判定用 `refermsg` 的结构化发送者 wxid（`<chatusr>`，
  私聊形态/部分客户端回退 `<fromusr>`，群 ID 忽略），与 selfID 大小写不敏感比较，
  昵称不作为依据。被引用原文仍只作为 AI 上下文，不参与 @/关键词/前缀触发。
  新增 `WeChatAppmsg.Quote.senderID` 与 `RuleEngine.isQuotingBot`，
  单测覆盖引用机器人/引用他人、`<fromusr>` 回退、群 ID 与 selfID 缺失、
  触发方式编解码；真机验证：引用机器人的消息可命中，引用他人消息不会误触发。

## [1.2.0] — 2026-10-22

### 修复

- **引用消息被归为「链接/文件」（2026-10-22）**：微信引用回复是 appmsg
  （`msg_type=49` + `<appmsg><type>57</type></appmsg>`），但 hook 只识别拍一拍，
  其余 appmsg 一律写成 `[链接/文件]`——回复正文（`<title>`）与被引用原文
  （`<refermsg>`）对 App、规则引擎与 AI 全部不可见（历史数据中有一批消息受影响，
  其中引用回复占多数）。现在 App 在事件解析时用新增的 `WeChatAppmsg` 按 appmsg
  `<type>` 还原可读文本：引用 → `回复正文` + 换行 + `[引用 发送者] 原文摘要`；
  链接 5 / 文件 6 / 视频 4 / 表情 8 / 聊天记录 19 / 小程序 33·36 / 转账 2000 /
  红包 2001 / 视频号 51 → `[类型] 标题`；拍一拍（62）与 `at`/媒体段保持原样。
  旧 bridge（4.1.12 legacy 路径）原样透传的 appmsg XML 正文也一并还原。
  历史消息由 `MemoryStore.repairAppmsgMessageTexts` 启动时幂等重算并刷新会话预览。
  群聊触发判定只取回复正文（`RuleEngine.triggerText`），被引用原文仅作为 AI 上下文，
  不会因引用旧的 @/关键词消息而重复唤醒；真实结构化 `at` 段不受影响。
  新增 `WeChatXML`（共享 XML 工具，`PatMessage` 去重）、`WeChatAppmsgTests`、
  `AppmsgRoutingTests`（实时替换、拍一拍不回归、历史修复幂等、群触发只看正文）。当前 Swift 测试 164 项通过。

## [1.1.0] — 2026-10-22

### 新增

- **微信 4.2.0.5 (270341) 适配**：新增 `hook/versions/4_2_0_5_mac.json`；App 的 R3 原生发送
  版本门禁同时接受 4.2.0.5 (270341) 与历史 4.1.15.55 (270135)，并按版本生成
  `hook-4.2.0.5-270341.json` 运行期配置；安装/管理脚本默认支持版本更新为 4.2.0.5，
  历史 4.1.12.53 / 4.1.15.55 版本文件与说明保留；README、安装/架构/UI 文档与中英界面文案同步。
  2026-10-22 在 4.2.0.5 (270341) 完成真机验证：Gadget 注入 + ad-hoc 重签（保留 sandbox
  entitlements）后微信正常启动、gadget 27042 监听；私聊与自消息入站字段正确
  （`is_self` / `target_id`）；通讯录解密读取真实昵称/群名/群成员；R3 文本发送真机送达
  （手动发消息捕获 seed、bridge 重启后从 `r3-seed.json` 恢复 seed 再次送达），微信全程存活。
  版本文件已按真机验证结果修正并生效。群聊 @ / 拍一拍沿用既有逻辑，本轮**未单独复测**；
  媒体下载维持自 4.1.15 起的已知缺失（4.2.0.5 hook 日志中
  downloadFile/downloadImag 仍 skipped，non-fatal）。

## [1.0.0] — 2026-10-20

### 新增

- macOS 原生 SwiftUI 微信 AI 助手：Frida Gadget 注入官方微信（唯一实例），
  Go OneBot bridge + `hook/script.js` 底层收发，OpenAI 兼容模型生成拟人化回复。
- 9 个侧边栏页面（总览/会话/机器人/AI 模型/人格/记忆/定时任务/日志/设置）+ 首次向导、
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

[Unreleased]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/compare/v1.7.0...HEAD
[1.3.0]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/tag/v1.3.0
[1.4.0]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/tag/v1.4.0
[1.5.0]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.5.0
[1.5.1]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.5.1
[1.5.2]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.5.2
[1.6.0]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.6.0
[1.6.1]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.6.1
[1.6.2]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/tag/v1.6.2
[1.7.0]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/tag/v1.7.0
[1.0.0]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.0.0
[1.1.0]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.1.0
[1.2.0]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.2.0
[1.2.1]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.2.1
[1.2.2]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.2.2
[1.2.3]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/tree/v1.2.3
[1.2.4]: https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/tag/v1.2.4
