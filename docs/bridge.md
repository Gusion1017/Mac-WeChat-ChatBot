# Bridge：本地 OneBot 桥接

`bridge/` 是 macOS 原生微信 AI 助手的本地桥接进程，负责两件事：

1. 通过 Frida Gadget（TCP `127.0.0.1:27042`）连接已注入 Gadget 的官方微信，加载
   `script.js`，接收微信消息并调用 Hook 的发送能力；
2. 对 App 暴露 OneBot 风格的 WebSocket 事件（`/ws`）与 HTTP 发送接口
   （`/send_private_msg`、`/send_group_msg`）。

```
WeChat.app (Frida Gadget) ⇄ bridge/onebot ⇄ WeChatAI.app
                              │
                              ├─ WS  /ws       事件推送（无鉴权，仅 127.0.0.1）
                              └─ HTTP send_*   发送（Authorization: Bearer <token>）
```

上游来源与许可证：

- 项目：<https://github.com/yincongcyincong/weixin-macos>，子目录 `onebot/`
- 提交：`f222f37321f66d3a199cb3c7642f77f7504d85da`（2026-09-28）
- 许可：**GPL-3.0**（完整文本见 [`bridge/LICENSE`](../bridge/LICENSE)；
  衍生说明见 [`bridge/NOTICE`](../bridge/NOTICE)）
- 本项目以上游 `onebot/` 为基线，**Go 源码有修改与新增**（自消息方向、入站归一化、
  通讯录目录、R3 句柄持久化等）；逐文件清单与原因见 [`bridge/NOTICE`](../bridge/NOTICE)。
  `script.js` 同步 `hook/script.js` 的微信 4.1.12 / 4.1.15 ABI 适配（见「与上游差异」）。

---

## 1. 构建

### 1.1 前置条件

| 项 | 要求 |
| --- | --- |
| 硬件/系统 | Apple Silicon（arm64）macOS；已验证 macOS 26.7.1 |
| 编译工具 | Xcode 或 Xcode Command Line Tools（`xcrun --find clang` 可用） |
| 网络 | 首次构建需下载 Go 工具链、Frida devkit、Go modules |
| 磁盘 | 约 1 GB（缓存 500 MB + 产物 96 MB） |

构建固定版本（均带 SHA256 校验）：

| 依赖 | 版本 | 来源 |
| --- | --- | --- |
| Go | 1.25.14 darwin-arm64 | <https://go.dev/dl/>（失败时回退 `golang.google.cn` / 阿里云镜像） |
| frida-core-devkit | 17.8.0 macos-arm64 | <https://github.com/frida/frida/releases/tag/17.8.0> |

### 1.2 一键构建

```bash
cd /path/to/ChatBot
scripts/build_bridge.sh
```

脚本行为：

- 工具链与缓存放在 `/tmp/chatbot-bridge-cache`（可用 `BRIDGE_CACHE_DIR` 覆盖），
  不安装 Homebrew 包、不改用户 `PATH`、不读写用户 `go env`（`GOENV=off`）；
- 下载 Go tarball 后校验 SHA256；解压到缓存；下载并校验 frida-core-devkit；
- 用独立的 `GOCACHE`/`GOMODCACHE`/`GOPATH`（均在缓存目录）下载 Go modules；
  默认 `GOPROXY` 失败时自动改用 `https://goproxy.cn,direct` 重试；
- 以 CGO 编译：`CGO_CFLAGS=-I<devkit>`、`CGO_LDFLAGS=-L<devkit>`，
  由 `frida-go` 自带 `-lfrida-core`；`CC=$(xcrun --find clang)`，`SDKROOT=$(xcrun --show-sdk-path)`；
- 构建参数：`-trimpath -buildvcs=false -ldflags="-s -w"`；
- 自检：产物必须是 Mach-O arm64，`onebot -h` 必须正常；若仓库存在 `hook/script.js`，
  还会对比它与 `bridge/script.js` 的 SHA256，不一致时给出同步警告；
- 运行 `go test ./...`（6 个 `_test.go`：鉴权/参数校验/WS 动作、入站归一化、
  `HandleMsg` 字段保留、通讯录、protobuf dump、工具函数；`BRIDGE_SKIP_TESTS=1` 可跳过）。

干净重建（下载与编译全部重来，约 70 秒，取决于网络）：

```bash
rm -rf bridge/onebot /tmp/chatbot-bridge-cache
scripts/build_bridge.sh
```

只清构建缓存、保留已下载工具链：

```bash
BRIDGE_CLEAN=1 scripts/build_bridge.sh
```

自定义缓存目录（例如 CI）：

```bash
BRIDGE_CACHE_DIR="$PWD/.cache-bridge" scripts/build_bridge.sh
```

### 1.3 产物

```bash
$ file bridge/onebot
bridge/onebot: Mach-O 64-bit executable arm64

$ ls -l bridge/onebot
-rwxr-xr-x ... 100074658 ... bridge/onebot     # 约 95 MiB

$ otool -L bridge/onebot | head
# 只依赖系统库/Frameworks，没有 libfrida-core.dylib
```

Frida 以**静态库**链接进可执行文件，因此分发时不需要额外 dylib；代价是二进制较大
（未 strip 时约 133 MB，strip 后约 95 MB）。

构建成功后 `bridge/` 结构（源码 + 运行时资源）：

```
bridge/
├── onebot              # 构建产物（被 .gitignore 忽略，发布前需构建）
├── script.js           # 运行时读取；由 hook/script.js 同步（scripts/sync_hook_script.sh）
├── go.mod / go.sum
├── *.go                # 上游源码 + 本项目修改/新增（清单见 NOTICE）
├── proto/              # gRPC/protobuf 生成代码（编译必需）
├── LICENSE             # 上游 GPL-3.0
├── NOTICE              # 上游来源、已修改文件与新增文件说明
└── *_test.go           # 本项目新增的 httptest 测试（不连 Frida）
```

`bridge/log/macos.log` 是 `run_bridge.sh` 的默认日志（相对 `-log_file`，已忽略）；
App 启动时会把 `-log_file` 指向 `~/Library/Logs/WeChatAI/bridge/macos.log`，见 §4.4。

> **script.js 同步**：`bridge/script.js` 是 `hook/script.js` 的运行时副本，不要手改。
> 修改 hook 脚本后运行 `bash scripts/sync_hook_script.sh`；`bash scripts/check.sh`
> 会校验两者一致。具体改动与版本说明见 [`bridge/NOTICE`](../bridge/NOTICE)，
> 文档里不要写死文件大小或 SHA256（会随脚本迭代过期）。

### 1.4 常见构建错误

| 现象 | 原因/处理 |
| --- | --- |
| `fatal error: 'stdlib.h' file not found` | 未设置 SDKROOT 或未安装 CLT。脚本已 `xcrun --show-sdk-path`；手工构建时需 `export SDKROOT=...`。 |
| `ld: warning: ignoring duplicate libraries: '-lfrida-core'` | 同时传了 `-lfrida-core`（frida-go 已带）。无害；脚本只传 `-L` 避免该警告。 |
| Go 模块下载超时 | 脚本会回退 `goproxy.cn`；也可手动 `GOPROXY=https://goproxy.cn,direct scripts/build_bridge.sh`。 |
| frida devkit 下载失败 | 从 §1.1 的 release 手动下载 `frida-core-devkit-17.8.0-macos-arm64.tar.xz`，放到 `/tmp/chatbot-bridge-cache/`（保留原文件名）后重跑。 |
| `go: command not found` | 脚本自带 Go，不会用系统 `go`；直接运行脚本即可。 |

---

## 2. 运行

### 2.1 前置条件

1. 已通过 `tools/manage_wechat.sh install` 给 `WeChat.app` 注入 Frida Gadget，
   Gadget 监听 `127.0.0.1:27042`（端口可在 App 设置中改，脚本用 `--gadget-addr` 或
   `GADGET_ADDR`）；
2. 微信已启动，且 Gadget 已启动；
3. Hook 版本 JSON 存在，默认 `hook/versions/4_2_0_5_mac.json`；
4. 微信图片临时目录存在（`.../xwechat_files/<wxid>/temp/<...>/Img/`），
   App 侧会探测/创建；脚本会检查；
5. `bridge/onebot` 与 `bridge/script.js` 已构建/同目录存在。

> `onebot` 用 `os.ReadFile("./script.js")` 读取脚本，**当前工作目录必须是
> `bridge/`**。`scripts/run_bridge.sh` 会自动 `cd`；App 启动子进程时必须设置
> `currentDirectoryURL` 为 bridge 资源目录（当前 `HookManager.startBridge` 已这样实现）。

### 2.2 脚本参数

```bash
scripts/run_bridge.sh [选项]
```

| 环境变量 | 命令行参数 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `WECHAT_CONF` | `--wechat-conf` | `hook/versions/4_2_0_5_mac.json` | Hook 版本 JSON |
| `PORT` | `--port` | `58080` | HTTP/WS 监听端口；始终只绑定 `127.0.0.1` |
| `TOKEN` | `--token` | 随机生成 64 字符 hex | OneBot token；HTTP 鉴权用 |
| `IMAGE_PATH` | `--image-path` | 无（**必填**） | 微信图片/语音/视频/文件临时目录，必须已存在 |
| `MEDIA_DIR` | `--media-dir` | `$HOME/Library/Application Support/WeChatAI/media` | 入站图片获取的落盘根目录；只写该目录，不写 app bundle |
| `GADGET_ADDR` | `--gadget-addr` | `127.0.0.1:27042` | Frida Gadget 地址 |
| `LOG_LEVEL` | `--log-level` | `info` | `debug` / `info` / `warn` / `error` |
| `BRIDGE_BIN` | `--bin` | `bridge/onebot` | 自定义可执行文件 |
| `HOOK_SEND_DISABLED` | —（仅环境变量） | `true` | 强制关闭 4.1.15 主动发送；显式 `false` 才允许 Hook/JSON 决定 |

示例：

```bash
IMAGE_PATH="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_xxxxxxxx/temp/2026-10/Img" \
  scripts/run_bridge.sh
```

```bash
scripts/run_bridge.sh \
  --port 58081 \
  --token "$(openssl rand -hex 32)" \
  --wechat-conf hook/versions/4_2_0_5_mac.json \
  --image-path "/Users/me/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_x/temp/2026-10/Img"
```

脚本会先做前置检查（二进制、`script.js`、版本 JSON、`IMAGE_PATH`、端口占用），
打印脱敏后的配置，然后 `exec`：

```bash
bridge/onebot \
  -type=gadget \
  -gadget_addr=127.0.0.1:27042 \
  -wechat_conf=/path/to/hook/versions/4_2_0_5_mac.json \
  -receive_host=127.0.0.1:58080 \
  -token=<token> \
  -conn_type=websocket \
  -image_path=/path/to/.../Img \
  -media_dir="$HOME/Library/Application Support/WeChatAI/media" \
  -log_level=info
```

参数与 [`docs/architecture.md`](architecture.md) §3.1 完全一致。

### 2.3 行为说明

- 启动顺序：解析参数 → 初始化日志 → **连接 Frida Gadget 并加载 `script.js`** →
  启动发送 worker → HTTP/WS 监听。**Gadget 连不上时进程立即退出（exit 1），
  不会开监听端口，也不会重试**。
- 日志同时输出到 stdout 与 `bridge/log/macos.log`（lumberjack：单文件 100 MB，
  最多 10 份，保留 30 天）。
- 事件推送不经过 `-send_interval` 节流：入站事件与发送回执在 `HandleIncomingMessage` /
  `SendWebSocketMsg` / `SendHttpReq` 中立即写出；`-send_interval`（默认 1000ms，App 运行期
  传 100）只约束真正发往微信的消息（`worker.go SendWechatMsg`）。2026-10-23 前事件推送
  也会固定 sleep 该时长，历史回放时表现为每条事件固定延迟 + 额外定时器唤醒。
- 事件级日志（`收到消息` / `发送数据` / `收到入站消息事件`）为 Debug 级，只记录字节长度与
  最多 256 字符的截断预览；默认 `-log_level=info` 下不产生每事件日志（排障时显式
  `-log_level=debug`）。Warn/Error 不受影响。
- 上游启动时会把完整 token 打印到 stdout（`OnebotToken <token>`）；App 侧日志
  如需脱敏，由 App 处理。
- 按 `Ctrl-C`/SIGTERM 时上游会清理 Frida script/session/device 后退出。
- Hook 脚本可选环境变量（`run_bridge.sh` 会原样透传）：
  `HOOK_DEBUG=1`（诊断日志）、`HOOK_REQ2BUF_MODE=A|B`（autoBuffer 预写策略，
  默认 B）、`HOOK_REQ2BUF_NODE_MODE=skip-erase|legacy`（found 路径清理策略）、
  `HOOK_REQ2BUF_SEND_MODE=off|C1|C2|legacy`（发送策略，默认由 JSON 决定）。
  `run_bridge.sh` 默认导出 `HOOK_SEND_DISABLED=true`，强制关闭主动发送；只有显式
  `HOOK_SEND_DISABLED=false` 才允许 Hook 脚本按 JSON 的 `enableSend`/`req2bufSendMode`
  执行。App 直接启动 binary 时不会经过本脚本，建议 `ProcessRunner.launch` 也注入
  `HOOK_SEND_DISABLED=true`（安全默认，需开发送时再关）。
  详见 `hook/script.js` 顶部。

---

## 3. 接口契约（与 `docs/architecture.md` §3 核对）

### 3.1 WebSocket 事件（bridge → App）

- 地址：`ws://127.0.0.1:58080/ws`；**无鉴权**，只应监听回环地址。
- 事件在 `HandleIncomingMessage` 完成身份归一化与入站图片登记后**立即**写出（不等待
  `-send_interval`），WS 写由 `wsWriteMu` 串行化；HTTP 推送同样立即发出。
- 上游通过 `json.Marshal(WechatMessage)` 发送紧凑 JSON；`message` 为数组；
  `sender`、`group_id`、`raw_message` 等在 protobuf 解析路径上通常存在。
- 实际字段集合比契约示例多：`post_type`、`msgsource`、`show_content`。
  解析方应忽略未知字段。
- **`time` 的单位是毫秒**（`time.Now().UnixMilli()`，13 位），不是契约示例中的
  10 位秒级时间戳；App 解析时需按毫秒处理或按位数兼容。
- `message[]` 类型：`text`（`data.text`）、`image`（`data.url` 为
  `file://...`，`data.text` 保留微信 XML）、`record`/`voice`、`video`、`file`、
  `face`。legacy `HandleMsg` 路径的媒体事件在推送前会同步下载/落盘，失败时整条事件
  可能被丢弃（见 §6）。
- 事件在 `HandleMsg` 中同步处理：图片/文件/视频/语音会先下载到 `image_path`
  再推送，因此大文件会拖慢该条事件（仅 legacy protobuf 路径；4.1.15 / 4.2.0.5 的
  Message finalizer 入站路径不再同步下载，见下一条）。
- **入站图片（4.1.15 / 4.2.0.5，2026-10-23）**：hook 只给文本占位 `[图片]`，图片 XML
  在 `raw_message`。`incoming.go` 的 `registerIncomingImage` 在推送前解析
  `<img>` 的 `aeskey` / `cdnmidimgurl` / `cdnthumburl` / `cdnthumbaeskey` / `md5` /
  `length`，按 `message_id` 登记下载候选（mid → thumb），并把文本占位替换成
  **无 data 的** `{"type":"image","data":{}}`。新增的结构化字段不携带 aeskey/CDN key，
  运行日志也不打印它们；`raw_message` 仍保留 hook 原始图片 XML（与历史行为一致）。
  实际下载发生在 App 调用 `POST /fetch_image` 时（按需，见 §3.4），不会阻塞事件推送。
  该链路已于 2026-10-23 在微信 4.2.0.5 真机验证（修正了下载 Hook 点与下载请求里
  变长字符串的长度处理；细节只在 `hook/` 实现中维护，不在公开文档展开）。

### 3.2 WebSocket 动作（App → bridge）

支持的动作（`websocket.go`）：

| action | 响应 | 说明 |
| --- | --- | --- |
| `get_login_info` | `{"echo":..., "status":"ok", "data":{"user_id":..., "nickname":...}}` | 上游 `nickname` 直接填 `wxid`（不是昵称）；`user_id` 来自 `image_path` 推断或已收到事件。 |
| `get_group_member_info` | `{"echo":..., "status":"ok", "data":{"nickname":...}}` | 只查进程内缓存（曾收到该群该成员消息）；未命中时为 `null`。 |
| `get_contact_directory` | `{"echo":..., "status":"ok", "data":{"ok":true,"users":{...},"groups":{...}}}` | 本机**只读**读取通讯录后的目录；失败回 `{"status":"failed","error":...}`。 |
| `send_private_msg` / `send_group_msg` | **不回包** | 发送结果只写日志；成功/失败不会产生 echo/响应。App 应以 HTTP 发送为主通道。 |

其余 action 会被静默忽略。同一时刻只有一个 WS 连接（全局 `conn`）；新连接会替换旧连接，
未连接期间的事件会被丢弃（仅记日志）。WS 入站消息无需 token。

### 3.3 HTTP 发送接口

```http
POST http://127.0.0.1:58080/send_private_msg
Authorization: Bearer <token>
Content-Type: application/json

{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}
```

- 两个路径 `/send_private_msg`、`/send_group_msg` 走**同一个 handler**；
  路径本身不决定私聊/群聊，实际由 body 中的 `user_id`/`group_id` 决定。
- 鉴权：`Authorization` 必须是 `Bearer <token>`。注意上游用
  `strings.TrimPrefix` 解析，**恰好等于 token、不带 `Bearer ` 前缀的 header 也会通过**；
  这是上游的宽松行为，未修改。
- 成功：HTTP 200 `{"status":"ok"}`；失败：HTTP 500
  `{"status":"failed","error":"..."}`。
- 参数校验：非 POST → 405（纯文本）；token 缺失/错误 → 401（`未授权`）；
  JSON 无效或 `message` 为空、`user_id`/`group_id` 都缺失 → 400（`无效的 JSON`/
  `参数缺失`，纯文本）。
- 文本分片会被拼接后一次发送；`at` 元素仅群聊且缓存过该成员昵称时生效，否则被忽略；
  媒体元素使用 `data.file`（支持 `base64://...`）；`record` 会转成 `voice` 发送。
- HTTP handler 会把消息交给发送 worker 并等待结果；`conn_type=websocket` 不影响 HTTP 发送。
- 额外的未鉴权调试端点：`/test_ws`（向当前 WS 连接写任意 body）以及
  `net/http/pprof` 注册的 `/debug/pprof/*`。它们只在 127.0.0.1 上暴露，详见 §7。

### 3.4 入站图片获取接口

```http
POST http://127.0.0.1:58080/fetch_image
Authorization: Bearer <token>
Content-Type: application/json

{"message_id":"<OneBot message_id>"}
```

- 鉴权与 `/send_*` 一致（Bearer + `hmac.Equal`）；非 POST → 405，未授权 → 401，
  `message_id` 缺失/未登记/已过期 → 400，下载失败 → 502。
- 成功：HTTP 200

  ```json
  {"status":"ok","data":{"file":"file:///Users/<user>/Library/Application%20Support/WeChatAI/media/2026-10-23/<name>.jpg","message_id":"..."}}
  ```

- 失败：HTTP 502 `{"status":"failed","error":"中文原因"}`。
- 处理流程：查 `pendingImageJobs` → 并发槽（上限 2）→ 对 mid/thumb 候选逐个
  `triggerDownload`（Frida 导出）触发微信 CDN 下载 → 等待下载分片稳定 → 用 XML 的
  `aeskey` AES-ECB 解密（与 legacy `GetFilePath` 相同的补齐/截断规则）→ 校验图片魔数
  → 写入 `<media_dir>/<yyyy-MM-dd>/<md5>.<ext>`（缩略图回退加 `-thumb` 后缀）
  → 返回 `file://` 路径。
  单次总预算约 12 秒；成功/失败都会移除该 `message_id` 的登记（不重复下载）。
- 图片只写入 `-media_dir`（`filepath.Rel` 校验，拒绝目录穿越），绝不写入 app bundle；
  日志不打印 aeskey / CDN key / XML。
- 该接口**不会**主动下载：该会话的「获取图片」关闭时 App 不会调用，因此不会发起新的下载
  （已在途的单次请求可能完成）。

---


> **语音接口（2026-10-26）**：`POST /fetch_voice`、`POST /send_voice` 与 `GET /voice_status` 的完整契约、
> 状态与 4.2.0.5 限制见 [`voice.md`](voice.md)。入站下载默认 `fileType=15` 已真机验证；
> 出站仍存在“气泡可见但音频无声”的上传关联问题，默认 `r3VoiceSend=false`，App 自动降级文字；
> `/voice_status` 提供登录稳定倒计时与句柄状态。

## 4. 验证记录

以下为 2026-10-19 在 macOS 26.7.1 / arm64 / Xcode 27 上的实测结果。

### 4.1 构建产物

```bash
$ file bridge/onebot
bridge/onebot: Mach-O 64-bit executable arm64
$ stat -f '%z bytes' bridge/onebot
100074658 bytes
$ bridge/onebot -h
Usage of bridge/onebot:
  -conn_type string
  -gadget_addr string
  ...
$ echo $?
0
```

`scripts/build_bridge.sh` 从**完全干净**状态（删除 `bridge/onebot` 与
`/tmp/chatbot-bridge-cache`）重跑成功：下载并校验 Go 1.25.14 与 devkit 17.8.0，
编译、`-h` 自检、契约测试全部通过，耗时约 70 秒。

`script.js`（Hook 脚本）单独验证：用与 `main.go` 相同的 `text/template` + 版本 JSON
渲染 4.1.15 与 4.1.12 的模板，`node --check` 均通过；4.1.15 渲染出对应的布局标记，
4.1.12 走旧布局（由上游代码按版本处理）。

### 4.2 无 Gadget 行为

无 Gadget 监听时（`-gadget_addr=127.0.0.1:65534`）：

```bash
$ python3 - <<'PY'   # 带超时，确认不会挂起
subprocess.run([...bridge/onebot, "-type=gadget", "-gadget_addr=127.0.0.1:65534", ...], timeout=15)
PY
EXIT=1 ELAPSED=0.07s
...
2026-10-19 ... | FATAL | .../main.go:109 ❌ 附加失败
```

结论：

- 进程在 **0.07 秒内退出（exit 1）**，不会挂起、不会开端口；
- 输出可读的 `FATAL ... ❌ 附加失败`；由于上游 `Fatal("...", err)` 的字段拼接方式，
  具体网络错误文本不会附加显示；
- 退出前先创建了 `./log/macos.log`（日志文件的副作用）；
- 因为 HTTP 监听在 Gadget attach 成功之后才启动，**无 Gadget 环境下无法用 curl 对真实进程
  测试 401**（进程根本到不了 ListenAndServe）。任务说明允许用 mock 场景验证；
  httptest 覆盖见 §4.3。
- 在 Gadget 已就绪的联调环境中（23:57 由 Lead 启动的 bridge，端口 58080），
  bridge 成功 attach、加载最终 `script.js` 并进入监听；随后用 curl 对真实进程
  验证了 405/401/400（未发送任何合法消息，避免真实外发），结果见 §4.3。

### 4.3 HTTP 鉴权 / 参数校验（真实进程 + httptest mock）

新增 `bridge/http_auth_test.go`，只启动 `httptest` 服务器（`sendHandler` /
`handleWebSocket`），不启动 Frida、不占真实端口：

```bash
cd bridge
go test -count=1 -timeout=120s -run 'TestSendHandlerAuth|TestWebSocketGetLoginInfo' .
```

覆盖并通过：

| 场景 | 结果 |
| --- | --- |
| `GET /send_private_msg` | 405 `仅支持 POST` |
| 无 `Authorization` | 401 `未授权` |
| 错误 token（含 `Bearer `） | 401 `未授权` |
| 错误 token（无 `Bearer `） | 401 `未授权` |
| 正确 token + 非法 JSON | 400 `无效的 JSON` |
| 正确 token + `message: []` | 400 `参数缺失` |
| 正确 token + 无 `user_id`/`group_id` | 400 `参数缺失` |
| WS `get_login_info` | 返回 `status=ok`、正确 `echo`、`data` 为对象 |

说明：正确 token + 合法消息会进入真实发送队列并等待 `SendWorker`，测试不启动 worker，
因此测试刻意不构造该场景（否则会阻塞），HTTP 发送成功路径由端到端联调验证。

真实进程 curl 复测（bridge 已由 Lead 启动在 `127.0.0.1:58080`，2026-10-19 23:58；
只发无效请求，不触发任何真实消息）：

| 请求 | 实际响应 |
| --- | --- |
| `GET /send_private_msg` | HTTP 405 `仅支持 POST` |
| `POST /send_private_msg` 无 `Authorization` | HTTP 401 `未授权` |
| `POST /send_private_msg` 错误 `Bearer wrong-token` | HTTP 401 `未授权` |
| `POST /send_private_msg` 正确 token + `{not-json` | HTTP 400 `无效的 JSON` |
| `POST /send_private_msg` 正确 token + `message: []` | HTTP 400 `参数缺失` |
| `POST /send_group_msg` 正确 token + 无 `user_id`/`group_id` | HTTP 400 `参数缺失` |

结论：鉴权与参数校验在真实 bridge 进程上可用；成功发送路径由 Lead 的真机联调
（日志中 `发送文本任务执行结果`）覆盖，本项目未主动发送真实消息。

### 4.4 运行脚本

`scripts/run_bridge.sh` 在无 Gadget 时同步输出配置并快速退出（exit 1），
`--wechat-conf`/`--image-path` 的相对路径会被转为绝对路径；缺少版本 JSON、
`IMAGE_PATH` 或二进制时给出明确中文错误。日志写入 `bridge/log/macos.log`。

---

## 5. 与上游差异

完整清单以 [`bridge/NOTICE`](../bridge/NOTICE) 为准（逐文件列出与上游一致、已修改与新增的
文件及原因）。概要：

1. **构建方式**：上游 `setup_frida_and_build.sh` 使用 `go build`（未 strip）；
   本项目用 `-trimpath -buildvcs=false -ldflags="-s -w"`，产物约 95 MB（上游约 133 MB）。
   调用方只是 App 启动进程，不受影响；如需保留符号调试，去掉这些参数即可。
2. **已修改文件**：`main.go`（`-self_id`、`-log_file`、`-media_dir`、通讯录 DB key 回灌、
   `/fetch_image` 路由）、`logger.go`（`-log_file`）、`param.go`（自消息方向与 `pat_*`
   字段、`media_dir`）、`incoming.go`（Message finalizer 归一化、非法群 ID 清洗、
   通讯录昵称补全、入站图片登记）、`websocket.go`（`get_contact_directory`、`at` 昵称回退）、
   `http.go`（`at` 昵称回退、`/fetch_image` handler）、`worker.go`（R3 提交后跳过 buf2resp）、
   `msg.go`（下载代次 `latestDownloadAfter`，供入站图片等待触发后的新下载）。
3. **本项目新增**：`contact.go`（通讯录目录与本地受限密钥缓存）、
   `media.go`（入站图片登记、按需下载/解密/落盘）、
   `r3seed.go`（发送句柄按 PID 持久化）、`NOTICE`、`.gitignore`、
   `*_test.go`、`UPSTREAM_README.md`（上游 `readme.md` 重命名）与
   `Makefile.upstream`（上游 Makefile，仅参考）。
4. **工程脚本**：`scripts/build_bridge.sh`（下载/校验/离线缓存/Go 工具链隔离/构建自检）
   与 `scripts/run_bridge.sh`（参数化启动与前置检查）。
5. **`script.js`**：唯一被修改的上游脚本，已同步 `hook/script.js` 的 4.1.12 / 4.1.15
   ABI 适配（入站消息、R3 发送、通讯录）。它以 `hook/script.js` 为唯一事实来源，
   细节见 NOTICE。

---

## 6. 已知限制

1. **Gadget 必须先就绪**：bridge 不重试 Gadget 连接；失败即退出，需要 App/用户重启。
2. **`script.js` 必须与 binary 同目录且以该目录为 cwd**：否则 `loadScript` 阶段 Fatal。
3. **`image_path` 启动时不校验**：上游只在媒体写入/下载时用到它，`os.MkdirAll`
   可能自动建目录；若目录不可写/沙箱不允许，媒体相关事件会失败。`run_bridge.sh`
   会提前检查目录存在，App 侧也应探测/创建。
4. **`time` 为毫秒**（见 §3.1），与架构示例的秒级值不同。
5. **WS 单连接、无鉴权**：断线期间事件丢失；重连会替换连接。WS `send_*` 无 echo，
   发送结果不可靠，App 应使用 HTTP。
6. **HTTP `Authorization` 解析宽松**：无 `Bearer ` 前缀但等于 token 也会通过。
7. **媒体同步下载**：图片/文件/视频/语音在事件推送前下载到 `image_path`；
   下载失败会导致该条事件不推送；大文件会阻塞该事件。
8. **昵称缓存依赖历史消息**：`at`、`get_group_member_info` 使用进程内缓存，
   冷启动后未收到过对应群成员消息时可能缺失。
9. **`myWechatId` 推断**：未收到事件前从 `image_path` 的
   `xwechat_files/<wxid>_xxx/...` 推断，路径格式不符时可能为空或截断。
10. **日志含聊天内容**：`Info("发送数据", ...)` 会记录完整事件 JSON；日志文件
    （`run_bridge.sh` 默认 `bridge/log/`，App 默认 `~/Library/Logs/WeChatAI/bridge/`）
    应按敏感数据保护并定期清理。
11. **静态链接 Frida**：二进制约 95 MB，冷启动/内存占用高于普通 Go 程序；
    未在真实微信 Gadget 环境下测量 RSS（目标 <80 MB 需联调确认）。
12. **无健康检查端点**：只能通过 WS 是否可连接判断；`/debug/pprof` 与 `/test_ws`
    不属于契约，勿依赖。
13. **`bridge/script.js` 是手同步副本**：Hook 脚本继续迭代时容易忘记同步；发布前
    务必对比 `hook/script.js` 与 `bridge/script.js` 的 SHA256（见 NOTICE）。
14. **`pat` 出站段保留但产品不再使用**：bridge 的 HTTP/WS 仍能解析 `{"type":"pat"}`
    并调用 hook 的 `triggerSendPatMessage`，属于历史/实验路径；App 已移除 `sendPat`，
    `r3PatSend` 永久保持 `false`，不要启用原生回拍。
15. **入站图片获取（2026-10-23 真机验证）**：bridge 优先使用微信收到图片后**自然下载**
    的分片（通常事件到达时已开始），没有分片时才用 Frida 导出 `triggerDownload` 主动
    触发；触发被拒绝也不直接失败，会继续等待自然分片。收到分片后用 XML 的 `aeskey`
    AES-ECB 解密并落盘。不按 XML 的 `length`/`cdnthumblength` 截断（该字段不总是真实
    明文长度，会切掉 JPEG 的 EOI 导致半张图）；改为按图片自身结束标记（JPEG EOI /
    PNG IEND 等）裁掉 AES 补齐字节，数据不完整时不落盘并继续等分片增长。4.2 的 mid 图
    常见 HEVC（`hevc_mid_size` / `cdnmidheight=0`），当前没有 HEVC 解码，自动改用
    JPEG 缩略图（实测完整 JPEG 图片）。4.2.0.5 端到端实测通过。
    限制：只处理实时入站图片，历史消息不回填；只支持图片（不含表情/语音/视频/文件）；
    触发调用带 10 秒超时。

---

## 7. 安全

- **仅回环**：`run_bridge.sh` 固定 `-receive_host=127.0.0.1:<port>`，App 同样如此；
  不要把端口暴露到局域网。
- **HTTP token**：`/send_*` 与 `/fetch_image` 要求 `Authorization: Bearer <token>`；token 建议用
  `openssl rand -hex 32` 生成（App 首次启动机器人时生成 64 字符 hex）。
  `run_bridge.sh` 未提供 token 时会随机生成并打印。
- **token 可见性**：上游启动时把完整 token 打印到 stdout，且 token 通过命令行参数
  传给进程，同机用户可用 `ps` 看到；仅适用于单用户桌面环境。App 日志如需脱敏，
  应在读取 bridge stdout 时过滤 `OnebotToken`。
- **未鉴权端点**：`/ws`、`/test_ws`、`/debug/pprof/*` 均无鉴权（`/test_ws` 可向
  当前 App WS 连接注入任意 JSON）。它们只监听 127.0.0.1；本机其他进程仍可访问，
  因此不要在不受信任的多用户机器上运行。
- **日志**：`bridge/log/macos.log` 含消息内容，轮转上限 100 MB × 10、保留 30 天。
  入站图片获取的日志只记 `message_id`、字节数与失败原因，**不记** aeskey / CDN key / XML。
- **媒体写入边界**：`/fetch_image` 只写 `-media_dir`（默认
  `~/Library/Application Support/WeChatAI/media`），写入前用 `filepath.Rel` 拒绝
  `..`/绝对路径越界；不会写 app bundle（避免破坏 ad-hoc 签名）。
- **许可证**：本项目是 GPL-3.0 衍生作品。分发 App/二进制时需按 GPL-3.0 提供
  `bridge/` 对应源码（含本项目修改），并保留 `LICENSE`、`NOTICE`。
  Frida 静态链接遵循 wxWindows Library Licence 3.1 的二进制例外；Go module
  依赖各自许可证见 `go.sum` 对应模块。
