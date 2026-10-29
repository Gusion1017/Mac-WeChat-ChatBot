import SQLite3
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

    // MARK: Extraction cursor (same-second batches) / history backfill

    /// 忙群常见：一批互动的 timestamp 完全相同。旧游标只存时间戳时，
    /// `LIMIT 40` 截断后同秒的第 41 条会被永久跳过；复合游标必须能续上。
    func testSameTimestampInteractionsAreNotDroppedAcrossBatches() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation(kind: .group)
        let now = Date()
        let sameSecond = now.addingTimeInterval(-10)
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        let inputs = (0..<41).map { index in
            interaction("batch-\(index)", "同一秒第 \(index) 条", at: sameSecond)
        }
        _ = try await store.upsertInteractions(
            conversationID: conversation.id, records: inputs)
        var settings = AppSettings.default
        settings.bot.memorySettings.extractionBatchSize = 4
        settings.bot.memorySettings.autoArchive = false
        let engine = MemoryEngine(
            characters: store,
            aiClient: AIClient(),
            completion: completion(text: #"{"memories":[]}"#)
        )
        let firstValue = await engine.extractIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now
        )
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.processedInteractions, 40, "单批上限 40；同秒第 41 条应留到下一批")

        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: [
                interaction("new-1", "新消息 1", at: now.addingTimeInterval(1)),
                interaction("new-2", "新消息 2", at: now.addingTimeInterval(2)),
                interaction("new-3", "新消息 3", at: now.addingTimeInterval(3))
            ])
        let secondValue = await engine.extractIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now
        )
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.processedInteractions, 4, "第 41 条同秒消息 + 3 条新消息")
        let pending = try await store.pendingInteractions(
            conversationID: conversation.id, minCount: 1, maxMessages: 40)
        XCTAssertNil(pending, "复合游标推进后不能再有漏网互动")
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    /// 建卡前的群聊历史只回填 `interactions`、默认永不提取；首次维护要补总结一次。
    func testHistoryBackfillSummarizesPreCursorInteractionsOnce() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation(kind: .group, title: "测试群")
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        let old = (0..<5).map { index in
            interaction(
                "old-\(index)",
                "建卡前历史 \(index)",
                at: now.addingTimeInterval(-400 + Double(index))
            )
        }
        _ = try await store.upsertInteractions(conversationID: conversation.id, records: old)
        try await store.markInteractionsBackfilled(conversationID: conversation.id)
        var settings = AppSettings.default
        settings.bot.memorySettings.extractionBatchSize = 2
        settings.bot.memorySettings.autoArchive = false
        let json = """
        {"memories":[{"category":"fact","content":"建卡前的群聊历史被补总结","importance":4,
        "keywords":["历史"],"supersedes":[]}]}
        """
        let engine = MemoryEngine(
            characters: store, aiClient: AIClient(), completion: completion(text: json))

        let before = try await store.pendingInteractions(
            conversationID: conversation.id, minCount: 1, maxMessages: 40)
        XCTAssertNil(before, "建卡前历史默认在提取游标之前")

        let historyValue = await engine.extractHistoryIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now,
            messageLimit: 10
        )
        let result = try XCTUnwrap(historyValue)
        XCTAssertEqual(result.processedInteractions, 5)
        let memories = try await store.fetchMemories(conversationID: conversation.id)
        XCTAssertEqual(
            memories.filter { $0.content == "建卡前的群聊历史被补总结" }.count, 1,
            "多批重复内容应折叠成一条，而不是每批堆一条")
        let after = try await store.pendingInteractions(
            conversationID: conversation.id, minCount: 1, maxMessages: 40)
        XCTAssertNil(after)

        let secondCall = await engine.extractHistoryIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now,
            messageLimit: 10
        )
        XCTAssertNil(secondCall, "历史补总结只允许做一次")
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    /// 历史补总结有上限：只回退最近 `messageLimit` 条，避免一次建卡扫完整 5000 条。
    func testHistoryBackfillOnlyCoversMostRecentLimit() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation(kind: .group)
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        let old = (0..<6).map { index in
            interaction(
                "limit-\(index)",
                "历史 \(index)",
                at: now.addingTimeInterval(-400 + Double(index))
            )
        }
        _ = try await store.upsertInteractions(conversationID: conversation.id, records: old)
        try await store.markInteractionsBackfilled(conversationID: conversation.id)
        var settings = AppSettings.default
        settings.bot.memorySettings.extractionBatchSize = 2
        settings.bot.memorySettings.autoArchive = false
        let engine = MemoryEngine(
            characters: store,
            aiClient: AIClient(),
            completion: completion(text: #"{"memories":[]}"#)
        )
        let historyValue = await engine.extractHistoryIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now,
            messageLimit: 2
        )
        let result = try XCTUnwrap(historyValue)
        XCTAssertEqual(result.processedInteractions, 2, "只补最近 2 条历史")
        let pending = try await store.pendingInteractions(
            conversationID: conversation.id, minCount: 1, maxMessages: 40)
        XCTAssertNil(pending, "更早的历史保持「只存档不提取」")
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    /// 历史补总结按批处理且**不碰普通提取游标**：已经排队的新消息仍在普通队列里。
    func testHistoryBackfillProcessesMultipleBatchesWithoutMovingNormalCursor() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation(kind: .group)
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        let history = (0..<90).map { index in
            interaction(
                "history-\(index)",
                "历史消息 \(index)",
                at: now.addingTimeInterval(-400 + Double(index))
            )
        }
        _ = try await store.upsertInteractions(conversationID: conversation.id, records: history)
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: (0..<3).map { index in
                interaction(
                    "pending-\(index)",
                    "新消息 \(index)",
                    at: now.addingTimeInterval(Double(index) - 10)
                )
            })
        try await store.markInteractionsBackfilled(conversationID: conversation.id)
        var settings = AppSettings.default
        settings.bot.memorySettings.extractionBatchSize = 4
        settings.bot.memorySettings.autoArchive = false

        let counter = CompletionCounter()
        let engine = MemoryEngine(
            characters: store,
            aiClient: AIClient(),
            completion: { _, _, _ in
                await counter.increment()
                return AICompletionResult(
                    text: #"{"memories":[]}"#,
                    model: "fake-model",
                    usage: AIUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2),
                    latencyMs: 1,
                    finishReason: "stop",
                    streamed: false
                )
            }
        )
        let resultValue = await engine.extractHistoryIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now,
            messageLimit: 90
        )
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result.processedInteractions, 90, "90 条历史要跨 3 批补完")
        let callCount = await counter.value
        XCTAssertGreaterThanOrEqual(callCount, 3)

        // 普通队列里的 3 条新消息没有被历史补总结消费，也没被游标跳过。
        let pending = try await store.pendingInteractions(
            conversationID: conversation.id, minCount: 1, maxMessages: 40)
        XCTAssertEqual(pending?.count, 3)
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    /// 空闲兜底允许低于 `extractionBatchSize` 的待提取互动单独提取。
    func testExtractIfNeededCanFlushBelowBatchSize() async throws {
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
            records: (0..<3).map { index in
                interaction(
                    "partial-\(index)",
                    "零散消息 \(index)",
                    at: now.addingTimeInterval(Double(index) - 10)
                )
            })
        var settings = AppSettings.default
        settings.bot.memorySettings.extractionBatchSize = 8
        settings.bot.memorySettings.autoArchive = false
        let engine = MemoryEngine(
            characters: store,
            aiClient: AIClient(),
            completion: completion(text: #"{"memories":[]}"#)
        )
        let normal = await engine.extractIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now
        )
        XCTAssertNil(normal, "不足一批时普通维护不提取")
        let flushedValue = await engine.extractIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now,
            minCount: 3
        )
        let flushed = try XCTUnwrap(flushedValue)
        XCTAssertEqual(flushed.processedInteractions, 3)
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Capture policy

    func testMemoryCapturePolicySkipsSystemOfficialAndAIDisabledConversations() {
        var settings = AppSettings.default
        settings.bot.memorySettings.enabled = true
        XCTAssertTrue(MemoryCapturePolicy.shouldCapture(
            conversation: makeConversation(id: "wxid_friend"), settings: settings))
        XCTAssertTrue(MemoryCapturePolicy.shouldCapture(
            conversation: makeConversation(id: "123456@chatroom", kind: .group),
            settings: settings))

        for systemID in ["filehelper", "notifymessage", "newsapp", "officialaccounts"] {
            XCTAssertFalse(MemoryCapturePolicy.shouldCapture(
                conversation: makeConversation(id: systemID), settings: settings),
                "系统会话不自动建卡：\(systemID)")
        }
        XCTAssertFalse(MemoryCapturePolicy.shouldCapture(
            conversation: makeConversation(id: "gh_abc123", kind: .official),
            settings: settings))
        XCTAssertFalse(MemoryCapturePolicy.shouldCapture(
            conversation: makeConversation(id: "__global__"), settings: settings))

        var aiDisabled = makeConversation(id: "wxid_ai_disabled")
        aiDisabled.aiEnabled = false
        XCTAssertFalse(MemoryCapturePolicy.shouldCapture(
            conversation: aiDisabled, settings: settings))

        settings.bot.memorySettings.enabled = false
        XCTAssertFalse(MemoryCapturePolicy.shouldCapture(
            conversation: makeConversation(id: "wxid_friend"), settings: settings))
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

    // MARK: Historical timestamps / expired plans

    private func lineTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    func testExtractionPromptCarriesMessageTimesAndHistoricalRange() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let start = now.addingTimeInterval(-6 * 86_400)
        let end = start.addingTimeInterval(3_600)
        let interactions = [
            CharacterInteraction(
                id: 1, messageID: "p1", direction: .incoming,
                senderID: "wxid_甲", senderName: "甲", content: "今晚一起吃饭吗",
                timestamp: start, createdAt: start),
            CharacterInteraction(
                id: 2, messageID: "p2", direction: .outgoing,
                senderID: "self", senderName: "我", content: "好",
                timestamp: end, createdAt: end)
        ]
        let prompt = MemoryEngine.extractionPrompt(
            conversation: makeConversation(kind: .group),
            persona: nil,
            existingMemories: [],
            interactions: interactions,
            memoryLimit: 8,
            now: now,
            historyBackfill: true
        )
        XCTAssertEqual(prompt.includedCount, 2)
        XCTAssertTrue(prompt.system.contains("发送时间"), "系统提示必须说明行首时间是消息发送时间")
        XCTAssertTrue(prompt.system.contains("相对时间"))
        XCTAssertTrue(prompt.user.contains("历史聊天"))
        XCTAssertTrue(prompt.user.contains("消息时间范围"))
        XCTAssertTrue(prompt.user.contains(
            "[\(lineTimestamp(start))] 甲：今晚一起吃饭吗"), "每条消息行首必须带发送时间")
        XCTAssertTrue(prompt.user.contains(
            "[\(lineTimestamp(end))] 我：好"))
    }

    /// 历史补总结的记忆时间必须是来源消息时间，不能是「现在」。
    func testHistoryBackfillStoresSourceMessageTimesInsteadOfNow() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation(kind: .group)
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        let historyStart = now.addingTimeInterval(-6 * 86_400)
        let old = (0..<4).map { index in
            interaction(
                "time-\(index)", "历史消息 \(index)",
                at: historyStart.addingTimeInterval(Double(index) * 60))
        }
        _ = try await store.upsertInteractions(conversationID: conversation.id, records: old)
        try await store.markInteractionsBackfilled(conversationID: conversation.id)
        var settings = AppSettings.default
        settings.bot.memorySettings.autoArchive = false
        let json = """
        {"memories":[{"category":"fact","content":"这段历史发生在六天前","importance":4,
        "keywords":["历史"],"supersedes":[]}]}
        """
        let engine = MemoryEngine(
            characters: store, aiClient: AIClient(), completion: completion(text: json))
        let value = await engine.extractHistoryIfNeeded(
            conversation: conversation, provider: fakeProvider(), settings: settings, now: now)
        let result = try XCTUnwrap(value)
        XCTAssertEqual(result.processedInteractions, 4)
        let memories = try await store.fetchMemories(conversationID: conversation.id)
        let memory = try XCTUnwrap(memories.first { $0.content == "这段历史发生在六天前" })
        let newestSource = historyStart.addingTimeInterval(3 * 60)
        XCTAssertEqual(
            memory.updatedAt.timeIntervalSince1970,
            newestSource.timeIntervalSince1970, accuracy: 0.01,
            "历史记忆的 updated_at 必须是最后一条来源消息时间")
        XCTAssertLessThan(memory.createdAt, now.addingTimeInterval(-5 * 86_400),
                          "历史记忆不能被标成「刚刚创建」")
    }

    /// 没有可用 AI 时历史补总结不能落本地兜底并写成「已完成」，AI 恢复后要能续补。
    func testHistoryBackfillRequiresAIAndResumesWhenAvailable() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation(kind: .group)
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: (0..<5).map { index in
                interaction("ai-\(index)", "历史 \(index)",
                            at: now.addingTimeInterval(-500 + Double(index)))
            })
        try await store.markInteractionsBackfilled(conversationID: conversation.id)
        var settings = AppSettings.default
        settings.bot.memorySettings.autoArchive = false

        let noAI = MemoryEngine(characters: store, aiClient: AIClient())
        let skipped = await noAI.extractHistoryIfNeeded(
            conversation: conversation, provider: nil, settings: settings, now: now)
        XCTAssertNil(skipped)
        let afterSkip = try await store.fetchMemories(conversationID: conversation.id)
        XCTAssertTrue(afterSkip.isEmpty, "没有 AI 时不能写本地兜底历史记忆")

        let json = """
        {"memories":[{"category":"fact","content":"AI 恢复后补上的历史","importance":3,
        "keywords":["历史"],"supersedes":[]}]}
        """
        let withAI = MemoryEngine(
            characters: store, aiClient: AIClient(), completion: completion(text: json))
        let resumedValue = await withAI.extractHistoryIfNeeded(
            conversation: conversation, provider: fakeProvider(), settings: settings, now: now)
        let resumed = try XCTUnwrap(resumedValue)
        XCTAssertEqual(resumed.processedInteractions, 5)
        let second = await withAI.extractHistoryIfNeeded(
            conversation: conversation, provider: fakeProvider(), settings: settings, now: now)
        XCTAssertNil(second, "补完一次后不再重复")
    }

    /// 「最近最多 500 条」必须是硬上限：同秒边界消息也不能多补。
    func testHistoryBackfillHonorsLimitWithSameTimestampBoundary() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation(kind: .group)
        let now = Date()
        let sameSecond = now.addingTimeInterval(-1_000)
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-500)
        )
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: (0..<60).map { index in
                interaction("tie-\(index)", "同秒历史 \(index)", at: sameSecond)
            })
        try await store.markInteractionsBackfilled(conversationID: conversation.id)
        var settings = AppSettings.default
        settings.bot.memorySettings.autoArchive = false
        let engine = MemoryEngine(
            characters: store,
            aiClient: AIClient(),
            completion: completion(text: #"{"memories":[]}"#)
        )
        let value = await engine.extractHistoryIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now,
            messageLimit: 40
        )
        let result = try XCTUnwrap(value)
        XCTAssertEqual(result.processedInteractions, 40, "同秒边界也必须严格补 40 条")
        let second = await engine.extractHistoryIfNeeded(
            conversation: conversation,
            provider: fakeProvider(),
            settings: settings,
            now: now,
            messageLimit: 40
        )
        XCTAssertNil(second, "窗口外的更早同秒消息不能继续补")
    }

    /// 历史补总结里的近期 todo（「今晚/这周末」）降级为 fact；普通提取不受影响。
    func testHistoryBackfillDowngradesExpiredNearTermTodo() async throws {
        let json = """
        {"memories":[{"category":"todo","content":"今晚一起吃饭","importance":6,
        "keywords":["吃饭"],"supersedes":[]}]}
        """
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation(kind: .group)
        let now = Date()
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        _ = try await store.upsertInteractions(
            conversationID: conversation.id,
            records: (0..<3).map { index in
                interaction("plan-\(index)", "今晚吃饭 \(index)",
                            at: now.addingTimeInterval(-3 * 86_400 + Double(index)))
            })
        try await store.markInteractionsBackfilled(conversationID: conversation.id)
        var settings = AppSettings.default
        settings.bot.memorySettings.autoArchive = false
        let engine = MemoryEngine(
            characters: store, aiClient: AIClient(), completion: completion(text: json))
        _ = await engine.extractHistoryIfNeeded(
            conversation: conversation, provider: fakeProvider(), settings: settings, now: now)
        let historyMemories = try await store.fetchMemories(conversationID: conversation.id)
        XCTAssertEqual(historyMemories.first?.category, .fact,
                       "历史中的「今晚」计划不能再当待办")

        // 普通实时提取：同样内容保留 todo。
        let liveRoot = makeRoot()
        let liveStore = CharacterStore(rootDirectory: liveRoot)
        let liveConversation = makeConversation()
        try await liveStore.ensureCharacter(
            conversation: liveConversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        _ = try await liveStore.upsertInteractions(
            conversationID: liveConversation.id,
            records: (0..<4).map { index in
                interaction("live-\(index)", "今晚吃饭 \(index)",
                            at: now.addingTimeInterval(-10 + Double(index)))
            })
        var liveSettings = AppSettings.default
        // MemorySettings 的合法范围是 4...20；这里用 4 条互动 + 批量 4 触发一次实时提取。
        liveSettings.bot.memorySettings.extractionBatchSize = 4
        liveSettings.bot.memorySettings.autoArchive = false
        let liveEngine = MemoryEngine(
            characters: liveStore, aiClient: AIClient(), completion: completion(text: json))
        _ = await liveEngine.extractIfNeeded(
            conversation: liveConversation, provider: fakeProvider(),
            settings: liveSettings, now: now)
        let liveMemories = try await liveStore.fetchMemories(
            conversationID: liveConversation.id)
        XCTAssertEqual(liveMemories.first?.category, .todo)

        await store.suspend()
        await liveStore.suspend()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: liveRoot)
    }

    /// 旧逻辑补出来的历史记忆：未编辑的归档待重补；编辑过的修时间并把过期 todo 降级。
    func testHistoricalMemoryRepairArchivesOldUntouchedAndFixesEditedTodo() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversation = makeConversation(kind: .group)
        let now = Date()
        let oldTime = now.addingTimeInterval(-3 * 86_400)
        try await store.ensureCharacter(
            conversation: conversation,
            persona: makePersona(),
            activationTimestamp: now.addingTimeInterval(-100)
        )
        let old = (0..<4).map { index in
            interaction("repair-\(index)", "旧消息 \(index)",
                        at: oldTime.addingTimeInterval(Double(index)))
        }
        _ = try await store.upsertInteractions(conversationID: conversation.id, records: old)
        try await store.markInteractionsBackfilled(conversationID: conversation.id)

        let untouched = CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "旧逻辑补出的历史事实",
            importance: 4,
            source: .extraction,
            sourceMessageIDs: [old[0].messageID, old[1].messageID],
            createdAt: now,
            updatedAt: now
        )
        try await store.upsertMemory(untouched, preserveUpdatedAt: true)
        let edited = CharacterMemory(
            characterID: conversation.id,
            category: .todo,
            content: "今晚一起吃饭",
            importance: 6,
            source: .extraction,
            sourceMessageIDs: [old[3].messageID],
            createdAt: now.addingTimeInterval(-10),
            updatedAt: now
        )
        try await store.upsertMemory(edited, preserveUpdatedAt: true)
        await store.suspend()

        // 模拟旧逻辑：已有完成标记、没有 version=2、没有 repair 标记。
        let databaseURL = root
            .appendingPathComponent(CharacterDirectory.key(for: conversation.id), isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        try rawSQLite(databaseURL, """
        INSERT OR REPLACE INTO meta(key, value) VALUES
            ('history_backfilled_at', '\(now.timeIntervalSince1970)');
        DELETE FROM meta WHERE key IN (
            'history_backfill_version', 'history_memory_repair_v1');
        """)

        let reopened = CharacterStore(rootDirectory: root)
        let repaired = try await reopened.fetchMemories(conversationID: conversation.id)
        let untouchedAfter = try XCTUnwrap(repaired.first { $0.id == untouched.id })
        XCTAssertTrue(untouchedAfter.archived, "未编辑的旧逻辑历史记忆应归档待重补")
        let editedAfter = try XCTUnwrap(repaired.first { $0.id == edited.id })
        XCTAssertEqual(editedAfter.category, .fact, "过期历史 todo 应降级")
        XCTAssertEqual(
            editedAfter.updatedAt.timeIntervalSince1970,
            oldTime.addingTimeInterval(3).timeIntervalSince1970,
            accuracy: 0.01,
            "编辑过的历史记忆时间也要修正为来源消息时间")

        // 完成标记被清掉：新逻辑会重新补总结。
        let engine = MemoryEngine(
            characters: reopened,
            aiClient: AIClient(),
            completion: completion(text: #"{"memories":[]}"#)
        )
        let resumed = await engine.extractHistoryIfNeeded(
            conversation: conversation, provider: fakeProvider(), settings: .default, now: now)
        XCTAssertNotNil(resumed, "旧逻辑归档后应能按新逻辑重补一次")
        await reopened.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    private func rawSQLite(_ url: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        guard let handle else { return }
        defer { sqlite3_close(handle) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            throw NSError(domain: "CharacterMemoryTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

/// 统计假 completion 被调用次数（历史补总结应跨多批调用 AI）。
private actor CompletionCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
