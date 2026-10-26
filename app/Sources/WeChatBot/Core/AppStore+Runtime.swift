import AppKit
import Foundation

// MARK: - Errors

enum RuntimeError: LocalizedError {
    case providerNotFound(String)
    case noProvider
    case providerNotConfigured(String)
    case providerCredentialUnreadable(String, OSStatus)
    case conversationNotFound(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .providerNotFound(let id): return "未找到 AI 服务：\(id)"
        case .noProvider: return "尚未配置 AI 服务，请先在「AI 模型」中添加"
        case .providerNotConfigured(let name): return "AI 服务「\(name)」缺少 API Key，请先配置"
        case .providerCredentialUnreadable(let name, let status):
            return "AI 服务「\(name)」的 API Key 无法从钥匙串读取（OSStatus \(status)）。"
                + "通常是 app 重新构建/重签后钥匙串授权失效：请在「钥匙串访问」删除 "
                + "\(AppPaths.bundleID) 下的条目，再在「AI 模型」里重新填写 Key。"
        case .conversationNotFound(let id): return "未找到会话：\(id)"
        case .notRunning: return "机器人未运行"
        }
    }
}

// MARK: - Runtime registry

/// Maps an `AppStore` to its runtime coordinator without adding stored properties to
/// the Lead-owned `AppStore` class. The store is retained for the app's lifetime.
@MainActor
enum RuntimeRegistry {
    private static var coordinators: [ObjectIdentifier: RuntimeCoordinator] = [:]

    static func coordinator(for store: AppStore) -> RuntimeCoordinator {
        let key = ObjectIdentifier(store)
        if let existing = coordinators[key] { return existing }
        let coordinator = RuntimeCoordinator(store: store)
        coordinators[key] = coordinator
        return coordinator
    }

    static func existing(for store: AppStore) -> RuntimeCoordinator? {
        coordinators[ObjectIdentifier(store)]
    }
}

@MainActor
enum RuntimeBootstrap {
    /// Kicked off from `AppStore.init`; loads DB state and refreshes hook status off the
    /// main thread without blocking app launch.
    static func scheduleRuntime(for store: AppStore) {
        Task { @MainActor in
            let coordinator = RuntimeRegistry.coordinator(for: store)
            await coordinator.bootstrapIfNeeded()
        }
    }
}

// MARK: - Coordinator

/// Owns all long-lived services and the event pipeline:
/// OneBot event → conversation/message persistence → RuleEngine → ChatEngine → send.
@MainActor
final class RuntimeCoordinator {
    private unowned let store: AppStore

    let memory = MemoryStore.shared
    let keychain = KeychainStore.shared
    let aiClient = AIClient()
    let hookManager: HookManager
    let ruleEngine = RuleEngine()
    let chatEngine: ChatEngine
    let scheduler = SchedulerService()
    /// DeepSeek 余额查询客户端（电量读取是 IOKit 同步调用，不需要长驻对象）。
    let deepSeekBalanceClient = DeepSeekBalanceClient()

    private(set) var bootstrapped = false
    private var bootstrapping = false
    private var bootstrapTask: Task<Void, Never>?

    private var oneBotClient: OneBotClient?
    private var startedOneBotConfiguration: OneBotClient.Configuration?
    private var selfID = ""
    private var inFlightConversations: Set<String> = []
    /// 识图（视觉模型）状态：只记录本次运行尝试过的消息，描述本身落库
    /// （`ChatMessage.imageDescription`）。避免同一条图片在一次运行内反复请求付费模型。
    private var visionAttempted: Set<String> = []
    /// 已成功入队的图片获取 ID（`ChatMessage.id`）。识图等待本地文件时据此判断
    /// 「还在下载」还是「已失败/从未请求」，不需要额外轮询 ImageFetcher 内部状态。
    private var pendingImageFetchIDs: Set<String> = []
    /// 已入队/在途的语音获取与转写 ID（`ChatMessage.id`）。自动回复等待转写完成
    /// （≤15s）时据此判断「还在处理」还是「已失败」，不轮询 VoiceFetcher 内部状态。
    private var pendingVoiceFetchIDs: Set<String> = []
    private var pendingVoiceTranscriptionIDs: Set<String> = []
    /// 本次运行是否已尝试过转写（避免同一消息反复调用识别；用户手动重试例外）。
    private var voiceTranscriptionAttempted: Set<String> = []
    /// 上一次声明的「语音转写总开关」，用于设置关闭时取消未完成的获取请求。
    private var lastVoiceTranscriptionEnabled: Bool?
    private var memoryMaintenanceInFlight: Set<String> = []
    private var lastSchedulerTasks: [ScheduledTask] = []
    /// 最近一次可用的通讯录目录（内存副本）；数据库缓存由 `MemoryStore` 负责。
    /// nil / `ok == false` 时行为与没有该功能完全一致：会话标题继续走 `ConversationName` 兜底。
    private var contactDirectory: ContactDirectorySnapshot?
    private var lastContactDirectoryFailureReason: String?

    /// Conversations whose newest message page is loaded synchronously at launch.
    /// The rest are filled in by a low-priority background prefetch after first paint.
    private static let preloadedConversationLimit = 48
    private static let preloadedMessagePageSize = 30
    /// 超过该时长的事件视为历史回放/补同步，只入库、不触发自动回复。
    private static let staleReplyWindow: TimeInterval = 120

    /// 设置键：selfID 的来源。`login` 表示由 bridge `get_login_info` 写入（权威），
    /// 启动时的历史修复可以直接信任它，不再从历史事件反推账号。
    private static let selfIDSourceKey = "onebot.self_id_source"
    private static let selfIDSourceLogin = "login"
    /// 一次性全表文本迁移的版本号（设置键 `data.repairs_version`）。
    /// 两项迁移都成功后写入；之后启动直接跳过，避免每次启动都全表 LIKE 扫描历史消息。
    private static let dataRepairVersion = 1
    private static let dataRepairVersionKey = "data.repairs_version"
    private var backgroundPrefetchTask: Task<Void, Never>?
    private var selfMentionBackfillTask: Task<Void, Never>?

    private var statsFlushTask: Task<Void, Never>?
    private var statsDay: String = RuntimeCoordinator.dayKey()
    private var terminationObserver: NSObjectProtocol?

    /// 电量 / DeepSeek 余额的后台刷新任务与去重标记。
    private var systemVitalsTask: Task<Void, Never>?
    private var balanceRefreshInFlight = false
    /// 通道配置指纹：AI 模型页新增通道、填写 Key 或改 baseURL 后立即重查余额。
    private var lastProviderFingerprint: String?

    init(store: AppStore) {
        self.store = store
        self.hookManager = HookManager(wechatPath: store.settings.hook.wechatPath)
        self.chatEngine = ChatEngine(memory: memory, aiClient: aiClient)

        // Single coalescing sink for UI + database log writes (batched every 200 ms).
        LogPipeline.shared.attach(store: store, memory: memory)

        hookManager.onStatusChange = { [weak self] status in
            guard let self else { return }
            if self.store.hookStatus != status { self.store.hookStatus = status }
            if self.store.gatewayConnected != status.gatewayConnected {
                self.store.gatewayConnected = status.gatewayConnected
            }
        }
        hookManager.onLog = { [weak self] level, message in
            self?.log(level, "Hook", message)
        }
        chatEngine.onLog = { [weak self] level, message in
            Task { @MainActor [weak self] in
                self?.log(level, "ChatEngine", message)
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdownImmediately()
            }
        }

        startSystemVitalsMonitoring()
    }

    deinit {
        systemVitalsTask?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: Bootstrap

    func bootstrapIfNeeded() async {
        guard !bootstrapped else { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        guard !bootstrapped, !bootstrapping else { return }
        bootstrapping = true
        defer { bootstrapping = false }

        AppPaths.ensureDirectories()
        prewarmWeChatVersion()
        log(.info, "Runtime", "正在启动服务层…")
        do {
            try await memory.open()
        } catch {
            log(.error, "Database", "无法打开数据库：\(error.localizedDescription)")
        }
        await ensureFirstRunDefaults()
        await loadPersistedState()
        await loadStats()
        log(.debug, "Runtime", "本地状态已加载，正在检测微信与 Hook 状态…")
        await refreshStatus()
        bootstrapped = true
        log(.info, "Runtime", "服务层就绪 · 数据库 \(memory.path)")

        if ProcessInfo.processInfo.environment["WECHATAI_SELFTEST"] == "1" {
            let code = await Diagnostics.runAll()
            if ProcessInfo.processInfo.environment["WECHATAI_SELFTEST_EXIT"] == "1" {
                exit(Int32(code))
            }
        }
    }

    /// Reads WeChat's bundle version off the main thread so it no longer blocks
    /// `AppStore.init`; the value is only a display fallback until `refreshStatus()`
    /// publishes the full hook status.
    private func prewarmWeChatVersion() {
        let path = store.settings.hook.wechatPath
        Task { [weak self] in
            let version = await Task.detached(priority: .utility) {
                AppStore.installedWeChatVersion(path: path) ?? ""
            }.value
            guard let self, !version.isEmpty, self.store.hookStatus.wechatVersion.isEmpty else { return }
            self.store.hookStatus.wechatVersion = version
        }
    }

    private func ensureFirstRunDefaults() async {
        var changed = false
        if store.providers.isEmpty {
            store.providers = [AppSettings.makeDefaultProvider()]
            changed = true
        }
        if store.personas.isEmpty {
            store.personas = [AppSettings.makeDefaultPersona()]
            changed = true
        }
        let providerIDs = Set(store.providers.map(\.id))
        let personaIDs = Set(store.personas.map(\.id))
        if store.settings.ai.defaultProviderID == nil || !providerIDs.contains(store.settings.ai.defaultProviderID ?? "") {
            store.settings.ai.defaultProviderID = store.settings.providers.first(where: \.isDefault)?.id
                ?? store.providers.first?.id
            changed = true
        }
        if store.settings.bot.defaultProviderID == nil || !providerIDs.contains(store.settings.bot.defaultProviderID ?? "") {
            store.settings.bot.defaultProviderID = store.settings.ai.defaultProviderID
            changed = true
        }
        if store.settings.bot.defaultPersonaID == nil || !personaIDs.contains(store.settings.bot.defaultPersonaID ?? "") {
            store.settings.bot.defaultPersonaID = store.personas.first(where: \.isDefault)?.id ?? store.personas.first?.id
            changed = true
        }
        let contextLimit = ChatEngine.shortTermMemoryLimit
        if store.settings.bot.maxContextMessages > contextLimit {
            store.settings.bot.maxContextMessages = contextLimit
            changed = true
        }
        if store.settings.bot.maxContextMessages < 2 {
            store.settings.bot.maxContextMessages = 2
            changed = true
        }
        // v1.1: 群聊触发方式不再提供“命令前缀”；旧配置迁移为关键词触发，
        // 并把原前缀作为关键词保留，避免升级后静默失效。
        if store.settings.bot.groupTrigger == .prefix {
            store.settings.bot.groupTrigger = .keyword
            let prefix = store.settings.bot.commandPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty,
               !store.settings.bot.keywords.contains(where: { $0.caseInsensitiveCompare(prefix) == .orderedSame }) {
                store.settings.bot.keywords.append(prefix)
            }
            changed = true
        }
        // v1.3: 温度改为按模型配置；把旧版按通道的温度一次性迁移到模型表。
        if store.settings.ai.modelTemperatures == nil {
            var seeded: [String: Double] = [:]
            for provider in store.providers {
                let model = AIClient.effectiveModel(for: provider)
                guard !model.isEmpty, seeded[model] == nil else { continue }
                seeded[model] = min(max(provider.temperature, 0), 2)
            }
            store.settings.ai.modelTemperatures = seeded
            changed = true
        }
        // v1.2: 群聊触发方式支持多选；旧版单选字段迁移为数组。
        if store.settings.bot.groupTriggers == nil {
            store.settings.bot.groupTriggers = store.settings.bot.effectiveGroupTriggers
            store.settings.bot.groupTrigger = store.settings.bot.groupTriggers?.first ?? .mention
            changed = true
        } else if store.settings.bot.groupTriggers?.isEmpty == true {
            store.settings.bot.groupTriggers = [.mention]
            store.settings.bot.groupTrigger = .mention
            changed = true
        } else if store.settings.bot.groupTriggers?.contains(.always) == true,
                  (store.settings.bot.groupTriggers?.count ?? 0) > 1 {
            // 「所有消息」与其它触发方式互斥。
            store.settings.bot.groupTriggers = [.always]
            store.settings.bot.groupTrigger = .always
            changed = true
        }
        // v1.4: 会话/用户四个白黑名单合并为两个统一列表（会话 ID 或用户 wxid）。
        if store.settings.bot.whitelistEntries == nil || store.settings.bot.blacklistEntries == nil {
            store.settings.bot.whitelistEntries = store.settings.bot.effectiveWhitelist
            store.settings.bot.blacklistEntries = store.settings.bot.effectiveBlacklist
            store.settings.bot.whitelistConversations = []
            store.settings.bot.blacklistConversations = []
            store.settings.bot.whitelistUsers = []
            store.settings.bot.blacklistUsers = []
            changed = true
        }
        store.settings.providers = store.providers
        store.settings.personas = store.personas
        if changed || !FileManager.default.fileExists(atPath: AppPaths.configFile.path) {
            store.persist()
        }
    }

    private func loadPersistedState() async {
        // selfID 必须最先读：历史数据修复需要用它识别「自己 wxid」会话，
        // 修复完成后再读取会话/消息，UI 打开时就是修正后的数据。
        if let id = try? await memory.setting(key: "onebot.self_id"), !id.isEmpty {
            selfID = id
        }
        // bridge get_login_info 写入的 selfID 是权威值：来源为 "login" 时修复直接信任它，
        // 不再从历史事件反推账号（反推要全表读取并逐行解析 raw_json，是大库启动主开销之一）。
        let source: String? = try? await memory.setting(key: Self.selfIDSourceKey)
        let trustedSelfID = source == Self.selfIDSourceLogin
        await repairSelfRoutingIfNeeded(trusted: trustedSelfID)
        await repairMisroutedConversationsIfNeeded(trusted: trustedSelfID)
        await repairConversationTitlesIfNeeded()
        // 两个全表文本迁移只在版本未达标时执行一次；任一失败则不写版本，下次启动重试。
        let repairedVersion = Int((try? await memory.setting(key: Self.dataRepairVersionKey)) ?? "") ?? 0
        if repairedVersion < Self.dataRepairVersion {
            let appmsgRepaired = await repairAppmsgTextsIfNeeded()
            let quotesRerendered = await rerenderLegacyQuoteTextsIfNeeded()
            if appmsgRepaired, quotesRerendered {
                try? await memory.setSetting(
                    key: Self.dataRepairVersionKey,
                    value: String(Self.dataRepairVersion)
                )
            }
        }
        // 语音：上次运行崩溃/退出时仍 pending 的转写不会再有人处理，统一标失败，
        // 气泡显示「重试」而不是永远「转写中」。
        if let interrupted = try? await memory.failInterruptedVoiceTranscripts(), interrupted > 0 {
            log(.debug, "Voice", "已将 \(interrupted) 条中断的语音转写标记为失败（可手动重试）")
        }

        do {
            store.conversations = try await memory.fetchConversations(limit: 300)
        } catch {
            log(.warning, "Database", "读取会话失败：\(error.localizedDescription)")
        }
        // 通讯录缓存要在会话加载之后应用：它只补占位标题，不覆盖用户重命名。
        await loadCachedContactDirectory()

        // Preload the newest page for the most recent conversations so the UI has
        // content immediately. One batched SQL query replaces the old N+1 pattern
        // (one `fetchMessages` round trip per conversation) and bounds the launch
        // work: 48 conversations × 30 messages instead of up to 300 × 30.
        let recentConversations = Array(store.conversations.prefix(Self.preloadedConversationLimit))
        if !recentConversations.isEmpty {
            if let preloaded = try? await memory.fetchLatestMessages(
                conversationIDs: recentConversations.map(\.id),
                perConversation: Self.preloadedMessagePageSize
            ) {
                store.messages = preloaded
            }
        }

        if let persistedLogs = try? await memory.fetchLogs(limit: 500) {
            // Merge with entries flushed while the database was opening (dedupe by id,
            // because the runtime log batch may already have written some of them).
            let live = store.logs
            var seen = Set(persistedLogs.map(\.id))
            var merged: [LogEntry] = persistedLogs.reversed().map { entry in
                var cleaned = entry
                cleaned.message = AnsiText.strip(cleaned.message)
                return cleaned
            }
            for entry in live where seen.insert(entry.id).inserted {
                merged.append(entry)
            }
            if merged.count > AppStore.logBufferLimit {
                merged.removeFirst(merged.count - AppStore.logBufferLimit)
            }
            store.replaceLogs(merged)
        }

        if let memories = try? await memory.fetchMemories(limit: 500) {
            store.longTermMemories = memories
        }

        // Schedules: settings JSON is canonical; DB is the crash-recovery mirror.
        if store.schedules.isEmpty, let dbSchedules = try? await memory.fetchSchedules(), !dbSchedules.isEmpty {
            store.schedules = dbSchedules
            store.settings.schedules = dbSchedules
            store.persist()
        } else {
            try? await memory.replaceSchedules(store.schedules)
        }

        scheduleSelfMentionBackfill()
        scheduleRemainingMessagePrefetch()
    }

    /// 修复旧 hook/App 把「自己发出的私聊消息」记进「自己 wxid」会话的历史数据。
    /// 幂等；selfID 为空时也能跑（内部会从历史事件反推账号）。
    /// - Parameter trusted: selfID 来自 bridge `get_login_info` 时为 `true`，
    ///   不再反推历史事件（避免启动时全表解析 raw_json）。
    private func repairSelfRoutingIfNeeded(trusted: Bool) async {
        guard let result = try? await memory.repairSelfRoutedMessages(
            selfID: selfID,
            trusted: trusted
        ) else { return }
        if let inferred = result.inferredSelfID, inferred != selfID {
            // 旧事件可能把 selfID 污染成好友 wxid；历史事件反推的账号更可信。
            selfID = inferred
            try? await memory.setSetting(key: "onebot.self_id", value: inferred)
            log(.warning, "Database", "self_id 已按历史事件自动校正为 \(inferred)")
            scheduleSelfMentionBackfill()
        }
        guard result.didChange else { return }
        log(.info, "Database", "已修复历史自消息归属：移动 \(result.movedMessages) 条，"
            + "影响 \(result.affectedConversationIDs.count) 个会话"
            + (result.removedSelfConversation ? "，删除「自己」会话" : ""))
    }

    /// 修复旧 hook 造成的「误归类会话」：自己 wxid 会话、`wxid_self` 占位会话、
    /// 以及 kind=group 但 ID 不是 `@chatroom` 的伪群会话。
    /// 只搬 `raw_json` 能明确推导目标的消息；幂等，selfID 为空时也能跑
    /// （内部会从历史事件反推账号）。
    /// - Parameter trusted: selfID 来自 bridge `get_login_info` 时为 `true`，
    ///   不再反推历史事件（避免启动时全表解析 raw_json）。
    private func repairMisroutedConversationsIfNeeded(trusted: Bool) async {
        guard let result = try? await memory.repairMisroutedConversations(
            selfID: selfID,
            trusted: trusted
        ), result.didChange else { return }
        var summary = "已修复历史误归类会话：移动 \(result.movedMessages) 条消息，"
            + "影响 \(result.affectedConversationIDs.count) 个会话"
        if result.fixedKinds > 0 {
            summary += "，修正 \(result.fixedKinds) 个会话类型"
        }
        if !result.removedConversationIDs.isEmpty {
            summary += "，删除 \(result.removedConversationIDs.count) 个空会话"
        }
        log(.info, "Database", summary)
    }

    /// 清理旧版本写入的裸 ID 标题（wxid / `xxx@chatroom` / 「群聊 <id>」）。
    /// 展示层本来就会忽略这类标题，这里让数据库也保持干净（AI 提示词、日志、导出都不再带 wxid）。
    private func repairConversationTitlesIfNeeded() async {
        guard let count = try? await memory.repairPlaceholderConversationTitles(), count > 0 else { return }
        log(.info, "Database", "已清理 \(count) 个会话的 ID 标题，改为可读名称")
    }

    /// 修复旧 hook 把引用回复 / 链接 / 文件等 appmsg 写成 `[链接/文件]` 的历史消息。
    /// 与实时事件的归一化共用 `WeChatAppmsg` 解析器；幂等，解析不出的消息保持原样。
    /// - Returns: 是否执行成功（失败时下次启动会重试这项一次性迁移）。
    private func repairAppmsgTextsIfNeeded() async -> Bool {
        do {
            let result = try await memory.repairAppmsgMessageTexts()
            guard result.didChange else { return true }
            log(.info, "Database", "已还原 \(result.repairedMessages) 条 appmsg 消息文本"
                + "（引用 / 链接 / 文件等，影响 \(result.affectedConversationIDs.count) 个会话）")
            return true
        } catch {
            log(.warning, "Database", "还原历史 appmsg 文本失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 把历史引用消息的展示定界符重排为 `【引用 发送者：原文】`（AI 更容易辨认）。
    /// 与实时解析共用 `WeChatAppmsg`；只处理 raw_json 可解析的引用 appmsg，幂等。
    /// - Returns: 是否执行成功（失败时下次启动会重试这项一次性迁移）。
    private func rerenderLegacyQuoteTextsIfNeeded() async -> Bool {
        do {
            let count = try await memory.rerenderLegacyQuoteTexts()
            guard count > 0 else { return true }
            log(.info, "Database", "已重排 \(count) 条引用消息的展示格式（【引用 …】定界符）")
            return true
        } catch {
            log(.warning, "Database", "重排历史引用消息失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 采纳 bridge `get_login_info` 返回的权威账号 wxid。
    private func adoptSelfID(_ raw: String) async {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        // 来源标记必须在 early-return 之前写：即使 id 与已有 selfID 相同（例如上次启动
        // 已从设置恢复），也要让下次启动知道这是 get_login_info 的权威值，从而跳过反推。
        try? await memory.setSetting(key: Self.selfIDSourceKey, value: Self.selfIDSourceLogin)
        guard id != selfID else { return }
        let previous = selfID
        selfID = id
        try? await memory.setSetting(key: "onebot.self_id", value: id)
        log(.info, "Bot", "已确认登录账号：\(id)")
        // selfID 从空/错误值变成正确值时，补跑一次修复并刷新 UI。
        // 这里的 selfID 来自 get_login_info，修复可以信任它、不再反推历史事件。
        var repaired = false
        if let result = try? await memory.repairSelfRoutedMessages(
            selfID: id,
            trusted: true
        ), result.didChange {
            log(.info, "Database", "已修复历史自消息归属：移动 \(result.movedMessages) 条，"
                + "影响 \(result.affectedConversationIDs.count) 个会话")
            repaired = true
        }
        if let result = try? await memory.repairMisroutedConversations(
            selfID: id,
            trusted: true
        ), result.didChange {
            var summary = "已修复历史误归类会话：移动 \(result.movedMessages) 条消息，"
                + "影响 \(result.affectedConversationIDs.count) 个会话"
            if result.fixedKinds > 0 {
                summary += "，修正 \(result.fixedKinds) 个会话类型"
            }
            if !result.removedConversationIDs.isEmpty {
                summary += "，删除 \(result.removedConversationIDs.count) 个空会话"
            }
            log(.info, "Database", summary)
            repaired = true
        }
        if repaired {
            await reloadConversationsAndMessages()
        }
        if previous != id {
            scheduleSelfMentionBackfill()
        }
    }

    /// 重新载入会话列表与首批消息（修复历史数据后调用）。
    private func reloadConversationsAndMessages() async {
        do {
            store.conversations = try await memory.fetchConversations(limit: 300)
        } catch {
            log(.warning, "Database", "重新读取会话失败：\(error.localizedDescription)")
        }
        let recent = Array(store.conversations.prefix(Self.preloadedConversationLimit))
        guard !recent.isEmpty else { return }
        if let preloaded = try? await memory.fetchLatestMessages(
            conversationIDs: recent.map(\.id),
            perConversation: Self.preloadedMessagePageSize
        ) {
            store.messages = preloaded
        }
    }

    /// Loads the message pages for conversations beyond the immediate preload window
    /// after first paint, in small batches. Keeps behaviour identical (every
    /// conversation still shows its newest page) without blocking launch on 300
    /// database round trips / one huge main-actor assignment.
    private func scheduleRemainingMessagePrefetch() {
        let remaining = store.conversations
            .dropFirst(Self.preloadedConversationLimit)
            .map(\.id)
        guard !remaining.isEmpty else { return }
        backgroundPrefetchTask?.cancel()
        backgroundPrefetchTask = Task { [weak self] in
            guard let self else { return }
            // Give the first frame + hook detection a chance to finish first.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            var index = 0
            while index < remaining.count, !Task.isCancelled {
                let upper = min(index + 32, remaining.count)
                let chunk = Array(remaining[index..<upper])
                if let page = try? await self.memory.fetchLatestMessages(
                    conversationIDs: chunk,
                    perConversation: Self.preloadedMessagePageSize
                ) {
                    for (conversationID, messages) in page
                    where self.store.messages[conversationID]?.isEmpty ?? true {
                        self.store.messages[conversationID] = messages
                    }
                }
                index = upper
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func loadStats() async {
        guard let text = try? await memory.setting(key: "stats.json"),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(BotStats.self, from: data) else { return }
        let storedDay = try? await memory.setting(key: "stats.day")
        statsDay = Self.dayKey()
        if storedDay == statsDay {
            store.stats = decoded
        } else {
            var fresh = BotStats.zero
            fresh.startedAt = decoded.startedAt
            store.stats = fresh
        }
        scheduleStatsPersist()
    }

    // MARK: Status

    func refreshStatus() async {
        hookManager.configure(wechatPath: store.settings.hook.wechatPath)
        let status = await hookManager.refresh()
        // Guard every assignment: re-assigning an equal value still invalidates
        // `@Observable` readers (Dashboard/Settings) and causes needless layout.
        if store.hookStatus != status { store.hookStatus = status }
        if store.gatewayConnected != status.gatewayConnected {
            store.gatewayConnected = status.gatewayConnected
        }
        if store.settings.hook.didInstallGadget != status.gadgetInstalled {
            store.settings.hook.didInstallGadget = status.gadgetInstalled
        }
        if let backup = hookManager.lastKnownBackupPath,
           store.settings.hook.lastBackupPath != backup {
            store.settings.hook.lastBackupPath = backup
        }
        // 只回写仓库自带的版本文件；运行期合并配置（Application Support/runtime）
        // 是 App 生成物，不能污染用户显式配置（否则切版本会错配）。
        if !status.versionConfigFile.isEmpty,
           let bundledDirectory = AppResources.versionConfigDirectory,
           status.versionConfigFile.hasPrefix(bundledDirectory.path),
           store.settings.hook.versionConfigPath != status.versionConfigFile {
            store.settings.hook.versionConfigPath = status.versionConfigFile
        }
        log(.debug, "Hook", "状态 \(status.state.label)：\(status.detail)")
    }

    // MARK: System vitals (battery + DeepSeek balance)

    /// 启动电量轮询与余额刷新。电量 30 秒一次（IOKit 同步读取，成本极低），
    /// 余额启动时查一次、之后每 5 分钟一次；手动刷新走 `refreshSystemVitals()`。
    private func startSystemVitalsMonitoring() {
        refreshBatteryStatus()
        systemVitalsTask = Task { [weak self] in
            await self?.refreshDeepSeekBalance()
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                self.refreshBatteryStatus()
                ticks += 1
                if ticks >= 10 {
                    ticks = 0
                    await self.refreshDeepSeekBalance()
                }
            }
        }
    }

    private func refreshBatteryStatus() {
        let status = BatteryReader.current()
        // 相等也赋值会无谓地让总览卡片失效（@Observable 不比较新旧值）。
        if store.batteryStatus != status { store.batteryStatus = status }
    }

    /// 总览「设备与账户」卡的手动刷新：电量立即重读，余额立即重查。
    func refreshSystemVitals() async {
        refreshBatteryStatus()
        await refreshDeepSeekBalance()
    }

    private func refreshDeepSeekBalance() async {
        guard !balanceRefreshInFlight else { return }
        guard let provider = DeepSeekProviderResolver.resolve(
            providers: store.providers,
            defaultProvider: store.defaultProvider
        ) else {
            setBalanceState(.unavailable("未配置 DeepSeek 通道"))
            return
        }
        guard provider.hasAPIKey else {
            setBalanceState(.unavailable("「\(provider.name)」尚未填写 API Key"))
            return
        }

        balanceRefreshInFlight = true
        store.isBalanceRefreshing = true
        defer {
            balanceRefreshInFlight = false
            store.isBalanceRefreshing = false
        }
        // 自动刷新时保留上一次金额，避免每 5 分钟闪一下加载态；首次查询才显示加载。
        if case .loaded = store.deepSeekBalance {
            // Keep the previous snapshot visible while refreshing.
        } else {
            setBalanceState(.loading)
        }

        // Keychain 读取放到后台线程：ad-hoc 重签后授权失效时，系统弹窗可能阻塞
        // 主线程数秒（见 AIClient.credentialState 的注释）。
        let reference = provider.apiKeyReference
        let keychainRead: (key: String?, error: String?) = await Task.detached(priority: .utility) {
            do {
                return (try KeychainStore.shared.apiKey(for: reference) ?? "", nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }.value

        if let readError = keychainRead.error {
            setBalanceState(.failed("读取钥匙串失败：\(readError)"))
            log(.warning, "System", "读取「\(provider.name)」API Key 失败：\(readError)")
            return
        }
        let key = (keychainRead.key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setBalanceState(.unavailable("「\(provider.name)」尚未填写 API Key"))
            return
        }

        do {
            let snapshot = try await deepSeekBalanceClient.fetch(apiKey: key, baseURL: provider.baseURL)
            setBalanceState(.loaded(snapshot))
            log(.debug, "System", "DeepSeek 余额已刷新：\(snapshot.primary?.displayTotal ?? "—")")
        } catch is CancellationError {
            // 退出/任务取消：保留当前展示，不标记为失败。
        } catch {
            setBalanceState(.failed(error.localizedDescription))
            log(.debug, "System", "DeepSeek 余额刷新失败：\(error.localizedDescription)")
        }
    }

    private func setBalanceState(_ state: DeepSeekBalanceState) {
        if store.deepSeekBalance != state { store.deepSeekBalance = state }
    }

    // MARK: Start / stop

    /// 4.1.15.55 / 4.2.0.5 使用 R3 原生文本发送（由 App 设置开启）；
    /// 4.1.12 及更早版本保持 legacy 发送路径，不做任何覆盖。
    /// 首次使用 R3 前需要在本机微信手动发一条消息以捕获发送句柄。
    /// 刷新 bridge `/voice_status`（登录稳定倒计时、文本/语音句柄、CdnManager）。
    /// 失败时保留可展示的错误状态，不抛给 UI。
    func refreshVoiceStatus() async {
        guard let client = oneBotClient else {
            var unavailable = VoiceRuntimeStatus.unavailable
            unavailable.error = "bridge 未运行"
            unavailable.receivedAt = Date()
            store.voiceRuntimeStatus = unavailable
            return
        }
        do {
            store.voiceRuntimeStatus = try await client.fetchVoiceStatus()
        } catch {
            var unavailable = VoiceRuntimeStatus.unavailable
            unavailable.error = error.localizedDescription
            unavailable.receivedAt = Date()
            store.voiceRuntimeStatus = unavailable
        }
    }

    private func nativeSendConfigOverrides() async -> [String: String] {
        let path = store.settings.hook.wechatPath
        let installation = await Task.detached(priority: .userInitiated) {
            WeChatInstallation.inspect(path: path)
        }.value
        let isR3Supported = NativeSendVersionSupport.supports(
            version: installation.version,
            build: installation.build
        )
        guard isR3Supported else { return [:] }
        if store.settings.hook.enableNativeSend {
            log(.info, "Hook", "微信 4.1.15.55 / 4.2.0.5：启用 R3 原生发送（首次使用前需在本机微信手动发一条消息以捕获发送句柄）")
            var overrides = [
                "enableSend": "true",
                "req2bufSendMode": "r3",
                "r3ClosureCapture": "true",
                "r3Slot13Capture": "true",
                "r3QueueUntilSeed": "true",
                // 2026-10-26 真机：官方 24k SILK 编码 + 上传/R3 发送已能正常播放。
                "r3VoiceSend": "true"
            ]
            return overrides
        } else {
            log(.warning, "Hook", "微信 4.1.15.55 / 4.2.0.5：R3 原生发送已关闭，主动发送不可用（接收不受影响）")
            return [
                "enableSend": "false",
                "req2bufSendMode": "off",
                "r3VoiceSend": "false"
            ]
        }
    }

    func startRuntime() async throws {
        await bootstrapIfNeeded()
        guard !store.isBotRunning, oneBotClient == nil else { return }

        guard let provider = store.settings.defaultProvider else { throw RuntimeError.noProvider }
        // Keychain 读取放到后台：签名变化时 macOS 可能弹授权框/阻塞调用线程，
        // 不能让主线程陪着卡住（旧实现实测卡 8s 后误报「缺少 API Key」）。
        let credentialState = await Task.detached(priority: .userInitiated) { [aiClient, provider] in
            aiClient.credentialState(for: provider)
        }.value
        switch credentialState {
        case .available:
            break
        case .missing:
            throw RuntimeError.providerNotConfigured(provider.name)
        case .unreadable(let status):
            log(.error, "AI", "Keychain 读取 API Key 失败（OSStatus \(status)）：app 签名变化后授权失效，需在「钥匙串访问」删除 \(AppPaths.bundleID) 条目并重新填写")
            throw RuntimeError.providerCredentialUnreadable(provider.name, status)
        }

        var token = store.settings.onebot.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            token = Self.randomToken()
            store.settings.onebot.token = token
            store.persist()
        }

        if store.settings.hook.autoStartBridge {
            let overrides = await nativeSendConfigOverrides()
            do {
                try await hookManager.startBridge(
                    host: store.settings.onebot.host,
                    port: store.settings.onebot.port,
                    token: token,
                    gadgetPort: store.settings.hook.gadgetPort,
                    explicitVersionConfigPath: store.settings.hook.versionConfigPath,
                    explicitImagePath: store.settings.onebot.imagePath,
                    selfID: selfID,
                    configOverrides: overrides
                )
            } catch {
                hookManager.stopBridge()
                throw error
            }
        } else {
            log(.info, "Bot", "未启用自动启动 bridge，等待外部 bridge 提供 \(store.settings.onebot.host):\(store.settings.onebot.port)")
        }

        let configuration = OneBotClient.Configuration(
            host: store.settings.onebot.host,
            port: store.settings.onebot.port,
            token: token
        )
        let client = OneBotClient(configuration: configuration)
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handle(event: event)
            }
        }
        client.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleOneBotState(state)
            }
        }
        client.onLog = { [weak self] level, message in
            Task { @MainActor [weak self] in
                self?.log(level, "OneBot", message)
            }
        }
        client.onLoginInfo = { [weak self] userID in
            Task { @MainActor [weak self] in
                await self?.adoptSelfID(userID)
            }
        }
        client.onContactDirectory = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                await self?.handleContactDirectory(snapshot)
            }
        }
        oneBotClient = client
        startedOneBotConfiguration = configuration
        await refreshVoiceStatus()
        store.imageFetcher.configure(
            fetch: { [weak self] bridgeMessageID in
                guard let client = self?.oneBotClient else { throw OneBotError.notRunning }
                return try await client.fetchImage(messageID: bridgeMessageID)
            },
            onFetched: { [weak self] request, path in
                await self?.applyFetchedImage(request: request, path: path)
            },
            onFailed: { [weak self] request, reason in
                // 失败只记 debug，避免网络/图片异常时刷屏；不重试由队列保证。
                self?.pendingImageFetchIDs.remove(request.chatMessageID)
                self?.log(.debug, "Media", "图片获取失败（\(request.chatMessageID)）：\(reason)")
            }
        )
        store.voiceFetcher.configure(
            fetch: { [weak self] bridgeMessageID in
                guard let client = self?.oneBotClient else { throw OneBotError.notRunning }
                let payload = try await client.fetchVoice(messageID: bridgeMessageID)
                return VoiceFetchResult(
                    path: payload.path,
                    silkPath: payload.silkPath,
                    durationMs: payload.durationMs
                )
            },
            onFetched: { [weak self] request, result in
                await self?.applyFetchedVoice(request: request, result: result)
            },
            onFailed: { [weak self] request, reason in
                // bridge 侧失败通常是音频未下载/SILK 解码失败；只记 debug，气泡转「重试」。
                self?.handleVoiceFetchFailure(request: request, reason: reason)
            }
        )
        lastVoiceTranscriptionEnabled = store.settings.bot.voiceTranscriptionEnabled
        client.start()

        ruleEngine.resetThrottles()
        let normalizedSchedules = SchedulerService.normalize(store.schedules)
        store.schedules = normalizedSchedules
        store.settings.schedules = normalizedSchedules
        lastSchedulerTasks = normalizedSchedules
        try? await memory.replaceSchedules(normalizedSchedules)
        await scheduler.setHandlers(
            onFire: { [weak self] task in
                await self?.fireScheduledTask(task)
            },
            onChange: { [weak self] tasks in
                Task { @MainActor [weak self] in
                    self?.schedulesDidChange(tasks)
                }
            }
        )
        await scheduler.start(tasks: normalizedSchedules)

        store.stats.startedAt = Date()
        scheduleStatsPersist()
        log(.info, "Bot", "机器人运行时已启动（\(configuration.host):\(configuration.port)）")
    }

    func stopRuntime() async {
        oneBotClient?.stop()
        oneBotClient = nil
        startedOneBotConfiguration = nil
        inFlightConversations.removeAll()
        clearReplyProgresses()
        store.imageFetcher.cancelAll()
        pendingImageFetchIDs.removeAll()
        visionAttempted.removeAll()
        store.voiceFetcher.cancelAll()
        pendingVoiceFetchIDs.removeAll()
        pendingVoiceTranscriptionIDs.removeAll()
        voiceTranscriptionAttempted.removeAll()
        lastVoiceTranscriptionEnabled = nil
        await scheduler.stop()
        if store.settings.hook.autoStartBridge {
            hookManager.stopBridge()
        }
        log(.info, "Bot", "机器人运行时已停止")
        // Flush coalesced logs (UI + SQLite) before the runtime goes idle.
        await LogPipeline.shared.flushNow()
        await persistStats()
        await SettingsPersistence.shared.flush()
    }

    // MARK: OneBot state / events

    private func handleOneBotState(_ state: OneBotConnectionState) {
        // `setGatewayConnected` publishes through `HookManager.onStatusChange`, which is
        // equality-guarded in `init`; no need to write each field separately here.
        switch state {
        case .connected:
            hookManager.setGatewayConnected(true)
            log(.info, "OneBot", "WebSocket 已连接")
        case .connecting:
            hookManager.setGatewayConnected(false, detail: "正在连接 bridge…")
            log(.debug, "OneBot", "正在连接…")
        case .reconnecting:
            hookManager.setGatewayConnected(false, detail: "连接断开，自动重连中…")
            log(.warning, "OneBot", "连接断开，正在自动重连")
        case .stopped:
            hookManager.setGatewayConnected(false, detail: "已停止")
        }
    }

    // MARK: Contact directory

    /// 启动时恢复上次成功的通讯录目录，并立即把缓存名落到占位标题的会话上。
    /// 缓存不存在/损坏时静默跳过：读不到目录时行为与现在完全一致。
    private func loadCachedContactDirectory() async {
        guard let cached = try? await memory.loadContactDirectory(), cached.ok else { return }
        contactDirectory = cached
        log(.debug, "Directory", "已加载通讯录缓存：\(cached.users.count) 位联系人 / \(cached.groups.count) 个群")
        await applyContactDirectoryToConversationTitles()
    }

    /// 收到 bridge 目录快照。成功时更新内存/DB 缓存并补会话标题；
    /// 失败时只记一条去重日志（同一 reason 不重复刷屏），消息链路完全不受影响。
    private func handleContactDirectory(_ snapshot: ContactDirectorySnapshot) async {
        guard snapshot.ok else {
            let reason = snapshot.reason ?? "unknown"
            guard lastContactDirectoryFailureReason != reason else { return }
            lastContactDirectoryFailureReason = reason
            log(.debug, "Directory", "通讯录目录暂不可用（\(reason)），继续使用兜底名称")
            return
        }
        lastContactDirectoryFailureReason = nil
        guard contactDirectory != snapshot else { return }
        let isFirstSnapshot = contactDirectory?.ok != true
        contactDirectory = snapshot
        do {
            try await memory.replaceContactDirectory(snapshot)
        } catch {
            log(.warning, "Database", "写入通讯录目录缓存失败：\(error.localizedDescription)")
        }
        let summary = "\(snapshot.users.count) 位联系人 / \(snapshot.groups.count) 个群"
        if isFirstSnapshot {
            log(.info, "Directory", "已获取通讯录：\(summary)")
        } else {
            log(.debug, "Directory", "通讯录目录已刷新：\(summary)")
        }
        await applyContactDirectoryToConversationTitles()
    }

    /// 只给标题为空/占位（`ConversationName.isPlaceholderTitle`）的会话补目录名。
    /// 用户重命名后（非占位标题）绝不覆盖；目录缺失/失败时什么都不做。
    private func applyContactDirectoryToConversationTitles() async {
        guard let directory = contactDirectory, directory.ok else { return }
        let resolved = ContactDirectoryTitles.updatedConversations(store.conversations, directory: directory)
        guard !resolved.isEmpty else { return }
        let names = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0.title) })

        // 先同步更新内存（UI 立即可见），再 await 持久化；期间事件可能改动会话列表，
        // 因此以「当前列表 + 仍是占位标题」为准逐个应用，绝不整体覆盖。
        var conversations = store.conversations
        var changed: [Conversation] = []
        for index in conversations.indices {
            let id = conversations[index].id
            guard let name = names[id],
                  ConversationName.isPlaceholderTitle(
                      conversations[index].title,
                      conversationID: id,
                      kind: conversations[index].kind
                  ) else { continue }
            conversations[index].title = name
            changed.append(conversations[index])
        }
        guard !changed.isEmpty else { return }
        store.conversations = conversations

        do {
            try await memory.upsertConversations(changed)
            log(.info, "Directory", "已用通讯录名称补齐 \(changed.count) 个会话标题")
        } catch {
            log(.warning, "Database", "写入通讯录会话标题失败：\(error.localizedDescription)")
        }
    }

    private func handle(event: OneBotEvent) async {
        let conversationID = event.conversationID
        guard !conversationID.isEmpty else { return }
        let receivedAt = Date()
        rolloverStatsIfNeeded()

        // 当前账号的权威来源是 bridge get_login_info（onLoginInfo）。只有在还没有
        // 任何 selfID 时才用事件兜底；否则错误/测试事件的 self_id 会覆盖真实账号，
        // 进而让拍一拍目标比对、自消息判定全部失效（2026-10-21 真机问题）。
        if selfID.isEmpty,
           !event.selfID.isEmpty,
           event.selfID != event.groupID,
           // 旧 bridge 的自消息可能把 self_id 写成对方 wxid；不要把它学成自己。
           !store.conversations.contains(where: { $0.id == event.selfID && $0.kind == .direct }) {
            selfID = event.selfID
            try? await memory.setSetting(key: "onebot.self_id", value: selfID)
        }
        learnMentionNameIfNeeded(from: event)

        // Local outgoing echo: mark the optimistic message as sent instead of duplicating.
        if event.isSelf && event.isEchoOfLocal && markLocalEchoSent(event) {
            log(.debug, "Bot", "已确认自己消息送达：\(conversationID)")
            return
        }

        let conversation = upsertConversation(for: event)
        // 历史回放/补同步的语音不自动下载转写：直接标失败（气泡可手动重试），
        // 避免打开旧会话时对旧语音批量发请求。
        let isStaleReplay = receivedAt.timeIntervalSince(event.timestamp) > Self.staleReplyWindow
        let chatMessage = makeChatMessage(
            from: event,
            conversation: conversation,
            isStaleReplay: isStaleReplay
        )

        var list = store.messages[conversationID] ?? []
        if list.contains(where: { $0.id == chatMessage.id }) { return }
        list.append(chatMessage)
        // Inbound events are ordered by arrival; only sort when a late/out-of-order
        // timestamp actually requires it (the previous code sorted on every message).
        if list.count > 1, list[list.count - 2].timestamp > chatMessage.timestamp {
            list.sort { $0.timestamp < $1.timestamp }
        }
        if list.count > 300 { list.removeFirst(list.count - 300) }
        store.messages[conversationID] = list

        do {
            // Conversation metadata + message in one SQLite transaction (was two).
            try await memory.upsertConversationAndMessages(conversation, [chatMessage])
        } catch {
            log(.warning, "Database", "写入消息失败：\(error.localizedDescription)")
        }

        // 图片获取与自动回复共用同一个「历史回放」门禁：只处理实时入站图片。
        scheduleImageFetchIfNeeded(
            event: event,
            message: chatMessage,
            conversation: conversation,
            receivedAt: receivedAt
        )
        // 入站语音：先向 bridge 取 16k WAV，再走本地转写；开关按会话生效值。
        scheduleVoiceFetchIfNeeded(
            event: event,
            message: chatMessage,
            conversation: conversation,
            receivedAt: receivedAt
        )

        if !event.isSelf {
            store.stats.receivedToday += 1
            scheduleStatsPersist()
        }

        let preview = chatMessage.text.isEmpty ? "[\(chatMessage.kind.rawValue)]" : String(chatMessage.text.prefix(80))
        log(.debug, "Bot", "\(event.isSelf ? "发出" : "收到") \(conversation.kind.label)消息（\(conversation.displayTitle)）：\(preview)")

        guard !event.isSelf else {
            scheduleMemoryMaintenance(conversationID: conversationID)
            return
        }
        // 历史回放会把很旧的消息重新投递（例如打开聊天时加载历史），
        // 这些消息仍入库供检索，但不应触发一次「现在」的自动回复。
        let age = receivedAt.timeIntervalSince(event.timestamp)
        guard age <= Self.staleReplyWindow else {
            log(.debug, "Bot", "跳过历史消息自动回复（\(Int(age)) 秒前）：\(preview)")
            scheduleMemoryMaintenance(conversationID: conversationID)
            return
        }
        // 语音消息：自动回复必须等转写完成（≤15s）；超时按「转写失败」继续回复，
        // 不丢消息。用最新消息副本做规则判定，关键词触发才能看到转写文本。
        var replyMessage = chatMessage
        if chatMessage.kind == .voice, voiceTranscriptionEnabled(for: conversation) {
            replyMessage = await waitForVoiceReplyMessage(
                conversationID: conversationID,
                messageID: chatMessage.id,
                fallback: chatMessage
            )
        }
        await evaluateAndReply(conversation: conversation, message: replyMessage, receivedAt: receivedAt)
        scheduleMemoryMaintenance(conversationID: conversationID)
    }

    private func upsertConversation(for event: OneBotEvent) -> Conversation {
        let existingIndex = store.conversations.firstIndex { $0.id == event.conversationID }
        // 目录名比事件里的 sender.nickname 更权威；只在标题仍是占位值时使用。
        let directoryTitle = ContactDirectoryTitles.title(
            for: event.conversationID,
            kind: event.conversationKind,
            in: contactDirectory
        )
        var conversation: Conversation
        if let index = existingIndex {
            conversation = store.conversations[index]
            if let directoryTitle,
               ConversationName.isPlaceholderTitle(
                   conversation.title,
                   conversationID: conversation.id,
                   kind: conversation.kind
               ) {
                conversation.title = directoryTitle
            }
        } else {
            // 新建会话时目录已有名字就直接写入，避免先闪一下兜底名；
            // 没有目录时标题留空，交给展示层兜底（微信只下发 wxid）。
            conversation = Conversation(
                id: event.conversationID,
                kind: event.conversationKind,
                title: directoryTitle ?? ""
            )
        }
        let learnedName = ConversationName.learnedSenderName(
            event.senderName,
            conversationID: event.conversationID,
            senderID: event.userID,
            selfID: selfID
        )
        if event.isGroup {
            // 群名不在事件里，只更新「最近发言人」副标题，且拒绝 wxid。
            if !event.isSelf, let learnedName { conversation.subtitle = learnedName }
        } else if !event.isSelf,
                  ConversationName.isPlaceholderTitle(
                    conversation.title,
                    conversationID: conversation.id,
                    kind: conversation.kind
                  ),
                  let learnedName {
            // 只有标题还是占位值时才学习昵称：用户重命名后不会被后续消息覆盖。
            conversation.title = learnedName
        }
        // 历史回放/补同步会带来很旧的 timestamp：不能让会话预览与排序倒退，
        // 也不能把旧消息算成未读。只有比当前记录更新的事件才推进预览。
        let previousLast = conversation.lastMessageAt
        let isNewest = previousLast == nil || event.timestamp > previousLast!
        if isNewest {
            conversation.lastMessageAt = event.timestamp
            conversation.lastMessagePreview = String(event.plainText.prefix(80))
        }
        // 正在查看的会话不累计未读：打开即已读，避免切换会话后还要额外点一次。
        if !event.isSelf, isNewest, store.selectedConversationID != event.conversationID {
            conversation.unreadCount += 1
        }

        if let index = existingIndex {
            var conversations = store.conversations
            conversations[index] = conversation
            store.conversations = Self.ordered(conversations, moving: index)
        } else {
            var conversations = store.conversations
            conversations.append(conversation)
            store.conversations = Self.ordered(conversations, moving: conversations.count - 1)
        }
        return conversation
    }

    /// Orders conversations by "pinned first, then newest activity" while moving only
    /// the mutated element. Replaces a full `sort` (and its comparator churn) on every
    /// inbound message with one array assignment.
    private static func ordered(_ conversations: [Conversation], moving index: Int) -> [Conversation] {
        guard conversations.indices.contains(index) else { return conversations }
        let item = conversations[index]
        var rest = conversations
        rest.remove(at: index)
        let insertion = rest.firstIndex { other in
            if item.isPinned != other.isPinned { return item.isPinned && !other.isPinned }
            return (item.lastMessageAt ?? .distantPast) > (other.lastMessageAt ?? .distantPast)
        } ?? rest.count
        guard insertion != index else { return conversations }
        rest.insert(item, at: insertion)
        return rest
    }

    private func makeChatMessage(
        from event: OneBotEvent,
        conversation: Conversation,
        isStaleReplay: Bool = false
    ) -> ChatMessage {
        let id = event.messageID.isEmpty ? "ob-\(UUID().uuidString)" : "ob-\(event.messageID)"
        let kind = event.primaryMessageKind
        var message = ChatMessage(
            id: id,
            conversationID: event.conversationID,
            senderID: event.isSelf ? (event.selfID.isEmpty ? "self" : event.selfID) : event.userID,
            senderName: event.isSelf ? "我" : event.senderName,
            direction: event.isSelf ? .outgoing : .incoming,
            kind: kind,
            text: event.plainText,
            mediaPath: event.mediaPath,
            mediaURL: event.primaryMediaSegment?.url,
            timestamp: event.timestamp,
            status: event.isSelf ? .sent : .received,
            replyToID: nil,
            rawJSON: event.rawJSON
        )
        if kind == .voice {
            // 语音时长来自 bridge 段（可能为空）；转写状态先置 pending，
            // 关闭转写时直接 disabled，气泡不显示「转写中」。
            message.voiceDurationMs = event.voiceDurationMs
            let enabled = voiceTranscriptionEnabled(for: conversation)
            // 自己发出的语音不转写（不触发自动回复，也没有上下文价值）；
            // 历史回放的语音不自动下载，标失败让用户可在气泡里手动重试。
            if !event.isSelf, enabled, !isStaleReplay {
                message.voiceTranscriptState = .pending
            } else {
                message.voiceTranscriptState = .disabled
            }
        }
        return message
    }

    // MARK: 入站图片获取

    /// 消息入库后决定是否向 bridge 请求图片。门槛见 `ImageFetchPolicy`，另加
    /// 与自动回复相同的历史回放门禁：只处理实时入站图片，打开旧会话重放历史
    /// 图片时不触发批量下载。「是否获取」按会话生效值：会话覆盖 → 旧全局默认 → true。
    private func scheduleImageFetchIfNeeded(
        event: OneBotEvent,
        message: ChatMessage,
        conversation: Conversation,
        receivedAt: Date
    ) {
        guard receivedAt.timeIntervalSince(event.timestamp) <= Self.staleReplyWindow else { return }
        guard ImageFetchPolicy.shouldFetch(
            kind: message.kind,
            enabled: conversation.effectiveImageFetchEnabled(
                global: store.settings.bot.fetchImagesEnabled
            ),
            isSelf: event.isSelf,
            messageID: event.messageID,
            mediaPath: message.mediaPath,
            mediaURL: message.mediaURL
        ) else { return }

        let request = ImageFetcher.Request(
            bridgeMessageID: event.messageID,
            chatMessageID: message.id,
            conversationID: event.conversationID
        )
        guard store.imageFetcher.enqueue(request) else { return }
        pendingImageFetchIDs.insert(message.id)
        // 只记 message_id 尾号，不打印 XML / key / 完整 ID。
        let suffix = event.messageID.count > 6 ? String(event.messageID.suffix(6)) : event.messageID
        log(.debug, "Media", "已排队获取图片（\(event.conversationID)，message_id 尾号 \(suffix)）")
    }

    /// 图片获取成功：更新该消息的 `mediaPath` 并写库，气泡随即显示图片。
    /// 消息可能已被内存裁剪/会话已删除：此时跳过内存更新，仍按 ID 从库里补写。
    private func applyFetchedImage(request: ImageFetcher.Request, path: String) async {
        pendingImageFetchIDs.remove(request.chatMessageID)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }

        var updated: ChatMessage?
        if var list = store.messages[request.conversationID],
           let index = list.firstIndex(where: { $0.id == request.chatMessageID }) {
            list[index].mediaPath = trimmedPath
            store.messages[request.conversationID] = list
            updated = list[index]
        } else if var stored = try? await memory.message(id: request.chatMessageID) {
            stored.mediaPath = trimmedPath
            updated = stored
        }
        guard let updated else {
            log(.debug, "Media", "图片已获取，但消息已不存在，跳过更新（\(request.chatMessageID)）")
            return
        }
        do {
            try await memory.upsertMessages([updated])
        } catch {
            log(.warning, "Database", "写入图片路径失败：\(error.localizedDescription)")
        }
        let title = store.conversations.first(where: { $0.id == request.conversationID })?.displayTitle
            ?? request.conversationID
        log(.info, "Media", "已获取图片：\(title)（\(URL(fileURLWithPath: trimmedPath).lastPathComponent)）")
    }

    // MARK: 入站语音（获取 + 本地转写，2026-10-26）

    /// 自动回复等待语音转写完成的预算（spec §2.3：≤15s，超时按转写失败继续）。
    private static let voiceTranscriptionWait: TimeInterval = 15

    /// 该会话生效的语音转写开关：会话覆盖 → 全局设置。
    private func voiceTranscriptionEnabled(for conversation: Conversation) -> Bool {
        conversation.effectiveVoiceTranscriptionEnabled(
            global: store.settings.bot.voiceTranscriptionEnabled
        )
    }

    /// 按会话 ID 取生效的语音转写开关；会话已删除/未加载时退回全局设置。
    private func voiceTranscriptionEnabled(conversationID: String) -> Bool {
        guard let conversation = store.conversations.first(where: { $0.id == conversationID }) else {
            return store.settings.bot.voiceTranscriptionEnabled
        }
        return voiceTranscriptionEnabled(for: conversation)
    }

    /// 消息入库后决定是否向 bridge 请求语音音频。门槛见 `VoiceFetchPolicy`：
    /// 该会话生效的转写开关、非自消息、kind=voice、无本地音频、message_id 非空；
    /// 另加与自动回复相同的历史回放门禁（打开旧会话重放历史不触发批量下载）。
    private func scheduleVoiceFetchIfNeeded(
        event: OneBotEvent,
        message: ChatMessage,
        conversation: Conversation,
        receivedAt: Date
    ) {
        guard receivedAt.timeIntervalSince(event.timestamp) <= Self.staleReplyWindow else { return }
        let enabled = voiceTranscriptionEnabled(for: conversation)
        guard VoiceFetchPolicy.shouldFetch(
            kind: message.kind,
            enabled: enabled,
            isSelf: event.isSelf,
            messageID: event.messageID,
            voiceMediaPath: message.voiceMediaPath,
            mediaPath: message.mediaPath
        ) else { return }

        let request = VoiceFetcher.Request(
            bridgeMessageID: event.messageID,
            chatMessageID: message.id,
            conversationID: event.conversationID
        )
        guard store.voiceFetcher.enqueue(request) else { return }
        pendingVoiceFetchIDs.insert(message.id)
        pendingVoiceTranscriptionIDs.insert(message.id)
        // 只记 message_id 尾号，不打印 XML / aeskey / CDN key。
        let suffix = event.messageID.count > 6 ? String(event.messageID.suffix(6)) : event.messageID
        log(.debug, "Media", "已排队获取语音（\(event.conversationID)，message_id 尾号 \(suffix)）")
    }

    /// 语音获取成功：写入 16k WAV 路径与时长并落库，随后在独立任务里转写，
    /// 不阻塞 `VoiceFetcher` 队列（下一条语音可以继续下载）。
    private func applyFetchedVoice(request: VoiceFetcher.Request, result: VoiceFetchResult) async {
        pendingVoiceFetchIDs.remove(request.chatMessageID)
        let path = result.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            pendingVoiceTranscriptionIDs.remove(request.chatMessageID)
            log(.debug, "Media", "语音获取返回空路径（\(request.chatMessageID)）")
            _ = await updateVoiceMessage(
                conversationID: request.conversationID,
                messageID: request.chatMessageID
            ) { $0.voiceTranscriptState = .failed }
            return
        }

        let updated = await updateVoiceMessage(
            conversationID: request.conversationID,
            messageID: request.chatMessageID
        ) { message in
            message.voiceMediaPath = path
            message.mediaPath = path
            if let duration = result.durationMs, duration > 0 {
                message.voiceDurationMs = duration
            }
            if message.voiceTranscriptState == .done { message.voiceTranscriptState = .pending }
        }
        guard updated != nil else {
            log(.debug, "Media", "语音已获取，但消息已不存在，跳过转写（\(request.chatMessageID)）")
            pendingVoiceTranscriptionIDs.remove(request.chatMessageID)
            return
        }
        let title = store.conversations.first(where: { $0.id == request.conversationID })?.displayTitle
            ?? request.conversationID
        let milliseconds = result.durationMs ?? 0
        log(.info, "Media", "已获取语音：\(title)（\(URL(fileURLWithPath: path).lastPathComponent)，\(milliseconds)ms）")
        Task { [weak self] in
            await self?.transcribeVoiceMessage(
                conversationID: request.conversationID,
                messageID: request.chatMessageID
            )
        }
    }

    /// 语音获取失败（含队列内重试后仍失败）：气泡显示「转写失败 · 重试」。
    /// 只记 debug 日志，不影响自动回复（等待方会按失败继续）。
    private func handleVoiceFetchFailure(request: VoiceFetcher.Request, reason: String) {
        pendingVoiceFetchIDs.remove(request.chatMessageID)
        pendingVoiceTranscriptionIDs.remove(request.chatMessageID)
        log(.debug, "Media", "语音获取失败（\(request.chatMessageID)）：\(reason)")
        Task { [weak self] in
            _ = await self?.updateVoiceMessage(
                conversationID: request.conversationID,
                messageID: request.chatMessageID
            ) { $0.voiceTranscriptState = .failed }
        }
    }

    /// 本地转写一条已落盘的语音。
    ///
    /// - `force == false` 时同一消息在本次运行内最多尝试一次（避免重复付费/重复识别）；
    /// - 失败/静音/资源未安装都写入状态并落库，气泡可重试；
    /// - 日志只写字数、置信度、时长，**不打印转写原文**。
    private func transcribeVoiceMessage(
        conversationID: String,
        messageID: String,
        force: Bool = false
    ) async {
        guard let message = await voiceMessage(conversationID: conversationID, messageID: messageID) else {
            pendingVoiceTranscriptionIDs.remove(messageID)
            return
        }
        guard message.kind == .voice else {
            pendingVoiceTranscriptionIDs.remove(messageID)
            return
        }
        if !force, voiceTranscriptionAttempted.contains(messageID) {
            pendingVoiceTranscriptionIDs.remove(messageID)
            return
        }
        let conversation = store.conversations.first(where: { $0.id == conversationID })
        let enabled = conversation?.effectiveVoiceTranscriptionEnabled(
            global: store.settings.bot.voiceTranscriptionEnabled
        ) ?? store.settings.bot.voiceTranscriptionEnabled
        guard enabled else {
            pendingVoiceTranscriptionIDs.remove(messageID)
            _ = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
                $0.voiceTranscriptState = .disabled
            }
            return
        }
        guard let path = message.voiceMediaPath ?? message.mediaPath, !path.isEmpty else {
            pendingVoiceTranscriptionIDs.remove(messageID)
            _ = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
                $0.voiceTranscriptState = .failed
            }
            return
        }

        voiceTranscriptionAttempted.insert(messageID)
        pendingVoiceTranscriptionIDs.insert(messageID)
        if message.voiceTranscriptState != .pending {
            _ = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
                $0.voiceTranscriptState = .pending
            }
        }
        do {
            let transcription = try await store.voiceTranscription.transcribe(
                fileURL: URL(fileURLWithPath: path)
            )
            await applyVoiceTranscription(
                conversationID: conversationID,
                messageID: messageID,
                transcription: transcription
            )
        } catch {
            let errorText = (error as? VoiceTranscriptionError)?.errorDescription
                ?? error.localizedDescription
            _ = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
                $0.voiceTranscriptState = .failed
            }
            let title = conversation?.displayTitle ?? conversationID
            if let voiceError = error as? VoiceTranscriptionError, voiceError.isAssetUnavailable {
                log(.warning, "Voice", "语音转写不可用（\(title)）：\(errorText)；"
                    + "可在「机器人 → 语音」或「设置 → 语音」直接下载中文语音资源")
            } else {
                log(.warning, "Voice", "语音转写失败（\(title)）：\(errorText)")
            }
        }
        pendingVoiceTranscriptionIDs.remove(messageID)
    }

    /// 把转写结果写回消息：文本、置信度、状态、时长；成功时把转写写入 `text`
    /// （记忆总结/搜索使用 `text`；长期总结是否使用由 `saveTranscriptToMemory` 控制）。
    private func applyVoiceTranscription(
        conversationID: String,
        messageID: String,
        transcription: VoiceTranscription
    ) async {
        let trimmed = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) { message in
            message.voiceTranscript = trimmed
            message.voiceTranscriptConfidence = transcription.maxConfidence
            message.voiceTranscriptState = .done
            if transcription.duration > 0 {
                message.voiceDurationMs = Int((transcription.duration * 1000).rounded())
            }
            // 转写写入 `text` 才会进入消息搜索与长期记忆总结；关闭该设置时只保留
            // 独立字段，气泡/AI 即时上下文仍可用，但不沉淀进记忆库。
            if store.settings.bot.voiceSettings.saveTranscriptToMemory {
                message.text = trimmed
            }
        }
        guard updated != nil else { return }
        let title = store.conversations.first(where: { $0.id == conversationID })?.displayTitle
            ?? conversationID
        log(.info, "Voice", "已转写语音：\(title)（\(trimmed.count) 字，"
            + "置信度 \(String(format: "%.2f", transcription.maxConfidence))，"
            + "\(String(format: "%.1f", transcription.duration))s）")
    }

    /// 等待一条语音的转写结果，最多 `voiceTranscriptionWait` 秒。
    ///
    /// 成功/失败/关闭都会立即返回最新消息；超时把状态标记为 failed 后返回
    /// （自动回复继续，上下文用 `[语音，转写失败]`，不丢消息）。
    private func waitForVoiceReplyMessage(
        conversationID: String,
        messageID: String,
        fallback: ChatMessage
    ) async -> ChatMessage {
        let deadline = Date().addingTimeInterval(Self.voiceTranscriptionWait)
        while !Task.isCancelled {
            if let message = store.messages[conversationID]?.first(where: { $0.id == messageID }) {
                switch message.voiceTranscriptState {
                case .done, .failed, .disabled, .none:
                    return message
                case .pending:
                    break
                }
            } else if !pendingVoiceFetchIDs.contains(messageID),
                      !pendingVoiceTranscriptionIDs.contains(messageID) {
                return fallback
            }
            guard Date() < deadline else {
                pendingVoiceFetchIDs.remove(messageID)
                pendingVoiceTranscriptionIDs.remove(messageID)
                let timedOut = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
                    $0.voiceTranscriptState = .failed
                }
                let title = store.conversations.first(where: { $0.id == conversationID })?.displayTitle
                    ?? conversationID
                log(.warning, "Voice", "语音转写在 \(Int(Self.voiceTranscriptionWait))s 内未完成，"
                    + "按转写失败继续回复（\(title)）")
                return timedOut ?? fallback
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return fallback
    }

    /// 引用语音时附加的转写说明（与引用图片 `prepareQuotedImageNote` 同构）。
    ///
    /// 微信引用只带 `svrid`（与 `ChatMessage.id` 的 `ob-<id>` 精确对应）和摘要
    /// `[语音]`。按 svrid 找回原语音：已有转写直接复用；没有转写但有本地音频时
    /// 现场转写一次（用户明确引用了它，不受 15s 自动回复预算限制）；仍拿不到就
    /// 明确告诉模型「暂不可用」，避免编造内容。
    private func prepareQuotedVoiceNote(conversation: Conversation, incoming: ChatMessage) async -> String? {
        guard let quote = WeChatAppmsg.parse(eventJSON: incoming.rawJSON)?.quote,
              quote.messageType == 34 || quote.snippet.trimmingCharacters(in: .whitespacesAndNewlines) == "[语音]"
        else { return nil }

        var referenced: ChatMessage?
        if let voiceID = quote.imageMessageID {
            referenced = store.messages[conversation.id]?.first(where: { $0.id == voiceID })
            if referenced == nil {
                referenced = try? await memory.message(id: voiceID)
            }
        }

        var transcript = referenced.flatMap(ChatEngine.normalizedVoiceTranscript)
        if transcript == nil,
           let referenced,
           let path = referenced.voiceMediaPath ?? referenced.mediaPath,
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            await transcribeVoiceMessage(
                conversationID: conversation.id,
                messageID: referenced.id,
                force: true
            )
            var refreshed = store.messages[conversation.id]?.first(where: { $0.id == referenced.id })
            if refreshed == nil {
                refreshed = try? await memory.message(id: referenced.id)
            }
            transcript = refreshed.flatMap(ChatEngine.normalizedVoiceTranscript)
        }

        let enabled = voiceTranscriptionEnabled(for: conversation)
        guard enabled || transcript != nil else { return nil }
        return VoiceQuoteText.quotedVoiceNote(transcript: transcript)
    }

    /// 内存或数据库里的最新消息副本。
    private func voiceMessage(conversationID: String, messageID: String) async -> ChatMessage? {
        if let message = store.messages[conversationID]?.first(where: { $0.id == messageID }) {
            return message
        }
        return try? await memory.message(id: messageID)
    }

    /// 按消息 ID 在全部已加载会话里查找（「重试」按钮只带 messageID，不带会话）。
    /// 找不到再查数据库。
    private func voiceMessageAnywhere(messageID: String) async -> ChatMessage? {
        for list in store.messages.values {
            if let message = list.first(where: { $0.id == messageID }) { return message }
        }
        return try? await memory.message(id: messageID)
    }

    /// 以事务安全的方式更新一条消息的语音字段（内存命中优先，否则按 ID 从库里读），
    /// 并立即落库；消息已被裁剪/删除时返回 nil。
    @discardableResult
    private func updateVoiceMessage(
        conversationID: String,
        messageID: String,
        mutate: (inout ChatMessage) -> Void
    ) async -> ChatMessage? {
        var updated: ChatMessage?
        if var list = store.messages[conversationID],
           let index = list.firstIndex(where: { $0.id == messageID }) {
            mutate(&list[index])
            updated = list[index]
            store.messages[conversationID] = list
        } else if var stored = try? await memory.message(id: messageID) {
            mutate(&stored)
            updated = stored
        }
        guard let updated else { return nil }
        do {
            try await memory.upsertMessages([updated])
        } catch {
            log(.warning, "Database", "写入语音字段失败：\(error.localizedDescription)")
        }
        return updated
    }

    /// 关闭语音转写时把内存里仍 pending 的语音消息标为 disabled（落库）：
    /// 取消队列后不会再有人更新它们，避免气泡永远停在「转写中」。
    private func markPendingVoiceMessagesDisabled() {
        var changed: [ChatMessage] = []
        for (conversationID, list) in store.messages {
            guard list.contains(where: { $0.kind == .voice && $0.voiceTranscriptState == .pending }) else {
                continue
            }
            var updated = list
            for index in updated.indices
            where updated[index].kind == .voice && updated[index].voiceTranscriptState == .pending {
                updated[index].voiceTranscriptState = .disabled
                changed.append(updated[index])
            }
            store.messages[conversationID] = updated
        }
        guard !changed.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await self.memory.upsertMessages(changed)
        }
    }

    /// 手动重试：有本地音频直接重新转写；没有音频时重新向 bridge 获取。
    func retryVoiceTranscription(messageID: String) async {
        guard messageID.hasPrefix("ob-") else {
            log(.debug, "Voice", "重试跳过：不是微信消息 ID（\(messageID)）")
            return
        }
        guard let message = await voiceMessageAnywhere(messageID: messageID) else {
            log(.debug, "Voice", "重试跳过：消息不存在（\(messageID)）")
            return
        }
        let conversationID = message.conversationID
        voiceTranscriptionAttempted.remove(messageID)
        if let path = message.voiceMediaPath ?? message.mediaPath,
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            await transcribeVoiceMessage(conversationID: conversationID, messageID: messageID, force: true)
            return
        }
        let enabled = voiceTranscriptionEnabled(conversationID: conversationID)
        guard enabled else {
            log(.debug, "Voice", "重试跳过：该会话已关闭语音转写（\(conversationID)）")
            return
        }
        _ = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
            $0.voiceTranscriptState = .pending
        }
        let bridgeID = String(messageID.dropFirst("ob-".count))
        let request = VoiceFetcher.Request(
            bridgeMessageID: bridgeID,
            chatMessageID: messageID,
            conversationID: conversationID
        )
        if store.voiceFetcher.retry(request) {
            pendingVoiceFetchIDs.insert(messageID)
            pendingVoiceTranscriptionIDs.insert(messageID)
            log(.debug, "Voice", "已重新排队获取语音（\(conversationID)）")
        } else {
            log(.debug, "Voice", "重试跳过：语音正在获取中（\(conversationID)）")
        }
    }

    // MARK: 识图（视觉模型）

    /// 生成回复前按需识别上下文里的近期图片（2026-10-23）。
    ///
    /// 只处理「入站图片 + 最近 10 分钟 + 尚无描述」，一次回复最多 2 张；图片还没落盘时
    /// 最多等 8 秒（只等本轮已入队的图片）。识别结果写回消息与数据库，之后
    /// `ChatEngine.promptText` 会以 `[图片：描述]` 参与文本上下文。
    /// 任何失败只写日志，不阻断回复。
    private func prepareVisionDescriptions(conversation: Conversation, incoming: ChatMessage) async {
        let settings = store.settings
        guard settings.isVisionEnabled, let provider = settings.visionProvider else { return }

        var context = Array((store.messages[conversation.id] ?? []).suffix(ChatEngine.shortTermMemoryLimit))
        if !context.contains(where: { $0.id == incoming.id }) {
            context.append(incoming)
        }
        let candidates = VisionSupport.candidates(in: context)
        guard !candidates.isEmpty else { return }

        let requestProvider = settings.visionRequestProvider(from: provider)
        guard aiClient.credentialState(for: requestProvider) == .available else {
            log(.debug, "Vision", "识图跳过：通道「\(provider.name)」缺少可用 API Key")
            return
        }
        let prompt = settings.ai.vision?.promptText ?? VisionSettings.defaultPrompt
        // 整个识图阶段共用一个等待预算：避免 2 张图各等 8 秒。
        let imageWaitDeadline = Date().addingTimeInterval(8)

        for candidate in candidates {
            if Task.isCancelled { return }
            _ = await recognizeVisionImage(
                candidate,
                conversation: conversation,
                provider: requestProvider,
                prompt: prompt,
                canWaitForImage: true,
                imageWaitDeadline: imageWaitDeadline
            )
        }
    }

    /// 识别一张图片并把描述写回消息/数据库；成功返回描述，失败返回 nil。
    ///
    /// 调用方负责已确认「识图开启 + 通道凭据可用」。`visionAttempted` 保证同一消息
    /// 在本次运行内最多请求一次；`canWaitForImage` 只用于本轮刚收到、可能仍在
    /// `ImageFetcher` 队列里的图片（引用旧图不需要等待）。
    private func recognizeVisionImage(
        _ message: ChatMessage,
        conversation: Conversation,
        provider: AIProvider,
        prompt: String,
        canWaitForImage: Bool,
        imageWaitDeadline: Date?
    ) async -> String? {
        if let existing = ChatEngine.normalizedImageDescription(message) {
            return existing
        }
        guard !visionAttempted.contains(message.id) else { return nil }

        let path: String?
        if let existing = message.mediaPath, !existing.isEmpty {
            path = existing
        } else if let existing = mediaPath(conversationID: conversation.id, messageID: message.id) {
            path = existing
        } else if canWaitForImage,
                  pendingImageFetchIDs.contains(message.id),
                  let imageWaitDeadline {
            let remaining = imageWaitDeadline.timeIntervalSinceNow
            guard remaining > 0 else {
                log(.debug, "Vision", "识图跳过：图片获取超时（\(message.id)）")
                return nil
            }
            path = await waitForImagePath(
                conversationID: conversation.id,
                messageID: message.id,
                timeout: remaining
            )
        } else {
            path = nil
        }
        guard let path, !path.isEmpty else { return nil }
        visionAttempted.insert(message.id)

        do {
            let dataURL = try VisionSupport.imageDataURL(forFileAt: path)
            let messages = VisionSupport.requestMessages(prompt: prompt, imageDataURL: dataURL)
            let result = try await aiClient.complete(
                messages: messages,
                provider: provider,
                forceStream: false,
                thinking: VisionSupport.thinkingMode(for: provider)
            )
            guard let description = VisionSupport.normalizedDescription(result.text) else {
                log(.debug, "Vision", "识图返回空描述（\(message.id)）")
                return nil
            }
            await applyImageDescription(
                conversationID: conversation.id,
                messageID: message.id,
                description: description
            )
            log(.info, "Vision", "已识图：\(conversation.displayTitle)（\(description.count) 字，模型 \(provider.model)）")
            return description
        } catch {
            if case AIError.emptyResponse = error {
                log(.warning, "Vision", "识图失败（\(conversation.displayTitle)）：模型返回空内容；"
                    + "请确认「\(provider.name)」的模型 \(provider.model) 支持图片输入（将跳过本条图片）")
            } else {
                log(.debug, "Vision", "识图失败（\(conversation.displayTitle)）：\(error.localizedDescription)")
            }
            return nil
        }
    }

    /// 当前消息引用的如果是图片，返回一段可附加到用户消息末尾的说明（2026-10-23）。
    ///
    /// 微信引用只带 `svrid`（与 `ChatMessage.id` 的 `ob-<id>` 精确对应）和摘要
    /// `[图片]`，主回复模型看不到被引用图片本体。这里按 `svrid` 找回原图：
    /// - 已有识图描述：直接复用；
    /// - 还没描述但有本地图片：借用识图通道现场识别（不受「最近 10 分钟」限制，
    ///   因为用户明确引用了它）；
    /// - 找不到原图/无法识别：明确告诉模型「内容暂不可用」，避免它猜图。
    ///
    /// 未开启识图且原图也没有旧描述时返回 nil，不改变旧行为。
    private func prepareQuotedImageNote(conversation: Conversation, incoming: ChatMessage) async -> String? {
        guard let quote = WeChatAppmsg.parse(eventJSON: incoming.rawJSON)?.quote,
              quote.isImage else { return nil }

        let settings = store.settings
        var referenced: ChatMessage?
        if let imageID = quote.imageMessageID {
            referenced = store.messages[conversation.id]?.first(where: { $0.id == imageID })
            if referenced == nil {
                referenced = try? await memory.message(id: imageID)
            }
        }

        var description = referenced.flatMap(ChatEngine.normalizedImageDescription)
        if description == nil,
           let referenced,
           settings.isVisionEnabled,
           let provider = settings.visionProvider {
            let requestProvider = settings.visionRequestProvider(from: provider)
            if aiClient.credentialState(for: requestProvider) == .available {
                description = await recognizeVisionImage(
                    referenced,
                    conversation: conversation,
                    provider: requestProvider,
                    prompt: settings.ai.vision?.promptText ?? VisionSettings.defaultPrompt,
                    canWaitForImage: false,
                    imageWaitDeadline: nil
                )
            }
        }

        guard settings.isVisionEnabled || description != nil else { return nil }
        return VisionSupport.quotedImageNote(description: description)
    }

    /// 已获取图片的本地路径；没有/尚未获取返回 nil。
    private func mediaPath(conversationID: String, messageID: String) -> String? {
        guard let list = store.messages[conversationID],
              let message = list.first(where: { $0.id == messageID }),
              let path = message.mediaPath,
              !path.isEmpty else { return nil }
        return path
    }

    /// 等待 `ImageFetcher` 把图片写回内存。只在本轮图片确实在队列里时调用；
    /// 100ms 低频检查 store（描述只在准备回复时用，不属于 UI 刷新热路径）。
    private func waitForImagePath(
        conversationID: String,
        messageID: String,
        timeout: TimeInterval
    ) async -> String? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while !Task.isCancelled {
            if let path = mediaPath(conversationID: conversationID, messageID: messageID) {
                return path
            }
            guard pendingImageFetchIDs.contains(messageID) else { return nil }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// 把识图描述写回内存消息与数据库；消息可能已被裁剪/删除，此时按 ID 从库里补写。
    private func applyImageDescription(conversationID: String, messageID: String, description: String) async {
        var updated: ChatMessage?
        if var list = store.messages[conversationID],
           let index = list.firstIndex(where: { $0.id == messageID }) {
            list[index].imageDescription = description
            store.messages[conversationID] = list
            updated = list[index]
        } else if var stored = try? await memory.message(id: messageID) {
            stored.imageDescription = description
            updated = stored
        }
        guard let updated else { return }
        do {
            try await memory.upsertMessages([updated])
        } catch {
            log(.warning, "Database", "写入识图描述失败：\(error.localizedDescription)")
        }
    }

    // MARK: @ 文本回退

    /// 从带结构化 at 段的事件中学习「机器人在该群的展示昵称」。
    /// 之后即使客户端没带 `<atuserlist>`（或用户手动打字 @），规则层也能用昵称命中。
    private func learnMentionNameIfNeeded(from event: OneBotEvent) {
        guard event.isGroup else { return }
        let robotID = event.selfID.isEmpty ? selfID : event.selfID
        guard !robotID.isEmpty, event.mentions.contains(robotID) else { return }
        let text = event.segments
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: " ")
        guard let name = MentionText.displayName(in: text, selfID: robotID, mentions: event.mentions) else { return }
        setSelfMentionName(name, for: event.conversationID)
    }

    private func setSelfMentionName(_ name: String, for conversationID: String) {
        var names = store.settings.bot.selfMentionNames ?? [:]
        guard names[conversationID] != name else { return }
        names[conversationID] = name
        store.settings.bot.selfMentionNames = names
        store.persist()
        log(.info, "Bot", "已记录机器人群昵称「\(name)」：之后纯文本 @ 也能触发回复")
    }

    /// 启动后在后台回填群昵称：只解析启动预载窗口内的群消息（≤30 个群 × 最近 30 条），
    /// 且在 UI 首帧之后运行，避免在主线程解析 rawJSON。升级后无需等待下一次结构化 @
    /// 即可修复历史会话里的纯文本 @。
    private func scheduleSelfMentionBackfill() {
        guard !selfID.isEmpty else { return }
        let selfID = selfID
        var groupPayloads: [String: [String]] = [:]
        for conversation in store.conversations where conversation.kind == .group {
            guard groupPayloads.count < 30 else { break }
            let payloads = (store.messages[conversation.id] ?? [])
                .suffix(30)
                .compactMap(\.rawJSON)
                .filter { $0.contains("\"at\"") && $0.contains(selfID) }
            if !payloads.isEmpty { groupPayloads[conversation.id] = payloads }
        }
        guard !groupPayloads.isEmpty else { return }
        let existing = store.settings.bot.selfMentionNames ?? [:]
        selfMentionBackfillTask?.cancel()
        selfMentionBackfillTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            let learned = await Task.detached(priority: .utility) {
                Self.learnSelfMentionNames(fromJSON: groupPayloads, selfID: selfID, existing: existing)
            }.value
            guard let self, !learned.isEmpty else { return }
            var names = self.store.settings.bot.selfMentionNames ?? [:]
            var changed = 0
            for (conversationID, name) in learned where names[conversationID] != name {
                names[conversationID] = name
                changed += 1
            }
            guard changed > 0 else { return }
            self.store.settings.bot.selfMentionNames = names
            self.store.persist()
            self.log(.info, "Bot", "已从历史消息回填机器人群昵称：\(changed) 个群")
        }
    }

    /// Pure JSON parsing for the mention-name backfill; runs on a utility thread.
    private nonisolated static func learnSelfMentionNames(
        fromJSON payloads: [String: [String]],
        selfID: String,
        existing: [String: String]
    ) -> [String: String] {
        var learned: [String: String] = [:]
        for (conversationID, raws) in payloads {
            for rawJSON in raws {
                guard let data = rawJSON.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let event = (object["data"] as? [String: Any]) ?? object
                guard let segments = event["message"] as? [[String: Any]] else { continue }
                let text = segments.compactMap { segment -> String? in
                    guard (segment["type"] as? String) == "text" else { return nil }
                    return (segment["data"] as? [String: Any])?["text"] as? String
                }.joined(separator: " ")
                var mentions = segments.compactMap { segment -> String? in
                    guard (segment["type"] as? String) == "at" else { return nil }
                    let data = segment["data"] as? [String: Any] ?? [:]
                    return (data["qq"] as? String)
                        ?? (data["user_id"] as? String)
                        ?? (data["target_id"] as? String)
                }
                if mentions.isEmpty, let explicit = event["mentions"] as? [String] {
                    mentions = explicit
                }
                guard let name = MentionText.displayName(in: text, selfID: selfID, mentions: mentions) else { continue }
                if existing[conversationID] != name {
                    learned[conversationID] = name
                }
            }
        }
        return learned
    }

    private func markLocalEchoSent(_ event: OneBotEvent) -> Bool {
        guard var list = store.messages[event.conversationID] else { return false }
        let normalized = event.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = list.lastIndex(where: {
            $0.direction == .outgoing && $0.status != .failed
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }) else { return false }
        list[index].status = .sent
        store.messages[event.conversationID] = list
        let updated = list[index]
        Task { try? await self.memory.upsertMessages([updated]) }
        return true
    }

    // MARK: Reply progress (UI)

    /// 每个会话当前进度的令牌：完成的「自动收起」任务只在令牌未变化时清理，
    /// 避免把紧接着开始的新一轮回复进度误删。
    private var replyProgressTokens: [String: UUID] = [:]

    private func beginReplyProgress(conversationID: String, providerName: String?, model: String?) {
        let now = Date()
        replyProgressTokens[conversationID] = UUID()
        store.replyProgress[conversationID] = ReplyProgress(
            conversationID: conversationID,
            stage: .generating,
            startedAt: now,
            stageStartedAt: now,
            providerName: providerName,
            model: model
        )
    }

    private func setReplyProgressProvider(conversationID: String, provider: AIProvider) {
        guard var progress = store.replyProgress[conversationID] else { return }
        progress.providerName = provider.name
        progress.model = provider.model
        store.replyProgress[conversationID] = progress
    }

    private func updateReplyProgress(
        conversationID: String,
        stage: ReplyStage,
        countdown: TimeInterval? = nil,
        segmentIndex: Int? = nil,
        segmentCount: Int? = nil
    ) {
        guard var progress = store.replyProgress[conversationID] else { return }
        let now = Date()
        progress.stage = stage
        progress.stageStartedAt = now
        if let countdown {
            progress.countdownEnd = now.addingTimeInterval(countdown)
            progress.countdownTotal = countdown
        } else {
            progress.countdownEnd = nil
            progress.countdownTotal = nil
        }
        if let segmentIndex { progress.segmentIndex = segmentIndex }
        if let segmentCount { progress.segmentCount = segmentCount }
        progress.note = nil
        progress.errorText = nil
        store.replyProgress[conversationID] = progress
    }

    /// 结束当前进度。只在已有进度快照时更新：bot 停止/会话删除会先清空快照，
    /// 此后迟到的异步回调不会把过期状态写回来。
    private func finishReplyProgress(
        conversationID: String,
        stage: ReplyStage,
        note: String? = nil,
        errorText: String? = nil,
        clearAfter: Duration? = nil
    ) {
        guard var progress = store.replyProgress[conversationID] else { return }
        let now = Date()
        progress.stage = stage
        progress.stageStartedAt = now
        progress.countdownEnd = nil
        progress.countdownTotal = nil
        progress.note = note
        progress.errorText = errorText
        store.replyProgress[conversationID] = progress

        let token = replyProgressTokens[conversationID] ?? UUID()
        replyProgressTokens[conversationID] = token
        guard let clearAfter else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: clearAfter)
            guard let self, self.replyProgressTokens[conversationID] == token else { return }
            self.store.replyProgress[conversationID] = nil
            self.replyProgressTokens[conversationID] = nil
        }
    }

    private func completeReplyProgress(conversationID: String, note: String) {
        finishReplyProgress(
            conversationID: conversationID,
            stage: .completed,
            note: note,
            clearAfter: .seconds(3)
        )
    }

    private func failReplyProgress(conversationID: String, error: String) {
        finishReplyProgress(
            conversationID: conversationID,
            stage: .failed,
            errorText: error,
            clearAfter: .seconds(60)
        )
    }

    /// 用户点击状态条上的关闭按钮。同时失效「自动收起」任务。
    func forgetReplyProgress(conversationID: String) {
        replyProgressTokens[conversationID] = nil
        if store.replyProgress[conversationID] != nil {
            store.replyProgress[conversationID] = nil
        }
    }

    /// bot 停止 / App 退出时清空所有进度，避免界面停留在过期的「生成中」。
    private func clearReplyProgresses() {
        guard !store.replyProgress.isEmpty || !replyProgressTokens.isEmpty else { return }
        store.replyProgress.removeAll()
        replyProgressTokens.removeAll()
    }

    // MARK: AI pipeline

    private func evaluateAndReply(conversation: Conversation, message: ChatMessage, receivedAt: Date) async {
        guard store.settings.bot.enabled else { return }
        let evaluation = ruleEngine.evaluate(RuleEngine.Context(
            conversation: conversation,
            message: message,
            settings: store.settings,
            now: Date(),
            selfID: selfID
        ))
        guard evaluation.shouldReply else {
            log(.debug, "Rule", "跳过回复（\(conversation.displayTitle)）：\(evaluation.reason)")
            return
        }
        guard !inFlightConversations.contains(conversation.id) else {
            log(.debug, "Bot", "会话 \(conversation.displayTitle) 正在生成回复，跳过本条")
            return
        }
        inFlightConversations.insert(conversation.id)
        defer { inFlightConversations.remove(conversation.id) }

        // 拍一拍回复优先：不再回拍，只发送自定义文字和/或 AI 回复；
        // 只有「没发出任何内容、需要回退」时才继续普通 AI 流程。
        // 群聊 @ 拍的人同样用于回退的普通 AI 回复，避免只开了 @ 没开文字/AI 时失效。
        let isPatForBot = store.settings.bot.patReplyEnabled
            && PatMessage.isDirectedAtBot(
                message,
                conversation: conversation,
                selfID: selfID,
                selfMentionName: store.settings.bot.selfMentionNames?[conversation.id]
            )
        let patMention = isPatForBot
            ? PatMessage.replyMention(
                message,
                conversation: conversation,
                selfID: selfID,
                enabled: store.settings.bot.patMentionPatterEnabled
            )
            : nil
        if isPatForBot {
            if await handlePatReply(
                conversation: conversation,
                message: message,
                evaluation: evaluation,
                receivedAt: receivedAt,
                mention: patMention
            ) {
                return
            }
            log(.warning, "Bot", "拍一拍回复未完成，回退为普通文字回复")
        }

        // Publish progress before any async gate so a missing provider / credential is
        // visible in the UI as a failed step instead of silently producing no reply.
        let settingsProvider = store.settings.provider(id: evaluation.providerID)
        beginReplyProgress(
            conversationID: conversation.id,
            providerName: settingsProvider?.name,
            model: settingsProvider?.model
        )
        updateReplyProgress(conversationID: conversation.id, stage: .generating)

        guard let settingsProvider else {
            log(.warning, "AI", "未找到可用 AI 服务，跳过回复")
            failReplyProgress(conversationID: conversation.id, error: "未找到可用 AI 服务")
            return
        }
        let credentialState = aiClient.credentialState(for: settingsProvider)
        guard credentialState == .available else {
            let reason: String
            if case .unreadable(let status) = credentialState {
                reason = "「\(settingsProvider.name)」的 API Key 无法从钥匙串读取（OSStatus \(status)），"
                    + "请在「钥匙串访问」删除 \(AppPaths.bundleID) 条目后重新填写"
            } else {
                reason = "「\(settingsProvider.name)」未配置 API Key"
            }
            log(.warning, "AI", "\(reason)，跳过回复")
            failReplyProgress(conversationID: conversation.id, error: reason)
            return
        }
        let persona = store.settings.persona(id: evaluation.personaID)
        var provider = settingsProvider
        if let model = evaluation.model, !model.isEmpty { provider.model = model }
        if let personaModel = persona?.model, !personaModel.isEmpty { provider.model = personaModel }
        setReplyProgressProvider(conversationID: conversation.id, provider: provider)

        // 识图：生成回复前把上下文里的近期图片转成文字描述（按需、最多 2 张）。
        // 图片获取可能仍在队列中，本轮消息最多等待 8 秒；超时按 [图片] 继续回复。
        if store.settings.isVisionEnabled {
            await prepareVisionDescriptions(conversation: conversation, incoming: message)
        }
        // 引用图片：按 svrid 找回被引用原图，把它的识图描述附加到本轮消息，
        // 让回复模型知道用户引用的是哪一张图（旧图也可以现场识别一次）。
        let quotedImageNote = await prepareQuotedImageNote(conversation: conversation, incoming: message)
        // 引用语音：按 svrid 找回被引用语音的转写，附加「（引用语音内容：…）」。
        let quotedVoiceNote = await prepareQuotedVoiceNote(conversation: conversation, incoming: message)
        // 描述写回 store.messages 后，用最新副本作为 incoming（避免提示词读到旧值）。
        let replyMessage = store.messages[conversation.id]?.first(where: { $0.id == message.id }) ?? message
        var promptMessage = replyMessage
        for note in [quotedImageNote, quotedVoiceNote] {
            guard let note, !note.isEmpty else { continue }
            let base = promptMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            promptMessage.text = base.isEmpty ? note : base + "\n" + note
        }

        // ChatEngine only reads the last `shortTermMemoryLimit` messages; pass that window
        // instead of copying the whole (up to 300 message) history on the main actor.
        var history = Array((store.messages[conversation.id] ?? []).suffix(ChatEngine.shortTermMemoryLimit))
        if let index = history.firstIndex(where: { $0.id == promptMessage.id }) {
            history[index] = promptMessage
        }
        do {
            let plan = try await chatEngine.generateReply(
                conversation: conversation,
                incoming: promptMessage,
                settings: store.settings,
                persona: persona,
                provider: provider,
                history: history,
                dryRun: store.settings.bot.dryRun
            )
            await deliver(
                plan: plan,
                conversation: conversation,
                receivedAt: receivedAt,
                mention: patMention,
                incomingWasVoice: replyMessage.kind == .voice
            )
            ruleEngine.noteReply(conversationID: conversation.id)
            log(.info, "AI", "\(conversation.displayTitle) 生成回复（\(Int(plan.latencyMs))ms，tokens \(plan.usage.totalTokens)，\(evaluation.triggerLabel)）")
        } catch {
            store.stats.failedToday += 1
            scheduleStatsPersist()
            store.lastError = error.localizedDescription
            log(.error, "AI", "生成回复失败：\(error.localizedDescription)")
            failReplyProgress(conversationID: conversation.id, error: error.localizedDescription)
        }
    }

    private func deliver(
        plan: ChatReplyPlan,
        conversation: Conversation,
        receivedAt: Date,
        mention: PatMention? = nil,
        incomingWasVoice: Bool = false
    ) async {
        if plan.dryRun {
            var text = "（dry-run）将回复：\(plan.fullText)"
            if mention != nil { text += "（第一条回复会 @ 拍的人）" }
            log(.info, "Bot", "\(text)（未实际发送）")
            let message = ChatMessage(
                id: "dry-\(UUID().uuidString)",
                conversationID: conversation.id,
                senderID: "system",
                senderName: "系统",
                direction: .system,
                kind: .system,
                text: text,
                timestamp: Date(),
                status: .sent
            )
            appendMessage(message)
            if let updatedConversation = updateConversationAfterSend(conversation: conversation, message: message) {
                do {
                    // Message + refreshed conversation preview in one transaction.
                    try await memory.upsertConversationAndMessages(updatedConversation, [message])
                } catch {
                    log(.warning, "Database", "写入 dry-run 消息失败：\(error.localizedDescription)")
                }
            } else {
                await persistMessage(message)
            }
            completeReplyProgress(conversationID: conversation.id, note: "演练完成（未实际发送）")
            return
        }

        let sentCount = await sendPlanSegments(plan, conversation: conversation, mention: mention, incomingWasVoice: incomingWasVoice)

        guard sentCount > 0 else {
            failReplyProgress(conversationID: conversation.id, error: "消息发送失败，详见运行日志")
            return
        }
        let segmentCount = plan.segments.count
        let note = sentCount == segmentCount
            ? "已发送 \(sentCount) 段"
            : "已发送 \(sentCount)/\(segmentCount) 段（部分失败）"
        completeReplyProgress(conversationID: conversation.id, note: note)

        store.stats.repliedToday += 1
        store.stats.lastReplyAt = Date()
        recordReplyLatency(plan.latencyMs)
        let endToEndMs = Int(Date().timeIntervalSince(receivedAt) * 1000)
        log(.info, "Bot", "回复投递完成：端到端 \(endToEndMs)ms（AI \(Int(plan.latencyMs))ms，拟人化 \(plan.delaysMs.first ?? 0)ms，bridge 环节见上一条）")
        scheduleStatsPersist()
    }

    /// 按拟人化设置发送一段 AI 回复计划，返回成功段数。
    /// 由普通回复和「拍一拍 AI 回复」共用，保留进度条阶段与分段延迟。
    /// `mention` 只作用于第一条真正发出的消息（拍一拍回复 @ 拍的人）。
    private func sendPlanSegments(
        _ plan: ChatReplyPlan,
        conversation: Conversation,
        mention: PatMention? = nil,
        incomingWasVoice: Bool = false
    ) async -> Int {
        let humanize = store.settings.bot.humanize
        let segmentCount = plan.segments.count
        var sentCount = 0

        // 语音回复决策：只在「单段 + 无 @ 提及」时尝试，避免多段语音刷屏或丢失群 @。
        let voiceSettings = store.settings.bot.voice ?? VoiceSettings()
        // 会话级覆盖优先：全局关闭但该会话显式开启时仍要尝试语音回复。
        let voiceConfigured = conversation.effectiveVoiceReplyEnabled(global: voiceSettings.replyEnabled)
        var runtimeReady = false
        if voiceConfigured {
            await refreshVoiceStatus()
            runtimeReady = store.voiceRuntimeStatus.canSendVoice()
        }
        let voiceDecision = decideVoiceReply(VoiceReplyContext(
            global: voiceSettings,
            conversation: conversation,
            incomingWasVoice: incomingWasVoice,
            replyText: plan.fullText,
            modelsReady: VoiceSynthesisService.isReady(voiceSettings.engine),
            runtimeReady: runtimeReady,
            rng: Double.random(in: 0..<1)
        ))
        let useVoice = voiceDecision.isVoice && segmentCount == 1 && mention == nil
        if voiceDecision.isVoice, !useVoice {
            log(.debug, "Voice", "本次不改发语音：\(voiceDecision.reason)（段数 \(segmentCount)，mention=\(mention == nil ? "无" : "有")）")
        } else if useVoice {
            log(.debug, "Voice", "本次回复改发语音：\(voiceDecision.reason)")
        }
        for (index, segment) in plan.segments.enumerated() {
            if humanize.enabled, index < plan.delaysMs.count, plan.delaysMs[index] > 0 {
                let delaySeconds = Double(plan.delaysMs[index]) / 1000
                updateReplyProgress(
                    conversationID: conversation.id,
                    stage: .waitingToSend,
                    countdown: delaySeconds,
                    segmentIndex: index + 1,
                    segmentCount: segmentCount
                )
                log(.debug, "Humanize", "分段 \(index + 1)/\(segmentCount) 延迟 \(plan.delaysMs[index])ms")
                try? await Task.sleep(nanoseconds: UInt64(plan.delaysMs[index]) * 1_000_000)
            }
            if humanize.enabled && humanize.typingIndicator && index == 0 {
                log(.debug, "Humanize", "输入端「正在输入」指示由微信客户端展示，bridge 暂未暴露接口")
            }
            updateReplyProgress(
                conversationID: conversation.id,
                stage: .sending,
                segmentIndex: index + 1,
                segmentCount: segmentCount
            )
            var sent = false
            if useVoice, index == 0 {
                sent = await sendOutgoingVoice(
                    segment,
                    conversation: conversation,
                    settings: voiceSettings
                )
            }
            if !sent {
                sent = await sendOutgoingText(
                    segment,
                    conversation: conversation,
                    mention: sentCount == 0 ? mention : nil
                )
            }
            if sent { sentCount += 1 }
        }
        return sentCount
    }

    /// 别人拍一拍机器人后的回复：自定义文字（前）→ AI → 自定义文字（后）。
    /// 不再发送原生拍一拍；AI 失败时仍发送自定义文字。
    /// `mention` 为群聊 @ 拍的人的目标，只附在第一条真正发出的消息前。
    private func handlePatReply(
        conversation: Conversation,
        message: ChatMessage,
        evaluation: RuleEvaluation,
        receivedAt: Date,
        mention: PatMention?
    ) async -> Bool {
        let bot = store.settings.bot
        let patName = message.displaySender
        let fixedEnabled = bot.patFixedTextEnabled
        let aiEnabled = bot.patAIEnabled
        let beforeText = fixedEnabled ? PatTextTemplate.render(bot.patBeforeText, name: patName) : ""
        let afterText = fixedEnabled ? PatTextTemplate.render(bot.patAfterText, name: patName) : ""

        let patProvider = store.settings.provider(id: evaluation.providerID)
        beginReplyProgress(
            conversationID: conversation.id,
            providerName: patProvider?.name,
            model: patProvider?.model
        )

        if bot.dryRun {
            var plan = "（dry-run）将回复拍一拍「\(patName)」"
            if mention != nil { plan += "，第一条回复 @ 拍的人" }
            if !beforeText.isEmpty { plan += "，AI 前文字「\(beforeText)」" }
            if aiEnabled { plan += "，附带 AI 回复" }
            if !afterText.isEmpty { plan += "，AI 后文字「\(afterText)」" }
            log(.info, "Bot", "\(plan)（未实际发送）")
            await appendSystemNotice(plan, conversationID: conversation.id)
            completeReplyProgress(conversationID: conversation.id, note: "演练完成（未实际发送）")
            return true
        }

        updateReplyProgress(conversationID: conversation.id, stage: .sending)
        var pendingMention = mention
        var sentAny = false
        if !beforeText.isEmpty {
            let sent = await sendOutgoingText(
                beforeText,
                conversation: conversation,
                mention: pendingMention
            )
            if sent { pendingMention = nil }
            sentAny = sent || sentAny
        }

        var aiLatency: Double?
        if aiEnabled {
            updateReplyProgress(conversationID: conversation.id, stage: .generating)
            if let plan = await generatePatAIReply(
                conversation: conversation, message: message, evaluation: evaluation
            ) {
                aiLatency = plan.latencyMs
                updateReplyProgress(conversationID: conversation.id, stage: .sending)
                let sent = await sendPlanSegments(
                    plan,
                    conversation: conversation,
                    mention: pendingMention
                )
                if sent > 0 {
                    pendingMention = nil
                    sentAny = true
                }
            }
        }

        if !afterText.isEmpty {
            let sent = await sendOutgoingText(
                afterText,
                conversation: conversation,
                mention: pendingMention
            )
            sentAny = sent || sentAny
        }

        if sentAny {
            finishPatReply(
                conversation: conversation,
                receivedAt: receivedAt,
                aiLatencyMs: aiLatency,
                note: aiEnabled ? "已发送拍一拍回复" : "已发送拍一拍自定义文字"
            )
            return true
        }

        log(.warning, "Bot", "拍一拍回复未发送：\(patName)")
        return false
    }

    /// 拍一拍附带的 AI 回复：走与普通自动回复相同的 persona/provider/model 与上下文窗口。
    /// 生成失败只记日志并返回 nil，不阻断固定文字/拍一拍。
    private func generatePatAIReply(
        conversation: Conversation,
        message: ChatMessage,
        evaluation: RuleEvaluation
    ) async -> ChatReplyPlan? {
        guard let settingsProvider = store.settings.provider(id: evaluation.providerID) else {
            log(.warning, "AI", "拍一拍 AI 回复：未找到可用 AI 服务")
            return nil
        }
        let credentialState = aiClient.credentialState(for: settingsProvider)
        guard credentialState == .available else {
            let reason: String
            if case .unreadable(let status) = credentialState {
                reason = "「\(settingsProvider.name)」的 API Key 无法从钥匙串读取（OSStatus \(status)）"
            } else {
                reason = "「\(settingsProvider.name)」未配置 API Key"
            }
            log(.warning, "AI", "拍一拍 AI 回复：\(reason)，本次跳过 AI 文字")
            return nil
        }
        let persona = store.settings.persona(id: evaluation.personaID)
        var provider = settingsProvider
        if let model = evaluation.model, !model.isEmpty { provider.model = model }
        if let personaModel = persona?.model, !personaModel.isEmpty { provider.model = personaModel }
        let history = Array((store.messages[conversation.id] ?? []).suffix(ChatEngine.shortTermMemoryLimit))
        do {
            return try await chatEngine.generateReply(
                conversation: conversation,
                incoming: message,
                settings: store.settings,
                persona: persona,
                provider: provider,
                history: history,
                dryRun: false
            )
        } catch {
            store.stats.failedToday += 1
            scheduleStatsPersist()
            log(.error, "AI", "拍一拍 AI 回复生成失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func finishPatReply(
        conversation: Conversation,
        receivedAt: Date,
        aiLatencyMs: Double?,
        note: String
    ) {
        ruleEngine.noteReply(conversationID: conversation.id)
        store.stats.repliedToday += 1
        store.stats.lastReplyAt = Date()
        if let aiLatencyMs { recordReplyLatency(aiLatencyMs) }
        scheduleStatsPersist()
        completeReplyProgress(conversationID: conversation.id, note: note)
        let endToEndMs = Int(Date().timeIntervalSince(receivedAt) * 1000)
        log(.info, "Bot", "拍一拍回复完成：端到端 \(endToEndMs)ms（\(note)）")
    }

    // MARK: Sending

    /// 会话内的系统提示（标为 system，不进入 AI 上下文，也不改写会话预览）。
    private func appendSystemNotice(_ text: String, conversationID: String) async {
        let notice = ChatMessage(
            id: "sys-\(UUID().uuidString)",
            conversationID: conversationID,
            senderID: "system",
            senderName: "系统",
            direction: .system,
            kind: .system,
            text: text,
            timestamp: Date(),
            status: .sent
        )
        appendMessage(notice)
        await persistMessage(notice)
    }

    /// 尝试把一段 AI 回复合成语音并通过 bridge 发送。
    ///
    /// 返回 `false` 时调用方必须降级为文字（spec §3.3）：模型未就绪、合成失败、
    /// bridge 返回 `voice_send_unsupported`（4.2 Hook 尚未支持）都走这一条。
    /// 只有真正发送成功才落一条 outgoing 语音消息，避免出现「本地已发、微信没收到」。
    ///
    /// `modelDownloadConsent` 只约束**下载**入口（`VoiceModelStore.download`），
    /// 不是使用门槛：模型已就绪时必须能直接合成，否则已下载模型的用户会永远只发文字。
    @discardableResult
    private func sendOutgoingVoice(
        _ text: String,
        conversation: Conversation,
        settings: VoiceSettings
    ) async -> Bool {
        guard VoiceSynthesisService.isReady(settings.engine) else {
            log(.debug, "Voice", "跳过语音回复：语音模型未就绪（\(settings.engine.rawValue)）")
            return false
        }
        if !store.voiceRuntimeStatus.canSendVoice() {
            await refreshVoiceStatus()
            guard store.voiceRuntimeStatus.canSendVoice() else {
                log(.info, "Voice", "语音发送未就绪：\(store.voiceRuntimeStatus.summary())；本条改发文字")
                return false
            }
        }
        let voice = VoiceSelection(settings: settings)
        if voice.engine == .zipvoiceClone,
           (voice.cloneID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log(.debug, "Voice", "跳过语音回复：克隆引擎未选择音色档案")
            return false
        }
        let synthesis: SynthesisResult
        do {
            synthesis = try await store.voiceSynthesis.synthesize(
                text: text,
                voice: voice,
                maxSeconds: settings.effectiveMaxVoiceSeconds,
                allowsTruncation: settings.overLimit == .truncate
            )
        } catch {
            log(.warning, "Voice", "语音合成失败：\(error.localizedDescription)；本条改发文字")
            return false
        }
        guard let client = oneBotClient else {
            log(.debug, "Voice", "bridge 未运行，语音改发文字")
            return false
        }
        do {
            let sent = try await client.sendVoice(
                conversationID: conversation.id,
                isGroup: conversation.kind == .group,
                wavURL: synthesis.wavURL,
                durationHintMs: Int(synthesis.duration * 1000)
            )
            let durationMs = sent.durationMs > 0
                ? sent.durationMs
                : Int(synthesis.duration * 1000)
            var message = ChatMessage(
                id: "local-\(UUID().uuidString)",
                conversationID: conversation.id,
                senderID: selfID.isEmpty ? "self" : selfID,
                senderName: "我",
                direction: .outgoing,
                kind: .voice,
                text: text,
                timestamp: Date(),
                status: .sent
            )
            message.voiceDurationMs = durationMs
            message.mediaPath = synthesis.wavURL.path
            appendMessage(message)
            if let updatedConversation = updateConversationAfterSend(
                conversation: conversation,
                message: message
            ) {
                do {
                    try await memory.upsertConversationAndMessages(updatedConversation, [message])
                } catch {
                    log(.warning, "Database", "写入语音消息失败：\(error.localizedDescription)")
                }
            } else {
                await persistMessage(message)
            }
            log(.info, "Voice", "已发送语音 → \(conversation.displayTitle)：\(durationMs)ms")
            return true
        } catch {
            // 典型：voice_send_unsupported（4.2 Hook 未支持）；不重试语音，直接降级文字。
            log(.info, "Voice", "语音发送未成功（\(error.localizedDescription)）；本条改发文字")
            return false
        }
    }

    @discardableResult
    func sendOutgoingText(
        _ text: String,
        conversation: Conversation,
        mention: PatMention? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // bridge 会把 at 段拼成「@群昵称\u2005正文」；本地记录只在不伪造昵称时保留原文。
        let displayText = mention?.localText(trimmed) ?? trimmed
        var message = ChatMessage(
            id: "local-\(UUID().uuidString)",
            conversationID: conversation.id,
            senderID: selfID.isEmpty ? "self" : selfID,
            senderName: "我",
            direction: .outgoing,
            kind: .text,
            text: displayText,
            timestamp: Date(),
            status: .pending
        )
        appendMessage(message)
        await persistMessage(message)

        do {
            guard let client = oneBotClient else { throw OneBotError.notRunning }
            let sendStartedAt = Date()
            if let mention, conversation.kind == .group {
                try await client.send(
                    conversationID: conversation.id,
                    isGroup: true,
                    segments: [
                        OneBotSegment(type: "at", targetID: mention.userID),
                        .text(trimmed)
                    ],
                    echoText: displayText
                )
            } else {
                try await client.sendText(
                    conversationID: conversation.id,
                    isGroup: conversation.kind == .group,
                    text: trimmed
                )
            }
            message.status = .sent
            updateMessage(message)
            let updatedConversation = updateConversationAfterSend(conversation: conversation, message: message)
            do {
                if let updatedConversation {
                    // Status update + conversation preview in one transaction (was two).
                    try await memory.upsertConversationAndMessages(updatedConversation, [message])
                } else {
                    try await memory.upsertMessages([message])
                }
            } catch {
                log(.warning, "Database", "写入消息失败：\(error.localizedDescription)")
            }
            let bridgeRTT = Int(Date().timeIntervalSince(sendStartedAt) * 1000)
            log(.info, "Bot", "已发送 \(conversation.kind.label)消息 → \(conversation.displayTitle)：\(displayText.prefix(60))（bridge 往返 \(bridgeRTT)ms）")
            scheduleMemoryMaintenance(conversationID: conversation.id)
            return true
        } catch {
            message.status = .failed
            updateMessage(message)
            await persistMessage(message)
            store.stats.failedToday += 1
            scheduleStatsPersist()
            store.lastError = error.localizedDescription
            log(.error, "Bot", "发送失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Refreshes the conversation list entry after a send and returns the updated value
    /// (so the caller can persist it together with the message in one transaction).
    @discardableResult
    private func updateConversationAfterSend(conversation: Conversation, message: ChatMessage) -> Conversation? {
        guard let index = store.conversations.firstIndex(where: { $0.id == conversation.id }) else { return nil }
        var updated = store.conversations[index]
        updated.lastMessageAt = message.timestamp
        updated.lastMessagePreview = String(message.text.prefix(80))
        var conversations = store.conversations
        conversations[index] = updated
        store.conversations = Self.ordered(conversations, moving: index)
        return updated
    }

    private func appendMessage(_ message: ChatMessage) {
        var list = store.messages[message.conversationID] ?? []
        guard !list.contains(where: { $0.id == message.id }) else { return }
        list.append(message)
        // Only sort when an out-of-order timestamp actually arrives (echo/status updates
        // are appended in order, so the common path avoids O(n log n) work per message).
        if list.count > 1, list[list.count - 2].timestamp > message.timestamp {
            list.sort { $0.timestamp < $1.timestamp }
        }
        if list.count > 300 { list.removeFirst(list.count - 300) }
        store.messages[message.conversationID] = list
    }

    private func updateMessage(_ message: ChatMessage) {
        guard var list = store.messages[message.conversationID],
              let index = list.firstIndex(where: { $0.id == message.id }) else {
            appendMessage(message)
            return
        }
        list[index] = message
        store.messages[message.conversationID] = list
    }

    private func persistMessage(_ message: ChatMessage) async {
        do {
            try await memory.upsertMessages([message])
        } catch {
            log(.warning, "Database", "写入消息失败：\(error.localizedDescription)")
        }
    }

    private func persistConversation(_ conversation: Conversation) async {
        do {
            try await memory.upsertConversation(conversation)
        } catch {
            log(.warning, "Database", "写入会话失败：\(error.localizedDescription)")
        }
    }

    private func recordReplyLatency(_ latency: Double) {
        let count = max(1, store.stats.repliedToday)
        let current = store.stats.aiLatencyAverageMs
        store.stats.aiLatencyAverageMs = current == 0 ? latency : current + (latency - current) / Double(count)
    }

    // MARK: Scheduler

    private func fireScheduledTask(_ task: ScheduledTask) async {
        guard store.isBotRunning else {
            log(.warning, "Scheduler", "机器人未运行，跳过定时任务「\(task.name)」")
            return
        }
        guard task.kind == .outgoing else {
            log(.info, "Scheduler", "定时任务「\(task.name)」为模拟收到消息类型，暂不执行")
            return
        }
        guard let conversation = store.conversations.first(where: { $0.id == task.conversationID }) else {
            log(.warning, "Scheduler", "定时任务「\(task.name)」的会话不存在：\(task.conversationID)")
            return
        }
        log(.info, "Scheduler", "执行定时任务「\(task.name)」→ \(conversation.displayTitle)")
        await sendOutgoingText(task.content, conversation: conversation)
    }

    private func schedulesDidChange(_ tasks: [ScheduledTask]) {
        lastSchedulerTasks = tasks
        guard tasks != store.schedules else { return }
        store.schedules = tasks
        store.settings.schedules = tasks
        store.persist()
        Task { [weak self] in
            try? await self?.memory.replaceSchedules(tasks)
        }
    }

    /// Called by `AppStore.persist()` after UI mutations.
    func settingsDidChange() {
        guard bootstrapped || bootstrapping else { return }
        hookManager.configure(wechatPath: store.settings.hook.wechatPath)
        // 语音转写总开关关闭：取消未完成的语音获取（已在途的转写完成后仍会落库，
        // 只是不再发起新的 bridge 下载）。与图片开关的行为保持一致。
        let voiceEnabled = store.settings.bot.voiceTranscriptionEnabled
        if lastVoiceTranscriptionEnabled == nil {
            lastVoiceTranscriptionEnabled = voiceEnabled
        } else if lastVoiceTranscriptionEnabled != voiceEnabled {
            lastVoiceTranscriptionEnabled = voiceEnabled
            if !voiceEnabled {
                store.voiceFetcher.cancelAll()
                pendingVoiceFetchIDs.removeAll()
                pendingVoiceTranscriptionIDs.removeAll()
                markPendingVoiceMessagesDisabled()
                log(.info, "Voice", "语音转写已关闭，已取消未完成的语音获取")
            }
        }
        if store.isBotRunning {
            if store.schedules != lastSchedulerTasks {
                Task { [weak self] in
                    guard let self else { return }
                    await self.scheduler.update(tasks: self.store.schedules)
                }
            }
            if let started = startedOneBotConfiguration {
                if started.host != store.settings.onebot.host
                    || started.port != store.settings.onebot.port
                    || started.token != store.settings.onebot.token {
                    log(.warning, "OneBot", "连接配置已修改，重启机器人后生效")
                }
            }
        }

        // AI 模型页保存通道/Key 后立即重查余额（不必等 5 分钟轮询）。
        let fingerprint = store.providers
            .map { "\($0.id)|\($0.kind.rawValue)|\($0.enabled)|\($0.apiKeyReference)|\($0.baseURL)" }
            .joined(separator: ";")
        if fingerprint != lastProviderFingerprint {
            lastProviderFingerprint = fingerprint
            Task { [weak self] in
                guard let self else { return }
                await self.refreshDeepSeekBalance()
            }
        }
    }

    // MARK: Manual actions

    func sendManualMessage(conversationID: String, text: String) async {
        await bootstrapIfNeeded()
        var conversation: Conversation
        if let existing = store.conversations.first(where: { $0.id == conversationID }) {
            conversation = existing
        } else {
            conversation = Conversation(id: conversationID, kind: conversationID.contains("@chatroom") ? .group : .direct,
                                         title: "")
            store.conversations.insert(conversation, at: 0)
            await persistConversation(conversation)
        }
        guard store.isBotRunning, oneBotClient != nil else {
            let error = RuntimeError.notRunning
            store.lastError = error.localizedDescription
            log(.error, "Bot", "手动发送失败：\(error.localizedDescription)")
            return
        }
        let sent = await sendOutgoingText(text, conversation: conversation)
        if sent {
            ruleEngine.noteReply(conversationID: conversationID)
        }
    }

    func testProvider(_ provider: AIProvider) async -> Result<String, Error> {
        await bootstrapIfNeeded()
        do {
            let model = AIClient.effectiveModel(for: provider)
            let result = try await aiClient.complete(
                messages: [.user("这是一次连接测试，请只回复：pong")],
                provider: provider,
                temperature: store.settings.ai.temperature(forModel: model),
                forceStream: false
            )
            let summary = "连接成功 · \(result.model) · \(Int(result.latencyMs))ms · tokens \(result.usage.totalTokens)"
            log(.info, "AI", "测试「\(provider.name)」：\(summary)")
            return .success(summary)
        } catch {
            log(.error, "AI", "测试「\(provider.name)」失败：\(error.localizedDescription)")
            return .failure(error)
        }
    }

    func installHook(onProgress: ((Double, String) -> Void)?) async throws -> HookStatus {
        await bootstrapIfNeeded()
        hookManager.configure(wechatPath: store.settings.hook.wechatPath)
        let status = try await hookManager.installGadget(
            explicitVersionConfigPath: store.settings.hook.versionConfigPath,
            onProgress: onProgress
        )
        store.hookStatus = status
        store.settings.hook.didInstallGadget = status.gadgetInstalled
        if let backup = hookManager.lastKnownBackupPath {
            store.settings.hook.lastBackupPath = backup
            log(.info, "Hook", "官方备份：\(backup)")
        }
        if let bundledDirectory = AppResources.versionConfigDirectory,
           status.versionConfigFile.hasPrefix(bundledDirectory.path) {
            store.settings.hook.versionConfigPath = status.versionConfigFile
        }
        store.persist()
        return status
    }

    func restoreBackup() async throws -> HookStatus {
        await bootstrapIfNeeded()
        hookManager.configure(wechatPath: store.settings.hook.wechatPath)
        let status = try await hookManager.restoreBackup()
        store.hookStatus = status
        store.settings.hook.didInstallGadget = status.gadgetInstalled
        store.persist()
        return status
    }

    // MARK: Memory maintenance

    func clearMessages(conversationID: String?) async {
        do {
            if let conversationID {
                try await memory.clearMessages(conversationID: conversationID)
                store.messages[conversationID] = []
                if let index = store.conversations.firstIndex(where: { $0.id == conversationID }) {
                    store.conversations[index].lastMessageAt = nil
                    store.conversations[index].lastMessagePreview = ""
                    store.conversations[index].unreadCount = 0
                    await persistConversation(store.conversations[index])
                }
            } else {
                try await memory.clearAllMessages()
                store.messages.removeAll()
                for index in store.conversations.indices {
                    store.conversations[index].lastMessageAt = nil
                    store.conversations[index].lastMessagePreview = ""
                    store.conversations[index].unreadCount = 0
                }
                try? await memory.upsertConversations(store.conversations)
            }
            log(.info, "Memory", conversationID == nil ? "已清空全部消息" : "已清空会话消息：\(conversationID!)")
        } catch {
            log(.error, "Memory", "清空消息失败：\(error.localizedDescription)")
        }
    }

    func deleteMessage(id: String) async {
        do {
            try await memory.deleteMessage(id: id)
        } catch {
            log(.warning, "Memory", "删除消息失败：\(error.localizedDescription)")
        }
        var conversationID: String?
        for (key, list) in store.messages {
            if let index = list.firstIndex(where: { $0.id == id }) {
                var updated = list
                updated.remove(at: index)
                store.messages[key] = updated
                conversationID = key
                break
            }
        }
        if let conversationID, var conversation = store.conversations.first(where: { $0.id == conversationID }) {
            if let last = store.messages[conversationID]?.last {
                conversation.lastMessageAt = last.timestamp
                conversation.lastMessagePreview = String(last.text.prefix(80))
            } else {
                conversation.lastMessageAt = nil
                conversation.lastMessagePreview = ""
            }
            store.conversations = store.conversations.map { $0.id == conversation.id ? conversation : $0 }
            await persistConversation(conversation)
        }
        log(.info, "Memory", "已删除消息 \(id)")
    }

    func deleteConversation(id: String) async {
        do {
            try await memory.deleteConversation(id: id)
        } catch {
            log(.warning, "Memory", "删除会话失败：\(error.localizedDescription)")
        }
        store.conversations.removeAll { $0.id == id }
        store.messages[id] = nil
        forgetReplyProgress(conversationID: id)
        if store.selectedConversationID == id { store.selectedConversationID = nil }
        // Drop the conversation's memories locally instead of re-fetching all 500 rows.
        store.longTermMemories.removeAll { $0.conversationID == id }
        log(.info, "Memory", "已删除会话 \(id)")
    }

    // MARK: Memory maintenance

    func loadLongTermMemories() async {
        do {
            store.longTermMemories = try await memory.fetchMemories(limit: 500)
        } catch {
            log(.warning, "Memory", "读取长期记忆失败：\(error.localizedDescription)")
        }
    }

    func saveLongTermMemory(_ memory: LongTermMemory) async {
        do {
            var memory = memory
            // 编辑器已收敛范围，这里再兜底一次，避免其它调用方写入越界权重。
            memory.baseWeight = LongTermMemory.clampBaseWeight(memory.baseWeight)
            try await self.memory.upsertMemory(memory)
            // Patch the observable list in place instead of re-fetching and re-sorting
            // 500 rows on every edit (which also invalidated the whole MemoryView).
            applyMemoryChange(memory)
            log(.info, "Memory", "已保存长期记忆：\(memory.summary.prefix(40))")
        } catch {
            log(.error, "Memory", "保存长期记忆失败：\(error.localizedDescription)")
        }
    }

    func deleteLongTermMemory(id: String) async {
        do {
            try await memory.deleteMemory(id: id)
            store.longTermMemories.removeAll { $0.id == id }
            log(.info, "Memory", "已删除长期记忆")
        } catch {
            log(.error, "Memory", "删除长期记忆失败：\(error.localizedDescription)")
        }
    }

    /// Mirrors `MemoryStore.fetchMemories` ordering (core first, then time weight)
    /// while touching only the changed row.
    private func applyMemoryChange(_ memory: LongTermMemory) {
        var updated = memory
        if updated.conversationTitle.isEmpty, !updated.conversationID.isEmpty {
            updated.conversationTitle = store.conversations.first { $0.id == updated.conversationID }?.title ?? ""
        }
        var memories = store.longTermMemories
        if let index = memories.firstIndex(where: { $0.id == updated.id }) {
            memories[index] = updated
        } else {
            memories.append(updated)
        }
        guard let movingIndex = memories.firstIndex(where: { $0.id == updated.id }) else {
            store.longTermMemories = memories
            return
        }
        let item = memories.remove(at: movingIndex)
        let now = Date()
        let insertion = memories.firstIndex { other in
            if item.isCore != other.isCore { return item.isCore && !other.isCore }
            return item.timeWeight(now: now) > other.timeWeight(now: now)
        } ?? memories.count
        memories.insert(item, at: insertion)
        store.longTermMemories = memories
    }

    func setLongTermMemoryCore(_ memory: LongTermMemory, isCore: Bool) async {
        var updated = memory
        updated.isCore = isCore
        updated.updatedAt = Date()
        await saveLongTermMemory(updated)
    }

    /// 后台把 10 条短期窗口之外的旧消息总结到长期记忆；不阻塞回复。
    private func scheduleMemoryMaintenance(conversationID: String) {
        guard !memoryMaintenanceInFlight.contains(conversationID) else { return }
        guard let conversation = store.conversations.first(where: { $0.id == conversationID }) else { return }
        let settings = store.settings
        let providerID = conversation.providerID
            ?? settings.bot.defaultProviderID
            ?? settings.ai.defaultProviderID
        let provider = providerID.flatMap { settings.provider(id: $0) }
        memoryMaintenanceInFlight.insert(conversationID)
        Task { [weak self] in
            guard let self else { return }
            let count = await self.chatEngine.summarizeOverflow(
                conversation: conversation,
                provider: provider,
                settings: settings
            )
            if count > 0 {
                await self.loadLongTermMemories()
            }
            self.memoryMaintenanceInFlight.remove(conversationID)
        }
    }

    // MARK: Logs / stats

    /// Single entry point for runtime logging. Hands the line to `LogPipeline`, which
    /// strips ANSI codes, merges duplicates and flushes `store.logs`/SQLite in batches
    /// (≤5 UI updates/s) instead of mutating the observable array once per line.
    func log(_ level: LogLevel, _ source: String, _ message: String) {
        LogPipeline.shared.emit(level, source, message)
    }

    private func scheduleStatsPersist() {
        statsFlushTask?.cancel()
        statsFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistStats()
        }
    }

    private func persistStats() async {
        guard let data = try? JSONEncoder().encode(store.stats),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await memory.setSetting(key: "stats.json", value: text)
        try? await memory.setSetting(key: "stats.day", value: statsDay)
    }

    private func rolloverStatsIfNeeded() {
        let today = Self.dayKey()
        guard today != statsDay else { return }
        statsDay = today
        var fresh = BotStats.zero
        fresh.startedAt = store.stats.startedAt
        store.stats = fresh
        scheduleStatsPersist()
    }

    // MARK: Shutdown

    func shutdownImmediately() {
        oneBotClient?.stop()
        oneBotClient = nil
        clearReplyProgresses()
        store.imageFetcher.cancelAll()
        store.voiceFetcher.cancelAll()
        hookManager.shutdown()
        LogPipeline.shared.flushForTermination()
        let statsSnapshot = store.stats
        Task {
            await scheduler.stop()
            await persistStatsSnapshot(statsSnapshot)
            await SettingsPersistence.shared.flush()
        }
    }

    private func persistStatsSnapshot(_ stats: BotStats) async {
        guard let data = try? JSONEncoder().encode(stats),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await memory.setSetting(key: "stats.json", value: text)
    }

    // MARK: Helpers

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Cached formatter: `dayKey()` used to allocate a `DateFormatter` on every inbound
    /// message (date rollover check), which is surprisingly expensive.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    func currentSelfID() -> String { selfID }
    func activeOneBotClient() -> OneBotClient? { oneBotClient }
    func isRuntimeRunning() -> Bool { oneBotClient != nil }
}

// MARK: - AppStore runtime API

extension AppStore {
    // MARK: Bot lifecycle

    func startBot() async {
        guard !isBotRunning else { return }
        isBusy = true
        defer { isBusy = false }
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        do {
            try await coordinator.startRuntime()
            isBotRunning = true
            settings.bot.enabled = true
            persist()
            appendLog(.info, "Bot", "机器人已启动")
        } catch {
            isBotRunning = false
            settings.bot.enabled = false
            lastError = error.localizedDescription
            coordinator.log(.error, "Bot", "启动失败：\(error.localizedDescription)")
        }
    }

    func stopBot() async {
        guard isBotRunning else { return }
        isBusy = true
        defer { isBusy = false }
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.stopRuntime()
        isBotRunning = false
        settings.bot.enabled = false
        persist()
        appendLog(.info, "Bot", "机器人已停止")
    }

    /// 设置里关闭「获取图片」时调用：取消所有未完成的图片请求；
    /// 已在途的请求返回后也不再更新消息（不会写入任何 App 侧文件）。
    func cancelPendingImageFetches() {
        imageFetcher.cancelAll()
    }

    /// 重试一条语音的获取/转写（气泡「转写失败 · 重试」按钮）。
    func retryVoiceTranscription(messageID: String) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.retryVoiceTranscription(messageID: messageID)
    }

    /// 刷新 bridge `/voice_status`（语音发送句柄 / 登录稳定倒计时），供设置页展示与决策门禁。
    func refreshVoiceStatus() async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.refreshVoiceStatus()
    }

    /// 查询本机中文语音识别资源状态（设置页「语音」区展示下载引导）。
    func voiceAssetStatus() async -> VoiceAssetStatus {
        await voiceTranscription.assetStatus()
    }

    func refreshStatus() async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.refreshStatus()
    }

    /// 总览「设备与账户」卡：立即重读电量并重查 DeepSeek 余额。
    func refreshSystemVitals() async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.refreshSystemVitals()
    }

    func installHook(onProgress: ((Double, String) -> Void)? = nil) async throws {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await coordinator.installHook(onProgress: onProgress)
            appendLog(.info, "Hook", "Gadget 安装流程完成")
        } catch {
            lastError = error.localizedDescription
            coordinator.log(.error, "Hook", error.localizedDescription)
            throw error
        }
    }

    func restoreWeChatBackup() async throws {
        if isBotRunning { await stopBot() }
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await coordinator.restoreBackup()
            appendLog(.info, "Hook", "已从官方备份恢复微信")
        } catch {
            lastError = error.localizedDescription
            coordinator.log(.error, "Hook", error.localizedDescription)
            throw error
        }
    }

    func testProvider(_ provider: AIProvider) async -> Result<String, Error> {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return await coordinator.testProvider(provider)
    }

    func sendManualMessage(conversationID: String, text: String) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.sendManualMessage(conversationID: conversationID, text: text)
    }

    /// 关闭会话页的回复进度状态条（完成/失败态由用户手动收起）。
    func dismissReplyProgress(conversationID: String) {
        RuntimeRegistry.existing(for: self)?.forgetReplyProgress(conversationID: conversationID)
        if replyProgress[conversationID] != nil {
            replyProgress[conversationID] = nil
        }
    }

    // MARK: API keys (Keychain)

    /// Saves the secret in Keychain and points the provider at it. JSON only ever
    /// stores `apiKeyReference`, never the secret.
    func saveAPIKey(_ key: String, for providerID: String) throws {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
            throw RuntimeError.providerNotFound(providerID)
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? KeychainStore.shared.deleteAPIKey(for: providers[index].apiKeyReference.isEmpty ? providerID : providers[index].apiKeyReference)
            providers[index].apiKeyReference = ""
            persist()
            return
        }
        try KeychainStore.shared.setAPIKey(trimmed, for: providerID)
        providers[index].apiKeyReference = providerID
        persist()
        RuntimeRegistry.existing(for: self)?.log(.info, "Keychain", "已保存「\(providers[index].name)」的 API Key")
    }

    func apiKey(for providerID: String) -> String? {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return nil }
        let account = provider.apiKeyReference.isEmpty ? providerID : provider.apiKeyReference
        return try? KeychainStore.shared.apiKey(for: account)
    }

    func deleteAPIKey(for providerID: String) throws {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
            throw RuntimeError.providerNotFound(providerID)
        }
        let account = providers[index].apiKeyReference.isEmpty ? providerID : providers[index].apiKeyReference
        try KeychainStore.shared.deleteAPIKey(for: account)
        providers[index].apiKeyReference = ""
        persist()
        RuntimeRegistry.existing(for: self)?.log(.info, "Keychain", "已删除「\(providers[index].name)」的 API Key")
    }

    // MARK: Conversations / messages

    /// Updates one conversation in memory and persists it immediately (per-conversation
    /// settings such as working hours must survive restarts without waiting for a
    /// new inbound message).
    func saveConversation(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index] = conversation
        let coordinator = RuntimeRegistry.coordinator(for: self)
        Task {
            await coordinator.bootstrapIfNeeded()
            do {
                try await coordinator.memory.upsertConversation(conversation)
            } catch {
                coordinator.log(.warning, "Memory", "写入会话设置失败：\(error.localizedDescription)")
            }
        }
    }

    func clearMessages(conversationID: String?) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.clearMessages(conversationID: conversationID)
    }

    func deleteMessage(id: String) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.deleteMessage(id: id)
    }

    func deleteConversation(id: String) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.deleteConversation(id: id)
    }

    /// Paginated history loading for the conversation view.
    @discardableResult
    func loadMessages(conversationID: String, limit: Int = 50, before: Date? = nil) async -> [ChatMessage] {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        do {
            let page = try await coordinator.memory.fetchMessages(
                conversationID: conversationID,
                limit: limit,
                before: before
            )
            if before == nil {
                messages[conversationID] = page
            } else {
                var merged = page + (messages[conversationID] ?? [])
                var seen = Set<String>()
                merged = merged.filter { seen.insert($0.id).inserted }
                merged.sort { $0.timestamp < $1.timestamp }
                messages[conversationID] = merged
            }
            return page
        } catch {
            coordinator.log(.warning, "Memory", "分页读取失败：\(error.localizedDescription)")
            return []
        }
    }

    func searchMessages(_ query: String, limit: Int = 100) async -> [MemorySearchHit] {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return (try? await coordinator.memory.searchMessages(query: query, limit: limit)) ?? []
    }

    // MARK: Long-term memory (UI API)

    func loadLongTermMemories() async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.loadLongTermMemories()
    }

    func saveLongTermMemory(_ memory: LongTermMemory) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.saveLongTermMemory(memory)
    }

    func deleteLongTermMemory(id: String) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.deleteLongTermMemory(id: id)
    }

    func setLongTermMemoryCore(_ memory: LongTermMemory, isCore: Bool) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.setLongTermMemoryCore(memory, isCore: isCore)
    }

    func currentSelfID() -> String {
        RuntimeRegistry.existing(for: self)?.currentSelfID() ?? ""
    }

    func isRuntimeConnected() -> Bool {
        RuntimeRegistry.existing(for: self)?.activeOneBotClient()?.isConnected ?? false
    }
}
