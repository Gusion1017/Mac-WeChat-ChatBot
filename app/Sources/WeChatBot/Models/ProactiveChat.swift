import Foundation

// MARK: - 主动聊天设置

/// 机器人主动发起聊天的设置（2026-10-28 新增）。
///
/// 「主动聊天」与「定时任务」不同：定时任务按固定时间点发送固定内容；主动聊天是
/// 在会话静默一段时间后，由 AI 结合最近聊天、记忆与人格**现场生成**一条自然的
/// 开场消息，并按频率上限 / 时段 / 未回复保护等规则收敛，避免刷屏或像推销。
///
/// 所有字段都随账号 `profile.json` 保存（`BotSettings.proactive`）。为了兼容旧配置，
/// `BotSettings.proactive` 是可选值；解码时逐键回退，缺键不会丢整份机器人设置。
struct ProactiveChatSettings: Codable, Hashable {
    /// 默认主动权提示词（用户可在机器人 → 主动里修改）。
    static let defaultPrompt = "结合你们最近的聊天内容和记忆，自然地开启一个新话题，或关心一下对方的近况。"
        + "像真人一样简短、口语化，只发一条消息；不要连续追问，不要解释自己为什么发消息，"
        + "不要提到「主动」「系统」「提醒」等字眼。"

    /// 静默多久后才允许主动（分钟）。15 分钟 ~ 7 天。
    static let idleMinutesRange: ClosedRange<Int> = 15...(7 * 24 * 60)
    /// 每个会话每天最多主动几条（不设跨会话的合计上限）。
    static let dailyPerConversationRange: ClosedRange<Int> = 1...5
    /// 生成/发送失败后的重试退避（分钟）。不是用户设置：失败后固定等待，
    /// 避免每分钟重试烧 token；成功发送后的间隔由「静默时长」自然约束。
    static let retryBackoffMinutes: Int = 30
    /// 自定义话题上限。
    static let maxTopics = 8
    /// 单个话题长度上限。
    static let maxTopicLength = 40

    /// 总开关。默认关闭：升级后不会突然开始自动找人聊天。
    var enabled: Bool = false

    /// 允许主动聊天的会话 ID 名单。默认空：不选择任何会话，即不发送。
    /// （与白名单不同，这里空名单表示「没有对象」，避免默认骚扰所有联系人。）
    var conversationIDs: [String] = []

    /// 会话静默超过该时长才允许主动。发送成功后最后一条消息变成机器人的消息，
    /// 因此下一次主动同样要再等一个静默周期——不需要额外的「最小间隔」设置。
    var idleMinutes: Int = 180

    /// 每个会话每天最多主动发送几条。
    var maxPerConversationPerDay: Int = 2

    /// 允许主动发送的时段（支持跨夜、按星期）。默认 09:00–23:00 每天。
    var activeHours: WorkingHours = WorkingHours(
        enabled: true,
        startMinute: 9 * 60,
        endMinute: 23 * 60,
        weekdays: Set(1...7)
    )

    /// 上一条主动消息还没被回复时，是否跳过（避免连续自说自话）。
    var skipIfUnanswered: Bool = true

    /// 主动权提示词；空白时使用 `defaultPrompt`。
    var prompt: String = ProactiveChatSettings.defaultPrompt

    /// 可选话题（最多 8 个）；为空时由 AI 自行决定。
    var topics: [String] = []

    // MARK: 派生值

    /// 有效的主动权提示词；空白回退到默认。
    var promptText: String {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? Self.defaultPrompt : value
    }

    /// 去空白、去重后的会话名单。
    var normalizedConversationIDs: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in conversationIDs {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    /// 去空白、去重后的自定义话题。
    var normalizedTopics: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in topics {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            result.append(String(value.prefix(Self.maxTopicLength)))
            if result.count >= Self.maxTopics { break }
        }
        return result
    }

    /// 生效的主动聊天时段：修正越界分钟、空星期与零长度窗口，避免设置看起来
    /// 开着却永远不生效。
    var activeHoursSanitized: WorkingHours {
        var hours = activeHours
        hours.startMinute = min(max(hours.startMinute, 0), 1439)
        hours.endMinute = min(max(hours.endMinute, 0), 1439)
        hours.weekdays = Set(hours.weekdays.filter { (1...7).contains($0) })
        if hours.enabled, hours.weekdays.isEmpty {
            hours.weekdays = Set(1...7)
        }
        if hours.startMinute == hours.endMinute {
            // 零长度窗口在 `WorkingHours.contains` 里永远为 false；顺延一小时，
            // 保证用户看到的「已启用」与真实行为一致。
            hours.endMinute = (hours.startMinute + 60) % 1440
        }
        return hours
    }

    /// 收敛所有数值与名单，写入/读取时统一使用。
    var sanitized: ProactiveChatSettings {
        var copy = self
        copy.conversationIDs = normalizedConversationIDs
        copy.idleMinutes = min(max(idleMinutes, Self.idleMinutesRange.lowerBound),
                               Self.idleMinutesRange.upperBound)
        copy.maxPerConversationPerDay = min(max(maxPerConversationPerDay,
                                                Self.dailyPerConversationRange.lowerBound),
                                            Self.dailyPerConversationRange.upperBound)
        copy.topics = normalizedTopics
        copy.activeHours = activeHoursSanitized
        return copy
    }

    // MARK: 展示辅助

    static func idleLabel(minutes: Int) -> String {
        if minutes < 60 { return Lf("%d 分钟", minutes) }
        if minutes < 60 * 24 {
            let hours = Double(minutes) / 60
            return hours == hours.rounded()
                ? Lf("%d 小时", Int(hours))
                : Lf("%.1f 小时", hours)
        }
        let days = Double(minutes) / (60 * 24)
        return days == days.rounded()
            ? Lf("%d 天", Int(days))
            : Lf("%.1f 天", days)
    }
}

// MARK: - 解码兼容

extension ProactiveChatSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, conversationIDs, idleMinutes
        case maxPerConversationPerDay, activeHours
        case skipIfUnanswered, prompt, topics
    }

    /// 逐键解码：手改/旧版本缺键只回退该字段，不让整份设置变成 nil。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProactiveChatSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        conversationIDs = (try? container.decodeIfPresent([String].self, forKey: .conversationIDs))
            ?? defaults.conversationIDs
        idleMinutes = (try? container.decodeIfPresent(Int.self, forKey: .idleMinutes))
            ?? defaults.idleMinutes
        maxPerConversationPerDay = (try? container.decodeIfPresent(
            Int.self, forKey: .maxPerConversationPerDay)) ?? defaults.maxPerConversationPerDay
        activeHours = (try? container.decodeIfPresent(WorkingHours.self, forKey: .activeHours))
            ?? defaults.activeHours
        skipIfUnanswered = (try? container.decodeIfPresent(Bool.self, forKey: .skipIfUnanswered))
            ?? defaults.skipIfUnanswered
        prompt = (try? container.decodeIfPresent(String.self, forKey: .prompt)) ?? defaults.prompt
        topics = (try? container.decodeIfPresent([String].self, forKey: .topics)) ?? defaults.topics
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(conversationIDs, forKey: .conversationIDs)
        try container.encode(idleMinutes, forKey: .idleMinutes)
        try container.encode(maxPerConversationPerDay, forKey: .maxPerConversationPerDay)
        try container.encode(activeHours, forKey: .activeHours)
        try container.encode(skipIfUnanswered, forKey: .skipIfUnanswered)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(topics, forKey: .topics)
    }
}

// MARK: - 运行期状态

/// 主动聊天的运行期状态（每个微信账号一份，持久化在账号数据库的 settings 表）。
///
/// 保存「今天已经主动几条 / 每个会话上次发送或尝试的时间 / 是否在等对方回复」，
/// 让重启 App 后不会立刻重复发送，也不会忘记「对方还没回」而连续追问。
struct ProactiveChatRuntimeState: Codable, Hashable {
    struct ConversationState: Codable, Hashable {
        /// 最近一次尝试（成功或失败都算），用于失败后退避。
        var lastAttemptAt: Date?
        /// 最近一次成功发送的时间。
        var lastSentAt: Date?
        /// 今天已主动发送条数。
        var sentToday: Int = 0
        /// 上一条主动消息发出后，对方还没有任何新消息。
        var awaitingReply: Bool = false
    }

    /// 统计所属日期（`yyyy-MM-dd`，本地时区）。
    var dayKey: String = ""
    /// 今天所有会话合计发送条数。
    var totalSentToday: Int = 0
    /// 按会话 ID 索引的状态。
    var conversations: [String: ConversationState] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case dayKey, totalSentToday, conversations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = (try? container.decodeIfPresent(String.self, forKey: .dayKey)) ?? ""
        totalSentToday = (try? container.decodeIfPresent(Int.self, forKey: .totalSentToday)) ?? 0
        conversations = (try? container.decodeIfPresent(
            [String: ConversationState].self, forKey: .conversations)) ?? [:]
    }

    // MARK: 日期

    static func dayKey(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// 跨日时清零「今日」计数，但保留每个会话的发送/尝试时间（频率间隔仍有效）。
    mutating func beginDay(_ now: Date = Date(), calendar: Calendar = .current) {
        let today = Self.dayKey(for: now, calendar: calendar)
        guard dayKey != today else { return }
        dayKey = today
        totalSentToday = 0
        for id in conversations.keys {
            conversations[id]?.sentToday = 0
        }
    }

    // MARK: 查询

    func state(for conversationID: String) -> ConversationState {
        conversations[conversationID] ?? ConversationState()
    }

    // MARK: 修改

    /// 记录一次尝试（生成失败也会退避），不增加每日计数。
    mutating func noteAttempt(_ conversationID: String, at date: Date = Date()) {
        var state = conversations[conversationID] ?? ConversationState()
        state.lastAttemptAt = date
        conversations[conversationID] = state
    }

    /// 记录一次成功发送。
    mutating func noteSent(_ conversationID: String, at date: Date = Date()) {
        var state = conversations[conversationID] ?? ConversationState()
        state.lastAttemptAt = date
        state.lastSentAt = date
        state.sentToday += 1
        state.awaitingReply = true
        conversations[conversationID] = state
        totalSentToday += 1
    }

    /// 收到对方消息：清除「等待回复」标记。
    /// - Returns: 是否真的发生了变化（避免每条入站消息都写一次数据库）。
    @discardableResult
    mutating func noteIncoming(_ conversationID: String) -> Bool {
        guard var state = conversations[conversationID], state.awaitingReply else { return false }
        state.awaitingReply = false
        conversations[conversationID] = state
        return true
    }
}
