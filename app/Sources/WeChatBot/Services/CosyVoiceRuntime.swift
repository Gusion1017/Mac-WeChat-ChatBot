import AppKit
import Darwin
import Foundation

// MARK: - 安装位置 / 脚本定位

/// CosyVoice3 运行环境在本机的位置约定（与 `cosyvoice-runtime` 队友的脚本一致）。
///
/// 解析顺序：
/// 1. 环境变量 `WECHATAI_COSYVOICE_HOME`（自定义安装位置）；
/// 2. 仓库检出：`<repo>/_local/cosyvoice`（开发态，脚本/模型都在仓库里）；
/// 3. 打包 App：`~/Library/Application Support/WeChatAI/cosyvoice`。
///
/// 打包后的 `.app` 里没有 `scripts/`，此时必须用
/// `WECHATAI_COSYVOICE_SCRIPT` / `WECHATAI_COSYVOICE_INSTALL_SCRIPT` 指定脚本，
/// 或在源码仓库里运行（见文档「已知限制」）。
enum CosyVoiceInstallation {
    static let homeEnvironmentKey = "WECHATAI_COSYVOICE_HOME"
    static let runScriptEnvironmentKey = "WECHATAI_COSYVOICE_SCRIPT"
    static let installScriptEnvironmentKey = "WECHATAI_COSYVOICE_INSTALL_SCRIPT"

    static let markerFileName = ".installed"
    static let venvDirectoryName = "venv"
    static let modelsDirectoryName = "models"
    static let voicesDirectoryName = "voices"

    /// 模型目录候选名（服务脚本默认 `Fun-CosyVoice3-0.5B-2512`）。
    static let modelDirectoryNames = [
        "Fun-CosyVoice3-0.5B-2512",
        "Fun-CosyVoice3-0.5B",
    ]

    /// 判断是否为源码仓库根（打包后的 `Contents/Resources` 不算）。
    nonisolated static var repositoryRoot: URL? {
        guard let root = AppResources.root else { return nil }
        let fileManager = FileManager.default
        let markers = ["app/Package.swift", "scripts", "_local"]
        for marker in markers where fileManager.fileExists(
            atPath: root.appendingPathComponent(marker).path) {
            return root
        }
        return nil
    }

    /// 默认安装根目录（未设置环境变量时）。
    nonisolated static var defaultHome: URL {
        if let root = repositoryRoot {
            return root.appendingPathComponent("_local/cosyvoice", isDirectory: true)
        }
        return AppPaths.supportDirectory.appendingPathComponent("cosyvoice", isDirectory: true)
    }

    nonisolated static var home: URL {
        if let raw = ProcessInfo.processInfo.environment[homeEnvironmentKey],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return defaultHome
    }

    nonisolated static func venvPythonURL(home: URL? = nil) -> URL {
        (home ?? Self.home)
            .appendingPathComponent(venvDirectoryName, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python")
    }

    /// 实际存在的模型目录；未安装时回退默认名（给脚本传参用）。
    nonisolated static func modelDirectory(home: URL? = nil) -> URL {
        let modelsRoot = (home ?? Self.home)
            .appendingPathComponent(modelsDirectoryName, isDirectory: true)
        let fileManager = FileManager.default
        for name in modelDirectoryNames {
            let candidate = modelsRoot.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        // 用户自定义目录名：取第一个包含 config/yaml 的子目录。
        if let entries = try? fileManager.contentsOfDirectory(
            at: modelsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                guard isDirectory else { continue }
                if fileManager.fileExists(
                    atPath: entry.appendingPathComponent("llm.pt").path) {
                    return entry
                }
            }
        }
        return modelsRoot.appendingPathComponent(modelDirectoryNames[0], isDirectory: true)
    }

    nonisolated static func voicesDirectory(home: URL? = nil) -> URL {
        (home ?? Self.home).appendingPathComponent(voicesDirectoryName, isDirectory: true)
    }

    nonisolated static func markerURL(home: URL? = nil) -> URL {
        (home ?? Self.home).appendingPathComponent(markerFileName)
    }

    /// 已安装 = 标记文件 + venv python 可执行 + 模型关键权重存在。
    ///
    /// 只信标记文件会在用户手动删模型后误判；只查文件又会在安装进行中被误判，
    /// 因此标记文件由安装脚本在**全部成功**后才写，这里再补一次关键文件校验。
    nonisolated static func isInstalled(home: URL? = nil) -> Bool {
        let home = home ?? Self.home
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: markerURL(home: home).path) else { return false }
        guard fileManager.isExecutableFile(atPath: venvPythonURL(home: home).path) else {
            return false
        }
        let modelDirectory = modelDirectory(home: home)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        // 关键权重：llm.pt 是最大件，另外至少要有 flow/hift 之一与 tokenizer。
        let hasLLM = fileManager.fileExists(
            atPath: modelDirectory.appendingPathComponent("llm.pt").path)
        guard hasLLM else { return false }
        let contents = (try? fileManager.contentsOfDirectory(
            at: modelDirectory, includingPropertiesForKeys: nil)) ?? []
        let names = Set(contents.map(\.lastPathComponent))
        let hasFlow = names.contains("flow.pt")
            || names.contains("flow.onnx")
            || names.contains { $0.hasPrefix("flow") && $0.hasSuffix(".pt") }
        let hasHift = names.contains("hift.pt")
            || names.contains { $0.hasPrefix("hift") && $0.hasSuffix(".pt") }
        let hasTokenizer = names.contains("speech_tokenizer_v3.onnx")
            || names.contains { $0.hasPrefix("speech_tokenizer") }
        let hasSpeaker = names.contains("campplus.onnx")
        let hasConfig = names.contains("cosyvoice3.yaml")
            || names.contains { $0.hasPrefix("cosyvoice") && $0.hasSuffix(".yaml") }
        return hasFlow && hasHift && hasTokenizer && hasSpeaker && hasConfig
    }

    /// `scripts/run_cosyvoice.sh`：环境变量 → 仓库 → 安装目录下的 scripts。
    nonisolated static var runScript: URL? {
        scriptURL(environmentKey: runScriptEnvironmentKey, name: "run_cosyvoice.sh")
    }

    /// `scripts/install_cosyvoice.sh`：环境变量 → 仓库 → 安装目录下的 scripts。
    nonisolated static var installScript: URL? {
        scriptURL(environmentKey: installScriptEnvironmentKey, name: "install_cosyvoice.sh")
    }

    private nonisolated static func scriptURL(
        environmentKey: String,
        name: String
    ) -> URL? {
        let fileManager = FileManager.default
        if let raw = ProcessInfo.processInfo.environment[environmentKey],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        var candidates: [URL] = []
        // 打包版：`build_app.sh` 把 scripts/ 与 devtools/cosyvoice/ 一起复制到
        // `Contents/Resources/cosyvoice/`，脚本与 server.py 同目录。
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("cosyvoice/\(name)"))
        }
        // 资源根（开发态是仓库根）下的 cosyvoice/。
        if let root = AppResources.root {
            candidates.append(root.appendingPathComponent("cosyvoice/\(name)"))
        }
        // 源码仓库：scripts/<name>。
        if let root = repositoryRoot {
            candidates.append(root.appendingPathComponent("scripts/\(name)"))
            candidates.append(root.appendingPathComponent("cosyvoice/\(name)"))
        }
        // 自定义安装目录内附带的脚本（可选）。
        candidates.append(home.appendingPathComponent("scripts/\(name)"))
        candidates.append(home.appendingPathComponent(name))
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// CosyVoice 辅助脚本目录（`server.py` / `patch_repo.py` 所在）。
    ///
    /// 打包版这些文件与 install/run 脚本同在 `Resources/cosyvoice/`；源码仓库在
    /// `devtools/cosyvoice/`。通过 `COSYVOICE_SERVER_DIR` 传给脚本，两边布局都能找到。
    nonisolated static var serverDirectory: URL? {
        let fileManager = FileManager.default
        let environmentKey = "COSYVOICE_SERVER_DIR"
        if let raw = ProcessInfo.processInfo.environment[environmentKey],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        var candidates: [URL] = []
        for script in [runScript, installScript].compactMap({ $0 }) {
            candidates.append(script.deletingLastPathComponent())
        }
        if let root = repositoryRoot {
            candidates.append(root.appendingPathComponent("devtools/cosyvoice", isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("cosyvoice", isDirectory: true))
        }
        for candidate in candidates {
            if fileManager.fileExists(
                atPath: candidate.appendingPathComponent("server.py").path) {
                return candidate
            }
        }
        // 没有 server.py 时仍返回脚本目录（给脚本一个可用的相对路径）。
        return candidates.first
    }

    /// 启动/安装脚本的环境变量（脚本自身也支持同名 env，双保险）。
    nonisolated static func scriptEnvironment(
        home: URL? = nil,
        endpoint: URL? = nil
    ) -> [String: String] {
        let home = home ?? Self.home
        var environment: [String: String] = [
            "PYTHONUNBUFFERED": "1",
            "COSYVOICE_HOME": home.path,
            "COSYVOICE_LOCAL_DIR": home.path,
            "COSYVOICE_VENV": home.appendingPathComponent(venvDirectoryName).path,
            "COSYVOICE_MODEL_DIR": modelDirectory(home: home).path,
            "COSYVOICE_REFS": voicesDirectory(home: home).path,
        ]
        if let serverDirectory {
            environment["COSYVOICE_SERVER_DIR"] = serverDirectory.path
        }
        if let endpoint {
            if let host = endpoint.host { environment["COSYVOICE_HOST"] = host }
            if let port = endpoint.port { environment["COSYVOICE_PORT"] = String(port) }
        }
        return environment
    }

    /// 删除安装目录前的安全检查：只允许删 `_local/cosyvoice` 或 Application Support 下的
    /// `cosyvoice`，拒绝 `/`、家目录、仓库根等危险路径。
    nonisolated static func isSafeToDelete(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path != "/", path != NSHomeDirectory() else { return false }
        var allowedRoots = [
            defaultHome.standardizedFileURL.path,
            AppPaths.supportDirectory.appendingPathComponent("cosyvoice").standardizedFileURL.path,
        ]
        if let repo = repositoryRoot {
            allowedRoots.append(
                repo.appendingPathComponent("_local/cosyvoice").standardizedFileURL.path)
        }
        return allowedRoots.contains(path)
    }
}

// MARK: - 运行状态快照

/// `CosyVoiceRuntime.snapshot()` 的返回值：设置页轮询展示用（不可变值）。
struct CosyVoiceRuntimeSnapshot: Sendable, Equatable {
    var state: CosyVoiceServiceState
    var endpoint: URL?
    var pid: Int32?
    /// 服务进程是否由本 App 启动（外部分进程只展示状态，停止按钮不杀）。
    var ownsProcess: Bool
    /// 安装目录是否完整。
    var installed: Bool
    var logTail: [String]
    var updatedAt: Date

    static let initial = CosyVoiceRuntimeSnapshot(
        state: .unknown,
        endpoint: nil,
        pid: nil,
        ownsProcess: false,
        installed: false,
        logTail: [],
        updatedAt: Date()
    )
}

// MARK: - 进程抽象（可注入 fake 做单测）

protocol CosyVoiceLaunchedProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func terminate()
    func forceKill()
}

protocol CosyVoiceServerLaunching: Sendable {
    func launch(
        script: URL,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any CosyVoiceLaunchedProcess
}

// MARK: - 进程注册表（App 退出时兜底终止）

/// App 被正常退出（⌘Q / 菜单退出）时，`applicationWillTerminate` 不会等待异步代码，
/// 因此用同步锁登记当前子进程，在 `NSApplication.willTerminateNotification` 时直接 terminate。
enum CosyVoiceProcessRegistry {
    enum Role: Hashable, Sendable {
        case service
        case installer
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var processes: [Role: any CosyVoiceLaunchedProcess] = [:]
    nonisolated(unsafe) private static var observersInstalled = false

    static func register(
        _ process: any CosyVoiceLaunchedProcess,
        role: Role
    ) {
        lock.lock()
        processes[role] = process
        lock.unlock()
        installExitObserver()
    }

    static func clear(role: Role) {
        lock.lock()
        processes[role] = nil
        lock.unlock()
    }

    static func process(role: Role) -> (any CosyVoiceLaunchedProcess)? {
        lock.lock()
        defer { lock.unlock() }
        return processes[role]
    }

    /// 同步终止所有登记的子进程（App 退出路径；不等待回收）。
    static func terminateAll() {
        lock.lock()
        let snapshot = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for process in snapshot {
            process.terminate()
        }
    }

    static func installExitObserver() {
        lock.lock()
        let alreadyInstalled = observersInstalled
        observersInstalled = true
        lock.unlock()
        guard !alreadyInstalled else { return }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            CosyVoiceProcessRegistry.terminateAll()
        }
    }
}

// MARK: - 真实 Process 实现

/// 把 `Process` 的 stdout/stderr 按行回调（安装进度/服务日志都靠它）。
final class CosyVoiceProcessLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let pipe: Pipe
    private let onLine: @Sendable (String) -> Void
    private var finished = false

    init(pipe: Pipe, onLine: @escaping @Sendable (String) -> Void) {
        self.pipe = pipe
        self.onLine = onLine
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line.trimmingCharacters(in: .newlines))
            }
        }
        lock.unlock()
        for line in lines {
            onLine(line)
        }
    }

    /// 进程退出后调用：摘掉 handler 并冲刷最后一行（没有换行结尾的输出）。
    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        pipe.fileHandleForReading.readabilityHandler = nil
        var remainder = buffer
        buffer.removeAll()
        lock.unlock()
        // 退出时可能还有未读数据；best-effort 读一次。
        if remainder.isEmpty {
            remainder = pipe.fileHandleForReading.availableData
        }
        guard !remainder.isEmpty,
              let text = String(data: remainder, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line).trimmingCharacters(in: .newlines)
            if !value.isEmpty { onLine(value) }
        }
    }
}

/// 真实子进程包装（bash + 脚本）。
final class CosyVoiceChildProcess: CosyVoiceLaunchedProcess, @unchecked Sendable {
    let process: Process
    private let reader: CosyVoiceProcessLineReader

    init(process: Process, reader: CosyVoiceProcessLineReader) {
        self.process = process
        self.reader = reader
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    /// 5 秒后仍未退出 → SIGKILL（脚本 exec 到 python，SIGTERM 正常可回收）。
    func forceKill() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    func finishReading() {
        reader.finish()
    }
}

/// 默认启动器：用 `/bin/bash <script> ...` 在登录 shell 外启动，保留脚本可执行位无关。
struct CosyVoiceProcessLauncher: CosyVoiceServerLaunching {
    func launch(
        script: URL,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any CosyVoiceLaunchedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = CosyVoiceProcessLineReader(pipe: pipe, onLine: onLine)
        process.terminationHandler = { finishedProcess in
            reader.finish()
            onExit(finishedProcess.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw CosyVoiceError.serviceUnavailable(
                "无法启动 \(script.lastPathComponent)：\(error.localizedDescription)")
        }
        return CosyVoiceChildProcess(process: process, reader: reader)
    }
}

// MARK: - 健康轮询（纯逻辑，可注入 fake）

/// 一次 `/health` 探测的归类结果。
enum CosyVoiceProbeResult: Sendable, Equatable {
    case running(CosyVoiceHealth)
    case loading(String)
    case notRunning(String)
    /// 端口可达但返回了非预期内容（多半是端口被其他程序占用）。
    case unexpected(String)
}

/// 启动阶段的健康轮询：等「ready / 进程退出 / 超时 / 取消」四选一。
///
/// 独立成纯函数（时钟/睡眠/探测都可注入），单测不需要真的起 Python 进程。
enum CosyVoiceHealthPolling {
    enum Outcome: Sendable, Equatable {
        case ready(CosyVoiceHealth)
        case failed(String)
        case timedOut(seconds: TimeInterval)
        case cancelled
    }

    static func waitUntilReady(
        timeout: TimeInterval,
        interval: TimeInterval,
        startedAt: Date = Date(),
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        probe: @Sendable () async -> CosyVoiceProbeResult,
        isProcessAlive: @Sendable () -> Bool
    ) async -> Outcome {
        let deadline = startedAt.addingTimeInterval(max(0.1, timeout))
        while true {
            if Task.isCancelled { return .cancelled }
            let result = await probe()
            switch result {
            case .running(let health):
                return .ready(health)
            case .loading:
                break
            case .notRunning(let reason):
                if !isProcessAlive() {
                    let suffix = reason.isEmpty ? "" : "（\(reason)）"
                    return .failed("服务进程已退出\(suffix)")
                }
            case .unexpected(let reason):
                return .failed(reason)
            }
            if now() >= deadline {
                return .timedOut(seconds: timeout)
            }
            do {
                try await sleep(max(0.01, interval))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .cancelled
            }
        }
    }
}

// MARK: - Runtime

/// CosyVoice3 本地服务生命周期管理（actor）。
///
/// 职责：
/// - 定位并启动 `scripts/run_cosyvoice.sh`（后台 Process，前台 exec 到 Python）；
/// - 采集服务日志（设置页展示最后 N 行），健康轮询 ≤90s；
/// - 停止（SIGTERM → 5s → SIGKILL）、崩溃检测（5s 一次健康检查）；
/// - 已安装 + 服务健康的状态以 nonisolated 快照暴露给回复决策（`isServiceReadySnapshot`）；
/// - App 正常退出时尽力停止子进程（`NSApplication.willTerminateNotification`）。
actor CosyVoiceRuntime {
    static let shared = CosyVoiceRuntime()

    static let defaultPort = 5051
    /// 启动等待上限：首次加载 0.5B 模型在 M3 Max 上约 20–60s。
    static let startupTimeout: TimeInterval = 90
    static let healthPollInterval: TimeInterval = 0.5
    static let probeTimeout: TimeInterval = 1.5
    static let monitorInterval: TimeInterval = 5
    /// 空闲时的健康轮询间隔：最近 2 分钟没有合成请求就从 5s 降到 30s，
    /// 避免常驻服务每天 1.7 万次无意义探活（唤醒/能耗/日志噪声）。
    static let idleMonitorInterval: TimeInterval = 30
    static let idleThreshold: TimeInterval = 120
    static let stopGraceSeconds: TimeInterval = 5
    static let maxLogLines = 200

    private let client: CosyVoiceClient
    private let launcher: any CosyVoiceServerLaunching
    nonisolated let home: URL

    private var state: CosyVoiceServiceState = .unknown
    private var currentEndpoint: URL?
    private var process: (any CosyVoiceLaunchedProcess)?
    private var ownsProcess = false
    private var lastExitStatus: Int32?
    private var expectedTermination = false
    private var logLines: [String] = []
    private var monitorTask: Task<Void, Never>?
    private var startTask: Task<CosyVoiceHealth, Error>?
    /// 最近一次合成活动时间；只用它决定健康轮询频率（不影响服务生命周期）。
    private var lastSynthesisAt = Date.distantPast

    init(
        client: CosyVoiceClient? = nil,
        launcher: any CosyVoiceServerLaunching = CosyVoiceProcessLauncher(),
        home: URL? = nil
    ) {
        self.client = client ?? .shared
        self.launcher = launcher
        self.home = home ?? CosyVoiceInstallation.home
        // 首次触达 runtime 时安装退出观察者（不依赖 SwiftUI/AppDelegate 生命周期）。
        CosyVoiceProcessRegistry.installExitObserver()
    }

    // MARK: 只读快照（nonisolated，供回复决策同步读取）

    /// 已安装 + 最近一次健康检查通过。
    ///
    /// 回复决策在 `@MainActor` 上同步读取；真正的健康检查在后台 actor 里推进，
    /// 这里只是最近一次结果的快照（服务崩溃后最多 5 秒内被监控置为 false）。
    nonisolated var isServiceReadySnapshot: Bool {
        CosyVoiceRuntimeCache.isReady
    }

    nonisolated static var isInstalledSnapshot: Bool {
        CosyVoiceInstallation.isInstalled(home: CosyVoiceInstallation.home)
    }

    func snapshot() -> CosyVoiceRuntimeSnapshot {
        CosyVoiceRuntimeSnapshot(
            state: state,
            endpoint: currentEndpoint,
            pid: process?.pid,
            ownsProcess: ownsProcess,
            installed: CosyVoiceInstallation.isInstalled(home: home),
            logTail: logLines,
            updatedAt: Date()
        )
    }

    // MARK: 生命周期

    /// 启动服务（幂等：已在运行直接返回；并发调用复用同一个启动任务）。
    func start(
        endpoint: URL,
        timeout: TimeInterval = CosyVoiceRuntime.startupTimeout
    ) async throws -> CosyVoiceHealth {
        if state.isRunning, currentEndpoint == endpoint,
           let health = state.health {
            return health
        }
        if let startTask {
            return try await startTask.value
        }
        let task = Task<CosyVoiceHealth, Error> {
            try await self.performStart(endpoint: endpoint, timeout: timeout)
        }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    /// 停止本 App 启动的服务进程；外部启动的服务只清理本地状态。
    func stop() async {
        startTask?.cancel()
        startTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        expectedTermination = true

        let current = process
        let wasOwned = ownsProcess
        process = nil
        ownsProcess = false
        CosyVoiceProcessRegistry.clear(role: .service)
        if wasOwned, let current {
            appendLog("停止 CosyVoice3 服务（pid \(current.pid)）")
            current.terminate()
            var waited: TimeInterval = 0
            while current.isRunning, waited < Self.stopGraceSeconds {
                try? await Task.sleep(for: .seconds(0.2))
                waited += 0.2
            }
            if current.isRunning {
                appendLog("服务未在 \(Int(Self.stopGraceSeconds)) 秒内退出，强制结束")
                current.forceKill()
            }
        }
        state = .stopped
        currentEndpoint = nil
        CosyVoiceRuntimeCache.setReady(false)
    }

    /// App 退出路径的同步兜底（不等待进程回收）。
    nonisolated func terminateImmediately() {
        CosyVoiceProcessRegistry.terminateAll()
    }

    /// 只探测、不启动（回复路径用：1.5s 内给出「运行中/加载中/未运行/端口异常」）。
    func quickStatus(endpoint: URL) async -> CosyVoiceServiceState {
        let result = await probe(endpoint: endpoint)
        switch result {
        case .running(let health):
            applyRunning(health: health, endpoint: endpoint, owned: ownsProcess)
            return state
        case .loading(let message):
            if !state.isRunning {
                state = .starting(message.isEmpty ? "服务加载模型中…" : message)
            }
            return state
        case .notRunning:
            if ownsProcess, process?.isRunning == true {
                return state
            }
            state = .stopped
            CosyVoiceRuntimeCache.setReady(false)
            return state
        case .unexpected(let reason):
            state = .failed(reason)
            CosyVoiceRuntimeCache.setReady(false)
            return state
        }
    }

    /// 设置页的「重新检测」：探测并更新状态；已安装但未运行时保持 stopped。
    func refresh(endpoint: URL) async -> CosyVoiceRuntimeSnapshot {
        _ = await quickStatus(endpoint: endpoint)
        return snapshot()
    }

    // MARK: 启动实现

    private func performStart(
        endpoint: URL,
        timeout: TimeInterval
    ) async throws -> CosyVoiceHealth {
        guard CosyVoiceInstallation.isInstalled(home: home) else {
            state = .stopped
            throw CosyVoiceError.notInstalled
        }
        currentEndpoint = endpoint
        expectedTermination = false
        lastExitStatus = nil

        // 1) 已有服务（可能是上次 App 遗留/用户手动启动）：直接复用。
        // 2) 正在加载：等它 ready，不重复起进程（避免端口冲突）。
        switch await probe(endpoint: endpoint) {
        case .running(let health):
            appendLog("检测到已运行的 CosyVoice3 服务，直接复用")
            applyRunning(health: health, endpoint: endpoint, owned: false)
            startMonitor(endpoint: endpoint)
            return health
        case .loading(let message):
            appendLog("检测到 CosyVoice3 服务正在加载，等待就绪：\(message)")
            state = .starting(message.isEmpty ? "服务加载模型中…" : message)
            CosyVoiceRuntimeCache.setReady(false)
            let outcome = await CosyVoiceHealthPolling.waitUntilReady(
                timeout: timeout,
                interval: Self.healthPollInterval,
                probe: { await self.probe(endpoint: endpoint) },
                isProcessAlive: { true }
            )
            return try finishStartup(
                outcome, endpoint: endpoint, processStarted: false,
                timeout: timeout
            )
        case .notRunning:
            break // 端口空闲，继续启动进程。
        case .unexpected(let reason):
            state = .failed(reason)
            throw CosyVoiceError.serviceUnavailable(reason)
        }

        // 3) 端口空闲：启动脚本。
        guard let script = CosyVoiceInstallation.runScript else {
            let reason = "找不到 scripts/run_cosyvoice.sh。"
                + "发布版 App 不包含启动脚本：请在源码仓库目录运行，"
                + "或用环境变量 WECHATAI_COSYVOICE_SCRIPT 指定脚本路径。"
            state = .failed(reason)
            throw CosyVoiceError.serviceUnavailable(reason)
        }
        let port = endpoint.port ?? Self.defaultPort
        let host = endpoint.host ?? "127.0.0.1"
        // `--home` 优先于 env：venv/模型/音色/标记都落在 App 指定的安装目录。
        let arguments = ["--home", home.path, "--port", String(port), "--host", host]
        let environment = CosyVoiceInstallation.scriptEnvironment(home: home, endpoint: endpoint)
        appendLog("启动服务：\(script.lastPathComponent) \(arguments.joined(separator: " "))")
        state = .starting("正在启动本地服务…")
        CosyVoiceRuntimeCache.setReady(false)

        let launched: any CosyVoiceLaunchedProcess
        do {
            launched = try launcher.launch(
                script: script,
                arguments: arguments,
                environment: environment,
                onLine: { [weak self] line in
                    Task { await self?.appendLog(line) }
                },
                onExit: { [weak self] status in
                    Task { await self?.handleProcessExit(status) }
                }
            )
        } catch let error as CosyVoiceError {
            state = .failed(error.errorDescription ?? "启动失败")
            throw error
        } catch {
            let reason = "无法启动 CosyVoice3 服务：\(error.localizedDescription)"
            state = .failed(reason)
            throw CosyVoiceError.serviceUnavailable(reason)
        }
        process = launched
        ownsProcess = true
        CosyVoiceProcessRegistry.register(launched, role: .service)
        state = .starting("服务进程已启动（pid \(launched.pid)），等待模型加载…")

        let outcome = await CosyVoiceHealthPolling.waitUntilReady(
            timeout: timeout,
            interval: Self.healthPollInterval,
            probe: { await self.probe(endpoint: endpoint) },
            isProcessAlive: { [weak launched] in launched?.isRunning ?? false }
        )
        return try finishStartup(
            outcome, endpoint: endpoint, processStarted: true,
            timeout: timeout
        )
    }

    private func finishStartup(
        _ outcome: CosyVoiceHealthPolling.Outcome,
        endpoint: URL,
        processStarted: Bool,
        timeout: TimeInterval
    ) throws -> CosyVoiceHealth {
        switch outcome {
        case .ready(let health):
            applyRunning(health: health, endpoint: endpoint, owned: processStarted)
            startMonitor(endpoint: endpoint)
            appendLog("服务就绪：model=\(health.model ?? "?") device=\(health.device ?? "?")")
            return health
        case .cancelled:
            teardownSpawnedProcess()
            state = .stopped
            CosyVoiceRuntimeCache.setReady(false)
            throw CosyVoiceError.cancelled
        case .failed(let reason):
            teardownSpawnedProcess()
            let message = explainStartupFailure(reason)
            state = .failed(message)
            CosyVoiceRuntimeCache.setReady(false)
            throw CosyVoiceError.serviceUnavailable(message)
        case .timedOut:
            teardownSpawnedProcess()
            let lastLog = logLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            let message = "服务启动超时（\(Int(timeout)) 秒）"
                + (lastLog.map { "；最后日志：\($0)" } ?? "")
            state = .failed(message)
            CosyVoiceRuntimeCache.setReady(false)
            throw CosyVoiceError.serviceUnavailable(message)
        }
    }

    /// 把退出码/端口冲突翻译成用户能行动的中文。
    private func explainStartupFailure(_ detail: String) -> String {
        var message = detail
        if detail.contains("EADDRINUSE") || detail.contains("address already in use") {
            message = "端口已被其他程序占用，请在设置里修改 CosyVoice3 服务端口"
                + "（原始错误：\(detail)）"
        }
        if let status = lastExitStatus, !detail.contains("退出码") {
            message += "（退出码 \(status)）"
        }
        if let lastLog = logLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           !message.contains(lastLog) {
            message += "；最后日志：\(lastLog)"
        }
        return message
    }

    private func teardownSpawnedProcess() {
        expectedTermination = true
        CosyVoiceProcessRegistry.clear(role: .service)
        if ownsProcess, let process {
            process.terminate()
            // 启动失败不阻塞：后台给 2 秒再强杀，避免僵尸进程。
            Task { [weak process] in
                try? await Task.sleep(for: .seconds(2))
                if process?.isRunning == true {
                    process?.forceKill()
                }
            }
        }
        process = nil
        ownsProcess = false
    }

    // MARK: 状态推进

    private func applyRunning(
        health: CosyVoiceHealth,
        endpoint: URL,
        owned: Bool
    ) {
        state = .running(health)
        currentEndpoint = endpoint
        ownsProcess = owned
        CosyVoiceRuntimeCache.setReady(true)
    }

    private func handleProcessExit(_ status: Int32) {
        lastExitStatus = status
        guard !expectedTermination else { return }
        if state.isRunning || state.isStarting {
            appendLog("服务进程退出（退出码 \(status)）")
            state = .failed("服务进程意外退出（退出码 \(status)）")
        }
        ownsProcess = false
        process = nil
        CosyVoiceRuntimeCache.setReady(false)
        CosyVoiceProcessRegistry.clear(role: .service)
    }

    private func startMonitor(endpoint: URL) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.nextMonitorInterval()
                try? await Task.sleep(
                    for: .seconds(interval), tolerance: .seconds(interval / 4))
                guard !Task.isCancelled else { return }
                let shouldContinue = await self.monitorTick(endpoint: endpoint)
                if !shouldContinue { return }
            }
        }
    }

    /// 最近有合成活动 → 5s；空闲 → 30s。
    private func nextMonitorInterval() -> TimeInterval {
        Date().timeIntervalSince(lastSynthesisAt) < Self.idleThreshold
            ? Self.monitorInterval
            : Self.idleMonitorInterval
    }

    /// 合成/试听请求发生时刷新活跃时间（由 Core 调用；空闲后健康轮询自动降频）。
    func noteSynthesisActivity() {
        lastSynthesisAt = Date()
    }

    /// 返回 false 时停止监控（服务已退出/已由其他路径接管）。
    private func monitorTick(endpoint: URL) async -> Bool {
        guard state.isRunning else { return false }
        if ownsProcess, let process, !process.isRunning {
            state = .failed("本地服务已退出")
            CosyVoiceRuntimeCache.setReady(false)
            ownsProcess = false
            self.process = nil
            CosyVoiceProcessRegistry.clear(role: .service)
            return false
        }
        switch await probe(endpoint: endpoint) {
        case .running(let health):
            state = .running(health)
            CosyVoiceRuntimeCache.setReady(true)
            return true
        case .loading(let message):
            state = .starting(message.isEmpty ? "服务重新加载模型中…" : message)
            CosyVoiceRuntimeCache.setReady(false)
            return true
        case .notRunning:
            state = .failed("本地服务已无响应")
            CosyVoiceRuntimeCache.setReady(false)
            return false
        case .unexpected(let reason):
            state = .failed(reason)
            CosyVoiceRuntimeCache.setReady(false)
            return false
        }
    }

    // MARK: 探测

    private func probe(endpoint: URL) async -> CosyVoiceProbeResult {
        do {
            let health = try await client.health(
                timeout: Self.probeTimeout, endpoint: endpoint)
            if health.isReady { return .running(health) }
            if health.loading { return .loading(health.progress ?? "模型加载中") }
            return .loading(health.progress ?? health.failureReason ?? "服务未就绪")
        } catch let error as CosyVoiceError {
            switch error {
            case .serviceLoading(let reason):
                return .loading(reason)
            case .serviceNotRunning(let reason):
                return .notRunning(reason)
            case .httpError, .invalidResponse:
                return .unexpected(error.errorDescription ?? "端口被其他程序占用")
            case .serviceUnavailable(let reason):
                return .notRunning(reason)
            case .cancelled:
                return .notRunning("探测被取消")
            default:
                return .unexpected(error.errorDescription ?? "服务不可用")
            }
        } catch {
            return .notRunning(error.localizedDescription)
        }
    }

    // MARK: 日志

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }
}

// MARK: - 健康快照缓存

/// `nonisolated` 只读快照：回复决策在 MainActor 同步读取「服务是否就绪」。
enum CosyVoiceRuntimeCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ready = false

    static var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    static func setReady(_ value: Bool) {
        lock.lock()
        ready = value
        lock.unlock()
    }
}

