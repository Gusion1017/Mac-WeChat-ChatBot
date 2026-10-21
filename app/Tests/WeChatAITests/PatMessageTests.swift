import XCTest
@testable import WeChatAI

final class PatMessageTests: XCTestCase {
    // MARK: Parsing

    func testParsesAppmsgPatInfoFromEventJSON() throws {
        // 4.1.15.55 实测形态：appmsg type=49 + <type>62</type> + <patinfo>。
        let rawJSON = #"""
        {"self_id":"wxid_bot","user_id":"wxid_friend","group_id":"123@chatroom",
         "message_type":"group","msg_type":49,
         "raw_message":"<msg><appmsg><title>&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;</title><type>62</type><patinfo><fromusername>wxid_friend</fromusername><chatusername>123@chatroom</chatusername><pattedusername>wxid_bot</pattedusername><patsuffix>的肩膀</patsuffix><template>&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;</template></patinfo></appmsg></msg>"}
        """#
        let event = try XCTUnwrap(PatMessage.event(from: rawJSON))
        XCTAssertEqual(event.fromID, "wxid_friend")
        XCTAssertEqual(event.chatID, "123@chatroom")
        XCTAssertEqual(event.targetID, "wxid_bot")
        XCTAssertEqual(event.suffix, "的肩膀")
        XCTAssertEqual(event.template, "\"小明\" 拍了拍 \"测试机器人\"")
    }

    func testParsesUnicodeEscapedXML() throws {
        // Go bridge 的 encoding/json 会把 <>& 转成 \u003c 等转义。
        let rawJSON = #"""
        {"msg_type":49,"raw_message":"\u003cmsg\u003e\u003cappmsg\u003e\u003ctitle\u003e\u0026quot;小明\u0026quot; 拍了拍我\u003c/title\u003e\u003ctype\u003e62\u003c/type\u003e\u003cpatinfo\u003e\u003cfromusername\u003ewxid_friend\u003c/fromusername\u003e\u003cchatusername\u003e123@chatroom\u003c/chatusername\u003e\u003cpattedusername\u003ewxid_bot\u003c/pattedusername\u003e\u003cpatsuffix\u003e\u0026lt;3\u0026gt; \u0026amp; \u0026apos;x\u0026apos;\u003c/patsuffix\u003e\u003ctemplate\u003e\u0026quot;小明\u0026quot; 拍了拍我\u003c/template\u003e\u003c/patinfo\u003e\u003c/appmsg\u003e\u003c/msg\u003e"}
        """#
        let event = try XCTUnwrap(PatMessage.event(from: rawJSON))
        XCTAssertEqual(event.targetID, "wxid_bot")
        XCTAssertEqual(event.suffix, "<3> & 'x'", "&lt; &gt; &amp; &apos; 应反转义")
        XCTAssertEqual(event.template, "\"小明\" 拍了拍我")
    }

    func testParsesDoubleEscapedRawMessage() throws {
        // raw_message 被二次转义：JSON 解码后仍残留字面量 \u003c。
        let rawJSON = #"""
        {"msg_type":49,"raw_message":"\\u003cmsg\\u003e\\u003cappmsg\\u003e\\u003ctype\\u003e62\\u003c/type\\u003e\\u003cpatinfo\\u003e\\u003cfromusername\\u003ewxid_friend\\u003c/fromusername\\u003e\\u003cchatusername\\u003e123@chatroom\\u003c/chatusername\\u003e\\u003cpattedusername\\u003ewxid_bot\\u003c/pattedusername\\u003e\\u003c/patinfo\\u003e\\u003c/appmsg\\u003e\\u003c/msg\\u003e"}
        """#
        let event = try XCTUnwrap(PatMessage.event(from: rawJSON))
        XCTAssertEqual(event.fromID, "wxid_friend")
        XCTAssertEqual(event.chatID, "123@chatroom")
        XCTAssertEqual(event.targetID, "wxid_bot")
    }

    func testParsesRawJSONThatIsXML() throws {
        let xml = #"<msg><appmsg><type>62</type><patinfo><fromusername>wxid_friend</fromusername><pattedusername>wxid_bot</pattedusername></patinfo></appmsg></msg>"#
        let event = try XCTUnwrap(PatMessage.event(from: xml))
        XCTAssertEqual(event.fromID, "wxid_friend")
        XCTAssertEqual(event.targetID, "wxid_bot")
    }

    func testParsesLegacySysmsgPat() throws {
        // 4.1.12：<sysmsg type="pat"><pat>…</pat></sysmsg>。
        let rawJSON = #"""
        {"msg_type":10000,"raw_message":"<sysmsg type=\"pat\"><pat><fromusername>wxid_friend</fromusername><chatusername>123@chatroom</chatusername><pattedusername>wxid_bot</pattedusername><patsuffix>的狗头</patsuffix><template>&quot;小明&quot; 拍了拍 &quot;测试机器人&quot; 的狗头</template></pat></sysmsg>"}
        """#
        let event = try XCTUnwrap(PatMessage.event(from: rawJSON))
        XCTAssertEqual(event.fromID, "wxid_friend")
        XCTAssertEqual(event.chatID, "123@chatroom")
        XCTAssertEqual(event.targetID, "wxid_bot")
        XCTAssertEqual(event.suffix, "的狗头")
        XCTAssertEqual(event.template, "\"小明\" 拍了拍 \"测试机器人\" 的狗头")
    }

    func testParsesLegacyPatmsgElement() throws {
        // 部分旧版把字段直接放在 <patmsg> 下。
        let rawJSON = #"{"msg_type":10000,"raw_message":"<patmsg><fromusername>wxid_friend</fromusername><chatusername>123@chatroom</chatusername><pattedusername>wxid_bot</pattedusername><patsuffix>的狗头</patsuffix></patmsg>"}"#
        let event = try XCTUnwrap(PatMessage.event(from: rawJSON))
        XCTAssertEqual(event.fromID, "wxid_friend")
        XCTAssertEqual(event.chatID, "123@chatroom")
        XCTAssertEqual(event.targetID, "wxid_bot")
        XCTAssertEqual(event.suffix, "的狗头")
    }

    func testStructuredFieldsTakePriorityOverXML() throws {
        let rawJSON = #"""
        {"pat_from_wxid":"wxid_friend","pat_chat_wxid":"123@chatroom","pat_target_wxid":"wxid_bot","pat_suffix":"的毛","pat_template":"结构化模板","raw_message":"<msg><appmsg><type>62</type><patinfo><fromusername>wxid_other</fromusername><pattedusername>wxid_someone_else</pattedusername></patinfo></appmsg></msg>"}
        """#
        let event = try XCTUnwrap(PatMessage.event(from: rawJSON))
        XCTAssertEqual(event.fromID, "wxid_friend")
        XCTAssertEqual(event.chatID, "123@chatroom")
        XCTAssertEqual(event.targetID, "wxid_bot")
        XCTAssertEqual(event.suffix, "的毛")
        XCTAssertEqual(event.template, "结构化模板")
    }

    func testStructuredFieldsInsideDataWrapper() throws {
        let rawJSON = #"""
        {"data":{"pat_from_wxid":"wxid_friend","pat_chat_wxid":"123@chatroom","pat_target_wxid":"wxid_bot"}}
        """#
        let event = try XCTUnwrap(PatMessage.event(from: rawJSON))
        XCTAssertEqual(event.fromID, "wxid_friend")
        XCTAssertEqual(event.chatID, "123@chatroom")
        XCTAssertEqual(event.targetID, "wxid_bot")
        XCTAssertNil(event.suffix)
        XCTAssertNil(event.template)
    }

    func testMissingPattedUsernameDoesNotGuessTarget() throws {
        let rawJSON = #"""
        {"msg_type":49,"raw_message":"<msg><appmsg><type>62</type><patinfo><fromusername>wxid_friend</fromusername><chatusername>123@chatroom</chatusername><template>&quot;小明&quot; 拍了拍我</template></patinfo></appmsg></msg>"}
        """#
        let event = try XCTUnwrap(PatMessage.event(from: rawJSON))
        XCTAssertEqual(event.targetID, "", "没有 pattedusername 时不得硬猜目标")
        XCTAssertEqual(event.template, "\"小明\" 拍了拍我")
    }

    func testNonPatPayloadsReturnNil() {
        XCTAssertNil(PatMessage.event(from: nil))
        XCTAssertNil(PatMessage.event(from: ""))
        // 纯文本消息即使正文含「拍了拍」也不是拍一拍。
        XCTAssertNil(PatMessage.event(from: #"{"raw_message":"我刚才拍了拍他"}"#))
        XCTAssertNil(PatMessage.event(from: #"{"msg_type":49,"raw_message":"<msg><appmsg><type>5</type><title>一条链接</title></appmsg></msg>"}"#))
        XCTAssertNil(PatMessage.event(from: #"{"raw_message":"<sysmsg type=\"sysmsg\"><text>拍了拍</text></sysmsg>"}"#))
        XCTAssertNil(PatMessage.event(from: #"{"message":[{"type":"text","data":{"text":"拍了拍"}}]}"#))
    }

    // MARK: Rule decision

    func testGroupPatTargetSelfIsDirected() {
        let rawJSON = appmsgPat(target: "wxid_bot", template: "&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;")
        XCTAssertTrue(PatMessage.isDirectedAtBot(
            message("小明 拍了拍我", rawJSON: rawJSON), conversation: groupConversation(),
            selfID: "wxid_bot", selfMentionName: nil
        ))
    }

    func testGroupPatTargetOtherIsNotDirected() {
        let rawJSON = appmsgPat(target: "wxid_someone_else", template: "&quot;小明&quot; 拍了拍 &quot;别人&quot;")
        XCTAssertFalse(PatMessage.isDirectedAtBot(
            message("小明 拍了拍 别人", rawJSON: rawJSON), conversation: groupConversation(),
            selfID: "wxid_bot", selfMentionName: nil
        ))
    }

    func testPatTargetComparisonIgnoresCase() {
        let rawJSON = appmsgPat(target: "WXID_BOT")
        XCTAssertTrue(PatMessage.isDirectedAtBot(
            message("", rawJSON: rawJSON), conversation: groupConversation(),
            selfID: "wxid_bot", selfMentionName: nil
        ))
    }

    func testGroupPlainTextMentioningPatIsNotDirected() {
        // 用户聊天里说「我刚才拍了拍他」，没有 patinfo / type 62 / sysmsg type=pat。
        XCTAssertFalse(PatMessage.isDirectedAtBot(
            message("我刚才拍了拍他", rawJSON: nil), conversation: groupConversation(),
            selfID: "wxid_bot", selfMentionName: "测试机器人"
        ))
        XCTAssertFalse(PatMessage.isDirectedAtBot(
            message("我刚才拍了拍他", rawJSON: #"{"raw_message":"我刚才拍了拍他"}"#),
            conversation: groupConversation(), selfID: "wxid_bot", selfMentionName: nil
        ))
    }

    func testGroupMissingTargetFallsBackToSelfIDOrLearnedNickname() {
        let rawJSON = legacySysmsgPat(target: nil, template: "&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;")
        let conversation = groupConversation()
        XCTAssertTrue(PatMessage.isDirectedAtBot(
            message("", rawJSON: rawJSON), conversation: conversation,
            selfID: "wxid_bot", selfMentionName: "测试机器人"
        ))
        XCTAssertFalse(PatMessage.isDirectedAtBot(
            message("", rawJSON: rawJSON), conversation: conversation,
            selfID: "wxid_bot", selfMentionName: nil
        ))

        let mentionsSelfID = legacySysmsgPat(target: nil, template: "&quot;小明&quot; 拍了拍 wxid_bot")
        XCTAssertTrue(PatMessage.isDirectedAtBot(
            message("", rawJSON: mentionsSelfID), conversation: conversation,
            selfID: "wxid_bot", selfMentionName: nil
        ))
    }

    func testGroupMissingTargetWithoutSelfReferenceIsNotDirected() {
        // 群聊里「拍了拍我」无法确定「我」是谁，不能用它硬猜机器人。
        let rawJSON = legacySysmsgPat(target: nil, template: "&quot;小明&quot; 拍了拍我")
        XCTAssertFalse(PatMessage.isDirectedAtBot(
            message("小明 拍了拍我", rawJSON: rawJSON), conversation: groupConversation(),
            selfID: "wxid_bot", selfMentionName: nil
        ))
    }

    func testDirectPatMeWithoutTargetIsDirected() {
        let conversation = Conversation(id: "wxid_friend", kind: .direct, title: "小明")
        let chinese = legacySysmsgPat(target: nil, template: "&quot;小明&quot; 拍了拍我")
        XCTAssertTrue(PatMessage.isDirectedAtBot(
            message("", rawJSON: chinese), conversation: conversation,
            selfID: "wxid_bot", selfMentionName: nil
        ))

        let english = legacySysmsgPat(target: nil, template: "&quot;小明&quot; patted me")
        XCTAssertTrue(PatMessage.isDirectedAtBot(
            message("", rawJSON: english), conversation: conversation,
            selfID: "wxid_bot", selfMentionName: nil
        ))
    }

    func testStructuredEventWithoutXMLIsDirected() {
        let rawJSON = #"{"pat_target_wxid":"wxid_bot"}"#
        XCTAssertTrue(PatMessage.isDirectedAtBot(
            message("", rawJSON: rawJSON), conversation: groupConversation(),
            selfID: "wxid_bot", selfMentionName: nil
        ))
    }

    // MARK: Reply mention

    /// 群聊被拍后 @ 拍的人：只有群聊、开关开启且拍的人是有效 wxid 时才返回目标。
    func testReplyMentionOnlyForGroupChatWithValidPatter() {
        let group = groupConversation()
        let direct = Conversation(id: "wxid_friend", kind: .direct, title: "小明")
        let patJSON = appmsgPat(target: "wxid_bot")

        let mention = PatMessage.replyMention(
            message("", rawJSON: patJSON), conversation: group,
            selfID: "wxid_bot", enabled: true
        )
        XCTAssertEqual(mention?.userID, "wxid_friend")
        XCTAssertEqual(mention?.displayName, "小明")
        XCTAssertEqual(mention?.localText("收到"), "@小明\u{2005}收到")

        XCTAssertNil(PatMessage.replyMention(
            message("", rawJSON: patJSON), conversation: group,
            selfID: "wxid_bot", enabled: false
        ), "开关关闭时不 @")
        XCTAssertNil(PatMessage.replyMention(
            message("", rawJSON: patJSON, conversationID: "wxid_friend"), conversation: direct,
            selfID: "wxid_bot", enabled: true
        ), "私聊不 @")
    }

    /// 自己/群 ID/占位账号不能作为 @ 目标；事件缺 senderID 时回退 pat_from_wxid。
    func testReplyMentionRejectsInvalidTargetsAndFallsBackToEventSender() {
        let group = groupConversation()
        func mention(senderID: String, senderName: String = "小明",
                     rawJSON: String? = nil) -> PatMention? {
            let incoming = ChatMessage(
                id: UUID().uuidString, conversationID: group.id, senderID: senderID,
                senderName: senderName, direction: .incoming, text: "",
                timestamp: Date(), rawJSON: rawJSON
            )
            return PatMessage.replyMention(
                incoming, conversation: group, selfID: "wxid_bot", enabled: true
            )
        }

        XCTAssertNil(mention(senderID: "wxid_bot"), "不能 @ 机器人自己")
        XCTAssertNil(mention(senderID: "123@chatroom"), "群 ID 不是可 @ 的人")
        XCTAssertNil(mention(senderID: "self"), "占位账号不 @")
        let unreadable = mention(senderID: "wxid_friend", senderName: "wxid_friend")
        XCTAssertNotNil(unreadable, "有有效 wxid 时仍应 @，只是本地不伪造昵称")
        XCTAssertNil(unreadable?.displayName, "不可读昵称不伪造 @昵称 文本")
        XCTAssertEqual(unreadable?.localText("收到"), "收到")
        XCTAssertEqual(
            mention(senderID: "", rawJSON: #"{"pat_from_wxid":"wxid_friend"}"#)?.userID,
            "wxid_friend",
            "senderID 缺失时回退 pat_from_wxid"
        )
    }

    // MARK: Helpers

    private func groupConversation() -> Conversation {
        Conversation(id: "123@chatroom", kind: .group, title: "测试群")
    }

    private func message(_ text: String, rawJSON: String?,
                         conversationID: String = "123@chatroom") -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString, conversationID: conversationID, senderID: "wxid_friend",
            senderName: "小明", direction: .incoming, text: text,
            timestamp: Date(), rawJSON: rawJSON
        )
    }

    /// 4.1.15 appmsg 拍一拍；target 为 nil 时模拟没有 pattedusername 的旧数据。
    private func appmsgPat(target: String?, template: String = "nudged") -> String {
        var fields = "<fromusername>wxid_friend</fromusername><chatusername>123@chatroom</chatusername>"
        if let target {
            fields += "<pattedusername>\(target)</pattedusername>"
        }
        fields += "<template>\(template)</template>"
        let xml = "<msg><appmsg><type>62</type><patinfo>\(fields)</patinfo></appmsg></msg>"
        let event: [String: Any] = [
            "self_id": "wxid_bot",
            "user_id": "wxid_friend",
            "group_id": "123@chatroom",
            "message_type": "group",
            "msg_type": 49,
            "raw_message": xml
        ]
        let data = try! JSONSerialization.data(withJSONObject: event)
        return String(data: data, encoding: .utf8)!
    }

    /// 4.1.12 sysmsg 拍一拍；target 为 nil 时模拟没有 pattedusername / <pat> 里只带模板。
    private func legacySysmsgPat(target: String?, template: String) -> String {
        var fields = "<fromusername>wxid_friend</fromusername><chatusername>123@chatroom</chatusername>"
        if let target {
            fields += "<pattedusername>\(target)</pattedusername>"
        }
        fields += "<template>\(template)</template>"
        let xml = "<sysmsg type=\"pat\"><pat>\(fields)</pat></sysmsg>"
        let event: [String: Any] = [
            "self_id": "wxid_bot",
            "user_id": "wxid_friend",
            "group_id": "123@chatroom",
            "message_type": "group",
            "msg_type": 10000,
            "raw_message": xml
        ]
        let data = try! JSONSerialization.data(withJSONObject: event)
        return String(data: data, encoding: .utf8)!
    }
}
