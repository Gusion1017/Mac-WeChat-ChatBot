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

        // 文件传输助手会话被创建，标题留空由 ConversationName 兜底成中文名。
        let filehelper = try XCTUnwrap(conversations.first { $0.id == "filehelper" })
        XCTAssertEqual(filehelper.title, "")
        XCTAssertEqual(filehelper.displayTitle, "文件传输助手")
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

    // MARK: Misrouted conversations (self wxid / placeholder / fake group)

    /// 旧 hook 把私聊拍一拍的 chatusername（wxid）写进 group_id：parser 不能当群，
    /// 必须落到对方私聊且 kind=direct。
    func testParserDirtyGroupIDFallsBackToPeerDirectConversation() throws {
        let raw: [String: Any] = [
            "self_id": "wxid_bot",
            "user_id": "wxid_friend",
            "group_id": "wxid_bot",
            "pat_chat_wxid": "wxid_bot",
            "pat_from_wxid": "wxid_friend",
            "pat_target_wxid": "wxid_bot",
            "from_wxid": "wxid_friend",
            "to_wxid": "wxid_bot",
            "sender_wxid": "wxid_friend",
            "sender": ["user_id": "wxid_friend", "nickname": "好友"],
            "time": 1_760_000_000.0,
            "message_id": "pat-1",
            "message": [["type": "text", "data": ["text": "好友 拍了拍我"]]],
            "raw_message": "好友 拍了拍我",
            "message_type": "group"
        ]
        let event = try XCTUnwrap(OneBotEventParser.parseEvent(raw, rawText: nil))
        XCTAssertFalse(event.isGroup)
        XCTAssertEqual(event.conversationID, "wxid_friend")
        XCTAssertEqual(event.conversationKind, .direct)
        XCTAssertFalse(event.isSelf)
    }

    /// E 形态：旧 hook 把私聊拍一拍记进「自己 wxid」的伪群会话。
    /// 三条拍一拍应搬回好友私聊（incoming），自己会话删除，二次运行无变化。
    func testRepairMisroutedConversationsMovesSelfGroupPatsToFriend() async throws {
        try await withTemporaryMemoryStore { store in
            let bot = "wxid_bot"
            let friend = "wxid_friend"
            let now = Date(timeIntervalSince1970: 1_760_000_000)

            try await store.upsertConversations([
                Conversation(id: bot, kind: .group, title: bot),
                Conversation(id: friend, kind: .direct, title: "好友"),
                Conversation(id: "wxid_health", kind: .direct, title: "健康会话")
            ])
            try await store.upsertMessages([
                ChatMessage(id: "health-1", conversationID: "wxid_health", senderID: "wxid_health",
                            senderName: "健康会话", direction: .incoming, text: "正常消息", timestamp: now)
            ])

            func patRaw(index: Int) -> String {
                rawJSONString([
                    "self_id": bot,
                    "user_id": friend,
                    "group_id": bot,
                    "pat_chat_wxid": bot,
                    "pat_from_wxid": friend,
                    "pat_target_wxid": bot,
                    "from_wxid": friend,
                    "to_wxid": bot,
                    "sender_wxid": friend,
                    "sender": ["user_id": friend, "nickname": "好友"],
                    "message_type": "group",
                    "message_id": "pat-\(index)",
                    "message": [["type": "text", "data": ["text": "好友 拍了拍我"]]],
                    "raw_message": "好友 拍了拍我"
                ])
            }

            try await store.upsertMessages((1...3).map { index in
                ChatMessage(id: "pat-\(index)", conversationID: bot, senderID: bot, senderName: bot,
                            direction: .incoming, text: "好友 拍了拍我",
                            timestamp: now.addingTimeInterval(Double(index)),
                            rawJSON: patRaw(index: index))
            })

            // 旧修复修不了这种形态（非法 group_id 优先导致 target==self 被跳过）。
            let legacy = try await store.repairSelfRoutedMessages(selfID: bot)
            XCTAssertFalse(legacy.didChange)
            let untouchedCount = try await store.messageCount(conversationID: bot)
            XCTAssertEqual(untouchedCount, 3)

            let result = try await store.repairMisroutedConversations(selfID: bot)
            XCTAssertEqual(result.movedMessages, 3)
            XCTAssertEqual(result.affectedConversationIDs, [friend])
            XCTAssertEqual(result.removedConversationIDs, [bot])
            XCTAssertEqual(result.fixedKinds, 0)
            XCTAssertTrue(result.didChange)

            let conversations = try await store.fetchConversations(limit: 50)
            XCTAssertFalse(conversations.contains { $0.id == bot })
            let friendConversation = try XCTUnwrap(conversations.first { $0.id == friend })
            XCTAssertEqual(friendConversation.kind, .direct)

            let moved = try await store.fetchMessages(conversationID: friend, limit: 10)
            XCTAssertEqual(moved.map(\.id), ["pat-1", "pat-2", "pat-3"])
            XCTAssertTrue(moved.allSatisfy { $0.direction == .incoming })
            XCTAssertTrue(moved.allSatisfy { $0.senderID == friend && $0.senderName == "好友" })
            XCTAssertTrue(moved.allSatisfy { $0.status == .received })
            // 搬入消息后目标会话预览应按最新一条重算。
            XCTAssertEqual(friendConversation.lastMessagePreview, "好友 拍了拍我")
            XCTAssertEqual(friendConversation.lastMessageAt, now.addingTimeInterval(3))

            // 健康会话完全不动。
            let healthMessages = try await store.fetchMessages(conversationID: "wxid_health", limit: 10)
            XCTAssertEqual(healthMessages.map(\.id), ["health-1"])
            let healthConversation = try await store.conversation(id: "wxid_health")
            XCTAssertEqual(healthConversation?.kind, .direct)

            // 幂等：二次运行不再产生任何变化。
            let second = try await store.repairMisroutedConversations(selfID: bot)
            XCTAssertEqual(second.movedMessages, 0)
            XCTAssertTrue(second.removedConversationIDs.isEmpty)
            XCTAssertEqual(second.fixedKinds, 0)
            XCTAssertFalse(second.didChange)
        }
    }

    /// D 形态：旧 bridge 把 self_id 污染成字面量 `wxid_self`，自己发到群的回复
    /// 落进占位会话。三条回复应搬回群（outgoing），占位会话删除。
    func testRepairMisroutedConversationsMovesPlaceholderSelfGroupRepliesToGroup() async throws {
        try await withTemporaryMemoryStore { store in
            let bot = "wxid_bot"
            let friend = "wxid_friend"
            let group = "123@chatroom"
            let now = Date(timeIntervalSince1970: 1_760_000_000)

            try await store.upsertConversations([
                Conversation(id: "wxid_self", kind: .direct, title: ""),
                Conversation(id: group, kind: .group, title: "")
            ])
            try await store.upsertMessages([
                ChatMessage(id: "group-in", conversationID: group, senderID: friend, senderName: "好友",
                            direction: .incoming, text: "群里消息", timestamp: now)
            ])

            func replyRaw(index: Int) -> String {
                rawJSONString([
                    "self_id": "wxid_self",
                    "user_id": bot,
                    "group_id": "",
                    "from_wxid": bot,
                    "to_wxid": group,
                    "sender_wxid": bot,
                    "sender": ["user_id": bot, "nickname": bot],
                    "message_type": "private",
                    "message_id": "reply-\(index)",
                    "message": [["type": "text", "data": ["text": "群里回复"]]],
                    "raw_message": "群里回复"
                ])
            }
            try await store.upsertMessages((1...3).map { index in
                ChatMessage(id: "reply-\(index)", conversationID: "wxid_self", senderID: "wxid_self",
                            senderName: "wxid_self", direction: .incoming, text: "群里回复",
                            timestamp: now.addingTimeInterval(Double(index)),
                            rawJSON: replyRaw(index: index))
            })

            let result = try await store.repairMisroutedConversations(selfID: bot)
            XCTAssertEqual(result.movedMessages, 3)
            XCTAssertEqual(result.affectedConversationIDs, [group])
            XCTAssertEqual(result.removedConversationIDs, ["wxid_self"])
            XCTAssertTrue(result.didChange)

            let conversations = try await store.fetchConversations(limit: 50)
            XCTAssertFalse(conversations.contains { $0.id == "wxid_self" })
            let groupConversation = try XCTUnwrap(conversations.first { $0.id == group })
            XCTAssertEqual(groupConversation.kind, .group)

            let groupMessages = try await store.fetchMessages(conversationID: group, limit: 10)
            XCTAssertEqual(groupMessages.map(\.id), ["group-in", "reply-1", "reply-2", "reply-3"])
            let moved = groupMessages.filter { $0.id.hasPrefix("reply-") }
            XCTAssertTrue(moved.allSatisfy { $0.direction == .outgoing })
            XCTAssertTrue(moved.allSatisfy { $0.senderID == bot && $0.senderName == "我" })
            XCTAssertTrue(moved.allSatisfy { $0.status == .sent })
            XCTAssertEqual(groupConversation.lastMessagePreview, "群里回复")
            XCTAssertEqual(groupConversation.lastMessageAt, now.addingTimeInterval(3))

            let second = try await store.repairMisroutedConversations(selfID: bot)
            XCTAssertEqual(second.movedMessages, 0)
            XCTAssertFalse(second.didChange)
        }
    }

    /// 历史事件反推账号时必须跳过 `wxid_self` 占位候选，否则会被旧数据污染。
    func testRepairUsesInferredAccountAndIgnoresPlaceholderSelfID() async throws {
        try await withTemporaryMemoryStore { store in
            let bot = "wxid_bot"
            let friend = "wxid_friend"
            let poisoned = "wxid_poisoned"
            let now = Date(timeIntervalSince1970: 1_760_000_000)
            try await store.upsertConversation(Conversation(id: bot, kind: .direct, title: bot))

            var messages: [ChatMessage] = []
            // 占位 wxid_self 作为 self_id 出现 4 次、4 个不同发送者：
            // 不跳过的话它会被误判成账号。
            for (index, sender) in ["wxid_a", "wxid_b", "wxid_c", "wxid_d"].enumerated() {
                messages.append(ChatMessage(
                    id: "placeholder-\(index)", conversationID: sender, senderID: sender, senderName: sender,
                    direction: .incoming, text: "x", timestamp: now.addingTimeInterval(Double(index)),
                    rawJSON: #"{"self_id":"wxid_self","user_id":"\#(sender)"}"#
                ))
            }
            // 真实账号 bot 作为 self_id 出现 3 次、3 个不同发送者。
            for (index, sender) in ["wxid_e", "wxid_f", "wxid_g"].enumerated() {
                messages.append(ChatMessage(
                    id: "bot-\(index)", conversationID: sender, senderID: sender, senderName: sender,
                    direction: .incoming, text: "y", timestamp: now.addingTimeInterval(10 + Double(index)),
                    rawJSON: #"{"self_id":"wxid_bot","user_id":"\#(sender)"}"#
                ))
            }
            // 自己会话里一条旧 hook 误路由消息：保证修复有动作并暴露 inferredSelfID。
            messages.append(ChatMessage(
                id: "self-1", conversationID: bot, senderID: bot, senderName: bot,
                direction: .incoming, text: "reply", timestamp: now.addingTimeInterval(20),
                rawJSON: #"{"self_id":"wxid_friend","user_id":"wxid_bot","group_id":""}"#
            ))
            try await store.upsertMessages(messages)

            let result = try await store.repairSelfRoutedMessages(selfID: poisoned)
            XCTAssertEqual(result.inferredSelfID, bot)
            XCTAssertEqual(result.movedMessages, 1)
            let friendMessages = try await store.fetchMessages(conversationID: friend, limit: 10)
            XCTAssertEqual(friendMessages.map(\.id), ["self-1"])
            XCTAssertEqual(friendMessages.first?.direction, .outgoing)
        }
    }

    /// 伪群会话：id=wxid_friend 但 kind=group，消息目标就是当前会话（不能搬走）。
    /// kind 必须归一化为 direct，消息保留，二次运行不再变化（Lead 补充边界）。
    func testRepairMisroutedConversationsFixesFakeGroupKindWithoutMovingMessages() async throws {
        try await withTemporaryMemoryStore { store in
            let bot = "wxid_bot"
            let friend = "wxid_friend"
            let now = Date(timeIntervalSince1970: 1_760_000_000)

            try await store.upsertConversations([
                Conversation(id: friend, kind: .group, title: "好友")
            ])
            try await store.upsertMessages([
                ChatMessage(
                    id: "in-1", conversationID: friend, senderID: friend, senderName: "好友",
                    direction: .incoming, text: "你好", timestamp: now,
                    rawJSON: rawJSONString([
                        "self_id": bot,
                        "user_id": friend,
                        "group_id": "",
                        "from_wxid": friend,
                        "to_wxid": bot,
                        "sender_wxid": friend,
                        "sender": ["user_id": friend, "nickname": "好友"],
                        "message_type": "private"
                    ])
                )
            ])

            let result = try await store.repairMisroutedConversations(selfID: bot)
            XCTAssertEqual(result.movedMessages, 0)
            XCTAssertEqual(result.fixedKinds, 1)
            XCTAssertTrue(result.affectedConversationIDs.contains(friend))
            XCTAssertTrue(result.removedConversationIDs.isEmpty)
            XCTAssertTrue(result.didChange)

            let conversation = try await store.conversation(id: friend)
            XCTAssertEqual(conversation?.kind, .direct)
            let messages = try await store.fetchMessages(conversationID: friend, limit: 10)
            XCTAssertEqual(messages.map(\.id), ["in-1"])
            XCTAssertEqual(messages.first?.direction, .incoming)

            let second = try await store.repairMisroutedConversations(selfID: bot)
            XCTAssertFalse(second.didChange)
            XCTAssertEqual(second.fixedKinds, 0)
        }
    }

    /// 已存在的目标会话 kind 与推导结果不一致时（如群 ID 会话被标成 direct），
    /// 搬入前应修正为群聊；属于同一事务，二次运行幂等。
    func testRepairMisroutedConversationsFixesExistingTargetKind() async throws {
        try await withTemporaryMemoryStore { store in
            let bot = "wxid_bot"
            let group = "123@chatroom"
            let now = Date(timeIntervalSince1970: 1_760_000_000)

            try await store.upsertConversations([
                Conversation(id: "wxid_self", kind: .direct, title: ""),
                Conversation(id: group, kind: .direct, title: "测试群")
            ])
            try await store.upsertMessages([
                ChatMessage(
                    id: "reply-1", conversationID: "wxid_self", senderID: "wxid_self",
                    senderName: "wxid_self", direction: .incoming, text: "群回复", timestamp: now,
                    rawJSON: rawJSONString([
                        "self_id": "wxid_self",
                        "user_id": bot,
                        "group_id": "",
                        "from_wxid": bot,
                        "to_wxid": group,
                        "sender_wxid": bot,
                        "message_type": "private"
                    ])
                )
            ])

            let result = try await store.repairMisroutedConversations(selfID: bot)
            XCTAssertEqual(result.movedMessages, 1)
            XCTAssertEqual(result.fixedKinds, 1)
            XCTAssertTrue(result.removedConversationIDs.contains("wxid_self"))

            let groupConversation = try await store.conversation(id: group)
            XCTAssertEqual(groupConversation?.kind, .group)
            let messages = try await store.fetchMessages(conversationID: group, limit: 10)
            XCTAssertEqual(messages.map(\.id), ["reply-1"])
            XCTAssertEqual(messages.first?.direction, .outgoing)

            let second = try await store.repairMisroutedConversations(selfID: bot)
            XCTAssertFalse(second.didChange)
        }
    }

    /// 健康会话（正常私聊 + 正常群聊）不会被误判/搬移。
    func testRepairMisroutedConversationsLeavesHealthyConversationsAlone() async throws {
        try await withTemporaryMemoryStore { store in
            let bot = "wxid_bot"
            let friend = "wxid_friend"
            let group = "123@chatroom"
            let now = Date(timeIntervalSince1970: 1_760_000_000)

            try await store.upsertConversations([
                Conversation(id: friend, kind: .direct, title: "好友"),
                Conversation(id: group, kind: .group, title: "测试群")
            ])
            try await store.upsertMessages([
                ChatMessage(
                    id: "dm-1", conversationID: friend, senderID: friend, senderName: "好友",
                    direction: .incoming, text: "私聊", timestamp: now,
                    rawJSON: rawJSONString([
                        "self_id": bot, "user_id": friend, "group_id": "",
                        "from_wxid": friend, "to_wxid": bot, "sender_wxid": friend,
                        "message_type": "private"
                    ])
                ),
                ChatMessage(
                    id: "gm-1", conversationID: group, senderID: friend, senderName: "好友",
                    direction: .incoming, text: "群聊", timestamp: now.addingTimeInterval(1),
                    rawJSON: rawJSONString([
                        "self_id": bot, "user_id": friend, "group_id": group,
                        "from_wxid": group, "to_wxid": bot, "sender_wxid": friend,
                        "message_type": "group"
                    ])
                )
            ])

            let result = try await store.repairMisroutedConversations(selfID: bot)
            XCTAssertFalse(result.didChange)
            XCTAssertEqual(result.movedMessages, 0)
            XCTAssertTrue(result.removedConversationIDs.isEmpty)
            XCTAssertEqual(result.fixedKinds, 0)

            let conversations = try await store.fetchConversations(limit: 50)
            XCTAssertEqual(conversations.count, 2)
            XCTAssertEqual(conversations.first { $0.id == friend }?.kind, .direct)
            XCTAssertEqual(conversations.first { $0.id == group }?.kind, .group)
            let dmCount = try await store.messageCount(conversationID: friend)
            let gmCount = try await store.messageCount(conversationID: group)
            XCTAssertEqual(dmCount, 1)
            XCTAssertEqual(gmCount, 1)
        }
    }

    // MARK: - Helpers

    private func withTemporaryMemoryStore(
        _ body: (MemoryStore) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-routing-\(UUID().uuidString)", isDirectory: true)
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
