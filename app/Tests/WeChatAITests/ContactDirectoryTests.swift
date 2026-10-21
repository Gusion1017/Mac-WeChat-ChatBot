import Foundation
import SQLite3
import XCTest
@testable import WeChatAI

/// 通讯录目录（bridge `get_contact_directory`）的 App 侧消费：
/// snake_case 解析、users/groups 分组取名、占位标题才应用、MemoryStore 缓存往返。
/// 夹具全部使用占位 wxid / 群 ID / 中文名，不触碰隐私红线。
final class ContactDirectoryTests: XCTestCase {
    // MARK: 解析

    func testSnapshotDecodesSnakeCaseAndMillisecondTimestamp() throws {
        let json = """
        {
          "ok": true,
          "generated_at": 1760000000000,
          "users": {
            "wxid_test_friend": { "display": "张三", "nickname": "张三", "remark": "老张" },
            "gh_test_official": { "display": "示例公众号" }
          },
          "groups": {
            "123456@chatroom": { "display": "项目群", "nickname": "项目群", "remark": "" }
          }
        }
        """
        let snapshot = try JSONDecoder().decode(ContactDirectorySnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.ok)
        XCTAssertNil(snapshot.reason)
        XCTAssertEqual(snapshot.generatedAt?.timeIntervalSince1970 ?? 0, 1_760_000_000, accuracy: 0.001)
        XCTAssertEqual(snapshot.users.count, 2)
        XCTAssertEqual(snapshot.users["wxid_test_friend"]?.display, "张三")
        XCTAssertEqual(snapshot.users["wxid_test_friend"]?.nickname, "张三")
        XCTAssertEqual(snapshot.users["wxid_test_friend"]?.remark, "老张")
        XCTAssertEqual(snapshot.groups["123456@chatroom"]?.display, "项目群")
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testFailureSnapshotDecodesWithoutCollections() throws {
        let json = #"{"ok":false,"reason":"key_missing"}"#
        let snapshot = try JSONDecoder().decode(ContactDirectorySnapshot.self, from: Data(json.utf8))
        XCTAssertFalse(snapshot.ok)
        XCTAssertEqual(snapshot.reason, "key_missing")
        XCTAssertTrue(snapshot.users.isEmpty)
        XCTAssertTrue(snapshot.groups.isEmpty)
        XCTAssertNil(snapshot.generatedAt)
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testContactDirectoryEntryToleratesMissingDisplay() throws {
        let json = #"{"wxid_test_empty":{},"wxid_test_friend":{"display":"张三"}}"#
        let users = try JSONDecoder().decode([String: ContactDirectoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(users["wxid_test_empty"]?.display, "")
        XCTAssertEqual(users["wxid_test_friend"]?.display, "张三")
    }

    func testSnapshotToleratesSecondTimestampAndWrongFieldTypes() throws {
        // 秒级时间戳与字段类型异常都不应让整包目录不可用。
        let json = #"{"ok":true,"generated_at":1760000000,"users":{"wxid_test_friend":{"display":123}}}"#
        let snapshot = try JSONDecoder().decode(ContactDirectorySnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.ok)
        XCTAssertEqual(snapshot.generatedAt?.timeIntervalSince1970 ?? 0, 1_760_000_000, accuracy: 0.001)
        XCTAssertEqual(snapshot.users["wxid_test_friend"]?.display, "")
    }

    // MARK: 取名规则

    func testDisplayNameUsesGroupsOnlyForGroupConversations() {
        let snapshot = ContactDirectorySnapshot(
            ok: true,
            users: [
                "wxid_test_friend": ContactDirectoryEntry(display: "张三"),
                "gh_test_official": ContactDirectoryEntry(display: "示例公众号")
            ],
            groups: ["123456@chatroom": ContactDirectoryEntry(display: "项目群")]
        )
        // 私聊 / 公众号只查 users。
        XCTAssertEqual(snapshot.displayName(for: "wxid_test_friend", kind: .direct), "张三")
        XCTAssertEqual(snapshot.displayName(for: "gh_test_official", kind: .official), "示例公众号")
        // 群只查 groups。
        XCTAssertEqual(snapshot.displayName(for: "123456@chatroom", kind: .group), "项目群")
        XCTAssertNil(snapshot.displayName(for: "wxid_test_friend", kind: .group))
        XCTAssertNil(snapshot.displayName(for: "123456@chatroom", kind: .direct))
        XCTAssertNil(snapshot.displayName(for: "wxid_test_unknown", kind: .direct))
    }

    func testDisplayNameRejectsIDLikeAndBlankDisplays() {
        let snapshot = ContactDirectorySnapshot(
            ok: true,
            users: [
                "wxid_test_same": ContactDirectoryEntry(display: "wxid_test_same"),
                "wxid_test_blank": ContactDirectoryEntry(display: "   "),
                "wxid_test_other_wxid": ContactDirectoryEntry(display: "wxid_test_other")
            ],
            groups: ["999999@chatroom": ContactDirectoryEntry(display: "999999@chatroom")]
        )
        // Hook 在无备注/昵称/别名时会回退成 ID，这类值不能写成会话标题。
        XCTAssertNil(snapshot.displayName(for: "wxid_test_same", kind: .direct))
        XCTAssertNil(snapshot.displayName(for: "wxid_test_blank", kind: .direct))
        XCTAssertNil(snapshot.displayName(for: "wxid_test_other_wxid", kind: .direct))
        XCTAssertNil(snapshot.displayName(for: "999999@chatroom", kind: .group))
    }

    // MARK: WS 契约

    func testRequestPayloadMatchesBridgeContract() throws {
        let data = Data(OneBotContactDirectory.requestPayload().utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["action"] as? String, "get_contact_directory")
        XCTAssertEqual(object["echo"] as? String, "contact-directory")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertTrue(params.isEmpty)
    }

    func testParseReplyReadsEchoDataObjectAndString() throws {
        let frame = """
        {"echo":"contact-directory","status":"ok","data":{"ok":true,"generated_at":1760000000000,
        "users":{"wxid_test_friend":{"display":"张三"}},"groups":{"123456@chatroom":{"display":"项目群"}}}}
        """
        let snapshot = try XCTUnwrap(OneBotContactDirectory.parseReply(data: Data(frame.utf8)))
        XCTAssertTrue(snapshot.ok)
        XCTAssertEqual(snapshot.users["wxid_test_friend"]?.display, "张三")
        XCTAssertEqual(snapshot.groups["123456@chatroom"]?.display, "项目群")

        // 兼容 bridge 把 Hook 返回的 JSON 字符串原样透传。
        let stringFrame = """
        {"echo":"contact-directory","status":"ok","data":{"ok":true,"users":{"wxid_test_friend":{"display":"张三"}}}}
        """
        let stringSnapshot = try XCTUnwrap(OneBotContactDirectory.parseReply(data: Data(stringFrame.utf8)))
        XCTAssertEqual(stringSnapshot.users["wxid_test_friend"]?.display, "张三")
    }

    func testParseReplyIgnoresMessageAndLoginFrames() {
        let message = #"{"self_id":"wxid_test_bot","user_id":"wxid_test_friend","sender":{"user_id":"wxid_test_friend","nickname":"张三"},"message":[{"type":"text","data":{"text":"hi"}}]}"#
        XCTAssertNil(OneBotContactDirectory.parseReply(data: Data(message.utf8)))
        let login = #"{"echo":"login-info","status":"ok","data":{"user_id":"wxid_test_bot"}}"#
        XCTAssertNil(OneBotContactDirectory.parseReply(data: Data(login.utf8)))
        XCTAssertNil(OneBotContactDirectory.parseReply(data: Data("not json".utf8)))
    }

    func testParseReplyMapsBridgeAndHookFailures() throws {
        let bridgeFailure = #"{"echo":"contact-directory","status":"failed","error":"frida timeout"}"#
        let bridgeSnapshot = try XCTUnwrap(OneBotContactDirectory.parseReply(data: Data(bridgeFailure.utf8)))
        XCTAssertFalse(bridgeSnapshot.ok)
        XCTAssertEqual(bridgeSnapshot.reason, "frida timeout")

        let hookFailure = #"{"echo":"contact-directory","status":"ok","data":{"ok":false,"reason":"key_missing"}}"#
        let hookSnapshot = try XCTUnwrap(OneBotContactDirectory.parseReply(data: Data(hookFailure.utf8)))
        XCTAssertFalse(hookSnapshot.ok)
        XCTAssertEqual(hookSnapshot.reason, "key_missing")

        let badPayload = #"{"echo":"contact-directory","status":"ok","data":42}"#
        let badSnapshot = try XCTUnwrap(OneBotContactDirectory.parseReply(data: Data(badPayload.utf8)))
        XCTAssertFalse(badSnapshot.ok)
        XCTAssertEqual(badSnapshot.reason, "bad_payload")
    }

    // MARK: 标题应用

    func testTitlesOnlyFillPlaceholderConversations() {
        let directory = ContactDirectorySnapshot(
            ok: true,
            users: [
                "wxid_test_friend": ContactDirectoryEntry(display: "张三"),
                "wxid_test_id_title": ContactDirectoryEntry(display: "李四"),
                "wxid_test_renamed": ContactDirectoryEntry(display: "微信昵称")
            ],
            groups: ["123456@chatroom": ContactDirectoryEntry(display: "项目群")]
        )
        let conversations = [
            Conversation(id: "wxid_test_friend", kind: .direct, title: ""),
            Conversation(id: "wxid_test_id_title", kind: .direct, title: "wxid_test_id_title"),
            Conversation(id: "123456@chatroom", kind: .group, title: "群聊 123456@chatroom"),
            Conversation(id: "wxid_test_renamed", kind: .direct, title: "老王"),
            Conversation(id: "wxid_test_unknown", kind: .direct, title: ""),
            // 系统账号没有目录记录：保持空标题，展示层继续走中文兜底名。
            Conversation(id: "filehelper", kind: .direct, title: "")
        ]

        let updated = ContactDirectoryTitles.updatedConversations(conversations, directory: directory)
        XCTAssertEqual(updated.map(\.id), ["wxid_test_friend", "wxid_test_id_title", "123456@chatroom"])
        let titles = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0.title) })
        XCTAssertEqual(titles["wxid_test_friend"], "张三")
        XCTAssertEqual(titles["wxid_test_id_title"], "李四")
        XCTAssertEqual(titles["123456@chatroom"], "项目群")
        // 用户重命名后的标题不在结果里，绝不会被覆盖。
        XCTAssertNil(titles["wxid_test_renamed"])
    }

    func testFailedDirectoryNeverRenames() {
        let failed = ContactDirectorySnapshot(
            ok: false,
            reason: "key_missing",
            users: ["wxid_test_friend": ContactDirectoryEntry(display: "张三")]
        )
        let conversations = [Conversation(id: "wxid_test_friend", kind: .direct, title: "")]
        XCTAssertTrue(ContactDirectoryTitles.updatedConversations(conversations, directory: failed).isEmpty)
        XCTAssertNil(ContactDirectoryTitles.title(for: "wxid_test_friend", kind: .direct, in: failed))
        XCTAssertNil(ContactDirectoryTitles.title(for: "wxid_test_friend", kind: .direct, in: nil))
    }

    func testNewConversationTitlePrefersDirectoryForMatchingKind() {
        let directory = ContactDirectorySnapshot(
            ok: true,
            users: ["wxid_test_friend": ContactDirectoryEntry(display: "张三")],
            groups: ["123456@chatroom": ContactDirectoryEntry(display: "项目群")]
        )
        XCTAssertEqual(
            ContactDirectoryTitles.title(for: "wxid_test_friend", kind: .direct, in: directory),
            "张三"
        )
        XCTAssertEqual(
            ContactDirectoryTitles.title(for: "123456@chatroom", kind: .group, in: directory),
            "项目群"
        )
        // 群 ID 不能从 users 取名字，私聊 ID 也不能从 groups 取名字。
        XCTAssertNil(ContactDirectoryTitles.title(for: "123456@chatroom", kind: .direct, in: directory))
        XCTAssertNil(ContactDirectoryTitles.title(for: "wxid_test_friend", kind: .group, in: directory))
        XCTAssertNil(ContactDirectoryTitles.title(for: "wxid_test_unknown", kind: .direct, in: directory))
    }

    // MARK: MemoryStore 往返

    func testMemoryStoreContactDirectoryRoundtripAndReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-contacts-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        // 空缓存返回 nil。
        let empty = try await store.loadContactDirectory()
        XCTAssertNil(empty)

        let generatedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = ContactDirectorySnapshot(
            ok: true,
            generatedAt: generatedAt,
            users: [
                "wxid_test_friend": ContactDirectoryEntry(display: "张三", nickname: "张三", remark: "老张"),
                "gh_test_official": ContactDirectoryEntry(display: "示例公众号")
            ],
            groups: ["123456@chatroom": ContactDirectoryEntry(display: "项目群", nickname: "项目群")]
        )
        try await store.replaceContactDirectory(snapshot)

        let loaded = try await store.loadContactDirectory()
        let cached = try XCTUnwrap(loaded)
        XCTAssertTrue(cached.ok)
        XCTAssertEqual(cached.generatedAt?.timeIntervalSince1970 ?? 0, 1_760_000_000, accuracy: 0.001)
        XCTAssertEqual(cached.users.count, 2)
        XCTAssertEqual(cached.groups.count, 1)
        XCTAssertEqual(cached.users["wxid_test_friend"]?.display, "张三")
        XCTAssertEqual(cached.users["wxid_test_friend"]?.nickname, "张三")
        XCTAssertEqual(cached.users["wxid_test_friend"]?.remark, "老张")
        XCTAssertEqual(cached.groups["123456@chatroom"]?.display, "项目群")
        // kind 决定条目落在 users 还是 groups。
        XCTAssertNil(cached.users["123456@chatroom"])
        XCTAssertNil(cached.groups["wxid_test_friend"])

        // 失败快照不能清掉可用缓存。
        try await store.replaceContactDirectory(ContactDirectorySnapshot(ok: false, reason: "key_missing"))
        let afterFailure = try await store.loadContactDirectory()
        XCTAssertEqual(afterFailure?.users.count, 2)

        // 全量替换：旧 ID 不再存在。
        try await store.replaceContactDirectory(ContactDirectorySnapshot(
            ok: true,
            users: ["wxid_test_other": ContactDirectoryEntry(display: "王五")]
        ))
        let replacedSnapshot = try await store.loadContactDirectory()
        let replaced = try XCTUnwrap(replacedSnapshot)
        XCTAssertEqual(replaced.users.keys.sorted(), ["wxid_test_other"])
        XCTAssertTrue(replaced.groups.isEmpty)
    }

    /// 旧版数据库（没有 contact_directory 表）启动后应自动补表，且原有会话/设置不受影响。
    func testOpeningLegacyDatabaseAddsContactDirectoryTableWithoutLosingData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-contacts-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chatbot.sqlite")
        let now = Date().timeIntervalSince1970
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
            INSERT INTO conversations (id, kind, title, last_message_at, last_message_preview)
            VALUES ('wxid_test_legacy', 'direct', '老王', \(now), '旧消息');
            """,
            """
            CREATE TABLE settings (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            INSERT INTO settings (key, value, updated_at) VALUES ('legacy.key', 'legacy.value', \(now));
            """,
            "PRAGMA user_version=4;"
        ])

        let store = MemoryStore(databaseURL: file)
        try await store.open()
        defer { Task { await store.close() } }

        // 旧数据仍在（迁移只补表，不重建/清空）。
        let conversations = try await store.fetchConversations(limit: 10)
        XCTAssertEqual(conversations.first?.id, "wxid_test_legacy")
        XCTAssertEqual(conversations.first?.title, "老王")
        let legacyValue = try await store.setting(key: "legacy.key")
        XCTAssertEqual(legacyValue, "legacy.value")

        // 新表可用：写入/读取目录缓存后旧会话标题不被改动。
        try await store.replaceContactDirectory(ContactDirectorySnapshot(
            ok: true,
            users: ["wxid_test_legacy": ContactDirectoryEntry(display: "老王")]
        ))
        let loadedSnapshot = try await store.loadContactDirectory()
        let loaded = try XCTUnwrap(loadedSnapshot)
        XCTAssertEqual(loaded.users["wxid_test_legacy"]?.display, "老王")
        let after = try await store.fetchConversations(limit: 10)
        XCTAssertEqual(after.first?.title, "老王")
    }

    // MARK: SQLite helpers (legacy DB fixture)

    private func executeSQL(at url: URL, statements: [String]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "ContactDirectoryTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建旧版数据库"])
        }
        defer { sqlite3_close_v2(handle) }
        for statement in statements {
            var error: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(handle, statement, nil, nil, &error)
            guard status == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "sqlite error \(status)"
                sqlite3_free(error)
                throw NSError(domain: "ContactDirectoryTests", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }
}
