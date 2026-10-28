import XCTest
@testable import WeChatAI

final class CharacterMemoryTests: XCTestCase {
    // MARK: Helpers

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-character-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeConversation(
        id: String = "wxid_test",
        kind: ConversationKind = .direct,
        title: String = "测试会话"
    ) -> Conversation {
        Conversation(id: id, kind: kind, title: title)
    }

    private func makePersona(
        id: String = "persona-a",
        name: String = "小鱼",
        summary: String = "爱吃米饭",
        prompt: String = "你是小鱼，说话简短。"
    ) -> Persona {
        Persona(id: id, name: name, summary: summary, systemPrompt: prompt, isDefault: true)
    }

    private func fakeProvider(kind: ProviderKind = .ollama) -> AIProvider {
        AIProvider(
            id: "fake-provider",
            name: "Fake",
            kind: kind,
            baseURL: "http://127.0.0.1:9/v1",
            model: "fake-model",
            apiKeyReference: "",
            stream: false
        )
    }

    private func completion(text: String) -> MemoryEngine.Completion {
        { _, _, _ in
            AICompletionResult(
                text: text,
                model: "fake-model",
                usage: AIUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2),
                latencyMs: 1,
                finishReason: "stop",
                streamed: false
            )
        }
    }

    private func interaction(
        _ id: String,
        _ text: String,
        at date: Date,
        direction: ChatDirection = .incoming
    ) -> CharacterInteractionInput {
        CharacterInteractionInput(
            messageID: id,
            direction: direction,
            senderID: direction == .incoming ? "wxid_user" : "self",
            senderName: direction == .incoming ? "用户" : "我",
            content: text,
            timestamp: date
        )
    }

    // MARK: Directory key

    func testCharacterDirectoryKeySanitizesAndHashes() {
        XCTAssertEqual(CharacterDirectory.key(for: "wxid_abc"), "c-wxid_abc")
        XCTAssertEqual(CharacterDirectory.key(for: "123@chatroom"), "c-123@chatroom")
        XCTAssertTrue(CharacterDirectory.key(for: "a/b").contains("%2F"))
        XCTAssertEqual(CharacterDirectory.key(for: ""), "c-empty")

        let longID = String(repeating: "群", count: 300)
        let key = CharacterDirectory.key(for: longID)
        XCTAssertLessThanOrEqual(key.count, 164)
        XCTAssertTrue(key.contains("-"))
        XCTAssertEqual(key, CharacterDirectory.key(for: longID))
    }

    // MARK: Persona card

    func testEnsureCharacterCreatesMemoryCardWithoutPersonaCard() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: Date().addingTimeInterval(-10)
        )

        let directory = root.appendingPathComponent(CharacterDirectory.key(for: conversation.id))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("memory.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("persona.md").path),
            "人设来自人格设定，不应再为每个会话复制 persona.md")

        // 新卡默认没有记忆；人格不再生成「起点记忆」。
        let memories = try await store.fetchMemories(conversationID: conversation.id)
        XCTAssertTrue(memories.isEmpty)

        // 再次 ensure 不应重复写入，也不应清掉已有记忆。
        try await store.upsertMemory(CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "用户喜欢猫",
            source: .manual
        ))
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(summary: "爱吃米饭和草莓"))
        let again = try await store.fetchMemories(conversationID: conversation.id)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.content, "用户喜欢猫")
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testMemorySimilarityThresholdAndContainment() {
        XCTAssertEqual(
            MemorySimilarity.score("用户喜欢猫。", "用户喜欢猫"), 1.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            MemorySimilarity.score("用户喜欢猫", "用户喜欢猫和狗"), 0.92)
        XCTAssertGreaterThanOrEqual(
            MemorySimilarity.score(
                "用户喜欢猫，家里养了一只橘猫",
                "用户喜欢猫，家里养了一只橘猫。"), 0.99)
        XCTAssertFalse(MemorySimilarity.isDuplicate(
            "用户喜欢猫", "用户喜欢狗", threshold: 0.92))
        XCTAssertTrue(MemorySimilarity.isDuplicate(
            "用户喜欢猫", "用户喜欢猫和狗", threshold: 0.92))
        XCTAssertEqual(MemorySimilarity.score("", "abc"), 0)
    }

    // MARK: Memory CRUD

    func testMemoryCRUDAndCounts() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        try await store.ensureCharacter(
            conversation: conversation, persona: makePersona())

        var memory = CharacterMemory(
            characterID: conversation.id,
            category: .todo,
            content: "下次提醒用户更新微信版本",
            keywords: ["微信", "版本"],
            importance: 8,
            pinned: true,
            source: .manual
        )
        memory.normalizeKind(threshold: 7)
        XCTAssertEqual(memory.kind, .important)
        try await store.upsertMemory(memory)

        let fetched = try await store.fetchMemories(conversationID: conversation.id)
        XCTAssertTrue(fetched.contains { $0.id == memory.id && $0.kind == .important })

        let summaries = try await store.listCharacters(settings: .default)
        let summary = try XCTUnwrap(summaries.first { $0.conversationID == conversation.id })
        XCTAssertEqual(summary.memoryCount, 1)
        XCTAssertGreaterThanOrEqual(summary.importantCount, 1)
        XCTAssertGreaterThanOrEqual(summary.todoCount, 1)

        try await store.deleteMemory(conversationID: conversation.id, id: memory.id)
        let after = try await store.fetchMemories(conversationID: conversation.id)
        XCTAssertFalse(after.contains { $0.id == memory.id })

        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testWeightDecayRecencyAndPinnedExemption() {
        let settings = MemorySettings.default
        let now = Date()
        let normal = CharacterMemory(
            characterID: "c1",
            category: .fact,
            content: "普通记忆",
            importance: 5,
            source: .extraction,
            createdAt: now.addingTimeInterval(-60 * 86_400),
            updatedAt: now.addingTimeInterval(-60 * 86_400)
        )
        // 60 天 = 2 个普通半衰期 → 0.25。
        XCTAssertEqual(normal.score(now: now, settings: settings), 1.25, accuracy: 0.02)

        var pinned = normal
        pinned.id = UUID().uuidString
        pinned.pinned = true
        pinned.kind = .important
        XCTAssertEqual(pinned.score(now: now, settings: settings), 5, accuracy: 0.02,
                       "置顶记忆不衰减")

        var important = normal
        important.id = UUID().uuidString
        important.kind = .important
        important.updatedAt = now.addingTimeInterval(-180 * 86_400)
        important.createdAt = important.updatedAt
        // 180 天 = 1 个重要半衰期 → 0.5。
        XCTAssertEqual(important.score(now: now, settings: settings), 2.5, accuracy: 0.02)

        var recent = normal
        recent.id = UUID().uuidString
        recent.createdAt = now.addingTimeInterval(-3_600)
        recent.updatedAt = recent.createdAt
        XCTAssertGreaterThan(recent.score(now: now, settings: settings), 5,
                             "72h 内最近记忆应获得加成")
    }

    // MARK: Recall

    func testRecallPrioritizesRecentImportantAndExcludesArchivedSuperseded() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-1_000)
        )

        let recent = CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "用户喜欢猫，家里养了一只橘猫",
            keywords: ["猫"],
            importance: 6,
            source: .extraction,
            createdAt: now.addingTimeInterval(-3_600),
            updatedAt: now.addingTimeInterval(-3_600)
        )
        let pinned = CharacterMemory(
            characterID: conversation.id,
            category: .todo,
            content: "下次提醒用户更新微信版本",
            importance: 4,
            pinned: true,
            source: .manual,
            createdAt: now.addingTimeInterval(-200 * 86_400),
            updatedAt: now.addingTimeInterval(-200 * 86_400)
        )
        let related = CharacterMemory(
            characterID: conversation.id,
            category: .lesson,
            content: "用户发梗图时适合用玩梗风格回复",
            keywords: ["梗图"],
            importance: 5,
            source: .extraction,
            createdAt: now.addingTimeInterval(-100 * 86_400),
            updatedAt: now.addingTimeInterval(-100 * 86_400)
        )
        var archived = CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "已归档的旧事实",
            importance: 3,
            source: .extraction,
            createdAt: now.addingTimeInterval(-300 * 86_400),
            updatedAt: now.addingTimeInterval(-300 * 86_400)
        )
        archived.archived = true
        let superseded = CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "已被取代的旧事实",
            importance: 3,
            source: .extraction,
            createdAt: now.addingTimeInterval(-50 * 86_400),
            updatedAt: now.addingTimeInterval(-50 * 86_400)
        )
        var replacement = CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "取代后的新事实",
            importance: 4,
            source: .extraction,
            createdAt: now.addingTimeInterval(-10 * 86_400),
            updatedAt: now.addingTimeInterval(-10 * 86_400)
        )
        replacement.supersedes = superseded.id
        var oldSuperseded = superseded
        oldSuperseded.supersededBy = replacement.id
        oldSuperseded.supersededAt = now

        for memory in [recent, pinned, related, archived, oldSuperseded, replacement] {
            try await store.upsertMemory(memory)
        }

        let engine = MemoryEngine(characters: store, aiClient: AIClient())
        let recall = await engine.recall(
            conversationID: conversation.id,
            query: "你记得我喜欢猫吗，还有梗图",
            settings: .default,
            now: now
        )
        XCTAssertTrue(recall.memories.contains { $0.id == recent.id })
        XCTAssertTrue(recall.memories.contains { $0.id == pinned.id })
        XCTAssertTrue(recall.memories.contains { $0.id == related.id })
        XCTAssertFalse(recall.memories.contains { $0.id == archived.id })
        XCTAssertFalse(recall.memories.contains { $0.id == oldSuperseded.id })
        XCTAssertTrue(recall.memories.contains { $0.id == replacement.id })
        XCTAssertFalse(recall.memories.contains { $0.kind == .normal && $0.content == "已归档的旧事实" })
        XCTAssertNotNil(recall.prompt)

        let updated = try await store.fetchMemories(conversationID: conversation.id)
        let accessed = try XCTUnwrap(updated.first { $0.id == recent.id })
        XCTAssertGreaterThan(accessed.accessCount, 0)
        XCTAssertNotNil(accessed.lastAccessedAt)

        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testRecallTokenBudgetTrimsLongMemories() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation, persona: makePersona(), activationTimestamp: now)
        for index in 0..<6 {
            let memory = CharacterMemory(
                characterID: conversation.id,
                category: .fact,
                content: String(repeating: "很长的记忆内容\(index)。", count: 40),
                importance: 6,
                source: .extraction,
                createdAt: now.addingTimeInterval(-Double(index) * 3_600),
                updatedAt: now.addingTimeInterval(-Double(index) * 3_600)
            )
            try await store.upsertMemory(memory)
        }
        var settings = MemorySettings.default
        settings.maxRecallCharacters = 300
        let engine = MemoryEngine(characters: store, aiClient: AIClient())
        let recall = await engine.recall(
            conversationID: conversation.id, query: "记忆", settings: settings, now: now)
        XCTAssertGreaterThan(recall.omittedCount, 0)
        XCTAssertLessThanOrEqual(recall.prompt?.count ?? 0, 300 + 120)
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Extraction

    func testExtractionAddsMergesSupersedesAndAdvancesCursor() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        let old = CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "用户喜欢狗",
            importance: 3,
            source: .manual,
            createdAt: now.addingTimeInterval(-50),
            updatedAt: now.addingTimeInterval(-50)
        )
        try await store.upsertMemory(old)

        let inputs = [
            interaction("m1", "其实我不喜欢狗", at: now.addingTimeInterval(-40)),
            interaction("m2", "我喜欢猫", at: now.addingTimeInterval(-30)),
            interaction("m3", "周末去杭州吧", at: now.addingTimeInterval(-20)),
            interaction("m4", "好啊，那就定了", at: now.addingTimeInterval(-10), direction: .outgoing)
        ]
        _ = try await store.upsertInteractions(conversationID: conversation.id, records: inputs)

        let json = """
        {"memories":[
          {"category":"fact","content":"用户喜欢猫","importance":6,"keywords":["猫"],"supersedes":[]},
          {"category":"todo","content":"下次提醒用户更新微信版本","importance":8,"keywords":["微信"],"supersedes":[]},
          {"category":"decision","content":"周末去杭州","importance":5,"keywords":["杭州"],"supersedes":["\(old.id)"]}
        ]}
        """
        var settings = AppSettings.default
        settings.bot.memorySettings.extractionBatchSize = 4
        settings.bot.memorySettings.autoArchive = false
        let engine = MemoryEngine(
            characters: store,
            aiClient: AIClient(),
            completion: completion(text: json)
        )
        let extraction = await engine.extractIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now
        )
        let result = try XCTUnwrap(extraction)
        XCTAssertEqual(result.processedInteractions, 4)
        XCTAssertEqual(result.added, 3)
        XCTAssertEqual(result.superseded, 1)
        XCTAssertGreaterThanOrEqual(result.merged, 0)

        let memories = try await store.fetchMemories(conversationID: conversation.id)
        let updatedOld = try XCTUnwrap(memories.first { $0.id == old.id })
        XCTAssertNotNil(updatedOld.supersededBy)
        let newDecision = try XCTUnwrap(memories.first { $0.content == "周末去杭州" })
        XCTAssertEqual(updatedOld.supersededBy, newDecision.id)
        XCTAssertTrue(newDecision.supersedes?.contains(old.id) == true)
        XCTAssertTrue(memories.contains { $0.category == .todo && $0.importance == 8 })

        // 游标推进后，不足一批不触发。
        let pendingAfterExtraction = try await store.pendingInteractions(
            conversationID: conversation.id, minCount: 4, maxMessages: 40)
        XCTAssertNil(pendingAfterExtraction)
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: [interaction("m5", "再来一条", at: now.addingTimeInterval(1))])
        let pendingAfterOneMore = try await store.pendingInteractions(
            conversationID: conversation.id, minCount: 4, maxMessages: 40)
        XCTAssertNil(pendingAfterOneMore)

        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testExtractionMergesSimilarMemoryAndKeepsManualSource() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        let manual = CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "用户喜欢猫",
            importance: 3,
            source: .manual,
            createdAt: now.addingTimeInterval(-50),
            updatedAt: now.addingTimeInterval(-50)
        )
        try await store.upsertMemory(manual)
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: (0..<4).map { index in
                interaction("g\(index)", "我喜欢猫 \(index)", at: now.addingTimeInterval(Double(index) - 10))
            })
        let json = """
        {"memories":[{"category":"fact","content":"用户喜欢猫。","importance":7,
        "keywords":["猫"],"supersedes":[]}]}
        """
        var settings = AppSettings.default
        settings.bot.memorySettings.extractionBatchSize = 4
        settings.bot.memorySettings.autoArchive = false
        let engine = MemoryEngine(
            characters: store, aiClient: AIClient(), completion: completion(text: json))
        let extraction = await engine.extractIfNeeded(
            conversation: conversation, provider: fakeProvider(), settings: settings, now: now)
        let result = try XCTUnwrap(extraction)
        XCTAssertEqual(result.merged, 1)
        XCTAssertEqual(result.added, 0)
        let memories = try await store.fetchMemories(conversationID: conversation.id)
        let merged = try XCTUnwrap(memories.first { $0.id == manual.id })
        XCTAssertEqual(merged.mergeCount, 1)
        XCTAssertEqual(merged.importance, 7, accuracy: 0.001)
        XCTAssertEqual(merged.source, .manual)
        XCTAssertEqual(merged.kind, .important)
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testExtractionFallbackWhenProviderHasNoCredential() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        let inputs = (0..<4).map { index in
            interaction(
                "f\(index)",
                "第 \(index) 条测试互动，记录一些内容",
                at: now.addingTimeInterval(Double(index) - 10)
            )
        }
        _ = try await store.upsertInteractions(conversationID: conversation.id, records: inputs)
        var settings = AppSettings.default
        settings.bot.memorySettings.extractionBatchSize = 4
        settings.bot.memorySettings.autoArchive = false
        let engine = MemoryEngine(characters: store, aiClient: AIClient())
        let extraction = await engine.extractIfNeeded(
            conversation: conversation,
            provider: fakeProvider(kind: .deepSeek),
            settings: settings,
            now: now
        )
        let result = try XCTUnwrap(extraction)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.processedInteractions, 4)
        let memories = try await store.fetchMemories(conversationID: conversation.id)
        XCTAssertTrue(memories.contains { $0.source == .extraction && $0.category == .fact })
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testExtractionParserToleratesCodeFenceAndRejectsGarbage() {
        let fenced = """
        ```json
        {"memories":[{"category":"todo","content":"提醒更新","importance":8,
        "keywords":["更新"],"supersedes":[]}]}
        ```
        """
        let parsed = MemoryEngine.parseExtraction(fenced)
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?.first?.category, .todo)
        XCTAssertEqual(parsed?.first?.importance, 8)
        XCTAssertEqual(MemoryEngine.parseExtraction("{\"memories\":[]}")?.count, 0)
        XCTAssertNil(MemoryEngine.parseExtraction("这不是 JSON"))
        XCTAssertNil(MemoryEngine.parseExtraction("{\"foo\":1}"))
    }

    // MARK: Archive

    func testArchiveStaleOnlyArchivesOldLowUsageNormalMemories() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation, persona: makePersona(), activationTimestamp: now)

        // 用旧记忆导入路径写入真实的旧时间戳（普通 upsert 会把 updated_at 刷新为 now）。
        var legacy = LongTermMemory(
            conversationID: conversation.id,
            summary: String(repeating: "旧记忆", count: 120),
            isCore: false,
            source: "summary"
        )
        legacy.createdAt = now.addingTimeInterval(-120 * 86_400)
        legacy.updatedAt = legacy.createdAt
        legacy.lastAccessedAt = now.addingTimeInterval(-100 * 86_400)
        try await store.importLegacyMemories(
            conversationID: conversation.id, memories: [legacy])
        let importedMemories = try await store.fetchMemories(conversationID: conversation.id)
        let imported = try XCTUnwrap(importedMemories.first { $0.source == .legacyImport })

        var pinned = imported
        pinned.id = UUID().uuidString
        pinned.kind = .important
        pinned.pinned = true
        try await store.upsertMemory(pinned)
        var recent = imported
        recent.id = UUID().uuidString
        recent.content = "最近更新过的事实"
        try await store.upsertMemory(recent)

        var settings = MemorySettings.default
        settings.archiveAfterDays = 90
        let engine = MemoryEngine(characters: store, aiClient: AIClient())
        let count = try await engine.archiveStale(
            conversationID: conversation.id, settings: settings, now: now)
        XCTAssertEqual(count, 1)
        let memories = try await store.fetchMemories(conversationID: conversation.id)
        XCTAssertTrue(memories.first { $0.id == imported.id }?.archived == true)
        XCTAssertFalse(memories.first { $0.id == pinned.id }?.archived == true)
        XCTAssertFalse(memories.first { $0.id == recent.id }?.archived == true)
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testCompressStoresPromptVersionAndKeepsOriginal() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        try await store.ensureCharacter(
            conversation: conversation, persona: makePersona())
        let longContent = String(repeating: "这是一条很长的记忆内容，需要压缩后放进提示词。", count: 20)
        let memory = CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: longContent,
            importance: 5,
            source: .manual
        )
        try await store.upsertMemory(memory)
        let engine = MemoryEngine(characters: store, aiClient: AIClient())
        let compressed = await engine.compress(
            memory: memory, provider: nil, settings: .default)
        XCTAssertNotNil(compressed?.compressedContent)
        XCTAssertLessThanOrEqual(compressed?.compressedContent?.count ?? 0, 180)
        let fetched = try await store.fetchMemories(conversationID: conversation.id)
            .first { $0.id == memory.id }
        XCTAssertEqual(fetched?.compressedContent, compressed?.compressedContent)
        XCTAssertEqual(fetched?.content, longContent, "压缩不能改原文")
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Interactions / full archive

    func testInteractionsUpsertDedupeAndPendingThreshold() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: [interaction("m1", "第一版", at: now.addingTimeInterval(-50))])
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: [interaction("m1", "第二版", at: now.addingTimeInterval(-50))])
        let rows = try await store.fetchInteractions(conversationID: conversation.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.content, "第二版")
        let pendingOne = try await store.pendingInteractions(
            conversationID: conversation.id, minCount: 2, maxMessages: 40)
        XCTAssertNil(pendingOne)
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: [interaction("m2", "第二条", at: now.addingTimeInterval(-40))])
        let pending = try await store.pendingInteractions(
            conversationID: conversation.id, minCount: 2, maxMessages: 40)
        XCTAssertEqual(pending?.count, 2)
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Legacy import

    func testLegacyImportSplitsBulletsAndPreservesCoreAsPinned() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        try await store.ensureCharacter(
            conversation: conversation, persona: makePersona())
        let legacy = LongTermMemory(
            conversationID: conversation.id,
            summary: "- 用户喜欢猫\n- 下次提醒用户更新微信版本",
            isCore: true,
            source: "manual"
        )
        let imported = try await store.importLegacyMemories(
            conversationID: conversation.id, memories: [legacy])
        XCTAssertEqual(imported, 2)
        let memories = try await store.fetchMemories(conversationID: conversation.id)
        let todo = memories.first { $0.category == .todo }
        XCTAssertNotNil(todo)
        XCTAssertTrue(todo?.pinned == true)
        XCTAssertTrue(memories.filter { $0.source == .legacyImport }.count >= 2)
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Account switch

    func testCharacterStoreSuspendActivateSwitchesRoots() async throws {
        let rootA = makeRoot()
        let rootB = makeRoot()
        let store = CharacterStore(rootDirectory: rootA)
        let conversationA = makeConversation(id: "wxid_account_a")
        try await store.ensureCharacter(
            conversation: conversationA, persona: makePersona())
        let hasA1 = await store.hasCharacter(conversationID: conversationA.id)
        XCTAssertTrue(hasA1)

        await store.suspend()
        try await store.activate(rootDirectory: rootB)
        let hasAInB = await store.hasCharacter(conversationID: conversationA.id)
        XCTAssertFalse(hasAInB)
        let conversationB = makeConversation(id: "wxid_account_b")
        try await store.ensureCharacter(
            conversation: conversationB, persona: makePersona())
        let hasB = await store.hasCharacter(conversationID: conversationB.id)
        XCTAssertTrue(hasB)

        await store.suspend()
        try await store.activate(rootDirectory: rootA)
        let hasAAgain = await store.hasCharacter(conversationID: conversationA.id)
        let hasBInA = await store.hasCharacter(conversationID: conversationB.id)
        XCTAssertTrue(hasAAgain)
        XCTAssertFalse(hasBInA)
        await store.suspend()
        try? FileManager.default.removeItem(at: rootA)
        try? FileManager.default.removeItem(at: rootB)
    }

    func testExtractionEmptyResultStillAdvancesCursor() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: (0..<4).map { index in
                interaction("e\(index)", "闲聊 \(index)", at: now.addingTimeInterval(Double(index) - 10))
            })
        var settings = AppSettings.default
        settings.bot.memorySettings.extractionBatchSize = 4
        settings.bot.memorySettings.autoArchive = false
        let engine = MemoryEngine(
            characters: store,
            aiClient: AIClient(),
            completion: completion(text: "{\"memories\":[]}")
        )
        let extraction = await engine.extractIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now
        )
        let result = try XCTUnwrap(extraction)
        XCTAssertEqual(result.processedInteractions, 4)
        XCTAssertEqual(result.added, 0)
        let pending = try await store.pendingInteractions(
            conversationID: conversation.id, minCount: 4, maxMessages: 40)
        XCTAssertNil(pending)
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testPinnedMemoryIsNeverAutoSuperseded() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        let pinned = CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "固定角色设定",
            importance: 10,
            pinned: true,
            source: .manual
        )
        try await store.upsertMemory(pinned)
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: (0..<4).map { index in
                interaction("o\(index)", "互动 \(index)", at: now.addingTimeInterval(Double(index) - 10))
            })
        let json = """
        {"memories":[{"category":"fact","content":"新的角色设定","importance":6,
        "keywords":[],"supersedes":["\(pinned.id)"]}]}
        """
        var settings = AppSettings.default
        settings.bot.memorySettings.extractionBatchSize = 4
        settings.bot.memorySettings.autoArchive = false
        let engine = MemoryEngine(
            characters: store,
            aiClient: AIClient(),
            completion: completion(text: json)
        )
        let extraction = await engine.extractIfNeeded(
            conversation: conversation, provider: fakeProvider(), settings: settings, now: now)
        let result = try XCTUnwrap(extraction)
        XCTAssertEqual(result.superseded, 0)
        let memories = try await store.fetchMemories(conversationID: conversation.id)
        let pinnedAfter = try XCTUnwrap(memories.first { $0.id == pinned.id })
        XCTAssertNil(pinnedAfter.supersededBy)
        XCTAssertTrue(memories.contains { $0.content == "新的角色设定" })
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testMemoryStoreFetchMessagesForMemorySkipsSystemAndRawJSON() async throws {
        let directory = makeRoot()
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        let now = Date()
        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "会话"))
        try await store.upsertMessages([
            ChatMessage(
                id: "m1", conversationID: "c1", senderID: "u1", senderName: "用户",
                direction: .incoming, text: "你好", timestamp: now, rawJSON: "{\"big\":true}"),
            ChatMessage(
                id: "m2", conversationID: "c1", senderID: "self", senderName: "我",
                direction: .outgoing, text: "在", timestamp: now.addingTimeInterval(1)),
            ChatMessage(
                id: "m3", conversationID: "c1", senderID: "system", senderName: "系统",
                direction: .system, text: "系统消息", timestamp: now.addingTimeInterval(2)),
        ])
        let messages = try await store.fetchMessagesForMemory(conversationID: "c1")
        XCTAssertEqual(messages.map(\.id), ["m1", "m2"])
        XCTAssertNil(messages.first?.rawJSON)
        XCTAssertEqual(messages.first?.text, "你好")
        let incremental = try await store.fetchMessagesForMemory(
            conversationID: "c1", after: now.addingTimeInterval(0.5))
        XCTAssertEqual(incremental.map(\.id), ["m2"])
        await store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func testInteractionSyncCursorPersists() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        try await store.ensureCharacter(
            conversation: conversation, persona: makePersona())
        let first = try await store.lastInteractionSyncedAt(conversationID: conversation.id)
        XCTAssertNil(first)
        try await store.markInteractionsSynced(
            conversationID: conversation.id, through: Date(timeIntervalSince1970: 100))
        var saved = try await store.lastInteractionSyncedAt(conversationID: conversation.id)
        XCTAssertEqual(saved?.timeIntervalSince1970 ?? 0, 100, accuracy: 0.01)
        // 游标只前进，不回退。
        try await store.markInteractionsSynced(
            conversationID: conversation.id, through: Date(timeIntervalSince1970: 50))
        saved = try await store.lastInteractionSyncedAt(conversationID: conversation.id)
        XCTAssertEqual(saved?.timeIntervalSince1970 ?? 0, 100, accuracy: 0.01)
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Settings

    func testMemorySettingsDecodesOldConfigAndClamps() throws {
        let data = #"{"enabled":false,"extractionBatchSize":999,"mergeSimilarity":0.5}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MemorySettings.self, from: data)
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.extractionBatchSize, MemorySettings.extractionBatchRange.upperBound)
        XCTAssertEqual(decoded.mergeSimilarity, MemorySettings.mergeSimilarityRange.lowerBound,
                       accuracy: 0.0001)
        XCTAssertEqual(decoded.recentWindowHours, MemorySettings.default.recentWindowHours)

        let empty = try JSONDecoder().decode(MemorySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, MemorySettings.default)
    }

    // MARK: Export

    func testGlobalCharacterIsListedSeparately() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        try await store.ensureCharacter(conversation: conversation, persona: makePersona())
        try await store.ensureGlobalCharacter()

        let summaries = try await store.listCharacters(settings: .default)
        let global = try XCTUnwrap(summaries.first { $0.isGlobal })
        XCTAssertEqual(global.conversationID, CharacterStore.globalConversationID)
        XCTAssertEqual(global.title, CharacterStore.globalTitle)
        XCTAssertTrue(global.memoryCount == 0)
        XCTAssertFalse(global.directoryPath.isEmpty)
        let regular = try XCTUnwrap(summaries.first { !$0.isGlobal })
        XCTAssertEqual(regular.conversationID, conversation.id)

        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testGlobalMemoryIsInjectedIntoConversationRecall() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        try await store.ensureCharacter(conversation: conversation, persona: makePersona())
        try await store.ensureGlobalCharacter()
        try await store.upsertMemory(CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "用户喜欢猫",
            keywords: ["猫"],
            importance: 6,
            source: .manual
        ))
        try await store.upsertMemory(CharacterMemory(
            characterID: CharacterStore.globalConversationID,
            category: .fact,
            content: "用户是素食者",
            keywords: ["素食"],
            importance: 8,
            pinned: true,
            source: .manual
        ))

        let engine = MemoryEngine(characters: store, aiClient: AIClient())
        let recall = await engine.recall(
            conversationID: conversation.id,
            query: "用户喜欢吃什么",
            settings: .default,
            recordAccess: false
        )
        XCTAssertTrue(recall.memories.contains { $0.content == "用户喜欢猫" })
        XCTAssertTrue(recall.memories.contains {
            $0.content == "用户是素食者"
                && $0.characterID == CharacterStore.globalConversationID
        })
        let prompt = try XCTUnwrap(recall.prompt)
        XCTAssertTrue(prompt.contains("全局"))
        XCTAssertTrue(prompt.contains("用户是素食者"))

        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    func testExportMarkdownAndJSONContainCardAndArchive() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation()
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        try await store.upsertMemory(CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "用户喜欢猫",
            keywords: ["猫"],
            importance: 6,
            source: .extraction
        ))
        var archived = CharacterMemory(
            characterID: conversation.id,
            category: .lesson,
            content: "归档经验",
            importance: 3,
            source: .extraction
        )
        archived.archived = true
        try await store.upsertMemory(archived)
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: [interaction("m1", "你好", at: now.addingTimeInterval(-50))])

        let snapshotValue = try await store.snapshot(conversationID: conversation.id)
        let snapshot = try XCTUnwrap(snapshotValue)
        let persona = makePersona()
        let markdown = CharacterMemoryExporter.markdown(snapshot: snapshot, persona: persona)
        XCTAssertTrue(markdown.contains("# 角色记忆卡"))
        XCTAssertTrue(markdown.contains("## 人设（人格设定）"))
        XCTAssertTrue(markdown.contains("## 事实"))
        XCTAssertTrue(markdown.contains("## 已归档"))
        XCTAssertTrue(markdown.contains("## 全量互动记录"))
        XCTAssertTrue(markdown.contains("你好"))

        let json = CharacterMemoryExporter.json(snapshot: snapshot, persona: persona)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, CharacterMemoryExporter.format)
        XCTAssertNotNil(object["character"] as? [String: Any])
        XCTAssertEqual((object["memories"] as? [Any])?.count, snapshot.memories.count)
        XCTAssertEqual((object["interactions"] as? [Any])?.count, 1)

        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }
}
