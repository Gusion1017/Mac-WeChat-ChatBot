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

        // 基础权重可由用户自由调整：范围收敛、持久化，并参与核心记忆之间的排序。
        XCTAssertEqual(LongTermMemory.clampBaseWeight(0.01), 0.1)
        XCTAssertEqual(LongTermMemory.clampBaseWeight(99), 10.0)
        XCTAssertEqual(LongTermMemory.clampBaseWeight(.nan), 1.0)
        let lowCore = LongTermMemory(
            conversationID: "",
            summary: "核心低权重",
            isCore: true,
            baseWeight: 0.5,
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-86_400)
        )
        let highCore = LongTermMemory(
            conversationID: "",
            summary: "核心高权重",
            isCore: true,
            baseWeight: 4.0,
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-86_400)
        )
        XCTAssertTrue(highCore.hasCustomBaseWeight)
        XCTAssertFalse(core.hasCustomBaseWeight)
        try await store.upsertMemory(lowCore)
        try await store.upsertMemory(highCore)
        let weighted = try await store.fetchMemoriesForPrompt(conversationID: "c1", limit: 6, now: now)
        XCTAssertEqual(
            Array(weighted.prefix(2)).map(\.summary),
            ["核心高权重", "核心低权重"],
            "同一更新时间的核心记忆按基础权重排序"
        )
        let persisted = try await store.fetchMemories().first { $0.summary == "核心高权重" }
        XCTAssertEqual(persisted?.baseWeight ?? 0, 4.0, accuracy: 0.000001)

        // 核心记忆超过注入上限时，按综合权重保留权重更高的前 6 条。
        for index in 0..<7 {
            try await store.upsertMemory(LongTermMemory(
                conversationID: "c3",
                summary: "核心 #\(index)",
                isCore: true,
                baseWeight: Double(index + 1),
                createdAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-86_400)
            ))
        }
        let capped = try await store.fetchMemoriesForPrompt(
            conversationID: "c3",
            limit: ChatEngine.longTermMemoryLimit,
            now: now
        )
        XCTAssertEqual(capped.count, ChatEngine.longTermMemoryLimit)
        XCTAssertFalse(capped.contains { $0.summary == "核心 #0" }, "权重最低的核心记忆应被注入上限挤出")
        XCTAssertTrue(capped.contains { $0.summary == "核心 #6" })

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
        let compat = try await store.pendingMemoryOverflow(conversationID: "c1", keep: 10)
        XCTAssertEqual(compat?.messages.map(\.id), ["m0", "m1"])
        XCTAssertNotNil(compat?.lastRowID)

        // 12 条时窗口外只有 2 条，不足默认批量阈值 8 条，不总结。
        let belowThreshold = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 8,
            maxMessages: 40
        )
        XCTAssertNil(belowThreshold)

        // 18 条时窗口外 8 条，一次返回 m0...m7。
        try await store.upsertMessages(makeMessages(12..<18))
        let firstBatch = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 8,
            maxMessages: 40
        )
        XCTAssertEqual(firstBatch?.messages.count, 8)
        XCTAssertEqual(firstBatch?.messages.first?.id, "m0")
        XCTAssertEqual(firstBatch?.messages.last?.id, "m7")
        try await store.markMemorySummarized(conversationID: "c1", throughRowID: firstBatch?.lastRowID ?? 0)
        let afterFirstBatch = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 8,
            maxMessages: 40
        )
        XCTAssertNil(afterFirstBatch, "游标推进后不应重复总结")

        // 26 条时再返回下一批 8 条（m8...m15）。
        try await store.upsertMessages(makeMessages(18..<26))
        let second = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 8,
            maxMessages: 40
        )
        XCTAssertEqual(second?.messages.count, 8)
        XCTAssertEqual(second?.messages.first?.id, "m8")
        XCTAssertEqual(second?.messages.last?.id, "m15")
        try await store.markMemorySummarized(conversationID: "c1", throughRowID: second?.lastRowID ?? 0)

        // 单批最多 maxMessages 条：70 条时窗口外待总结消息更多，但只取 40 条。
        try await store.upsertMessages(makeMessages(26..<70))
        let capped = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 8,
            maxMessages: 40
        )
        XCTAssertEqual(capped?.messages.count, 40, "单批上限 maxOverflowBatch")
        XCTAssertEqual(capped?.messages.first?.id, "m16")
        XCTAssertEqual(capped?.messages.last?.id, "m55")
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

    func testSummarizeOverflowBatchesEightMessagesAndKeepsOneAutoMemory() async throws {
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
        XCTAssertEqual(ChatEngine.overflowBatchThreshold, 8)
        XCTAssertEqual(ChatEngine.maxOverflowBatch, 40)
        XCTAssertEqual(ChatEngine.summaryCharacterLimit, 600)
        XCTAssertEqual(ChatEngine.summaryBulletLimit, 5)

        let engine = ChatEngine(memory: store, aiClient: AIClient())
        try await store.upsertMessages(makeMessages(0..<12))
        let firstCount = await engine.summarizeOverflow(
            conversation: conversation,
            provider: nil,
            settings: .default
        )
        XCTAssertEqual(firstCount, 0, "12 条时窗口外只有 2 条，不应总结")
        var memories = try await store.fetchMemories()
        XCTAssertTrue(memories.isEmpty, "未达阈值时不应创建长期记忆")

        // 18 条：窗口外 8 条，一次总结最早的 8 条。
        try await store.upsertMessages(makeMessages(12..<18))
        let secondCount = await engine.summarizeOverflow(
            conversation: conversation,
            provider: nil,
            settings: .default
        )
        XCTAssertEqual(secondCount, 8, "18 条时应总结窗口外的 8 条")
        memories = try await store.fetchMemories()
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories[0].source, "summary")
        XCTAssertEqual(memories[0].sourceCount, 8)
        XCTAssertTrue(memories[0].summary.contains("消息 0"))
        XCTAssertTrue(memories[0].summary.contains("消息 7"))
        XCTAssertLessThanOrEqual(memories[0].summary.count, ChatEngine.summaryCharacterLimit)
        var autos = try await store.autoMemories(conversationID: "c1")
        XCTAssertEqual(autos.count, 1)
        let pendingAfterFirst = try await store.pendingMemoryOverflow(
            conversationID: "c1",
            keep: 10,
            minOverflow: 8,
            maxMessages: 40
        )
        XCTAssertNil(pendingAfterFirst, "总结后剩余 10 条在短期窗口内")

        // 26 条：再总结下一批 8 条，自动记忆仍是一条。
        try await store.upsertMessages(makeMessages(18..<26))
        let thirdCount = await engine.summarizeOverflow(
            conversation: conversation,
            provider: nil,
            settings: .default
        )
        XCTAssertEqual(thirdCount, 8, "26 条时再总结 8 条")
        memories = try await store.fetchMemories()
        XCTAssertEqual(memories.count, 1, "自动总结应滚动更新同一条长期记忆")
        XCTAssertEqual(memories[0].sourceCount, 16)
        XCTAssertTrue(memories[0].summary.contains("消息 8"))
        XCTAssertTrue(memories[0].summary.contains("消息 15"))
        XCTAssertLessThanOrEqual(memories[0].summary.count, ChatEngine.summaryCharacterLimit)
        autos = try await store.autoMemories(conversationID: "c1")
        XCTAssertEqual(autos.count, 1)
    }

    func testCoreMemoryAndManualMemoryFollowConversationScope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-scope-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "小林"))
        try await store.upsertConversation(Conversation(id: "c2", kind: .direct, title: "阿强"))
        let now = Date()
        let globalCore = LongTermMemory(
            conversationID: "",
            summary: "全局核心：用户叫小林",
            isCore: true,
            updatedAt: now.addingTimeInterval(-3 * 86_400)
        )
        let c1Core = LongTermMemory(
            conversationID: "c1",
            summary: "c1 核心：周五讨论旅行",
            isCore: true,
            updatedAt: now.addingTimeInterval(-86_400)
        )
        let c2Core = LongTermMemory(
            conversationID: "c2",
            summary: "c2 核心：阿强喜欢健身",
            isCore: true,
            updatedAt: now.addingTimeInterval(-86_400)
        )
        let c1Manual = LongTermMemory(
            conversationID: "c1",
            summary: "c1 手写：用户喜欢猫",
            updatedAt: now.addingTimeInterval(-2 * 86_400),
            source: "manual"
        )
        let c1Auto = LongTermMemory(
            conversationID: "c1",
            summary: "c1 自动：周末去杭州",
            updatedAt: now.addingTimeInterval(-2 * 86_400)
        )
        for memory in [globalCore, c1Core, c2Core, c1Manual, c1Auto] {
            try await store.upsertMemory(memory)
        }

        let promptC1 = try await store.fetchMemoriesForPrompt(conversationID: "c1", limit: 6, now: now)
        XCTAssertEqual(
            Set(promptC1.map(\.summary)),
            Set(["全局核心：用户叫小林", "c1 核心：周五讨论旅行",
                 "c1 手写：用户喜欢猫", "c1 自动：周末去杭州"]),
            "只应注入本会话与全局记忆，其他会话核心不串入"
        )
        XCTAssertEqual(promptC1.first?.summary, "c1 核心：周五讨论旅行", "核心优先，且越近权重越高")
        XCTAssertEqual(promptC1[1].summary, "全局核心：用户叫小林")
        XCTAssertEqual(promptC1[2].source, "manual", "手写记忆优先于自动总结")

        let promptC2 = try await store.fetchMemoriesForPrompt(conversationID: "c2", limit: 6, now: now)
        XCTAssertEqual(
            Set(promptC2.map(\.summary)),
            Set(["全局核心：用户叫小林", "c2 核心：阿强喜欢健身"])
        )
        XCTAssertFalse(promptC2.contains { $0.summary.contains("c1") })
    }

    func testGroupPromptLabelsSpeakersAndDirectKeepsPlainText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-speaker-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings.default
        let group = Conversation(id: "g1", kind: .group, title: "群聊")
        let direct = Conversation(id: "c1", kind: .direct, title: "私聊")
        let now = Date()
        let history = [
            ChatMessage(id: "h1", conversationID: "g1", senderID: "wxid_a", senderName: "小明",
                        direction: .incoming, text: "早上好", timestamp: now),
            ChatMessage(id: "h2", conversationID: "g1", senderID: "self", senderName: "我",
                        direction: .outgoing, text: "早呀", timestamp: now.addingTimeInterval(1)),
            ChatMessage(id: "h3", conversationID: "g1", senderID: "wxid_b", senderName: "",
                        direction: .incoming, text: "在吗", timestamp: now.addingTimeInterval(2))
        ]
        let incoming = ChatMessage(id: "h4", conversationID: "g1", senderID: "wxid_c", senderName: "小红",
                                   direction: .incoming, text: "最新消息", timestamp: now.addingTimeInterval(3))
        let engine = ChatEngine(memory: store, aiClient: AIClient())

        let groupMessages = engine.buildMessages(
            conversation: group, incoming: incoming, settings: settings,
            persona: nil, history: history, memoryNotes: nil
        )
        let groupSystem = groupMessages.first?.content ?? ""
        XCTAssertTrue(groupSystem.contains("群聊消息格式"), "群聊应说明发言人标注规则")
        XCTAssertTrue(groupSystem.contains("以括号内的 wxid 为准"), "群聊应要求用 wxid 对齐长期记忆")
        let groupBody = groupMessages.dropFirst().map(\.content).joined(separator: "\n")
        XCTAssertTrue(groupBody.contains("小明(wxid_a)：早上好"), "昵称与 wxid 应同时出现在发言人前缀里")
        XCTAssertTrue(groupBody.contains("wxid_b：在吗"), "senderName 为空时回退 senderID，且不重复拼接")
        XCTAssertTrue(groupBody.contains("小红(wxid_c)：最新消息"))
        XCTAssertFalse(groupBody.contains("小明(wxid_a)：早呀"), "机器人自己的消息不加发言人前缀")

        let directMessages = engine.buildMessages(
            conversation: direct, incoming: incoming, settings: settings,
            persona: nil, history: history, memoryNotes: nil
        )
        let directSystem = directMessages.first?.content ?? ""
        XCTAssertFalse(directSystem.contains("群聊消息格式"), "私聊不应加群聊发言人说明")
        let directBody = directMessages.dropFirst().map(\.content).joined(separator: "\n")
        XCTAssertTrue(directBody.contains("早上好"))
        XCTAssertFalse(directBody.contains("wxid_a"), "私聊保持原文，减少提示词噪声")
    }

    /// 回归：长期记忆以 wxid 为人员键，群聊发言人前缀必须带同一个 wxid，
    /// 否则模型只能凭昵称猜测，容易套用记忆里另一个人的称呼。
    func testGroupPromptSpeakerLabelSharesWXIDKeyWithMemory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-speaker-key-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        let group = Conversation(id: "test-group@chatroom", kind: .group, title: "测试群")
        let now = Date()
        let senderID = "wxid_member_a"
        let history = [
            ChatMessage(id: "h1", conversationID: group.id, senderID: senderID,
                        senderName: "群友甲", direction: .incoming, text: "晚安",
                        timestamp: now)
        ]
        let incoming = ChatMessage(id: "h2", conversationID: group.id, senderID: senderID,
                                   senderName: "群友甲", direction: .incoming,
                                   text: "/delate", timestamp: now.addingTimeInterval(1))
        let memoryNotes = """
        长期记忆（核心/手写优先，自动总结仅供参考）：
        - [★核心·本会话·权重 10.0] 群聊中微信号对应的人员：
        wxid_member_b：测试群友乙/别名乙
        wxid_member_a：群友甲/别名甲
        """
        let engine = ChatEngine(memory: store, aiClient: AIClient())
        let messages = engine.buildMessages(
            conversation: group, incoming: incoming, settings: .default,
            persona: nil, history: history, memoryNotes: memoryNotes
        )
        let system = messages.first?.content ?? ""
        let body = messages.dropFirst().map(\.content).joined(separator: "\n")
        XCTAssertTrue(system.contains("wxid_member_a：群友甲/别名甲"),
                      "记忆里应有该人员对应关系")
        XCTAssertTrue(body.contains("群友甲(wxid_member_a)：/delate"),
                      "发言前缀必须带记忆使用的同一个 wxid，模型才能精确对齐")
        XCTAssertFalse(body.contains("测试群友乙(wxid_member_a)"),
                       "不能把记忆里另一个人的称呼拼到当前发言人上")

        let identity = "【本轮发言人身份】群友甲（wxid_member_a）"
        let withIdentity = engine.buildMessages(
            conversation: group, incoming: incoming, settings: .default,
            persona: nil, history: history, memoryNotes: memoryNotes,
            speakerIdentity: identity
        )
        XCTAssertTrue(withIdentity.first?.content.hasSuffix(identity) ?? false,
                      "身份硬约束应放在 system 提示词最后，压过最近聊天里的玩梗")
    }

    /// 回归（2026-10-26 真机）：AI 自己的 TTS 语音回复在短期历史里曾带 `[语音 Ns]` 标注，
    /// 模型把标注当成自己的回复格式照抄，下一轮文字回复以 `[语音 8s]` 开头发到微信。
    /// 出站语音必须只以正文进入 assistant 轮次；system 提示同时明确禁止输出标注。
    func testBuildMessagesKeepsOutgoingVoiceHistoryUnlabelled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-voice-prompt-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        let group = Conversation(id: "test-group@chatroom", kind: .group, title: "测试群")
        let now = Date()
        var voice = ChatMessage(
            id: "v1", conversationID: group.id, senderID: "self", senderName: "我",
            direction: .outgoing, kind: .voice, text: "我在呢",
            timestamp: now.addingTimeInterval(1)
        )
        voice.voiceDurationMs = 9_680
        voice.voiceTranscriptState = .disabled
        let history = [
            ChatMessage(id: "h1", conversationID: group.id, senderID: "wxid_member_a",
                        senderName: "群友甲", direction: .incoming, text: "在吗",
                        timestamp: now),
            voice,
            ChatMessage(id: "h2", conversationID: group.id, senderID: "wxid_member_a",
                        senderName: "群友甲", direction: .incoming, text: "出来聊天",
                        timestamp: now.addingTimeInterval(2))
        ]
        let incoming = ChatMessage(id: "h3", conversationID: group.id, senderID: "wxid_member_a",
                                   senderName: "群友甲", direction: .incoming, text: "测试消息",
                                   timestamp: now.addingTimeInterval(3))
        let engine = ChatEngine(memory: store, aiClient: AIClient())
        let messages = engine.buildMessages(
            conversation: group, incoming: incoming, settings: .default,
            persona: nil, history: history, memoryNotes: nil
        )
        let system = messages.first?.content ?? ""
        XCTAssertTrue(system.contains("回复里绝对不要输出"), "system 提示要明确禁止输出语音标注")
        let assistant = messages.filter { $0.role == .assistant }.map(\.content)
        XCTAssertEqual(assistant, ["我在呢"], "出站语音在历史里只保留正文，不能带 `[语音 Ns]`")
        let body = messages.dropFirst().map(\.content).joined(separator: "\n")
        XCTAssertFalse(body.contains("[语音"), "assistant 轮次出现标注会被模型照抄")
    }

    /// 手写/核心记忆里的 `wxid：称呼` 是群聊身份的唯一权威来源；
    /// 最近聊天里「我现在是某某」「某某其实是某某」不能被当成映射。
    func testSpeakerIdentityNoteUsesAuthoritativeWXIDNotRecentChat() throws {
        let group = Conversation(id: "test-group@chatroom", kind: .group, title: "测试群")
        let incoming = ChatMessage(
            id: "m", conversationID: group.id, senderID: "wxid_member_a",
            senderName: "群友甲", direction: .incoming,
            text: "好的，我现在是别名乙", timestamp: Date()
        )
        let memories = [
            LongTermMemory(
                conversationID: group.id,
                summary: "群聊人员：\nwxid_member_b：测试群友乙/别名乙\nwxid_member_a：群友甲/别名甲",
                isCore: true, source: "manual"
            ),
            LongTermMemory(
                conversationID: group.id,
                summary: "- 人物与称呼：群友甲被称别名乙\n- 偏好：喜欢猫",
                source: "summary"
            )
        ]
        let note = try XCTUnwrap(ChatEngine.speakerIdentityNote(
            conversation: group, incoming: incoming, memories: memories
        ))
        XCTAssertTrue(note.contains("群友甲"))
        XCTAssertTrue(note.contains("wxid_member_a"))
        XCTAssertTrue(note.contains("不要附和"))
        XCTAssertFalse(note.contains("测试群友乙"), "不能把另一个人的称呼写进本轮身份约束")
        XCTAssertFalse(note.contains("别名乙"), "不能把群聊里的临时改口当成权威称呼")
    }

    func testPersonMappingsParseWXIDAliases() {
        let mappings = ChatEngine.personMappings(in: [
            """
            群聊中微信号对应的人员（回答时不要带出 wxid；排在前面的称呼优先）：
            wxid_member_b：测试群友乙/别名乙
            wxid_member_a：群友甲/别名甲
            """,
            "项目负责人（回答时不要带出 wxid）：wxid_owner：负责人"
        ])
        XCTAssertEqual(mappings["wxid_member_a"], ["群友甲", "别名甲"])
        XCTAssertEqual(mappings["wxid_member_b"], ["测试群友乙", "别名乙"])
        XCTAssertEqual(mappings["wxid_owner"], ["负责人"])
    }

    func testAutoSummaryPersonSectionIsStrippedWhenManualMappingExists() {
        let auto = LongTermMemory(
            conversationID: "test-group@chatroom",
            summary: "- 人物与称呼：群友甲被称别名乙\n- 偏好：喜欢猫",
            source: "summary"
        )
        let core = LongTermMemory(
            conversationID: "test-group@chatroom",
            summary: "wxid_member_a：群友甲/别名甲",
            isCore: true, source: "manual"
        )
        let stripped = ChatEngine.promptSummary(for: auto, hasAuthoritativePersonMapping: true)
        XCTAssertFalse(stripped.contains("人物与称呼"))
        XCTAssertFalse(stripped.contains("别名乙"))
        XCTAssertTrue(stripped.contains("喜欢猫"))
        XCTAssertEqual(
            ChatEngine.promptSummary(for: core, hasAuthoritativePersonMapping: true),
            core.summary,
            "手写/核心记忆本身不能被裁剪"
        )
        XCTAssertTrue(
            ChatEngine.promptSummary(for: auto, hasAuthoritativePersonMapping: false)
                .contains("人物与称呼"),
            "没有手写映射时保留自动总结的人物信息作为兜底"
        )
    }

    func testSummaryPromptForbidsPersonClaimsWhenManualMappingExists() {
        let group = Conversation(id: "test-group@chatroom", kind: .group, title: "测试群")
        let core = LongTermMemory(
            conversationID: group.id,
            summary: "wxid_member_a：群友甲/别名甲",
            isCore: true, source: "manual"
        )
        let pair = ChatEngine.summaryPrompt(
            conversation: group,
            authoritativeMemories: [core],
            hasAuthoritativePersonMapping: true,
            existingSummary: "- 人物与称呼：群友甲被称别名乙\n- 偏好：喜欢猫",
            transcript: "群友甲：好的，我现在是别名乙\n测试群友乙：对，你就是别名乙",
            newMessageCount: 2
        )
        XCTAssertTrue(pair.user.contains("人物与称呼由用户手写的核心记忆维护"))
        XCTAssertTrue(pair.user.contains("玩笑"))
        XCTAssertTrue(pair.user.contains("以手写记忆为准"))
        XCTAssertTrue(pair.user.contains("wxid_member_a：群友甲/别名甲"))
    }

    func testEarlierRecallStaysInCurrentConversation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-recall-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        let conversation = Conversation(id: "c1", kind: .direct, title: "小林")
        let now = Date()
        try await store.upsertMessages([
            ChatMessage(id: "old1", conversationID: "c1", senderID: "wxid_a", senderName: "wxid_a",
                        direction: .incoming, text: "去杭州玩", timestamp: now.addingTimeInterval(-3_600)),
            ChatMessage(id: "other1", conversationID: "c2", senderID: "wxid_b", senderName: "wxid_b",
                        direction: .incoming, text: "去杭州玩（其他会话）", timestamp: now.addingTimeInterval(-1_800)),
            ChatMessage(id: "recent1", conversationID: "c1", senderID: "wxid_a", senderName: "wxid_a",
                        direction: .incoming, text: "去杭州玩（窗口内）", timestamp: now.addingTimeInterval(-10))
        ])
        let recent = ChatMessage(id: "recent1", conversationID: "c1", senderID: "wxid_a", senderName: "wxid_a",
                                 direction: .incoming, text: "去杭州玩（窗口内）",
                                 timestamp: now.addingTimeInterval(-10))
        var history = (0..<9).map { index in
            ChatMessage(id: "h\(index)", conversationID: "c1", senderID: "wxid_a", senderName: "wxid_a",
                        direction: index.isMultiple(of: 2) ? .incoming : .outgoing,
                        text: "窗口消息 \(index)",
                        timestamp: now.addingTimeInterval(Double(-9 + index)))
        }
        history.append(recent)
        let incoming = ChatMessage(id: "in", conversationID: "c1", senderID: "wxid_a", senderName: "wxid_a",
                                   direction: .incoming, text: "去杭州玩", timestamp: now.addingTimeInterval(-5))
        let engine = ChatEngine(memory: store, aiClient: AIClient())

        let recall = await engine.recallEarlierMessages(
            conversation: conversation,
            incoming: incoming,
            history: history
        )
        XCTAssertNotNil(recall)
        XCTAssertTrue(recall?.contains("本会话较早的相关片段") ?? false)
        XCTAssertTrue(recall?.contains("对方：去杭州玩") ?? false, "私聊召回统一标「对方」")
        XCTAssertFalse(recall?.contains("其他会话") ?? true, "不得召回其他会话的原文")
        XCTAssertFalse(recall?.contains("窗口内") ?? true, "短期窗口内的消息不重复召回")
    }

    func testSummarizeOverflowKeepsManualMemoryAuthoritative() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-manual-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        let conversation = Conversation(id: "c1", kind: .direct, title: "测试")
        try await store.upsertConversation(conversation)
        let manual = LongTermMemory(
            conversationID: "c1",
            summary: "手写：用户叫小林，喜欢猫",
            updatedAt: Date().addingTimeInterval(-86_400),
            source: "manual"
        )
        try await store.upsertMemory(manual)
        let now = Date()
        try await store.upsertMessages((0..<18).map { index in
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
        XCTAssertEqual(count, 8)

        let manuals = try await store.manualMemories(conversationID: "c1")
        XCTAssertEqual(manuals.map(\.summary), ["手写：用户叫小林，喜欢猫"], "手写记忆不应被自动总结覆盖")
        let all = try await store.fetchMemories()
        XCTAssertEqual(all.count, 2)
        guard let auto = all.first(where: { $0.source == "summary" }) else {
            return XCTFail("应生成一条自动滚动记忆")
        }
        XCTAssertEqual(auto.sourceCount, 8)
        XCTAssertTrue(auto.summary.contains("消息 0"))
        XCTAssertTrue(auto.summary.contains("消息 7"))

        let prompt = try await store.fetchMemoriesForPrompt(conversationID: "c1")
        XCTAssertTrue(prompt.contains { $0.source == "manual" })
        XCTAssertTrue(prompt.contains { $0.source == "summary" })
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

        // 窗口外攒够 8 条后触发总结：先合并历史多条，再滚动合并本批。
        try await store.upsertMessages((0..<18).map { index in
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
        XCTAssertEqual(count, 8)

        let after = try await store.autoMemories(conversationID: "c1")
        XCTAssertEqual(after.count, 1, "同一会话只保留一条自动记忆")
        XCTAssertEqual(after[0].sourceCount, 5 + 7 + 8, "合并时累加 sourceCount")
        XCTAssertTrue(after[0].summary.contains("猫"))
        XCTAssertTrue(after[0].summary.contains("杭州"))
        XCTAssertTrue(after[0].summary.contains("消息 0"))
        XCTAssertTrue(after[0].summary.contains("消息 7"))
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

    // MARK: AI channel editor settings

    func testProviderRequiresAPIKeyByKind() {
        var provider = AIProvider(
            name: "test",
            kind: .deepSeek,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat"
        )

        XCTAssertTrue(provider.requiresAPIKey, "DeepSeek 必须有 Key")
        XCTAssertFalse(provider.hasUsableCredential)

        provider.kind = .openAI
        XCTAssertTrue(provider.requiresAPIKey)
        XCTAssertFalse(provider.hasUsableCredential)

        provider.kind = .ollama
        XCTAssertFalse(provider.requiresAPIKey, "本地 Ollama 无需 Key")
        XCTAssertTrue(provider.hasUsableCredential)

        provider.kind = .custom
        XCTAssertFalse(provider.requiresAPIKey, "自定义兼容端点 Key 可选")
        XCTAssertTrue(provider.hasUsableCredential)

        provider.kind = .openAI
        provider.apiKeyReference = "provider-openai"
        XCTAssertTrue(provider.hasUsableCredential)
    }

    func testLegacyAISettingsWithRemovedRequestTimeoutStillDecodes() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var ai = try XCTUnwrap(root["ai"] as? [String: Any])
        XCTAssertNil(ai["requestTimeoutSeconds"], "已移除未生效的全局请求超时")

        // 旧 config.json 仍带着已删除的键：未知键必须被忽略，不能影响整份配置解码。
        ai["requestTimeoutSeconds"] = 30
        root["ai"] = ai
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertTrue(decoded.ai.streamReplies)
        XCTAssertEqual(decoded.ai.retryCount, AppSettings.default.ai.retryCount)
        XCTAssertEqual(decoded.providers.count, AppSettings.default.providers.count)
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
    func testMainWindowVisibilityMapsToActivationPolicy() {
        // 窗口打开时临时注册 Dock 图标（并让台前调度接管窗口）。
        XCTAssertEqual(
            ActivationPolicyController.policy(forVisibleWindow: true).rawValue,
            NSApplication.ActivationPolicy.regular.rawValue
        )
        // 关闭窗口后退回仅菜单栏模式。
        XCTAssertEqual(
            ActivationPolicyController.policy(forVisibleWindow: false).rawValue,
            NSApplication.ActivationPolicy.accessory.rawValue
        )
    }

    // The activation policy is derived from window visibility only. The old
    // `showDockIcon` preference (and its Stage Manager override) has been removed;
    // Stage Manager must not be able to force a hidden Dock icon back on.

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

    func testMemoryStoreDeleteConversationRemovesChatData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-delete-chat-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "测试"))
        try await store.upsertMessages([ChatMessage(
            id: "m1",
            conversationID: "c1",
            senderID: "u1",
            senderName: "用户",
            direction: .incoming,
            text: "你好",
            timestamp: Date()
        )])
        try await store.upsertMemory(LongTermMemory(conversationID: "c1", summary: "会话摘要"))

        try await store.deleteConversation(id: "c1")

        let deletedConversation = try await store.conversation(id: "c1")
        let remainingMessages = try await store.fetchMessages(conversationID: "c1")
        let remainingMemories = try await store.fetchMemories()
        XCTAssertNil(deletedConversation)
        XCTAssertTrue(remainingMessages.isEmpty)
        XCTAssertTrue(remainingMemories.isEmpty, "删除聊天会同时删除相关记忆")
    }

    // MARK: Pat / multi-select triggers

    func testGroupPatTriggerDetectsSystemMessage() {
        var settings = AppSettings.default
        settings.bot.groupTriggers = [.pat]
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        settings.bot.selfMentionNames = ["g1@chatroom": "测试机器人"]
        let conversation = Conversation(id: "g1@chatroom", kind: .group, title: "测试群")
        let engine = RuleEngine()

        func context(text: String, rawJSON: String?,
                     selfID: String = "wxid_bot") -> RuleEngine.Context {
            let message = ChatMessage(
                id: UUID().uuidString, conversationID: conversation.id, senderID: "wxid_friend",
                senderName: "小明", direction: .incoming, text: text,
                timestamp: Date(), rawJSON: rawJSON
            )
            return RuleEngine.Context(
                conversation: conversation, message: message, settings: settings,
                selfID: selfID
            )
        }

        // 4.1.15.55 实测形态：appmsg type=62 + <patinfo> target=self。
        let appmsg = #"{"msg_type":49,"raw_message":"<msg><appmsg><type>62</type><title>&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;</title><patinfo><fromusername>wxid_friend</fromusername><chatusername>g1@chatroom</chatusername><pattedusername>wxid_bot</pattedusername><template>&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;</template></patinfo></appmsg></msg>"}"#
        XCTAssertTrue(engine.evaluate(context(text: "\"小明\" 拍了拍我", rawJSON: appmsg)).shouldReply)

        // 4.1.12 sysmsg pat + pattedusername=self。
        let sysmsg = #"{"msg_type":10000,"raw_message":"<sysmsg type=\"pat\"><pat><fromusername>wxid_friend</fromusername><chatusername>g1@chatroom</chatusername><pattedusername>wxid_bot</pattedusername><template>&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;</template></pat></sysmsg>"}"#
        let sysmsgMatched = engine.evaluate(context(text: "", rawJSON: sysmsg))
        XCTAssertTrue(sysmsgMatched.shouldReply)
        XCTAssertEqual(sysmsgMatched.triggerLabel, "群聊·拍一拍")

        // hook 新增的结构化字段：没有可解析 XML 也能识别。
        let structured = #"{"pat_from_wxid":"wxid_friend","pat_chat_wxid":"g1@chatroom","pat_target_wxid":"wxid_bot"}"#
        XCTAssertTrue(engine.evaluate(context(text: "", rawJSON: structured)).shouldReply)

        // 没有结构化目标时，标题命中已学到的机器人群昵称才触发。
        let noTarget = #"{"msg_type":49,"raw_message":"<msg><appmsg><type>62</type><patinfo><fromusername>wxid_friend</fromusername><chatusername>g1@chatroom</chatusername><template>&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;</template></patinfo></appmsg></msg>"}"#
        XCTAssertTrue(engine.evaluate(context(text: "", rawJSON: noTarget)).shouldReply)

        // 拍别人不触发（即使事件里永远带 self_id）。
        let otherTarget = #"{"msg_type":49,"raw_message":"<msg><appmsg><type>62</type><patinfo><fromusername>wxid_friend</fromusername><chatusername>g1@chatroom</chatusername><pattedusername>wxid_someone_else</pattedusername><template>&quot;小明&quot; 拍了拍 &quot;别人&quot;</template></patinfo></appmsg></msg>"}"#
        XCTAssertFalse(engine.evaluate(context(text: "", rawJSON: otherTarget)).shouldReply)

        // 纯文本消息里提到「拍了拍」不是拍一拍（rawJSON 没有 patinfo / type 62 / sysmsg）。
        XCTAssertFalse(engine.evaluate(context(text: "\"小明\" 拍了拍我", rawJSON: nil)).shouldReply)
        XCTAssertFalse(engine.evaluate(context(text: "我刚才拍了拍他", rawJSON: nil)).shouldReply)
        XCTAssertFalse(engine.evaluate(context(
            text: "我刚才拍了拍他",
            rawJSON: #"{"raw_message":"我刚才拍了拍他"}"#
        )).shouldReply)

        // 没有 target 且对不上机器人昵称/selfID 时不触发。
        settings.bot.selfMentionNames = nil
        XCTAssertFalse(engine.evaluate(context(text: "\"小明\" 拍了拍我", rawJSON: noTarget)).shouldReply)
        // 普通消息不应触发。
        XCTAssertFalse(engine.evaluate(context(text: "大家好", rawJSON: nil)).shouldReply)
        // 未勾选「关键词」时，关键词消息不触发。
        settings.bot.keywords = ["天气"]
        XCTAssertFalse(engine.evaluate(context(text: "今天天气如何", rawJSON: nil)).shouldReply)
    }

    /// 回归：拍别人 / 纯文本提到「拍了拍」都不应唤醒机器人。
    func testGroupPatTriggerRequiresBotAsTarget() {
        var settings = AppSettings.default
        settings.bot.groupTriggers = [.pat]
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        let conversation = Conversation(id: "g1@chatroom", kind: .group, title: "测试群")
        let engine = RuleEngine()

        func context(text: String, rawJSON: String?) -> RuleEngine.Context {
            let message = ChatMessage(
                id: UUID().uuidString, conversationID: conversation.id, senderID: "wxid_friend",
                senderName: "小明", direction: .incoming, text: text,
                timestamp: Date(), rawJSON: rawJSON
            )
            return RuleEngine.Context(
                conversation: conversation, message: message, settings: settings,
                selfID: "wxid_bot"
            )
        }

        let targetSelf = #"{"msg_type":49,"raw_message":"<msg><appmsg><type>62</type><patinfo><fromusername>wxid_friend</fromusername><chatusername>g1@chatroom</chatusername><pattedusername>WXID_BOT</pattedusername><template>nudged</template></patinfo></appmsg></msg>"}"#
        let matched = engine.evaluate(context(text: "", rawJSON: targetSelf))
        XCTAssertTrue(matched.shouldReply, "目标比对忽略大小写")
        XCTAssertEqual(matched.triggerLabel, "群聊·拍一拍")

        let targetOther = #"{"msg_type":49,"raw_message":"<msg><appmsg><type>62</type><patinfo><fromusername>wxid_friend</fromusername><chatusername>g1@chatroom</chatusername><pattedusername>wxid_someone_else</pattedusername><template>&quot;小明&quot; 拍了拍 &quot;别人&quot;</template></patinfo></appmsg></msg>"}"#
        XCTAssertFalse(engine.evaluate(context(text: "", rawJSON: targetOther)).shouldReply)

        // 没有目标：群聊里「拍了拍我」不能硬猜成机器人。
        let patMeNoTarget = #"{"msg_type":10000,"raw_message":"<sysmsg type=\"pat\"><pat><fromusername>wxid_friend</fromusername><chatusername>g1@chatroom</chatusername><template>&quot;小明&quot; 拍了拍我</template></pat></sysmsg>"}"#
        XCTAssertFalse(engine.evaluate(context(text: "小明 拍了拍我", rawJSON: patMeNoTarget)).shouldReply)

        // 没有目标：模板里出现 selfID 或已学到的群昵称才命中。
        let mentionsSelfID = #"{"msg_type":10000,"raw_message":"<sysmsg type=\"pat\"><pat><fromusername>wxid_friend</fromusername><chatusername>g1@chatroom</chatusername><template>&quot;小明&quot; 拍了拍 wxid_bot</template></pat></sysmsg>"}"#
        XCTAssertTrue(engine.evaluate(context(text: "", rawJSON: mentionsSelfID)).shouldReply)

        settings.bot.selfMentionNames = ["g1@chatroom": "测试机器人"]
        let mentionsName = #"{"msg_type":10000,"raw_message":"<sysmsg type=\"pat\"><pat><fromusername>wxid_friend</fromusername><chatusername>g1@chatroom</chatusername><template>&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;</template></pat></sysmsg>"}"#
        XCTAssertTrue(engine.evaluate(context(text: "", rawJSON: mentionsName)).shouldReply)
    }

    /// 私聊不做群聊触发方式过滤：replyToDirect 为真时，拍一拍照常回复。
    func testDirectPatMeStillReplies() {
        var settings = AppSettings.default
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        let conversation = Conversation(id: "wxid_friend", kind: .direct, title: "小明")
        let rawJSON = #"{"msg_type":10000,"raw_message":"<sysmsg type=\"pat\"><pat><fromusername>wxid_friend</fromusername><template>&quot;小明&quot; 拍了拍我</template></pat></sysmsg>"}"#
        let message = ChatMessage(
            id: "m-pat-direct", conversationID: conversation.id, senderID: "wxid_friend",
            senderName: "小明", direction: .incoming, text: "\"小明\" 拍了拍我",
            timestamp: Date(), rawJSON: rawJSON
        )
        let ctx = RuleEngine.Context(
            conversation: conversation, message: message, settings: settings,
            selfID: "wxid_bot"
        )
        XCTAssertTrue(RuleEngine().evaluate(ctx).shouldReply)
        XCTAssertTrue(PatMessage.isDirectedAtBot(
            message, conversation: conversation, selfID: "wxid_bot", selfMentionName: nil
        ))
    }

    func testGroupTriggerMultiSelectAndAlwaysExclusive() {
        var settings = AppSettings.default
        settings.bot.groupTriggers = [.mention, .pat]
        settings.bot.keywords = ["天气"]
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        let conversation = Conversation(id: "g1@chatroom", kind: .group, title: "测试群")
        let engine = RuleEngine()
        // 真实拍一拍事件：patinfo target=self，正文被 hook 提取为 title。
        let patJSON = #"{"msg_type":49,"raw_message":"<msg><appmsg><type>62</type><patinfo><fromusername>wxid_friend</fromusername><chatusername>g1@chatroom</chatusername><pattedusername>self</pattedusername><template>&quot;小明&quot; 拍了拍我</template></patinfo></appmsg></msg>"}"#

        func context(_ text: String, rawJSON: String? = nil) -> RuleEngine.Context {
            let message = ChatMessage(
                id: UUID().uuidString, conversationID: conversation.id, senderID: "u1",
                senderName: "小明", direction: .incoming, text: text, timestamp: Date(),
                rawJSON: rawJSON
            )
            return RuleEngine.Context(
                conversation: conversation, message: message, settings: settings,
                selfID: "self"
            )
        }

        // @ + 拍一拍同时生效。
        XCTAssertTrue(engine.evaluate(context("@self 你好")).shouldReply)
        XCTAssertTrue(engine.evaluate(context("\"小明\" 拍了拍我", rawJSON: patJSON)).shouldReply)
        // 未勾选关键词时不触发。
        XCTAssertFalse(engine.evaluate(context("今天天气如何")).shouldReply)
        XCTAssertFalse(engine.evaluate(context("大家好")).shouldReply)

        // 勾选关键词后同样生效。
        settings.bot.groupTriggers = [.keyword, .pat]
        XCTAssertTrue(engine.evaluate(context("今天天气如何")).shouldReply)
        XCTAssertTrue(engine.evaluate(context("\"小明\" 拍了拍我", rawJSON: patJSON)).shouldReply)
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

    // MARK: Reply pipeline progress

    func testReplyProgressCountdownClampsAndFormats() {
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = ReplyProgress(
            conversationID: "c1",
            stage: .waitingToSend,
            startedAt: start,
            stageStartedAt: start,
            countdownEnd: start.addingTimeInterval(3),
            countdownTotal: 5,
            providerName: "DeepSeek",
            model: "deepseek-chat",
            segmentIndex: 1,
            segmentCount: 2
        )

        // 倒计时按截止时间计算，剩余比例用于收缩进度条。
        XCTAssertEqual(progress.remainingSeconds(at: start) ?? -1, 3, accuracy: 0.0001)
        XCTAssertEqual(progress.countdownFraction(at: start) ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(progress.remainingSeconds(at: start.addingTimeInterval(4)) ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(progress.countdownFraction(at: start.addingTimeInterval(4)) ?? -1, 1, accuracy: 0.0001)

        // 未知/已结束倒计时不会产生负值。
        progress.countdownEnd = nil
        progress.countdownTotal = nil
        XCTAssertNil(progress.remainingSeconds(at: start))
        XCTAssertNil(progress.countdownFraction(at: start))

        XCTAssertEqual(UIFormat.liveSeconds(6.24), "6.2 秒")
        XCTAssertEqual(UIFormat.liveSeconds(65), "1 分 05 秒")
        XCTAssertEqual(UIFormat.liveSeconds(-1), "0.0 秒")

        XCTAssertTrue(ReplyStage.generating.isActive)
        XCTAssertTrue(ReplyStage.waitingToSend.needsTicking)
        XCTAssertFalse(ReplyStage.failed.isActive)
        XCTAssertEqual(ReplyStage.completed.label, "回复已发送")
    }
}
