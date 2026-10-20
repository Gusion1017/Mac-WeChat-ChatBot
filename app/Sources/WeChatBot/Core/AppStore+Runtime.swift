import AppKit
import Foundation

// MARK: - Errors

enum RuntimeError: LocalizedError {
    case providerNotFound(String)
    case noProvider
    case providerNotConfigured(String)
    case conversationNotFound(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .providerNotFound(let id): return "未找到 AI 服务：\(id)"
        case .noProvider: return "尚未配置 AI 服务，请先在「AI 模型」中添加"
        case .providerNotConfigured(let name): return "AI 服务「\(name)」缺少 API Key，请先配置"
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

    private(set) var bootstrapped = false
    private var bootstrapping = false
    private var bootstrapTask: Task<Void, Never>?

    private var oneBotClient: OneBotClient?
    private var startedOneBotConfiguration: OneBotClient.Configuration?
    private var selfID = ""
    private var inFlightConversations: Set<String> = []
    private var memoryMaintenanceInFlight: Set<String> = []
    private var lastSchedulerTasks: [ScheduledTask] = []

    private var pendingLogs: [LogEntry] = []
    private var logFlushTask: Task<Void, Never>?
    private var logWriteCount = 0
    private var statsFlushTask: Task<Void, Never>?
    private var statsDay: String = RuntimeCoordinator.dayKey()
    private var terminationObserver: NSObjectProtocol?

    init(store: AppStore) {
        self.store = store
        self.hookManager = HookManager(wechatPath: store.settings.hook.wechatPath)
        self.chatEngine = ChatEngine(memory: memory, aiClient: aiClient)

        hookManager.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.store.hookStatus = status
            self.store.gatewayConnected = status.gatewayConnected
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
    }

    deinit {
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
        do {
            store.conversations = try await memory.fetchConversations(limit: 300)
        } catch {
            log(.warning, "Database", "读取会话失败：\(error.localizedDescription)")
        }

        // Preload the newest page for each conversation so the UI has content immediately.
        var preloaded: [String: [ChatMessage]] = [:]
        for conversation in store.conversations {
            if let page = try? await memory.fetchMessages(conversationID: conversation.id, limit: 30) {
                preloaded[conversation.id] = page
            }
        }
        store.messages = preloaded

        if let persistedLogs = try? await memory.fetchLogs(limit: 500) {
            store.logs = persistedLogs.reversed()
            if store.logs.count > 2000 { store.logs.removeFirst(store.logs.count - 2000) }
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

        if let id = try? await memory.setting(key: "onebot.self_id"), !id.isEmpty {
            selfID = id
        }
        backfillSelfMentionNames()
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
        store.hookStatus = status
        store.gatewayConnected = status.gatewayConnected
        store.settings.hook.didInstallGadget = status.gadgetInstalled
        if let backup = hookManager.lastKnownBackupPath {
            store.settings.hook.lastBackupPath = backup
        }
        // 只回写仓库自带的版本文件；运行期合并配置（Application Support/runtime）
        // 是 App 生成物，不能污染用户显式配置（否则切版本会错配）。
        if !status.versionConfigFile.isEmpty,
           let bundledDirectory = AppResources.versionConfigDirectory,
           status.versionConfigFile.hasPrefix(bundledDirectory.path) {
            store.settings.hook.versionConfigPath = status.versionConfigFile
        }
        log(.debug, "Hook", "状态 \(status.state.label)：\(status.detail)")
    }

    // MARK: Start / stop

    /// 4.1.15.55 使用 R3 原生发送（构造 newsendmsg task + slot13 提交）；
    /// 4.1.12 及更早版本保持 legacy 发送路径，不做任何覆盖。
    /// 首次使用 R3 前需要在本机微信手动发一条消息以捕获 hand-off 闭包（种子）。
    private func nativeSendConfigOverrides() -> [String: String] {
        let installation = WeChatInstallation.inspect(path: store.settings.hook.wechatPath)
        let is415 = installation.version == "4.1.15.55" || installation.build == "270135"
        guard is415 else { return [:] }
        if store.settings.hook.enableNativeSend {
            log(.info, "Hook", "微信 4.1.15.55：启用 R3 原生发送（首次使用前需在本机微信手动发一条消息以捕获发送句柄）")
            return [
                "enableSend": "true",
                "req2bufSendMode": "r3",
                "r3ClosureCapture": "true",
                "r3Slot13Capture": "true",
                "r3QueueUntilSeed": "true"
            ]
        } else {
            log(.warning, "Hook", "微信 4.1.15.55：R3 原生发送已关闭，主动发送不可用（接收不受影响）")
            return [
                "enableSend": "false",
                "req2bufSendMode": "off"
            ]
        }
    }

    func startRuntime() async throws {
        await bootstrapIfNeeded()
        guard !store.isBotRunning, oneBotClient == nil else { return }

        guard let provider = store.settings.defaultProvider else { throw RuntimeError.noProvider }
        guard aiClient.hasCredential(for: provider) else {
            throw RuntimeError.providerNotConfigured(provider.name)
        }

        var token = store.settings.onebot.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            token = Self.randomToken()
            store.settings.onebot.token = token
            store.persist()
        }

        if store.settings.hook.autoStartBridge {
            let overrides = nativeSendConfigOverrides()
            do {
                try await hookManager.startBridge(
                    host: store.settings.onebot.host,
                    port: store.settings.onebot.port,
                    token: token,
                    gadgetPort: store.settings.hook.gadgetPort,
                    explicitVersionConfigPath: store.settings.hook.versionConfigPath,
                    explicitImagePath: store.settings.onebot.imagePath,
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
        oneBotClient = client
        startedOneBotConfiguration = configuration
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
        await scheduler.stop()
        if store.settings.hook.autoStartBridge {
            hookManager.stopBridge()
        }
        flushPendingLogs()
        await persistStats()
        await SettingsPersistence.shared.flush()
        log(.info, "Bot", "机器人运行时已停止")
    }

    // MARK: OneBot state / events

    private func handleOneBotState(_ state: OneBotConnectionState) {
        switch state {
        case .connected:
            store.gatewayConnected = true
            hookManager.setGatewayConnected(true)
            store.hookStatus.gatewayConnected = true
            store.hookStatus.state = .connected
            store.hookStatus.detail = "已连接微信"
            log(.info, "OneBot", "WebSocket 已连接")
        case .connecting:
            store.gatewayConnected = false
            hookManager.setGatewayConnected(false, detail: "正在连接 bridge…")
            log(.debug, "OneBot", "正在连接…")
        case .reconnecting:
            store.gatewayConnected = false
            hookManager.setGatewayConnected(false, detail: "连接断开，自动重连中…")
            log(.warning, "OneBot", "连接断开，正在自动重连")
        case .stopped:
            store.gatewayConnected = false
            hookManager.setGatewayConnected(false, detail: "已停止")
        }
    }

    private func handle(event: OneBotEvent) async {
        let conversationID = event.conversationID
        guard !conversationID.isEmpty else { return }
        let receivedAt = Date()
        rolloverStatsIfNeeded()

        if !event.selfID.isEmpty,
           event.selfID != event.groupID,
           event.selfID != selfID {
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
        let chatMessage = makeChatMessage(from: event)

        var list = store.messages[conversationID] ?? []
        if list.contains(where: { $0.id == chatMessage.id }) { return }
        list.append(chatMessage)
        list.sort { $0.timestamp < $1.timestamp }
        if list.count > 300 { list.removeFirst(list.count - 300) }
        store.messages[conversationID] = list

        await persistConversation(conversation)
        do {
            try await memory.upsertMessages([chatMessage])
        } catch {
            log(.warning, "Database", "写入消息失败：\(error.localizedDescription)")
        }

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
        await evaluateAndReply(conversation: conversation, message: chatMessage, receivedAt: receivedAt)
        scheduleMemoryMaintenance(conversationID: conversationID)
    }

    private func upsertConversation(for event: OneBotEvent) -> Conversation {
        let existingIndex = store.conversations.firstIndex { $0.id == event.conversationID }
        var conversation: Conversation
        if let index = existingIndex {
            conversation = store.conversations[index]
        } else {
            let title: String
            if event.isGroup {
                title = "群聊 \(event.groupID ?? event.conversationID)"
            } else {
                title = event.senderName.isEmpty ? event.conversationID : event.senderName
            }
            conversation = Conversation(
                id: event.conversationID,
                kind: event.conversationKind,
                title: title
            )
        }
        if event.isGroup {
            if !event.senderName.isEmpty { conversation.subtitle = event.senderName }
        } else if !event.senderName.isEmpty {
            conversation.title = event.senderName
        }
        conversation.lastMessageAt = event.timestamp
        conversation.lastMessagePreview = String(event.plainText.prefix(80))
        // 正在查看的会话不累计未读：打开即已读，避免切换会话后还要额外点一次。
        if !event.isSelf && store.selectedConversationID != event.conversationID {
            conversation.unreadCount += 1
        }

        if let index = existingIndex {
            store.conversations[index] = conversation
        } else {
            store.conversations.append(conversation)
        }
        store.conversations.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast)
        }
        return conversation
    }

    private func makeChatMessage(from event: OneBotEvent) -> ChatMessage {
        let id = event.messageID.isEmpty ? "ob-\(UUID().uuidString)" : "ob-\(event.messageID)"
        return ChatMessage(
            id: id,
            conversationID: event.conversationID,
            senderID: event.isSelf ? (event.selfID.isEmpty ? "self" : event.selfID) : event.userID,
            senderName: event.isSelf ? "我" : event.senderName,
            direction: event.isSelf ? .outgoing : .incoming,
            kind: event.primaryMessageKind,
            text: event.plainText,
            mediaPath: event.mediaPath,
            mediaURL: event.primaryMediaSegment?.url,
            timestamp: event.timestamp,
            status: event.isSelf ? .sent : .received,
            replyToID: nil,
            rawJSON: event.rawJSON
        )
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

    /// 启动时从已持久化的近 30 条消息中回填群昵称。
    /// 这样升级后无需等待下一次结构化 @ 即可修复历史会话里的纯文本 @。
    private func backfillSelfMentionNames() {
        guard !selfID.isEmpty else { return }
        let groupIDs = Set(store.conversations.filter { $0.kind == .group }.map(\.id))
        guard !groupIDs.isEmpty else { return }
        var learned = store.settings.bot.selfMentionNames ?? [:]
        var changed = false
        for conversationID in groupIDs {
            for message in store.messages[conversationID] ?? [] {
                guard let rawJSON = message.rawJSON,
                      let data = rawJSON.data(using: .utf8),
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
                if learned[conversationID] != name {
                    learned[conversationID] = name
                    changed = true
                }
            }
        }
        guard changed else { return }
        store.settings.bot.selfMentionNames = learned
        store.persist()
        log(.info, "Bot", "已从历史消息回填机器人群昵称：\(learned.count) 个群")
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

        guard let settingsProvider = store.settings.provider(id: evaluation.providerID) else {
            log(.warning, "AI", "未找到可用 AI 服务，跳过回复")
            return
        }
        guard aiClient.hasCredential(for: settingsProvider) else {
            log(.warning, "AI", "「\(settingsProvider.name)」未配置 API Key，跳过回复")
            return
        }
        let persona = store.settings.persona(id: evaluation.personaID)
        var provider = settingsProvider
        if let model = evaluation.model, !model.isEmpty { provider.model = model }
        if let personaModel = persona?.model, !personaModel.isEmpty { provider.model = personaModel }

        let history = store.messages[conversation.id] ?? []
        do {
            let plan = try await chatEngine.generateReply(
                conversation: conversation,
                incoming: message,
                settings: store.settings,
                persona: persona,
                provider: provider,
                history: history,
                dryRun: store.settings.bot.dryRun
            )
            await deliver(plan: plan, conversation: conversation, receivedAt: receivedAt)
            ruleEngine.noteReply(conversationID: conversation.id)
            log(.info, "AI", "\(conversation.displayTitle) 生成回复（\(Int(plan.latencyMs))ms，tokens \(plan.usage.totalTokens)，\(evaluation.triggerLabel)）")
        } catch {
            store.stats.failedToday += 1
            scheduleStatsPersist()
            store.lastError = error.localizedDescription
            log(.error, "AI", "生成回复失败：\(error.localizedDescription)")
        }
    }

    private func deliver(plan: ChatReplyPlan, conversation: Conversation, receivedAt: Date) async {
        if plan.dryRun {
            let text = "（dry-run）将回复：\(plan.fullText)"
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
            await persistMessage(message)
            if var updated = store.conversations.first(where: { $0.id == conversation.id }) {
                updated.lastMessageAt = message.timestamp
                updated.lastMessagePreview = String(text.prefix(80))
                store.conversations = store.conversations.map { $0.id == updated.id ? updated : $0 }
                await persistConversation(updated)
            }
            return
        }

        let humanize = store.settings.bot.humanize
        var sentAny = false
        for (index, segment) in plan.segments.enumerated() {
            if humanize.enabled, index < plan.delaysMs.count, plan.delaysMs[index] > 0 {
                log(.debug, "Humanize", "分段 \(index + 1)/\(plan.segments.count) 延迟 \(plan.delaysMs[index])ms")
                try? await Task.sleep(nanoseconds: UInt64(plan.delaysMs[index]) * 1_000_000)
            }
            if humanize.enabled && humanize.typingIndicator && index == 0 {
                log(.debug, "Humanize", "输入端「正在输入」指示由微信客户端展示，bridge 暂未暴露接口")
            }
            let sent = await sendOutgoingText(segment, conversation: conversation)
            sentAny = sentAny || sent
        }

        guard sentAny else { return }
        store.stats.repliedToday += 1
        store.stats.lastReplyAt = Date()
        recordReplyLatency(plan.latencyMs)
        let endToEndMs = Int(Date().timeIntervalSince(receivedAt) * 1000)
        log(.info, "Bot", "回复投递完成：端到端 \(endToEndMs)ms（AI \(Int(plan.latencyMs))ms，拟人化 \(plan.delaysMs.first ?? 0)ms，bridge 环节见上一条）")
        scheduleStatsPersist()
    }

    // MARK: Sending

    @discardableResult
    func sendOutgoingText(_ text: String, conversation: Conversation) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var message = ChatMessage(
            id: "local-\(UUID().uuidString)",
            conversationID: conversation.id,
            senderID: selfID.isEmpty ? "self" : selfID,
            senderName: "我",
            direction: .outgoing,
            kind: .text,
            text: trimmed,
            timestamp: Date(),
            status: .pending
        )
        appendMessage(message)
        await persistMessage(message)

        do {
            guard let client = oneBotClient else { throw OneBotError.notRunning }
            let sendStartedAt = Date()
            try await client.sendText(
                conversationID: conversation.id,
                isGroup: conversation.kind == .group,
                text: trimmed
            )
            message.status = .sent
            updateMessage(message)
            await persistMessage(message)
            updateConversationAfterSend(conversation: conversation, message: message)
            await persistConversation(conversation)
            let bridgeRTT = Int(Date().timeIntervalSince(sendStartedAt) * 1000)
            log(.info, "Bot", "已发送 \(conversation.kind.label)消息 → \(conversation.displayTitle)：\(trimmed.prefix(60))（bridge 往返 \(bridgeRTT)ms）")
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

    private func updateConversationAfterSend(conversation: Conversation, message: ChatMessage) {
        guard var updated = store.conversations.first(where: { $0.id == conversation.id }) else { return }
        updated.lastMessageAt = message.timestamp
        updated.lastMessagePreview = String(message.text.prefix(80))
        store.conversations = store.conversations.map { $0.id == updated.id ? updated : $0 }
        store.conversations.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast)
        }
    }

    private func appendMessage(_ message: ChatMessage) {
        var list = store.messages[message.conversationID] ?? []
        if !list.contains(where: { $0.id == message.id }) { list.append(message) }
        list.sort { $0.timestamp < $1.timestamp }
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
    }

    // MARK: Manual actions

    func sendManualMessage(conversationID: String, text: String) async {
        await bootstrapIfNeeded()
        var conversation: Conversation
        if let existing = store.conversations.first(where: { $0.id == conversationID }) {
            conversation = existing
        } else {
            conversation = Conversation(id: conversationID, kind: conversationID.contains("@chatroom") ? .group : .direct,
                                         title: conversationID)
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
        if store.selectedConversationID == id { store.selectedConversationID = nil }
        await loadLongTermMemories()
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
            try await self.memory.upsertMemory(memory)
            await loadLongTermMemories()
            log(.info, "Memory", "已保存长期记忆：\(memory.summary.prefix(40))")
        } catch {
            log(.error, "Memory", "保存长期记忆失败：\(error.localizedDescription)")
        }
    }

    func deleteLongTermMemory(id: String) async {
        do {
            try await memory.deleteMemory(id: id)
            await loadLongTermMemories()
            log(.info, "Memory", "已删除长期记忆")
        } catch {
            log(.error, "Memory", "删除长期记忆失败：\(error.localizedDescription)")
        }
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

    func log(_ level: LogLevel, _ source: String, _ message: String) {
        store.appendLog(level, source, message)
        if let entry = store.logs.last {
            pendingLogs.append(entry)
            scheduleLogFlush()
        }
    }

    private func scheduleLogFlush() {
        if pendingLogs.count >= 20 {
            flushPendingLogs()
            return
        }
        guard logFlushTask == nil else { return }
        logFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingLogs()
        }
    }

    private func flushPendingLogs() {
        logFlushTask?.cancel()
        logFlushTask = nil
        guard !pendingLogs.isEmpty else { return }
        let batch = pendingLogs
        pendingLogs = []
        logWriteCount += batch.count
        Task { [weak self] in
            guard let self else { return }
            try? await self.memory.appendLogs(batch)
            if self.logWriteCount >= 100 {
                self.logWriteCount = 0
                try? await self.memory.pruneLogs(keep: 5000)
            }
        }
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
        hookManager.shutdown()
        flushPendingLogs()
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

    static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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

    func refreshStatus() async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.refreshStatus()
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
