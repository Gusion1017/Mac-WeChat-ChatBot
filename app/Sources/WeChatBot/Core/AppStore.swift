import Foundation
import Observation

/// Central application store. UI reads observable state from here.
/// Runtime wiring (OneBot / AI / memory / scheduler) lives in `Services/` and is
/// composed by the `AppStore+Runtime` extension.
@MainActor
@Observable
final class AppStore {
    // Persisted state
    var settings: AppSettings
    var providers: [AIProvider]
    var personas: [Persona]
    var schedules: [ScheduledTask]

    // Runtime state
    var hookStatus = HookStatus()
    var stats = BotStats()
    var conversations: [Conversation] = []
    var messages: [String: [ChatMessage]] = [:]
    var longTermMemories: [LongTermMemory] = []
    var logs: [LogEntry] = []
    /// 日志缓冲的修改代数：`logs` 每次整体变化都会 +1。日志页/仪表盘用低频采样
    /// （500ms / 750ms）对比这个值，未变化时跳过 O(n) 的重算与复制，空闲时不空转。
    private(set) var logRevision: UInt64 = 0

    var sidebarSelection: SidebarItem? = .dashboard
    var selectedConversationID: String?
    var isBotRunning = false
    var isBusy = false
    var isOnboardingPresented = false
    var gatewayConnected = false
    var lastError: String?

    /// 语音发送运行时状态（bridge /voice_status；登录稳定倒计时/句柄）。
    /// 由 Runtime 刷新；设置页只读展示，语音回复决策用它拦截未就绪状态。
    var voiceRuntimeStatus: VoiceRuntimeStatus = .unavailable

    /// 自动回复流水线的实时阶段快照，按会话 ID 索引（不持久化）。
    /// 由 `RuntimeCoordinator` 在收到消息后写入，供会话页头、输入区状态条与会话列表实时展示。
    var replyProgress: [String: ReplyProgress] = [:]

    /// 入站图片获取队列（设置开关 + 串行请求）。生命周期跟随 AppStore，
    /// 由 Runtime 注入请求/回调闭包；`@Observable` 不追踪（UI 无需刷新）。
    let imageFetcher = ImageFetcher()

    /// 入站语音获取队列（`POST /fetch_voice`，串行 + 去重 + 重试 1 次）。
    /// 同样由 Runtime 注入闭包；转写服务是 actor，可在后台串行执行。
    let voiceFetcher = VoiceFetcher()

    /// 本地语音转写（SpeechAnalyzer actor）；UI 查询资源状态、Runtime 调用转写。
    let voiceTranscription = VoiceTranscriptionService()

    /// 本地语音合成（sherpa-onnx actor）；回复投递时按设置决定是否改用语音。
    let voiceSynthesis = VoiceSynthesisService()

    init(settings: AppSettings = SettingsStore.load()) {
        self.settings = settings
        self.providers = settings.providers
        self.personas = settings.personas
        self.schedules = settings.schedules
        L10n.apply(settings.general.language)
        self.hookStatus.versionConfigFile = settings.hook.versionConfigPath
        // Reading WeChat's Info.plist is disk I/O and used to run synchronously in init.
        // It is filled in off-main by the runtime bootstrap instead (`AppStore+Runtime`),
        // which also refreshes the full hook status shortly after.
        RuntimeBootstrap.scheduleRuntime(for: self)
    }

    // MARK: Derived

    var selectedConversation: Conversation? {
        guard let id = selectedConversationID else { return nil }
        return conversations.first(where: { $0.id == id })
    }

    var selectedMessages: [ChatMessage] {
        guard let id = selectedConversationID else { return [] }
        return messages[id] ?? []
    }

    var defaultProvider: AIProvider? {
        settings.provider(id: settings.ai.defaultProviderID)
    }

    // MARK: Persistence

    func persist() {
        settings.providers = providers
        settings.personas = personas
        settings.schedules = schedules
        settings.bot.defaultProviderID = settings.ai.defaultProviderID
        let snapshot = settings
        // Encoding/atomic write happens on SettingsPersistence's actor, never on MainActor.
        Task { try? await SettingsPersistence.shared.save(snapshot) }
        RuntimeRegistry.existing(for: self)?.settingsDidChange()
    }

    func reload() {
        let loaded = SettingsStore.load()
        settings = loaded
        providers = loaded.providers
        personas = loaded.personas
        schedules = loaded.schedules
        L10n.apply(loaded.general.language)
    }

    /// Changes the interface language and persists it. Views re-render through the
    /// `language` setting; `L()` strings pick up the new language immediately.
    func setLanguage(_ raw: String) {
        guard settings.general.language != raw else { return }
        settings.general.language = raw
        L10n.apply(raw)
        persist()
    }

    // MARK: Logs (runtime methods live in AppStore+Runtime.swift)

    /// Upper bound for the observable in-memory log buffer (LogsView displays this cap).
    static let logBufferLimit = 2000

    /// Coalesced, thread-safe entry point. Entries are buffered by `LogPipeline` and
    /// appended to `logs` in batches (see `appendLogBatch`) so a chatty bridge cannot
    /// invalidate the UI once per line. Safe to call from any actor/thread.
    func appendLog(_ level: LogLevel, _ source: String, _ message: String) {
        LogPipeline.shared.emit(level, source, message)
    }

    /// Applies a batch of already-coalesced entries with a single observable mutation
    /// and one trim pass. Called by `LogPipeline` on the main actor.
    func appendLogBatch(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        var updated = logs
        updated.append(contentsOf: entries)
        if updated.count > Self.logBufferLimit {
            updated.removeFirst(updated.count - Self.logBufferLimit)
        }
        logs = updated
        logRevision &+= 1
    }

    /// 用启动时从数据库合并出的历史日志整体替换内存缓冲（由 `RuntimeCoordinator` 调用）。
    /// 统一裁剪到上限并 bump `logRevision`，UI 的低频采样据此感知内容变化。
    func replaceLogs(_ newLogs: [LogEntry]) {
        var updated = newLogs
        if updated.count > Self.logBufferLimit {
            updated.removeFirst(updated.count - Self.logBufferLimit)
        }
        logs = updated
        logRevision &+= 1
    }

    func clearLogs() {
        LogPipeline.shared.clearPending()
        logs.removeAll()
        logRevision &+= 1
    }

    // MARK: Helpers

    /// Reads WeChat's bundle version. Pure file I/O with no actor state, so it can run
    /// off the main actor (startup prewarm in `AppStore+Runtime`).
    nonisolated static func installedWeChatVersion(path: String) -> String? {
        let info = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["WeChatBundleVersion"] as? String ?? plist["CFBundleShortVersionString"] as? String
    }
}
