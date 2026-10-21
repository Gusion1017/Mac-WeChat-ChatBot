# 安装与启动（从 GitHub 获取）

> 本项目是 **macOS 原生 App + 微信 Hook**，不是双击即用的普通应用。
> GitHub 的「Download ZIP」默认只给**源码**，不含已编译的 App、bridge 二进制和 Frida Gadget。
> 非开发者请让发布者提供 **Releases 里的 App 压缩包**；只有源码时按「源码构建」操作。

## 1. 先确认环境

| 项目 | 要求 |
| --- | --- |
| 硬件 | Apple Silicon（arm64） |
| 系统 | macOS 26 或更高 |
| 微信 | 4.1.12.53 (269365) 或 4.1.15.55 (270135)，需已安装并登录 |
| 构建 | 仅源码方式需要：Xcode 27（含命令行工具） |

> 微信版本不在支持列表时，首次向导会提示不匹配；不要强行安装 Hook。

## 2. 方式 A：Releases 里的 App 压缩包（推荐给普通用户）

发布者在本地构建后，把 `WeChat AI.app` 压缩上传到 GitHub Releases。下载后：

1. 解压 zip，得到 `WeChat AI.app`。
2. 拖到 `~/Applications` 或 `/Applications`。
3. **右键 → 打开**（首次不要双击）。App 是 ad-hoc 签名、未做 Apple 公证，Gatekeeper 会拦截。
   如果仍提示“无法验证/已损坏”，在终端执行：

   ```bash
   xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
   open "$HOME/Applications/WeChat AI.app"
   ```

   或在「系统设置 → 隐私与安全性」里选择“仍要打开”。
4. 这是一个**菜单栏 App**（默认不显示 Dock 图标）：启动后看屏幕顶部菜单栏的图标，
   不是 Dock。
5. 首次启动向导（右上角可切换 **语言 / Language**：跟随系统 / 简体中文 / English）：
   检测微信 → 备份并安装 Gadget → 配置 AI → 启动机器人。
   - 安装 Gadget 前需要完全退出微信；
   - 会完整备份官方 App，可在设置里一键还原；
   - AI Key 存在 macOS Keychain，不写入 `config.json`。

> 如果发布者没有提供 Releases 压缩包，只能用方式 B。

## 3. 方式 B：源码 ZIP（需要 Xcode 27）

1. 在 GitHub 页面 **Code → Download ZIP**，解压（目录名通常是 `Mac-WeChat-ChatBot-main`）。
2. 打开「终端」，进入解压后的目录：

   ```bash
   cd ~/Downloads/Mac-WeChat-ChatBot-main   # 以实际解压目录为准
   ```

3. 依次执行（首次会下载 Go 1.25、Frida devkit 与 Gadget，约需数分钟和数 GB 磁盘）：

   ```bash
   bash scripts/fetch_gadget.sh      # 下载 Frida Gadget 17.8.0
   bash scripts/build_bridge.sh      # 构建 bridge/onebot（含 Go 测试）
   bash scripts/build_app.sh         # 生成 dist/WeChat AI.app
   bash scripts/install_app.sh       # 安装到 ~/Applications
   open "$HOME/Applications/WeChat AI.app"
   ```

4. 后续与方式 A 的第 4–5 步相同（菜单栏图标、首次向导、退出微信后安装 Hook）。

> 只想先看看界面、不碰微信：用 `devtools/` 的 Mock 联调，见
> [`devtools/README.md`](../devtools/README.md)。

## 4. 发布者：如何制作可下载的 App 压缩包

在已具备 Xcode 27 的机器上：

```bash
bash scripts/fetch_gadget.sh
bash scripts/build_bridge.sh
bash scripts/package_release.sh
```

脚本会构建 App、校验签名、打包并生成 SHA256；也可以直接 `make release`：

- `dist/WeChat-AI-<version>.zip`
- `dist/WeChat-AI-<version>.zip.sha256`

也可以手动执行：

```bash
bash scripts/build_app.sh
ditto -c -k --norsrc --keepParent "dist/WeChat AI.app" "dist/WeChat-AI-1.0.0.zip"
shasum -a 256 "dist/WeChat-AI-1.0.0.zip"
```

把 zip 与 `.sha256` 上传到 GitHub **Releases**，在说明里写清：

- 支持 Apple Silicon / macOS 26+ / 微信 4.1.12.53 或 4.1.15.55；
- App 为 ad-hoc 签名、未公证，首次需右键打开或移除 quarantine；
- 安装 Hook 会修改微信、存在账号风控与签名失效风险；
- 按 GPL-3.0 提供对应源码（仓库地址即可）。

## 5. 常见问题

| 现象 | 处理 |
| --- | --- |
| 双击提示“无法验证开发者” | 右键 → 打开；或 `xattr -dr com.apple.quarantine <App 路径>` |
| 打开后没有窗口 | 这是菜单栏 App，点顶部菜单栏图标；可在设置里开启 Dock 图标 |
| `swift: command not found` / 构建失败 | 安装 Xcode 27 并执行 `sudo xcode-select -s /Applications/Xcode.app` |
| 微信版本不匹配 | 只支持 4.1.12.53 / 4.1.15.55；其他版本需自行适配或还原 |
| 安装 Hook 后微信打不开 | 用 App 的「还原」或 `bash tools/manage_wechat.sh restore` |
| 发送不出去 | 确认 R3 开关与发送句柄；首次需在本机微信手动发一条消息 |

## 6. 安全提醒

- 只在自己的设备与账号上使用；不要用于他人账号。
- 修改微信客户端会破坏官方签名，存在账号风控、封号与数据丢失风险；安装前先备份。
- 只从本仓库源码或你信任的发布者构建的 App 运行；不要使用来源不明的二进制。
