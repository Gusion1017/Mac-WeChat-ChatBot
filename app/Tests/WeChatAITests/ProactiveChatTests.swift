import XCTest

@testable import WeChatAI

/// 主动聊天（2026-10-28）的设置、运行期状态、决策矩阵与提示词测试。
///
/// 覆盖范围：
/// - `ProactiveChatSettings`：默认值、范围收敛、名单/话题清洗、时段修正与逐键 Codable 兼容；
/// - `ProactiveChatRuntimeState`：跨日清零、每日计数、「等待回复」标记与活动时间；
/// - `ProactiveChatPlanner.evaluate`：全部硬门槛、静默/间隔、每日上限与概率边界（固定时间 +
///   固定随机值，不读数据库、不发网络）；
/// - `ChatEngine.buildProactiveMessages`：system/user 结构、人格/提示词/话题注入、历史方向映射
///   与短期窗口上限（临时目录，`AIClient()` 只构造、不发请求）。
///
/// 时间一律用固定 UTC 日历构造（`2026-10-28 12:00`），避免测试依赖机器时区。
final class ProactiveChatTests: XCTestCase {
    private let targetID = "wxid_proactive_target"
    private let otherID = "wxid_other"

    // MARK: - 固定时间

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// 固定「现在」：2026-10-28（周三）12:00 UTC。
    private var fixedNow: Date { date(2026, 10, 28, 12, 0) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    // MARK: - ChatEngine 临时环境

    private var directory: URL?
    private var memoryStore: MemoryStore?
    private var engine: ChatEngine?

    override func tearDownWithError() throws {
        if let memoryStore {
            Task { await memoryStore.close() }
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        memoryStore = nil
        engine = nil
    }

    /// 临时目录里的 `ChatEngine`：`AIClient()` 只构造客户端，不发起网络请求。
    private func makeEngine() throws -> ChatEngine {
        if let engine { return engine }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-proactive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        let engine = ChatEngine(memory: store, aiClient: AIClient())
        self.directory = directory
        self.memoryStore = store
        self.engine = engine
        return engine
    }

    // MARK: - 构造辅助

    private func makeProactive(
        enabled: Bool = true,
        conversationIDs: [String]? = nil,
        idleMinutes: Int = 180,
        maxPerConversationPerDay: Int = 2,
        skipIfUnanswered: Bool = true,
        activeHours: WorkingHours? = nil,
        prompt: String = ProactiveChatSettings.defaultPrompt,
        topics: [String] = []
    ) -> ProactiveChatSettings {
        var proactive = ProactiveChatSettings()
        proactive.enabled = enabled
        proactive.conversationIDs = conversationIDs ?? [targetID]
        proactive.idleMinutes = idleMinutes
        proactive.maxPerConversationPerDay = maxPerConversationPerDay
        proactive.skipIfUnanswered = skipIfUnanswered
        proactive.activeHours = activeHours ?? WorkingHours(
            enabled: false,
            startMinute: 0,
            endMinute: 1439,
            weekdays: Set(1...7)
        )
        proactive.prompt = prompt
        proactive.topics = topics
        return proactive
    }

    private func makeConversation(
        lastActivity: Date?,
        kind: ConversationKind = .direct,
        aiEnabled: Bool = true,
        id: String? = nil
    ) -> Conversation {
        Conversation(
            id: id ?? targetID,
            kind: kind,
            title: "小林",
            lastMessageAt: lastActivity,
            aiEnabled: aiEnabled
        )
    }

    private func makeMessage(
        _ text: String,
        direction: ChatDirection = .incoming,
        at date: Date? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            conversationID: targetID,
            senderID: direction == .outgoing ? "self" : "wxid_friend",
            senderName: direction == .outgoing ? "我" : "小林",
            direction: direction,
            text: text,
            timestamp: date ?? fixedNow
        )
    }

    /// 今日运行期状态：默认无历史（没有 lastSentAt / lastAttemptAt）。
    private func makeState(
        total: Int = 0,
        sentToday: Int = 0,
        lastSentAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        awaitingReply: Bool = false
    ) -> ProactiveChatRuntimeState {
        var state = ProactiveChatRuntimeState()
        state.dayKey = ProactiveChatRuntimeState.dayKey(for: fixedNow, calendar: calendar)
        state.totalSentToday = total
        state.conversations[targetID] = ProactiveChatRuntimeState.ConversationState(
            lastAttemptAt: lastAttemptAt,
            lastSentAt: lastSentAt,
            sentToday: sentToday,
            awaitingReply: awaitingReply
        )
        return state
    }

    /// 跑一次规划器；默认会话 4 小时前最后一条消息（满足默认 3 小时静默）。
    private func plan(
        _ proactive: ProactiveChatSettings,
        conversation: Conversation? = nil,
        messages: [ChatMessage] = [],
        state: ProactiveChatRuntimeState? = nil,
        now: Date? = nil,
        bot: BotSettings? = nil
    ) -> ProactiveChatDecision {
        let moment = now ?? fixedNow
        let target = conversation ?? makeConversation(
            lastActivity: moment.addingTimeInterval(-4 * 3600))
        var botSettings = bot ?? BotSettings()
        botSettings.proactive = proactive
        return ProactiveChatPlanner.evaluate(
            settings: proactive,
            bot: botSettings,
            conversation: target,
            messages: messages,
            state: state ?? ProactiveChatRuntimeState(),
            now: moment,
            calendar: calendar
        )
    }

    // MARK: - 1. 设置默认值与范围收敛

    func testDefaultsMatchDocumentedBehaviour() {
        let settings = ProactiveChatSettings()

        // 默认关闭：升级后不会突然自动找人聊天。
        XCTAssertFalse(settings.enabled)
        // 默认空名单：没有主动对象就不发送。
        XCTAssertTrue(settings.conversationIDs.isEmpty)
        XCTAssertTrue(settings.normalizedConversationIDs.isEmpty)
        XCTAssertEqual(settings.idleMinutes, 180)
        XCTAssertEqual(settings.maxPerConversationPerDay, 2)
        XCTAssertTrue(settings.skipIfUnanswered)
        XCTAssertTrue(settings.topics.isEmpty)
        XCTAssertEqual(settings.prompt, ProactiveChatSettings.defaultPrompt)
        XCTAssertEqual(settings.promptText, ProactiveChatSettings.defaultPrompt)

        // 默认时段 09:00–23:00，每天。
        let hours = settings.activeHours
        XCTAssertTrue(hours.enabled)
        XCTAssertEqual(hours.startMinute, 9 * 60)
        XCTAssertEqual(hours.endMinute, 23 * 60)
        XCTAssertEqual(hours.weekdays, Set(1...7))

        // 默认值本身已经是收敛后的形态。
        XCTAssertEqual(settings.sanitized, settings)
        XCTAssertEqual(settings.activeHoursSanitized, hours)
    }

    func testSanitizedClampsNumericRanges() {
        var low = makeProactive()
        low.idleMinutes = 1
        low.maxPerConversationPerDay = 0
        let clampedLow = low.sanitized
        XCTAssertEqual(clampedLow.idleMinutes, ProactiveChatSettings.idleMinutesRange.lowerBound)
        XCTAssertEqual(clampedLow.maxPerConversationPerDay,
                       ProactiveChatSettings.dailyPerConversationRange.lowerBound)

        var high = makeProactive()
        high.idleMinutes = 100_000
        high.maxPerConversationPerDay = 100
        let clampedHigh = high.sanitized
        XCTAssertEqual(clampedHigh.idleMinutes, ProactiveChatSettings.idleMinutesRange.upperBound)
        XCTAssertEqual(clampedHigh.maxPerConversationPerDay,
                       ProactiveChatSettings.dailyPerConversationRange.upperBound)
    }

    func testConversationIDsAreTrimmedDeduplicatedAndDropEmpty() {
        var settings = makeProactive()
        settings.conversationIDs = [" wxid_a ", "wxid_a", "", "   ", "wxid_b", " wxid_b"]
        XCTAssertEqual(settings.normalizedConversationIDs, ["wxid_a", "wxid_b"])
        XCTAssertEqual(settings.sanitized.conversationIDs, ["wxid_a", "wxid_b"])
    }

    func testTopicsAreDeduplicatedLimitedAndTruncated() {
        var settings = makeProactive()
        let longTopic = String(repeating: "长", count: ProactiveChatSettings.maxTopicLength + 10)
        settings.topics = [
            longTopic,
            " 话题一 ",
            "话题一",
            "话题二",
            "话题三",
            "话题四",
            "话题五",
            "话题六",
            "话题七",
            "话题八",
            "话题九"
        ]

        let topics = settings.normalizedTopics
        XCTAssertEqual(topics.count, ProactiveChatSettings.maxTopics)
        XCTAssertEqual(topics[0].count, ProactiveChatSettings.maxTopicLength)
        XCTAssertEqual(topics[1], "话题一")
        XCTAssertEqual(topics.filter { $0 == "话题一" }.count, 1, "重复话题只保留一条")
        XCTAssertEqual(topics.last, "话题七", "超过 8 个后截断，不再追加")
        XCTAssertEqual(settings.sanitized.topics, topics)
    }

    func testActiveHoursSanitizedFixesInvalidConfiguration() {
        var settings = makeProactive()

        // 越界分钟与非法星期（0 / 8）被收敛。
        settings.activeHours = WorkingHours(
            enabled: true, startMinute: -30, endMinute: 5000, weekdays: [0, 3, 8])
        let clamped = settings.activeHoursSanitized
        XCTAssertEqual(clamped.startMinute, 0)
        XCTAssertEqual(clamped.endMinute, 1439)
        XCTAssertEqual(clamped.weekdays, Set([3]))

        // 启用但空星期：补成每天，避免「开着却永远不生效」。
        settings.activeHours = WorkingHours(
            enabled: true, startMinute: 10 * 60, endMinute: 10 * 60, weekdays: [])
        let zeroWindow = settings.activeHoursSanitized
        XCTAssertEqual(zeroWindow.weekdays, Set(1...7))
        XCTAssertEqual(zeroWindow.endMinute, 11 * 60, "零长度窗口顺延一小时")

        // 关闭时不补星期，但仍修正零长度窗口。
        settings.activeHours = WorkingHours(
            enabled: false, startMinute: 0, endMinute: 0, weekdays: [])
        let disabledWindow = settings.activeHoursSanitized
        XCTAssertTrue(disabledWindow.weekdays.isEmpty)
        XCTAssertEqual(disabledWindow.endMinute, 60)

        // 跨夜窗口保持原样（22:00–02:00）。
        settings.activeHours = WorkingHours(
            enabled: true, startMinute: 22 * 60, endMinute: 2 * 60, weekdays: Set(1...7))
        let overnight = settings.activeHoursSanitized
        XCTAssertEqual(overnight.startMinute, 22 * 60)
        XCTAssertEqual(overnight.endMinute, 2 * 60)
    }

    func testPromptTextFallsBackWhenBlankAndTrimsCustomPrompt() {
        var settings = makeProactive()
        settings.prompt = ""
        XCTAssertEqual(settings.promptText, ProactiveChatSettings.defaultPrompt)
        settings.prompt = "  \n\t  "
        XCTAssertEqual(settings.promptText, ProactiveChatSettings.defaultPrompt)
        settings.prompt = "  自定义开口提示  "
        XCTAssertEqual(settings.promptText, "自定义开口提示")
    }

    func testEffectiveWindowPriorityConversationThenGlobalThenProactive() {
        let proactive = makeProactive(activeHours: WorkingHours(
            enabled: true, startMinute: 9 * 60, endMinute: 23 * 60, weekdays: Set(1...7)))
        var bot = BotSettings()
        bot.workingHours = WorkingHours(
            enabled: true, startMinute: 8 * 60, endMinute: 18 * 60, weekdays: Set(1...7))

        // 1. 会话独立时段优先。
        var conversation = makeConversation(
            lastActivity: fixedNow.addingTimeInterval(-4 * 3600))
        conversation.workingHours = WorkingHours(
            enabled: true, startMinute: 10 * 60, endMinute: 12 * 60, weekdays: Set(1...7))
        var window = ProactiveChatPlanner.effectiveWindow(
            settings: proactive, bot: bot, conversation: conversation)
        XCTAssertEqual(window.source, .conversation)
        XCTAssertEqual(window.hours?.startMinute, 10 * 60)
        XCTAssertEqual(window.hours?.endMinute, 12 * 60)

        // 2. 会话未单独设置时使用全局工作时间（节奏）。
        conversation.workingHours = nil
        window = ProactiveChatPlanner.effectiveWindow(
            settings: proactive, bot: bot, conversation: conversation)
        XCTAssertEqual(window.source, .globalWorkingHours)
        XCTAssertEqual(window.hours?.startMinute, 8 * 60)
        XCTAssertEqual(window.hours?.endMinute, 18 * 60)

        // 3. 全局未启用时才回落到主动页时段。
        bot.workingHours.enabled = false
        window = ProactiveChatPlanner.effectiveWindow(
            settings: proactive, bot: bot, conversation: conversation)
        XCTAssertEqual(window.source, .proactive)
        XCTAssertEqual(window.hours?.startMinute, 9 * 60)
        XCTAssertEqual(window.hours?.endMinute, 23 * 60)

        // 4. 三者都未启用 = 不限时段。
        var allDisabled = proactive
        allDisabled.activeHours.enabled = false
        window = ProactiveChatPlanner.effectiveWindow(
            settings: allDisabled, bot: bot, conversation: conversation)
        XCTAssertEqual(window.source, .unrestricted)
        XCTAssertNil(window.hours)
        XCTAssertTrue(window.contains(date(2026, 10, 28, 3, 0), calendar: calendar))
    }

    func testConversationUnrestrictedOverridesGlobalAndProactiveWindow() {
        var conversation = makeConversation(
            lastActivity: fixedNow.addingTimeInterval(-4 * 3600))
        conversation.workingHours = WorkingHours(enabled: false)

        var bot = BotSettings()
        bot.workingHours = WorkingHours(
            enabled: true, startMinute: 9 * 60, endMinute: 10 * 60, weekdays: Set(1...7))
        let proactive = makeProactive(activeHours: WorkingHours(
            enabled: true, startMinute: 9 * 60, endMinute: 10 * 60, weekdays: Set(1...7)))

        let window = ProactiveChatPlanner.effectiveWindow(
            settings: proactive, bot: bot, conversation: conversation)
        XCTAssertEqual(window.source, .unrestricted)
        XCTAssertNil(window.hours)
        XCTAssertTrue(plan(proactive, conversation: conversation, bot: bot).shouldSend,
                      "会话显式「不限时段」应压过全局/主动页时段")
    }

    // MARK: - 2. Codable 兼容

    func testDecodingEmptyJSONUsesDefaults() throws {
        let decoded = try JSONDecoder().decode(
            ProactiveChatSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, ProactiveChatSettings())
        XCTAssertFalse(decoded.enabled)
    }

    func testDecodingMissingKeysFallsBackPerField() throws {
        let json = #"{"enabled":true,"idleMinutes":30,"topics":["考试"],"skipIfUnanswered":false}"#
        let decoded = try JSONDecoder().decode(
            ProactiveChatSettings.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.idleMinutes, 30)
        XCTAssertEqual(decoded.topics, ["考试"])
        XCTAssertFalse(decoded.skipIfUnanswered)

        // 其余键回退默认值。
        let defaults = ProactiveChatSettings()
        XCTAssertEqual(decoded.conversationIDs, defaults.conversationIDs)
        XCTAssertEqual(decoded.maxPerConversationPerDay, defaults.maxPerConversationPerDay)
        XCTAssertEqual(decoded.activeHours, defaults.activeHours)
        XCTAssertEqual(decoded.prompt, defaults.prompt)
    }

    func testDecodingInvalidValueFallsBackToDefault() throws {
        // 类型不匹配（手改配置）只影响该字段，不让整份设置解码失败。
        let json = #"{"idleMinutes":"半小时","enabled":true}"#
        let decoded = try JSONDecoder().decode(
            ProactiveChatSettings.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.idleMinutes, ProactiveChatSettings().idleMinutes)
    }

    func testEncodeDecodeRoundtripPreservesSettings() throws {
        var settings = makeProactive(
            conversationIDs: ["wxid_a", "123456@chatroom"],
            idleMinutes: 240,
            maxPerConversationPerDay: 3,
            skipIfUnanswered: false,
            activeHours: WorkingHours(
                enabled: true, startMinute: 8 * 60, endMinute: 22 * 60,
                weekdays: [2, 3, 4, 5, 6]),
            prompt: "自定义提示词",
            topics: ["话题A", "话题B"]
        )
        settings.enabled = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ProactiveChatSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testBotSettingsWithoutProactiveKeyDecodesAsDisabled() throws {
        // 旧 profile.json 没有 bot.proactive 键：必须保持可解码，且默认关闭。
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default))
                as? [String: Any]
        )
        var bot = try XCTUnwrap(object["bot"] as? [String: Any])
        bot.removeValue(forKey: "proactive")
        object["bot"] = bot

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertNil(decoded.bot.proactive)
        XCTAssertEqual(decoded.bot.proactiveSettings, ProactiveChatSettings())
        XCTAssertFalse(decoded.bot.proactiveSettings.enabled)
    }

    func testProactiveSettingsSetterSanitizes() throws {
        var settings = AppSettings.default
        settings.bot.proactiveSettings = makeProactive(
            conversationIDs: [" wxid_a ", "wxid_a"],
            idleMinutes: 1,
            maxPerConversationPerDay: 99
        )
        XCTAssertEqual(settings.bot.proactive?.conversationIDs, ["wxid_a"])
        XCTAssertEqual(settings.bot.proactiveSettings.idleMinutes,
                       ProactiveChatSettings.idleMinutesRange.lowerBound)
        XCTAssertEqual(settings.bot.proactiveSettings.maxPerConversationPerDay,
                       ProactiveChatSettings.dailyPerConversationRange.upperBound)

        // 写回后再读依然收敛。
        settings.bot.proactiveSettings.idleMinutes = 999_999
        XCTAssertEqual(settings.bot.proactiveSettings.idleMinutes,
                       ProactiveChatSettings.idleMinutesRange.upperBound)
    }

    // MARK: - 3. 运行期状态

    func testBeginDayResetsDailyCountersButKeepsTimestamps() {
        var state = ProactiveChatRuntimeState()
        state.dayKey = "2026-10-27"
        state.totalSentToday = 5
        let sent = date(2026, 10, 27, 20, 0)
        let attempted = date(2026, 10, 27, 21, 0)
        state.conversations[targetID] = ProactiveChatRuntimeState.ConversationState(
            lastAttemptAt: attempted,
            lastSentAt: sent,
            sentToday: 2,
            awaitingReply: true
        )

        state.beginDay(fixedNow, calendar: calendar)

        XCTAssertEqual(state.dayKey, "2026-10-28")
        XCTAssertEqual(state.totalSentToday, 0)
        let conversation = state.state(for: targetID)
        XCTAssertEqual(conversation.sentToday, 0)
        XCTAssertEqual(conversation.lastSentAt, sent)
        XCTAssertEqual(conversation.lastAttemptAt, attempted)
        XCTAssertTrue(conversation.awaitingReply, "跨日不清除「等待回复」")

        // 同一天再次调用不清零。
        var sameDay = state
        sameDay.totalSentToday = 3
        sameDay.beginDay(fixedNow.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(sameDay.totalSentToday, 3)
        XCTAssertEqual(sameDay.state(for: targetID).sentToday, 0)
    }

    func testNoteSentIncrementsBothCountersAndMarksAwaitingReply() {
        var state = makeState()
        let first = fixedNow.addingTimeInterval(-600)
        state.noteSent(targetID, at: first)
        state.noteSent(targetID, at: fixedNow)

        XCTAssertEqual(state.totalSentToday, 2)
        let conversation = state.state(for: targetID)
        XCTAssertEqual(conversation.sentToday, 2)
        XCTAssertEqual(conversation.lastSentAt, fixedNow)
        XCTAssertEqual(conversation.lastAttemptAt, fixedNow)
        XCTAssertTrue(conversation.awaitingReply)

        // 其它会话不受影响。
        XCTAssertEqual(state.state(for: otherID).sentToday, 0)
        XCTAssertEqual(state.state(for: otherID).awaitingReply, false)
    }

    func testNoteAttemptDoesNotIncreaseDailyCounters() {
        var state = makeState()
        state.noteAttempt(targetID, at: fixedNow)
        XCTAssertEqual(state.totalSentToday, 0)
        let conversation = state.state(for: targetID)
        XCTAssertEqual(conversation.sentToday, 0)
        XCTAssertNil(conversation.lastSentAt)
        XCTAssertEqual(conversation.lastAttemptAt, fixedNow)
        XCTAssertFalse(conversation.awaitingReply)
    }

    func testNoteIncomingOnlyReportsChangeWhenAwaitingReply() {
        var state = ProactiveChatRuntimeState()
        XCTAssertFalse(state.noteIncoming(targetID), "没有状态的会话不产生写入")

        state.conversations[targetID] = ProactiveChatRuntimeState.ConversationState(
            awaitingReply: false)
        XCTAssertFalse(state.noteIncoming(targetID))

        state.conversations[targetID] = ProactiveChatRuntimeState.ConversationState(
            lastAttemptAt: fixedNow,
            lastSentAt: fixedNow,
            sentToday: 1,
            awaitingReply: true
        )
        XCTAssertTrue(state.noteIncoming(targetID))
        XCTAssertFalse(state.state(for: targetID).awaitingReply)
        // 发送时间与计数保留，供间隔判定使用。
        XCTAssertEqual(state.state(for: targetID).lastSentAt, fixedNow)
        XCTAssertEqual(state.state(for: targetID).sentToday, 1)
        // 第二次调用不再报告变化。
        XCTAssertFalse(state.noteIncoming(targetID))
    }

    // MARK: - 4. Planner 决策矩阵

    func testPlannerTickIntervalIsSixtySeconds() {
        XCTAssertEqual(ProactiveChatPlanner.tickInterval, 60)
    }

    func testPlannerSkipsWhenDisabled() {
        var proactive = makeProactive()
        proactive.enabled = false
        let decision = plan(proactive)
        XCTAssertFalse(decision.shouldSend)
        XCTAssertFalse(decision.reason.isEmpty)
    }

    func testPlannerSkipsWhenConversationNotSelected() {
        var proactive = makeProactive()
        proactive.conversationIDs = [otherID]
        let notSelected = plan(proactive)
        XCTAssertFalse(notSelected.shouldSend)
        XCTAssertFalse(notSelected.reason.isEmpty)

        proactive.conversationIDs = []
        let emptyList = plan(proactive)
        XCTAssertFalse(emptyList.shouldSend, "空名单不发送任何消息")
        XCTAssertFalse(emptyList.reason.isEmpty)
    }

    func testPlannerSkipsWhenConversationAIDisabled() {
        let conversation = makeConversation(
            lastActivity: fixedNow.addingTimeInterval(-4 * 3600),
            aiEnabled: false
        )
        let decision = plan(makeProactive(), conversation: conversation)
        XCTAssertFalse(decision.shouldSend)
        XCTAssertFalse(decision.reason.isEmpty)
    }

    func testPlannerSkipsOfficialAccounts() {
        let official = makeConversation(
            lastActivity: fixedNow.addingTimeInterval(-4 * 3600),
            kind: .official
        )
        XCTAssertFalse(plan(makeProactive(), conversation: official).shouldSend,
                       "公众号不是可对话对象")
    }

    func testPlannerAllowsGroupTargets() {
        let group = makeConversation(
            lastActivity: fixedNow.addingTimeInterval(-4 * 3600),
            kind: .group
        )
        XCTAssertTrue(plan(makeProactive(), conversation: group).shouldSend,
                      "主动对象支持群聊，不再限制只对私聊")
    }

    func testPlannerSkipsBlacklistedConversation() {
        var bot = BotSettings()
        bot.blacklistEntries = [targetID]
        let blocked = plan(makeProactive(), bot: bot)
        XCTAssertFalse(blocked.shouldSend)
        XCTAssertFalse(blocked.reason.isEmpty)

        bot.blacklistEntries = []
        XCTAssertTrue(plan(makeProactive(), bot: bot).shouldSend)
    }

    func testPlannerSkipsOutsideActiveHours() {
        var proactive = makeProactive(
            activeHours: WorkingHours(
                enabled: true, startMinute: 18 * 60, endMinute: 20 * 60,
                weekdays: Set(1...7))
        )
        let daytime = plan(proactive)
        XCTAssertFalse(daytime.shouldSend, "12:00 不在 18:00–20:00 内")
        XCTAssertFalse(daytime.reason.isEmpty)

        let evening = date(2026, 10, 28, 19, 0)
        XCTAssertTrue(plan(proactive, now: evening).shouldSend)

        // 工作日时段：周末不发送（2026-10-31 是周六）。
        proactive.activeHours = WorkingHours(
            enabled: true, startMinute: 9 * 60, endMinute: 18 * 60, weekdays: [2, 3, 4, 5, 6])
        let saturdayNoon = date(2026, 10, 31, 12, 0)
        XCTAssertFalse(plan(proactive, now: saturdayNoon).shouldSend)
    }

    func testPlannerTimeWindowPriorityIsConversationThenGlobalThenProactive() {
        var bot = BotSettings()
        bot.workingHours = WorkingHours(
            enabled: true, startMinute: 8 * 60, endMinute: 18 * 60, weekdays: Set(1...7))
        let proactive = makeProactive(activeHours: WorkingHours(
            enabled: true, startMinute: 0, endMinute: 1439, weekdays: Set(1...7)))
        var conversation = makeConversation(
            lastActivity: fixedNow.addingTimeInterval(-4 * 3600))
        conversation.workingHours = WorkingHours(
            enabled: true, startMinute: 18 * 60, endMinute: 20 * 60, weekdays: Set(1...7))

        // 会话独立时段排除 12:00，即使全局与主动页都允许。
        XCTAssertFalse(plan(proactive, conversation: conversation, bot: bot).shouldSend)

        // 会话未单独设置时用全局工作时间（12:00 在 08:00–18:00 内）。
        conversation.workingHours = nil
        XCTAssertTrue(plan(proactive, conversation: conversation, bot: bot).shouldSend)

        // 全局排除 12:00 时，主动页时段不能越过全局。
        bot.workingHours = WorkingHours(
            enabled: true, startMinute: 18 * 60, endMinute: 20 * 60, weekdays: Set(1...7))
        XCTAssertFalse(plan(proactive, conversation: conversation, bot: bot).shouldSend)

        // 全局未启用时才回落到主动页时段。
        bot.workingHours.enabled = false
        XCTAssertTrue(plan(proactive, conversation: conversation, bot: bot).shouldSend)
    }

    func testPlannerSkipsWhenIdleTooShort() {
        let conversation = makeConversation(
            lastActivity: fixedNow.addingTimeInterval(-60 * 60))
        let decision = plan(makeProactive(), conversation: conversation)
        XCTAssertFalse(decision.shouldSend)
        XCTAssertFalse(decision.reason.isEmpty)
    }

    func testPlannerSkipsWhenConversationHasNoHistory() {
        let empty = Conversation(id: targetID, kind: .direct, title: "小林")
        let noHistory = plan(makeProactive(), conversation: empty)
        XCTAssertFalse(noHistory.shouldSend)
        XCTAssertFalse(noHistory.reason.isEmpty)

        // 会话没有 lastMessageAt 时回退到内存里最后一条消息的时间。
        let history = [makeMessage("旧消息", at: fixedNow.addingTimeInterval(-4 * 3600))]
        XCTAssertTrue(plan(makeProactive(), conversation: empty, messages: history).shouldSend)
    }

    func testPlannerSkipsAtPerConversationLimit() {
        XCTAssertTrue(plan(makeProactive(), state: makeState(sentToday: 1)).shouldSend)
        let atLimit = plan(makeProactive(), state: makeState(sentToday: 2))
        XCTAssertFalse(atLimit.shouldSend)
        XCTAssertFalse(atLimit.reason.isEmpty)
    }

    func testPlannerSkipsWhenAwaitingReplyAndProtected() {
        var proactive = makeProactive()
        let state = makeState(
            sentToday: 1,
            lastSentAt: fixedNow.addingTimeInterval(-4 * 3600),
            awaitingReply: true
        )
        let awaiting = plan(proactive, state: state)
        XCTAssertFalse(awaiting.shouldSend)
        XCTAssertFalse(awaiting.reason.isEmpty)

        // 关掉「未回复保护」后，条件满足即可发送。
        proactive.skipIfUnanswered = false
        XCTAssertTrue(plan(proactive, state: state).shouldSend)
    }

    func testPlannerBacksOffAfterFailedAttempt() {
        let conversation = makeConversation(
            lastActivity: fixedNow.addingTimeInterval(-4 * 3600))

        // 失败尝试 10 分钟前：退避期内跳过。
        let recentFailure = makeState(
            lastAttemptAt: fixedNow.addingTimeInterval(-10 * 60)
        )
        let backedOff = plan(makeProactive(), conversation: conversation, state: recentFailure)
        XCTAssertFalse(backedOff.shouldSend)
        XCTAssertTrue(backedOff.reason.contains("失败"), "原因写明失败退避")

        // 超过固定退避（30 分钟）后放行。
        let oldFailure = makeState(
            lastAttemptAt: fixedNow.addingTimeInterval(-45 * 60)
        )
        XCTAssertTrue(plan(makeProactive(), conversation: conversation,
                           state: oldFailure).shouldSend)
    }

    func testPlannerDoesNotAddExtraIntervalAfterSuccessfulSend() {
        // 成功发送后的间隔完全由静默时长决定；旧的「最小间隔」设置已移除。
        let conversation = makeConversation(
            lastActivity: fixedNow.addingTimeInterval(-30 * 60))
        let state = makeState(
            sentToday: 1,
            lastSentAt: fixedNow.addingTimeInterval(-30 * 60),
            lastAttemptAt: fixedNow.addingTimeInterval(-30 * 60)
        )
        let proactive = makeProactive(idleMinutes: 15)
        XCTAssertTrue(plan(proactive, conversation: conversation, state: state).shouldSend)
    }

    func testPlannerIgnoresLegacyTotalSentTodayCounter() {
        // 合计上限已移除：即使今日累计计数很大，只要该会话未到单会话上限就允许。
        let state = makeState(total: 999, sentToday: 1)
        XCTAssertTrue(plan(makeProactive(), state: state).shouldSend)
    }

    func testPlannerSendsWhenAllConditionsMet() {
        let decision = plan(makeProactive())
        XCTAssertTrue(decision.shouldSend)
        XCTAssertTrue(decision.reason.contains("静默"), "发送原因写明静默时长，便于看运行日志")
    }

    func testPlannerResetsDailyCountsOnNewDay() {
        var state = ProactiveChatRuntimeState()
        state.dayKey = "2026-10-27"
        state.totalSentToday = 8
        let yesterday = date(2026, 10, 27, 20, 0)
        state.conversations[targetID] = ProactiveChatRuntimeState.ConversationState(
            lastAttemptAt: yesterday,
            lastSentAt: yesterday,
            sentToday: 2,
            awaitingReply: false
        )
        // 昨天已到上限、会话也已到上限，但跨日清零后应重新可以发送。
        XCTAssertTrue(plan(makeProactive(), state: state).shouldSend)
    }

    // MARK: - 5. ChatEngine 主动聊天提示词

    private func proactiveSettings(
        prompt: String = ProactiveChatSettings.defaultPrompt,
        topics: [String] = []
    ) -> AppSettings {
        var settings = AppSettings.default
        var proactive = ProactiveChatSettings()
        proactive.enabled = true
        proactive.conversationIDs = [targetID]
        proactive.prompt = prompt
        proactive.topics = topics
        settings.bot.proactive = proactive
        return settings
    }

    func testProactiveMessagesBeginWithPersonaAndTaskContext() throws {
        let engine = try makeEngine()
        let settings = proactiveSettings(
            prompt: "聊聊最近的天气和周末安排",
            topics: ["周末计划", "最近的考试"]
        )
        let conversation = Conversation(
            id: targetID, kind: .direct, title: "小林", aiEnabled: true)

        let messages = engine.buildProactiveMessages(
            conversation: conversation,
            settings: settings,
            personaPrompt: "你是小林的老朋友，说话轻松自然。",
            history: [],
            memoryPrompt: "记忆上下文：用户最近在准备考试。"
        )

        let system = try XCTUnwrap(messages.first)
        XCTAssertEqual(system.role, .system)
        XCTAssertTrue(system.content.contains("你是小林的老朋友，说话轻松自然。"), "人格正文")
        XCTAssertTrue(system.content.contains("主动聊天"), "场景说明")
        XCTAssertTrue(system.content.contains("主动开口"), "要求先开口")
        XCTAssertTrue(system.content.contains(settings.bot.proactiveSettings.promptText),
                      "注入 proactive.promptText")
        XCTAssertTrue(system.content.contains("周末计划"), "注入自定义话题")
        XCTAssertTrue(system.content.contains("最近的考试"))
        XCTAssertTrue(system.content.contains("记忆上下文：用户最近在准备考试。"),
                      "长期记忆随 system 段注入")
    }

    func testProactiveMessagesEndWithSystemOperationHint() throws {
        let engine = try makeEngine()
        let conversation = Conversation(id: targetID, kind: .direct, title: "小林")
        let messages = engine.buildProactiveMessages(
            conversation: conversation,
            settings: proactiveSettings(),
            personaPrompt: "人格正文",
            history: [makeMessage("在吗", at: fixedNow.addingTimeInterval(-4 * 3600))],
            memoryPrompt: nil
        )

        let last = try XCTUnwrap(messages.last)
        XCTAssertEqual(last.role, .user)
        XCTAssertTrue(last.content.contains("系统的操作提示"))
        XCTAssertTrue(last.content.contains("不是对方发来的消息"))
    }

    func testProactiveMessagesMapHistoryDirections() throws {
        let engine = try makeEngine()
        let conversation = Conversation(id: targetID, kind: .direct, title: "小林")
        let history = [
            makeMessage("你好", direction: .incoming, at: fixedNow.addingTimeInterval(-600)),
            makeMessage("系统日志", direction: .system, at: fixedNow.addingTimeInterval(-540)),
            makeMessage("在的，怎么了", direction: .outgoing, at: fixedNow.addingTimeInterval(-480)),
            makeMessage("最近怎么样", direction: .incoming, at: fixedNow.addingTimeInterval(-420))
        ]

        let messages = engine.buildProactiveMessages(
            conversation: conversation,
            settings: proactiveSettings(),
            personaPrompt: "人格正文",
            history: history,
            memoryPrompt: nil
        )

        XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant, .user, .user])
        XCTAssertEqual(messages[1].content, "你好")
        XCTAssertEqual(messages[2].content, "在的，怎么了")
        XCTAssertEqual(messages[3].content, "最近怎么样")
        XCTAssertFalse(messages.dropFirst().contains { $0.content.contains("系统日志") },
                       "系统方向的消息不进提示词历史")
    }

    func testProactiveMessagesCapHistoryAtShortTermLimit() throws {
        let engine = try makeEngine()
        let conversation = Conversation(id: targetID, kind: .direct, title: "小林")
        var history: [ChatMessage] = []
        for index in 0..<14 {
            let direction: ChatDirection = index % 2 == 0 ? .incoming : .outgoing
            history.append(makeMessage(
                String(format: "历史消息 %02d", index),
                direction: direction,
                at: fixedNow.addingTimeInterval(Double(index))
            ))
        }

        let settings = proactiveSettings()
        let messages = engine.buildProactiveMessages(
            conversation: conversation,
            settings: settings,
            personaPrompt: "人格正文",
            history: history,
            memoryPrompt: nil
        )
        let joined = messages.dropFirst().dropLast().map(\.content).joined(separator: "\n")

        XCTAssertTrue(joined.contains("历史消息 04"))
        XCTAssertFalse(joined.contains("历史消息 03"), "超出短期窗口的历史被丢弃")
        XCTAssertTrue(joined.contains("历史消息 13"))
        XCTAssertLessThanOrEqual(
            messages.count,
            ChatEngine.shortTermMemoryLimit + 2,
            "system + 历史 + 末尾操作提示"
        )

        // 会话级窗口覆盖：maxContextMessages 小于固定上限时按设置裁剪。
        var narrowed = settings
        narrowed.bot.maxContextMessages = 4
        let narrowMessages = engine.buildProactiveMessages(
            conversation: conversation,
            settings: narrowed,
            personaPrompt: "人格正文",
            history: history,
            memoryPrompt: nil
        )
        let narrowedText = narrowMessages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(narrowedText.contains("历史消息 10"))
        XCTAssertFalse(narrowedText.contains("历史消息 09"))
    }

    func testProactiveMessagesUseDefaultPromptWhenBlank() throws {
        let engine = try makeEngine()
        let conversation = Conversation(id: targetID, kind: .direct, title: "小林")
        let messages = engine.buildProactiveMessages(
            conversation: conversation,
            settings: proactiveSettings(prompt: "   \n  "),
            personaPrompt: "人格正文",
            history: [],
            memoryPrompt: nil
        )

        let system = try XCTUnwrap(messages.first)
        XCTAssertEqual(system.role, .system)
        XCTAssertTrue(system.content.contains(ProactiveChatSettings.defaultPrompt))
    }

    func testProactiveMessagesSkipTopicsSectionWhenEmpty() throws {
        let engine = try makeEngine()
        let conversation = Conversation(id: targetID, kind: .direct, title: "小林")
        let messages = engine.buildProactiveMessages(
            conversation: conversation,
            settings: proactiveSettings(topics: []),
            personaPrompt: "人格正文",
            history: [],
            memoryPrompt: nil
        )
        let system = try XCTUnwrap(messages.first)
        XCTAssertFalse(system.content.contains("可以自然聊到这些话题"))
    }
}
