import Foundation
import XCTest
@testable import WeChatAI

/// 账号切换的存储层保证：`MemoryStore` 关闭旧库后打开新账号库，
/// 会话/消息/KV 互不串号；同路径切换保持幂等。
final class AccountDatabaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    func testSwitchingDatabaseIsolatesConversationsMessagesAndKV() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-account-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MemoryStore(databaseURL: directory.appendingPathComponent("a/chatbot.sqlite"))
        try await store.open()

        try await store.upsertConversation(Conversation(id: "wxid_a", kind: .direct, title: "A 好友"))
        try await store.upsertMessages([
            ChatMessage(
                id: "m-a",
                conversationID: "wxid_a",
                senderID: "wxid_a",
                senderName: "A 好友",
                direction: .incoming,
                text: "A 账号的聊天",
                timestamp: now
            )
        ])
        try await store.setSetting(key: "onebot.self_id", value: "wxid_a")

        let aConversations = try await store.fetchConversations().map(\.id)
        XCTAssertEqual(aConversations, ["wxid_a"])
        let aSelfID = try await store.setting(key: "onebot.self_id")
        XCTAssertEqual(aSelfID, "wxid_a")

        // 切到另一个账号的库：旧会话/消息/KV 必须不可见。
        try await store.switchDatabase(to: directory.appendingPathComponent("b/chatbot.sqlite"))
        let bConversationsBefore = try await store.fetchConversations()
        XCTAssertEqual(bConversationsBefore, [])
        let bSelfIDBefore = try await store.setting(key: "onebot.self_id")
        XCTAssertNil(bSelfIDBefore)
        let aMessagesInB = try await store.fetchMessages(conversationID: "wxid_a", limit: 10)
        XCTAssertTrue(aMessagesInB.isEmpty)

        try await store.upsertConversation(Conversation(id: "wxid_b", kind: .direct, title: "B 好友"))
        try await store.setSetting(key: "onebot.self_id", value: "wxid_b")
        let bConversations = try await store.fetchConversations().map(\.id)
        XCTAssertEqual(bConversations, ["wxid_b"])

        // 切回 A：A 的数据仍在，且看不到 B。
        try await store.switchDatabase(to: directory.appendingPathComponent("a/chatbot.sqlite"))
        let aConversationsAfter = try await store.fetchConversations().map(\.id)
        XCTAssertEqual(aConversationsAfter, ["wxid_a"])
        let aSelfIDAfter = try await store.setting(key: "onebot.self_id")
        XCTAssertEqual(aSelfIDAfter, "wxid_a")
        let aMessages = try await store.fetchMessages(conversationID: "wxid_a", limit: 10)
        XCTAssertEqual(aMessages.first?.text, "A 账号的聊天")
        let bMessagesInA = try await store.fetchMessages(conversationID: "wxid_b", limit: 10)
        XCTAssertTrue(bMessagesInA.isEmpty)
    }

    func testSwitchToSameOpenDatabaseDoesNotDropData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-account-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("chatbot.sqlite")
        let store = MemoryStore(databaseURL: file)
        try await store.open()
        try await store.upsertConversation(Conversation(id: "wxid_same", kind: .direct, title: "同账号"))

        try await store.switchDatabase(to: file)
        let samePathConversations = try await store.fetchConversations().map(\.id)
        XCTAssertEqual(samePathConversations, ["wxid_same"])

        // 关闭后再次 switch 到同一路径应重新打开并保留磁盘数据。
        await store.close()
        try await store.switchDatabase(to: file)
        let reopenedConversations = try await store.fetchConversations().map(\.id)
        XCTAssertEqual(reopenedConversations, ["wxid_same"])
    }

    func testPathReflectsConfiguredDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-account-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("chatbot.sqlite")
        let store = MemoryStore(databaseURL: file)
        let beforeOpenPath = await store.path
        XCTAssertEqual(beforeOpenPath, file.path)
        try await store.open()
        let afterOpenPath = await store.path
        XCTAssertEqual(afterOpenPath, file.path)
    }
}
