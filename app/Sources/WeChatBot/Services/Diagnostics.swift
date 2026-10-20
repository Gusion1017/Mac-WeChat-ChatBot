import Foundation

/// Lightweight in-process self-test, enabled with `WECHATAI_SELFTEST=1`.
///
/// Set `WECHATAI_SELFTEST_EXIT=1` to terminate with a non-zero exit code on failure,
/// which makes it usable from CI/verification scripts without a UI test harness.
/// Results are printed to stdout and also logged into the app log buffer.
enum Diagnostics {
    private static var passed = 0
    private static var failed = 0
    private static var warnings = 0

    @MainActor
    static func runAll() async -> Int {
        passed = 0
        failed = 0
        warnings = 0
        print("[selftest] ===== WeChatAI core service self-test =====")

        await testSettingsPersistence()
        await testKeychain()
        await testMemoryStore()
        await testAIClientConstruction()
        await testOneBotParsing()
        await testRuleEngine()
        await testScheduler()
        await testChatEngineShaping()

        print("[selftest] RESULT passed=\(passed) failed=\(failed) warnings=\(warnings)")
        print("[selftest] ==========================================")
        fflush(stdout)
        return failed == 0 ? 0 : 1
    }

    // MARK: Harness

    private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("[selftest] PASS \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        } else {
            failed += 1
            print("[selftest] FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    private static func warn(_ name: String, _ detail: String) {
        warnings += 1
        print("[selftest] WARN \(name) — \(detail)")
    }

    // MARK: Settings persistence

    private static func testSettingsPersistence() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-selftest-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("config.json")
        do {
            let persistence = SettingsPersistence(fileURL: fileURL)
            var settings = AppSettings.default
            settings.bot.whitelistEntries = ["wxid_test"]
            settings.providers[0].apiKeyReference = "provider-deepseek-default"
            let wrote = try await persistence.save(settings)
            check("SettingsPersistence.save", wrote)
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            let whitelistMatches = decoded.bot.whitelistEntries == ["wxid_test"]
            let referenceMatches = decoded.providers.first?.apiKeyReference == "provider-deepseek-default"
            check("SettingsPersistence.roundtrip", whitelistMatches && referenceMatches)
            let raw = String(data: data, encoding: .utf8) ?? ""
            check("SettingsPersistence.no-plaintext-secret",
                  !raw.lowercased().contains("\"apikey\"") && !raw.contains("sk-"),
                  "只允许 apiKeyReference")
            let wroteAgain = try await persistence.save(settings)
            check("SettingsPersistence.skip-identical-write", wroteAgain == false)
            try? FileManager.default.removeItem(at: directory)
        } catch {
            check("SettingsPersistence", false, error.localizedDescription)
        }
    }

    // MARK: Keychain

    private static func testKeychain() async {
        let account = "selftest-\(UUID().uuidString)"
        let store = KeychainStore()
        do {
            try store.setAPIKey("sk-selftest-not-real", for: account)
            let read = try store.apiKey(for: account)
            check("Keychain.set/get", read == "sk-selftest-not-real")
            check("Keychain.has", store.hasAPIKey(for: account))
            try store.deleteAPIKey(for: account)
            check("Keychain.delete", (try store.apiKey(for: account)) == nil)
        } catch {
            // Unsigned `swift run` binaries may be denied Keychain access on some Macs.
            warn("Keychain", "当前构建无法访问 Keychain（打包签名后应正常）：\(error.localizedDescription)")
        }
    }

    // MARK: MemoryStore

    private static func testMemoryStore() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-selftest-db-\(UUID().uuidString)", isDirectory: true)
        let dbURL = directory.appendingPathComponent("chatbot.sqlite")
        let store = MemoryStore(databaseURL: dbURL)
        do {
            try await store.open()
            check("MemoryStore.open", FileManager.default.fileExists(atPath: dbURL.path))

            let conversation = Conversation(id: "wxid_a", kind: .direct, title: "张三", lastMessageAt: Date())
            try await store.upsertConversation(conversation)
            let fetched = try await store.conversation(id: "wxid_a")
            check("MemoryStore.conversation-roundtrip", fetched?.title == "张三")

            let now = Date()
            var messages: [ChatMessage] = []
            for index in 0..<5 {
                let senderID: String = index % 2 == 0 ? "wxid_a" : "self"
                let senderName: String = index % 2 == 0 ? "张三" : "我"
                let direction: ChatDirection = index % 2 == 0 ? .incoming : .outgoing
                let text: String = index == 2 ? "请问 DeepSeek 怎么配置" : "消息 \(index)"
                let message = ChatMessage(
                    id: "m\(index)",
                    conversationID: "wxid_a",
                    senderID: senderID,
                    senderName: senderName,
                    direction: direction,
                    kind: .text,
                    text: text,
                    timestamp: now.addingTimeInterval(Double(index))
                )
                messages.append(message)
            }
            try await store.upsertMessages(messages)
            check("MemoryStore.messages-count", (try await store.messageCount(conversationID: "wxid_a")) == 5)

            let page = try await store.fetchMessages(conversationID: "wxid_a", limit: 2)
            check("MemoryStore.pagination", page.count == 2 && page.last?.id == "m4")
            let older = try await store.fetchMessages(conversationID: "wxid_a", limit: 10,
                                                      before: now.addingTimeInterval(2.5))
            check("MemoryStore.pagination-before", older.count == 3 && older.last?.id == "m2")

            let hits = try await store.searchMessages(query: "DeepSeek")
            check("MemoryStore.search", hits.count == 1 && hits.first?.message.id == "m2")
            let emptyHits = try await store.searchMessages(query: "")
            check("MemoryStore.search-empty", emptyHits.isEmpty)

            let logs = [
                LogEntry(level: .info, source: "test", message: "hello"),
                LogEntry(level: .error, source: "test", message: "boom")
            ]
            try await store.appendLogs(logs)
            let fetchedLogs = try await store.fetchLogs(limit: 10, minimumLevel: .error)
            check("MemoryStore.logs-filter", fetchedLogs.count == 1 && fetchedLogs.first?.level == .error)

            let task = ScheduledTask(name: "早安", conversationID: "wxid_a", content: "早上好",
                                     repeatRule: .daily, fireAt: now, weekdays: [2, 3, 4, 5, 6])
            try await store.replaceSchedules([task])
            let schedules = try await store.fetchSchedules()
            check("MemoryStore.schedules", schedules.count == 1 && schedules.first?.name == "早安")

            try await store.setSetting(key: "k", value: "v")
            check("MemoryStore.settings", (try await store.setting(key: "k")) == "v")

            try await store.deleteMessage(id: "m0")
            check("MemoryStore.delete-message", (try await store.messageCount(conversationID: "wxid_a")) == 4)
            try await store.clearMessages(conversationID: "wxid_a")
            check("MemoryStore.clear-conversation",
                  (try await store.messageCount(conversationID: "wxid_a")) == 0)
            try await store.upsertMessages(messages)
            try await store.clearAllMessages()
            check("MemoryStore.clear-all", (try await store.messageCount()) == 0)

            await store.close()
            check("MemoryStore.close", true)
            try? FileManager.default.removeItem(at: directory)
        } catch {
            check("MemoryStore", false, error.localizedDescription)
            await store.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: AIClient construction

    private static func testAIClientConstruction() async {
        let client = AIClient(keychain: KeychainStore(service: "com.gusionw.wechatai.selftest"))
        for kind in ProviderKind.allCases {
            let baseURL = kind.defaultBaseURL.isEmpty ? "http://127.0.0.1:11434/v1" : kind.defaultBaseURL
            let model = kind.defaultModel.isEmpty ? "local-model" : kind.defaultModel
            var provider = AIProvider(name: kind.label, kind: kind,
                                      baseURL: baseURL,
                                      model: model)
            provider.apiKeyReference = "selftest-\(kind.rawValue)"
            do {
                let endpoint = try AIClient.endpoint(for: provider)
                check("AIClient.endpoint.\(kind.rawValue)",
                      endpoint.absoluteString.hasSuffix("/chat/completions"),
                      endpoint.absoluteString)
                let body = try AIClient.requestBody(
                    messages: [.system("s"), .user("u")],
                    provider: provider,
                    stream: true
                )
                let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                let messages = object?["messages"] as? [[String: Any]]
                check("AIClient.body.\(kind.rawValue)",
                      (object?["stream"] as? Bool) == true
                      && (object?["model"] as? String) == AIClient.effectiveModel(for: provider)
                      && messages?.count == 2,
                      "model=\(object?["model"] as? String ?? "?")")
            } catch {
                check("AIClient.\(kind.rawValue)", false, error.localizedDescription)
            }
        }

        var custom = AIProvider(name: "bad", kind: .custom, baseURL: "", model: "")
        custom.apiKeyReference = "x"
        do {
            _ = try AIClient.endpoint(for: custom)
            check("AIClient.reject-empty-baseURL", false)
        } catch {
            check("AIClient.reject-empty-baseURL", error is AIError)
        }

        var keyless = AIProvider(name: "local", kind: .ollama, baseURL: "", model: "")
        keyless.apiKeyReference = ""
        check("AIClient.ollama-keyless", client.hasCredential(for: keyless))

        var deepseek = AIProvider(name: "ds", kind: .deepSeek, baseURL: "", model: "")
        deepseek.apiKeyReference = "missing-account"
        check("AIClient.deepseek-needs-key", !client.hasCredential(for: deepseek))

        let mapped = AIClient.mapTransportError(URLError(.timedOut))
        check("AIClient.error-mapping", mapped == .timedOut && mapped.isRetryable)
    }

    // MARK: OneBot parsing

    private static func testOneBotParsing() async {
        let json = """
        {"self_id":"wxid_self","user_id":"wxid_target","group_id":"123@chatroom",
         "sender":{"user_id":"wxid_target","nickname":"小明"},"time":1760000000,
         "message_id":"m1","message":[{"type":"text","data":{"text":"你好"}},
         {"type":"image","data":{"url":"file:///tmp/does-not-exist.jpg"}}],
         "raw_message":"你好","message_type":"group"}
        """
        let events = OneBotEventParser.parse(data: Data(json.utf8))
        check("OneBot.parse-group", events.count == 1)
        if let event = events.first {
            check("OneBot.group-id", event.conversationID == "123@chatroom" && event.isGroup)
            check("OneBot.sender", event.userID == "wxid_target" && event.senderName == "小明")
            check("OneBot.segments", event.segments.count == 2 && event.primaryMessageKind == .image)
            check("OneBot.plain-text", event.plainText.contains("你好") && event.plainText.contains("[图片]"))
            check("OneBot.timestamp", abs(event.timestamp.timeIntervalSince1970 - 1_760_000_000) < 1)
        }

        let privateJSON = """
        {"self_id":"wxid_self","user_id":"wxid_self","sender":{"user_id":"wxid_self","nickname":"我"},
         "time":1760000100,"message_id":"m2","message":"自己发的消息","message_type":"private"}
        """
        let privateEvents = OneBotEventParser.parse(data: Data(privateJSON.utf8))
        check("OneBot.string-message", privateEvents.first?.segments.first?.text == "自己发的消息")
        check("OneBot.self-detection", privateEvents.first?.isSelf == true)
        check("OneBot.direct-kind", privateEvents.first?.conversationKind == .direct)

        check("OneBot.invalid-frame", OneBotEventParser.parse(data: Data("not-json".utf8)).isEmpty)
        check("OneBot.empty-array", OneBotEventParser.parse(data: Data("[]".utf8)).isEmpty)

        let segments = OneBotClient.encodeSegments([.text("hi"), OneBotSegment(type: "image", file: "base64://abc")])
        check("OneBot.encode-segments", segments.count == 2 && segments[1]["type"] as? String == "image")
    }

    // MARK: RuleEngine

    private static func testRuleEngine() async {
        var settings = AppSettings.default
        settings.bot.enabled = true
        settings.bot.replyToDirect = true
        settings.bot.groupTrigger = .mention
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        settings.bot.workingHours.enabled = false

        let conversation = Conversation(id: "wxid_a", kind: .direct, title: "张三")
        let message = ChatMessage(id: "m1", conversationID: "wxid_a", senderID: "wxid_a", senderName: "张三",
                                  direction: .incoming, text: "你好", timestamp: Date())
        let engine = RuleEngine()

        let context = RuleEngine.Context(conversation: conversation, message: message,
                                         settings: settings, selfID: "wxid_self")
        check("RuleEngine.direct-default", engine.evaluate(context).shouldReply)

        settings.bot.whitelistEntries = ["wxid_other"]
        let whitelistContext = RuleEngine.Context(conversation: conversation, message: message,
                                                  settings: settings, selfID: "wxid_self")
        check("RuleEngine.whitelist-block", !engine.evaluate(whitelistContext).shouldReply)
        settings.bot.whitelistEntries = []

        settings.bot.blacklistEntries = ["wxid_a"]
        let blacklistContext = RuleEngine.Context(conversation: conversation, message: message,
                                                  settings: settings, selfID: "wxid_self")
        check("RuleEngine.blacklist-block", !engine.evaluate(blacklistContext).shouldReply)
        settings.bot.blacklistEntries = []

        var groupConversation = conversation
        groupConversation.id = "123@chatroom"
        groupConversation.kind = .group
        var groupMessage = message
        groupMessage.conversationID = "123@chatroom"
        groupMessage.rawJSON = "{\"message\":[{\"type\":\"at\",\"data\":{\"qq\":\"wxid_self\"}}]}"
        let groupContext = RuleEngine.Context(conversation: groupConversation, message: groupMessage,
                                              settings: settings, selfID: "wxid_self")
        check("RuleEngine.group-mention", engine.evaluate(groupContext).shouldReply)

        var plainGroupMessage = groupMessage
        plainGroupMessage.rawJSON = nil
        plainGroupMessage.text = "普通聊天"
        let plainGroupContext = RuleEngine.Context(conversation: groupConversation, message: plainGroupMessage,
                                                   settings: settings, selfID: "wxid_self")
        check("RuleEngine.group-no-mention", !engine.evaluate(plainGroupContext).shouldReply)

        settings.bot.keywords = ["天气"]
        settings.bot.groupTriggers = [.keyword]
        settings.bot.cooldownSeconds = 60
        var keywordMessage = plainGroupMessage
        keywordMessage.text = "今天天气如何"
        let keywordContext = RuleEngine.Context(conversation: groupConversation, message: keywordMessage,
                                                settings: settings, selfID: "wxid_self")
        check("RuleEngine.keyword", engine.evaluate(keywordContext).shouldReply)
        engine.noteReply(conversationID: groupConversation.id)
        check("RuleEngine.cooldown", !engine.evaluate(keywordContext).shouldReply)
    }

    // MARK: Scheduler

    private static func testScheduler() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 19 // Monday
        components.hour = 12
        components.minute = 0
        let fireAt = calendar.date(from: components) ?? Date()

        var daily = ScheduledTask(name: "daily", conversationID: "c", content: "x",
                                  repeatRule: .daily, fireAt: fireAt)
        daily.nextFireAt = SchedulerService.nextFireDate(for: daily, after: fireAt.addingTimeInterval(3600),
                                                         calendar: calendar)
        check("Scheduler.daily-next-day",
              daily.nextFireAt?.timeIntervalSince(fireAt.addingTimeInterval(86_400)) == 0,
              daily.nextFireAt?.description ?? "nil")

        var once = ScheduledTask(name: "once", conversationID: "c", content: "x",
                                 repeatRule: .once, fireAt: fireAt.addingTimeInterval(3600))
        check("Scheduler.once-future",
              SchedulerService.nextFireDate(for: once, after: fireAt, calendar: calendar) != nil)
        check("Scheduler.once-past",
              SchedulerService.nextFireDate(for: once, after: fireAt.addingTimeInterval(7200), calendar: calendar) == nil)

        var weekly = ScheduledTask(name: "weekly", conversationID: "c", content: "x",
                                   repeatRule: .weekly, fireAt: fireAt, weekdays: [2]) // Monday
        let nextWeekly = SchedulerService.nextFireDate(for: weekly, after: fireAt.addingTimeInterval(3600),
                                                       calendar: calendar)
        let weekday = nextWeekly.map { calendar.component(.weekday, from: $0) }
        check("Scheduler.weekly", nextWeekly != nil && weekday == 2)
        _ = weekly

        var weekdays = ScheduledTask(name: "weekdays", conversationID: "c", content: "x",
                                     repeatRule: .weekdays, fireAt: fireAt)
        let friday = calendar.date(byAdding: .day, value: 4, to: fireAt) ?? fireAt
        let nextWorkday = SchedulerService.nextFireDate(for: weekdays, after: friday.addingTimeInterval(3600),
                                                        calendar: calendar)
        let workdayWeekday = nextWorkday.map { calendar.component(.weekday, from: $0) }
        check("Scheduler.weekdays", workdayWeekday == 2 || workdayWeekday == 3 || workdayWeekday == 4
            || workdayWeekday == 5 || workdayWeekday == 6)
        _ = weekdays

        let normalized = SchedulerService.normalize([
            ScheduledTask(name: "expired", conversationID: "c", content: "x",
                          repeatRule: .once, fireAt: fireAt)
        ], now: fireAt.addingTimeInterval(3600), calendar: calendar)
        check("Scheduler.normalize-expired-once", normalized.first?.enabled == false)
    }

    // MARK: ChatEngine shaping

    private static func testChatEngineShaping() async {
        var humanize = HumanizeSettings()
        humanize.enabled = true
        humanize.splitMessages = true
        humanize.maxSegments = 3
        let text = "你好呀。今天过得怎么样？我在想周末要不要一起去看电影！如果你有空的话我们可以约个时间。"
        let segments = ChatEngine.splitReply(text, humanize: humanize)
        check("ChatEngine.split-cap", !segments.isEmpty && segments.count <= 3,
              "segments=\(segments.count)")
        check("ChatEngine.split-nonempty", segments.allSatisfy { !$0.isEmpty })

        var disabled = humanize
        disabled.splitMessages = false
        let single = ChatEngine.splitReply(text, humanize: disabled)
        check("ChatEngine.split-disabled", single.count == 1)

        let merged = ChatEngine.mergeAdjacentRoles([
            .user("a"), .user("b"), .assistant("c"), .assistant("d")
        ])
        check("ChatEngine.merge-roles", merged.count == 2 && merged[0].content == "a\nb")

        let tokens = ChatEngine.memoryTokens(from: "你好，请问DeepSeek的API怎么配置？")
        check("ChatEngine.memory-tokens", tokens.contains("DeepSeek"))
    }
}
