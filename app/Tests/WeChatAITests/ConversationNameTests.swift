import XCTest
@testable import WeChatAI

/// 会话展示名与标题清洗：微信 4.1.15 只下发 wxid，展示层必须永远给出可读名称。
final class ConversationNameTests: XCTestCase {
    // MARK: 展示名

    func testSystemAccountsUseCanonicalChineseNames() {
        XCTAssertEqual(
            ConversationName.displayTitle(kind: .direct, conversationID: "filehelper", storedTitle: ""),
            "文件传输助手"
        )
        XCTAssertEqual(
            ConversationName.displayTitle(kind: .direct, conversationID: "weixin", storedTitle: ""),
            "微信团队"
        )
        // 旧数据把 ID 写成标题：仍按系统账号映射展示。
        XCTAssertEqual(
            ConversationName.displayTitle(kind: .direct, conversationID: "filehelper", storedTitle: "filehelper"),
            "文件传输助手"
        )
    }

    func testUnknownDirectConversationFallsBackToFriendLabel() {
        let id = "wxid_test_friend"
        XCTAssertEqual(
            ConversationName.displayTitle(kind: .direct, conversationID: id, storedTitle: ""),
            "微信好友 · friend"
        )
        // 旧版本把 wxid 落库成标题。
        XCTAssertEqual(
            ConversationName.displayTitle(kind: .direct, conversationID: id, storedTitle: id),
            "微信好友 · friend"
        )
        XCTAssertEqual(
            ConversationName.displayTitle(kind: .direct, conversationID: id, storedTitle: "wxid_test_self"),
            "微信好友 · friend"
        )
    }

    func testGroupConversationFallsBackToGroupLabel() {
        let id = "123456789@chatroom"
        XCTAssertEqual(
            ConversationName.displayTitle(kind: .group, conversationID: id, storedTitle: ""),
            "群聊 · 456789"
        )
        // 旧版本写入的「群聊 <群 ID>」不是可用标题。
        XCTAssertEqual(
            ConversationName.displayTitle(kind: .group, conversationID: id, storedTitle: "群聊 \(id)"),
            "群聊 · 456789"
        )
    }

    func testOfficialAccountFallsBackToOfficialLabel() {
        XCTAssertEqual(
            ConversationName.displayTitle(kind: .direct, conversationID: "gh_abcdef123456", storedTitle: ""),
            "公众号 · 123456"
        )
    }

    func testCustomTitleWinsOverAutomaticName() {
        let conversation = Conversation(id: "wxid_test_friend", kind: .direct, title: "测试好友")
        XCTAssertEqual(conversation.customTitle, "测试好友")
        XCTAssertEqual(conversation.displayTitle, "测试好友")

        let group = Conversation(id: "123456789@chatroom", kind: .group, title: "群聊 兄弟")
        XCTAssertEqual(group.customTitle, "群聊 兄弟")
        XCTAssertEqual(group.displayTitle, "群聊 兄弟")
    }

    // MARK: 标题学习

    func testLearningRejectsIDLikeNames() {
        let conversationID = "wxid_test_friend"
        XCTAssertNil(ConversationName.learnedTitle(
            from: "wxid_test_friend",
            conversationID: conversationID,
            senderID: "wxid_test_friend",
            selfID: "wxid_test_self"
        ))
        XCTAssertNil(ConversationName.learnedTitle(
            from: conversationID,
            conversationID: conversationID,
            senderID: "wxid_other",
            selfID: ""
        ))
        XCTAssertNil(ConversationName.learnedTitle(
            from: "我",
            conversationID: conversationID,
            senderID: "wxid_other",
            selfID: ""
        ))
        XCTAssertNil(ConversationName.learnedTitle(
            from: "123456789@chatroom",
            conversationID: conversationID,
            senderID: "wxid_other",
            selfID: ""
        ))
        XCTAssertNil(ConversationName.learnedTitle(
            from: "wxid_test_self",
            conversationID: conversationID,
            senderID: "wxid_other",
            selfID: "wxid_test_self"
        ))
        // sender 自己的 wxid 也不能当昵称。
        XCTAssertNil(ConversationName.learnedTitle(
            from: "wxid_other",
            conversationID: conversationID,
            senderID: "wxid_other",
            selfID: ""
        ))
    }

    func testLearningAcceptsReadableNickname() {
        XCTAssertEqual(
            ConversationName.learnedTitle(
                from: " 小王 ",
                conversationID: "wxid_test_friend",
                senderID: "wxid_test_friend",
                selfID: "wxid_test_self"
            ),
            "小王"
        )
    }

    // MARK: 历史数据清洗

    func testRepairClearsLegacyIDTitlesOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-name-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        let directWxid = "wxid_test_friend"
        let groupID = "123456789@chatroom"
        try await store.upsertConversation(Conversation(id: directWxid, kind: .direct, title: directWxid))
        try await store.upsertConversation(Conversation(id: groupID, kind: .group, title: "群聊 \(groupID)"))
        try await store.upsertConversation(Conversation(id: "wxid_custom", kind: .direct, title: "测试好友"))
        try await store.upsertConversation(Conversation(id: "filehelper", kind: .direct, title: "wxid_test_self"))

        let repaired = try await store.repairPlaceholderConversationTitles()
        XCTAssertEqual(repaired, 3)

        let conversations = try await store.fetchConversations(limit: 50)
        let direct = try XCTUnwrap(conversations.first { $0.id == directWxid })
        XCTAssertEqual(direct.title, "")
        XCTAssertEqual(direct.displayTitle, "微信好友 · friend")

        let group = try XCTUnwrap(conversations.first { $0.id == groupID })
        XCTAssertEqual(group.title, "")
        XCTAssertEqual(group.displayTitle, "群聊 · 456789")

        let custom = try XCTUnwrap(conversations.first { $0.id == "wxid_custom" })
        XCTAssertEqual(custom.title, "测试好友")

        let filehelper = try XCTUnwrap(conversations.first { $0.id == "filehelper" })
        XCTAssertEqual(filehelper.title, "")
        XCTAssertEqual(filehelper.displayTitle, "文件传输助手")

        // 幂等：第二次不再更新任何行。
        let secondPass = try await store.repairPlaceholderConversationTitles()
        XCTAssertEqual(secondPass, 0)
    }
}
