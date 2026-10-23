import SQLite3
import XCTest

@testable import WeChatAI

/// 入站图片获取（2026-10-23）：
/// 设置解码兼容 / `ImageFetchPolicy` / `OneBotClient` HTTP 纯函数 / `ImageFetcher` 串行队列。
final class ImageFetchTests: XCTestCase {
    // MARK: - 1. 设置解码

    func testLegacyConfigWithoutImageFetchKeyDecodesAsEnabled() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any]
        )
        var bot = try XCTUnwrap(object["bot"] as? [String: Any])
        // 默认配置不写入该键（nil 视为开启，等价于旧配置缺少该键）。
        XCTAssertNil(bot["imageFetchEnabled"])
        bot.removeValue(forKey: "imageFetchEnabled")
        object["bot"] = bot

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertNil(decoded.bot.imageFetchEnabled)
        XCTAssertTrue(decoded.bot.fetchImagesEnabled)
    }

    func testImageFetchSettingRoundtripKeepsFalse() throws {
        var settings = AppSettings.default
        XCTAssertTrue(settings.bot.fetchImagesEnabled)

        settings.bot.fetchImagesEnabled = false
        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let bot = try XCTUnwrap(object["bot"] as? [String: Any])
        XCTAssertEqual(bot["imageFetchEnabled"] as? Bool, false)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.bot.fetchImagesEnabled)

        // 显式 true 同样能被读回。
        var explicitTrue = AppSettings.default
        explicitTrue.bot.imageFetchEnabled = true
        let trueData = try JSONEncoder().encode(explicitTrue)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: trueData).bot.fetchImagesEnabled)
    }

    // MARK: - 2. 获取策略

    func testImageFetchPolicy() {
        func should(
            kind: MessageKind = .image,
            enabled: Bool = true,
            isSelf: Bool = false,
            messageID: String = "42",
            mediaPath: String? = nil,
            mediaURL: String? = nil
        ) -> Bool {
            ImageFetchPolicy.shouldFetch(
                kind: kind,
                enabled: enabled,
                isSelf: isSelf,
                messageID: messageID,
                mediaPath: mediaPath,
                mediaURL: mediaURL
            )
        }

        XCTAssertTrue(should(), "实时入站图片默认应获取")
        XCTAssertFalse(should(enabled: false), "关闭设置后不请求")
        XCTAssertFalse(should(isSelf: true), "自己发出的图片不请求")
        XCTAssertFalse(should(kind: .text), "非图片消息不请求")
        XCTAssertFalse(should(messageID: ""), "缺少 message_id 无法请求")
        XCTAssertFalse(should(mediaPath: "/tmp/a.jpg"), "已有本地路径不重复请求")
        XCTAssertFalse(should(mediaURL: "https://example.com/a.jpg"), "已有 URL 不重复请求")
        XCTAssertTrue(should(mediaPath: ""), "空字符串不应阻止获取")
    }

    // MARK: - 3. fetchImageRequest

    func testFetchImageRequestUsesPostBearerAndMessageID() throws {
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:58080"))
        let request = try OneBotClient.fetchImageRequest(
            baseURL: base,
            token: "test-token",
            messageID: "123456"
        )

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:58080/fetch_image")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["message_id"] as? String, "123456")
    }

    func testFetchImageRequestOmitsAuthorizationWhenTokenEmpty() throws {
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:58080"))
        let request = try OneBotClient.fetchImageRequest(baseURL: base, token: "", messageID: "1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - 4. parseImageFetchResponse

    func testParseImageFetchResponseDecodesPercentEncodedFilePath() throws {
        let data = Data(#"{"status":"ok","data":{"file":"file:///tmp/a%20b.jpg"}}"#.utf8)
        let path = try OneBotClient.parseImageFetchResponse(data: data, statusCode: 200)
        XCTAssertEqual(path, "/tmp/a b.jpg")
    }

    func testParseImageFetchResponsePassesPlainPathThrough() throws {
        let data = Data(#"{"status":"ok","data":{"file":"/tmp/plain.jpg"}}"#.utf8)
        XCTAssertEqual(
            try OneBotClient.parseImageFetchResponse(data: data, statusCode: 200),
            "/tmp/plain.jpg"
        )
    }

    func testParseImageFetchResponseSurfacesBridgeError() {
        let data = Data(#"{"status":"failed","error":"图片下载超时（微信未响应）"}"#.utf8)
        XCTAssertThrowsError(try OneBotClient.parseImageFetchResponse(data: data, statusCode: 200)) { error in
            XCTAssertTrue(error.localizedDescription.contains("图片下载超时（微信未响应）"))
        }
    }

    func testParseImageFetchResponseHintsBridgeUpdateOn404() {
        let data = Data(#"{"status":"failed","error":"not found"}"#.utf8)
        XCTAssertThrowsError(try OneBotClient.parseImageFetchResponse(data: data, statusCode: 404)) { error in
            XCTAssertTrue(error.localizedDescription.contains("不支持图片获取"))
            XCTAssertTrue(error.localizedDescription.contains("更新 bridge"))
        }
    }

    func testParseImageFetchResponseRejectsMissingFile() {
        let data = Data(#"{"status":"ok","data":{}}"#.utf8)
        XCTAssertThrowsError(try OneBotClient.parseImageFetchResponse(data: data, statusCode: 200))
    }

    // MARK: - 5. ImageFetcher 串行队列

    @MainActor
    func testFetcherProcessesQueueSeriallyInOrderAndIgnoresDuplicate() async throws {
        let fetcher = ImageFetcher()
        let idle = IdleSignal()
        var started: [String] = []
        var fetched: [(chatMessageID: String, path: String)] = []
        var inFlight = 0
        var maxInFlight = 0

        fetcher.configure(
            fetch: { bridgeMessageID in
                started.append(bridgeMessageID)
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
                try? await Task.sleep(nanoseconds: 5_000_000)
                inFlight -= 1
                return "/tmp/\(bridgeMessageID).jpg"
            },
            onFetched: { request, path in
                fetched.append((request.chatMessageID, path))
            },
            onFailed: { request, reason in
                XCTFail("不应失败：\(request.chatMessageID) \(reason)")
            },
            onIdle: { idle.signal() }
        )

        let first = ImageFetcher.Request(
            bridgeMessageID: "m1",
            chatMessageID: "ob-m1",
            conversationID: "wxid_test"
        )
        XCTAssertTrue(fetcher.enqueue(first))
        XCTAssertTrue(fetcher.enqueue(.init(bridgeMessageID: "m2", chatMessageID: "ob-m2", conversationID: "wxid_test")))
        XCTAssertTrue(fetcher.enqueue(.init(bridgeMessageID: "m3", chatMessageID: "ob-m3", conversationID: "wxid_test")))
        // 同一 chatMessageID 还未处理时重复入队：直接忽略。
        XCTAssertFalse(fetcher.enqueue(first))
        XCTAssertEqual(fetcher.pendingCount, 3)

        try await idle.wait()

        XCTAssertEqual(started, ["m1", "m2", "m3"], "严格按入队顺序串行请求")
        XCTAssertEqual(fetched.map(\.chatMessageID), ["ob-m1", "ob-m2", "ob-m3"])
        XCTAssertEqual(fetched.map(\.path), ["/tmp/m1.jpg", "/tmp/m2.jpg", "/tmp/m3.jpg"])
        XCTAssertEqual(maxInFlight, 1, "一次只允许一个请求在途")
        XCTAssertEqual(fetcher.pendingCount, 0)
    }

    @MainActor
    func testFetcherReportsFailureOnceAndDoesNotRetry() async throws {
        let fetcher = ImageFetcher()
        let idle = IdleSignal()
        var failures: [String] = []
        var fetched = 0

        fetcher.configure(
            fetch: { _ in
                throw OneBotError.badResponse("图片下载超时")
            },
            onFetched: { _, _ in fetched += 1 },
            onFailed: { request, reason in
                failures.append("\(request.chatMessageID):\(reason)")
            },
            onIdle: { idle.signal() }
        )

        let request = ImageFetcher.Request(
            bridgeMessageID: "m-fail",
            chatMessageID: "ob-m-fail",
            conversationID: "wxid_test"
        )
        XCTAssertTrue(fetcher.enqueue(request))
        try await idle.wait()

        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("图片下载超时"))
        XCTAssertEqual(fetched, 0)
        XCTAssertEqual(fetcher.pendingCount, 0)

        // 失败过的 chatMessageID 不再重试。
        XCTAssertFalse(fetcher.enqueue(request))
        XCTAssertEqual(failures.count, 1)
    }

    @MainActor
    func testFetcherCancelAllSuppressesCallbacks() async throws {
        let fetcher = ImageFetcher()
        let fetchStarted = IdleSignal()
        let fetchExited = IdleSignal()
        let idle = IdleSignal()
        let gate = AsyncGate()
        var callbacks = 0

        fetcher.configure(
            fetch: { _ in
                fetchStarted.signal()
                await gate.wait()
                fetchExited.signal()
                return "/tmp/should-not-apply.jpg"
            },
            onFetched: { _, _ in callbacks += 1 },
            onFailed: { _, _ in callbacks += 1 },
            onIdle: { idle.signal() }
        )

        XCTAssertTrue(
            fetcher.enqueue(
                .init(bridgeMessageID: "m-cancel", chatMessageID: "ob-m-cancel", conversationID: "wxid_test")
            )
        )
        try await fetchStarted.wait()
        XCTAssertEqual(fetcher.pendingCount, 1)

        fetcher.cancelAll()
        XCTAssertEqual(fetcher.pendingCount, 0)

        // 放行在途 fetch：任务已取消，回调必须被抑制（也不会触发 onIdle）。
        gate.release()
        try await fetchExited.wait()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(fetcher.pendingCount, 0)
    }

    // MARK: - 6. 按会话生效值

    func testConversationEffectiveImageFetchEnabledPriority() {
        var conversation = Conversation(id: "wxid_test", kind: .direct, title: "测试")

        // nil：跟随旧全局默认。
        XCTAssertTrue(conversation.effectiveImageFetchEnabled(global: true))
        XCTAssertFalse(conversation.effectiveImageFetchEnabled(global: false))

        // 会话显式值优先于全局。
        conversation.imageFetchEnabled = true
        XCTAssertTrue(conversation.effectiveImageFetchEnabled(global: false))
        conversation.imageFetchEnabled = false
        XCTAssertFalse(conversation.effectiveImageFetchEnabled(global: true))
    }

    // MARK: - 7. 会话设置持久化（DB 往返 + 旧库补列）

    func testMemoryStoreRoundtripsPerConversationImageFetch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-perconv-image-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()

        var off = Conversation(id: "wxid_test", kind: .direct, title: "关闭会话")
        off.imageFetchEnabled = false
        var on = Conversation(id: "wxid_test-group@chatroom", kind: .group, title: "开启群")
        on.imageFetchEnabled = true
        on.workingHours = WorkingHours(enabled: true, startMinute: 540, endMinute: 1080)
        let follow = Conversation(id: "wxid_follow", kind: .direct, title: "跟随会话")
        try await store.upsertConversations([off, on, follow])

        let fetched = try await store.fetchConversations()
        XCTAssertEqual(fetched.count, 3)
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        XCTAssertEqual(byID["wxid_test"]?.imageFetchEnabled, false)
        XCTAssertEqual(byID["wxid_test-group@chatroom"]?.imageFetchEnabled, true)
        XCTAssertNil(byID["wxid_follow"]?.imageFetchEnabled, "NULL 应读回 nil，而不是 false")
        XCTAssertEqual(
            byID["wxid_test-group@chatroom"]?.workingHours?.startMinute,
            540,
            "新增列不应打乱相邻列的解码"
        )

        // 单条查询走同一套 SELECT/解码。
        let single = try await store.conversation(id: "wxid_test")
        XCTAssertEqual(single?.title, "关闭会话")
        XCTAssertEqual(single?.imageFetchEnabled, false)

        // 覆盖更新：false → true 后读回 true。
        off.imageFetchEnabled = true
        try await store.upsertConversation(off)
        let reloaded = try await store.conversation(id: "wxid_test")
        XCTAssertEqual(reloaded?.imageFetchEnabled, true)
        await store.close()
    }

    func testLegacyDatabaseMigrationAddsImageFetchColumn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-perconv-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chatbot.sqlite")

        // 旧结构：1.2.5 的 conversations 表（有 working_hours，无 image_fetch_enabled）。
        try executeSQL(at: file, statements: [
            """
            CREATE TABLE conversations (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                subtitle TEXT,
                unread_count INTEGER NOT NULL DEFAULT 0,
                last_message_at REAL,
                last_message_preview TEXT NOT NULL DEFAULT '',
                ai_enabled INTEGER NOT NULL DEFAULT 1,
                provider_id TEXT,
                model TEXT,
                persona_id TEXT,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                is_muted INTEGER NOT NULL DEFAULT 0,
                note TEXT NOT NULL DEFAULT '',
                working_hours TEXT
            );
            """,
            """
            INSERT INTO conversations (id, kind, title, working_hours)
            VALUES ('wxid_test', 'direct', '旧会话', NULL);
            """
        ])

        let store = MemoryStore(databaseURL: file)
        try await store.open()
        let legacy = try await store.conversation(id: "wxid_test")
        XCTAssertEqual(legacy?.title, "旧会话")
        XCTAssertNil(legacy?.imageFetchEnabled, "旧库补列后应为 NULL（跟随默认）")

        var updated = try XCTUnwrap(legacy)
        updated.imageFetchEnabled = false
        try await store.upsertConversation(updated)
        await store.close()

        // 重新打开：迁移幂等，补列后的覆盖值仍可读回。
        let reopened = MemoryStore(databaseURL: file)
        try await reopened.open()
        let reloaded = try await reopened.conversation(id: "wxid_test")
        XCTAssertEqual(reloaded?.imageFetchEnabled, false)
        XCTAssertEqual(reloaded?.workingHours, nil)
        await reopened.close()
    }

    // MARK: - SQLite fixture helper

    /// 绕过 `MemoryStore` 直接写一个「旧版本」数据库文件，用于验证补列迁移。
    private func executeSQL(at url: URL, statements: [String]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(
                domain: "ImageFetchTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建旧版数据库"]
            )
        }
        defer { sqlite3_close_v2(handle) }
        for statement in statements {
            var error: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(handle, statement, nil, nil, &error)
            guard status == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "sqlite error \(status)"
                sqlite3_free(error)
                throw NSError(
                    domain: "ImageFetchTests",
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }
    }
}

// MARK: - Test helpers

/// 一次性「空闲」信号：worker 结束时 `signal()`，测试用 continuation + 超时等待，
/// 超时抛错而不是把测试挂死。
@MainActor
private final class IdleSignal {
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
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.expire(token)
            }
        }
        guard finished else { throw TestWaitTimeout() }
    }

    private func expire(_ token: Int) {
        guard let continuation = waiters.removeValue(forKey: token) else { return }
        continuation.resume(returning: false)
    }
}

/// 可控 async 闸门：`wait()` 挂起，直到测试调用 `release()`。
@MainActor
private final class AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false

    func wait() async {
        if open {
            open = false
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
    }

    func release() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            open = true
        }
    }
}

private struct TestWaitTimeout: Error, CustomStringConvertible {
    var description: String { "等待图片获取队列空闲超时" }
}
