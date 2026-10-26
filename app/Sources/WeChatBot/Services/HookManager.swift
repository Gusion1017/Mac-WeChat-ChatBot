import AppKit
import Foundation

// MARK: - Errors

enum HookError: LocalizedError {
    case resourcesMissing
    case installScriptMissing
    case gadgetPayloadMissing
    case versionConfigMissing(String)
    case commandLineToolsMissing
    case weChatNotInstalled(String)
    case weChatRunning
    case weChatNotRunning
    case gadgetNotInstalled
    case bridgeBinaryMissing
    case bridgeDirectoryMissing
    case imagePathUnavailable
    case missingToken
    case backupMissing
    case installFailed(String)
    case restoreFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing:
            return "未找到应用资源目录（bridge/hook/tools）；请通过 App bundle 或 WECHATAI_ROOT 运行"
        case .installScriptMissing:
            return "安装脚本缺失：tools/install_gadget.sh"
        case .gadgetPayloadMissing:
            return "Frida Gadget 文件缺失：hook/gadget/FridaGadget.dylib 或配置文件"
        case .versionConfigMissing(let path):
            return "Hook 版本文件未就绪：\(path)（等待 hook-port 产出对应微信版本的 JSON 偏移）"
        case .commandLineToolsMissing:
            return L("需要安装 Xcode Command Line Tools（提供 python3 与 otool）。请到首启向导或「设置 → Hook」点击安装，然后重试。")
        case .weChatNotInstalled(let path):
            return "未找到微信 App：\(path)"
        case .weChatRunning:
            return "微信正在运行，请先完全退出微信（含菜单栏图标）再安装"
        case .weChatNotRunning:
            return "微信未运行，请先登录微信后再启动机器人"
        case .gadgetNotInstalled:
            return "尚未安装 Frida Gadget，请先在总览页安装并重启微信"
        case .bridgeBinaryMissing:
            return "未找到 bridge/onebot 可执行文件（请先构建 bridge 或检查 App 资源）"
        case .bridgeDirectoryMissing:
            return "未找到 bridge 资源目录（onebot 从当前目录读取 script.js）"
        case .imagePathUnavailable:
            return "未找到微信媒体临时目录（xwechat_files/<账号>/temp）；请先登录微信，或在设置中填写 image_path"
        case .missingToken:
            return "OneBot token 为空，已拒绝以无鉴权方式启动 bridge"
        case .backupMissing:
            return "未找到微信官方备份，无法恢复"
        case .installFailed(let message):
            return "Gadget 安装失败：\(message)"
        case .restoreFailed(let message):
            return "微信恢复失败：\(message)"
        case .commandFailed(let message):
            return "命令执行失败：\(message)"
        }
    }
}

// MARK: - WeChat inspection

struct WeChatInstallation: Sendable {
    var appURL: URL
    var exists: Bool = false
    var version: String = ""
    var build: String = ""
    var executable: URL?
    var frameworkGadget: URL?

    static func inspect(path: String) -> WeChatInstallation {
        let expanded = (path as NSString).expandingTildeInPath
        let appURL = URL(fileURLWithPath: expanded, isDirectory: true)
        let fileManager = FileManager.default
        var installation = WeChatInstallation(appURL: appURL)
        installation.exists = fileManager.fileExists(atPath: appURL.path)
        guard installation.exists else { return installation }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: infoURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            installation.version = (plist["WeChatBundleVersion"] as? String)
                ?? (plist["CFBundleShortVersionString"] as? String)
                ?? ""
            installation.build = String(describing: plist["CFBundleVersion"] ?? "")
            if installation.build == "nil" { installation.build = "" }
            let executableName = (plist["CFBundleExecutable"] as? String) ?? "WeChat"
            installation.executable = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        }
        if installation.executable == nil {
            let fallback = appURL.appendingPathComponent("Contents/MacOS/WeChat")
            if fileManager.fileExists(atPath: fallback.path) { installation.executable = fallback }
        }
        installation.frameworkGadget = appURL.appendingPathComponent("Contents/Frameworks/FridaGadget.dylib")
        return installation
    }

    /// Verifies both the gadget file and the `LC_LOAD_DYLIB` entry (via `otool -L`).
    func hasGadgetLoadCommand() async -> Bool {
        guard let frameworkGadget,
              FileManager.default.fileExists(atPath: frameworkGadget.path) else { return false }
        guard let executable, FileManager.default.fileExists(atPath: executable.path) else { return false }
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/otool"),
            arguments: ["-L", executable.path]
        ) else { return false }
        return result.stdout.contains("FridaGadget.dylib")
    }
}

/// 支持 R3 原生发送（App 运行期配置）的微信版本。
///
/// 4.1.15.55 (270135) 与 4.2.0.x（4.2.0.5 / 270341、4.2.0.9 / 270345）共用同一 R3 发送链路；
/// 4.1.12 及更早版本保持 legacy 发送路径，不做任何覆盖。
enum NativeSendVersionSupport {
    static let versions: Set<String> = ["4.1.15.55", "4.2.0.5", "4.2.0.9"]
    static let builds: Set<String> = ["270135", "270341", "270345"]

    static func supports(version: String, build: String) -> Bool {
        versions.contains(version) || builds.contains(build)
    }
}

// MARK: - HookManager

/// Owns WeChat/gadget detection, install/restore script execution and the bridge child process.
/// All UI-visible state is published on the main actor via `onStatusChange`.
@MainActor
final class HookManager {
    var onStatusChange: ((HookStatus) -> Void)?
    var onLog: ((LogLevel, String) -> Void)?

    private(set) var status = HookStatus()
    private(set) var lastKnownBackupPath: String?
    private var wechatPath: String

    private var bridgeProcess: Process?
    private var bridgeMonitorTask: Task<Void, Never>?
    /// Incremented on every start/stop; stale monitor callbacks from a terminated bridge
    /// (rapid stop/restart, QA kill/restart) are ignored instead of clobbering new status.
    private var bridgeGeneration = 0

    init(wechatPath: String = "/Applications/WeChat.app") {
        self.wechatPath = wechatPath
    }

    func configure(wechatPath: String) {
        self.wechatPath = wechatPath
    }

    func currentStatus() -> HookStatus { status }

    /// Reads WeChat's `Info.plist` metadata off the main actor. This is disk I/O that
    /// used to run synchronously inside `refresh()`/`startBridge()` on the UI thread.
    private func inspectInstallation() async -> WeChatInstallation {
        let path = wechatPath
        return await Task.detached(priority: .utility) {
            WeChatInstallation.inspect(path: path)
        }.value
    }

    // MARK: Detection

    @discardableResult
    func refresh() async -> HookStatus {
        let commandLineTools = await CommandLineTools.status()
        let installation = await inspectInstallation()
        var updated = status
        updated.wechatVersion = installation.version
        updated.wechatBuild = installation.build
        updated.wechatRunning = Self.isWeChatRunning()

        // CLT 缺失时 /usr/bin/otool、/usr/bin/python3 只是 xcode-select 的 shim：
        // 直接执行会触发系统安装弹窗，且 manage_wechat.sh status 也会透传失败。
        // 因此跳过这两处探测，保留可行动引导，避免启动时惊扰用户。
        if commandLineTools.isReady {
            var gadgetInstalled = false
            if installation.exists {
                gadgetInstalled = await installation.hasGadgetLoadCommand()
            }
            updated.gadgetInstalled = gadgetInstalled
        }

        let versionConfig = AppResources.versionConfig(
            version: installation.version,
            explicitPath: status.versionConfigFile
        )
        updated.versionConfigFile = versionConfig?.path
            ?? AppResources.expectedVersionConfigPath(version: installation.version)
        updated.matchedVersion = versionConfig != nil

        // Optional: merge richer state from manage_wechat.sh (signature, backup path).
        if commandLineTools.isReady, let scriptStatus = await runManageStatus() {
            lastKnownBackupPath = scriptStatus.backupPath
            if scriptStatus.gadgetInstalled { updated.gadgetInstalled = true }
            if updated.wechatVersion.isEmpty { updated.wechatVersion = scriptStatus.version }
            if updated.wechatBuild.isEmpty { updated.wechatBuild = scriptStatus.build }
            if !updated.versionConfigFile.isEmpty, scriptStatus.versionConfigFile != nil {
                updated.versionConfigFile = scriptStatus.versionConfigFile!
            }
        }

        if !commandLineTools.isReady {
            updated.state = .failed
            updated.detail = "需要安装 Xcode Command Line Tools 才能检测 Hook"
        } else if !installation.exists {
            updated.state = .notInstalled
            updated.detail = "未找到微信：\(installation.appURL.path)"
        } else if !updated.gadgetInstalled {
            updated.state = .notInstalled
            updated.detail = "尚未安装 Frida Gadget"
        } else if !updated.wechatRunning {
            updated.state = .wechatNotRunning
            updated.detail = "微信未运行"
        } else if updated.bridgeRunning {
            updated.gatewayConnected = status.gatewayConnected
            if updated.gatewayConnected {
                updated.state = .connected
                updated.detail = "已连接微信"
            } else {
                updated.state = .bridgeStarting
                updated.detail = "bridge 运行中，等待事件连接"
            }
        } else {
            updated.state = .installed
            updated.detail = ""
        }
        if commandLineTools.isReady, !updated.matchedVersion, installation.exists, updated.gadgetInstalled {
            updated.detail = "Hook 版本文件未就绪：\(updated.versionConfigFile)"
        }
        publish(updated)
        return updated
    }

    /// Called by the runtime when the OneBot WebSocket connects/disconnects.
    func setGatewayConnected(_ connected: Bool, detail: String? = nil) {
        var updated = status
        updated.gatewayConnected = connected
        if connected {
            updated.state = .connected
            updated.detail = detail ?? "已连接微信"
        } else if updated.bridgeRunning {
            updated.state = .bridgeStarting
            updated.detail = detail ?? "事件连接已断开，bridge 仍在运行"
        } else if updated.gadgetInstalled && updated.wechatRunning {
            updated.state = .installed
            updated.detail = detail ?? "事件连接已断开"
        }
        publish(updated)
    }

    private func publish(_ newStatus: HookStatus) {
        status = newStatus
        onStatusChange?(newStatus)
    }

    static func isWeChatRunning() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat").isEmpty {
            return true
        }
        return NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == "WeChat" || $0.executableURL?.lastPathComponent == "WeChat"
        }
    }

    // MARK: Install / restore

    /// Runs `tools/install_gadget.sh` with the progress protocol from the Lead:
    /// `[stage]0.52|message` or JSON `{"progress":0.52,"stage":"..."}`.
    @discardableResult
    func installGadget(
        explicitVersionConfigPath: String = "",
        onProgress: ((Double, String) -> Void)? = nil
    ) async throws -> HookStatus {
        onProgress?(0.0, "检查安装环境")
        guard await CommandLineTools.status().isReady else {
            var missing = status
            missing.state = .failed
            missing.detail = "需要安装 Xcode Command Line Tools 才能安装 Hook"
            publish(missing)
            throw HookError.commandLineToolsMissing
        }
        guard AppResources.root != nil else { throw HookError.resourcesMissing }
        guard let script = AppResources.installScript else { throw HookError.installScriptMissing }
        guard let bridgeRoot = AppResources.root else { throw HookError.resourcesMissing }

        let installation = await inspectInstallation()
        guard installation.exists else { throw HookError.weChatNotInstalled(wechatPath) }
        guard !Self.isWeChatRunning() else { throw HookError.weChatRunning }
        guard let gadget = AppResources.gadgetDylib, let gadgetConfig = AppResources.gadgetConfig else {
            throw HookError.gadgetPayloadMissing
        }
        // 安装阶段只需要版本文件存在；R3 发送开关在 startBridge 时再合并。
        guard let versionConfig = AppResources.versionConfig(
            version: installation.version,
            explicitPath: explicitVersionConfigPath
        ) else {
            let expected = AppResources.expectedVersionConfigPath(
                version: installation.version,
                explicitPath: explicitVersionConfigPath
            )
            throw HookError.versionConfigMissing(expected)
        }

        var updated = status
        updated.wechatVersion = installation.version
        updated.wechatBuild = installation.build
        updated.wechatRunning = false
        updated.versionConfigFile = versionConfig.path
        updated.matchedVersion = true
        updated.state = .bridgeStarting
        updated.detail = "正在安装 Frida Gadget…"
        publish(updated)

        try FileManager.default.createDirectory(at: AppPaths.backupsDirectory, withIntermediateDirectories: true)
        let arguments = [
            script.path,
            "--wechat-path", wechatPath,
            "--gadget", gadget.path,
            "--config", gadgetConfig.path,
            "--backup-dir", AppPaths.backupsDirectory.path,
            "--json"
        ]
        onLog?(.info, "开始安装 Gadget：\(script.lastPathComponent)（备份到 \(AppPaths.backupsDirectory.path)）")
        let handle = ProcessRunner.launch(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: arguments,
            currentDirectory: bridgeRoot
        )

        var exitCode: Int32 = -1
        var failureMessage: String?
        var sawOK = false
        do {
            for try await event in handle.events {
                switch event {
                case .line(let line, .stdout):
                    if line == "OK" {
                        sawOK = true
                    } else if line.hasPrefix("ERROR:") {
                        failureMessage = String(line.dropFirst("ERROR:".count))
                            .trimmingCharacters(in: .whitespaces)
                    } else if let stage = Self.parseProgressLine(line) {
                        onProgress?(stage.progress, stage.message)
                    } else if !line.isEmpty {
                        onLog?(.debug, "install: \(line)")
                    }
                case .line(let line, .stderr):
                    if line.contains("ERROR:") && failureMessage == nil {
                        failureMessage = line
                    }
                    if line.contains("[wechat-hook]") || line.contains("ERROR") {
                        onLog?(.debug, "install(stderr): \(Self.redact(line))")
                    }
                case .terminated(let code):
                    exitCode = code
                }
            }
        } catch {
            throw HookError.installFailed(error.localizedDescription)
        }

        guard exitCode == 0, sawOK, failureMessage == nil else {
            let message = failureMessage ?? "脚本退出码 \(exitCode)"
            var failed = status
            failed.state = .failed
            failed.detail = message
            publish(failed)
            throw HookError.installFailed(message)
        }

        onProgress?(0.98, "刷新安装状态")
        let refreshed = await refresh()
        onProgress?(1.0, "Gadget 安装完成，重启微信后生效")
        onLog?(.info, "Gadget 安装完成，微信版本 \(refreshed.wechatVersion) (\(refreshed.wechatBuild))")
        return refreshed
    }

    @discardableResult
    func restoreBackup() async throws -> HookStatus {
        guard let script = AppResources.manageScript else {
            throw HookError.commandFailed("缺少 tools/manage_wechat.sh")
        }
        guard AppResources.root != nil else { throw HookError.resourcesMissing }
        let installation = await inspectInstallation()
        guard installation.exists else { throw HookError.weChatNotInstalled(wechatPath) }
        guard !Self.isWeChatRunning() else { throw HookError.weChatRunning }

        onLog?(.info, "开始从官方备份恢复微信…")
        let handle = ProcessRunner.launch(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path, "restore", "--app", wechatPath,
                        "--backup-dir", AppPaths.backupsDirectory.path],
            currentDirectory: AppResources.root
        )
        var exitCode: Int32 = -1
        var output = ""
        var failure: String?
        for try await event in handle.events {
            switch event {
            case .line(let line, .stdout):
                output += line + "\n"
                onLog?(.debug, "restore: \(line)")
            case .line(let line, .stderr):
                output += line + "\n"
                if line.contains("ERROR") { failure = line }
                onLog?(.debug, "restore(stderr): \(line)")
            case .terminated(let code):
                exitCode = code
            }
        }
        guard exitCode == 0, failure == nil else {
            throw HookError.restoreFailed(failure ?? String(output.suffix(300)))
        }
        onLog?(.info, "微信已从官方备份恢复")
        return await refresh()
    }

    // MARK: Bridge lifecycle

    /// 只接受与当前 `image_path` 中账号目录一致的 selfID。
    ///
    /// 历史版本/测试事件曾把 `onebot.self_id` 污染成别的值（例如 `wxid_self`），
    /// 启动 bridge 时又通过 `-self_id` 覆盖真实账号，导致 bridge 的 get_login_info
    /// 也返回错误账号，拍一拍目标比对与自消息判定全部失效。
    /// 路径形如 `.../xwechat_files/<wxid>_xxxx/temp`；无法从路径判断时保留原值。
    nonisolated static func validatedSelfID(_ raw: String, imagePath: URL) -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return "" }
        let components = imagePath.pathComponents
        guard let index = components.firstIndex(of: "xwechat_files"),
              components.indices.contains(index + 1) else {
            return id
        }
        let accountDir = components[index + 1]
        // 目录名形如 `<wxid>_<四位后缀>`；wxid 自身可能含一个 `_`，因此去掉最后一段。
        let parts = accountDir.split(separator: "_")
        let accountID = parts.count > 1
            ? parts.dropLast().joined(separator: "_")
            : accountDir
        guard !accountID.isEmpty else { return id }
        return accountID.caseInsensitiveCompare(id) == .orderedSame ? id : ""
    }

    func startBridge(
        host: String,
        port: Int,
        token: String,
        gadgetPort: Int,
        explicitVersionConfigPath: String,
        explicitImagePath: String,
        selfID: String = "",
        configOverrides: [String: String] = [:]
    ) async throws {
        guard bridgeProcess == nil else { return }
        guard let binary = AppResources.bridgeBinary else { throw HookError.bridgeBinaryMissing }
        guard let bridgeDirectory = AppResources.bridgeDirectory else { throw HookError.bridgeDirectoryMissing }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HookError.missingToken }

        let installation = await inspectInstallation()
        guard installation.exists else { throw HookError.weChatNotInstalled(wechatPath) }
        guard Self.isWeChatRunning() else { throw HookError.weChatNotRunning }
        guard await CommandLineTools.status().isReady else {
            var updated = status
            updated.state = .failed
            updated.detail = "需要安装 Xcode Command Line Tools 才能启动 Hook"
            publish(updated)
            throw HookError.commandLineToolsMissing
        }
        guard await installation.hasGadgetLoadCommand() else { throw HookError.gadgetNotInstalled }

        guard let versionConfig = AppResources.materializedVersionConfig(
            version: installation.version,
            build: installation.build,
            explicitPath: explicitVersionConfigPath,
            overrides: configOverrides
        ) else {
            let expected = AppResources.expectedVersionConfigPath(
                version: installation.version,
                explicitPath: explicitVersionConfigPath
            )
            var updated = status
            updated.state = .failed
            updated.detail = "Hook 版本文件未就绪：\(expected)"
            publish(updated)
            throw HookError.versionConfigMissing(expected)
        }

        let imagePath: URL
        if !explicitImagePath.isEmpty {
            imagePath = URL(fileURLWithPath: (explicitImagePath as NSString).expandingTildeInPath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: imagePath.path) else {
                throw HookError.imagePathUnavailable
            }
        } else if let detected = AppResources.imageDirectory() {
            imagePath = detected
        } else {
            throw HookError.imagePathUnavailable
        }

        // bridge 的 cwd 必须保持在 bundle 内的 bridge/（它从这里读 script.js），
        // 因此日志路径必须显式指到 ~/Library/Logs 下；否则写进 app bundle 会
        // 破坏 ad-hoc 签名，导致下次启动被系统直接杀掉。
        try? FileManager.default.createDirectory(at: AppPaths.bridgeLogDirectory, withIntermediateDirectories: true)

        var arguments = [
            "-type=gadget",
            "-gadget_addr=127.0.0.1:\(gadgetPort)",
            "-wechat_conf=\(versionConfig.path)",
            "-receive_host=\(host):\(port)",
            "-token=\(token)",
            "-conn_type=websocket",
            "-image_path=\(imagePath.path)",
            // 入站图片解密后的落盘目录（App 传入，bridge 保证写入不越界）。
            "-media_dir=\(AppPaths.mediaDirectory.path)",
            "-log_file=\(AppPaths.bridgeLogFile.path)",
            // 上游默认 1000ms：既延迟入站事件转发，也延迟发送任务。
            // 本项目已有冷却/每分钟限流，这里收紧到 100ms 以降低端到端延迟。
            "-send_interval=100"
        ]
        let trimmedSelfID = Self.validatedSelfID(selfID, imagePath: imagePath)
        if !trimmedSelfID.isEmpty {
            // 多账号目录时 image_path 推导可能选错账号；App 已知账号时直接告诉 bridge，
            // 用于判定自消息方向与 target_id。
            arguments.append("-self_id=\(trimmedSelfID)")
        } else if !selfID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 历史值/测试事件可能把 self_id 污染成别的账号；与当前 image_path 不一致时
            // 不要传给 bridge，让它从账号目录重新推导，再由 get_login_info 校正 App。
            onLog?(.warning, "已忽略与 image_path 账号目录不一致的 self_id，bridge 将按目录重新推导")
        }

        let handle = ProcessRunner.launch(
            executable: binary,
            arguments: arguments,
            currentDirectory: bridgeDirectory
        )
        bridgeGeneration += 1
        let generation = bridgeGeneration
        bridgeProcess = handle.process

        var updated = status
        updated.bridgeRunning = true
        updated.bridgePID = handle.process.processIdentifier
        updated.gatewayConnected = false
        updated.state = .bridgeStarting
        updated.detail = "bridge 启动中…"
        updated.versionConfigFile = versionConfig.path
        updated.matchedVersion = true
        publish(updated)
        onLog?(.info, "bridge 启动：PID \(updated.bridgePID)，WS \(host):\(port)，配置 \(versionConfig.lastPathComponent)")

        bridgeMonitorTask?.cancel()
        // Consume bridge stdout on a background task: ANSI stripping, redaction, level
        // classification and log emission all happen off the main actor. Only genuine
        // status transitions (rare) hop back to the main actor, so a bridge emitting
        // 3–10 lines/second no longer causes per-line main-thread work / UI churn.
        let events = handle.events
        bridgeMonitorTask = Task.detached(priority: .utility) { [weak self] in
            var lineCount = 0
            do {
                for try await event in events {
                    if Task.isCancelled { return }
                    switch event {
                    case .line(let rawLine, let kind):
                        lineCount += 1
                        guard let line = HookManager.sanitizeBridgeLine(rawLine, token: token) else { continue }
                        let level = HookManager.bridgeLineLevel(line, kind: kind)
                        if lineCount <= 400 || level == .error {
                            LogPipeline.shared.emit(level, "Hook", "bridge: \(line)")
                        }
                        if let effect = HookManager.bridgeLineEffect(line) {
                            await self?.applyBridgeLineEffect(effect, generation: generation)
                        }
                    case .terminated(let code):
                        await self?.handleBridgeTermination(code, generation: generation)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self?.handleBridgeTermination(-1, error: error.localizedDescription, generation: generation)
            }
        }
    }

    func stopBridge() {
        bridgeGeneration += 1
        bridgeMonitorTask?.cancel()
        bridgeMonitorTask = nil
        if let process = bridgeProcess {
            if process.isRunning { process.terminate() }
            onLog?(.info, "已请求停止 bridge（PID \(process.processIdentifier)）")
        }
        bridgeProcess = nil
        var updated = status
        updated.bridgeRunning = false
        updated.bridgePID = 0
        updated.gatewayConnected = false
        if updated.gadgetInstalled && updated.wechatRunning {
            updated.state = .installed
            updated.detail = ""
        }
        publish(updated)
    }

    func shutdown() {
        stopBridge()
    }

    // MARK: Bridge output classification (off-main)

    /// Small value describing the status change a bridge log line implies.
    /// Built off the main actor, applied on it — keeps per-line work off the UI thread.
    private struct BridgeLineEffect: Sendable {
        enum DetailUpdate: Sendable {
            case set(String)
            case setIfEmpty(String)
        }

        var detail: DetailUpdate?
        var state: HookState?
        var r3Active: Bool?
        var r3Seeded: Bool?
        var r3Queued: Int?

        var isEmpty: Bool {
            detail == nil && state == nil && r3Active == nil && r3Seeded == nil && r3Queued == nil
        }
    }

    /// Strips ANSI escapes and redacts the OneBot token. Returns `nil` for empty lines.
    nonisolated private static func sanitizeBridgeLine(_ rawLine: String, token: String) -> String? {
        let line = redact(AnsiText.strip(rawLine), token: token)
        return line.isEmpty ? nil : line
    }

    nonisolated private static func bridgeLineLevel(_ line: String, kind: ProcessStreamKind) -> LogLevel {
        if line.contains("panic") || line.contains("Fatal") || line.contains("ERROR") { return .error }
        return kind == .stderr ? .warning : .debug
    }

    nonisolated private static func bridgeLineEffect(_ line: String) -> BridgeLineEffect? {
        var effect = BridgeLineEffect()
        if line.contains("HTTP 服务启动在") || line.contains("HTTP 服务") {
            effect.detail = .set("bridge HTTP 已启动，等待事件连接")
        }
        if line.contains("FridaGadget") || (line.contains("gadget") && (line.contains("connect") || line.contains("连接"))) {
            effect.state = .bridgeStarting
            effect.detail = .set("Gadget 连接中…")
        }
        if line.contains("panic") || line.contains("服务启动失败") || line.contains("Fatal") {
            effect.state = .failed
            effect.detail = .set(line)
        }
        // 4.1.15.55 / 4.2.0.x R3 原生发送状态（来自 hook/script.js 的 console 日志 / bridge 日志）
        if line.contains("R3 原生发送模式") || line.contains("R3: init 完成") {
            effect.r3Active = true
            effect.detail = .setIfEmpty("R3 原生发送已启用，等待发送句柄")
        }
        // bridge/App 重启时句柄由 ~/Library/Caches/WeChatAI/r3-seed.json 恢复：
        // JS 打印「从 bridge 恢复发送句柄」，bridge 打印「R3 发送句柄恢复（bridge 重启）」。
        // 这两条日志过去没有解析，导致句柄其实已就绪、界面却仍提示「R3 等待信号」，
        // 用户会误以为每次重启都要手动发一条消息（2026-10-21 修复）。
        if line.contains("从 bridge 恢复发送句柄") || line.contains("R3 发送句柄恢复") {
            effect.r3Active = true
            effect.r3Seeded = true
            effect.r3Queued = 0
            effect.detail = .set("R3 发送句柄已从缓存恢复")
        }
        // 微信重启后 PID 变化，持久化句柄会过期；此时才需要人工发一条消息重新捕获。
        if line.contains("R3 发送句柄记录已过期") || line.contains("R3 发送句柄已失效") {
            effect.r3Active = true
            effect.r3Seeded = false
            effect.detail = .set("R3 等待信号：微信重启后请在本机微信手动发一条消息")
        }
        if line.contains("R3: slot13 捕获 newsendmsg 闭包") || line.contains("R3: 捕获 newsendmsg 闭包") {
            effect.r3Active = true
            effect.r3Seeded = true
            effect.r3Queued = 0
            effect.detail = .set("R3 发送句柄已就绪")
        }
        if line.contains("尚无发送句柄") || line.contains("尚无真实 newsendmsg 闭包") {
            effect.r3Active = true
            effect.r3Seeded = false
            effect.detail = .set("R3 等待信号：微信重启后请在本机微信手动发一条消息以捕获发送句柄")
        }
        if line.contains("消息已排队") {
            effect.r3Active = true
            effect.r3Seeded = false
            effect.detail = .setIfEmpty("R3 等待信号：微信重启后请在本机微信手动发一条消息")
        }
        return effect.isEmpty ? nil : effect
    }

    @MainActor
    private func applyBridgeLineEffect(_ effect: BridgeLineEffect, generation: Int) {
        guard bridgeGeneration == generation else { return }
        var updated = status
        if let detail = effect.detail {
            switch detail {
            case .set(let value): updated.detail = value
            case .setIfEmpty(let value): if updated.detail.isEmpty { updated.detail = value }
            }
        }
        if let state = effect.state { updated.state = state }
        if let active = effect.r3Active { updated.r3Active = active }
        if let seeded = effect.r3Seeded { updated.r3Seeded = seeded }
        if let queued = effect.r3Queued { updated.r3Queued = queued }
        if updated != status { publish(updated) }
    }

    private func handleBridgeTermination(_ code: Int32, error: String? = nil, generation: Int) {
        guard bridgeGeneration == generation else { return }
        guard bridgeProcess != nil || status.bridgeRunning else { return }
        bridgeProcess = nil
        bridgeMonitorTask = nil
        var updated = status
        updated.bridgeRunning = false
        updated.bridgePID = 0
        updated.gatewayConnected = false
        if code == 0 {
            updated.state = updated.gadgetInstalled ? .installed : .notInstalled
            updated.detail = "bridge 已退出"
        } else {
            updated.state = .failed
            updated.detail = "bridge 异常退出（\(error ?? "退出码 \(code)")）"
        }
        publish(updated)
        onLog?(code == 0 ? .info : .error, "bridge 已退出：\(updated.detail)")
        // Keep the token for potential restart; token is not secret to UI (local auth).
    }

    // MARK: Script helpers

    private struct ScriptStatus {
        var version: String = ""
        var build: String = ""
        var gadgetInstalled: Bool = false
        var backupPath: String?
        var versionConfigFile: String?
    }

    private func runManageStatus() async -> ScriptStatus? {
        guard let script = AppResources.manageScript, let root = AppResources.root else { return nil }
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path, "status", "--app", wechatPath,
                        "--backup-dir", AppPaths.backupsDirectory.path],
            currentDirectory: root
        ), result.status == 0 else { return nil }
        guard let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var parsed = ScriptStatus()
        parsed.version = object["version"] as? String ?? ""
        parsed.build = object["build"] as? String ?? ""
        parsed.gadgetInstalled = object["gadgetInstalled"] as? Bool ?? false
        parsed.backupPath = object["backupPath"] as? String
        return parsed
    }

    private static func parseProgressLine(_ line: String) -> (progress: Double, message: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[stage]") {
            let body = trimmed.dropFirst("[stage]".count)
            guard let separator = body.firstIndex(of: "|") else { return nil }
            let progressText = body[body.startIndex..<separator]
            let message = String(body[body.index(after: separator)...])
            if let progress = Double(progressText) {
                return (min(max(progress, 0), 1), message)
            }
            return nil
        }
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let progress = (object["progress"] as? NSNumber)?.doubleValue {
            let message = object["stage"] as? String ?? ""
            return (min(max(progress, 0), 1), message)
        }
        return nil
    }

    nonisolated private static func redact(_ line: String, token: String = "") -> String {
        var redacted = line
        if !token.isEmpty {
            redacted = redacted.replacingOccurrences(of: token, with: "<redacted-token>")
        }
        if redacted.contains("OnebotToken") || redacted.lowercased().contains("token") {
            let components = redacted.split(separator: " ", maxSplits: 1)
            if components.count == 2 { return "\(components[0]) <redacted>" }
        }
        return redacted
    }
}
