import AppKit
import Darwin
import Foundation
import os

// MARK: - Unified log

/// 稳定性相关的统一日志（`log show --predicate 'subsystem == "com.gusionw.wechatai"'`）。
let stabilityLogger = Logger(subsystem: "com.gusionw.wechatai", category: "Stability")

// MARK: - AppKit 布局安全阀

/// AppKit 显示周期断言的“安全阀”。
///
/// 背景：macOS 26.x 的 AppKit 在 `NSWindow` 的
/// “Update Constraints in Window” 周期数超过窗口内视图数时，会抛出
/// `NSInternalInconsistencyException` 并直接走 `+[NSApplication _crashOnException:]`
/// → `EXC_BREAKPOINT`。这个 abort 发生在 AppKit 的布局回调内部，应用层拿不到异常，
/// 只能提前让 AppKit 不要断言。
///
/// AppKit 通过 `UserDefaults` 的 `NSWindowAssertWhenDisplayCycleLimitReached` 决定
/// 该不该 abort；设为 `false` 时只写日志。本机已确认（macOS 26.7.1 / 25G241）：
/// 该字符串在 dyld shared cache 的 AppKit 段里与
/// `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]`、
/// “The window has been marked as needing another %@ pass…” 相邻，说明这个键确实被
/// 这段代码读取。该 workaround 最早记录于 UTM issue #4691：
/// <https://github.com/utmapp/UTM/issues/4691>。
///
/// 安全阀只把“断言崩溃”降级为“日志”，不修复布局回环本身；真正的根因仍由 UI 层
/// 修复。它也不会关闭 AppKit 的布局检查
/// （不使用 `NSWindowShouldCheckDisplayCycleLimit`）。
enum AppKitLayoutGuard {
    /// AppKit 读取的 asserts 开关键（`false` = 只记录日志，不 abort）。
    static let assertDefaultsKey = "NSWindowAssertWhenDisplayCycleLimitReached"
    /// 调试用逃生门：设为 `1` 时不设置安全阀，并清掉已持久化的键，恢复 AppKit 断言。
    static let disableEnvironmentKey = "WECHATAI_DISABLE_LAYOUT_GUARD"

    /// 必须在任何 SwiftUI 场景 / AppKit 窗口出现之前调用（`WeChatAIApp.init` 第一行）。
    ///
    /// 重复调用无害：`AppDelegate` 在 launch 阶段会再确认一次。`phase` 只用于日志。
    static func install(_ phase: String) {
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.environment[disableEnvironmentKey] == "1" {
            defaults.removeObject(forKey: assertDefaultsKey)
            stabilityLogger.notice(
                "布局安全阀已禁用（\(disableEnvironmentKey, privacy: .public)=1），保留 AppKit 断言以便定位问题"
            )
            return
        }
        // register 只影响本进程、不落盘；set 让 CFPreferences 层（AppKit 若绕过
        // NSUserDefaults 直接读偏好也覆盖到）也读到 false。
        defaults.register(defaults: [assertDefaultsKey: false])
        defaults.set(false, forKey: assertDefaultsKey)
        stabilityLogger.notice(
            "布局安全阀已安装（\(phase, privacy: .public)）：\(assertDefaultsKey, privacy: .public)=false"
        )
    }
}

// MARK: - CrashReporter

/// 崩溃取证与稳定性护栏。
///
/// 提供四件事，全部串在“启动最早、运行期便宜、崩溃时不抛异常”的约束上：
///
/// 1. `install()`：安装 `NSSetUncaughtExceptionHandler`，在
///    `~/Library/Logs/WeChatAI/crash-<yyyyMMdd-HHmmss>.log` 写异常名/原因/调用栈/
///    应用与系统版本/窗口与机器人状态/最近 50 条运行日志。
/// 2. 会话面包屑 `~/Library/Logs/WeChatAI/last-session.txt`：记录本次运行阶段
///    （launching → running → clean-exit…），下次启动能判断上次是否“硬退出”，
///    并把上次的最后状态写进新面包屑（AppKit 内部崩溃不会经过未捕获异常处理器，
///    面包屑是这类硬 abort 的主要证据）。
/// 3. `MainThreadWatchdog`：后台 1s 心跳；主线程 >1.5s 无响应时落盘 + 统一日志 +
///    补写运行日志，为卡顿/布局风暴留下时间线。
/// 4. `AppKitLayoutGuard`：见上。
///
/// 约束：异常处理器运行在崩溃线程上，因此**只做**「复制快照 → 拼字符串 → try? 写文件」，
/// 不 throw、不 force unwrap、不调用 AppKit UI、不碰 MainActor 业务对象。
/// 现场数据由主线程快照（probe）预先准备好，处理器只读。
enum CrashReporter {
    // MARK: 常量

    /// 崩溃报告/面包屑目录：`~/Library/Logs/WeChatAI`。
    static var logsDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Logs/WeChatAI", isDirectory: true)
    }

    static var sessionBreadcrumbURL: URL { logsDirectory.appendingPathComponent("last-session.txt") }
    static var sessionHistoryURL: URL { logsDirectory.appendingPathComponent("sessions.log") }
    static var stallLogURL: URL { logsDirectory.appendingPathComponent("main-thread-stalls.log") }

    private static let recentLogLimit = 50
    private static let maxReportBytes = 128 * 1024
    private static let maxBreadcrumbBytes = 32 * 1024
    private static let maxAppendFileBytes = 256 * 1024
    /// 空闲时面包屑心跳写盘间隔；状态变化/阶段切换会立即写。
    private static let breadcrumbHeartbeatInterval: TimeInterval = 30

    // MARK: 生命周期阶段

    enum LifecycleStage: String {
        case launching = "launching"
        case willFinishLaunch = "will-finish-launch"
        case running = "running"
        /// 主窗口首次真正出现在屏幕上（SwiftUI 场景已挂载）。
        case mainWindow = "main-window"
        case cleanExit = "clean-exit"
        case crashed = "crashed"
    }

    // MARK: 主线程快照（probe 由 App 侧提供）

    /// 主线程现场：只允许读取既有值，不能触发布局/渲染。
    struct Probe {
        var sidebarPage: String
        var botRunning: Bool
        var windowSummary: String
        var logCount: Int
        var lastLogTime: TimeInterval

        init(sidebarPage: String = "-",
             botRunning: Bool = false,
             windowSummary: String = "无主窗口",
             logCount: Int = 0,
             lastLogTime: TimeInterval = 0) {
            self.sidebarPage = sidebarPage
            self.botRunning = botRunning
            self.windowSummary = windowSummary
            self.logCount = logCount
            self.lastLogTime = lastLogTime
        }
    }

    /// 启动期就固定的信息。
    private struct StaticInfo {
        var appVersion = "未知"
        var bundleIdentifier = "未知"
        var osVersion = "未知"
        var pid: Int32 = 0
        var launchedAt = Date()
    }

    /// 主线程维护、崩溃线程只读的现场快照。
    private struct Snapshot {
        var capturedAt = Date.distantPast
        var heartbeatAt = Date.distantPast
        var windowSummary = "未知（启动期崩溃或未上报）"
        var sidebarPage = "未知（启动期崩溃或未上报）"
        var botRunning = false
        var logCount = 0
        var lastLogSummary = "-"
        var logLines: [String] = []
        var fingerprint = 0
        var lastStall = ""
    }

    private struct PreviousSession {
        var stage = "unknown"
        var written = "-"
        var lastLog = "-"
        var exists = false

        var isClean: Bool { stage == LifecycleStage.cleanExit.rawValue }
    }

    // MARK: 状态（`stateLock` 保护；处理器里只用 try-lock）

    private static let stateLock = NSLock()
    /// 串行化面包屑/时间线/崩溃报告的写盘。
    private static let fileLock = NSLock()

    private static var staticInfo = StaticInfo()
    private static var snapshot = Snapshot()
    private static var currentStage: LifecycleStage = .launching
    private static var previousSession = PreviousSession()
    private static var probeProvider: (@MainActor () -> Probe)?
    private static var logProvider: (@MainActor () -> [LogEntry])?
    private static var didInitialInstall = false
    private static var lastBreadcrumbWrite = Date.distantPast

    // MARK: 安装

    /// 最早安装点：`WeChatAIApp.init` 的第一行（AppKit 尚未创建窗口）。
    ///
    /// 注意：AppKit 会在启动过程中安装自己的顶层异常处理器，可能覆盖这里注册的
    /// 处理器。因此 `AppDelegate.applicationWillFinishLaunching` 会再调用
    /// `reinstallExceptionHandler(phase:)` 覆盖回来（实测只有这样处理器才会被调用）。
    static func install() {
        stateLock.lock()
        let alreadyInstalled = didInitialInstall
        if !alreadyInstalled {
            didInitialInstall = true
            staticInfo = StaticInfo(
                appVersion: resolvedAppVersion(),
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.gusionw.wechatai(dev)",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                pid: ProcessInfo.processInfo.processIdentifier,
                launchedAt: Date()
            )
            previousSession = readPreviousSession()
            currentStage = .launching
            lastBreadcrumbWrite = .distantPast
        }
        stateLock.unlock()

        reinstallExceptionHandler(phase: alreadyInstalled ? "reinstall" : "App.init")

        guard !alreadyInstalled else { return }

        // `exit()` / `NSApp.terminate` 都会走 atexit；崩溃（SIGTRAP/SIGABRT）不会。
        // 这样下次启动就能区分「正常退出」和「硬 abort」。
        _ = atexit {
            CrashReporter.noteCleanExit(reason: "atexit")
        }

        let previous = previousSession
        if previous.exists {
            if previous.isClean {
                stabilityLogger.notice("上次会话正常退出（\(previous.written, privacy: .public)）")
            } else {
                stabilityLogger.error(
                    "检测到上次会话未正常退出：stage=\(previous.stage, privacy: .public) written=\(previous.written, privacy: .public) lastLog=\(previous.lastLog, privacy: .public)"
                )
            }
        }
        writeBreadcrumb(force: true)
        appendFileLine(
            "launch pid=\(ProcessInfo.processInfo.processIdentifier) stage=launching previous=\(previous.exists ? previous.stage : "none")",
            to: sessionHistoryURL
        )
    }

    /// 安装/重新安装顶层未捕获异常处理器。必须在 AppKit 启动完成后调用一次才可靠。
    static func reinstallExceptionHandler(phase: String) {
        NSSetUncaughtExceptionHandler { exception in
            // 处理器在崩溃线程上运行：只读快照 + 写文件，绝不能 throw。
            CrashReporter.writeReportForUncaughtException(exception)
        }
        stabilityLogger.notice("未捕获异常处理器已安装（\(phase, privacy: .public)）")
    }

    /// 启动阶段推进（AppDelegate 调用）。
    static func markPhase(_ stage: LifecycleStage) {
        stateLock.lock()
        if currentStage == .cleanExit || currentStage == .crashed { stateLock.unlock(); return }
        currentStage = stage
        stateLock.unlock()
        writeBreadcrumb(force: true)
        appendFileLine("stage=\(stage.rawValue)", to: sessionHistoryURL)
    }

    /// 主窗口首次真正挂载（`MainWindowBehavior.Coordinator` 调用）。
    static func noteMainWindowPresented() {
        stateLock.lock()
        let stage = currentStage
        let shouldPromote = stage == .launching || stage == .willFinishLaunch || stage == .running
        if shouldPromote { currentStage = .mainWindow }
        stateLock.unlock()
        guard shouldPromote else { return }
        // 窗口信息只有在 attach 之后才可读：补一次主线程现场快照再写面包屑。
        mainThreadHeartbeat()
        writeBreadcrumb(force: true)
    }

    /// 正常退出落面包屑（`applicationWillTerminate` / `atexit` 都会调用，幂等）。
    static func noteCleanExit(reason: String) {
        stateLock.lock()
        let previous = currentStage
        let alreadyClean = previous == .cleanExit
        currentStage = .cleanExit
        stateLock.unlock()
        guard !alreadyClean else { return }
        writeBreadcrumb(force: true)
        appendFileLine("exit reason=\(reason) stage=clean-exit", to: sessionHistoryURL)
    }

    /// 把 App 侧的现场提供者挂上（在 `AppStore` 创建之后、主线程调用）。
    ///
    /// 闭包由 App 侧以 `[weak store]` 捕获，静态存储不会延长 `AppStore` 生命周期，
    /// 也不会形成引用环。
    @MainActor
    static func attach(
        probe: @escaping @MainActor () -> Probe,
        logs: @escaping @MainActor () -> [LogEntry]
    ) {
        stateLock.lock()
        probeProvider = probe
        logProvider = logs
        stateLock.unlock()
        captureSnapshot(reason: "attach", force: true)
    }

    // MARK: 主线程快照

    /// 主线程心跳：刷新现场快照（状态没变时几乎无开销）并节流写面包屑。
    ///
    /// 由看门狗的 main-queue ping 调用；也可在 AppDelegate 里手动调用。
    @MainActor
    static func captureSnapshot(reason: String = "heartbeat", force: Bool = false) {
        stateLock.lock()
        let probeClosure = probeProvider
        let logsClosure = logProvider
        let previous = snapshot
        stateLock.unlock()

        guard let probeClosure, let logsClosure else {
            writeBreadcrumb(force: force)
            return
        }

        let probe = probeClosure()
        let fingerprint = fingerprint(of: probe)
        let now = Date()

        if fingerprint != previous.fingerprint || force {
            let entries = Array(logsClosure().suffix(recentLogLimit))
            let lines = entries.map(formatLogLine)
            var updated = previous
            updated.capturedAt = now
            updated.heartbeatAt = now
            updated.windowSummary = probe.windowSummary
            updated.sidebarPage = probe.sidebarPage
            updated.botRunning = probe.botRunning
            updated.logCount = probe.logCount
            updated.logLines = lines
            updated.lastLogSummary = lines.last ?? "-"
            updated.fingerprint = fingerprint
            stateLock.lock()
            snapshot = updated
            stateLock.unlock()
        } else {
            stateLock.lock()
            snapshot.heartbeatAt = now
            stateLock.unlock()
        }
        writeBreadcrumb(force: force || fingerprint != previous.fingerprint)
        _ = reason // 目前只用于调试断点，保留参数便于后续区分来源
    }

    /// 主线程心跳（看门狗调用；非 MainActor 入口，内部 assumeIsolated）。
    static func mainThreadHeartbeat() {
        MainActor.assumeIsolated {
            captureSnapshot(reason: "watchdog-heartbeat")
        }
    }

    private static func fingerprint(of probe: Probe) -> Int {
        var hasher = Hasher()
        hasher.combine(probe.sidebarPage)
        hasher.combine(probe.botRunning)
        hasher.combine(probe.windowSummary)
        hasher.combine(probe.logCount)
        hasher.combine(probe.lastLogTime)
        return hasher.finalize()
    }

    private static func formatLogLine(_ entry: LogEntry) -> String {
        "\(timeText(entry.date)) \(entry.level.rawValue.uppercased()) \(entry.source): \(entry.message)"
    }

    // MARK: 主线程卡顿

    /// 主线程无响应/恢复记录（看门狗后台线程调用）。
    ///
    /// 只写文件 + 统一日志，不触碰 MainActor，避免主线程卡住时把看门狗也拖死。
    static func recordMainThreadStall(_ message: String) {
        let now = Date()
        let stamp = timeText(now)
        appendFileLine("\(stamp) [stall] \(message)", to: stallLogURL)
        stateLock.lock()
        snapshot.lastStall = "\(stamp) \(message)"
        stateLock.unlock()
        writeBreadcrumb(force: true)
    }

    // MARK: 未捕获异常报告

    /// 未捕获异常处理器主体。**运行在崩溃线程上**：只读快照、只写文件。
    private static func writeReportForUncaughtException(_ exception: NSException) {
        // 取快照：try-lock，避免极端情况下与主线程写快照互相等待。
        let captured: Snapshot
        let info: StaticInfo
        let previous: PreviousSession
        if stateLock.try() {
            captured = snapshot
            info = staticInfo
            previous = previousSession
            stateLock.unlock()
        } else {
            captured = Snapshot()
            info = StaticInfo(
                appVersion: resolvedAppVersion(),
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.gusionw.wechatai(dev)",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                pid: ProcessInfo.processInfo.processIdentifier,
                launchedAt: Date()
            )
            previous = PreviousSession()
        }

        let now = Date()
        let fileName = "crash-\(fileStamp(now)).log"
        let url = logsDirectory.appendingPathComponent(fileName)

        var report = ""
        report += "[WeChatAI 崩溃报告]\n"
        report += "written=\(timeText(now, withDate: true, withTimeZone: true))\n"
        report += "pid=\(info.pid)\n"
        report += "app=\(info.appVersion)\n"
        report += "bundle=\(info.bundleIdentifier)\n"
        report += "os=\(info.osVersion)\n"
        report += "sessionLaunchedAt=\(timeText(info.launchedAt, withDate: true))\n"
        report += "breadcrumb=\(sessionBreadcrumbURL.path)\n"
        report += "\n--- 未捕获异常 ---\n"
        report += "exceptionName=\(exception.name.rawValue)\n"
        report += "exceptionReason=\(exception.reason ?? "(nil)")\n"
        if let userInfo = exception.userInfo, !userInfo.isEmpty {
            report += "exceptionUserInfo=\(String(describing: userInfo))\n"
        }
        report += "\n--- 现场快照（主线程最后一次上报；captured=\(timeText(captured.capturedAt, withDate: true))） ---\n"
        report += "sidebar=\(captured.sidebarPage)\n"
        report += "botRunning=\(captured.botRunning)\n"
        report += "window=\(captured.windowSummary)\n"
        report += "logCount=\(captured.logCount)\n"
        report += "lastLog=\(captured.lastLogSummary)\n"
        if !captured.lastStall.isEmpty {
            report += "lastStall=\(captured.lastStall)\n"
        }
        if previous.exists {
            report += "previousSessionStage=\(previous.stage)\n"
            report += "previousSessionWritten=\(previous.written)\n"
        }
        report += "\n--- 最近 \(captured.logLines.count) 条运行日志（旧 → 新） ---\n"
        if captured.logLines.isEmpty {
            report += "(启动期崩溃：还没有运行日志)\n"
        } else {
            report += captured.logLines.joined(separator: "\n") + "\n"
        }
        report += "\n--- 崩溃线程调用栈（exception.callStackSymbols） ---\n"
        let exceptionSymbols = exception.callStackSymbols
        report += exceptionSymbols.isEmpty ? "(无符号)\n" : exceptionSymbols.joined(separator: "\n") + "\n"
        report += "\n--- 当前线程调用栈（Thread.callStackSymbols） ---\n"
        let threadSymbols = Thread.callStackSymbols
        report += threadSymbols.isEmpty ? "(无符号)\n" : threadSymbols.joined(separator: "\n") + "\n"
        report += "\n--- 提示 ---\n"
        report += "AppKit 内部 abort（例如 +[NSApplication _crashOnException:]）不会走到未捕获异常处理器，\n"
        report += "对应系统报告在 ~/Library/Logs/DiagnosticReports/WeChatAI-*.ips，可与 \(sessionBreadcrumbURL.lastPathComponent) 对照。\n"
        report += "统一日志：log show --last 5m --predicate 'process == \"WeChatAI\"' | grep -i DisplayCycle\n"

        if report.utf8.count > maxReportBytes {
            report = String(report.prefix(maxReportBytes))
            report += "\n…（报告超长已截断）\n"
        }

        fileLock.lock()
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try? report.write(to: url, atomically: true, encoding: .utf8)
        fileLock.unlock()

        fputs("[CrashReporter] 未捕获异常报告已写入 \(url.path)\n", stderr)

        stabilityLogger.fault(
            "未捕获异常 \(exception.name.rawValue, privacy: .public)：\(exception.reason ?? "(nil)", privacy: .public)；报告 \(fileName, privacy: .public)"
        )

        // 面包屑标记崩溃，便于下次启动关联；不改写阶段以外的内容。
        stateLock.lock()
        currentStage = .crashed
        stateLock.unlock()
        appendFileLine("crash file=\(fileName) exception=\(exception.name.rawValue)", to: sessionHistoryURL)
        writeBreadcrumb(force: true)
    }

    // MARK: 面包屑

    private static func writeBreadcrumb(force: Bool) {
        let now = Date()
        stateLock.lock()
        guard force || now.timeIntervalSince(lastBreadcrumbWrite) >= breadcrumbHeartbeatInterval else {
            stateLock.unlock()
            return
        }
        lastBreadcrumbWrite = now
        let info = staticInfo
        let current = snapshot
        let stage = currentStage
        let previous = previousSession
        stateLock.unlock()

        var text = ""
        text += "# WeChatAI 会话面包屑（崩溃取证用；正常退出时 stage=clean-exit）\n"
        text += "written=\(timeText(now, withDate: true, withTimeZone: true))\n"
        text += "heartbeat=\(current.heartbeatAt == .distantPast ? "-" : timeText(current.heartbeatAt, withDate: true, withTimeZone: true))\n"
        text += "stage=\(stage.rawValue)\n"
        text += "app=\(info.appVersion)\n"
        text += "bundle=\(info.bundleIdentifier)\n"
        text += "os=\(info.osVersion)\n"
        text += "pid=\(info.pid)\n"
        text += "launched=\(timeText(info.launchedAt, withDate: true, withTimeZone: true))\n"
        text += "sidebar=\(current.sidebarPage)\n"
        text += "botRunning=\(current.botRunning)\n"
        text += "window=\(current.windowSummary)\n"
        text += "logCount=\(current.logCount)\n"
        text += "lastLog=\(current.lastLogSummary)\n"
        if !current.lastStall.isEmpty {
            text += "lastStall=\(current.lastStall)\n"
        }
        text += "previousStage=\(previous.exists ? previous.stage : "none")\n"
        text += "previousWritten=\(previous.exists ? previous.written : "-")\n"
        text += "previousLastLog=\(previous.exists ? previous.lastLog : "-")\n"
        text += "\n# 日志目录：\(logsDirectory.path)\n"

        if text.utf8.count > maxBreadcrumbBytes {
            text = String(text.prefix(maxBreadcrumbBytes))
        }

        fileLock.lock()
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try? text.write(to: sessionBreadcrumbURL, atomically: true, encoding: .utf8)
        fileLock.unlock()
    }

    private static func readPreviousSession() -> PreviousSession {
        var previous = PreviousSession()
        guard let data = try? Data(contentsOf: sessionBreadcrumbURL),
              data.count <= maxBreadcrumbBytes,
              let text = String(data: data, encoding: .utf8)
        else { return previous }
        previous.exists = true
        previous.stage = "unknown"
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = String(parts[1])
            switch key {
            case "stage": previous.stage = value
            case "written": previous.written = value
            case "lastLog": previous.lastLog = value
            default: break
            }
        }
        return previous
    }

    // MARK: 小工具

    private static func resolvedAppVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        if let short {
            return build.map { "\(short) (\($0))" } ?? short
        }
        // SwiftPM 裸二进制没有 Info.plist。
        return "dev (\(ProcessInfo.processInfo.processName))"
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()

    private static let dateTimeZoneFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()

    private static func fileStamp(_ date: Date) -> String {
        fileStampFormatter.string(from: date)
    }

    private static func timeText(_ date: Date, withDate: Bool = false, withTimeZone: Bool = false) -> String {
        if date == .distantPast { return "-" }
        if withDate {
            return withTimeZone ? dateTimeZoneFormatter.string(from: date) : dateTimeFormatter.string(from: date)
        }
        return timeFormatter.string(from: date)
    }

    /// 追加一行；超过 `maxBytes` 时清空重建，避免日志无限增长。
    private static func appendFileLine(_ line: String, to url: URL) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let size = ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size > maxAppendFileBytes {
            try? "".write(to: url, atomically: false, encoding: .utf8)
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - 主线程看门狗

/// 主线程看门狗：后台串行队列每 `tickInterval` 秒向主队列发一次心跳，
/// 主线程超过 `stallThreshold` 没有响应就记录卡顿。
///
/// 设计要点：
/// - 行情健康时每个 tick 只产生一次 main-queue block，不拼字符串、不分配数组；
///   现场快照（probe）在快照指纹未变化时直接跳过（见 `CrashReporter.captureSnapshot`）。
/// - 卡顿期间**不叠加**新的 ping，因此不会反过来压垮主队列。
/// - 卡顿记录只写文件 + 统一日志，并把补写运行日志的 `Task { @MainActor }` 扔给主队列：
///   主线程卡住时它排队等待、恢复后执行，不会造成 MainActor 死锁。
/// - 测试环境（XCTest）与 `WECHATAI_DISABLE_WATCHDOG=1` 下不启动。
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    /// 心跳间隔（秒）。
    static let tickInterval: TimeInterval = 1.0
    /// 判定“主线程无响应”的阈值（秒）。
    static let stallThreshold: TimeInterval = 1.5
    /// 同一次卡顿内重复上报的最小间隔（秒）。
    private static let repeatedReportInterval: TimeInterval = 5.0

    private let queue = DispatchQueue(label: "com.gusionw.wechatai.main-thread-watchdog", qos: .utility)
    private let lock = NSLock()

    private var timer: DispatchSourceTimer?
    private var awaitingPong = false
    private var pingSentAt: TimeInterval = 0
    private var lastReportAt: TimeInterval = 0
    private var reportedThisStall = false
    private var running = false

    /// 卡顿/恢复回调。在**后台队列**上调用，实现方必须自己保证线程安全。
    var onStall: ((String) -> Void)?

    private init() {}

    /// 测试环境：不启动（避免拖慢 / 干扰 52 个单元测试）。
    static var isRunningUnderTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }

    func start() {
        guard !Self.isRunningUnderTests else {
            stabilityLogger.notice("主线程看门狗：检测到测试环境，跳过启动")
            return
        }
        guard ProcessInfo.processInfo.environment["WECHATAI_DISABLE_WATCHDOG"] != "1" else {
            stabilityLogger.notice("主线程看门狗：WECHATAI_DISABLE_WATCHDOG=1，跳过启动")
            return
        }

        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.tickInterval,
            repeating: Self.tickInterval,
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            self?.tick()
        }

        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
        stabilityLogger.notice(
            "主线程看门狗已启动（tick=\(Int(Self.tickInterval * 1000), privacy: .public)ms，阈值=\(Int(Self.stallThreshold * 1000), privacy: .public)ms）"
        )
    }

    func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        running = false
        awaitingPong = false
        reportedThisStall = false
        lock.unlock()
        timer?.cancel()
        stabilityLogger.notice("主线程看门狗已停止")
    }

    // MARK: 内部

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let running = self.running
        let awaiting = awaitingPong
        let sentAt = pingSentAt
        let reported = reportedThisStall
        let lastReport = lastReportAt
        lock.unlock()
        guard running else { return }

        if awaiting {
            let elapsed = now - sentAt
            if elapsed >= Self.stallThreshold,
               !reported || now - lastReport >= Self.repeatedReportInterval {
                lock.lock()
                reportedThisStall = true
                lastReportAt = now
                lock.unlock()
                reportStall(elapsed: elapsed)
            }
            // 主线程仍无响应：不叠加新 ping，等它恢复。
            return
        }
        sendPing(at: now)
    }

    private func sendPing(at now: TimeInterval) {
        lock.lock()
        awaitingPong = true
        pingSentAt = now
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            CrashReporter.mainThreadHeartbeat()
            self.handlePong()
        }
    }

    private func handlePong() {
        lock.lock()
        let wasReported = reportedThisStall
        let sentAt = pingSentAt
        awaitingPong = false
        reportedThisStall = false
        lock.unlock()

        guard wasReported else { return }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - sentAt)
        let message = "主线程恢复响应（本次卡顿约 \(Self.milliseconds(elapsed))ms）"
        stabilityLogger.notice("\(message, privacy: .public)")
        CrashReporter.recordMainThreadStall(message)
        onStall?(message)
    }

    private func reportStall(elapsed: TimeInterval) {
        let message = "主线程无响应 ≥\(Self.milliseconds(elapsed))ms（阈值 \(Self.milliseconds(Self.stallThreshold))ms）"
        stabilityLogger.error("\(message, privacy: .public)")
        CrashReporter.recordMainThreadStall(message)
        onStall?(message)
    }

    private static func milliseconds(_ interval: TimeInterval) -> String {
        String(format: "%.0f", interval * 1000)
    }
}
