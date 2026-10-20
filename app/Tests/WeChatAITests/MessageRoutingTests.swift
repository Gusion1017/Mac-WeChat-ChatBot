import XCTest
@testable import WeChatAI

final class MessageRoutingTests: XCTestCase {
    // MARK: Parser

    func testParserHonorsExplicitSelfFlagAndTargetForPrivateEcho() throws {
        let raw: [String: Any] = [
            "self_id": "wxid_bot",
            "user_id": "wxid_bot",
            "target_id": "wxid_friend",
            "sender": ["user_id": "wxid_bot", "nickname": "wxid_bot"],
            "time": 1_760_000_000.0,
            "message_id": "1",
            "message": [["type": "text", "data": ["text": "hello"]]],
            "raw_message": "hello",
            "message_type": "private",
            "is_self": true
        ]
        let event = try XCTUnwrap(OneBotEventParser.parseEvent(raw, rawText: nil))
        XCTAssertTrue(event.isSelf)
        // 自消息必须落进对方会话，而不是自己 wxid 的会话。
        XCTAssertEqual(event.conversationID, "wxid_friend")
        XCTAssertEqual(event.userID, "wxid_bot")
    }

    func testParserIncomingPrivateStaysWithSenderConversation() throws {
        let raw: [String: Any] = [
            "self_id": "wxid_bot",
            "user_id": "wxid_friend",
            "sender": ["user_id": "wxid_friend", "nickname": "好友"],
            "time": 1_760_000_000.0,
            "message_id": "2",
            "message": [["type": "text", "data": ["text": "hi"]]],
            "raw_message": "hi",
            "message_type": "private"
        ]
        let event = try XCTUnwrap(OneBotEventParser.parseEvent(raw, rawText: nil))
        XCTAssertFalse(event.isSelf)
        XCTAssertEqual(event.conversationID, "wxid_friend")
    }

    func testParserSelfGroupUsesGroupConversation() throws {
        let raw: [String: Any] = [
            "group_id": "123@chatroom",
            "self_id": "wxid_bot",
            "user_id": "wxid_bot",
            "target_id": "123@chatroom",
            "sender": ["user_id": "wxid_bot", "nickname": "wxid_bot"],
            "time": 1_760_000_000.0,
            "message_id": "3",
            "message": [["type": "text", "data": ["text": "reply"]]],
            "raw_message": "reply",
            "message_type": "group",
            "is_self": true
        ]
        let event = try XCTUnwrap(OneBotEventParser.parseEvent(raw, rawText: nil))
        XCTAssertTrue(event.isSelf)
        XCTAssertEqual(event.conversationID, "123@chatroom")
    }

    // MARK: Data repair

    func testRepairMovesSelfMessagesToCorrectConversationsAndIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-routing-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        let bot = "wxid_bot"
        let friend = "wxid_friend"
        let group = "123@chatroom"
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        try await store.upsertConversations([
            Conversation(id: bot, kind: .direct, title: bot),
            Conversation(id: friend, kind: .direct, title: "好友")
        ])

        // 对方发来的入站消息（保留）。
        try await store.upsertMessages([
            ChatMessage(
                id: "m-friend-in",
                conversationID: friend,
                senderID: friend,
                senderName: "好友",
                direction: .incoming,
                text: "hi",
                timestamp: now
            )
        ])

        // 旧 hook 误路由的三条自消息：私聊×2 + 群×1。
        func selfRaw(selfID: String, groupID: String = "") -> String {
            let object: [String: Any] = [
                "self_id": selfID,
                "user_id": bot,
                "group_id": groupID,
                "message_id": UUID().uuidString,
                "message_type": groupID.isEmpty ? "private" : "group"
            ]
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(data: data, encoding: .utf8)!
        }
        try await store.upsertMessages([
            ChatMessage(
                id: "m-self-friend",
                conversationID: bot,
                senderID: bot,
                senderName: bot,
                direction: .incoming,
                text: "reply to friend",
                timestamp: now.addingTimeInterval(300),
                rawJSON: selfRaw(selfID: friend)
            ),
            ChatMessage(
                id: "m-self-filehelper",
                conversationID: bot,
                senderID: bot,
                senderName: bot,
                direction: .incoming,
                text: "seed",
                timestamp: now.addingTimeInterval(400),
                rawJSON: selfRaw(selfID: "filehelper")
            ),
            ChatMessage(
                id: "m-self-group",
                conversationID: bot,
                senderID: bot,
                senderName: bot,
                direction: .incoming,
                text: "group reply",
                timestamp: now.addingTimeInterval(200),
                rawJSON: selfRaw(selfID: bot, groupID: group)
            )
        ])

        let result = try await store.repairSelfRoutedMessages(selfID: bot)
        XCTAssertEqual(result.movedMessages, 3)
        XCTAssertTrue(result.removedSelfConversation)
        XCTAssertEqual(Set(result.affectedConversationIDs), Set([friend, "filehelper", group]))

        // 「自己」会话被删除。
        let conversations = try await store.fetchConversations(limit: 50)
        XCTAssertFalse(conversations.contains { $0.id == bot })

        // 私聊自消息归位为 outgoing。
        let friendMessages = try await store.fetchMessages(conversationID: friend, limit: 50)
        let movedReply = try XCTUnwrap(friendMessages.first { $0.id == "m-self-friend" })
        XCTAssertEqual(movedReply.direction, .outgoing)
        XCTAssertEqual(movedReply.senderName, "我")
        XCTAssertEqual(movedReply.status, .sent)

        // 文件传输助手会话被创建并带中文标题。
        let filehelper = try XCTUnwrap(conversations.first { $0.id == "filehelper" })
        XCTAssertEqual(filehelper.title, "文件传输助手")
        XCTAssertEqual(filehelper.lastMessagePreview, "seed")

        // 群自消息回到群会话。
        let groupMessages = try await store.fetchMessages(conversationID: group, limit: 10)
        XCTAssertEqual(groupMessages.map(\.id), ["m-self-group"])
        XCTAssertEqual(groupMessages.first?.direction, .outgoing)

        // 好友会话预览按最新消息重算（自消息 300 晚于入站 0）。
        let friendConversationValue = try await store.conversation(id: friend)
        let friendConversation = try XCTUnwrap(friendConversationValue)
        XCTAssertEqual(friendConversation.lastMessagePreview, "reply to friend")
        XCTAssertEqual(
            friendConversation.lastMessageAt?.timeIntervalSince1970,
            now.addingTimeInterval(300).timeIntervalSince1970
        )

        // 幂等：再跑一次不动任何东西。
        let second = try await store.repairSelfRoutedMessages(selfID: bot)
        XCTAssertEqual(second.movedMessages, 0)
        XCTAssertFalse(second.removedSelfConversation)
        XCTAssertFalse(second.didChange)
    }

    /// selfID 被旧事件污染成好友时，修复仍应从历史事件反推真实账号，
    /// 绝不能把好友会话里的正常消息搬走。
    func testRepairUsesInferredAccountEvenWhenStoredSelfIDIsPoisoned() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-routing-infer-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        let bot = "wxid_bot"
        let friend = "wxid_friend"
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        try await store.upsertConversation(Conversation(id: bot, kind: .direct, title: bot))

        // 三个不同好友的入站消息：self_id 都是 bot，user_id 各不相同 → 反推出 bot。
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

        // 自会话里的三条误路由消息（私聊对象 = friend）。
        try await store.upsertMessages([
            ChatMessage(id: "self-1", conversationID: bot, senderID: bot, senderName: bot,
                        direction: .incoming, text: "r1", timestamp: now.addingTimeInterval(10),
                        rawJSON: #"{"self_id":"wxid_friend","user_id":"wxid_bot","group_id":""}"#),
            ChatMessage(id: "self-2", conversationID: bot, senderID: bot, senderName: bot,
                        direction: .incoming, text: "r2", timestamp: now.addingTimeInterval(11),
                        rawJSON: #"{"self_id":"wxid_friend","user_id":"wxid_bot","group_id":""}"#),
            ChatMessage(id: "self-3", conversationID: bot, senderID: bot, senderName: bot,
                        direction: .incoming, text: "r3", timestamp: now.addingTimeInterval(12),
                        rawJSON: #"{"self_id":"wxid_friend","user_id":"wxid_bot","group_id":""}"#)
        ])

        // 传入被污染的 selfID（好友），修复必须用反推账号 bot。
        let result = try await store.repairSelfRoutedMessages(selfID: friend)
        XCTAssertEqual(result.inferredSelfID, bot)
        XCTAssertEqual(result.movedMessages, 3)
        XCTAssertTrue(result.removedSelfConversation)

        // 三条自消息应落到好友会话并标 outgoing，而不是把好友会话当成「自己」搬空。
        let friendMessages = try await store.fetchMessages(conversationID: friend, limit: 50)
        XCTAssertEqual(friendMessages.map(\.id).sorted(), ["self-1", "self-2", "self-3"])
        XCTAssertTrue(friendMessages.allSatisfy { $0.direction == .outgoing })

        // 三个好友各自的入站消息仍在原会话。
        for (conversation, messageID) in [("wxid_a", "in-1"), ("wxid_b", "in-2"), ("wxid_c", "in-3")] {
            let messages = try await store.fetchMessages(conversationID: conversation, limit: 10)
            XCTAssertEqual(messages.map(\.id), [messageID])
            XCTAssertEqual(messages.first?.direction, .incoming)
        }
    }
}
