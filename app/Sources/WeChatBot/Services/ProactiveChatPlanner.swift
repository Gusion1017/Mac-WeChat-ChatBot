import Foundation

/// 主动聊天的一次判定结果。
struct ProactiveChatDecision: Equatable {
    var shouldSend: Bool
    /// 给运行日志/调试看的说明（不发到微信）。
    var reason: String

    static func send(_ reason: String) -> ProactiveChatDecision {
        ProactiveChatDecision(shouldSend: true, reason: reason)
    }

    static func skip(_ reason: String) -> ProactiveChatDecision {
        ProactiveChatDecision(shouldSend: false, reason: reason)
    }
}

/// 主动聊天实际使用的时间窗口来源。
///
/// 优先级固定为：**会话独立时段 > 节奏（全局工作时间）> 主动页时段**。
/// 前三者都未启用时不限制时段。
enum ProactiveChatWindowSource: String, Equatable {
    case conversation
    case globalWorkingHours
    case proactive
    case unrestricted

    /// 展示/日志用的中文来源名（`L()` 在 UI 层处理）。
    var label: String {
        switch self {
        case .conversation: "会话独立时段"
        case .globalWorkingHours: "节奏的工作时间"
        case .proactive: "主动页时段"
        case .unrestricted: "不限时段"
        }
    }
}

/// 生效时段解析结果：`hours == nil` 表示不限制。
struct ProactiveChatWindow: Equatable {
    var source: ProactiveChatWindowSource
    var hours: WorkingHours?

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let hours else { return true }
        return hours.contains(date, calendar: calendar)
    }

    /// 给 UI/日志的摘要，例如「会话独立时段 09:00–18:00」「不限时段」。
    var summary: String {
        guard let hours else { return source.label }
        return "\(source.label) · \(hours.summaryText)"
    }
}

/// 主动聊天的纯决策逻辑：给定设置、会话、运行期状态与当前时间，判断该不该主动发。
///
/// 不做任何 IO、不修改状态、不发起 AI 请求，便于单测覆盖所有门槛；运行时按
/// `tickInterval` 轮询并调用本规划器。判定顺序按「便宜且硬的门槛 → 时间 → 概率」，
/// 原因文本会写进设置页的「上次检查」提示，方便用户排查「为什么没有主动发」。
enum ProactiveChatPlanner {
    /// 运行时的轮询间隔（秒）。主动聊天不追求秒级精度，60 秒足够。
    static let tickInterval: TimeInterval = 60

    /// 解析某个会话主动发送实际使用的时间窗口。
    ///
    /// 优先级（用户 2026-10-28 指定）：
    /// 1. 会话独立时段（`Conversation.workingHours`，含显式「不限时段」）；
    /// 2. 节奏 → 全局工作时间（`BotSettings.workingHours`）；
    /// 3. 主动页的发送时段（`ProactiveChatSettings.activeHours`，仅在以上两者都未启用时兜底）。
    ///
    /// 会话显式设为「不限时段」时尊重会话选择，不再回退到全局或主动页时段。
    static func effectiveWindow(
        settings: ProactiveChatSettings,
        bot: BotSettings,
        conversation: Conversation
    ) -> ProactiveChatWindow {
        if let custom = conversation.workingHours {
            let sanitized = custom.sanitized
            return ProactiveChatWindow(
                source: sanitized.enabled ? .conversation : .unrestricted,
                hours: sanitized.enabled ? sanitized : nil
            )
        }
        if bot.workingHours.enabled {
            return ProactiveChatWindow(
                source: .globalWorkingHours,
                hours: bot.workingHours.sanitized
            )
        }
        let proactive = settings.sanitized.activeHoursSanitized
        return ProactiveChatWindow(
            source: proactive.enabled ? .proactive : .unrestricted,
            hours: proactive.enabled ? proactive : nil
        )
    }

    /// 当前时间是否在该会话的生效时段内（供设置页状态与测试使用）。
    static func isWithinWindow(
        settings: ProactiveChatSettings,
        bot: BotSettings,
        conversation: Conversation,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        effectiveWindow(settings: settings, bot: bot, conversation: conversation)
            .contains(now, calendar: calendar)
    }

    /// 一条会话的消息是否都太久没有动静时仍然考虑（不额外限制上限）；
    /// 用户明确选择了会话，长期沉默也属于「可以主动问候」的场景。
    static func evaluate(
        settings: ProactiveChatSettings,
        bot: BotSettings,
        conversation: Conversation,
        messages: [ChatMessage],
        state: ProactiveChatRuntimeState,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProactiveChatDecision {
        let settings = settings.sanitized

        guard settings.enabled else { return .skip("主动聊天未启用") }
        guard settings.normalizedConversationIDs.contains(conversation.id) else {
            return .skip("会话不在主动聊天名单")
        }
        guard conversation.aiEnabled else { return .skip("会话已关闭 AI 回复") }
        // 公众号/服务号不是可对话对象（机器人默认也忽略其入站消息），主动聊天跳过。
        guard conversation.kind != .official else { return .skip("公众号不支持主动聊天") }
        let blacklist = Set(bot.effectiveBlacklist)
        if blacklist.contains(conversation.id) {
            return .skip("会话在黑名单中")
        }
        // 白名单是「允许自动回复的会话」；主动聊天更不应该越过它去打扰别人。
        let whitelist = bot.effectiveWhitelist
        if !whitelist.isEmpty, !whitelist.contains(conversation.id) {
            return .skip("会话不在白名单中")
        }
        let nowDate = now

        // 生效时段：会话独立时段 > 节奏的全局工作时间 > 主动页时段（仅兜底）。
        let window = effectiveWindow(settings: settings, bot: bot, conversation: conversation)
        guard window.contains(nowDate, calendar: calendar) else {
            return .skip("不在\(window.source.label)（\(window.hours?.summaryText ?? "不限时段")）")
        }

        var state = state
        state.beginDay(nowDate, calendar: calendar)
        let conversationState = state.state(for: conversation.id)
        guard conversationState.sentToday < settings.maxPerConversationPerDay else {
            return .skip("此会话今日主动已达上限（\(settings.maxPerConversationPerDay) 条）")
        }
        if settings.skipIfUnanswered, conversationState.awaitingReply {
            return .skip("上一条主动消息还没有回复")
        }

        // 静默时长：优先用会话最后一条消息时间，缺失时退回内存中的最后一条消息。
        let lastActivity = conversation.lastMessageAt ?? messages.last?.timestamp
        guard let lastActivity else {
            return .skip("会话还没有聊天记录")
        }
        let idleSeconds = nowDate.timeIntervalSince(lastActivity)
        guard idleSeconds >= 0 else { return .skip("会话时间异常（最后消息在未来）") }
        let requiredIdle = Double(settings.idleMinutes * 60)
        guard idleSeconds >= requiredIdle else {
            let remaining = max(0, requiredIdle - idleSeconds)
            return .skip("静默时间不足，还需 \(Int(remaining / 60)) 分钟")
        }

        // 失败退避：`lastAttemptAt` 晚于 `lastSentAt`，说明上次生成/发送失败过。
        // 成功发送后的节奏完全由上面的静默时长决定（机器人自己的消息会更新最后消息时间），
        // 不再需要用户再配一个「最小间隔」。
        if let attempted = conversationState.lastAttemptAt,
           conversationState.lastSentAt.map({ attempted > $0 }) ?? true {
            let elapsed = nowDate.timeIntervalSince(attempted)
            let required = Double(ProactiveChatSettings.retryBackoffMinutes * 60)
            guard elapsed >= required else {
                let remaining = max(1, Int(ceil((required - elapsed) / 60)))
                return .skip("上次生成/发送失败，约 \(remaining) 分钟后重试")
            }
        }

        let idleLabel = ProactiveChatSettings.idleLabel(minutes: settings.idleMinutes)
        return .send("会话已静默 \(idleLabel)，满足主动聊天条件")
    }
}
