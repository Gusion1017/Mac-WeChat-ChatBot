import Foundation

// MARK: - Reply plan

struct ChatReplyPlan: Sendable {
    var segments: [String]
    var fullText: String
    var providerID: String
    var providerName: String
    var personaID: String?
    var model: String
    var latencyMs: Double
    var usage: AIUsage
    var dryRun: Bool
    var delaysMs: [Int]
    var contextMessageCount: Int
}

/// Builds prompts and produces reply plans. Never sends anything itself; the runtime
/// owns transport and human-like pacing so this stays testable and transport-agnostic.
final class ChatEngine: @unchecked Sendable {
    /// 短期记忆窗口：固定最多 10 条消息。超出的旧消息由 summarizeOverflow 总结。
    static let shortTermMemoryLimit = 10
    /// 批量总结阈值：短期窗口外未总结消息攒够 8 条才触发一次 AI 总结，
    /// 既避免每条新消息都调用模型，也把「窗口外未总结」的遗忘区间压到最多 7 条。
    static let overflowBatchThreshold = 8
    /// 单次批量总结的消息上限（多出的部分留到下一批）。
    static let maxOverflowBatch = 40
    /// 长期记忆正文长度上限；AI 结果与本地兜底摘要都会被压缩到该长度。
    static let summaryCharacterLimit = 600
    /// 长期记忆正文的要点条数上限（AI 提示与本地兜底共用）。
    static let summaryBulletLimit = 5
    /// 同会话早期相关片段的召回条数上限。
    static let earlierRecallLimit = 3
    /// 长期记忆注入提示词的最大条数（核心记忆优先占用名额，核心之间按综合权重排序）。
    static let longTermMemoryLimit = 6

    private let memory: MemoryStore
    private let aiClient: AIClient
    var onLog: (@Sendable (LogLevel, String) -> Void)?

    init(memory: MemoryStore, aiClient: AIClient) {
        self.memory = memory
        self.aiClient = aiClient
    }

    // MARK: Generate

    func generateReply(
        conversation: Conversation,
        incoming: ChatMessage,
        settings: AppSettings,
        persona: Persona?,
        provider: AIProvider,
        history: [ChatMessage],
        dryRun: Bool
    ) async throws -> ChatReplyPlan {
        let maxRetries = max(0, settings.ai.retryCount)
        var lastError: Error = AIError.emptyResponse

        for attempt in 0...maxRetries {
            do {
                return try await attemptReply(
                    conversation: conversation,
                    incoming: incoming,
                    settings: settings,
                    persona: persona,
                    provider: provider,
                    history: history,
                    dryRun: dryRun
                )
            } catch is CancellationError {
                throw AIError.cancelled
            } catch {
                lastError = error
                let retryable = (error as? AIError)?.isRetryable ?? false
                if !retryable || attempt == maxRetries { throw error }
                let delay = 400 * (attempt + 1)
                onLog?(.warning, "AI 请求失败，\(delay)ms 后重试（\(attempt + 1)/\(maxRetries)）：\(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
        }
        throw lastError
    }

    private func attemptReply(
        conversation: Conversation,
        incoming: ChatMessage,
        settings: AppSettings,
        persona: Persona?,
        provider: AIProvider,
        history: [ChatMessage],
        dryRun: Bool
    ) async throws -> ChatReplyPlan {
        let memories = (try? await memory.fetchMemoriesForPrompt(
            conversationID: conversation.id,
            limit: Self.longTermMemoryLimit
        )) ?? []
        let longTermNotes = await recallLongTermMemory(conversation: conversation, memories: memories)
        // 本轮发言人的权威身份约束：群昵称会被改、会被开玩笑，长期记忆里的
        // wxid→称呼才是稳定键。把这条放到 system 末尾，压过最近聊天里的玩梗。
        let speakerIdentity = Self.speakerIdentityNote(
            conversation: conversation,
            incoming: incoming,
            memories: memories
        )
        let earlierNotes = await recallEarlierMessages(
            conversation: conversation,
            incoming: incoming,
            history: history
        )
        let memoryParts = [longTermNotes, earlierNotes].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let memoryNotes = memoryParts.isEmpty ? nil : memoryParts.joined(separator: "\n\n")
        let promptMessages = buildMessages(
            conversation: conversation,
            incoming: incoming,
            settings: settings,
            persona: persona,
            history: history,
            memoryNotes: memoryNotes,
            speakerIdentity: speakerIdentity
        )
        let temperature = settings.ai.temperature(forModel: AIClient.effectiveModel(for: provider))
        let result = try await aiClient.complete(
            messages: promptMessages,
            provider: provider,
            temperature: temperature,
            forceStream: Self.forceStream(for: settings)
        )
        let plan = makePlan(result: result, provider: provider, persona: persona,
                            settings: settings, dryRun: dryRun, contextCount: promptMessages.count)
        onLog?(.debug, "AI 回复生成完成：\(result.text.count) 字，\(Int(result.latencyMs))ms，"
            + "tokens=\(result.usage.totalTokens)（上下文 \(promptMessages.count) 条）")
        return plan
    }

    // MARK: Prompt assembly

    /// 全局「流式回复」总开关：关闭时所有通道都走非流式（forceStream = false），
    /// 开启时按各 provider 自己的 `stream` 设置（forceStream = nil）。
    static func forceStream(for settings: AppSettings) -> Bool? {
        settings.ai.streamReplies ? nil : false
    }

    func buildMessages(
        conversation: Conversation,
        incoming: ChatMessage,
        settings: AppSettings,
        persona: Persona?,
        history: [ChatMessage],
        memoryNotes: String?,
        speakerIdentity: String? = nil
    ) -> [AIMessage] {
        var systemLines: [String] = []
        let basePrompt = (persona?.systemPrompt ?? Persona.defaultSystemPrompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !basePrompt.isEmpty { systemLines.append(basePrompt) }
        systemLines.append("你在 macOS 微信客户端上以真人身份聊天，回复要简短自然，不要暴露自己是 AI。")
        systemLines.append("当前时间：\(ISO8601DateFormatter.localDateTimeString())")
        systemLines.append("会话类型：\(conversation.kind.label)；会话名称：\(conversation.displayTitle)")
        if conversation.kind == .group {
            systemLines.append("群聊消息格式为「昵称(wxid)：内容」或「wxid：内容」，括号内是发言人的微信 ID；"
                + "昵称可能重名或被修改，判断谁在说话时请以括号内的 wxid 为准，"
                + "对照长期记忆中「wxid：称呼」的人员对应关系；"
                + "记忆里找不到该 wxid 时直接用消息里的昵称或「你」，"
                + "不要套用记忆中其他人的称呼；回复时不要输出 wxid。")
        }
        // 引用消息用固定定界符标记被引用内容，帮助模型区分「本轮发言」与「引用的历史消息」。
        systemLines.append("引用消息的格式为「回复正文」换行「【引用 发言人：被引用原文】」；"
            + "【引用 …】内是对方引用的历史消息，不是本轮新内容，回复时不要把它当成当前发言人刚说的话。")
        let note = conversation.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            systemLines.append("关于此会话的长期记忆：\(note)")
        }
        if let memoryNotes, !memoryNotes.isEmpty {
            systemLines.append("相关历史记忆（仅供参考，不要逐字复述）：\n\(memoryNotes)")
        }
        // 放在最后：最近聊天里的「我就是某某」「某某其实是某某」不能覆盖这条。
        if let speakerIdentity, !speakerIdentity.isEmpty {
            systemLines.append(speakerIdentity)
        }

        var messages: [AIMessage] = [.system(systemLines.joined(separator: "\n"))]

        let configured = max(2, settings.bot.maxContextMessages)
        let maxContext = min(configured, Self.shortTermMemoryLimit)
        let recent = Array(history.suffix(maxContext))
        let isGroupChat = conversation.kind == .group
        var conversationMessages: [AIMessage] = recent.compactMap { message in
            guard message.direction != .system else { return nil }
            let content = Self.promptText(for: message)
            guard !content.isEmpty else { return nil }
            if message.direction == .outgoing {
                return .assistant(content)
            }
            return .user(Self.attributedUserText(content, message: message, isGroupChat: isGroupChat))
        }
        let incomingText = Self.promptText(for: incoming)
        if recent.last?.id != incoming.id, !incomingText.isEmpty {
            conversationMessages.append(.user(
                Self.attributedUserText(incomingText, message: incoming, isGroupChat: isGroupChat)
            ))
        }
        messages.append(contentsOf: Self.mergeAdjacentRoles(conversationMessages))
        return messages
    }

    /// 群聊里给 incoming 内容加上发言人前缀，避免多人群聊丢失说话人；
    /// 私聊保持原文，减少提示词噪声。
    static func attributedUserText(_ content: String, message: ChatMessage, isGroupChat: Bool) -> String {
        guard isGroupChat, let speaker = promptSpeakerLabel(for: message) else { return content }
        return "\(speaker)：\(content)"
    }

    /// 提示词用发言人标识：群聊里同时带昵称与 wxid。
    ///
    /// 长期记忆以 wxid 为人员对应关系的键（`wxid_xxx：称呼`），只给昵称时
    /// 群昵称被修改/重名或模型无法把昵称当成键，就会凭印象套用别人的称呼。
    /// 这里让每条消息自带稳定键，同时保留昵称方便称呼。`senderName` 为空时
    /// 直接回退 wxid，不再重复拼接。
    static func promptSpeakerLabel(for message: ChatMessage) -> String? {
        guard let name = speakerLabel(for: message) else { return nil }
        let id = message.senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != "self", id != "system", id != "我", id != "系统", id != name else {
            return name
        }
        return "\(name)(\(id))"
    }

    /// 发言人展示名：优先 senderName，缺失时回退 senderID。
    static func speakerLabel(for message: ChatMessage) -> String? {
        let name = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != "我", name != "系统", name != "self" {
            return name
        }
        let id = message.senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty, id != "self", id != "system", id != "我" {
            return id
        }
        return nil
    }

    static func promptText(for message: ChatMessage) -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        switch message.kind {
        case .image: return "[图片]"
        case .voice: return "[语音]"
        case .emoji: return "[表情]"
        case .file: return "[文件]"
        case .video: return "[视频]"
        case .link: return message.mediaURL ?? "[链接]"
        case .system: return ""
        case .text: return ""
        }
    }

    static func mergeAdjacentRoles(_ messages: [AIMessage]) -> [AIMessage] {
        var merged: [AIMessage] = []
        for message in messages {
            if let last = merged.last, last.role == message.role {
                merged[merged.count - 1] = AIMessage(role: last.role, content: last.content + "\n" + message.content)
            } else {
                merged.append(message)
            }
        }
        return merged
    }

    // MARK: Memory recall

    /// 只在本会话内召回短期窗口之外的早期片段：避免把其他会话的原文塞进当前对话。
    /// 结果明确标注为「较早、可能过时」，最多 `earlierRecallLimit` 条。
    func recallEarlierMessages(
        conversation: Conversation,
        incoming: ChatMessage,
        history: [ChatMessage]
    ) async -> String? {
        let text = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return nil }
        let tokens = Self.memoryTokens(from: text)
        guard !tokens.isEmpty else { return nil }

        let recentIDs = Set(history.suffix(Self.shortTermMemoryLimit).map(\.id))
        let excluded = recentIDs.union([incoming.id])
        var lines: [String] = []
        var seen = Set<String>()
        for token in tokens.prefix(2) {
            guard let hits = try? await memory.searchMessages(query: token, limit: 12) else { continue }
            for hit in hits {
                let message = hit.message
                guard message.conversationID == conversation.id else { continue }
                guard !excluded.contains(message.id) else { continue }
                guard message.direction != .system else { continue }
                guard message.timestamp <= incoming.timestamp else { continue }
                let snippet = Self.promptText(for: message)
                guard snippet.count >= 2, !seen.contains(snippet) else { continue }
                seen.insert(snippet)
                let who: String
                if message.direction == .outgoing {
                    who = "我"
                } else if conversation.kind == .group {
                    who = Self.promptSpeakerLabel(for: message) ?? "对方"
                } else {
                    who = "对方"
                }
                lines.append("- \(who)：\(snippet.prefix(120))")
                if lines.count >= Self.earlierRecallLimit { break }
            }
            if lines.count >= Self.earlierRecallLimit { break }
        }
        guard !lines.isEmpty else { return nil }
        return "本会话较早的相关片段（可能已过时，仅供参考）：\n" + lines.joined(separator: "\n")
    }

    static func memoryTokens(from text: String) -> [String] {
        var tokens: [String] = []
        var cjkBuffer = ""
        var asciiBuffer = ""

        func flush() {
            if cjkBuffer.count >= 2 && cjkBuffer.count <= 20 { tokens.append(cjkBuffer) }
            if asciiBuffer.count >= 2 && asciiBuffer.count <= 20 { tokens.append(asciiBuffer) }
            cjkBuffer = ""
            asciiBuffer = ""
        }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isASCIIAlphanumeric = (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            let isCJK = (0x4E00...0x9FFF).contains(value)
            if isASCIIAlphanumeric {
                if !cjkBuffer.isEmpty { flush() }
                asciiBuffer.unicodeScalars.append(scalar)
            } else if isCJK {
                if !asciiBuffer.isEmpty { flush() }
                cjkBuffer.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()

        var unique: [String] = []
        for token in tokens where !unique.contains(token) {
            unique.append(token)
        }
        return unique
    }

    // MARK: Speaker identity / person mapping

    /// 从核心/手写记忆里解析 `wxid_xxx：称呼1/称呼2` 形式的人员对应关系。
    ///
    /// 只用于群聊提示词的硬约束与自动总结冲突过滤；解析不出的行直接忽略，
    /// 不影响其它记忆。昵称本身可以包含括号（如「昵称（备注）」），不做过度清洗。
    static func personMappings(in summaries: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        let pattern = #"(wxid_[A-Za-z0-9_-]+)\s*[：:]\s*([^\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }

        for summary in summaries {
            let text = summary as NSString
            let matches = regex.matches(in: summary, range: NSRange(location: 0, length: text.length))
            for match in matches {
                guard match.numberOfRanges >= 3 else { continue }
                let id = text.substring(with: match.range(at: 1))
                let aliases = text.substring(with: match.range(at: 2))
                    .components(separatedBy: CharacterSet(charactersIn: "/、,，|"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "。；;：:")) }
                    .filter { !$0.isEmpty && $0.count <= 40 && !$0.contains("回答时不要带出") }
                guard !aliases.isEmpty else { continue }
                var merged = result[id] ?? []
                for alias in aliases where !merged.contains(alias) { merged.append(alias) }
                result[id] = merged
            }
        }
        return result
    }

    /// 去掉自动总结里的人物归属段（人物与称呼 / wxid 清单）。
    /// 手写/核心映射才是权威来源，自动总结里的这些行最容易把群聊玩笑固化成事实。
    static func removingPersonMappingLines(from summary: String) -> String {
        summary
            .components(separatedBy: "\n")
            .filter { line in
                var body = line.trimmingCharacters(in: .whitespacesAndNewlines)
                for prefix in ["- ", "* ", "• ", "· "] where body.hasPrefix(prefix) {
                    body = String(body.dropFirst(prefix.count))
                }
                body = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return !(body.hasPrefix("人物与称呼")
                    || body.hasPrefix("人物：")
                    || body.hasPrefix("人物:")
                    || body.hasPrefix("群成员")
                    || body.hasPrefix("wxid_"))
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 提示词里实际注入的摘要：有权威人员映射时，自动总结去掉人物段。
    static func promptSummary(
        for memory: LongTermMemory,
        hasAuthoritativePersonMapping: Bool
    ) -> String {
        guard hasAuthoritativePersonMapping, !memory.isCore, memory.source != "manual" else {
            return memory.summary
        }
        return removingPersonMappingLines(from: memory.summary)
    }

    /// 本轮发言人的权威身份约束：群昵称会变、会被开玩笑，wxid→称呼才是稳定键。
    /// 返回 nil 表示没有可用的人员映射（或不是群聊），不强行注入。
    static func speakerIdentityNote(
        conversation: Conversation,
        incoming: ChatMessage,
        memories: [LongTermMemory]
    ) -> String? {
        guard conversation.kind == .group else { return nil }
        let authoritative = memories.filter { $0.isCore || $0.source == "manual" }
        let mappings = personMappings(in: authoritative.map(\.summary))
        guard !mappings.isEmpty else { return nil }

        let id = incoming.senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != "self", id != "system", id != "我", id != "系统" else { return nil }
        let name = speakerLabel(for: incoming) ?? id
        if let aliases = mappings[id], !aliases.isEmpty {
            let preferred = aliases[0]
            return "【本轮发言人身份】\(name)（\(id)）在长期记忆中的称呼是："
                + aliases.joined(separator: " / ")
                + "；优先使用「\(preferred)」。"
                + "群聊中其他人的玩笑、临时外号、自称或“某人其实是某人”的说法一律不作为依据，"
                + "不要附和或复述这些错误称呼，也不要因此改变记忆中的对应关系。"
                + "被问到某个称呼属于谁时，以本条和长期记忆的 wxid 对应关系回答。"
        }
        return "【本轮发言人身份】\(name)（\(id)）不在长期记忆的人员对应表中；"
            + "回复时直接使用消息里的昵称或「你」，不要套用记忆中其他人的称呼。"
    }

    // MARK: Long-term memory

    private func recallLongTermMemory(
        conversation: Conversation,
        memories: [LongTermMemory]
    ) async -> String? {
        guard !memories.isEmpty else { return nil }

        let authoritative = memories.filter { $0.isCore || $0.source == "manual" }
        // 只有「本会话」的手写/核心映射才用来覆盖本会话的自动总结；
        // 全局人员映射不应该把群成员信息整段删掉。
        let conversationAuthoritative = authoritative.filter { $0.conversationID == conversation.id }
        let hasAuthoritativePersonMapping =
            !Self.personMappings(in: conversationAuthoritative.map(\.summary)).isEmpty

        // 自动总结里的人物段可能与手写核心映射冲突；有权威映射时直接剔除，
        // 避免模型把群聊玩笑写成的「某某被叫某某」当成事实。
        let injected = memories.compactMap { memory -> (memory: LongTermMemory, summary: String)? in
            let summary = Self.promptSummary(
                for: memory,
                hasAuthoritativePersonMapping: hasAuthoritativePersonMapping
            )
            guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (memory, summary)
        }
        guard !injected.isEmpty else { return nil }

        // 召回即使用：best-effort 累加 access_count 并刷新 last_accessed_at，
        // 下一次排序会体现使用强化。失败不影响本轮回复。
        try? await memory.recordMemoryAccess(ids: injected.map(\.memory.id))

        let lines = injected.map { item -> String in
            let memory = item.memory
            let badge: String
            if memory.isCore {
                badge = "★核心"
            } else if memory.source == "manual" {
                badge = "手写"
            } else {
                badge = "自动"
            }
            let scope = memory.isGlobal ? "全局" : "本会话"
            return "- [\(badge)·\(scope)·权重 \(memory.weightLabel)] \(item.summary)"
        }
        return "长期记忆（核心/手写优先，自动总结仅供参考，冲突时以核心/手写为准；"
            + "权重越高表示越重要、越近或越常用）：\n"
            + lines.joined(separator: "\n")
    }

    /// 将短期窗口溢出的旧消息批量总结进长期记忆；返回本次总结的消息数。
    ///
    /// 只有游标与短期窗口 cutoff 之间攒够 `overflowBatchThreshold` 条旧消息才总结，
    /// 单次最多 `maxOverflowBatch` 条；同一会话复用最近一条自动总结（滚动更新），
    /// 历史遗留的多条自动总结会先合并为一条。
    @discardableResult
    func summarizeOverflow(
        conversation: Conversation,
        provider: AIProvider?,
        settings: AppSettings
    ) async -> Int {
        guard let overflow = try? await memory.pendingMemoryOverflow(
            conversationID: conversation.id,
            keep: Self.shortTermMemoryLimit,
            minOverflow: Self.overflowBatchThreshold,
            maxMessages: Self.maxOverflowBatch
        ), !overflow.messages.isEmpty else { return 0 }

        // 同一会话只保留一条自动滚动总结：先合并历史遗留的多条（失败不阻塞）。
        let existing = await consolidateAutoMemories(conversation: conversation)
        // 核心/手写记忆是权威参考：自动总结要避让，不得覆盖或重复罗列。
        // 这里不能只用 manualMemories（它排除 is_core）——群聊的人员映射常常写在
        // 「手写核心记忆」里，拿不到它，摘要就会把群里的玩笑写进人物与称呼。
        let promptMemories = (try? await memory.fetchMemoriesForPrompt(
            conversationID: conversation.id,
            limit: 20
        )) ?? []
        let authoritative = promptMemories.filter { $0.isCore || $0.source == "manual" }
        // 只根据本会话的手写/核心映射决定是否剔除自动总结的人物段；
        // 全局人员映射不应把群成员信息整段删掉。
        let conversationAuthoritative = authoritative.filter { $0.conversationID == conversation.id }
        let hasAuthoritativePersonMapping =
            !Self.personMappings(in: conversationAuthoritative.map(\.summary)).isEmpty
        let existingText = existing.map { memory in
            hasAuthoritativePersonMapping
                ? Self.removingPersonMappingLines(from: memory.summary)
                : memory.summary
        }

        let transcript = Self.transcript(for: overflow.messages)
        guard !transcript.isEmpty else {
            try? await memory.markMemorySummarized(
                conversationID: conversation.id,
                throughRowID: overflow.lastRowID
            )
            return 0
        }

        var summary: String?
        if let provider, aiClient.hasCredential(for: provider) {
            let promptPair = Self.summaryPrompt(
                conversation: conversation,
                authoritativeMemories: authoritative,
                hasAuthoritativePersonMapping: hasAuthoritativePersonMapping,
                existingSummary: existingText,
                transcript: transcript,
                newMessageCount: overflow.messages.count
            )
            let messages: [AIMessage] = [
                .system(promptPair.system),
                .user(promptPair.user)
            ]
            do {
                let temperature = settings.ai.temperature(forModel: AIClient.effectiveModel(for: provider))
                let result = try await aiClient.complete(
                    messages: messages,
                    provider: provider,
                    temperature: temperature
                )
                let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw AIError.emptyResponse }
                var compacted = MemorySummaryCompactor.compact(
                    trimmed,
                    maxCharacters: Self.summaryCharacterLimit
                )
                // 兜底：即使模型没遵守，也不让把群聊玩梗写成的人物段进入长期记忆。
                if hasAuthoritativePersonMapping {
                    compacted = Self.removingPersonMappingLines(from: compacted)
                }
                if !compacted.isEmpty { summary = compacted }
            } catch {
                onLog?(.warning, "长期记忆总结失败，使用本地摘要：\(error.localizedDescription)")
            }
        }

        if summary == nil || summary?.isEmpty == true {
            let fallback = Self.localSummary(existing: existingText, transcript: transcript)
            summary = hasAuthoritativePersonMapping
                ? Self.removingPersonMappingLines(from: fallback)
                : fallback
        }
        guard let finalSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !finalSummary.isEmpty else { return 0 }

        var record = existing ?? LongTermMemory(
            conversationID: conversation.id,
            summary: finalSummary,
            source: "summary"
        )
        record.conversationID = conversation.id
        record.conversationTitle = conversation.displayTitle
        record.summary = finalSummary
        record.updatedAt = Date()
        record.sourceCount += overflow.messages.count
        // 保留用户可能手工调过的基础权重，只做范围收敛；自动总结不重置权重。
        record.baseWeight = LongTermMemory.clampBaseWeight(record.baseWeight)

        do {
            try await memory.upsertMemory(record)
            try await memory.markMemorySummarized(
                conversationID: conversation.id,
                throughRowID: overflow.lastRowID
            )
            onLog?(.info, "长期记忆已更新（\(conversation.displayTitle)，"
                + "批量合并 \(overflow.messages.count) 条旧消息（单批上限 \(Self.maxOverflowBatch)），"
                + "累计 \(record.sourceCount) 条，权重 \(record.weightLabel)）")
            return overflow.messages.count
        } catch {
            onLog?(.error, "写入长期记忆失败：\(error.localizedDescription)")
            return 0
        }
    }

    /// 历史版本可能为同一会话留下多条自动总结；合并为最新一条：
    /// 累加 `sourceCount`、用压缩器合并摘要、保留最新一条并删除其余。
    /// best-effort：失败时保留原状并记录日志，不阻塞本次总结。
    private func consolidateAutoMemories(conversation: Conversation) async -> LongTermMemory? {
        guard let memories = try? await memory.autoMemories(conversationID: conversation.id),
              !memories.isEmpty else { return nil }
        guard memories.count > 1 else { return memories[0] }

        // autoMemories 按 updated_at 降序：第一条最新，合并摘要时按时间正序拼接。
        let keeper = memories[0]
        let mergedSummary = MemorySummaryCompactor.compact(
            memories.reversed().map(\.summary).joined(separator: "\n"),
            maxCharacters: Self.summaryCharacterLimit
        )
        let mergedSourceCount = memories.reduce(0) { $0 + max(0, $1.sourceCount) }
        var merged = keeper
        if !mergedSummary.isEmpty { merged.summary = mergedSummary }
        merged.sourceCount = mergedSourceCount
        merged.updatedAt = Date()
        // 保留用户可能手工调过的基础权重，只做范围收敛；合并不重置权重。
        merged.baseWeight = LongTermMemory.clampBaseWeight(keeper.baseWeight)

        do {
            try await memory.upsertMemory(merged)
            for duplicate in memories.dropFirst() {
                try await memory.deleteMemory(id: duplicate.id)
            }
            onLog?(.info, "已合并 \(memories.count) 条历史自动记忆为 1 条"
                + "（\(conversation.displayTitle)，累计 \(mergedSourceCount) 条消息）")
            return merged
        } catch {
            onLog?(.warning, "合并历史自动记忆失败，保留原状：\(error.localizedDescription)")
            return keeper
        }
    }

    static func transcript(for messages: [ChatMessage]) -> String {
        var lines: [String] = []
        var total = 0
        for message in messages where message.direction != .system {
            guard let text = Optional(Self.promptText(for: message)), !text.isEmpty else { continue }
            let who = message.direction == .outgoing ? "我" : (message.senderName.isEmpty ? "对方" : message.senderName)
            let line = "\(who)：\(text)"
            if total + line.count > 6_000 { break }
            lines.append(line)
            total += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    /// 批量总结提示词。抽成纯函数便于验证「有权威人员映射时禁止模型写人物归属」。
    static func summaryPrompt(
        conversation: Conversation,
        authoritativeMemories: [LongTermMemory],
        hasAuthoritativePersonMapping: Bool,
        existingSummary: String?,
        transcript: String,
        newMessageCount: Int
    ) -> (system: String, user: String) {
        var prompt = "请把下面的微信聊天压缩成一条可长期使用的记忆。"
        prompt += "要求：最多 \(summaryBulletLimit) 条要点，每行以「- 」开头，"
        prompt += "总长不超过 \(summaryCharacterLimit) 字；与已有记忆合并去重；"
        if hasAuthoritativePersonMapping {
            prompt += "人物与称呼由用户手写的核心记忆维护，你不需要输出「人物与称呼」部分；"
            prompt += "也不要把群聊里的玩笑、互称、临时外号、自称或“某人其实是某人”的玩梗写成人物归属；"
            prompt += "如果聊天与手写记忆冲突，以手写记忆为准，宁可不写也不要记录冲突说法；"
        } else {
            prompt += "按「人物与称呼 / 偏好 / 约定与待办 / 其他」组织；"
            prompt += "人物与称呼只记录长期稳定、可核实的对应关系，"
            prompt += "不要把群聊里的玩笑、互称、临时外号、自称或“某人其实是某人”的玩梗写成人物归属；"
        }
        prompt += "保留事实、偏好、约定和未完成事项；删除已解决或过时的细节；"
        prompt += "不要编造；不要罗列成员 wxid 清单，提到人时优先用已知称呼。\n"
        prompt += "\n会话：\(conversation.displayTitle)（\(conversation.kind.label)）\n"

        let authoritativeText = authoritativeMemories
            .map(\.summary)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        if !authoritativeText.isEmpty {
            prompt += "\n用户手写/核心记忆（权威参考，必须保留原意，不要覆盖或重复罗列）：\n"
            prompt += "\(authoritativeText.prefix(1_200))\n"
        }
        if let existingSummary, !existingSummary.isEmpty {
            prompt += "\n已有自动记忆（请在此基础上合并去重，保留仍然有效的内容）：\n\(existingSummary)\n"
        }
        prompt += "\n新增对话（\(newMessageCount) 条）：\n\(transcript)"

        let system = "你负责维护聊天机器人的长期记忆。只输出更新后的记忆正文，"
            + "最多 \(summaryBulletLimit) 条要点，每行以「- 」开头，"
            + "不要解释，总长不超过 \(summaryCharacterLimit) 字。"
        return (system, prompt)
    }

    /// 本地兜底摘要：已有摘要 + 新对话交给确定性压缩器，去重/规范空白
    /// 并强制不超过 `summaryCharacterLimit`（默认 600 字符），不再截断原文。
    static func localSummary(existing: String?, transcript: String) -> String {
        var parts: [String] = []
        if let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            parts.append(existing)
        }
        if !transcript.isEmpty { parts.append(transcript) }
        return MemorySummaryCompactor.compact(
            parts.joined(separator: "\n"),
            maxCharacters: summaryCharacterLimit
        )
    }

    // MARK: Reply shaping

    private func makePlan(
        result: AICompletionResult,
        provider: AIProvider,
        persona: Persona?,
        settings: AppSettings,
        dryRun: Bool,
        contextCount: Int
    ) -> ChatReplyPlan {
        let segments = Self.splitReply(
            result.text,
            humanize: settings.bot.humanize,
            dryRun: dryRun
        )
        let delays: [Int]
        if settings.bot.humanize.enabled && !dryRun {
            let minimum = max(0, settings.bot.humanize.minDelayMs)
            let maximum = max(minimum, settings.bot.humanize.maxDelayMs)
            delays = segments.map { _ in Int.random(in: minimum...maximum) }
        } else {
            delays = Array(repeating: 0, count: segments.count)
        }
        return ChatReplyPlan(
            segments: segments,
            fullText: result.text,
            providerID: provider.id,
            providerName: provider.name,
            personaID: persona?.id,
            model: result.model,
            latencyMs: result.latencyMs,
            usage: result.usage,
            dryRun: dryRun,
            delaysMs: delays,
            contextMessageCount: contextCount
        )
    }

    /// Splits a reply into natural chat bubbles and collapses overly small fragments.
    static func splitReply(_ raw: String, humanize: HumanizeSettings, dryRun: Bool = false) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard humanize.enabled, humanize.splitMessages, !dryRun else {
            return chunk(trimmed, maxLength: 1200)
        }

        var pieces: [String] = []
        var buffer = ""
        func flush() {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { pieces.append(value) }
            buffer = ""
        }

        for character in trimmed {
            buffer.append(character)
            let isBoundary = "。！？!?\n".contains(character)
            if isBoundary && buffer.count >= 8 {
                flush()
            } else if buffer.count >= 180 {
                flush()
            }
        }
        flush()

        // Merge too-short fragments forward so bubbles feel natural.
        var merged: [String] = []
        var carry = ""
        for piece in pieces {
            let candidate = carry.isEmpty ? piece : carry + piece
            if candidate.count < 12 {
                carry = candidate
                continue
            }
            merged.append(candidate)
            carry = ""
        }
        if !carry.isEmpty {
            if merged.isEmpty { merged.append(carry) } else { merged[merged.count - 1] += carry }
        }

        let maxSegments = max(1, humanize.maxSegments)
        if merged.count > maxSegments {
            let head = Array(merged.prefix(maxSegments - 1))
            let tail = merged.suffix(from: maxSegments - 1).joined(separator: " ")
            return head + chunk(tail, maxLength: 1200)
        }
        return chunkSegments(merged, maxLength: 600)
    }

    private static func chunkSegments(_ segments: [String], maxLength: Int) -> [String] {
        segments.flatMap { chunk($0, maxLength: maxLength) }
    }

    private static func chunk(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= maxLength {
                result.append(current)
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { result.append(remainder) }
        return result
    }
}

// MARK: - Memory summary compactor

/// 确定性记忆摘要压缩器：AI 总结与本地兜底摘要都会经过它。
///
/// - 逐行规范化空白、去掉空行，按行组织成 `- ` 要点；
/// - 去重时忽略空白与大小写差异；
/// - 超长时保留尾部最新内容，并插入「…（早期细节已压缩）」提示；
/// - 输出长度强制 `<= maxCharacters`（默认 600）。
enum MemorySummaryCompactor {
    static let defaultMaxCharacters = ChatEngine.summaryCharacterLimit
    static let defaultTruncationNote = "…（早期细节已压缩）"

    static func compact(
        _ text: String,
        maxCharacters: Int = defaultMaxCharacters,
        truncationNote: String = defaultTruncationNote
    ) -> String {
        let limit = max(1, maxCharacters)
        var seen = Set<String>()
        var bullets: [String] = []
        for line in normalizedLines(text) {
            let key = dedupeKey(for: line)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            bullets.append("- " + line)
        }
        guard !bullets.isEmpty else { return "" }

        let joined = bullets.joined(separator: "\n")
        guard joined.count > limit else { return joined }
        return tail(bullets: bullets, maxCharacters: limit, note: truncationNote)
    }

    // MARK: Internals

    private static func normalizedLines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { normalizedLine(String($0)) }
    }

    private static func normalizedLine(_ raw: String) -> String? {
        let collapsed = normalizedWhitespace(raw)
        let stripped = strippingOrderedPrefix(strippingBulletPrefix(collapsed))
        let line = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// 所有空白（含全角空格、制表符、换行）折叠为单个普通空格并去首尾。
    private static func normalizedWhitespace(_ raw: String) -> String {
        var result = ""
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !result.isEmpty { pendingSpace = true }
            } else {
                if pendingSpace {
                    result.append(" ")
                    pendingSpace = false
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func strippingBulletPrefix(_ line: String) -> String {
        let prefixes = ["- ", "* ", "• ", "· ", "– ", "— "]
        for prefix in prefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }

    /// 去掉「1. 」「2) 」「3、」这类有序列表序号。
    private static func strippingOrderedPrefix(_ line: String) -> String {
        var rest = Substring(line)
        var digits = ""
        while let first = rest.first, first.isNumber, digits.count < 3 {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let separator = rest.first,
              ".．、)".contains(separator) else { return line }
        var value = String(rest.dropFirst())
        if value.hasPrefix(" ") { value.removeFirst() }
        return value
    }

    private static func dedupeKey(for line: String) -> String {
        line.filter { !$0.isWhitespace }.lowercased()
    }

    /// 超长时从尾部保留最新要点，并在开头提示早期细节已压缩。
    private static func tail(bullets: [String], maxCharacters: Int, note: String) -> String {
        let budget = max(0, maxCharacters - note.count - 1)
        var kept: [String] = []
        var length = 0
        for bullet in bullets.reversed() {
            let extra = bullet.count + (kept.isEmpty ? 0 : 1)
            guard length + extra <= budget else { break }
            kept.insert(bullet, at: 0)
            length += extra
        }
        guard !kept.isEmpty else {
            // 单条要点就超过上限：硬截断尾部，保证长度约束。
            return String(bullets.joined(separator: "\n").suffix(maxCharacters))
        }
        let result = note + "\n" + kept.joined(separator: "\n")
        return result.count <= maxCharacters ? result : String(result.suffix(maxCharacters))
    }
}

private extension ISO8601DateFormatter {
    static func localDateTimeString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        return formatter.string(from: Date())
    }
}
