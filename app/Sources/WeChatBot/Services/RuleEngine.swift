import Foundation

// MARK: - Result

struct RuleEvaluation: Sendable {
    var shouldReply: Bool
    var reason: String
    var personaID: String?
    var providerID: String?
    var model: String?
    var triggerLabel: String

    static func blocked(_ reason: String) -> RuleEvaluation {
        RuleEvaluation(shouldReply: false, reason: reason,
                       personaID: nil, providerID: nil, model: nil, triggerLabel: "未触发")
    }
}

// MARK: - Engine

/// Pure decision logic for "should the bot answer this message, and with which persona/provider".
///
/// `RuleEngine` keeps only ephemeral throttling state (cooldown + per-minute cap),
/// guarded by a lock. It never performs IO and never touches the UI.
///
/// Trigger order:
/// 1. blacklist / whitelist / conversation switches (hard gates),
/// 2. bot-level defaults (`BotSettings.groupTriggers`, keywords, prefix).
///
/// Cooldown is consumed only when the runtime successfully sends a reply, via `noteReply`.
final class RuleEngine: @unchecked Sendable {
    private struct ThrottleState {
        var lastReplyAt: Date?
        var recentReplies: [Date] = []
    }

    private let lock = NSLock()
    private var throttles: [String: ThrottleState] = [:]
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    struct Context {
        var conversation: Conversation
        var message: ChatMessage
        var settings: AppSettings
        var now: Date = Date()
        /// Bot self id (wxid), used for group @ detection.
        var selfID: String = ""
    }

    // MARK: Evaluate

    func evaluate(_ context: Context) -> RuleEvaluation {
        let bot = context.settings.bot
        let conversation = context.conversation
        let message = context.message
        let senderID = message.senderID
        // 触发判定只看「本条消息自己的正文」：引用消息的被引用原文只是上下文，
        // 不能让「引用了一条 @过机器人 / 含关键词的旧消息」在群里重复触发（2026-10-22）。
        let text = Self.triggerText(message.text)

        // 1. Hard gates -------------------------------------------------------
        if !conversation.aiEnabled {
            return .blocked("会话已关闭 AI 回复")
        }
        if conversation.kind == .official && bot.ignoreOfficialAccounts {
            return .blocked("忽略公众号消息")
        }
        if message.direction == .outgoing && bot.ignoreSelf {
            return .blocked("忽略自己发送的消息")
        }
        // 统一名单：条目可以是会话 ID 或发送者 wxid；黑名单优先。
        let whitelist = bot.effectiveWhitelist
        let blacklist = bot.effectiveBlacklist
        if blacklist.contains(conversation.id) || (!senderID.isEmpty && blacklist.contains(senderID)) {
            return .blocked("会话或用户在黑名单中")
        }
        if !whitelist.isEmpty,
           !whitelist.contains(conversation.id),
           senderID.isEmpty || !whitelist.contains(senderID) {
            return .blocked("会话或用户不在白名单中")
        }
        let workingHours = conversation.effectiveWorkingHours(global: bot.workingHours)
        if workingHours.enabled && !workingHours.contains(context.now, calendar: calendar) {
            return .blocked(conversation.usesCustomWorkingHours ? "不在会话工作时段" : "不在工作时段")
        }
        // 免打扰设置已从产品中移除；isMuted 字段仅保留用于旧数据库兼容，不再参与判定。

        // 2. Bot defaults ------------------------------------------------------
        let defaults = botTriggerMatches(bot: bot, conversation: conversation, message: message,
                                         text: text, selfID: context.selfID)
        guard defaults.matched else {
            return .blocked(defaults.reason)
        }
        let throttle = checkThrottle(conversationID: conversation.id,
                                     cooldown: max(bot.cooldownSeconds, 0),
                                     perMinute: bot.maxRepliesPerMinute,
                                     now: context.now)
        if let throttle {
            return .blocked("触发限流：\(throttle)")
        }
        return RuleEvaluation(
            shouldReply: true,
            reason: "命中默认触发（\(defaults.label)）",
            personaID: conversation.personaID ?? bot.defaultPersonaID,
            providerID: conversation.providerID ?? bot.defaultProviderID,
            model: conversation.model,
            triggerLabel: defaults.label
        )
    }

    /// 触发判定用的正文：去掉 App 为引用消息追加的被引用上下文。
    ///
    /// `WeChatAppmsg` 的引用展示格式是 `回复正文\n[引用 发送者] 原文摘要`；
    /// 回复正文为空时只剩 `[引用 …] 原文摘要`。被引用原文只作为 AI 上下文，
    /// 不参与 @ / 关键词 / 前缀判定——否则「引用一条 @过机器人的旧消息再回一句
    /// 哈哈」会再次唤醒机器人，而微信的引用本身并不产生 @ 提醒。
    static func triggerText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "\n[引用 ", options: .backwards) {
            return String(trimmed[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 没有回复正文的引用消息：整条都是被引用上下文，没有可触发的内容。
        if trimmed.hasPrefix("[引用] ") || trimmed.hasPrefix("[引用 ") {
            return ""
        }
        return trimmed
    }

    /// Records a successful reply so cooldown / per-minute caps apply to future messages.
    func noteReply(conversationID: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var state = throttles[conversationID] ?? ThrottleState()
        state.lastReplyAt = date
        state.recentReplies.append(date)
        state.recentReplies.removeAll { date.timeIntervalSince($0) > 120 }
        throttles[conversationID] = state
        pruneLocked(now: date)
    }

    /// Clears throttling state (e.g. when the bot restarts).
    func resetThrottles() {
        lock.lock()
        defer { lock.unlock() }
        throttles.removeAll()
    }

    // MARK: Trigger matching

    private struct DefaultMatch {
        var matched: Bool
        var label: String
        var reason: String
    }

    private func botTriggerMatches(
        bot: BotSettings,
        conversation: Conversation,
        message: ChatMessage,
        text: String,
        selfID: String
    ) -> DefaultMatch {
        if conversation.kind == .direct {
            guard bot.replyToDirect else {
                return DefaultMatch(matched: false, label: "私聊", reason: "私聊回复已关闭")
            }
            return DefaultMatch(matched: true, label: "私聊", reason: "")
        }

        let triggers = bot.effectiveGroupTriggers
        if triggers.contains(.always) {
            return DefaultMatch(matched: true, label: "群聊·所有消息", reason: "")
        }
        var matchedLabels: [String] = []
        for trigger in triggers {
            switch trigger {
            case .always:
                break // handled above
            case .mention:
                if isMentioned(message: message, selfID: selfID, text: text,
                               mentionName: bot.selfMentionNames?[conversation.id]) {
                    matchedLabels.append("群聊·@")
                }
            case .keyword:
                if containsKeyword(bot.keywords, in: text) {
                    matchedLabels.append("群聊·关键词")
                }
            case .pat:
                if PatMessage.isDirectedAtBot(
                    message, conversation: conversation, selfID: selfID,
                    selfMentionName: bot.selfMentionNames?[conversation.id]
                ) {
                    matchedLabels.append("群聊·拍一拍")
                }
            case .quote:
                if isQuotingBot(message: message, selfID: selfID) {
                    matchedLabels.append("群聊·引用")
                }
            case .prefix:
                let prefix = bot.commandPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty, text.hasPrefix(prefix) {
                    matchedLabels.append("群聊·前缀")
                }
            }
        }
        if let label = matchedLabels.first {
            return DefaultMatch(matched: true, label: label, reason: "")
        }
        let labels = triggers.map(\.groupLabel).joined(separator: " / ")
        return DefaultMatch(matched: false, label: "群聊", reason: "未命中触发方式：\(labels)")
    }

    /// 群聊 @ 判定：
    /// 1. 结构化 at 段 / `mentions` 的目标等于机器人 wxid（最可靠）；
    /// 2. 文本里直接出现 `@<selfID>`（旧桥接把 wxid 渲染进正文）；
    /// 3. 文本里 `@<该群学到的机器人昵称>`（手动输入 / 客户端未带 atuserlist 的兜底）。
    ///
    /// 事件里的 `self_id` 永远存在，任意 at 段也可能 @ 的是别人（例如群收款卡片 @ 收款人），
    /// 因此不能只用 `self_id` 判断。
    private func isMentioned(message: ChatMessage, selfID: String, text: String,
                             mentionName: String?) -> Bool {
        guard !selfID.isEmpty else { return false }

        if let rawJSON = message.rawJSON,
           let data = rawJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if eventMentions(object, selfID: selfID) { return true }
            // 兼容包装事件 {"data": {...}}。
            if let nested = object["data"] as? [String: Any],
               eventMentions(nested, selfID: selfID) {
                return true
            }
        }

        // 回退 1：部分桥接版本把 wxid 直接渲染进文本（如 "@wxid_xxx"）。
        if text.contains("@\(selfID)") { return true }

        // 回退 2：用从成功 @ 事件学到的群昵称匹配纯文本 @。
        if let mentionName, MentionText.containsMention(of: mentionName, in: text) {
            return true
        }
        return false
    }

    private func eventMentions(_ event: [String: Any], selfID: String) -> Bool {
        if let mentions = event["mentions"] as? [Any],
           mentions.contains(where: { ($0 as? String) == selfID }) {
            return true
        }
        if let at = event["at"] as? [Any],
           at.contains(where: { ($0 as? String) == selfID }) {
            return true
        }
        guard let segments = event["message"] as? [[String: Any]] else { return false }
        for segment in segments where (segment["type"] as? String) == "at" {
            let data = segment["data"] as? [String: Any] ?? [:]
            let target = (data["qq"] as? String)
                ?? (data["user_id"] as? String)
                ?? (data["target_id"] as? String)
            if target == selfID { return true }
        }
        return false
    }

    /// 「引用机器人」判定：被引用消息的发送者是不是机器人自己。
    ///
    /// 用 `refermsg` 的结构化发送者 wxid（`<chatusr>`，私聊形态回退 `<fromusr>`），
    /// 不能用 `<displayname>`——昵称可重名，也不是稳定身份。
    /// 触发只看「引用谁」，与回复正文无关：正文没有 @/关键词时也应唤醒。
    private func isQuotingBot(message: ChatMessage, selfID: String) -> Bool {
        let botID = selfID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !botID.isEmpty else { return false }
        guard let quote = WeChatAppmsg.parse(eventJSON: message.rawJSON)?.quote else { return false }
        let quotedID = quote.senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quotedID.isEmpty else { return false }
        return quotedID.caseInsensitiveCompare(botID) == .orderedSame
    }

    private func containsKeyword(_ keywords: [String], in text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lowered = text.lowercased()
        return keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { !$0.isEmpty && lowered.contains($0) }
    }

    // 拍一拍的解析与「是否拍的是机器人」判定集中在 `PatMessage`：
    // - 4.1.12 及更早：系统消息（localType 10000）/ `<sysmsg type="pat">`；
    // - 4.1.15.55 实测：appmsg（type=49），`<appmsg><type>62</type><patinfo>…</patinfo>`。
    // 只有真实拍一拍事件才参与 .pat 触发；普通消息正文里提到「拍了拍」不算。

    // MARK: Throttling

    /// Returns a reason when the message must be dropped, `nil` when allowed.
    private func checkThrottle(conversationID: String, cooldown: Double, perMinute: Int, now: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        let state = throttles[conversationID] ?? ThrottleState()
        if cooldown > 0, let last = state.lastReplyAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < cooldown {
                return String(format: "冷却中（还需 %.1f 秒）", cooldown - elapsed)
            }
        }
        if perMinute > 0 {
            let recent = state.recentReplies.filter { now.timeIntervalSince($0) < 60 }
            if recent.count >= perMinute {
                return "每分钟最多 \(perMinute) 条"
            }
        }
        return nil
    }

    private func pruneLocked(now: Date) {
        throttles = throttles.filter { _, state in
            if let last = state.lastReplyAt, now.timeIntervalSince(last) > 3600 { return false }
            return true
        }
    }
}
