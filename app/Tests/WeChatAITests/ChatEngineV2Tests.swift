import XCTest
@testable import WeChatAI

/// ChatEngine 记忆 v2 提示词路径测试（全部使用临时目录，不发起真实网络请求）。
///
/// 覆盖 docs/memory.md §3 / §8 / §9：
/// - 会话人格设定是唯一人设来源，记忆卡只保存记忆；
/// - `MemoryEngine.recall` 的「记忆上下文」段原样注入、不重复套旧标题；
/// - 群聊身份硬约束从 `CharacterMemory`（置顶/重要/fact）解析；
/// - 旧 `ChatEngine(memory:aiClient:)` 与 `buildMessages(persona:memoryNotes:)` 行为不变。
final class ChatEngineV2Tests: XCTestCase {
    private var directory: URL!
    private var legacyStore: MemoryStore!
    private var characters: CharacterStore!
    private var aiClient: AIClient!

    private let directID = "wxid_conv_v2"
    private let groupID = "123456@chatroom"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-chatengine-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        legacyStore = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        characters = CharacterStore(
            rootDirectory: directory.appendingPathComponent("characters", isDirectory: true))
        aiClient = AIClient()
    }

    override func tearDownWithError() throws {
        if let legacyStore {
            Task { await legacyStore.close() }
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Helpers

    private func makeProvider(model: String = "template-model") -> AIProvider {
        AIProvider(
            id: "fake-provider",
            name: "测试通道",
            kind: .ollama,
            baseURL: "http://127.0.0.1:9/v1",
            model: model,
            apiKeyReference: "",
            stream: false
        )
    }

    private func makeIncoming(
        conversation: Conversation,
        text: String,
        senderID: String = "wxid_user",
        senderName: String = "用户"
    ) -> ChatMessage {
        ChatMessage(
            id: "incoming-\(UUID().uuidString)",
            conversationID: conversation.id,
            senderID: senderID,
            senderName: senderName,
            direction: .incoming,
            text: text,
            timestamp: Date()
        )
    }

    private func makeTemplate(prompt: String) -> Persona {
        Persona(
            id: "persona-template",
            name: "模板小鱼",
            summary: "模板摘要",
            systemPrompt: prompt,
            isDefault: true
        )
    }

    private func makeV2Engine() -> ChatEngine {
        ChatEngine(
            memory: legacyStore,
            aiClient: aiClient,
            characters: characters,
            memoryEngine: MemoryEngine(characters: characters, aiClient: aiClient)
        )
    }

    // MARK: v2 prompt context

    func testV2ContextUsesPersonaSettingsAndRecalledMemory() async throws {
        let conversation = Conversation(id: directID, kind: .direct, title: "小林")
        let incoming = makeIncoming(conversation: conversation, text: "我最近喜欢吃什么？")
        let template = makeTemplate(prompt: "人格设定里的提示词")
        var settings = AppSettings.default
        settings.bot.memory = MemorySettings()

        try await characters.ensureCharacter(
            conversation: conversation,
            persona: template,
            activationTimestamp: incoming.timestamp
        )

        // 记忆卡里的一条事实记忆（模拟提取结果）。
        try await characters.upsertMemory(CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "用户最近喜欢吃草莓",
            keywords: ["草莓"],
            importance: 6,
            source: .extraction
        ))

        let provider = makeProvider()
        let engine = makeV2Engine()
        let context = await engine.buildPromptContext(
            conversation: conversation,
            incoming: incoming,
            settings: settings,
            persona: template,
            provider: provider
        )

        XCTAssertEqual(context.characterID, conversation.id)
        XCTAssertEqual(context.personaPrompt, "人格设定里的提示词",
                       "人设唯一来源是人格设定，不再复制到会话")
        XCTAssertEqual(context.provider.model, "template-model")
        XCTAssertEqual(provider.model, "template-model")
        XCTAssertNil(context.speakerIdentity, "私聊不注入群聊身份约束")

        let memoryPrompt = try XCTUnwrap(context.memoryPrompt)
        XCTAssertTrue(memoryPrompt.contains("记忆上下文"), "召回段由 MemoryEngine 自带标题")
        XCTAssertTrue(memoryPrompt.contains("用户最近喜欢吃草莓"))
        XCTAssertFalse(memoryPrompt.contains("相关历史记忆（仅供参考"), "v2 召回段不应再套旧标题")

        let messages = engine.buildMessages(
            conversation: conversation,
            incoming: incoming,
            settings: settings,
            personaPrompt: context.personaPrompt,
            history: [],
            memoryPrompt: context.memoryPrompt,
            speakerIdentity: context.speakerIdentity
        )
        let system = try XCTUnwrap(messages.first?.content)
        XCTAssertTrue(system.contains("人格设定里的提示词"))
        XCTAssertEqual(system.components(separatedBy: "记忆上下文").count, 2,
                       "记忆段只应出现一次")
        XCTAssertFalse(system.contains("相关历史记忆（仅供参考"))
    }

    func testV2MemoryDisabledFallsBackToTemplateWithoutRecall() async throws {
        let conversation = Conversation(id: directID, kind: .direct, title: "小林")
        let incoming = makeIncoming(conversation: conversation, text: "你还记得吗？")
        let template = makeTemplate(prompt: "全局人格模板提示词")
        var settings = AppSettings.default
        var memory = MemorySettings()
        memory.enabled = false
        settings.bot.memory = memory

        // 即使已有记忆，关闭后也必须丢弃召回，只使用人格设定。
        try await characters.ensureCharacter(
            conversation: conversation, persona: template)
        try await characters.upsertMemory(CharacterMemory(
            characterID: conversation.id,
            category: .fact,
            content: "用户喜欢猫"
        ))

        let engine = makeV2Engine()
        let context = await engine.buildPromptContext(
            conversation: conversation,
            incoming: incoming,
            settings: settings,
            persona: template,
            provider: makeProvider()
        )
        XCTAssertNil(context.characterID)
        XCTAssertEqual(context.personaPrompt, "全局人格模板提示词")
        XCTAssertNil(context.memoryPrompt, "记忆关闭后不召回")
        XCTAssertNil(context.speakerIdentity, "记忆关闭后不注入身份约束")
    }

    func testV2ContextFallsBackToTemplateWhenCharacterStoreUnavailable() async throws {
        let conversation = Conversation(id: "c-suspended", kind: .direct, title: "测试")
        let incoming = makeIncoming(conversation: conversation, text: "你好")
        let template = makeTemplate(prompt: "全局人格模板提示词")
        var settings = AppSettings.default
        settings.bot.memory = MemorySettings()

        // 未 activate 的 CharacterStore：ensureCharacter 会抛错，回复不能因此失败。
        let suspended = CharacterStore()
        let engine = ChatEngine(
            memory: legacyStore,
            aiClient: aiClient,
            characters: suspended,
            memoryEngine: MemoryEngine(characters: suspended, aiClient: aiClient)
        )
        let recorder = LogRecorder()
        engine.onLog = { level, message in recorder.append(level, message) }

        let context = await engine.buildPromptContext(
            conversation: conversation,
            incoming: incoming,
            settings: settings,
            persona: template,
            provider: makeProvider()
        )
        XCTAssertNil(context.characterID)
        XCTAssertEqual(context.personaPrompt, "全局人格模板提示词")
        XCTAssertNil(context.memoryPrompt)
        XCTAssertNil(context.speakerIdentity)
        XCTAssertTrue(
            recorder.messages(level: .warning).contains { $0.contains("仍使用人格设定") },
            "记忆卡不可用应记 warning 并继续回复"
        )
    }

    // MARK: Legacy path stays intact

    func testLegacyEngineKeepsTemplateAndLegacyMemoryHeading() async throws {
        let conversation = Conversation(id: "c-legacy", kind: .direct, title: "测试")
        let incoming = makeIncoming(conversation: conversation, text: "你好")
        let template = makeTemplate(prompt: "全局人格模板提示词")
        try await legacyStore.open()
        try await legacyStore.upsertMemory(LongTermMemory(
            conversationID: conversation.id,
            summary: "旧版长期记忆：用户叫小林"
        ))

        // 没有注入 characters/memoryEngine：完全走旧路径。
        let engine = ChatEngine(memory: legacyStore, aiClient: aiClient)
        let context = await engine.buildPromptContext(
            conversation: conversation,
            incoming: incoming,
            settings: .default,
            persona: template,
            provider: makeProvider(),
            history: []
        )
        XCTAssertNil(context.characterID)
        XCTAssertEqual(context.personaPrompt, "全局人格模板提示词")
        XCTAssertNil(context.speakerIdentity)
        let memoryPrompt = try XCTUnwrap(context.memoryPrompt)
        XCTAssertTrue(memoryPrompt.hasPrefix("相关历史记忆（仅供参考，不要逐字复述）："))
        XCTAssertTrue(memoryPrompt.contains("旧版长期记忆：用户叫小林"))

        // 旧入口仍按存量行为：模板正文 + 旧标题包装。
        let messages = engine.buildMessages(
            conversation: conversation,
            incoming: incoming,
            settings: .default,
            persona: template,
            history: [],
            memoryNotes: "旧版长期记忆：用户叫小林"
        )
        let system = try XCTUnwrap(messages.first?.content)
        XCTAssertTrue(system.contains("全局人格模板提示词"))
        XCTAssertTrue(system.contains(
            "相关历史记忆（仅供参考，不要逐字复述）：\n旧版长期记忆：用户叫小林"))
    }

    // MARK: Prompt assembly

    func testBuildMessagesInjectsV2MemoryPromptVerbatimAndIdentityLast() throws {
        let group = Conversation(id: groupID, kind: .group, title: "测试群")
        let incoming = makeIncoming(
            conversation: group, text: "在吗",
            senderID: "wxid_member_a", senderName: "群友甲")
        let engine = ChatEngine(memory: legacyStore, aiClient: aiClient)
        let recallPrompt = """
        记忆上下文（最近/重要/相关；已被取代的记忆不注入）：
        - [事实] 用户喜欢猫
        - [事实·最近·重要度 6] 用户喜欢猫
        """
        let identity = "【本轮发言人身份】群友甲（wxid_member_a）在长期记忆中的称呼是："
            + "群友甲 / 别名甲；优先使用「群友甲」。"
        let messages = engine.buildMessages(
            conversation: group,
            incoming: incoming,
            settings: .default,
            personaPrompt: "人格设定正文提示词",
            history: [],
            memoryPrompt: recallPrompt,
            speakerIdentity: identity
        )
        let system = try XCTUnwrap(messages.first?.content)
        XCTAssertTrue(system.hasPrefix("人格设定正文提示词"))
        XCTAssertTrue(system.contains(recallPrompt), "v2 记忆段应原样注入")
        XCTAssertEqual(system.components(separatedBy: "记忆上下文").count, 2,
                       "MemoryEngine 已带标题，不能双重包装")
        XCTAssertFalse(system.contains("相关历史记忆（仅供参考"))
        XCTAssertTrue(system.hasSuffix(identity), "身份硬约束必须放在 system 末尾")
    }

    // MARK: Speaker identity (CharacterMemory)

    func testSpeakerIdentityNoteUsesCharacterMemoryMappings() throws {
        let group = Conversation(id: groupID, kind: .group, title: "测试群")
        let memories = [
            // 置顶事实记忆：权威 wxid→称呼 映射。
            CharacterMemory(
                characterID: groupID,
                category: .fact,
                content: "群聊人员：\nwxid_member_b：测试群友乙/别名乙\n"
                    + "wxid_member_a：群友甲/别名甲",
                importance: 8,
                pinned: true,
                source: .manual
            ),
            // 已归档 / 已被取代的映射不能参与身份约束。
            CharacterMemory(
                characterID: groupID,
                category: .fact,
                content: "wxid_member_a：过期旧称呼",
                importance: 8,
                pinned: true,
                archived: true,
                source: .extraction
            ),
            CharacterMemory(
                characterID: groupID,
                category: .fact,
                kind: .important,
                content: "wxid_member_a：被取代的旧称呼",
                importance: 8,
                supersededBy: "newer-memory-id",
                source: .extraction
            )
        ]

        let memberA = makeIncoming(
            conversation: group, text: "在吗",
            senderID: "wxid_member_a", senderName: "群友甲")
        let note = try XCTUnwrap(ChatEngine.speakerIdentityNote(
            conversation: group, incoming: memberA, memories: memories))
        XCTAssertTrue(note.contains("群友甲"))
        XCTAssertTrue(note.contains("wxid_member_a"))
        XCTAssertTrue(note.contains("别名甲"))
        XCTAssertTrue(note.contains("优先使用「群友甲」"))
        XCTAssertTrue(note.contains("不要附和"))
        XCTAssertFalse(note.contains("测试群友乙"), "不能把另一个人的称呼写进本轮身份约束")
        XCTAssertFalse(note.contains("过期旧称呼"), "归档记忆不参与身份映射")
        XCTAssertFalse(note.contains("被取代的旧称呼"), "已被取代的记忆不参与身份映射")

        // 未收录的发言人：明确要求不要套用他人称呼。
        let unknown = makeIncoming(
            conversation: group, text: "在吗",
            senderID: "wxid_member_c", senderName: "群友丙")
        let unknownNote = try XCTUnwrap(ChatEngine.speakerIdentityNote(
            conversation: group, incoming: unknown, memories: memories))
        XCTAssertTrue(unknownNote.contains("不在长期记忆的人员对应表中"))
        XCTAssertTrue(unknownNote.contains("不要套用"))

        // 未置顶的普通 fact 记忆也参与映射（§8.2 的 fact 来源）。
        let withFact = memories + [CharacterMemory(
            characterID: groupID,
            category: .fact,
            content: "wxid_member_c：群友丙/小丙",
            importance: 3,
            source: .extraction
        )]
        let factNote = try XCTUnwrap(ChatEngine.speakerIdentityNote(
            conversation: group, incoming: unknown, memories: withFact))
        XCTAssertTrue(factNote.contains("小丙"))

        // 私聊不强行注入身份约束。
        let direct = Conversation(id: directID, kind: .direct, title: "私聊")
        XCTAssertNil(ChatEngine.speakerIdentityNote(
            conversation: direct, incoming: memberA, memories: memories))
    }

    func testV2GroupContextInjectsIdentityFromMemoryCard() async throws {
        let group = Conversation(id: groupID, kind: .group, title: "测试群")
        let incoming = makeIncoming(
            conversation: group, text: "在吗",
            senderID: "wxid_member_a", senderName: "群友甲")
        let template = makeTemplate(prompt: "人格模板正文")
        var settings = AppSettings.default
        settings.bot.memory = MemorySettings()

        try await characters.ensureCharacter(
            conversation: group,
            persona: template,
            activationTimestamp: incoming.timestamp
        )
        try await characters.upsertMemory(CharacterMemory(
            characterID: group.id,
            category: .fact,
            kind: .important,
            content: "wxid_member_a：群友甲/别名甲",
            importance: 9,
            pinned: true,
            source: .manual
        ))

        let engine = makeV2Engine()
        let context = await engine.buildPromptContext(
            conversation: group,
            incoming: incoming,
            settings: settings,
            persona: template,
            provider: makeProvider()
        )
        let identity = try XCTUnwrap(context.speakerIdentity)
        XCTAssertTrue(identity.contains("群友甲（wxid_member_a）"))
        XCTAssertTrue(identity.contains("别名甲"))
        XCTAssertNotNil(context.memoryPrompt, "记忆卡应召回置顶/事实记忆")

        let messages = engine.buildMessages(
            conversation: group,
            incoming: incoming,
            settings: settings,
            personaPrompt: context.personaPrompt,
            history: [],
            memoryPrompt: context.memoryPrompt,
            speakerIdentity: context.speakerIdentity
        )
        let system = try XCTUnwrap(messages.first?.content)
        XCTAssertTrue(system.contains("记忆上下文"))
        XCTAssertEqual(system.components(separatedBy: "记忆上下文").count, 2)
        XCTAssertTrue(system.hasSuffix(identity))
    }
}

// MARK: - Test log capture

/// 线程安全的日志收集器：ChatEngine 的 onLog 可能从任意执行器回调。
private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(level: LogLevel, message: String)] = []

    func append(_ level: LogLevel, _ message: String) {
        lock.lock()
        entries.append((level, message))
        lock.unlock()
    }

    func messages(level: LogLevel) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.level == level }.map(\.message)
    }
}
