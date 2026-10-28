import Foundation

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
    func extractIfNeeded(
        conversation: Conversation,
        provider: AIProvider?,
        settings: AppSettings,
        now: Date = Date()
    ) async -> MemoryMaintenanceResult? {
        let memorySettings = settings.bot.memorySettings
        guard memorySettings.enabled, !Task.isCancelled else { return nil }
        guard let interactions = try? await characters.pendingInteractions(
            conversationID: conversation.id,
            minCount: memorySettings.extractionBatchSize,
            maxMessages: Self.maxExtractionBatch
        ), !interactions.isEmpty else {
            return nil
        }

        var result = MemoryMaintenanceResult(characterID: conversation.id)
        result.processedInteractions = interactions.count
        var persisted = true

        let allExisting = (try? await characters.fetchMemories(conversationID: conversation.id))?
            .filter { !$0.archived && !$0.isSuperseded } ?? []
        // 交给模型的参考记忆：置顶/重要优先，再补本批关键词命中的，最后按更新补齐。
        let reference = Self.referenceMemories(allExisting, interactions: interactions)

        var extracted: [ExtractedMemory]?
        var usedFallback = false
        if let provider, aiClient.hasCredential(for: provider) {
            do {
                let prompt = Self.extractionPrompt(
                    conversation: conversation,
                    persona: settings.persona(
                        id: conversation.personaID ?? settings.bot.defaultPersonaID),
                    existingMemories: reference,
                    interactions: interactions,
                    memoryLimit: Self.maxExtractedMemories
                )
                var requestProvider = provider
                requestProvider.stream = false
                requestProvider.maxTokens = max(provider.maxTokens, 2_000)
                let response = try await completion(
                    [.system(prompt.system), .user(prompt.user)],
                    requestProvider,
                    0.2
                )
                extracted = Self.parseExtraction(response.text)
                if extracted == nil {
                    onLog?(.warning, "记忆提取返回无法解析，改用本地兜底（\(conversation.displayTitle)）")
                }
            } catch {
                onLog?(.warning, "记忆提取失败，改用本地兜底：\(error.localizedDescription)")
            }
        }

        // 停止机器人/切号会取消维护任务：取消后不再写库，避免停止后仍落盘。
        guard !Task.isCancelled else { return nil }
        let effective = extracted ?? []
        if extracted == nil {
            usedFallback = true
            let fallback = Self.localFallback(
                interactions: interactions,
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
                    sourceMessageIDs: interactions.map(\.messageID),
                    now: now
                )
            }
        } else {
            persisted = await persist(
                candidates: effective,
                result: &result,
                existing: allExisting,
                conversationID: conversation.id,
                settings: memorySettings,
                sourceMessageIDs: interactions.map(\.messageID),
                now: now
            )
        }
        result.usedFallback = usedFallback

        // 只有成功处理（含空结果/本地兜底）且落库成功才推进游标；
        // 失败时不推进，下批重试会走相似度折叠，不会重复堆积。
        if persisted, let lastTimestamp = interactions.map(\.timestamp).max() {
            try? await characters.markExtracted(
                conversationID: conversation.id, through: lastTimestamp)
        } else if !persisted {
            onLog?(.warning, "记忆写入失败，保留提取游标等待重试（\(conversation.displayTitle)）")
            return result
        }

        if memorySettings.autoArchive {
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

    /// 把提取结果落库：同类别相似度 ≥ 阈值折叠；supersede 双方留档。
    private func persist(
        candidates: [ExtractedMemory],
        result: inout MemoryMaintenanceResult,
        existing: [CharacterMemory],
        conversationID: String,
        settings: MemorySettings,
        sourceMessageIDs: [String],
        now: Date
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
                createdAt: now,
                updatedAt: now
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
                merged.updatedAt = now
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
                    target.supersededAt = now
                    working[index] = target
                    do {
                        try await characters.upsertMemory(target, now: now)
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
                try await characters.upsertMemory(stored, now: now)
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

    static func extractionPrompt(
        conversation: Conversation,
        persona: Persona?,
        existingMemories: [CharacterMemory],
        interactions: [CharacterInteraction],
        memoryLimit: Int
    ) -> (system: String, user: String) {
        let system = """
        你负责维护一个微信聊天机器人的长期记忆卡。请从下面的新对话中提取值得长期记住的原子记忆。
        只输出 JSON，不要解释、不要 Markdown 代码围栏。格式：
        {"memories":[{"category":"fact|decision|todo|lesson","content":"...","importance":1-10,"keywords":["..."],"supersedes":["旧记忆 id"]}]}
        规则：
        1. 每条 content 必须能独立理解，用中文，不超过 \(memoryContentLimit) 字；
        2. 只记录可核实的信息：用户身份/偏好、约定与决策、未完成待办、互动经验；
        3. 不记录群聊玩笑、临时外号、自称或「某人其实是某人」的玩梗；
        4. 与已有记忆矛盾时用 supersedes 指向旧 id，不要改写旧记忆；没有矛盾就不填；
        5. 已有未完成待办优先保留；已经完成或过时的待办可以不再输出；
        6. 没有值得记录的内容时返回 {"memories":[]}；每批最多 \(memoryLimit) 条。
        """

        var user = "当前时间：\(Self.promptDateFormatter.string(from: Date()))\n"
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
        user += "\n新对话（\(interactions.count) 条）：\n"
        user += transcript(for: interactions)
        return (system, user)
    }

    private static let promptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        return formatter
    }()

    static func transcript(for interactions: [CharacterInteraction]) -> String {
        var lines: [String] = []
        var total = 0
        for interaction in interactions {
            let content = interaction.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !content.isEmpty else { continue }
            let who: String
            if interaction.direction == .outgoing {
                who = "我"
            } else {
                who = interaction.speakerLabel
            }
            let line = "\(who)：\(content)"
            guard total + line.count <= 6_000 else { break }
            lines.append(line)
            total += line.count + 1
        }
        return lines.joined(separator: "\n")
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
