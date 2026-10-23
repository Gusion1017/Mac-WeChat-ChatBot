import AppKit
import SQLite3
import XCTest

@testable import WeChatAI

/// 识图（视觉模型，2026-10-23）：
/// 设置解码兼容 / 通道与模型回退 / 多模态请求体 / 候选筛选 / 图片编码 /
/// 提示词注入 / `image_description` 持久化与旧库迁移。
final class VisionTests: XCTestCase {
    // MARK: - 1. 设置

    func testLegacyConfigWithoutVisionDecodesAsDisabled() throws {
        // 旧配置的 `ai` 里没有 vision 键：必须解码成 nil（关闭），不能整份配置失败。
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any]
        )
        var ai = try XCTUnwrap(object["ai"] as? [String: Any])
        ai.removeValue(forKey: "vision")
        object["ai"] = ai

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertNil(decoded.ai.vision)
        XCTAssertFalse(decoded.isVisionEnabled)
        XCTAssertEqual(decoded.visionProvider?.id, decoded.defaultProvider?.id)
        XCTAssertEqual(
            decoded.visionProvider.map { decoded.visionModel(for: $0) },
            decoded.defaultProvider.map { AIClient.effectiveModel(for: $0) }
        )
    }

    func testVisionSettingsRoundtripAndFallbacks() throws {
        var settings = AppSettings.default
        let base = try XCTUnwrap(settings.providers.first)
        var visionProvider = AIProvider(
            id: "provider-vision",
            name: "Vision",
            kind: .custom,
            baseURL: "https://vision.example/v1",
            model: "qwen-vl-max",
            apiKeyReference: "provider-vision",
            temperature: 0.2,
            maxTokens: 2_000,
            timeoutSeconds: 120,
            stream: true,
            enabled: true
        )
        visionProvider.isDefault = false
        settings.providers.append(visionProvider)
        settings.ai.vision = VisionSettings(
            enabled: true,
            providerID: "provider-vision",
            model: "  gpt-4o-mini  ",
            prompt: "  "
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.isVisionEnabled)
        XCTAssertEqual(decoded.ai.vision?.providerID, "provider-vision")
        XCTAssertEqual(decoded.ai.vision?.modelOverride, "gpt-4o-mini")
        XCTAssertEqual(decoded.ai.vision?.promptText, VisionSettings.defaultPrompt)

        let provider = try XCTUnwrap(decoded.visionProvider)
        XCTAssertEqual(provider.id, "provider-vision")
        XCTAssertEqual(decoded.visionModel(for: provider), "gpt-4o-mini")
        let requestProvider = decoded.visionRequestProvider(from: provider)
        XCTAssertEqual(requestProvider.model, "gpt-4o-mini")
        XCTAssertFalse(requestProvider.stream)
        XCTAssertLessThanOrEqual(requestProvider.timeoutSeconds, AppSettings.visionTimeoutSeconds)
        XCTAssertLessThanOrEqual(requestProvider.maxTokens, AppSettings.visionMaxTokens)

        // 覆盖值留空 → 跟随通道模型；通道 ID 失效 → 回退默认通道。
        settings.ai.vision?.model = ""
        XCTAssertNil(settings.ai.vision?.modelOverride)
        XCTAssertEqual(settings.visionModel(for: base), AIClient.effectiveModel(for: base))
        settings.ai.vision?.providerID = "missing-provider"
        XCTAssertEqual(settings.visionProvider?.id, settings.defaultProvider?.id)
    }

    // MARK: - 2. AIClient 多模态请求体

    func testMultimodalRequestBodyUsesOpenAIContentParts() throws {
        let provider = AIProvider(
            name: "Vision",
            kind: .custom,
            baseURL: "https://vision.example/v1",
            model: "qwen-vl-max",
            maxTokens: 300,
            timeoutSeconds: 20,
            stream: false
        )
        let dataURL = "data:image/jpeg;base64,AAAA"
        let body = try AIClient.requestBody(
            messages: [
                .system("系统提示"),
                .user("描述这张图片", images: [dataURL])
            ],
            provider: provider,
            stream: false
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "qwen-vl-max")
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, "系统提示")
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "描述这张图片")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let image = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(image["url"] as? String, dataURL)

        // 纯文本请求保持字符串 content（向后兼容）。
        let textBody = try AIClient.requestBody(
            messages: [.user("hello")],
            provider: provider,
            stream: false
        )
        let textObject = try XCTUnwrap(JSONSerialization.jsonObject(with: textBody) as? [String: Any])
        let textMessages = try XCTUnwrap(textObject["messages"] as? [[String: Any]])
        XCTAssertEqual(textMessages[0]["content"] as? String, "hello")
        XCTAssertNil(textObject["thinking"])
    }

    func testDeepSeekVisionRequestBodyDisablesThinking() throws {
        // deepseek-flash 默认 thinking=enabled；识图必须显式关闭，避免推理把
        // max_tokens 用完后 content 为空（2026-10-23「AI 返回了空内容」）。
        let deepseek = AIProvider(
            name: "DeepSeek",
            kind: .deepSeek,
            baseURL: ProviderKind.deepSeek.defaultBaseURL,
            model: "deepseek-flash",
            maxTokens: 800,
            timeoutSeconds: 30,
            stream: false
        )
        let body = try AIClient.requestBody(
            messages: [.user("描述这张图片", images: ["data:image/jpeg;base64,AAAA"])],
            provider: deepseek,
            stream: false,
            thinking: VisionSupport.thinkingMode(for: deepseek)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try XCTUnwrap(object["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "disabled")

        // 非 DeepSeek 通道不发送该扩展字段，避免严格 OpenAI 端点报未知参数。
        let openAI = AIProvider(
            name: "OpenAI",
            kind: .openAI,
            baseURL: ProviderKind.openAI.defaultBaseURL,
            model: "gpt-4o-mini"
        )
        XCTAssertNil(VisionSupport.thinkingMode(for: openAI))
        let openAIBody = try AIClient.requestBody(
            messages: [.user("hello")],
            provider: openAI,
            stream: false,
            thinking: VisionSupport.thinkingMode(for: openAI)
        )
        let openAIObject = try XCTUnwrap(JSONSerialization.jsonObject(with: openAIBody) as? [String: Any])
        XCTAssertNil(openAIObject["thinking"])

        // 自定义域名里带 deepseek 的通道同样关闭思考。
        let proxy = AIProvider(
            name: "Proxy",
            kind: .custom,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-flash"
        )
        XCTAssertEqual(VisionSupport.thinkingMode(for: proxy), .disabled)
    }

    // MARK: - 3. 候选与描述清洗

    private func imageMessage(
        id: String,
        at date: Date,
        messageKind: MessageKind = .image,
        direction: ChatDirection = .incoming,
        description: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationID: "c1",
            senderID: "wxid_test",
            senderName: "测试",
            direction: direction,
            kind: messageKind,
            text: "",
            imageDescription: description,
            timestamp: date
        )
    }

    func testCandidatesFilterAndLimit() {
        let now = Date()
        let messages: [ChatMessage] = [
            imageMessage(id: "recent-old", at: now.addingTimeInterval(-120)),
            imageMessage(id: "stale", at: now.addingTimeInterval(-900)),
            imageMessage(id: "text", at: now, messageKind: .text),
            imageMessage(id: "outgoing", at: now.addingTimeInterval(-10), direction: .outgoing),
            imageMessage(id: "recognized", at: now.addingTimeInterval(-5), description: "一只猫"),
            imageMessage(id: "recent-new", at: now.addingTimeInterval(-30)),
            imageMessage(id: "recent-newest", at: now.addingTimeInterval(-1))
        ]
        let candidates = VisionSupport.candidates(in: messages, now: now, limit: 2)
        XCTAssertEqual(candidates.map(\.id), ["recent-newest", "recent-new"])

        XCTAssertTrue(VisionSupport.isRecognizable(
            imageMessage(id: "x", at: now.addingTimeInterval(-300)), now: now
        ))
        XCTAssertFalse(VisionSupport.isRecognizable(
            imageMessage(id: "x", at: now.addingTimeInterval(-601)), now: now
        ))
        XCTAssertTrue(VisionSupport.candidates(in: messages, now: now, limit: 0).isEmpty)
    }

    func testNormalizedDescription() {
        XCTAssertEqual(
            VisionSupport.normalizedDescription("  一张\n桌子上  放着咖啡\n\n和书  "),
            "一张 桌子上 放着咖啡 和书"
        )
        XCTAssertEqual(VisionSupport.normalizedDescription("\"一只橘猫\""), "一只橘猫")
        XCTAssertEqual(VisionSupport.normalizedDescription("“窗外的雪景”"), "窗外的雪景")
        XCTAssertNil(VisionSupport.normalizedDescription(" \n\t "))
        XCTAssertNil(VisionSupport.normalizedDescription("\"\""))

        let long = String(repeating: "字", count: 500)
        let capped = try? XCTUnwrap(VisionSupport.normalizedDescription(long))
        XCTAssertEqual(capped?.count, VisionSupport.maxDescriptionCharacters + 1) // + 省略号
        XCTAssertTrue(capped?.hasSuffix("…") ?? false)
    }

    func testRequestMessagesFallbackPrompt() {
        let messages = VisionSupport.requestMessages(prompt: "   ", imageDataURL: "data:image/jpeg;base64,AA")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, VisionSettings.defaultPrompt)
        XCTAssertEqual(messages[0].imageURLs, ["data:image/jpeg;base64,AA"])
    }

    func testQuotedImageNote() {
        XCTAssertEqual(
            VisionSupport.quotedImageNote(description: " 一只橘猫趴在键盘上 "),
            "（引用图片内容：一只橘猫趴在键盘上）"
        )
        XCTAssertEqual(
            VisionSupport.quotedImageNote(description: nil),
            "（引用的图片内容暂不可用）"
        )
        XCTAssertEqual(
            VisionSupport.quotedImageNote(description: "   "),
            "（引用的图片内容暂不可用）"
        )
    }

    // MARK: - 4. 图片编码

    func testImageDataURLReencodesPNGAsJPEG() throws {
        // 1x1 透明 PNG。
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let png = try XCTUnwrap(Data(base64Encoded: pngBase64))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-vision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.png")
        try png.write(to: file)

        let dataURL = try VisionSupport.imageDataURL(forFileAt: file.path)
        XCTAssertTrue(dataURL.hasPrefix("data:image/jpeg;base64,"))
        let encoded = try XCTUnwrap(Data(base64Encoded: String(dataURL.dropFirst("data:image/jpeg;base64,".count))))
        XCTAssertGreaterThan(encoded.count, 2)
        XCTAssertEqual(Array(encoded.prefix(3)), [0xFF, 0xD8, 0xFF])

        XCTAssertThrowsError(try VisionSupport.imageDataURL(forFileAt: ""))
        XCTAssertThrowsError(try VisionSupport.imageDataURL(forFileAt: directory.appendingPathComponent("missing.jpg").path))
    }

    // MARK: - 5. 提示词

    func testChatEnginePromptTextIncludesImageDescription() {
        let now = Date()
        let recognized = ChatMessage(
            id: "img",
            conversationID: "c1",
            senderID: "u",
            senderName: "用户",
            direction: .incoming,
            kind: .image,
            text: "",
            imageDescription: "一张会议白板的照片",
            timestamp: now
        )
        XCTAssertEqual(ChatEngine.promptText(for: recognized), "[图片：一张会议白板的照片]")

        var plain = recognized
        plain.imageDescription = "   "
        XCTAssertEqual(ChatEngine.promptText(for: plain), "[图片]")

        var captioned = recognized
        captioned.text = "[图片]"
        XCTAssertEqual(
            ChatEngine.promptText(for: captioned),
            "[图片]\n[图片：一张会议白板的照片]"
        )

        var text = recognized
        text.kind = .text
        text.text = "普通文本"
        text.imageDescription = "不应出现"
        XCTAssertEqual(ChatEngine.promptText(for: text), "普通文本")
    }

    // MARK: - 6. 持久化与旧库迁移

    func testMemoryStorePersistsImageDescription() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-vision-db-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("chatbot.sqlite")
        let store = MemoryStore(databaseURL: file)
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "测试"))
        let message = ChatMessage(
            id: "m-img",
            conversationID: "c1",
            senderID: "u1",
            senderName: "用户",
            direction: .incoming,
            kind: .image,
            text: "",
            mediaPath: "/tmp/a.jpg",
            imageDescription: "一只趴在键盘上的猫",
            timestamp: Date()
        )
        try await store.upsertMessages([message])

        let page = try await store.fetchMessages(conversationID: "c1")
        XCTAssertEqual(page.first?.imageDescription, "一只趴在键盘上的猫")
        let fetched = try await store.message(id: "m-img")
        XCTAssertEqual(fetched?.imageDescription, "一只趴在键盘上的猫")
        let latest = try await store.fetchLatestMessages(conversationIDs: ["c1"])
        XCTAssertEqual(latest["c1"]?.first?.imageDescription, "一只趴在键盘上的猫")

        // 更新后写回（例如重新识图）也走同一 upsert。
        var changed = message
        changed.imageDescription = "新的描述"
        try await store.upsertMessages([changed])
        let updated = try await store.message(id: "m-img")
        XCTAssertEqual(updated?.imageDescription, "新的描述")
        await store.close()

        let reopened = MemoryStore(databaseURL: file)
        try await reopened.open()
        defer { Task { await reopened.close() } }
        let persisted = try await reopened.message(id: "m-img")
        XCTAssertEqual(persisted?.imageDescription, "新的描述")
    }

    func testLegacyMessagesTableGetsImageDescriptionColumn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-vision-migrate-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("chatbot.sqlite")
        let store = MemoryStore(databaseURL: file)
        try await store.open()
        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "测试"))
        try await store.upsertMessages([ChatMessage(
            id: "m1",
            conversationID: "c1",
            senderID: "u1",
            senderName: "用户",
            direction: .incoming,
            kind: .image,
            text: "",
            mediaPath: "/tmp/a.jpg",
            imageDescription: "旧描述",
            timestamp: Date()
        )])
        await store.close()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 模拟旧库：删掉后加列。SQLite 3.35+ 支持 DROP COLUMN（macOS 自带版本满足）。
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        let dropResult = sqlite3_exec(handle, "ALTER TABLE messages DROP COLUMN image_description;", nil, nil, nil)
        sqlite3_close(handle)
        if dropResult != SQLITE_OK {
            throw XCTSkip("当前 SQLite 不支持 DROP COLUMN，跳过旧库迁移子测试")
        }

        let reopened = MemoryStore(databaseURL: file)
        try await reopened.open()
        defer { Task { await reopened.close() } }
        let legacy = try await reopened.message(id: "m1")
        XCTAssertNotNil(legacy)
        XCTAssertNil(legacy?.imageDescription)
        XCTAssertEqual(legacy?.mediaPath, "/tmp/a.jpg")

        // 列被补回后仍可写识图描述。
        var recognized = try XCTUnwrap(legacy)
        recognized.imageDescription = "迁移后识别"
        try await reopened.upsertMessages([recognized])
        let migrated = try await reopened.message(id: "m1")
        XCTAssertEqual(migrated?.imageDescription, "迁移后识别")
    }
}
