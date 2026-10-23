import Foundation
import XCTest
@testable import WeChatAI

/// 启动数据修复的 `trusted:` 语义：`selfID` 来自 bridge `get_login_info` 时是权威值，
/// 修复不得再从历史事件反推账号（反推要全表读取并逐行 JSON 解析）。
final class DataRepairTrustTests: XCTestCase {
    private let bot = "wxid_bot"
    private let friend = "wxid_friend"
    private let group = "123@chatroom"
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// `repairSelfRoutedMessages(trusted: true)` 完全跳过反推；默认参数保持旧语义。
    func testTrustedSelfRoutingRepairSkipsHistoricalInference() async throws {
        try await withTemporaryMemoryStore { store in
            // 3 个不同好友的入站消息：历史事件反推会得到 bot。
            try await store.upsertMessages([
                ChatMessage(id: "in-1", conversationID: "wxid_a", senderID: "wxid_a", senderName: "A",
                            direction: .incoming, text: "a", timestamp: now,
                            rawJSON: #"{"self_id":"wxid_bot","user_id":"wxid_a"}"#),
                ChatMessage(id: "in-2", conversationID: "wxid_b", senderID: "wxid_b", senderName: "B",
                            direction: .incoming, text: "b", timestamp: now.addingTimeInterval(1),
                            rawJSON: #"{"self_id":"wxid_bot","user_id":"wxid_b"}"#),
                ChatMessage(id: "in-3", conversationID: "wxid_c", senderID: "wxid_c", senderName: "C",
                            direction: .incoming, text: "c", timestamp: now.addingTimeInterval(2),
                            rawJSON: #"{"self_id":"wxid_bot","user_id":"wxid_c"}"#)
            ])
            // 「自己」会话里 3 条旧 hook 误路由消息（私聊对象 = friend）。
            try await store.upsertConversation(Conversation(id: bot, kind: .direct, title: bot))
            try await store.upsertMessages((1...3).map { index in
                ChatMessage(id: "self-\(index)", conversationID: bot, senderID: bot, senderName: bot,
                            direction: .incoming, text: "r\(index)",
                            timestamp: now.addingTimeInterval(10 + Double(index)),
                            rawJSON: #"{"self_id":"wxid_friend","user_id":"wxid_bot","group_id":""}"#)
            })

            // trusted：传入什么就用什么（这里故意传 friend），不反推、不动数据。
            let trustedResult = try await store.repairSelfRoutedMessages(selfID: friend, trusted: true)
            XCTAssertNil(trustedResult.inferredSelfID)
            XCTAssertFalse(trustedResult.didChange)
            let remaining = try await store.messageCount(conversationID: bot)
            XCTAssertEqual(remaining, 3)

            // 默认 trusted=false 保持旧语义：反推出 bot 并完成归位。
            let inferredResult = try await store.repairSelfRoutedMessages(selfID: friend)
            XCTAssertEqual(inferredResult.inferredSelfID, bot)
            XCTAssertEqual(inferredResult.movedMessages, 3)
            XCTAssertTrue(inferredResult.removedSelfConversation)
        }
    }

    /// `repairMisroutedConversations(trusted: true)` 用传入账号判定消息方向；
    /// 未 trusted 时才用反推账号覆盖。两种结果的方向不同，可直接观察。
    func testTrustedMisroutedRepairUsesGivenSelfIDInsteadOfInference() async throws {
        let trustedDirection = try await misroutedMessageDirection(trusted: true)
        let inferredDirection = try await misroutedMessageDirection(trusted: false)
        XCTAssertEqual(trustedDirection, .outgoing, "trusted 时应按传入账号 bot 判定为自己发出")
        XCTAssertEqual(inferredDirection, .incoming, "未 trusted 时应改用反推账号 other 判定")
    }

    // MARK: - Helpers

    /// 构造「伪群会话 + 一条 bot 发到群的回复 + 可反推成 other 的历史消息」，
    /// 跑一次误归类修复并返回搬入群的消息方向。
    private func misroutedMessageDirection(trusted: Bool) async throws -> ChatDirection? {
        var direction: ChatDirection?
        try await withTemporaryMemoryStore { store in
            try await store.upsertConversation(Conversation(id: "wxid_fake", kind: .group, title: "伪群"))
            // 3 条入站消息：self_id=other，user_id 各不相同 → 反推会得到 other。
            try await store.upsertMessages([
                ChatMessage(id: "in-1", conversationID: "wxid_a", senderID: "wxid_a", senderName: "A",
                            direction: .incoming, text: "a", timestamp: now,
                            rawJSON: #"{"self_id":"wxid_other","user_id":"wxid_a"}"#),
                ChatMessage(id: "in-2", conversationID: "wxid_b", senderID: "wxid_b", senderName: "B",
                            direction: .incoming, text: "b", timestamp: now.addingTimeInterval(1),
                            rawJSON: #"{"self_id":"wxid_other","user_id":"wxid_b"}"#),
                ChatMessage(id: "in-3", conversationID: "wxid_c", senderID: "wxid_c", senderName: "C",
                            direction: .incoming, text: "c", timestamp: now.addingTimeInterval(2),
                            rawJSON: #"{"self_id":"wxid_other","user_id":"wxid_c"}"#)
            ])
            let raw = rawJSONString([
                "user_id": bot,
                "group_id": "",
                "from_wxid": bot,
                "to_wxid": group,
                "sender_wxid": bot,
                "sender": ["user_id": bot, "nickname": bot],
                "message_type": "private"
            ])
            try await store.upsertMessages([
                ChatMessage(id: "reply-1", conversationID: "wxid_fake", senderID: "wxid_fake",
                            senderName: "wxid_fake", direction: .incoming, text: "群回复",
                            timestamp: now.addingTimeInterval(10), rawJSON: raw)
            ])

            let result = try await store.repairMisroutedConversations(selfID: bot, trusted: trusted)
            XCTAssertEqual(result.movedMessages, 1)
            let moved = try await store.fetchMessages(conversationID: group, limit: 10)
            direction = moved.first { $0.id == "reply-1" }?.direction
        }
        return direction
    }

    private func withTemporaryMemoryStore(
        _ body: (MemoryStore) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-repair-trust-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        do {
            try await body(store)
        } catch {
            await store.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func rawJSONString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }
}
