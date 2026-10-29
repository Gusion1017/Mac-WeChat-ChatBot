import Foundation

// MARK: - Extraction AI gate

/// 记忆提取的全局并发闸门：启动补跑/历史补总结可能同时有多个会话要调用模型，
/// 限制同时进行的提取请求数，避免一次向模型发几十个并发请求（限流/费用失控）。
/// 普通提取与历史补总结共用（按「一次 AI 请求」占用，不是按会话）。
private actor MemoryExtractionGate {
    static let shared = MemoryExtractionGate(limit: 3)

    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Capture policy

/// 哪些会话在「收到消息」时就应该有记忆卡（不再要求机器人先回复）。
///
/// 记忆卡以前只在生成回复时惰性创建，因此机器人不回复的群聊/私聊（平时群里
/// 没 @ 机器人）永远没有记忆卡：消息只留在账号库，既不进 `interactions`，
/// 也不会被批量提取。现在消息落库后由运行时按这里判定并后台建卡。
enum MemoryCapturePolicy {
    static func shouldCapture(conversation: Conversation, settings: AppSettings) -> Bool {
        guard settings.bot.memorySettings.enabled else { return false }
        let id = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != CharacterStore.globalConversationID else { return false }
        guard !ConversationName.isSystemAccount(id) else { return false }
        // 公众号/服务号没有长期记忆价值；文档约定默认不建卡。
        if conversation.kind == .official || id.lowercased().hasPrefix("gh_") {
            return false
        }
        // 用户在这个会话关闭了 AI：不再自动采集/总结。
        return conversation.aiEnabled
    }
}

// MARK: - MemoryEngine

/// 记忆 v2 的召回、批量提取、归档、压缩与导出。
///
/// - 无共享可变状态（`@unchecked Sendable` 仅持有线程安全的 actor/AIClient/闭包）；
/// - 所有 SQLite 读写委托给 `CharacterStore` actor；
/// - 提取/压缩需要 AI 时通过可注入的 `completion` 调用，便于单测。
final class MemoryEngine: @unchecked Sendable {
    typealias Completion = @Sendable ([AIMessage], AIProvider, Double?) async throws
        -> AICompletionResult

    /// 单批提取最多带入的互动条数。
    static let maxExtractionBatch = 40
    /// 单次提取最多返回的新记忆条数。
    static let maxExtractedMemories = 8
    /// 单条记忆正文建议上限。
    static let memoryContentLimit = 300
    /// 压缩后的正文上限。
    static let compressedContentLimit = 180
    /// 提示词里单条记忆的正文上限。
    static let promptContentLimit = 240
    /// 提取提示词里最多引用的已有记忆条数。
    static let extractionReferenceLimit = 12
    /// 首次维护时补总结「建卡前历史互动」的上限：只补最近这么多条，
    /// 避免一次建卡把 5000 条历史全交给 AI（也不丢弃更早的 `interactions`）。
    static let historyBackfillMessageLimit = 500

    private let characters: CharacterStore
    private let aiClient: AIClient
    private let completion: Completion
    var onLog: (@Sendable (LogLevel, String) -> Void)?

    init(
        characters: CharacterStore,
        aiClient: AIClient,
        completion: Completion? = nil
    ) {
        self.characters = characters
        self.aiClient = aiClient
        self.completion = completion ?? { messages, provider, temperature in
            try await aiClient.complete(
                messages: messages,
                provider: provider,
                temperature: temperature,
                forceStream: false,
                thinking: Self.extractionThinkingMode(for: provider)
            )
        }
    }

    /// 结构化 JSON 提取/压缩不需要长思考；DeepSeek 系显式关闭，避免思考内容挤空 `content`。
    private static func extractionThinkingMode(for provider: AIProvider) -> AIThinkingMode? {
        if provider.kind == .deepSeek { return .disabled }
        let host = URL(string: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?.lowercased() ?? ""
        return host.contains("deepseek") ? .disabled : nil
    }

    // MARK: Recall

    /// 一轮召回；`recordAccess = false` 用于记忆面板的预览/召回测试。
    func recall(
        conversationID: String,
        query: String,
        settings: MemorySettings = .default,
        now: Date = Date(),
        recordAccess: Bool = true
    ) async -> MemoryRecall {
        try? await characters.ensureGlobalCharacter()
        let local = (try? await characters.fetchMemories(conversationID: conversationID)) ?? []
        // 全局共享记忆注入所有会话；在全局卡自己的预览里不重复叠加。
        let global = conversationID == CharacterStore.globalConversationID
            ? []
            : ((try? await characters.fetchMemories(
                conversationID: CharacterStore.globalConversationID)) ?? [])
        let all = local + global
        let eligible = all.filter {
            !$0.archived && !$0.isSuperseded
                && !$0.normalizedContent.isEmpty
        }
        guard !eligible.isEmpty else { return .empty }

        var used = Set<String>()
        var usedContent = Set<String>()
        var ordered: [CharacterMemory] = []
        var omitted = 0

        func append(_ memory: CharacterMemory) {
            guard !used.contains(memory.id) else { return }
            let key = MemorySimilarity.normalize(memory.content)
            guard !key.isEmpty, usedContent.insert(key).inserted else { return }
            used.insert(memory.id)
            ordered.append(memory)
        }

        let recent = eligible
            .filter { $0.isRecent(now: now, settings: settings) }
            .sorted { $0.score(now: now, settings: settings) > $1.score(now: now, settings: settings) }
            .prefix(4)
        recent.forEach(append)

        let important = eligible
            .filter { $0.pinned || $0.kind == .important }
            .sorted { $0.score(now: now, settings: settings) > $1.score(now: now, settings: settings) }
            .prefix(4)
        important.forEach(append)

        let tokens = ChatEngine.memoryTokens(from: query)
        if !tokens.isEmpty {
            let related = eligible
                .filter { memory in
                    guard memory.category == .fact || memory.category == .lesson else { return false }
                    return Self.matches(memory: memory, tokens: tokens)
                }
                .sorted { $0.score(now: now, settings: settings) > $1.score(now: now, settings: settings) }
                .prefix(4)
            related.forEach(append)
        }

        if ordered.count < settings.maxRecallCount {
            let fill = eligible
                .filter { !used.contains($0.id) }
                .sorted { $0.score(now: now, settings: settings) > $1.score(now: now, settings: settings) }
            for memory in fill where ordered.count < settings.maxRecallCount {
                append(memory)
            }
        }

        if ordered.count > settings.maxRecallCount {
            omitted += ordered.count - settings.maxRecallCount
            ordered = Array(ordered.prefix(settings.maxRecallCount))
        }

        // 按 token 预算裁剪：保留优先级高的（数组前面的）。
        var total = 0
        var kept: [CharacterMemory] = []
        var budgetOmitted = 0
        for memory in ordered {
            let body = memory.promptText(limit: Self.promptContentLimit)
            let cost = body.count + 8
            if total + cost > settings.maxRecallCharacters, !kept.isEmpty {
                budgetOmitted += 1
                continue
            }
            kept.append(memory)
            total += cost
        }
        omitted += budgetOmitted
        guard !kept.isEmpty else { return .empty }

        if recordAccess {
            // 局部记忆与全局记忆分属不同的记忆库；按 characterID 分组回写访问次数。
            let groups = Dictionary(grouping: kept, by: \.characterID)
            for (ownerID, memories) in groups where !ownerID.isEmpty {
                try? await characters.recordAccess(
                    conversationID: ownerID,
                    ids: memories.map(\.id),
                    at: now
                )
            }
        }

        let body = kept.map { memory -> String in
            let tag = Self.promptTag(for: memory, settings: settings, now: now)
            return "- [\(tag)] \(memory.promptText(limit: Self.promptContentLimit))"
        }.joined(separator: "\n")
        var prompt = "记忆上下文（最近/重要/相关；已被取代的记忆不注入）：\n\(body)"
        if omitted > 0 {
            prompt += "\n（另有 \(omitted) 条记忆因条数/长度限制未注入）"
        }
        return MemoryRecall(
            memories: kept,
            prompt: prompt,
            omittedCount: omitted,
            estimatedCharacters: prompt.count
        )
    }

    private static func matches(memory: CharacterMemory, tokens: [String]) -> Bool {
        let content = memory.content
        let keywords = memory.keywords
        for token in tokens {
            if content.contains(token) { return true }
            if keywords.contains(where: { $0.contains(token) || token.contains($0) }) {
                return true
            }
        }
        return false
    }

    private static func promptTag(
        for memory: CharacterMemory,
        settings: MemorySettings,
        now: Date
    ) -> String {
        var parts = [memory.category.label]
        if memory.characterID == CharacterStore.globalConversationID {
            parts.insert("全局", at: 0)
        }
        if memory.pinned {
            parts.append("置顶")
        } else if memory.kind == .important {
            parts.append("重要")
        } else if memory.isRecent(now: now, settings: settings) {
            parts.append("最近")
        }
        parts.append("重要度 \(Int(memory.importance.rounded()))")
        return parts.joined(separator: "·")
    }

    // MARK: Extraction

    /// 满足阈值时提取一批；返回 nil 表示没有达到批量阈值。
    ///
    /// - Parameter minCount: 覆盖 `extractionBatchSize` 的最低待提取条数。
    ///   空闲兜底会传入「半批」来总结不足一批的新消息；历史补总结传 1。
    func extractIfNeeded(
        conversation: Conversation,
        provider: AIProvider?,
        settings: AppSettings,
        now: Date = Date(),
        minCount: Int? = nil
    ) async -> MemoryMaintenanceResult? {
        let memorySettings = settings.bot.memorySettings
        guard memorySettings.enabled, !Task.isCancelled else { return nil }
        let pendingThreshold = max(1, minCount ?? memorySettings.extractionBatchSize)
        guard let interactions = try? await characters.pendingInteractions(
            conversationID: conversation.id,
            minCount: pendingThreshold,
            maxMessages: Self.maxExtractionBatch
        ), !interactions.isEmpty else {
            return nil
        }
        return await extractBatch(
            interactions: interactions,
            conversation: conversation,
            provider: provider,
            settings: settings,
            now: now,
            advanceNormalCursor: true
        )
    }

    /// 对一批互动做提取、落库与游标推进；普通提取与历史补总结共用。
    ///
    /// - Parameter advanceNormalCursor: true 推进普通提取游标；false 推进
    ///   独立的「历史补总结」断点（不碰 `last_extracted_at`）。
    /// - Parameter historyBackfill: 提示词标记为「建卡前历史」，避免把旧事件
    ///   补成新的待办/决定。
    private func extractBatch(
        interactions: [CharacterInteraction],
        conversation: Conversation,
        provider: AIProvider?,
        settings: AppSettings,
        now: Date,
        advanceNormalCursor: Bool,
        historyBackfill: Bool = false
    ) async -> MemoryMaintenanceResult? {
        let memorySettings = settings.bot.memorySettings
        var result = MemoryMaintenanceResult(characterID: conversation.id)
        var persisted = true
        var batchInteractions = interactions

        let allExisting = (try? await characters.fetchMemories(conversationID: conversation.id))?
            .filter { !$0.archived && !$0.isSuperseded } ?? []
        // 交给模型的参考记忆：置顶/重要优先，再补本批关键词命中的，最后按更新补齐。
        let reference = Self.referenceMemories(allExisting, interactions: interactions)

        var extracted: [ExtractedMemory]?
        var usedFallback = false
        let hasAI = provider.map { aiClient.hasCredential(for: $0) } ?? false
        if let provider, hasAI {
            let prompt = Self.extractionPrompt(
                conversation: conversation,
                persona: settings.persona(
                    id: conversation.personaID ?? settings.bot.defaultPersonaID),
                existingMemories: reference,
                interactions: interactions,
                memoryLimit: Self.maxExtractedMemories,
                now: now,
                historyBackfill: historyBackfill
            )
            // 提示词受 6000 字预算限制：只把实际进入提示词的前缀记为已提取，
            // 否则批尾被截断的消息会被误标成已处理。
            let includedCount = min(max(0, prompt.includedCount), interactions.count)
            if includedCount > 0 {
                batchInteractions = Array(interactions.prefix(includedCount))
            }
            var requestProvider = provider
            requestProvider.stream = false
            requestProvider.maxTokens = max(provider.maxTokens, 2_000)
            // 全局并发闸门：一次 AI 请求占一个名额，普通提取与历史补总结共用。
            await MemoryExtractionGate.shared.acquire()
            do {
                let response = try await completion(
                    [.system(prompt.system), .user(prompt.user)],
                    requestProvider,
                    0.2
                )
                extracted = Self.parseExtraction(response.text)
                if extracted == nil {
                    onLog?(.warning, "记忆提取返回无法解析（\(conversation.displayTitle)）")
                }
            } catch {
                onLog?(.warning, "记忆提取失败：\(error.localizedDescription)")
            }
            await MemoryExtractionGate.shared.release()
        }

        // 停止机器人/切号会取消维护任务：取消后不再写库，避免停止后仍落盘。
        guard !Task.isCancelled else { return nil }
        result.processedInteractions = batchInteractions.count
        // 历史补总结的记忆时间锚点 = 这批实际进入提示词的最后一条时间，不能写 now：
        // 否则旧聊天会被记忆页与权重当成「最近/今天」，并生成过期计划。
        let memoryTimestamp = historyBackfill
            ? (batchInteractions.last?.timestamp ?? now)
            : now

        // 历史补总结必须由 AI 完成：没配 AI / 调用失败 / 解析失败时保留断点，
        // 下次维护重试；不能用本地兜底把压缩旧聊天永久标记成「已总结」。
        if historyBackfill, extracted == nil {
            onLog?(.warning, "历史补总结等待 AI 恢复，保留断点（\(conversation.displayTitle)）")
            return nil
        }

        let effective = extracted ?? []
        if extracted == nil {
            usedFallback = true
            let fallback = Self.localFallback(
                interactions: batchInteractions,
                characterID: conversation.id,
                now: now
            )
            if let fallback {
                persisted = await persist(
                    candidates: [fallback],
                    result: &result,
                    existing: allExisting,
                    conversationID: conversation.id,
                    settings: memorySettings,
                    sourceMessageIDs: batchInteractions.map(\.messageID),
                    timestamp: memoryTimestamp
                )
            }
        } else {
            // 历史补总结里的「今晚/这周末」等近期计划无法保证换算正确，
            // 统一把带近期时间词的 todo 降级为 fact：信息保留，不冒充当前待办。
            var candidates = effective
            var downgraded = 0
            if historyBackfill {
                candidates = effective.map { candidate in
                    var value = candidate
                    let category = HistoricalPlanHeuristics.downgradedCategory(
                        for: candidate.category,
                        content: candidate.content,
                        isHistoryBackfill: true
                    )
                    if category != candidate.category { downgraded += 1 }
                    value.category = category
                    return value
                }
            }
            if downgraded > 0 {
                onLog?(.info, "历史补总结：\(downgraded) 条近期计划降级为事实（\(conversation.displayTitle)）")
            }
            persisted = await persist(
                candidates: candidates,
                result: &result,
                existing: allExisting,
                conversationID: conversation.id,
                settings: memorySettings,
                sourceMessageIDs: batchInteractions.map(\.messageID),
                timestamp: memoryTimestamp
            )
        }
        result.usedFallback = usedFallback

        // 只有成功处理（含空结果/本地兜底）且落库成功才推进游标；
        // 失败时不推进，下批重试会走相似度折叠，不会重复堆积。
        // 普通游标用本批最后一条的 `(timestamp, id)`：同一秒内被 LIMIT 截断的消息
        // 下一批仍能续上，不会因为「本批最大时间戳」相同而永久漏掉。
        if persisted, let last = batchInteractions.last {
            do {
                if advanceNormalCursor {
                    try await characters.markExtracted(
                        conversationID: conversation.id,
                        through: last.timestamp,
                        interactionID: last.id
                    )
                } else {
                    try await characters.advanceHistoryBackfill(
                        conversationID: conversation.id,
                        through: last.timestamp,
                        interactionID: last.id
                    )
                }
                result.cursorAdvanced = true
            } catch {
                onLog?(.warning, "记忆提取游标推进失败：\(error.localizedDescription)")
            }
        } else if !persisted {
            onLog?(.warning, "记忆写入失败，保留提取游标等待重试（\(conversation.displayTitle)）")
            return result
        }

        // 历史补总结批次不跑归档：它们的 updated_at 是历史时间，
        // 若历史窗口超过归档阈值，刚补出来的记忆会被立刻归档。
        if memorySettings.autoArchive, !historyBackfill {
            result.archived = (try? await archiveStale(
                conversationID: conversation.id,
                settings: memorySettings,
                now: now
            )) ?? 0
        }

        let suffix = result.usedFallback ? "，本地兜底" : ""
        onLog?(.info, "记忆卡已更新（\(conversation.displayTitle)："
            + "处理 \(result.processedInteractions) 条，新增 \(result.added)，"
            + "合并 \(result.merged)，取代 \(result.superseded)，归档 \(result.archived)\(suffix)）")
        return result
    }

    // MARK: History backfill

    /// 一次性历史补总结：把建卡前的历史互动（最近 `messageLimit` 条）按批提取成记忆。
    ///
    /// 背景：`ensureCharacter` 把提取游标初始化在建卡时刻，历史回填只进
    /// `interactions`（全量记录），永远不会被 AI 总结——「平时」的群聊历史
    /// 就是这样只存档、不形成记忆的。现在记忆卡第一次维护时：
    ///
    /// 1. `beginHistoryBackfill` 建立一份**独立于普通提取游标**的补总结断点，
    ///    范围是建卡时刻之前最近 `messageLimit` 条互动；
    /// 2. 这里按批取 `pendingHistoryBackfill`（每批 ≤40 条）并提取，
    ///    最多补 `messageLimit` 条；普通 `last_extracted_at` 全程不动；
    /// 3. 补完写一次性标记；中途退出保留断点，下次维护继续。
    ///
    /// 返回 nil 表示这张卡不需要（或已经做过）历史补总结。
    func extractHistoryIfNeeded(
        conversation: Conversation,
        provider: AIProvider?,
        settings: AppSettings,
        now: Date = Date(),
        messageLimit: Int = MemoryEngine.historyBackfillMessageLimit
    ) async -> MemoryMaintenanceResult? {
        guard settings.bot.memorySettings.enabled, !Task.isCancelled else { return nil }
        // 历史补总结必须由 AI 完成：没有可用模型时直接跳过（断点未建立/未推进），
        // 等模型恢复后的下一次维护再补；不能用本地兜底把旧聊天永久标记为已总结。
        guard let provider, aiClient.hasCredential(for: provider) else {
            onLog?(.debug, "历史补总结跳过：没有可用的 AI 凭据（\(conversation.displayTitle)）")
            return nil
        }
        let limit = max(1, messageLimit)
        guard (try? await characters.beginHistoryBackfill(
            conversationID: conversation.id,
            limit: limit
        )) == true else { return nil }

        var total = MemoryMaintenanceResult(characterID: conversation.id)
        while !Task.isCancelled, total.processedInteractions < limit {
            let remaining = limit - total.processedInteractions
            guard let batch = try? await characters.pendingHistoryBackfill(
                conversationID: conversation.id,
                maxMessages: min(Self.maxExtractionBatch, max(1, remaining))
            ) else { break }
            guard !batch.isEmpty else {
                // 断点之外没有再早于建卡时刻的互动：一次性补总结完成。
                try? await characters.finishHistoryBackfill(
                    conversationID: conversation.id)
                break
            }
            guard let result = await extractBatch(
                interactions: batch,
                conversation: conversation,
                provider: provider,
                settings: settings,
                now: now,
                advanceNormalCursor: false,
                historyBackfill: true
            ) else { break }
            total.merge(result)
            // 落库失败/等待 AI 时游标不前进，必须停下等下次维护，避免原地重试刷 AI。
            if !result.cursorAdvanced { break }
        }
        guard total.processedInteractions > 0 else { return nil }
        onLog?(.info, "历史聊天补总结（\(conversation.displayTitle)：处理 \(total.processedInteractions) 条，"
            + "新增 \(total.added)，合并 \(total.merged)，取代 \(total.superseded)）")
        return total
    }

    /// 把提取结果落库：同类别相似度 ≥ 阈值折叠；supersede 双方留档。
    private func persist(
        candidates: [ExtractedMemory],
        result: inout MemoryMaintenanceResult,
        existing: [CharacterMemory],
        conversationID: String,
        settings: MemorySettings,
        sourceMessageIDs: [String],
        timestamp: Date
    ) async -> Bool {
        guard !candidates.isEmpty else { return true }
        var succeeded = true
        var working = existing
        for raw in candidates.prefix(Self.maxExtractedMemories) {
            let candidate = raw.sanitized
            guard !candidate.content.isEmpty else { continue }
            let memory = CharacterMemory(
                characterID: conversationID,
                category: candidate.category,
                kind: .normal,
                content: candidate.content,
                keywords: candidate.keywords,
                importance: candidate.importance,
                source: .extraction,
                sourceMessageIDs: sourceMessageIDs,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            var candidateMemory = memory
            candidateMemory.normalizeKind(threshold: settings.importanceThreshold)

            // 同类别相似度最高的一条（不合并进归档/已取代记忆）。
            let match = working
                .filter {
                    $0.category == candidate.category
                        && !$0.archived && !$0.isSuperseded
                }
                .map { ($0, MemorySimilarity.score($0.content, candidate.content)) }
                .filter { $0.1 >= settings.mergeSimilarity }
                .max { $0.1 < $1.1 }

            var stored: CharacterMemory
            if let (target, _) = match {
                var merged = target
                if candidate.content.count > merged.content.count {
                    merged.content = candidate.content
                    merged.compressedContent = nil
                }
                var keywordSet = Set(merged.keywords)
                for keyword in candidate.keywords { keywordSet.insert(keyword) }
                merged.keywords = Array(keywordSet)
                merged.importance = max(merged.importance, candidate.importance)
                merged.mergeCount += 1
                merged.sourceMessageIDs = Array(
                    Set(merged.sourceMessageIDs + sourceMessageIDs).sorted())
                // 不把历史记忆的 updated_at 拖回过去覆盖更新的记忆；普通提取时 timestamp≈now。
                merged.updatedAt = max(merged.updatedAt, timestamp)
                if merged.source != .manual && merged.source != .legacyImport {
                    merged.source = .extraction
                }
                merged.normalizeKind(threshold: settings.importanceThreshold)
                stored = merged
                if let index = working.firstIndex(where: { $0.id == merged.id }) {
                    working[index] = merged
                }
                result.merged += 1
            } else {
                stored = candidateMemory
                working.append(candidateMemory)
                result.added += 1
            }

            // supersede：先写新记忆，再给旧记忆盖戳；置顶不自动取代。
            if !candidate.supersedes.isEmpty {
                var supersededIDs: [String] = []
                for targetID in candidate.supersedes {
                    guard let index = working.firstIndex(where: { $0.id == targetID }) else {
                        continue
                    }
                    var target = working[index]
                    if targetID == stored.id { continue }
                    if target.pinned {
                        onLog?(.warning, "跳过取代置顶记忆：\(target.content.prefix(30))")
                        continue
                    }
                    if target.isSuperseded { continue }
                    target.supersededBy = stored.id
                    target.supersededAt = timestamp
                    working[index] = target
                    do {
                        try await characters.upsertMemory(target, now: timestamp)
                    } catch {
                        succeeded = false
                    }
                    supersededIDs.append(target.id)
                    result.superseded += 1
                }
                if !supersededIDs.isEmpty {
                    stored.supersedes = supersededIDs.joined(separator: ",")
                }
            }

            do {
                try await characters.upsertMemory(
                    stored, now: timestamp, preserveUpdatedAt: true)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    // MARK: Archive / compress

    /// 归档长期未访问、低召回的普通记忆；返回归档条数。
    @discardableResult
    func archiveStale(
        conversationID: String,
        settings: MemorySettings,
        now: Date = Date()
    ) async throws -> Int {
        let memories = try await characters.fetchMemories(conversationID: conversationID)
        let threshold = now.addingTimeInterval(-Double(settings.archiveAfterDays) * 86_400)
        var count = 0
        for var memory in memories {
            guard memory.kind == .normal, !memory.pinned, !memory.archived,
                  !memory.isSuperseded,
                  memory.activityAt < threshold,
                  memory.accessCount < 3 else { continue }
            memory.archived = true
            if memory.content.count > 300, memory.compressedContent == nil {
                memory.compressedContent = Self.normalizedCompression(memory.content)
            }
            try await characters.upsertMemory(memory, now: now)
            count += 1
        }
        if count > 0 {
            try await characters.markArchiveRun(conversationID: conversationID, at: now)
        }
        return count
    }

    /// 压缩一条记忆（AI 优先，失败用确定性压缩器）；只写 compressed_content，原文保留。
    func compress(
        memory: CharacterMemory,
        provider: AIProvider?,
        settings: AppSettings,
        now: Date = Date()
    ) async -> CharacterMemory? {
        var updated = memory
        var compressed: String?

        if let provider, aiClient.hasCredential(for: provider) {
            let system = "你负责压缩聊天机器人的一条长期记忆。只输出压缩后的正文，"
                + "不要解释、不要 Markdown、不要超过 \(Self.compressedContentLimit) 字；"
                + "保留人物、事实、约定、未完成事项和关键细节，不要编造。"
            let user = "记忆类别：\(memory.category.label)\n原始记忆：\n\(memory.content)"
            var requestProvider = provider
            requestProvider.stream = false
            requestProvider.maxTokens = min(max(provider.maxTokens, 300), 900)
            if let response = try? await completion(
                [.system(system), .user(user)],
                requestProvider,
                0.2
            ) {
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    compressed = Self.normalizedCompression(text)
                }
            }
        }
        if compressed?.isEmpty != false {
            compressed = Self.normalizedCompression(memory.content)
        }
        guard let compressed, !compressed.isEmpty else { return nil }
        updated.compressedContent = compressed
        updated.updatedAt = now
        do {
            try await characters.upsertMemory(updated, now: now)
            return updated
        } catch {
            onLog?(.warning, "保存压缩记忆失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Prompts / parsing (pure functions)

    /// 提取提示词里的参考记忆（最多 `extractionReferenceLimit` 条）：
    /// 置顶/重要优先，其次本批互动关键词命中的，最后按更新时间补齐。
    static func referenceMemories(
        _ memories: [CharacterMemory],
        interactions: [CharacterInteraction],
        limit: Int = extractionReferenceLimit
    ) -> [CharacterMemory] {
        guard !memories.isEmpty else { return [] }
        let tokens = ChatEngine.memoryTokens(from: transcript(for: interactions))
        var result: [CharacterMemory] = []
        var seen = Set<String>()

        func add(_ memory: CharacterMemory) {
            guard result.count < limit, seen.insert(memory.id).inserted else { return }
            result.append(memory)
        }

        let byUpdated = memories.sorted { $0.updatedAt > $1.updatedAt }
        byUpdated.filter { $0.pinned }.forEach(add)
        byUpdated.filter { $0.kind == .important && !$0.pinned }.forEach(add)
        if !tokens.isEmpty {
            byUpdated.filter { matches(memory: $0, tokens: tokens) }.forEach(add)
        }
        byUpdated.forEach(add)
        return result
    }

    /// 生成提取提示词。
    ///
    /// - Returns: `includedCount` 是实际写进提示词的互动条数（受 6000 字预算限制）；
    ///   游标与 `source_message_ids` 只能推进/记录到这一条，否则批尾被截断的消息
    ///   会被误标成已提取。
    static func extractionPrompt(
        conversation: Conversation,
        persona: Persona?,
        existingMemories: [CharacterMemory],
        interactions: [CharacterInteraction],
        memoryLimit: Int,
        now: Date = Date(),
        historyBackfill: Bool = false
    ) -> (system: String, user: String, includedCount: Int) {
        let system = """
        你负责维护一个微信聊天机器人的长期记忆卡。请从下面给出的消息中提取值得长期记住的原子记忆。
        只输出 JSON，不要解释、不要 Markdown 代码围栏。格式：
        {"memories":[{"category":"fact|decision|todo|lesson","content":"...","importance":1-10,"keywords":["..."],"supersedes":["旧记忆 id"]}]}
        规则：
        1. 每个消息行以 `[yyyy-MM-dd HH:mm]` 开头，这是消息的发送时间；「今天/明天/今晚/这周末/下周」
           等相对时间必须按该发送时间理解，不能按当前时间或对话顺序揣测；
        2. 每条 content 必须能独立理解，用中文，不超过 \(memoryContentLimit) 字；
        3. 只记录可核实的信息：用户身份/偏好、约定与决策、未完成待办、互动经验；
        4. 不记录群聊玩笑、临时外号、自称或「某人其实是某人」的玩梗；
        5. 已经过去的事件、已经过期或完成的计划/待办不要再输出为 todo/decision；确有长期价值的
           用 fact 以过去时客观记录（例如「当时约定…」），不要编造日期；
        6. 与已有记忆矛盾时用 supersedes 指向旧 id，不要改写旧记忆；没有矛盾就不填；
        7. 已有未完成待办优先保留；已经完成或过时的待办可以不再输出；
        8. 没有值得记录的内容时返回 {"memories":[]}；每批最多 \(memoryLimit) 条。
        """

        let timestamps = interactions.map(\.timestamp)
        let rangeStart = timestamps.min()
        let rangeEnd = timestamps.max()
        var user = "当前时间：\(Self.promptDateFormatter.string(from: now))\n"
        if let rangeStart, let rangeEnd {
            user += "消息时间范围：\(Self.promptLineDateFormatter.string(from: rangeStart))"
                + " ~ \(Self.promptLineDateFormatter.string(from: rangeEnd))\n"
        }
        if historyBackfill {
            user += "说明：以下消息是记忆卡创建之前的**历史聊天**（一次性补总结），发送时间见每行行首，"
                + "均早于当前时间。请按每条消息的发送时间解析相对时间：已经过去的「今晚/这周末」等"
                + "计划不要输出成当前待办或决定；仍有长期价值的用 fact 以过去时记录。\n"
        }
        if let persona {
            let summary = persona.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
            user += "角色：\(name.isEmpty ? conversation.displayTitle : name)"
            if !summary.isEmpty { user += "（\(summary)）" }
            user += "\n"
        }
        user += "会话：\(conversation.displayTitle)（\(conversation.kind.label)）\n"
        if !existingMemories.isEmpty {
            user += "\n已有记忆（供合并/取代引用，id 是稳定键）：\n"
            for memory in existingMemories.prefix(extractionReferenceLimit) {
                let content = memory.content
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(160)
                user += "- \(memory.id) | \(memory.category.rawValue) | \(content)\n"
            }
        }
        user += "\n对话（\(interactions.count) 条）：\n"
        let transcriptResult = promptTranscript(
            for: interactions, includeTimestamps: true)
        user += transcriptResult.text
        return (system, user, transcriptResult.includedCount)
    }

    private static let promptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        return formatter
    }()

    private static let promptLineDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 提示词里的对话文本。返回实际纳入的互动条数：提示词超预算时只取前缀，
    /// 调用方必须只把前缀记为「已提取」。
    static func promptTranscript(
        for interactions: [CharacterInteraction],
        includeTimestamps: Bool
    ) -> (text: String, includedCount: Int) {
        var lines: [String] = []
        var total = 0
        var included = 0
        for interaction in interactions {
            let content = interaction.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !content.isEmpty else { continue }
            let who = interaction.direction == .outgoing ? "我" : interaction.speakerLabel
            let prefix = includeTimestamps
                ? "[\(Self.promptLineDateFormatter.string(from: interaction.timestamp))] "
                : ""
            let line = "\(prefix)\(who)：\(content)"
            guard total + line.count <= 6_000 else { break }
            lines.append(line)
            total += line.count + 1
            included += 1
        }
        return (lines.joined(separator: "\n"), included)
    }

    static func transcript(for interactions: [CharacterInteraction]) -> String {
        promptTranscript(for: interactions, includeTimestamps: false).text
    }

    /// 解析模型 JSON；非法返回 nil（调用方走本地兜底）。
    static func parseExtraction(_ raw: String) -> [ExtractedMemory]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let rawItems: [Any]
        if let dictionary = object as? [String: Any],
           let items = dictionary["memories"] as? [Any] {
            rawItems = items
        } else if let items = object as? [Any] {
            rawItems = items
        } else {
            return nil
        }
        var result: [ExtractedMemory] = []
        for rawItem in rawItems {
            guard let item = rawItem as? [String: Any] else { continue }
            guard let content = (item["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !content.isEmpty else { continue }
            let category = (item["category"] as? String)
                .flatMap(MemoryCategory.init(rawValue:)) ?? .fact
            let importance = (item["importance"] as? NSNumber)?.doubleValue ?? 3
            let keywords = (item["keywords"] as? [Any])?
                .compactMap { $0 as? String } ?? []
            let supersedes = (item["supersedes"] as? [Any])?
                .compactMap { $0 as? String } ?? []
            result.append(ExtractedMemory(
                category: category,
                content: content,
                importance: importance,
                keywords: keywords,
                supersedes: supersedes
            ))
        }
        return result
    }

    /// 无可用模型时的确定性兜底：把本批互动压成一条事实记忆。
    static func localFallback(
        interactions: [CharacterInteraction],
        characterID: String,
        now: Date
    ) -> ExtractedMemory? {
        let transcriptText = transcript(for: interactions)
        guard !transcriptText.isEmpty else { return nil }
        let compacted = Self.normalizedCompression(transcriptText, limit: 400)
        guard !compacted.isEmpty else { return nil }
        let tokens = ChatEngine.memoryTokens(from: transcriptText)
        return ExtractedMemory(
            category: .fact,
            content: String(compacted.prefix(400)),
            importance: 2,
            keywords: Array(tokens.prefix(2)),
            supersedes: []
        )
    }

    /// 压缩器输出是 `- ` 要点列表；记忆正文用「；」连接的单段，避免提示词里出现嵌套列表。
    private static func normalizedCompression(_ text: String, limit: Int = compressedContentLimit) -> String {
        let compacted = MemorySummaryCompactor.compact(text, maxCharacters: limit)
        let stripped = compacted
            .components(separatedBy: "\n")
            .map { line -> String in
                var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                for prefix in ["- ", "* ", "• ", "· "] where value.hasPrefix(prefix) {
                    value = String(value.dropFirst(prefix.count))
                }
                return value
            }
            .filter { !$0.isEmpty }
            .joined(separator: "；")
        return String(stripped.prefix(limit))
    }

    // MARK: Interaction inputs

    /// 把账号消息转成记忆卡互动记录；语音/图片沿用提示词文本。
    static func interactionInputs(for messages: [ChatMessage]) -> [CharacterInteractionInput] {
        messages.compactMap { message in
            guard message.direction != .system else { return nil }
            let content = ChatEngine.promptText(for: message)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return CharacterInteractionInput(
                messageID: message.id,
                direction: message.direction,
                senderID: message.senderID,
                senderName: message.senderName,
                content: content,
                timestamp: message.timestamp
            )
        }
    }
}

// MARK: - Export

/// 记忆卡导出：Markdown / JSON。
enum CharacterMemoryExporter {
    static let format = "wechatai.character.v1"

    static func markdown(
        snapshot: CharacterSnapshot,
        persona: Persona?,
        settings: MemorySettings = .default,
        now: Date = Date()
    ) -> String {
        let name = (persona?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? snapshot.conversationTitle : name
        var lines: [String] = []
        lines.append("# 角色记忆卡：\(displayName)")
        lines.append("")
        lines.append("- 会话：\(snapshot.conversationTitle)（\(snapshot.conversationKind.label)）")
        lines.append("- 会话 ID：\(snapshot.conversationID)")
        lines.append("- 人设来源：人格设定（\(displayName)）")
        if let model = persona?.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            lines.append("- 模型：\(model)")
        }
        lines.append("- 导出时间：\(Self.dateString(now))")
        lines.append("")

        lines.append("## 人设（人格设定）")
        lines.append("")
        let summary = (persona?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }
        lines.append(persona?.systemPrompt ?? Persona.defaultSystemPrompt)
        lines.append("")

        let active = snapshot.memories.filter {
            !$0.archived && !$0.isSuperseded
        }
        let archived = snapshot.memories.filter { $0.archived }
        let superseded = snapshot.memories.filter { $0.isSuperseded }

        for category in MemoryCategory.displayOrder {
            let items = active
                .filter { $0.category == category }
                .sorted { $0.score(settings: settings) > $1.score(settings: settings) }
            guard !items.isEmpty else { continue }
            lines.append("## \(category.label)（\(items.count) 条）")
            lines.append("")
            for memory in items {
                lines.append("- \(memory.content.replacingOccurrences(of: "\n", with: " "))")
                var meta: [String] = []
                meta.append("重要度 \(Int(memory.importance.rounded()))")
                if memory.pinned { meta.append("置顶") }
                else if memory.kind == .important { meta.append("重要") }
                if memory.mergeCount > 0 { meta.append("合并 \(memory.mergeCount) 次") }
                if memory.accessCount > 0 { meta.append("召回 \(memory.accessCount) 次") }
                meta.append("来源 \(memory.source.label)")
                lines.append("  - \(meta.joined(separator: " · "))")
            }
            lines.append("")
        }

        if !archived.isEmpty {
            lines.append("## 已归档（\(archived.count) 条）")
            lines.append("")
            for memory in archived {
                lines.append("- [\(memory.category.label)] \(memory.content.replacingOccurrences(of: "\n", with: " "))")
            }
            lines.append("")
        }
        if !superseded.isEmpty {
            lines.append("## 已被取代（\(superseded.count) 条）")
            lines.append("")
            for memory in superseded {
                let target = memory.supersededBy ?? ""
                lines.append("- [\(memory.category.label)] \(memory.content.replacingOccurrences(of: "\n", with: " ")) → 被 \(target) 取代")
            }
            lines.append("")
        }

        lines.append("## 全量互动记录（\(snapshot.interactions.count) 条）")
        lines.append("")
        for interaction in snapshot.interactions {
            let content = interaction.content.replacingOccurrences(of: "\n", with: " ")
            lines.append("- \(Self.dateString(interaction.timestamp)) \(interaction.speakerLabel)：\(content)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func json(
        snapshot: CharacterSnapshot,
        persona: Persona?,
        settings: MemorySettings = .default,
        now: Date = Date()
    ) -> String {
        let name = (persona?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var object: [String: Any] = [:]
        object["format"] = format
        object["exportedAt"] = Self.isoString(now)
        object["character"] = [
            "conversationID": snapshot.conversationID,
            "title": snapshot.conversationTitle,
            "kind": snapshot.conversationKind.rawValue,
            "personaID": persona?.id ?? "",
            "name": name.isEmpty ? snapshot.conversationTitle : name,
            "summary": persona?.summary ?? "",
            "model": persona?.model ?? "",
            "systemPrompt": persona?.systemPrompt ?? Persona.defaultSystemPrompt,
            "personaSource": "persona-settings",
        ]
        object["memories"] = snapshot.memories.map { memory -> [String: Any] in
            [
                "id": memory.id,
                "category": memory.category.rawValue,
                "kind": memory.kind.rawValue,
                "content": memory.content,
                "compressedContent": memory.compressedContent ?? "",
                "keywords": memory.keywords,
                "importance": memory.importance,
                "pinned": memory.pinned,
                "archived": memory.archived,
                "supersededBy": memory.supersededBy ?? "",
                "supersedes": memory.supersedes ?? "",
                "supersededAt": memory.supersededAt.map(Self.isoString) ?? "",
                "source": memory.source.rawValue,
                "sourceMessageIDs": memory.sourceMessageIDs,
                "mergeCount": memory.mergeCount,
                "accessCount": memory.accessCount,
                "createdAt": Self.isoString(memory.createdAt),
                "updatedAt": Self.isoString(memory.updatedAt),
                "lastAccessedAt": memory.lastAccessedAt.map(Self.isoString) ?? "",
                "score": memory.score(settings: settings),
            ]
        }
        object["interactions"] = snapshot.interactions.map { interaction -> [String: Any] in
            [
                "messageID": interaction.messageID,
                "direction": interaction.direction.rawValue,
                "senderID": interaction.senderID,
                "senderName": interaction.senderName,
                "content": interaction.content,
                "timestamp": Self.isoString(interaction.timestamp),
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
