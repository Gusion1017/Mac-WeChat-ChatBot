import AppKit
import SQLite3
import XCTest
@testable import WeChatAI

final class CoreServicesTests: XCTestCase {
    // MARK: MemoryStore

    func testMemoryStoreRoundtripAndPagination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-tests-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "测试"))
        let now = Date()
        var messages: [ChatMessage] = []
        for index in 0..<4 {
            messages.append(ChatMessage(
                id: "m\(index)",
                conversationID: "c1",
                senderID: "u1",
                senderName: "用户",
                direction: .incoming,
                text: index == 1 ? "hello deepseek" : "msg \(index)",
                timestamp: now.addingTimeInterval(Double(index))
            ))
        }
        try await store.upsertMessages(messages)
        let page = try await store.fetchMessages(conversationID: "c1", limit: 2)
        XCTAssertEqual(page.map(\.id), ["m2", "m3"])
        let older = try await store.fetchMessages(conversationID: "c1", limit: 2, before: now.addingTimeInterval(2))
        XCTAssertEqual(older.map(\.id), ["m0", "m1"])
        let hits = try await store.searchMessages(query: "deepseek")
        XCTAssertEqual(hits.first?.message.id, "m1")
        try await store.setSetting(key: "k", value: "v")
        let value = try await store.setting(key: "k")
        XCTAssertEqual(value, "v")
        await store.close()
    }

    func testLongTermMemoryWeightCoreAndPromptSelection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-memory-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "小林"))
        let now = Date()
        let old = LongTermMemory(
            conversationID: "c1",
            summary: "旧记忆",
            createdAt: now.addingTimeInterval(-60 * 86_400),
            updatedAt: now.addingTimeInterval(-60 * 86_400)
        )
        let recent = LongTermMemory(
            conversationID: "c1",
            summary: "新记忆",
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-86_400)
        )
        let core = LongTermMemory(
            conversationID: "",
            summary: "核心设定：用户叫小林",
            isCore: true,
            createdAt: now.addingTimeInterval(-100 * 86_400),
            updatedAt: now.addingTimeInterval(-100 * 86_400)
        )
        try await store.upsertMemory(old)
        try await store.upsertMemory(recent)
        try await store.upsertMemory(core)

        // 新公式在合并条数/召回次数为 0 时退化为纯 30 天半衰期。
        XCTAssertEqual(old.importanceFactor, 1.0, accuracy: 0.000001)
        XCTAssertEqual(old.usageFactor, 1.0, accuracy: 0.000001)
        XCTAssertEqual(old.timeWeight(now: now), 0.25, accuracy: 0.001, "60 天应衰减到 0.25")
        XCTAssertGreaterThan(recent.timeWeight(now: now), old.timeWeight(now: now))

        let all = try await store.fetchMemories()
        XCTAssertEqual(all.first?.summary, "核心设定：用户叫小林", "核心记忆应排在最前")

        let prompt = try await store.fetchMemoriesForPrompt(conversationID: "c1", limit: 6, now: now)
        XCTAssertEqual(prompt.count, 3)
        XCTAssertEqual(prompt.first?.isCore, true)
        XCTAssertEqual(Set(prompt.map(\.summary)), Set(["旧记忆", "新记忆", "核心设定：用户叫小林"]))
        let search = try await store.fetchMemories(search: "新记忆")
        XCTAssertEqual(search.map(\.summary), ["新记忆"])
    }

    func testLongTermMemoryAccessCountBoostsWeightAndPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-access-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "小林"))
        let now = Date()
        let memory = LongTermMemory(
            conversationID: "c1",
            summary: "常用记忆：对方喜欢猫",
            createdAt: now.addingTimeInterval(-60 * 86_400),
            updatedAt: now.addingTimeInterval(-60 * 86_400),
            sourceCount: 4
        )
        try await store.upsertMemory(memory)
        let cold = memory.timeWeight(now: now)

        // 使用强化：每次召回 +2%，最多 +40%。
        var boosted = memory
        boosted.accessCount = 10
        XCTAssertEqual(boosted.usageFactor, 1.2, accuracy: 0.000001)
        var capped = memory
        capped.accessCount = 50
        XCTAssertEqual(capped.usageFactor, 1.4, accuracy: 0.000001, "使用强化上限 +40%")

        // 召回两次：access_count 累加、last_accessed_at 刷新、衰减锚点前移。
        try await store.recordMemoryAccess(ids: [memory.id], at: now.addingTimeInterval(-2 * 86_400))
        try await store.recordMemoryAccess(ids: [memory.id], at: now.addingTimeInterval(-86_400))
        var fetched = try await store.fetchMemories()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].accessCount, 2)
        XCTAssertEqual(
            fetched[0].lastAccessedAt?.timeIntervalSince1970 ?? -1,
            now.addingTimeInterval(-86_400).timeIntervalSince1970,
            accuracy: 0.001
        )
        // 衰减锚点从 60 天前前移到 1 天前，权重回升；使用强化额外 +2%。
        let expected = memory.importanceFactor * 1.04 * pow(0.5, 1.0 / 30.0)
        XCTAssertEqual(fetched[0].timeWeight(now: now), expected, accuracy: 0.01)
        XCTAssertGreaterThan(fetched[0].timeWeight(now: now), cold,
                             "召回后衰减锚点前移，权重应提升")

        // accessCount 随 upsert 持久化。
        var edited = fetched[0]
        edited.accessCount = 7
        try await store.upsertMemory(edited)
        fetched = try await store.fetchMemories()
        XCTAssertEqual(fetched.first?.accessCount, 7)
    }

    func testSourceCountImportanceIsLogarithmicAndBounded() {
        func importance(_ sourceCount: Int) -> Double {
            LongTermMemory(conversationID: "", summary: "x", sourceCount: sourceCount).importanceFactor
        }
        XCTAssertEqual(importance(0), 1.0, accuracy: 0.000001)
        XCTAssertEqual(importance(3), 1 + 0.12 * log2(4), accuracy: 0.000001)
        XCTAssertGreaterThan(importance(20), importance(3))
        XCTAssertLessThan(importance(1_000), 2.25, "现实合并条数范围内重要度约 1~2.2")
        // 对数增长：每翻一倍的增量收敛且始终小于 0.12。
        XCTAssertLessThan(importance(2_000) - importance(1_000), 0.12)
        XCTAssertGreaterThan(importance(2_000) - importance(1_000), 0.1)
        XCTAssertGreaterThan(importance(10_000), importance(1_000))
        XCTAssertLessThan(importance(10_000), 3.0)
    }

    func testMemorySummaryCompactorDedupesAndLimitsLength() {
        let input = """
        - 用户叫小林

        • 用户叫小林
        *  用户   叫小林
        1. 用户喜欢猫
        用户喜欢猫
        """
        let compacted = MemorySummaryCompactor.compact(input)
        let lines = compacted.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2, "应忽略空行、重复行与空白/大小写差异：\(compacted)")
        XCTAssertTrue(compacted.contains("用户叫小林"))
        XCTAssertTrue(compacted.contains("用户喜欢猫"))
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("- ") }, "输出按行组织为要点")
        XCTAssertEqual(MemorySummaryCompactor.compact("  \n\t\n"), "")

        let caseVariants = "Hello World\nhello   world\nHELLO WORLD"
        XCTAssertEqual(MemorySummaryCompactor.compact(caseVariants).components(separatedBy: "\n").count, 1)

        // 超长输入：保留尾部最新内容并强制 <= 600 字符。
        let long = (0..<400)
            .map { "第\($0)条：用户偏好与约定细节 \($0)" }
            .joined(separator: "\n")
        let limited = MemorySummaryCompactor.compact(long)
        XCTAssertLessThanOrEqual(limited.count, 600)
        XCTAssertTrue(limited.contains("早期细节已压缩"))
        XCTAssertTrue(limited.contains("399"), "应保留尾部最新内容")

        // 单行超长也强制限长。
        let single = String(repeating: "很长的记忆内容", count: 500)
        XCTAssertLessThanOrEqual(MemorySummaryCompactor.compact(single, maxCharacters: 600).count, 600)
        XCTAssertTrue(ChatEngine.localSummary(existing: nil, transcript: single).count <= 600)
    }

    func testMemoryOverflowCursorRespectsBatchThreshold() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-overflow-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "测试"))
        let now = Date()
        func makeMessages(_ range: Range<Int>) -> [ChatMessage] {
            range.map { index in
                ChatMessage(
                    id: "m\(index)",
                    conversationID: "c1",
                    senderID: index.isMultiple(of: 2) ? "u1" : "self",
                    senderName: index.isMultiple(of: 2) ? "用户" : "我",
                    direction: index.isMultiple(of: 2) ? .incoming : .outgoing,
                    text: "消息 \(index)",
                    timestamp: now.addingTimeInterval(Double(index))
                )
            }
        }
        try await store.upsertMessages(makeMessages(0..<12))

        // 默认 minOverflow = 1：窗口外有 2 条就会报告（手动/兼容行为）。
        let first = try await store.pendingMemoryOverflow(conversationID: "c1", keep: 10)
        XCTAssertEqual(first?.messages.map(\.id), ["m0", "m1"])
        XCTAssertNotNil(first?.lastRowID)

        // 未攒够批量阈值时返回 nil（12 条不总结）。
        let belowThreshold = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 20,
            maxMessages: 40
        )
        XCTAssertNil(belowThreshold)

        // 30 条时一次返回 20 条（m0...m19）。
        try await store.upsertMessages(makeMessages(12..<30))
        let batch = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 20,
            maxMessages: 40
        )
        XCTAssertEqual(batch?.messages.count, 20)
        XCTAssertEqual(batch?.messages.first?.id, "m0")
        XCTAssertEqual(batch?.messages.last?.id, "m19")
        try await store.markMemorySummarized(conversationID: "c1", throughRowID: batch?.lastRowID ?? 0)
        let afterFirstBatch = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 20,
            maxMessages: 40
        )
        XCTAssertNil(afterFirstBatch)

        // 50 条时再返回下一批 20 条（m20...m39），游标继续前移。
        try await store.upsertMessages(makeMessages(30..<50))
        let second = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 20,
            maxMessages: 40
        )
        XCTAssertEqual(second?.messages.count, 20)
        XCTAssertEqual(second?.messages.first?.id, "m20")
        XCTAssertEqual(second?.messages.last?.id, "m39")

        // 单批最多 maxMessages 条：70 条时窗口外共 50 条，但只取 40 条。
        try await store.upsertMessages(makeMessages(50..<70))
        let capped = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 20,
            maxMessages: 40
        )
        XCTAssertEqual(capped?.messages.count, 40, "单批上限 maxOverflowBatch")
    }

    func testChatEngineShortTermWindowIsTenMessages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-window-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        var settings = AppSettings.default
        settings.bot.maxContextMessages = 50
        let conversation = Conversation(id: "c1", kind: .direct, title: "测试")
        let history = (0..<20).map { index in
            ChatMessage(
                id: "h\(index)",
                conversationID: "c1",
                senderID: index.isMultiple(of: 2) ? "u1" : "self",
                senderName: index.isMultiple(of: 2) ? "用户" : "我",
                direction: index.isMultiple(of: 2) ? .incoming : .outgoing,
                text: "历史 \(index)",
                timestamp: Date().addingTimeInterval(Double(index))
            )
        }
        let incoming = ChatMessage(
            id: "incoming",
            conversationID: "c1",
            senderID: "u1",
            senderName: "用户",
            direction: .incoming,
            text: "最新消息",
            timestamp: Date().addingTimeInterval(100)
        )
        let engine = ChatEngine(memory: store, aiClient: AIClient())
        let messages = engine.buildMessages(
            conversation: conversation,
            incoming: incoming,
            settings: settings,
            persona: nil,
            history: history,
            memoryNotes: nil
        )
        XCTAssertEqual(ChatEngine.shortTermMemoryLimit, 10)
        XCTAssertEqual(messages.first?.role, .system)
        let body = messages.dropFirst().map(\.content).joined(separator: "\n")
        XCTAssertFalse(body.contains("历史 9"), "只应包含最近 10 条历史")
        XCTAssertTrue(body.contains("历史 10"))
        XCTAssertTrue(body.contains("最新消息"))
    }

    func testChatEnginePromptComesFromPersona() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-prompt-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings.default
        let conversation = Conversation(id: "c1", kind: .direct, title: "测试")
        let incoming = ChatMessage(
            id: "incoming",
            conversationID: "c1",
            senderID: "u1",
            senderName: "用户",
            direction: .incoming,
            text: "你好",
            timestamp: Date()
        )
        let engine = ChatEngine(memory: store, aiClient: AIClient())

        let persona = Persona(name: "测试人格", summary: "", systemPrompt: "人格专属提示词")
        let withPersona = engine.buildMessages(
            conversation: conversation,
            incoming: incoming,
            settings: settings,
            persona: persona,
            history: [],
            memoryNotes: nil
        )
        XCTAssertTrue(withPersona.first?.content.contains("人格专属提示词") ?? false)

        let withoutPersona = engine.buildMessages(
            conversation: conversation,
            incoming: incoming,
            settings: settings,
            persona: nil,
            history: [],
            memoryNotes: nil
        )
        XCTAssertTrue(withoutPersona.first?.content.contains(Persona.defaultSystemPrompt) ?? false,
                      "没有人格时应回退到内置默认提示词")
    }

    func testSummarizeOverflowBatchesTwentyMessagesAndKeepsOneAutoMemory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-summary-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        let conversation = Conversation(id: "c1", kind: .direct, title: "测试")
        try await store.upsertConversation(conversation)
        let now = Date()
        func makeMessages(_ range: Range<Int>) -> [ChatMessage] {
            range.map { index in
                ChatMessage(
                    id: "m\(index)",
                    conversationID: "c1",
                    senderID: index.isMultiple(of: 2) ? "u1" : "self",
                    senderName: index.isMultiple(of: 2) ? "用户" : "我",
                    direction: index.isMultiple(of: 2) ? .incoming : .outgoing,
                    text: "消息 \(index)",
                    timestamp: now.addingTimeInterval(Double(index))
                )
            }
        }
        XCTAssertEqual(ChatEngine.shortTermMemoryLimit, 10)
        XCTAssertEqual(ChatEngine.overflowBatchThreshold, 20)
        XCTAssertEqual(ChatEngine.maxOverflowBatch, 40)
        XCTAssertEqual(ChatEngine.summaryCharacterLimit, 600)

        let engine = ChatEngine(memory: store, aiClient: AIClient())
        try await store.upsertMessages(makeMessages(0..<12))
        let firstCount = await engine.summarizeOverflow(
            conversation: conversation,
            provider: nil,
            settings: .default
        )
        XCTAssertEqual(firstCount, 0, "12 条未攒够 20 条，不应总结")
        var memories = try await store.fetchMemories()
        XCTAssertTrue(memories.isEmpty, "未达阈值时不应创建长期记忆")

        // 30 条：一次总结最早的 20 条。
        try await store.upsertMessages(makeMessages(12..<30))
        let secondCount = await engine.summarizeOverflow(
            conversation: conversation,
            provider: nil,
            settings: .default
        )
        XCTAssertEqual(secondCount, 20, "30 条时一次总结 20 条")
        memories = try await store.fetchMemories()
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories[0].source, "summary")
        XCTAssertEqual(memories[0].sourceCount, 20)
        XCTAssertTrue(memories[0].summary.contains("消息 0"))
        XCTAssertTrue(memories[0].summary.contains("消息 19"))
        XCTAssertLessThanOrEqual(memories[0].summary.count, ChatEngine.summaryCharacterLimit)
        var autos = try await store.autoMemories(conversationID: "c1")
        XCTAssertEqual(autos.count, 1)
        let pendingAfterFirst = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 20,
            maxMessages: 40
        )
        XCTAssertNil(pendingAfterFirst, "总结后剩余 10 条在短期窗口内")

        // 50 条：再总结下一批 20 条，自动记忆仍是一条。
        try await store.upsertMessages(makeMessages(30..<50))
        let thirdCount = await engine.summarizeOverflow(
            conversation: conversation,
            provider: nil,
            settings: .default
        )
        XCTAssertEqual(thirdCount, 20, "50 条时再总结 20 条")
        memories = try await store.fetchMemories()
        XCTAssertEqual(memories.count, 1, "自动总结应滚动更新同一条长期记忆")
        XCTAssertEqual(memories[0].sourceCount, 40)
        XCTAssertTrue(memories[0].summary.contains("消息 20"))
        XCTAssertTrue(memories[0].summary.contains("消息 39"))
        XCTAssertLessThanOrEqual(memories[0].summary.count, ChatEngine.summaryCharacterLimit)
        autos = try await store.autoMemories(conversationID: "c1")
        XCTAssertEqual(autos.count, 1)
    }

    func testSummarizeOverflowMergesDuplicateAutoMemories() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-duplicates-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        let conversation = Conversation(id: "c1", kind: .direct, title: "测试")
        try await store.upsertConversation(conversation)
        let now = Date()

        // 模拟旧版本留下的两条自动总结（同一会话）。
        let older = LongTermMemory(
            conversationID: "c1",
            summary: "旧自动记忆：用户喜欢猫",
            createdAt: now.addingTimeInterval(-10 * 86_400),
            updatedAt: now.addingTimeInterval(-10 * 86_400),
            sourceCount: 5
        )
        let newer = LongTermMemory(
            conversationID: "c1",
            summary: "用户住在杭州",
            createdAt: now.addingTimeInterval(-5 * 86_400),
            updatedAt: now.addingTimeInterval(-5 * 86_400),
            sourceCount: 7
        )
        try await store.upsertMemory(older)
        try await store.upsertMemory(newer)
        let before = try await store.autoMemories(conversationID: "c1")
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before.first?.summary, "用户住在杭州", "autoMemories 按 updated_at 降序")

        // 攒够 20 条后触发总结：先合并历史多条，再滚动合并本批。
        try await store.upsertMessages((0..<30).map { index in
            ChatMessage(
                id: "m\(index)",
                conversationID: "c1",
                senderID: index.isMultiple(of: 2) ? "u1" : "self",
                senderName: index.isMultiple(of: 2) ? "用户" : "我",
                direction: index.isMultiple(of: 2) ? .incoming : .outgoing,
                text: "消息 \(index)",
                timestamp: now.addingTimeInterval(Double(index))
            )
        })
        let engine = ChatEngine(memory: store, aiClient: AIClient())
        let count = await engine.summarizeOverflow(
            conversation: conversation,
            provider: nil,
            settings: .default
        )
        XCTAssertEqual(count, 20)

        let after = try await store.autoMemories(conversationID: "c1")
        XCTAssertEqual(after.count, 1, "同一会话只保留一条自动记忆")
        XCTAssertEqual(after[0].sourceCount, 5 + 7 + 20, "合并时累加 sourceCount")
        XCTAssertTrue(after[0].summary.contains("猫"))
        XCTAssertTrue(after[0].summary.contains("杭州"))
        XCTAssertTrue(after[0].summary.contains("消息 0"))
        let allMemories = try await store.fetchMemories()
        XCTAssertEqual(allMemories.count, 1, "重复的自动记忆应被删除")
    }

    func testLegacyDatabaseMigrationAddsAccessCount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chatbot.sqlite")
        let now = Date().timeIntervalSince1970

        // 旧结构（user_version = 2，memories 无 access_count）。
        try executeSQL(at: file, statements: [
            """
            CREATE TABLE memories (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL DEFAULT '',
                summary TEXT NOT NULL,
                is_core INTEGER NOT NULL DEFAULT 0,
                base_weight REAL NOT NULL DEFAULT 1.0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_accessed_at REAL,
                source_count INTEGER NOT NULL DEFAULT 0,
                source TEXT NOT NULL DEFAULT 'summary'
            );
            """,
            """
            INSERT INTO memories (id, conversation_id, summary, is_core, base_weight,
                                  created_at, updated_at, last_accessed_at, source_count, source)
            VALUES ('legacy-1', 'c1', '旧记忆', 0, 1.0, \(now), \(now), NULL, 7, 'summary');
            """,
            "PRAGMA user_version=2;"
        ])

        let store = MemoryStore(databaseURL: file)
        try await store.open()
        var memories = try await store.fetchMemories()
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories[0].summary, "旧记忆")
        XCTAssertEqual(memories[0].sourceCount, 7)
        XCTAssertEqual(memories[0].accessCount, 0, "迁移补列默认 0")

        memories[0].accessCount = 5
        try await store.upsertMemory(memories[0])
        memories = try await store.fetchMemories()
        XCTAssertEqual(memories.first?.accessCount, 5, "新列可正常读写")
        await store.close()
        XCTAssertEqual(try readUserVersion(at: file), 4, "迁移后 user_version 应为 4")
    }

    func testGlobalStreamToggleOverridesProviderStream() {
        var settings = AppSettings.default
        settings.ai.streamReplies = true
        XCTAssertNil(ChatEngine.forceStream(for: settings), "总开关开启时按各 provider 的 stream 设置")
        settings.ai.streamReplies = false
        XCTAssertEqual(ChatEngine.forceStream(for: settings), false, "关闭时所有通道强制非流式")
    }

    // MARK: SQLite helpers (legacy DB fixtures)

    private func executeSQL(at url: URL, statements: [String]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "CoreServicesTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建旧版数据库"])
        }
        defer { sqlite3_close_v2(handle) }
        for statement in statements {
            var error: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(handle, statement, nil, nil, &error)
            guard status == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "sqlite error \(status)"
                sqlite3_free(error)
                throw NSError(domain: "CoreServicesTests", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }

    private func readUserVersion(at url: URL) throws -> Int32 {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "CoreServicesTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法打开数据库"])
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    // MARK: OneBot parsing

    func testOneBotEventParsing() {
        let json = """
        {"self_id":"self","user_id":"u1","group_id":"g1@chatroom",
         "sender":{"user_id":"u1","nickname":"小明"},"time":1760000000,
         "message_id":"m1","message":[{"type":"text","data":{"text":"hi"}},
         {"type":"at","data":{"qq":"self"}}],"raw_message":"hi","message_type":"group"}
        """
        let events = OneBotEventParser.parse(data: Data(json.utf8))
        XCTAssertEqual(events.count, 1)
        let event = try? XCTUnwrap(events.first)
        XCTAssertEqual(event?.conversationID, "g1@chatroom")
        XCTAssertEqual(event?.conversationKind, .group)
        XCTAssertEqual(event?.senderName, "小明")
        XCTAssertTrue(event?.mentions.contains("self") == true)
        XCTAssertEqual(event?.plainText, "hi @self")
        XCTAssertTrue(OneBotEventParser.parse(data: Data("nope".utf8)).isEmpty)
    }

    // MARK: OneBot event parsing

    func testGroupPatEventWithGroupAsSelfIdIsIncoming() throws {
        // 4.1.15 拍一拍事件里 from/to 都是群 ID；不能把它当成自己发出的消息。
        let groupID = "00000000000@chatroom"
        let raw: [String: Any] = [
            "self_id": groupID,
            "user_id": groupID,
            "group_id": groupID,
            "sender": ["user_id": groupID, "nickname": groupID],
            "message_type": "group",
            "message": [["type": "text", "data": ["text": "\"张三\" 拍了拍 \"测试机器人\""]]],
            "raw_message": "<msg><appmsg><type>62</type><title>\"张三\" 拍了拍 \"测试机器人\"</title></appmsg></msg>",
            "time": 1_760_000_000
        ]
        let event = try XCTUnwrap(OneBotEventParser.parseEvent(raw, rawText: nil))
        XCTAssertFalse(event.isSelf, "群系统消息不应被识别为自己发出")
        XCTAssertEqual(event.groupID, groupID)
    }

    func testMentionsFieldFallback() throws {
        // 4.1.15 的 @ 消息：hook 从 <atuserlist> 解析出 mentions，即使没有 at 段也要生效。
        let raw: [String: Any] = [
            "self_id": "wxid_bot",
            "user_id": "wxid_sender",
            "group_id": "g1@chatroom",
            "sender": ["user_id": "wxid_sender", "nickname": "小明"],
            "message_type": "group",
            "message": [["type": "text", "data": ["text": "@测试机器人"]],
                        ["type": "at", "data": ["qq": "wxid_bot"]]],
            "mentions": ["wxid_bot"],
            "time": 1_760_000_000
        ]
        let event = try XCTUnwrap(OneBotEventParser.parseEvent(raw, rawText: nil))
        XCTAssertTrue(event.mentions.contains("wxid_bot"))

        var settings = AppSettings.default
        settings.bot.groupTriggers = [.mention]
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        let conversation = Conversation(id: "g1@chatroom", kind: .group, title: "测试群")
        let message = ChatMessage(
            id: "m1", conversationID: conversation.id, senderID: "wxid_sender",
            senderName: "小明", direction: .incoming, text: "@测试机器人",
            timestamp: Date(), rawJSON: event.rawJSON
        )
        let context = RuleEngine.Context(
            conversation: conversation, message: message, settings: settings,
            selfID: "wxid_bot"
        )
        XCTAssertTrue(RuleEngine().evaluate(context).shouldReply)
    }

    // MARK: @ 文本回退（无 at 段 / 手动输入）

    func testMentionTextExtractsNamesInOrder() {
        XCTAssertEqual(MentionText.names(in: "@机器人 你好"), ["机器人"])
        XCTAssertEqual(MentionText.names(in: "@机器人\u{2005}你好 @小明 早"), ["机器人", "小明"])
        XCTAssertTrue(MentionText.names(in: "没有 at 的消息").isEmpty)
    }

    func testMentionTextDisplayNameMatchesSelfTarget() {
        // 结构化 at 段命中机器人时，文本中对应的昵称可以被学习。
        XCTAssertEqual(
            MentionText.displayName(in: "@测试机器人\u{2005}你好", selfID: "wxid_bot",
                                    mentions: ["wxid_bot"]),
            "测试机器人"
        )
        // 多个 @ 时按正文顺序对位。
        XCTAssertEqual(
            MentionText.displayName(in: "@群友 早 @测试机器人\u{2005}你好", selfID: "wxid_bot",
                                    mentions: ["wxid_other", "wxid_bot"]),
            "测试机器人"
        )
        // 无法对位时不学习，避免把别人的昵称当成机器人。
        XCTAssertNil(MentionText.displayName(in: "@甲 早 @乙 早", selfID: "wxid_bot",
                                             mentions: ["wxid_other"]))
        // wxid 本身不作为展示昵称。
        XCTAssertNil(MentionText.displayName(in: "@wxid_bot\u{2005}你好", selfID: "wxid_bot",
                                             mentions: ["wxid_bot"]))
    }

    func testLearnedGroupNameTriggersPlainTextMention() {
        // 回归：部分客户端/手动输入的 @ 只带正文，不带 at 段/atuserlist；
        // 学到群昵称后应能命中「群聊·@」，且不能误伤近似昵称或别人的 @。
        var settings = AppSettings.default
        settings.bot.groupTriggers = [.mention]
        settings.bot.keywords = []
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        settings.bot.selfMentionNames = ["g1@chatroom": "测试机器人"]
        let conversation = Conversation(id: "g1@chatroom", kind: .group, title: "测试群")
        let engine = RuleEngine()

        func context(_ text: String) -> RuleEngine.Context {
            let message = ChatMessage(
                id: UUID().uuidString, conversationID: conversation.id, senderID: "u1",
                senderName: "群友", direction: .incoming, text: text, timestamp: Date()
            )
            return RuleEngine.Context(
                conversation: conversation, message: message, settings: settings,
                selfID: "wxid_bot"
            )
        }

        XCTAssertTrue(engine.evaluate(context("@测试机器人\u{2005}是谁把你玩坏了？")).shouldReply)
        XCTAssertTrue(engine.evaluate(context("@测试机器人 在吗")).shouldReply)
        // 昵称是前缀时不能误命中更长的昵称。
        XCTAssertFalse(engine.evaluate(context("@测试机器人2 在吗")).shouldReply)
        // 只 @ 别人不应触发。
        XCTAssertFalse(engine.evaluate(context("@别人 在吗")).shouldReply)
        // 其他群没有学到的昵称也不应跨群生效。
        let otherGroup = Conversation(id: "g2@chatroom", kind: .group, title: "另一个群")
        let message = ChatMessage(
            id: "m-other", conversationID: otherGroup.id, senderID: "u1",
            senderName: "群友", direction: .incoming, text: "@测试机器人 在吗", timestamp: Date()
        )
        XCTAssertFalse(engine.evaluate(RuleEngine.Context(
            conversation: otherGroup, message: message, settings: settings,
            selfID: "wxid_bot"
        )).shouldReply)
    }

    // MARK: RuleEngine

    func testRuleEngineBlacklistAndCooldown() {
        var settings = AppSettings.default
        settings.bot.enabled = true
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        let conversation = Conversation(id: "c1", kind: .direct, title: "测试")
        let message = ChatMessage(id: "m", conversationID: "c1", senderID: "u1", senderName: "用户",
                                  direction: .incoming, text: "你好", timestamp: Date())
        let engine = RuleEngine()
        let context = RuleEngine.Context(conversation: conversation, message: message,
                                         settings: settings, selfID: "self")
        XCTAssertTrue(engine.evaluate(context).shouldReply)

        settings.bot.blacklistConversations = ["c1"]
        let blacklisted = RuleEngine.Context(conversation: conversation, message: message,
                                             settings: settings, selfID: "self")
        XCTAssertFalse(engine.evaluate(blacklisted).shouldReply)
        settings.bot.blacklistConversations = []

        settings.bot.cooldownSeconds = 60
        let cooldownContext = RuleEngine.Context(conversation: conversation, message: message,
                                                 settings: settings, selfID: "self")
        XCTAssertTrue(engine.evaluate(cooldownContext).shouldReply)
        engine.noteReply(conversationID: "c1")
        XCTAssertFalse(engine.evaluate(cooldownContext).shouldReply)
    }

    func testRuleEngineIgnoresLegacyMuteFlag() {
        // 免打扰设置已从产品移除：旧的 isMuted=true 数据不应再阻止自动回复。
        var settings = AppSettings.default
        settings.bot.enabled = true
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        var conversation = Conversation(id: "c-mute", kind: .direct, title: "旧静音会话")
        conversation.isMuted = true
        let message = ChatMessage(
            id: "m-mute", conversationID: conversation.id, senderID: "u1", senderName: "用户",
            direction: .incoming, text: "你好", timestamp: Date()
        )
        let context = RuleEngine.Context(conversation: conversation, message: message,
                                         settings: settings, selfID: "self")
        XCTAssertTrue(RuleEngine().evaluate(context).shouldReply)
    }

    func testUnifiedAllowAndDenyLists() {
        var settings = AppSettings.default
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        let engine = RuleEngine()
        let conversation = Conversation(id: "c1", kind: .direct, title: "会话")

        func context(conversation: Conversation, senderID: String = "u1") -> RuleEngine.Context {
            let message = ChatMessage(
                id: UUID().uuidString, conversationID: conversation.id, senderID: senderID,
                senderName: senderID, direction: .incoming, text: "你好", timestamp: Date()
            )
            return RuleEngine.Context(
                conversation: conversation, message: message, settings: settings,
                selfID: "self"
            )
        }

        // 会话白名单：只允许该会话。
        settings.bot.whitelistEntries = ["c1"]
        XCTAssertTrue(engine.evaluate(context(conversation: conversation)).shouldReply)
        let other = Conversation(id: "c2", kind: .direct, title: "其他")
        XCTAssertFalse(engine.evaluate(context(conversation: other)).shouldReply)

        // 用户白名单：允许该发送者进入其它会话。
        settings.bot.whitelistEntries = ["u1"]
        XCTAssertTrue(engine.evaluate(context(conversation: other)).shouldReply)
        XCTAssertFalse(engine.evaluate(context(conversation: other, senderID: "u2")).shouldReply)

        // 黑名单用户优先于会话白名单。
        settings.bot.whitelistEntries = ["c1"]
        settings.bot.blacklistEntries = ["u1"]
        XCTAssertFalse(engine.evaluate(context(conversation: conversation)).shouldReply)

        // 黑名单会话即使发送者在白名单也拒绝。
        settings.bot.whitelistEntries = ["u1"]
        settings.bot.blacklistEntries = ["c2"]
        XCTAssertFalse(engine.evaluate(context(conversation: other)).shouldReply)

        // 旧版四列表在未迁移时合并回退。
        settings.bot.whitelistEntries = nil
        settings.bot.blacklistEntries = nil
        settings.bot.whitelistConversations = ["c1"]
        settings.bot.whitelistUsers = ["u1"]
        settings.bot.blacklistConversations = ["c2"]
        settings.bot.blacklistUsers = ["u2"]
        XCTAssertEqual(settings.bot.effectiveWhitelist, ["c1", "u1"])
        XCTAssertEqual(settings.bot.effectiveBlacklist, ["c2", "u2"])
    }

    // MARK: Scheduler

    func testSchedulerNextFireDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 19
        components.hour = 12; components.minute = 0
        let fireAt = calendar.date(from: components)!

        let daily = ScheduledTask(name: "daily", conversationID: "c1", content: "x",
                                  repeatRule: .daily, fireAt: fireAt)
        let nextDaily = SchedulerService.nextFireDate(for: daily, after: fireAt.addingTimeInterval(3600),
                                                       calendar: calendar)
        XCTAssertEqual(nextDaily, fireAt.addingTimeInterval(86_400))

        let once = ScheduledTask(name: "once", conversationID: "c1", content: "x",
                                 repeatRule: .once, fireAt: fireAt)
        XCTAssertNil(SchedulerService.nextFireDate(for: once, after: fireAt.addingTimeInterval(1),
                                                    calendar: calendar))
    }

    // MARK: ChatEngine shaping

    func testChatEngineSplitAndTokens() {
        var humanize = HumanizeSettings()
        humanize.maxSegments = 3
        let segments = ChatEngine.splitReply("你好。今天过得怎么样？周末去看电影吧！", humanize: humanize)
        XCTAssertFalse(segments.isEmpty)
        XCTAssertLessThanOrEqual(segments.count, 3)
        let tokens = ChatEngine.memoryTokens(from: "请问DeepSeek的API怎么配置？")
        XCTAssertTrue(tokens.contains("DeepSeek"))
        let merged = ChatEngine.mergeAdjacentRoles([.user("a"), .user("b"), .assistant("c")])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].content, "a\nb")
    }

    // MARK: Settings persistence

    func testSettingsPersistenceAtomicWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-settings-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("config.json")
        let persistence = SettingsPersistence(fileURL: file)
        var settings = AppSettings.default
        settings.providers[0].apiKeyReference = "provider-deepseek-default"
        let wrote = try await persistence.save(settings)
        XCTAssertTrue(wrote)
        let data = try Data(contentsOf: file)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.providers.first?.apiKeyReference, "provider-deepseek-default")
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("sk-"))
        let wroteAgain = try await persistence.save(settings)
        XCTAssertFalse(wroteAgain)
        try? FileManager.default.removeItem(at: directory)
    }

    func testLegacyConfigWithGlobalSystemPromptStillDecodes() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var bot = try XCTUnwrap(root["bot"] as? [String: Any])
        XCTAssertNil(bot["systemPrompt"], "新配置不应再写入全局系统提示词")
        bot["systemPrompt"] = "旧的全局提示词"
        root["bot"] = bot
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded.bot, AppSettings.default.bot)
        XCTAssertEqual(decoded.personas, AppSettings.default.personas)
        XCTAssertEqual(decoded.personas.first?.systemPrompt, Persona.defaultSystemPrompt)
    }

    // MARK: ProcessRunner (crash regression: cancellation must not read terminationStatus early)

    func testProcessRunnerCollectsOutputAndStatus() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "process"]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("hello process"), "stdout=\(result.stdout)")
    }

    func testProcessRunnerCancellationDoesNotCrash() async throws {
        // A long-running child: if cancellation reads `terminationStatus` while the task
        // is still alive, Foundation raises NSInvalidArgumentException and kills the test host.
        let handle = ProcessRunner.launch(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"]
        )
        let consumer = Task { () -> Bool in
            do {
                for try await _ in handle.events {}
                return true
            } catch {
                return true
            }
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        consumer.cancel()

        // Bounded wait using only `isRunning` (safe to query). Never read terminationStatus
        // here; the stream reports it through `.terminated` after Process has exited.
        let deadline = Date().addingTimeInterval(5)
        while handle.process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(handle.process.isRunning, "cancelling the stream must terminate the child process")

        let consumerFinished: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await consumer.result
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return !Task.isCancelled ? false : true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            // If the first result was the watchdog (false), the consumer is still hung.
            return first
        }
        XCTAssertTrue(consumerFinished, "cancelled event stream should finish promptly")
    }

    func testProcessRunnerTerminatedEventOnlyAfterExit() async throws {
        let handle = ProcessRunner.launch(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.2; exit 7"]
        )
        var terminatedStatus: Int32?
        var processWasRunningWhenReported: Bool?
        for try await event in handle.events {
            if case .terminated(let code) = event {
                terminatedStatus = code
                processWasRunningWhenReported = handle.process.isRunning
            }
        }
        XCTAssertEqual(terminatedStatus, 7)
        XCTAssertEqual(processWasRunningWhenReported, false,
                       "terminated event must only be emitted after the process exited")
    }

    // MARK: AIClient construction

    func testAIClientEndpointAndBody() throws {
        var provider = AppSettings.makeDefaultProvider()
        provider.apiKeyReference = "test-ref"
        let url = try AIClient.endpoint(for: provider)
        XCTAssertTrue(url.absoluteString.hasSuffix("/chat/completions"))
        let body = try AIClient.requestBody(messages: [.system("s"), .user("u")], provider: provider, stream: true)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(object?["stream"] as? Bool, true)
        XCTAssertEqual(object?["model"] as? String, provider.model)
        XCTAssertNil(object?["api_key"])
        XCTAssertNil(object?["apiKey"])
        // 未配置模型温度时不发送 temperature，由模型使用自身默认值。
        XCTAssertNil(object?["temperature"])

        // 配置了模型温度时才发送。
        let customBody = try AIClient.requestBody(
            messages: [.system("s"), .user("u")],
            provider: provider,
            temperature: 0.3,
            stream: true
        )
        let custom = try JSONSerialization.jsonObject(with: customBody) as? [String: Any]
        XCTAssertEqual(custom?["temperature"] as? Double ?? -1, 0.3, accuracy: 0.0001)
    }

    func testModelTemperatureConfiguration() {
        var settings = AppSettings.default
        XCTAssertNil(settings.ai.temperature(forModel: "deepseek-chat"))
        settings.ai.modelTemperatures = ["deepseek-chat": 1.2]
        XCTAssertEqual(settings.ai.temperature(forModel: "deepseek-chat"), 1.2)
        XCTAssertNil(settings.ai.temperature(forModel: "gpt-4o-mini"))
        // 超界值会被收敛到 0...2。
        settings.ai.modelTemperatures = ["deepseek-chat": 3.0]
        XCTAssertEqual(settings.ai.temperature(forModel: "deepseek-chat"), 2.0)
        // 空白模型名视为未配置。
        settings.ai.modelTemperatures = ["": 1.0]
        XCTAssertNil(settings.ai.temperature(forModel: " "))
    }

    // MARK: Activation policy

    @MainActor
    func testDockIconPreferenceMapsToActivationPolicy() {
        XCTAssertEqual(
            ActivationPolicyController.policy(showDockIcon: true).rawValue,
            NSApplication.ActivationPolicy.regular.rawValue
        )
        XCTAssertEqual(
            ActivationPolicyController.policy(showDockIcon: false).rawValue,
            NSApplication.ActivationPolicy.accessory.rawValue
        )
    }

    // Regression: the Dock icon preference used to be overridden to `.regular`
    // whenever Stage Manager was enabled, so turning the setting off had no visible
    // effect. Stage Manager is now only used for the informational notice; the
    // controller must never consult it when resolving the activation policy.

    // MARK: Per-conversation working hours

    func testConversationWorkingHoursOverrideGlobal() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 19
        components.hour = 12; components.minute = 0
        let noon = calendar.date(from: components)!

        var settings = AppSettings.default
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        settings.bot.workingHours = WorkingHours(
            enabled: true,
            startMinute: 9 * 60,
            endMinute: 18 * 60,
            weekdays: [2, 3, 4, 5, 6]
        )
        let message = ChatMessage(
            id: "m", conversationID: "c1", senderID: "u1", senderName: "用户",
            direction: .incoming, text: "你好", timestamp: noon
        )
        let engine = RuleEngine(calendar: calendar)
        let conversation = Conversation(id: "c1", kind: .direct, title: "测试")

        // 全局时段内允许回复。
        let globalContext = RuleEngine.Context(
            conversation: conversation, message: message, settings: settings,
            now: noon, selfID: "self"
        )
        XCTAssertTrue(engine.evaluate(globalContext).shouldReply)

        // 会话自定义时段（19:00–08:00）覆盖全局设置，午间应被拦截。
        var custom = conversation
        custom.workingHours = WorkingHours(
            enabled: true,
            startMinute: 19 * 60,
            endMinute: 8 * 60,
            weekdays: [1, 2, 3, 4, 5, 6, 7]
        )
        let customContext = RuleEngine.Context(
            conversation: custom, message: message, settings: settings,
            now: noon, selfID: "self"
        )
        XCTAssertFalse(engine.evaluate(customContext).shouldReply)

        // 会话显式关闭时间限制后，即使全局时段不包含当前时间也允许回复。
        settings.bot.workingHours = WorkingHours(
            enabled: true,
            startMinute: 0,
            endMinute: 60,
            weekdays: [1, 2, 3, 4, 5, 6, 7]
        )
        var unlimited = conversation
        unlimited.workingHours = WorkingHours(enabled: false)
        let unlimitedContext = RuleEngine.Context(
            conversation: unlimited, message: message, settings: settings,
            now: noon, selfID: "self"
        )
        XCTAssertTrue(engine.evaluate(unlimitedContext).shouldReply)
    }

    func testConversationWorkingHoursRoundtripAndFollowGlobal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-working-hours-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        var conversation = Conversation(id: "c1", kind: .group, title: "测试群")
        conversation.workingHours = WorkingHours(
            enabled: true,
            startMinute: 8 * 60 + 30,
            endMinute: 23 * 60,
            weekdays: [2, 3]
        )
        try await store.upsertConversation(conversation)

        let fetched = try await store.conversation(id: "c1")
        XCTAssertEqual(fetched?.workingHours?.enabled, true)
        XCTAssertEqual(fetched?.workingHours?.startMinute, 510)
        XCTAssertEqual(fetched?.workingHours?.endMinute, 1380)
        XCTAssertEqual(fetched?.workingHours?.weekdays, [2, 3])

        conversation.workingHours = nil
        try await store.upsertConversation(conversation)
        let cleared = try await store.conversation(id: "c1")
        XCTAssertNil(cleared?.workingHours, "nil 应表示跟随全局")
    }

    // MARK: Pat / multi-select triggers

    func testGroupPatTriggerDetectsSystemMessage() {
        var settings = AppSettings.default
        settings.bot.groupTriggers = [.pat]
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        let conversation = Conversation(id: "g1@chatroom", kind: .group, title: "测试群")
        let engine = RuleEngine()

        func context(text: String, rawJSON: String?) -> RuleEngine.Context {
            let message = ChatMessage(
                id: UUID().uuidString, conversationID: conversation.id, senderID: "u1",
                senderName: "小明", direction: .incoming, text: text,
                timestamp: Date(), rawJSON: rawJSON
            )
            return RuleEngine.Context(
                conversation: conversation, message: message, settings: settings,
                selfID: "self"
            )
        }

        // 中文系统模板。
        XCTAssertTrue(engine.evaluate(context(text: "\"小明\" 拍了拍我", rawJSON: nil)).shouldReply)
        // 部分版本下发 raw sysmsg XML，JSON 转义后不包含中文模板。
        XCTAssertTrue(engine.evaluate(context(
            text: "",
            rawJSON: "{\"msg_type\":10000,\"raw_message\":\"<sysmsg type=\\\"pat\\\">\"}"
        )).shouldReply)
        // 4.1.15.55 实测形态：appmsg type=49 + <type>62</type>，文本已被 hook 提取为 title。
        XCTAssertTrue(engine.evaluate(context(
            text: "\"小明\" 拍了拍我",
            rawJSON: "{\"msg_type\":49,\"raw_message\":\"<msg><appmsg><type>62</type><title>\\\"小明\\\" 拍了拍我</title></appmsg></msg>\"}"
        )).shouldReply)
        // 本地化 title 不含中文模板时，仍靠 <type>62</type> 识别。
        XCTAssertTrue(engine.evaluate(context(
            text: "",
            rawJSON: "{\"msg_type\":49,\"raw_message\":\"<msg><appmsg><type>62</type><title>nudged</title></appmsg></msg>\"}"
        )).shouldReply)
        // 普通消息不应触发。
        XCTAssertFalse(engine.evaluate(context(text: "大家好", rawJSON: nil)).shouldReply)
        // 未勾选「关键词」时，关键词消息不触发。
        settings.bot.keywords = ["天气"]
        XCTAssertFalse(engine.evaluate(context(text: "今天天气如何", rawJSON: nil)).shouldReply)
    }

    func testGroupTriggerMultiSelectAndAlwaysExclusive() {
        var settings = AppSettings.default
        settings.bot.groupTriggers = [.mention, .pat]
        settings.bot.keywords = ["天气"]
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        let conversation = Conversation(id: "g1@chatroom", kind: .group, title: "测试群")
        let engine = RuleEngine()

        func context(_ text: String) -> RuleEngine.Context {
            let message = ChatMessage(
                id: UUID().uuidString, conversationID: conversation.id, senderID: "u1",
                senderName: "小明", direction: .incoming, text: text, timestamp: Date()
            )
            return RuleEngine.Context(
                conversation: conversation, message: message, settings: settings,
                selfID: "self"
            )
        }

        // @ + 拍一拍同时生效。
        XCTAssertTrue(engine.evaluate(context("@self 你好")).shouldReply)
        XCTAssertTrue(engine.evaluate(context("\"小明\" 拍了拍我")).shouldReply)
        // 未勾选关键词时不触发。
        XCTAssertFalse(engine.evaluate(context("今天天气如何")).shouldReply)
        XCTAssertFalse(engine.evaluate(context("大家好")).shouldReply)

        // 勾选关键词后同样生效。
        settings.bot.groupTriggers = [.keyword, .pat]
        XCTAssertTrue(engine.evaluate(context("今天天气如何")).shouldReply)
        XCTAssertTrue(engine.evaluate(context("\"小明\" 拍了拍我")).shouldReply)
        XCTAssertFalse(engine.evaluate(context("@self 你好")).shouldReply)

        // 「所有消息」与其它方式互斥，即使配置里同时出现也按独占处理。
        settings.bot.groupTriggers = [.always, .keyword]
        XCTAssertEqual(settings.bot.effectiveGroupTriggers, [.always])
        XCTAssertTrue(engine.evaluate(context("大家好")).shouldReply)

        // 空数组回退为旧版单选字段。
        settings.bot.groupTriggers = []
        settings.bot.groupTrigger = .mention
        XCTAssertEqual(settings.bot.effectiveGroupTriggers, [.mention])
    }

    /// 回归：appmsg/群收款卡片里出现对别人的 at 段时曾被误判为“群聊·@”。
    func testMentionRequiresAtTargetSelf() {
        var settings = AppSettings.default
        settings.bot.groupTriggers = [.mention]
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        let conversation = Conversation(id: "g1@chatroom", kind: .group, title: "测试群")
        let engine = RuleEngine()

        func eventJSON(at target: String?, text: String = "<msg><appmsg><content>%40someone</content></appmsg></msg>") -> String {
            var event: [String: Any] = [
                "post_type": "message",
                "self_id": "wxid_bot",
                "user_id": "wxid_other",
                "group_id": "g1@chatroom",
                "message_id": "m1",
                "message_type": "group",
                "sender": ["user_id": "wxid_other", "nickname": "群友"],
                "message": [["type": "text", "data": ["text": text]]],
            ]
            if let target {
                var segments = event["message"] as? [[String: Any]] ?? []
                segments.append(["type": "at", "data": ["qq": target]])
                event["message"] = segments
            }
            let data = try! JSONSerialization.data(withJSONObject: event)
            return String(data: data, encoding: .utf8)!
        }

        func context(rawJSON: String) -> RuleEngine.Context {
            let message = ChatMessage(
                id: UUID().uuidString, conversationID: conversation.id, senderID: "wxid_other",
                senderName: "群友", direction: .incoming,
                text: "<msg><appmsg><content>%40someone</content></appmsg></msg>",
                timestamp: Date(), rawJSON: rawJSON
            )
            return RuleEngine.Context(
                conversation: conversation, message: message, settings: settings,
                selfID: "wxid_bot"
            )
        }

        // at 目标是别人：不回复（即使事件里永远带 self_id）。
        XCTAssertFalse(engine.evaluate(context(rawJSON: eventJSON(at: "wxid_someone_else"))).shouldReply)
        // 文本以 @ 开头但没有 at 段：不再按模糊规则触发。
        XCTAssertFalse(engine.evaluate(context(rawJSON: eventJSON(at: nil, text: "@群友 你好"))).shouldReply)
        // 没有 at 段：不回复。
        XCTAssertFalse(engine.evaluate(context(rawJSON: eventJSON(at: nil))).shouldReply)

        // at 目标就是机器人：回复且标签正确。
        let matched = engine.evaluate(context(rawJSON: eventJSON(at: "wxid_bot")))
        XCTAssertTrue(matched.shouldReply)
        XCTAssertEqual(matched.triggerLabel, "群聊·@")

        // 兼容包装事件 {"data": {...}}。
        let wrapped = "{\"data\":\(eventJSON(at: "wxid_bot"))}"
        XCTAssertTrue(engine.evaluate(context(rawJSON: wrapped)).shouldReply)
    }
}
