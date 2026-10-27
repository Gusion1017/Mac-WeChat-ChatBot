# 安装与启动（从 GitHub 获取）

> 本项目是 **macOS 原生 App + 微信 Hook**，不是双击即用的普通应用。
> GitHub 的「Download ZIP」默认只给**源码**，不含已编译的 App、bridge 二进制和 Frida Gadget。
> 非开发者请让发布者提供 **Releases 里的 App 压缩包**；只有源码时按「源码构建」操作。
>
> 当前发布版本：**1.6.0（build 16，2026-10-28）**，Releases 压缩包约 72MB。

## 1. 先确认环境

| 项目 | 要求 |
| --- | --- |
| 硬件 | Apple Silicon（arm64） |
| 系统 | macOS 26 或更高 |
| 微信 | 4.2.0.9 (270345)、4.2.0.5 (270341)、4.1.15.55 (270135) 或 4.1.12.53 (269365) 之一，已安装并登录；默认位于 `/Applications/WeChat.app`，当前用户需对该 App 有写权限 |
| 命令行工具 | **安装 Hook 必需**：Xcode Command Line Tools（或完整 Xcode），提供 `/usr/bin/python3` 与 `/usr/bin/otool`。安装命令 `xcode-select --install`；不需要 Apple 开发者账号 |
| 权限 | 安装到 `/Applications`、修改微信或移除 quarantine 时可能需要管理员密码 / Touch ID |
| 磁盘 | 安装 Hook 会完整备份微信（约 665MB），建议预留 ≥2.5GB |
| 源码构建 | 仅方式 B 需要 Xcode 27（含命令行工具）；方式 A 只需上面的 CLT |
| CosyVoice3（可选） | 本地大模型旁路：额外需要 `uv`（或 conda）与 `ffmpeg`，首次安装约 8GB 磁盘（运行环境 ~2–3GB + 模型 ~5.4GB）；App 不内置音色，需自行导入参考音；不装不影响 Kokoro/ZipVoice |

> 微信版本必须**精确匹配**上表四个版本之一；不在列表时向导会提示不匹配，不要强行安装 Hook。
> 当前安装脚本默认以 4.2.0.9 (270345) 为目标；4.2.0.5 / 4.1.15.55 / 4.1.12.53 仍在已知支持列表，
> 可直接安装，`hook/versions/` 保留其历史版本文件。4.2.0.5 已于 2026-10-22 完成真机验证：私聊/自消息
> 入站、通讯录、R3 文本发送（含 bridge 重启后句柄恢复）；群聊 @ / 拍一拍沿用既有逻辑，本轮未单独复测；
> 图片获取（入站图片自动下载/解密）已接通并真机验证。4.2.0.9 已完成代码与地址表适配（2026-10-27），
> 并完成文本真机验证：2026-10-27 在 4.2.0.9 (270345) 完成真机验证：Gadget 注入 + ad-hoc 重签（保留 sandbox entitlements）、WeChat 正常启动且 gadget 27042 监听；hook 基址解析与 classA/service vptr 校验通过；通讯录解密读取（29 联系人 / 1 群 / 10 群成员，DB key 回灌）；入站自消息事件正确；手动发一条文本捕获并持久化 R3 发送句柄后，R3 文本发送到文件传输助手 slot13 返回 0、worker result=1。语音发送沿用同一链路但本轮未复测（需手动发一条语音捕获 voice seed/header）；群聊 @ / 拍一拍与媒体下载未复测。
>
> 如果微信来自 **App Store**，或 App 由 root 安装导致当前用户不可写，Hook 可能装不上；
> 请改用微信官网下载的 arm64 版，并确认 `/Applications/WeChat.app` 属主是当前用户。
> 修改微信仍有风险，安装前请保留官方备份。

## 2. 方式 A：Releases 里的 App 压缩包（推荐给普通用户）

发布者在本地构建后，把 `WeChat AI.app` 压缩上传到 GitHub Releases。当前版本 **1.6.0（约 72MB）**。

1. 下载 `WeChat-AI-1.6.0.zip`（建议同时下载 `.sha256`），解压 zip，得到 `WeChat AI.app`。
   可选校验（在下载目录执行）：

   ```bash
   shasum -a 256 -c WeChat-AI-1.6.0.zip.sha256
   ```

2. 把 `WeChat AI.app` 拖到 `~/Applications`（当前用户，无需管理员）或 `/Applications`（所有用户）。
   下文示例分别给出两种安装路径。

3. **首次打开会被 Gatekeeper 拦截**（App 是 ad-hoc 签名、未做 Apple 公证）。
   **macOS 15（Sequoia）起，包括 macOS 26，已取消「右键 → 打开」这个绕过入口**，旧教程不再适用。
   正确流程：

   - 双击 App，看到“无法验证开发者 / 无法打开”的拦截提示；
   - 打开「系统设置 → 隐私与安全性」，滚动到底部，找到刚被拦截的 App，点「仍要打开」；
   - 按提示输入管理员密码或使用 Touch ID 确认。

   如果「隐私与安全性」里没有条目，或仍然被拦截，可在终端移除 quarantine。
   **路径必须与实际安装位置一致**：

   ```bash
   # 安装在当前用户目录
   xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
   open "$HOME/Applications/WeChat AI.app"

   # 安装在系统目录（需要管理员，命令前加 sudo）
   sudo xattr -dr com.apple.quarantine "/Applications/WeChat AI.app"
   open "/Applications/WeChat AI.app"
   ```

   > 不要对不存在的路径执行 `xattr`；如果 App 被系统移动过（例如 App Translocation），
   > 先把 App 拖到 `~/Applications` 或 `/Applications` 再执行。

4. 这是一个**菜单栏 App，且默认显示 Dock 图标**（`showDockIcon` 默认开启）：
   启动后 Dock 与屏幕顶部菜单栏都有入口；**左键单击菜单栏图标开合状态面板**，
   面板内提供打开主窗口、启动/停止机器人、设置与退出。右键 / Control-左键不执行操作。
   可在「设置 → 通用」关闭 Dock 图标，只用菜单栏。

5. **首次启动向导**（右上角可切换 **语言 / Language**：跟随系统 / 简体中文 / English）：

   - **环境检查**：显示 Xcode Command Line Tools 状态（已安装 / 未安装 / 检测中）。
     未安装时点「安装 Command Line Tools」会执行 `xcode-select --install` 并弹出系统安装面板；
     按提示完成（通常几分钟），回到向导点「重新检测」。**CLT 未就绪时「备份并安装 Hook」按钮禁用**。
     完整 Xcode 用户同样视为就绪；此步不需要 Apple 开发者账号。
   - **检测微信**：显示路径、版本与进程状态；版本须精确匹配。
   - **备份并安装 Hook**：先**完全退出微信（包括菜单栏图标，不只是关闭窗口）**，
     向导会完整备份官方 App 后注入 Gadget 并 ad-hoc 重签。备份约 665MB、安装约 1–2 分钟
     （磁盘预留 ≥2.5GB）。安装完成后 App **不会自动打开微信**，请手动打开并登录。
   - **系统授权（TCC）**：首次读取微信容器会触发「App 数据」授权，请选择允许；
     拒绝后图片/语音相关功能与 `image_path` 检测会失败。修改微信 bundle 时可能再触发
     「App 管理」授权。App **不会**请求麦克风、语音识别或自动化权限
     （本地 SpeechAnalyzer 不需要麦克风，也不使用 AppleScript）。
   - **配置 AI**：填写通道、Base URL、模型与 API Key；Key 存在 macOS Keychain，不写入 `config.json`。
   - **启动**：完成并启动机器人。

6. **首次发送需捕获句柄**：微信 4.1.15.55 / 4.2.0.5 / 4.2.0.9 使用 R3 原生发送。首次启用、或每次微信重启后，
   需要在本机微信**手动发一条消息**捕获发送句柄；语音回复还需再发一条语音。
   句柄未就绪时回复会排队（不会丢失）。bridge 重启会从 `r3-seed.json` 自动恢复。

7. **还原官方微信**：随时可在「设置 → Hook → 还原官方微信」恢复（还原前先完全退出微信），
   或执行：

   ```bash
   bash tools/manage_wechat.sh restore
   ```

> 如果发布者没有提供 Releases 压缩包，只能用方式 B。

## 3. 方式 B：源码 ZIP（需要 Xcode 27）

Xcode 自带 Command Line Tools，满足 Hook 的 `python3` / `otool` 依赖。

1. 在 GitHub 页面 **Code → Download ZIP**，解压（目录名通常是 `Mac-WeChat-ChatBot-main`）。
2. 打开「终端」，进入解压后的目录：

   ```bash
   cd ~/Downloads/Mac-WeChat-ChatBot-main   # 以实际解压目录为准
   ```

3. 依次执行（首次会下载 Go 1.25、Frida devkit、sherpa-onnx 静态库与 Gadget，
   约需数分钟和数 GB 磁盘）：

   ```bash
   bash scripts/fetch_gadget.sh      # 下载 Frida Gadget 17.8.0（校验 SHA256）
   bash scripts/build_bridge.sh      # 构建 bridge/onebot（含 Go 测试）
   bash scripts/build_app.sh         # 生成 dist/WeChat AI.app（缺 TTS 库时自动 fetch_sherpa）
   bash scripts/install_app.sh       # 安装到 ~/Applications（移除 quarantine 并重签）
   open "$HOME/Applications/WeChat AI.app"
   ```

4. 后续与方式 A 的第 4–7 步相同（Dock/菜单栏、首启向导与 CLT 检查、退出微信后安装 Hook、
   手动登录微信、R3 首次手发消息、还原入口）。

> 只想先看看界面、不碰微信：用 `devtools/` 的 Mock 联调，见
> [`devtools/README.md`](../devtools/README.md)。

## 4. 发布者：如何制作可下载的 App 压缩包

当前发布版本 **1.6.0（build 16，2026-10-28）**，zip 约 **72MB**。在已具备 Xcode 27 / CLT 的机器上，
按下面顺序构建（`build_app.sh` 会在缺库时自动下载 sherpa-onnx，但显式执行更便于定位失败）：

```bash
bash scripts/fetch_gadget.sh
bash scripts/build_bridge.sh
bash scripts/fetch_sherpa.sh
bash scripts/build_app.sh
bash scripts/package_release.sh      # 或 make release
```

脚本会校验必需资源、检查签名、打包并生成 SHA256，产物：

- `dist/WeChat-AI-1.6.0.zip`
- `dist/WeChat-AI-1.6.0.zip.sha256`

`package_release.sh --skip-build` 可复用 `dist/WeChat AI.app` 重新打包。也可以手动执行：

```bash
bash scripts/build_app.sh
/usr/bin/ditto -c -k --norsrc --keepParent "dist/WeChat AI.app" "dist/WeChat-AI-1.6.0.zip"
( cd dist && shasum -a 256 "WeChat-AI-1.6.0.zip" > "WeChat-AI-1.6.0.zip.sha256" )
```

签名与公证的预期：

- App 为 **ad-hoc 签名**、未走 Apple 公证；`codesign -dv --verbose=4 "dist/WeChat AI.app"`
  会显示 `Signature=adhoc`、无 Team ID；
- `codesign --verify --strict "dist/WeChat AI.app"` 应通过；
- `spctl --assess --type execute -vv "dist/WeChat AI.app"` **预期返回 `rejected`**
  （来源不可识别 / 未公证），这是 ad-hoc 分发的正常结果，不代表压缩包损坏；
- 用户首次打开仍需按方式 A 第 3 步的 Gatekeeper 流程操作。

上传前校验：

```bash
cd dist
shasum -a 256 -c WeChat-AI-1.6.0.zip.sha256
```

把 zip 与 `.sha256` 上传到 GitHub **Releases**（tag 建议 `v1.6.0`），在说明里写清：

- 支持 Apple Silicon / macOS 26+ / 微信 4.2.0.9、4.2.0.5、4.1.15.55 或 4.1.12.53；
- **安装 Hook 需要 Xcode Command Line Tools**（`xcode-select --install`，无需开发者账号），
  首启向导会检测并引导安装；
- App 为 ad-hoc 签名、未公证；macOS 15+ 已无「右键 → 打开」，
  首次需在 系统设置 → 隐私与安全性 → 仍要打开，或用 `xattr -dr com.apple.quarantine`；
- 安装 Hook 会修改微信、需完整备份（约 665MB），存在账号风控与签名失效风险；
- 按 GPL-3.0 提供对应源码（仓库地址即可）。
- SHA256 指向 `.sha256` 文件，不在说明正文里手抄。

## 5. 常见问题

| 现象 | 处理 |
| --- | --- |
| 双击提示“无法验证开发者”，且找不到「仍要打开」 | macOS 15+ 已取消右键打开。先双击触发拦截，再进 系统设置 → 隐私与安全性 → 仍要打开（需管理员/Touch ID）；仍没有条目就 `xattr -dr com.apple.quarantine "<App 实际路径>"` 后 `open`。两种路径示例见方式 A 第 3 步 |
| 提示“App 已损坏” / 校验失败 | 重新下载并核对 `.sha256`；确认 App 完整解压、没有被安全软件截断；不要从不可信镜像下载 |
| 向导提示缺少 Command Line Tools / 安装 Hook 按钮禁用 | 点「安装 Command Line Tools」或终端执行 `xcode-select --install`，完成系统安装后点「重新检测」；完整 Xcode 亦可；不需要开发者账号。终端报 `invalid active developer path` 时执行 `sudo xcode-select -s /Library/Developer/CommandLineTools` |
| 微信从 App Store 安装，或 `/Applications/WeChat.app` 属主是 root | Hook 需要当前用户可写 `/Applications/WeChat.app`。App Store 版路径/签名不同，建议换官网 arm64 版；属主异常时重装微信，或在明确风险后 `sudo chown -R "$USER":staff /Applications/WeChat.app`。可用 `ls -ld /Applications/WeChat.app` 检查 |
| 打开后没有窗口 | 这是菜单栏 App（默认同时显示 Dock 图标）：**左键**单击顶部菜单栏图标开合状态面板，面板内提供「打开主窗口」、启停、设置与退出；右键 / Control-左键不执行操作。Dock 图标可在设置关闭 |
| 换微信账号后聊天记录、记忆、会话设置会切换吗 | **会，且旧账号数据不会被删除。** App 以当前登录的微信账号为边界：聊天/长期记忆/会话设置/机器人配置/人格/定时任务/新媒体自动切到该账号自己的档案（`~/Library/Application Support/WeChatAI/accounts/<wxid>/`）；AI 通道/Keychain/Hook/OneBot/语音模型/崩溃与 bridge 日志仍全局共享。升级旧版时会把旧单库复制到旧 `settings.onebot.self_id` 所属账号（只 copy 不删，旧媒体保留），因此升级后需要**切回原微信账号**才能看到旧聊天。运行中换号会停止机器人、提示后需手动重新启动；App 不提供手动选库。未登录时数据先写 `_unassigned`，登录后自动认领。详见 [`accounts.md`](accounts.md) |
| 微信版本不匹配 | 已知支持 4.2.0.9 (270345) / 4.2.0.5 (270341) / 4.1.15.55 (270135) / 4.1.12.53 (269365)；用 `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/WeChat.app/Contents/Info.plist` 与 `:CFBundleVersion` 核对。其他版本需自行适配、用 `WECHAT_SUPPORTED_VERSION`/`WECHAT_SUPPORTED_BUILD` 覆盖或还原，**不要强装** |
| 图片/语音获取失败，或 `image_path` 检测失败 | 检查 系统设置 → 隐私与安全性 → App 数据 中是否允许 WeChat AI；拒绝授权会导致这些功能失败。修改微信时可能还需要「App 管理」授权 |
| 安装 Hook 后微信打不开 | 先完全退出微信，再用 App 的「设置 → Hook → 还原官方微信」或 `bash tools/manage_wechat.sh restore` 还原 |
| 发送不出去 / 一直排队 | 确认「R3 原生发送」开关已开；首次或微信重启后在本机微信手动发一条消息（语音再发一条语音）捕获句柄；bridge 启动 60 秒内 CdnManager 未就绪时先等待或用图片触发恢复 |
| 端口被占用（58080 / 27042） | `lsof -nP -iTCP:58080 -sTCP:LISTEN` 与 `lsof -nP -iTCP:27042 -sTCP:LISTEN` 查看占用进程；退出冲突 App，或在「设置 → OneBot」改端口后重启 bridge。27042 是 Gadget 注入端口，只允许一个微信实例 |
| 语音模型下载失败 | 确认已勾选同意、网络与代理可用、磁盘足够（模型合计约 528MB），然后重试；失败会自动降级文字，不影响文本回复。系统中文语音资源缺失时可在 系统设置 → 辅助功能 → 朗读内容 下载，或点「机器人 → 语音」的「下载中文语音资源」 |
| 从源码构建报 `swift: command not found` | 安装 Xcode 27 并执行 `sudo xcode-select -s /Applications/Xcode.app`；只装 CLT 不足以源码构建（Hook 安装只需要 CLT） |

> 换微信账号前不需要备份或重装 Hook；账号数据按微信账号自动归档。首次升级建议先备份
> `~/Library/Application Support/WeChatAI/`（至少旧 `chatbot.sqlite` 与 `media/`），
> 确认新账号数据正常后再自行清理旧文件。不要在 App 运行时手动移动 `accounts/` 下的目录。

## 6. 安全提醒

- 只在自己的设备与账号上使用；不要用于他人账号。
- 修改微信客户端会破坏官方签名，存在账号风控、封号与数据丢失风险；安装前先备份。
- 安装/还原 Hook 前都要完全退出微信；还原入口在「设置 → Hook」。
- 只从本仓库源码或你信任的发布者构建的 App 运行；不要使用来源不明的二进制。
