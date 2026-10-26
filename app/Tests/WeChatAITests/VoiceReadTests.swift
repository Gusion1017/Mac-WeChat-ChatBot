import SQLite3
import XCTest

@testable import WeChatAI

/// 入站语音（T2，2026-10-26）：
/// 转写清洗/静音门限/segment 解析/fetch_voice 契约/设置迁移/会话覆盖/
/// 空库迁移/提示词格式/语音回复决策。
final class VoiceReadTests: XCTestCase {
    // MARK: - 1. 文本清洗

    func testCleanTranscriptCollapsesWhitespaceAndPunctuationSpaces() {
        XCTAssertEqual(
            VoiceTranscriptionService.cleanTranscript("  你 好 ， 世 界 ！  "),
            "你 好，世 界！"
        )
        XCTAssertEqual(
            VoiceTranscriptionService.cleanTranscript("第一行\n第二行\t第三行"),
            "第一行 第二行 第三行"
        )
        XCTAssertEqual(
            VoiceTranscriptionService.cleanTranscript("「 引号 」 【 括号 】 《 书名 》"),
            "「引号」【括号】《书名》"
        )
        XCTAssertEqual(VoiceTranscriptionService.cleanTranscript("   "), "")
    }

    func testCleanTranscriptKeepsEnglishSpacingAfterPunctuation() {
        XCTAssertEqual(
            VoiceTranscriptionService.cleanTranscript("hello , world !"),
            "hello, world!"
        )
        XCTAssertEqual(
            VoiceTranscriptionService.cleanTranscript("a  b   c"),
            "a b c"
        )
    }

    // MARK: - 2. 静音门限 / 低置信度 / 标签

    func testSilenceGateRequiresBothLowConfidenceAndShortDuration() {
        // 短 + 低置信度 → 静音/幻觉。
        XCTAssertTrue(VoiceTranscriptionService.isLikelySilence(
            text: "谢谢观看",
            maxConfidence: 0.12,
            duration: 1.2
        ))
        // 低置信度但足够长：可能是轻声说话，保留。
        XCTAssertFalse(VoiceTranscriptionService.isLikelySilence(
            text: "今天天气不错",
            maxConfidence: 0.2,
            duration: 3.0
        ))
        // 短但置信度高：保留。
        XCTAssertFalse(VoiceTranscriptionService.isLikelySilence(
            text: "在吗",
            maxConfidence: 0.9,
            duration: 0.8
        ))
        // 空文本一律视为无内容。
        XCTAssertTrue(VoiceTranscriptionService.isLikelySilence(
            text: "  ",
            maxConfidence: 1,
            duration: 5
        ))
    }

    func testLowConfidenceThreshold() {
        XCTAssertTrue(VoiceTranscriptionService.isLowConfidence(0.3))
        XCTAssertFalse(VoiceTranscriptionService.isLowConfidence(0.6))
        XCTAssertFalse(VoiceTranscriptionService.isLowConfidence(nil))
        XCTAssertFalse(VoiceTranscriptionService.isLowConfidence(.nan))
    }

    func testVoiceLabelFormatting() {
        XCTAssertEqual(VoiceTranscriptionService.voiceLabel(durationMs: nil), "[语音]")
        XCTAssertEqual(VoiceTranscriptionService.voiceLabel(durationMs: 0), "[语音]")
        XCTAssertEqual(VoiceTranscriptionService.voiceLabel(durationMs: 400), "[语音 1s]")
        XCTAssertEqual(VoiceTranscriptionService.voiceLabel(durationMs: 4_600), "[语音 5s]")
        XCTAssertEqual(VoiceTranscriptionService.voiceLabel(durationMs: 30_400), "[语音 30s]")
    }

    // MARK: - 3. OneBotSegment / OneBotEvent 解析

    func testVoiceSegmentParsing() throws {
        let raw: [String: Any] = [
            "self_id": "wxid_self",
            "user_id": "wxid_peer",
            "message_id": "9001",
            "message_type": "private",
            "time": 1_700_000_000,
            "sender": ["user_id": "wxid_peer", "nickname": "好友"],
            "message": [
                ["type": "voice", "data": ["duration_ms": 5_200]]
            ]
        ]
        let event = try XCTUnwrap(OneBotEventParser.parseEvent(raw, rawText: nil))
        XCTAssertEqual(event.primaryMessageKind, .voice)
        XCTAssertEqual(event.voiceDurationMs, 5_200)
        XCTAssertEqual(event.plainText, "[语音]")
        XCTAssertNil(event.mediaPath, "语音段没有文件，不能走图片的 mediaPath")
        XCTAssertEqual(event.primaryMediaSegment?.durationMs, 5_200)
    }

    func testLegacyRecordSegmentStillParsesAsVoice() throws {
        // 旧 bridge/旧 hook 用 `record` 类型；兼容解析为语音但时长可能缺失。
        let raw: [String: Any] = [
            "self_id": "wxid_self",
            "user_id": "wxid_peer",
            "message_id": "9002",
            "time": 1_700_000_000,
            "message": [["type": "record", "data": [:]]]
        ]
        let event = try XCTUnwrap(OneBotEventParser.parseEvent(raw, rawText: nil))
        XCTAssertEqual(event.primaryMessageKind, .voice)
        XCTAssertNil(event.voiceDurationMs)
        XCTAssertEqual(event.plainText, "[语音]")
    }

    func testVoiceSegmentIgnoresInvalidDuration() throws {
        let raw: [String: Any] = [
            "self_id": "s",
            "user_id": "u",
            "message_id": "1",
            "time": 1_700_000_000,
            "message": [["type": "voice", "data": ["duration_ms": "0"]]]
        ]
        let event = try XCTUnwrap(OneBotEventParser.parseEvent(raw, rawText: nil))
        XCTAssertNil(event.voiceDurationMs, "0/负时长视为未提供")
    }

    // MARK: - 4. VoiceFetchPolicy

    func testVoiceFetchPolicy() {
        func should(
            kind: MessageKind = .voice,
            enabled: Bool = true,
            isSelf: Bool = false,
            messageID: String = "42",
            voiceMediaPath: String? = nil,
            mediaPath: String? = nil
        ) -> Bool {
            VoiceFetchPolicy.shouldFetch(
                kind: kind,
                enabled: enabled,
                isSelf: isSelf,
                messageID: messageID,
                voiceMediaPath: voiceMediaPath,
                mediaPath: mediaPath
            )
        }

        XCTAssertTrue(should())
        XCTAssertFalse(should(enabled: false), "关闭转写后不请求")
        XCTAssertFalse(should(isSelf: true), "自己发出的语音不请求")
        XCTAssertFalse(should(kind: .text), "非语音不请求")
        XCTAssertFalse(should(messageID: ""), "缺少 message_id 不请求")
        XCTAssertFalse(should(voiceMediaPath: "/tmp/a.wav"), "已有语音文件不重复请求")
        XCTAssertFalse(should(mediaPath: "/tmp/a.wav"), "mediaPath 已有文件不再请求")
        XCTAssertTrue(should(voiceMediaPath: ""), "空字符串不阻止获取")
    }

    // MARK: - 5. POST /fetch_voice 契约

    func testFetchVoiceRequest() throws {
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:58080"))
        let request = try OneBotClient.fetchVoiceRequest(
            baseURL: base,
            token: "token-1",
            messageID: "123456"
        )
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:58080/fetch_voice")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["message_id"] as? String, "123456")

        let noToken = try OneBotClient.fetchVoiceRequest(baseURL: base, token: "", messageID: "1")
        XCTAssertNil(noToken.value(forHTTPHeaderField: "Authorization"))
    }

    func testParseVoiceFetchResponseTopLevelShape() throws {
        let data = Data(#"""
        {"ok":true,"path":"file:///tmp/voice_a%20b_16k.wav","silk_path":"file:///tmp/voice_a.silk","duration_ms":5200}
        """#.utf8)
        let payload = try OneBotClient.parseVoiceFetchResponse(data: data, statusCode: 200)
        XCTAssertEqual(payload.path, "/tmp/voice_a b_16k.wav")
        XCTAssertEqual(payload.silkPath, "/tmp/voice_a.silk")
        XCTAssertEqual(payload.durationMs, 5_200)
    }

    func testParseVoiceFetchResponseOneBotWrappedShape() throws {
        let data = Data(#"{"status":"ok","data":{"path":"/tmp/plain.wav","duration_ms":"4200"}}"#.utf8)
        let payload = try OneBotClient.parseVoiceFetchResponse(data: data, statusCode: 200)
        XCTAssertEqual(payload.path, "/tmp/plain.wav")
        XCTAssertNil(payload.silkPath)
        XCTAssertEqual(payload.durationMs, 4_200, "字符串毫秒数也应解析")
    }

    func testParseVoiceFetchResponseSurfacesBridgeError() {
        let data = Data(#"{"ok":false,"error":"voice download timeout"}"#.utf8)
        XCTAssertThrowsError(try OneBotClient.parseVoiceFetchResponse(data: data, statusCode: 200)) { error in
            XCTAssertTrue(error.localizedDescription.contains("voice download timeout"))
        }
    }

    func testParseVoiceFetchResponseHintsBridgeUpdateOn404() {
        let data = Data(#"{"ok":false,"error":"not found"}"#.utf8)
        XCTAssertThrowsError(try OneBotClient.parseVoiceFetchResponse(data: data, statusCode: 404)) { error in
            XCTAssertTrue(error.localizedDescription.contains("不支持语音获取"))
            XCTAssertTrue(error.localizedDescription.contains("更新 bridge"))
        }
    }

    func testParseVoiceFetchResponseRejectsMissingPath() {
        let data = Data(#"{"ok":true}"#.utf8)
        XCTAssertThrowsError(try OneBotClient.parseVoiceFetchResponse(data: data, statusCode: 200))
    }

    // MARK: - 6. VoiceFetcher 队列（串行 + 去重 + 重试 1 次）

    @MainActor
    func testVoiceFetcherRetriesOnceThenSucceeds() async throws {
        let fetcher = VoiceFetcher()
        let idle = VoiceIdleSignal()
        var attempts = 0
        var fetched: [(String, String)] = []
        var failures: [String] = []

        fetcher.configure(
            fetch: { _ in
                attempts += 1
                if attempts == 1 { throw OneBotError.badResponse("voice not ready") }
                return VoiceFetchResult(path: "/tmp/voice.wav", silkPath: nil, durationMs: 3_000)
            },
            onFetched: { request, result in
                fetched.append((request.chatMessageID, result.path))
            },
            onFailed: { request, reason in
                failures.append("\(request.chatMessageID):\(reason)")
            },
            onIdle: { idle.signal() }
        )

        let request = VoiceFetcher.Request(
            bridgeMessageID: "m1",
            chatMessageID: "ob-m1",
            conversationID: "wxid_test"
        )
        XCTAssertTrue(fetcher.enqueue(request))
        XCTAssertEqual(fetcher.pendingCount, 1)
        try await idle.wait()

        XCTAssertEqual(attempts, 2, "首次失败后应自动重试 1 次")
        XCTAssertEqual(fetched.map(\.0), ["ob-m1"])
        XCTAssertEqual(fetched.map(\.1), ["/tmp/voice.wav"])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fetcher.pendingCount, 0)
        XCTAssertFalse(fetcher.enqueue(request), "同一消息不再入队")
    }

    @MainActor
    func testVoiceFetcherReportsFailureAfterRetriesAndDeduplicates() async throws {
        let fetcher = VoiceFetcher()
        let idle = VoiceIdleSignal()
        var attempts = 0
        var failures: [String] = []

        fetcher.configure(
            fetch: { _ in
                attempts += 1
                throw OneBotError.badResponse("silk decode failed")
            },
            onFetched: { _, _ in XCTFail("不应成功") },
            onFailed: { request, reason in failures.append("\(request.chatMessageID):\(reason)") },
            onIdle: { idle.signal() }
        )

        let first = VoiceFetcher.Request(bridgeMessageID: "m1", chatMessageID: "ob-m1", conversationID: "c")
        let second = VoiceFetcher.Request(bridgeMessageID: "m2", chatMessageID: "ob-m2", conversationID: "c")
        XCTAssertTrue(fetcher.enqueue(first))
        XCTAssertTrue(fetcher.enqueue(second))
        XCTAssertFalse(fetcher.enqueue(first))
        try await idle.wait()

        XCTAssertEqual(attempts, 4, "每条消息各重试 1 次")
        XCTAssertEqual(failures.count, 2)
        XCTAssertTrue(failures.allSatisfy { $0.contains("silk decode failed") })

        // retry() 会忘掉失败记录并重新入队。
        XCTAssertTrue(fetcher.retry(first))
        try await idle.wait()
        XCTAssertEqual(failures.count, 3)
    }

    @MainActor
    func testVoiceFetcherCancelAllStopsCallbacks() async throws {
        let fetcher = VoiceFetcher()
        var fetched = 0
        fetcher.configure(
            fetch: { _ in
                try? await Task.sleep(nanoseconds: 20_000_000)
                return VoiceFetchResult(path: "/tmp/v.wav", silkPath: nil, durationMs: nil)
            },
            onFetched: { _, _ in fetched += 1 },
            onFailed: { _, _ in XCTFail("取消后不应回调失败") }
        )
        XCTAssertTrue(fetcher.enqueue(.init(bridgeMessageID: "m", chatMessageID: "ob-m", conversationID: "c")))
        fetcher.cancelAll()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(fetched, 0, "cancelAll 后不再更新消息")
    }

    // MARK: - 7. 设置迁移

    func testLegacyConfigWithoutVoiceDecodesDefaults() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any]
        )
        var bot = try XCTUnwrap(object["bot"] as? [String: Any])
        bot.removeValue(forKey: "voice")
        object["bot"] = bot

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertNil(decoded.bot.voice, "旧配置缺 voice 键必须保持 nil")
        XCTAssertEqual(decoded.bot.voiceSettings, VoiceSettings(), "生效值等于默认设置")
        XCTAssertTrue(decoded.bot.voiceTranscriptionEnabled)
        XCTAssertFalse(decoded.bot.voiceReplyEnabled)
    }

    func testPartialVoiceSettingsDecodesDefaultsAndClamps() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any]
        )
        var bot = try XCTUnwrap(object["bot"] as? [String: Any])
        bot["voice"] = [
            "replyEnabled": true,
            "replyProbability": 7.5,
            "maxVoiceSeconds": 999,
            "shortReplyMaxChars": 0,
            "kokoroSpeed": -2,
            "overLimit": "bogus",
            "engine": "unknown-engine"
        ]
        object["bot"] = bot

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        let voice = try XCTUnwrap(decoded.bot.voice)
        XCTAssertTrue(voice.replyEnabled)
        XCTAssertEqual(voice.effectiveReplyProbability, 1.0, "概率收敛到 0...1")
        XCTAssertEqual(voice.effectiveMaxVoiceSeconds, 60, "时长收敛到 5...60")
        XCTAssertEqual(voice.effectiveShortReplyMaxChars, 1)
        XCTAssertEqual(voice.effectiveKokoroSpeed, 0.5)
        XCTAssertEqual(voice.overLimit, .text, "未知枚举回退默认")
        XCTAssertEqual(voice.engine, .kokoro, "未知引擎回退默认")
        XCTAssertFalse(voice.modelDownloadConsent)
        XCTAssertTrue(voice.transcriptionEnabled, "缺失字段用默认值")
        XCTAssertEqual(voice.kokoroSpeakerID, 0)
    }

    func testVoiceSettingsRoundtrip() throws {
        var settings = AppSettings.default
        var voice = VoiceSettings()
        voice.transcriptionEnabled = false
        voice.showTranscriptInBubble = false
        voice.saveTranscriptToMemory = false
        voice.replyEnabled = true
        voice.replyProbability = 0.42
        voice.mirrorIncomingVoice = true
        voice.shortReplyOnly = false
        voice.shortReplyMaxChars = 120
        voice.maxVoiceSeconds = 45
        voice.overLimit = .truncate
        voice.engine = .zipvoiceClone
        voice.kokoroSpeakerID = 7
        voice.kokoroSpeed = 1.25
        voice.cloneID = "clone-1"
        voice.modelDownloadConsent = true
        settings.bot.voice = voice

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.bot.voice, voice)
    }

    // MARK: - 8. 会话覆盖

    func testConversationVoiceOverrides() {
        var conversation = Conversation(id: "c1", kind: .group, title: "群")
        XCTAssertNil(conversation.voiceTranscriptionEnabled)
        XCTAssertTrue(conversation.effectiveVoiceTranscriptionEnabled(global: true))
        XCTAssertFalse(conversation.effectiveVoiceReplyEnabled(global: false))
        XCTAssertEqual(conversation.effectiveVoiceReplyProbability(global: 0.3), 0.3, accuracy: 0.0001)

        conversation.voiceTranscriptionEnabled = false
        conversation.voiceReplyEnabled = true
        conversation.voiceReplyProbability = 0.85
        XCTAssertFalse(conversation.effectiveVoiceTranscriptionEnabled(global: true))
        XCTAssertTrue(conversation.effectiveVoiceReplyEnabled(global: false))
        XCTAssertEqual(conversation.effectiveVoiceReplyProbability(global: 0.1), 0.85, accuracy: 0.0001)
    }

    // MARK: - 9. 持久化与旧库迁移

    func testMemoryStorePersistsVoiceFields() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-voice-db-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("chatbot.sqlite")
        let store = MemoryStore(databaseURL: file)
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        var conversation = Conversation(id: "c1", kind: .direct, title: "测试")
        conversation.voiceTranscriptionEnabled = true
        conversation.voiceReplyEnabled = false
        conversation.voiceReplyProbability = 0.7
        try await store.upsertConversation(conversation)

        let message = ChatMessage(
            id: "m-voice",
            conversationID: "c1",
            senderID: "u1",
            senderName: "用户",
            direction: .incoming,
            kind: .voice,
            text: "你好呀",
            mediaPath: "/tmp/voice.wav",
            voiceMediaPath: "/tmp/voice.wav",
            voiceDurationMs: 4_600,
            voiceTranscript: "你好呀",
            voiceTranscriptConfidence: 0.87,
            voiceTranscriptState: .done,
            timestamp: Date()
        )
        try await store.upsertMessages([message])

        let fetched = try await store.message(id: "m-voice")
        XCTAssertEqual(fetched?.voiceMediaPath, "/tmp/voice.wav")
        XCTAssertEqual(fetched?.voiceDurationMs, 4_600)
        XCTAssertEqual(fetched?.voiceTranscript, "你好呀")
        XCTAssertEqual(fetched?.voiceTranscriptConfidence ?? 0, 0.87, accuracy: 0.0001)
        XCTAssertEqual(fetched?.voiceTranscriptState, .done)

        let page = try await store.fetchMessages(conversationID: "c1")
        XCTAssertEqual(page.first?.voiceTranscript, "你好呀")
        let latest = try await store.fetchLatestMessages(conversationIDs: ["c1"])
        XCTAssertEqual(latest["c1"]?.first?.voiceTranscriptState, .done)
        let hits = try await store.searchMessages(query: "你好")
        XCTAssertEqual(hits.first?.message.id, "m-voice", "转写写入 text 后应能被搜索")

        let storedConversation = try await store.conversation(id: "c1")
        XCTAssertEqual(storedConversation?.voiceTranscriptionEnabled, true)
        XCTAssertEqual(storedConversation?.voiceReplyEnabled, false)
        XCTAssertEqual(storedConversation?.voiceReplyProbability ?? 0, 0.7, accuracy: 0.0001)

        await store.close()
        let reopened = MemoryStore(databaseURL: file)
        try await reopened.open()
        defer { Task { await reopened.close() } }
        let persisted = try await reopened.message(id: "m-voice")
        XCTAssertEqual(persisted?.voiceTranscript, "你好呀")
    }

    func testFailInterruptedVoiceTranscripts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-voice-interrupted-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("chatbot.sqlite")
        let store = MemoryStore(databaseURL: file)
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "测试"))
        try await store.upsertMessages([ChatMessage(
            id: "m-pending",
            conversationID: "c1",
            senderID: "u1",
            senderName: "用户",
            direction: .incoming,
            kind: .voice,
            text: "",
            voiceTranscriptState: .pending,
            timestamp: Date()
        )])

        let repaired = try await store.failInterruptedVoiceTranscripts()
        XCTAssertEqual(repaired, 1)
        let message = try await store.message(id: "m-pending")
        XCTAssertEqual(message?.voiceTranscriptState, .failed, "启动后遗留 pending 应标失败以便重试")
        let secondPass = try await store.failInterruptedVoiceTranscripts()
        XCTAssertEqual(secondPass, 0, "幂等：没有 pending 时不再更新")
    }

    func testLegacyMessagesTableGetsVoiceColumns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-voice-migrate-\(UUID().uuidString)", isDirectory: true)
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
            kind: .voice,
            text: "旧转写",
            voiceMediaPath: "/tmp/old.wav",
            voiceDurationMs: 1_000,
            voiceTranscript: "旧转写",
            voiceTranscriptConfidence: 0.5,
            voiceTranscriptState: .done,
            timestamp: Date()
        )])
        await store.close()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 模拟旧库：删掉后加的语音列。
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        var dropFailed = false
        for column in [
            "voice_media_path", "voice_duration_ms", "voice_transcript",
            "voice_transcript_confidence", "voice_transcript_state"
        ] {
            if sqlite3_exec(handle, "ALTER TABLE messages DROP COLUMN \(column);", nil, nil, nil) != SQLITE_OK {
                dropFailed = true
                break
            }
        }
        sqlite3_close(handle)
        if dropFailed { throw XCTSkip("当前 SQLite 不支持 DROP COLUMN，跳过旧库迁移子测试") }

        let reopened = MemoryStore(databaseURL: file)
        try await reopened.open()
        defer { Task { await reopened.close() } }
        let legacy = try await reopened.message(id: "m1")
        XCTAssertNotNil(legacy)
        XCTAssertNil(legacy?.voiceTranscript, "旧库补列后为 NULL")
        XCTAssertNil(legacy?.voiceTranscriptState)
        XCTAssertEqual(legacy?.text, "旧转写")

        var updated = try XCTUnwrap(legacy)
        updated.voiceTranscript = "迁移后转写"
        updated.voiceTranscriptState = .failed
        try await reopened.upsertMessages([updated])
        let migrated = try await reopened.message(id: "m1")
        XCTAssertEqual(migrated?.voiceTranscript, "迁移后转写")
        XCTAssertEqual(migrated?.voiceTranscriptState, .failed)
    }

    func testLegacyConversationsTableGetsVoiceOverrideColumns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-voice-conv-migrate-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("chatbot.sqlite")
        let store = MemoryStore(databaseURL: file)
        try await store.open()
        var conversation = Conversation(id: "c1", kind: .direct, title: "测试")
        conversation.voiceReplyEnabled = true
        try await store.upsertConversation(conversation)
        await store.close()
        defer { try? FileManager.default.removeItem(at: directory) }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        var dropFailed = false
        for column in [
            "voice_transcription_enabled", "voice_reply_enabled", "voice_reply_probability"
        ] {
            if sqlite3_exec(handle, "ALTER TABLE conversations DROP COLUMN \(column);", nil, nil, nil) != SQLITE_OK {
                dropFailed = true
                break
            }
        }
        sqlite3_close(handle)
        if dropFailed { throw XCTSkip("当前 SQLite 不支持 DROP COLUMN，跳过旧库迁移子测试") }

        let reopened = MemoryStore(databaseURL: file)
        try await reopened.open()
        defer { Task { await reopened.close() } }
        let legacy = try await reopened.conversation(id: "c1")
        XCTAssertNotNil(legacy)
        XCTAssertNil(legacy?.voiceTranscriptionEnabled)
        XCTAssertNil(legacy?.voiceReplyEnabled)
        XCTAssertNil(legacy?.voiceReplyProbability)

        var updated = try XCTUnwrap(legacy)
        updated.voiceReplyProbability = 0.25
        try await reopened.upsertConversation(updated)
        let migrated = try await reopened.conversation(id: "c1")
        XCTAssertEqual(migrated?.voiceReplyProbability ?? 0, 0.25, accuracy: 0.0001)
    }

    // MARK: - 10. 提示词格式

    private func voiceMessage(
        transcript: String? = nil,
        confidence: Double? = nil,
        state: VoiceTranscriptState? = .done,
        durationMs: Int? = 5_000,
        text: String = ""
    ) -> ChatMessage {
        ChatMessage(
            id: "m",
            conversationID: "c",
            senderID: "u",
            senderName: "用户",
            direction: .incoming,
            kind: .voice,
            text: text,
            mediaPath: "/tmp/v.wav",
            voiceMediaPath: "/tmp/v.wav",
            voiceDurationMs: durationMs,
            voiceTranscript: transcript,
            voiceTranscriptConfidence: confidence,
            voiceTranscriptState: state,
            timestamp: Date()
        )
    }

    func testPromptTextFormatsVoiceTranscript() {
        XCTAssertEqual(
            ChatEngine.promptText(for: voiceMessage(transcript: "你在干什么", confidence: 0.9, durationMs: 4_000)),
            "[语音 4s] 你在干什么"
        )
        XCTAssertEqual(
            ChatEngine.promptText(for: voiceMessage(transcript: "明天见", confidence: 0.3, durationMs: 2_000)),
            "[语音 2s] 明天见（识别可能不准确）"
        )
        XCTAssertEqual(
            ChatEngine.promptText(for: voiceMessage(transcript: nil, state: .failed)),
            "[语音，转写失败]"
        )
        XCTAssertEqual(
            ChatEngine.promptText(for: voiceMessage(transcript: nil, state: .pending)),
            "[语音 5s]"
        )
        XCTAssertEqual(
            ChatEngine.promptText(for: voiceMessage(transcript: nil, state: .disabled)),
            "[语音 5s]"
        )
        XCTAssertEqual(
            ChatEngine.promptText(for: voiceMessage(transcript: nil, state: .done)),
            "[语音 5s]",
            "静音/无有效内容只留标签"
        )
        // 旧数据：转写写在 text 里，没有独立字段。
        XCTAssertEqual(
            ChatEngine.promptText(for: voiceMessage(transcript: nil, state: nil, text: "旧转写")),
            "[语音 5s] 旧转写"
        )
        // 桥接占位文本不能被当成转写内容。
        XCTAssertEqual(
            ChatEngine.promptText(for: voiceMessage(transcript: nil, state: .pending, text: "[语音]")),
            "[语音 5s]"
        )
    }

    func testPromptTextKeepsOutgoingVoiceUnlabelled() {
        // AI 自己的 TTS 语音回复也会进短期历史。如果它也带「[语音 Ns]」标注，
        // 模型会误以为这是自己的回复格式并照抄（真机复现：文字回复以「[语音 8s]」开头）。
        var spoken = voiceMessage(transcript: nil, state: .disabled, durationMs: 9_680, text: "@老大爷 我在呢")
        spoken.direction = .outgoing
        spoken.senderID = "self"
        spoken.senderName = "我"
        XCTAssertEqual(ChatEngine.promptText(for: spoken), "@老大爷 我在呢")

        // 自消息回显只有桥接占位「[语音]」：整条跳过，不能变成只有标注的 assistant 轮次。
        var echo = voiceMessage(transcript: nil, state: .disabled, durationMs: 9_680, text: "[语音]")
        echo.direction = .outgoing
        XCTAssertEqual(ChatEngine.promptText(for: echo), "")
    }

    func testTranscriptKeepsOutgoingVoiceTextWithoutLabel() {
        var spoken = voiceMessage(transcript: nil, state: .disabled, durationMs: 9_680, text: "我在呢")
        spoken.direction = .outgoing
        spoken.senderName = "我"
        let transcript = ChatEngine.transcript(for: [spoken], includeVoiceTranscripts: false)
        XCTAssertEqual(transcript, "我：我在呢", "AI 自己的语音回复不该以「[语音 Ns]」形式写进记忆")
        XCTAssertFalse(transcript.contains("[语音"))
    }

    func testStrippingVoiceAnnotationsFromReplyText() {
        XCTAssertEqual(ChatEngine.strippingVoiceAnnotations("[语音 8s] 好呀"), "好呀")
        XCTAssertEqual(ChatEngine.strippingVoiceAnnotations("[语音 8s]@AAA 好呀"), "@AAA 好呀")
        XCTAssertEqual(ChatEngine.strippingVoiceAnnotations("[语音] 好呀"), "好呀")
        XCTAssertEqual(ChatEngine.strippingVoiceAnnotations("[语音，转写失败] 好呀"), "好呀")
        XCTAssertEqual(ChatEngine.strippingVoiceAnnotations("［语音 8s］好呀"), "好呀")
        XCTAssertEqual(ChatEngine.strippingVoiceAnnotations("好呀[语音 12s]你在吗"), "好呀你在吗")
        XCTAssertEqual(ChatEngine.strippingVoiceAnnotations("[语音 8s]"), "")
        // 正常聊到「语音」或「8s」时不能被误删。
        XCTAssertEqual(ChatEngine.strippingVoiceAnnotations("我们聊聊语音吧"), "我们聊聊语音吧")
        XCTAssertEqual(ChatEngine.strippingVoiceAnnotations("语音 8s 也挺快的"), "语音 8s 也挺快的")
    }

    func testTranscriptExcludesVoiceTranscriptsWhenMemorySavingDisabled() {
        let message = voiceMessage(transcript: "这是一段不该进入长期记忆的转写", durationMs: 3_000)
        XCTAssertTrue(ChatEngine.transcript(for: [message]).contains("这是一段不该进入长期记忆的转写"))
        let without = ChatEngine.transcript(for: [message], includeVoiceTranscripts: false)
        XCTAssertFalse(without.contains("不该进入长期记忆"))
        XCTAssertTrue(without.contains("[语音 3s]"))
    }

    func testQuotedVoiceNote() {
        XCTAssertEqual(VoiceQuoteText.quotedVoiceNote(transcript: "晚上七点见"), "（引用语音内容：晚上七点见）")
        XCTAssertEqual(VoiceQuoteText.quotedVoiceNote(transcript: "  "), "（引用的语音转写暂不可用）")
        XCTAssertEqual(VoiceQuoteText.quotedVoiceNote(transcript: nil), "（引用的语音转写暂不可用）")
    }

    // MARK: - 11. 语音回复决策纯函数

    private func replyContext(
        global: VoiceSettings = VoiceSettings(),
        conversation: Conversation = Conversation(id: "c", kind: .direct, title: "测试"),
        incomingWasVoice: Bool = false,
        replyText: String = "好",
        modelsReady: Bool = true,
        rng: Double = 0.1
    ) -> VoiceReplyContext {
        VoiceReplyContext(
            global: global,
            conversation: conversation,
            incomingWasVoice: incomingWasVoice,
            replyText: replyText,
            modelsReady: modelsReady,
            rng: rng
        )
    }

    func testDecideVoiceReplyDisabledBySwitch() {
        // 默认关闭：即使 rng 命中也不发语音。
        XCTAssertFalse(decideVoiceReply(replyContext(rng: 0)).isVoice)
        var on = VoiceSettings()
        on.replyEnabled = true
        XCTAssertTrue(decideVoiceReply(replyContext(global: on, rng: 0.1)).isVoice)
    }

    func testDecideVoiceReplyConversationSwitchOverride() {
        // 全局关闭 + 会话显式开启：会话覆盖生效。
        var conversation = Conversation(id: "c", kind: .direct, title: "测试")
        conversation.voiceReplyEnabled = true
        XCTAssertTrue(decideVoiceReply(replyContext(conversation: conversation, rng: 0)).isVoice)

        // 全局开启 + 会话显式关闭：只发文字。
        var on = VoiceSettings()
        on.replyEnabled = true
        conversation.voiceReplyEnabled = false
        XCTAssertFalse(decideVoiceReply(replyContext(global: on, conversation: conversation, rng: 0)).isVoice)

        // nil = 跟随全局。
        conversation.voiceReplyEnabled = nil
        XCTAssertTrue(decideVoiceReply(replyContext(global: on, conversation: conversation, rng: 0)).isVoice)
    }

    func testDecideVoiceReplyModelsNotReady() {
        var on = VoiceSettings()
        on.replyEnabled = true
        on.replyProbability = 1
        let decision = decideVoiceReply(replyContext(global: on, modelsReady: false, rng: 0))
        XCTAssertEqual(decision, .text(reason: "语音模型未就绪"))
    }

    func testDecideVoiceReplyMirrorRequiresIncomingVoice() {
        var settings = VoiceSettings()
        settings.replyEnabled = true
        settings.replyProbability = 1
        settings.mirrorIncomingVoice = true
        XCTAssertFalse(decideVoiceReply(replyContext(global: settings, incomingWasVoice: false, rng: 0)).isVoice)
        XCTAssertTrue(decideVoiceReply(replyContext(global: settings, incomingWasVoice: true, rng: 0)).isVoice)
    }

    func testDecideVoiceReplyShortReplyOnly() {
        var settings = VoiceSettings()
        settings.replyEnabled = true
        settings.replyProbability = 1
        settings.shortReplyOnly = true
        settings.shortReplyMaxChars = 5
        XCTAssertTrue(decideVoiceReply(replyContext(global: settings, replyText: "好的", rng: 0)).isVoice)
        let long = decideVoiceReply(replyContext(
            global: settings,
            replyText: "这是一条超过五个字的回复",
            rng: 0
        ))
        XCTAssertFalse(long.isVoice)
        XCTAssertTrue(long.reason.contains("仅短回复"))

        // 关闭「仅短回复」后长回复也可以发语音。
        settings.shortReplyOnly = false
        XCTAssertTrue(decideVoiceReply(replyContext(
            global: settings,
            replyText: "这是一条超过五个字的回复",
            rng: 0
        )).isVoice)
    }

    func testDecideVoiceReplyProbability() {
        var settings = VoiceSettings()
        settings.replyEnabled = true
        settings.replyProbability = 0.3
        XCTAssertTrue(decideVoiceReply(replyContext(global: settings, rng: 0.29)).isVoice)
        let miss = decideVoiceReply(replyContext(global: settings, rng: 0.31))
        XCTAssertFalse(miss.isVoice)
        XCTAssertTrue(miss.reason.contains("未命中"))
        // 概率 0 永不发语音。
        settings.replyProbability = 0
        XCTAssertFalse(decideVoiceReply(replyContext(global: settings, rng: 0)).isVoice)
        // NaN rng 视为不命中，不崩溃。
        settings.replyProbability = 1
        XCTAssertFalse(decideVoiceReply(replyContext(global: settings, rng: .nan)).isVoice)
    }

    func testConversationVoiceProbabilityStaysGlobal() {
        var settings = VoiceSettings()
        settings.replyEnabled = true
        settings.replyProbability = 0.2
        var conversation = Conversation(id: "c", kind: .direct, title: "测试")
        conversation.voiceReplyProbability = 0.9
        // 会话只覆盖总开关；概率仍用全局 20%，rng=0.8 不命中，避免旧的概率覆盖遗留。
        XCTAssertFalse(decideVoiceReply(replyContext(
            global: settings,
            conversation: conversation,
            rng: 0.8
        )).isVoice)

        conversation.voiceReplyProbability = 0
        settings.replyProbability = 1
        XCTAssertTrue(decideVoiceReply(replyContext(
            global: settings,
            conversation: conversation,
            rng: 0
        )).isVoice)
    }
}

/// 语音测试用的一次性唤醒信号（与 ImageFetchTests 的 IdleSignal 同构，
/// 单独命名避免跨文件 private 冲突）。
private final class VoiceIdleSignal {
    private var fired = false
    private var nextToken = 0
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    func signal() {
        guard !waiters.isEmpty else {
            fired = true
            return
        }
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume(returning: true)
        }
    }

    func wait(timeout: TimeInterval = 5) async throws {
        nextToken += 1
        let token = nextToken
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if fired {
                fired = false
                continuation.resume(returning: true)
                return
            }
            waiters[token] = continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let pending = self.takeWaiter(token) {
                    pending.resume(returning: false)
                }
            }
        }
        if !finished { throw NSError(domain: "VoiceIdleSignal", code: 1) }
    }

    private func takeWaiter(_ token: Int) -> CheckedContinuation<Bool, Never>? {
        waiters.removeValue(forKey: token)
    }
}
