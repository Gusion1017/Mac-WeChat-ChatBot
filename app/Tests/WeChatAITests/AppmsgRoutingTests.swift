import XCTest
@testable import WeChatAI

/// 旧 hook 把「拍一拍」以外的 appmsg（引用回复 / 链接 / 文件 / 表情 / 聊天记录 /
/// 转账 / 视频号 …）统一写成 `[链接/文件]`，引用正文与被引用原文因此对 UI、规则引擎
/// 和 AI 都不可见。这里覆盖两条修复路径：
///
/// 1. 实时事件：`OneBotEventParser` 用 `WeChatAppmsg` 从 `raw_message` 还原文本；
/// 2. 历史消息：`MemoryStore.repairAppmsgMessageTexts()` 幂等重算并刷新会话预览。
///
/// 同时守住不回归的边界：拍一拍、普通文本、`at` 段、无法解析的占位都不动。
final class AppmsgRoutingTests: XCTestCase {
    // MARK: - 样本（虚构昵称/内容，避免把真实聊天记录带进仓库）

    private enum Sample {
        /// appmsg type=57：`<title>` 是回复正文，`<refermsg>` 是被引用原文。
        static let quoteXML = #"""
        <?xml version="1.0"?>
        <msg>
        	<appmsg appid="" sdkver="0">
        		<title>火锅局改到明晚吧</title>
        		<type>57</type>
        		<refermsg>
        			<type>1</type>
        			<svrid>1000000000000000001</svrid>
        			<fromusr>123@chatroom</fromusr>
        			<chatusr>wxid_zhangsan</chatusr>
        			<displayname>张三</displayname>
        			<content>
        明天晚上七点老地方吃火锅</content>
        			<createtime>1760000000</createtime>
        		</refermsg>
        	</appmsg>
        	<fromusername>wxid_lisi</fromusername>
        	<scene>0</scene>
        </msg>
        """#

        /// appmsg type=5：链接卡片。
        static let linkXML = #"""
        <?xml version="1.0"?>
        <msg>
        	<appmsg appid="wx_example" sdkver="0">
        		<title>一篇值得一读的文章</title>
        		<des>示例摘要</des>
        		<action>view</action>
        		<type>5</type>
        		<url>https://example.com/article</url>
        	</appmsg>
        	<fromusername>wxid_zhangsan</fromusername>
        </msg>
        """#

        /// appmsg type=62：拍一拍（hook 会先把 title 写进消息文本）。
        static let patXML = #"""
        <msg><appmsg><title>&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;</title><type>62</type><patinfo><fromusername>wxid_zhangsan</fromusername><chatusername>123@chatroom</chatusername><pattedusername>wxid_bot</pattedusername></patinfo></appmsg></msg>
        """#
    }

    private func makeEvent(
        text: String,
        rawMessage: String,
        msgType: Int = 49,
        groupID: String = "123@chatroom",
        sender: String = "wxid_lisi",
        extraSegments: [[String: Any]] = []
    ) -> OneBotEvent? {
        var raw: [String: Any] = [
            "self_id": "wxid_bot",
            "user_id": sender,
            "sender": ["user_id": sender, "nickname": "李四"],
            "time": 1_760_000_000.0,
            "message_id": "m-\(UUID().uuidString)",
            "message": [["type": "text", "data": ["text": text]]] + extraSegments,
            "raw_message": rawMessage,
            "message_type": groupID.isEmpty ? "private" : "group",
            "msg_type": msgType
        ]
        if !groupID.isEmpty { raw["group_id"] = groupID }
        return OneBotEventParser.parseEvent(raw, rawText: nil)
    }

    /// 构造引用 appmsg XML；`reply` 为空表示没有回复正文。
    /// `senderID` / `fromID` 模拟 refermsg 的被引用消息作者字段（群聊 `<chatusr>`、
    /// 私聊形态 `<fromusr>`），供「引用机器人」触发测试使用。
    private func quoteXML(
        reply: String,
        quoted: String,
        senderID: String? = nil,
        fromID: String? = nil,
        displayName: String = "张三"
    ) -> String {
        var body = ""
        if !reply.isEmpty { body += "<title>\(reply)</title>" }
        body += "<type>57</type><refermsg><type>1</type>"
        body += "<displayname>\(displayName)</displayname>"
        if let senderID { body += "<chatusr>\(senderID)</chatusr>" }
        if let fromID { body += "<fromusr>\(fromID)</fromusr>" }
        body += "<content>\(quoted)</content></refermsg>"
        return "<msg><appmsg appid=\"\" sdkver=\"0\">\(body)</appmsg></msg>"
    }

    /// 用指定触发方式在群聊里评估一条文本（冷却/限流关闭），便于对照触发语义。
    private func evaluateGroup(
        _ text: String,
        triggers: [TriggerMode],
        keywords: [String],
        rawJSON: String? = nil,
        selfID: String = "wxid_bot"
    ) -> RuleEvaluation {
        var settings = AppSettings.default
        settings.bot.groupTriggers = triggers
        settings.bot.keywords = keywords
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        let conversation = Conversation(id: "123@chatroom", kind: .group, title: "测试群")
        let message = ChatMessage(
            id: "m-\(UUID().uuidString)",
            conversationID: conversation.id,
            senderID: "wxid_lisi",
            senderName: "李四",
            direction: .incoming,
            text: text,
            timestamp: Date(),
            rawJSON: rawJSON
        )
        return RuleEngine().evaluate(RuleEngine.Context(
            conversation: conversation, message: message, settings: settings, selfID: selfID
        ))
    }

    // MARK: - 实时事件归一化

    func testParserRestoresQuotedReplyText() throws {
        let event = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: Sample.quoteXML))
        XCTAssertEqual(
            event.plainText,
            "火锅局改到明晚吧\n【引用 张三：明天晚上七点老地方吃火锅】"
        )
        XCTAssertFalse(event.plainText.contains(WeChatAppmsg.placeholderText))
        XCTAssertEqual(event.primaryMessageKind, .text)
    }

    func testParserRestoresLinkCardText() throws {
        let event = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: Sample.linkXML))
        XCTAssertEqual(event.plainText, "[链接] 一篇值得一读的文章")
    }

    /// 历史回放会重新投递旧 bridge 已渲染好的 `[引用 发送者] 原文`，
    /// 这些消息绕过启动迁移再次入库；入口必须统一成 `【引用 发送者：原文】`，
    /// 否则提示词里的引用格式与真实消息不一致，模型会把被引用内容当成当前发言。
    func testParserNormalizesLegacyQuoteDelimiterAtIngestion() throws {
        let legacy = "火锅局改到明晚吧\n[引用 张三] 明天晚上七点老地方吃火锅"
        let event = try XCTUnwrap(makeEvent(text: legacy, rawMessage: Sample.quoteXML))
        XCTAssertEqual(
            event.plainText,
            "火锅局改到明晚吧\n【引用 张三：明天晚上七点老地方吃火锅】"
        )

        // 用户自己手打的 `[引用 …]` 没有 quote 结构，不能误伤。
        let typed = try XCTUnwrap(makeEvent(
            text: "我打的是 [引用 格式",
            rawMessage: "我打的是 [引用 格式",
            msgType: 1
        ))
        XCTAssertEqual(typed.plainText, "我打的是 [引用 格式")
    }

    /// hook 的拍一拍启发式只看正文是否含「拍了拍」；引用回复里出现该词时
    /// 会把 `<title>`（回复正文）当拍一拍标题写进 text，引用上下文因此丢失。
    func testParserRestoresQuoteWhenHookMistookItForPatTitle() throws {
        let event = try XCTUnwrap(makeEvent(text: "火锅局改到明晚吧", rawMessage: Sample.quoteXML))
        XCTAssertEqual(
            event.plainText,
            "火锅局改到明晚吧\n【引用 张三：明天晚上七点老地方吃火锅】"
        )
    }

    func testParserKeepsPatMessageTextUntouched() throws {
        let text = "\"小明\" 拍了拍 \"测试机器人\""
        let event = try XCTUnwrap(makeEvent(text: text, rawMessage: Sample.patXML))
        XCTAssertEqual(event.plainText, text)
    }

    func testParserNormalizesLegacyRawXMLTextSegment() throws {
        // 4.1.12 legacy 桥接：appmsg 正文就是原始 XML（没有 hook 的占位文本）。
        let event = try XCTUnwrap(makeEvent(text: Sample.quoteXML, rawMessage: Sample.quoteXML))
        XCTAssertEqual(event.plainText, "火锅局改到明晚吧\n【引用 张三：明天晚上七点老地方吃火锅】")

        // 非 appmsg 的原始 XML（图片/语音）不能用 appmsg 解析覆盖，保持原样。
        let imageXML = #"<msg><img aeskey="fake-key" /></msg>"#
        let untouched = try XCTUnwrap(makeEvent(text: imageXML, rawMessage: imageXML, msgType: 3))
        XCTAssertEqual(untouched.plainText, imageXML)
    }

    func testParserLeavesOrdinaryMessagesUntouched() throws {
        let text = try XCTUnwrap(makeEvent(text: "你好", rawMessage: "你好", msgType: 1))
        XCTAssertEqual(text.plainText, "你好")

        // 有占位文本但 raw_message 不是 appmsg：保守保留原文本，不能丢消息。
        let placeholder = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: "不是 XML"))
        XCTAssertEqual(placeholder.plainText, WeChatAppmsg.placeholderText)
    }

    func testParserKeepsStructuredAtSegments() throws {
        let event = try XCTUnwrap(makeEvent(
            text: WeChatAppmsg.placeholderText,
            rawMessage: Sample.quoteXML,
            extraSegments: [["type": "at", "data": ["qq": "wxid_bot"]]]
        ))
        XCTAssertEqual(event.mentions, ["wxid_bot"])
        XCTAssertTrue(event.plainText.hasPrefix("火锅局改到明晚吧"))
        XCTAssertTrue(event.plainText.contains("@wxid_bot"))
    }

    // MARK: - 触发回归：引用正文里的关键词现在可见

    func testGroupKeywordMatchesQuotedReplyBody() throws {
        let event = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: Sample.quoteXML))

        // 修复后：事件文本包含引用正文里的「火锅」，关键词触发成立。
        let evaluation = evaluateGroup(event.plainText, triggers: [.keyword], keywords: ["火锅"])
        XCTAssertTrue(evaluation.shouldReply)
        XCTAssertEqual(evaluation.triggerLabel, "群聊·关键词")
        // 旧行为（占位文本）不会触发——这就是本次修复的用户可见差异。
        XCTAssertFalse(
            evaluateGroup(WeChatAppmsg.placeholderText, triggers: [.keyword], keywords: ["火锅"]).shouldReply
        )
    }

    /// 被引用原文只作为 AI 上下文，不能让「引用一条含关键词的旧消息」再次触发。
    func testGroupKeywordIgnoresQuotedOriginal() throws {
        let xml = quoteXML(reply: "好的", quoted: "明天晚上要不要一起吃火锅")
        let event = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: xml))
        XCTAssertTrue(event.plainText.contains("火锅"), "上下文仍应保留给 AI")
        XCTAssertFalse(evaluateGroup(event.plainText, triggers: [.keyword], keywords: ["火锅"]).shouldReply)

        // 回复正文自己带关键词时照常触发。
        let bodyHit = quoteXML(reply: "火锅可以", quoted: "明晚见")
        let bodyEvent = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: bodyHit))
        XCTAssertTrue(evaluateGroup(bodyEvent.plainText, triggers: [.keyword], keywords: ["火锅"]).shouldReply)
    }

    /// 引用上下文里的 `@机器人` 不是真实 @（微信引用不产生 @ 提醒），不能触发。
    func testGroupMentionIgnoresQuotedOriginal() throws {
        let xml = quoteXML(reply: "哈哈", quoted: "@wxid_bot 你之前说的方案还能用吗")
        let event = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: xml))
        XCTAssertTrue(event.plainText.contains("@wxid_bot"), "上下文仍应保留给 AI")
        XCTAssertFalse(evaluateGroup(event.plainText, triggers: [.mention], keywords: []).shouldReply)

        // 真实结构化 at 段不受影响。
        let realMention = try XCTUnwrap(makeEvent(
            text: WeChatAppmsg.placeholderText,
            rawMessage: Sample.quoteXML,
            extraSegments: [["type": "at", "data": ["qq": "wxid_bot"]]]
        ))
        XCTAssertTrue(
            evaluateGroup(realMention.plainText, triggers: [.mention], keywords: [],
                          rawJSON: realMention.rawJSON).shouldReply
        )
    }

    /// 没有回复正文的纯引用（只有被引用上下文）不参与关键词/ @ 触发。
    func testQuoteWithoutReplyBodyNeverTriggersByQuotedContext() throws {
        let xml = quoteXML(reply: "", quoted: "明天晚上吃火锅 @wxid_bot")
        let event = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: xml))
        XCTAssertFalse(evaluateGroup(event.plainText, triggers: [.keyword], keywords: ["火锅"]).shouldReply)
        XCTAssertFalse(evaluateGroup(event.plainText, triggers: [.mention], keywords: []).shouldReply)
    }

    // MARK: - 「引用机器人」触发（2026-10-22 新增）

    /// 引用的是机器人自己发的消息：正文没有任何 @/关键词，也应唤醒。
    func testGroupQuoteTriggerWakesWhenQuotingBotMessage() throws {
        let xml = quoteXML(
            reply: "这个怎么弄",
            quoted: "记得把日志发我",
            senderID: "wxid_bot",
            fromID: "123@chatroom",
            displayName: "测试机器人"
        )
        let event = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: xml))
        XCTAssertTrue(event.plainText.contains("【引用 测试机器人："))

        let matched = evaluateGroup(event.plainText, triggers: [.quote], keywords: [],
                                    rawJSON: event.rawJSON)
        XCTAssertTrue(matched.shouldReply)
        XCTAssertEqual(matched.triggerLabel, "群聊·引用")

        // 未勾选该触发方式时保持原行为：引用机器人不触发。
        XCTAssertFalse(evaluateGroup(event.plainText, triggers: [.mention], keywords: [],
                                     rawJSON: event.rawJSON).shouldReply)
    }

    /// 引用的是别人的消息：不是「引用机器人」，不能唤醒。
    func testGroupQuoteTriggerIgnoresQuotingOthers() throws {
        let xml = quoteXML(
            reply: "哈哈哈",
            quoted: "晚上吃什么",
            senderID: "wxid_zhangsan",
            fromID: "123@chatroom"
        )
        let event = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: xml))
        XCTAssertFalse(evaluateGroup(event.plainText, triggers: [.quote], keywords: [],
                                     rawJSON: event.rawJSON).shouldReply)
    }

    /// 部分客户端/私聊形态的 refermsg 没有 `<chatusr>`，只有 `<fromusr>`：
    /// 后者是 wxid 时同样能识别「引用的是机器人」。
    func testGroupQuoteTriggerFallsBackToFromUser() throws {
        let xml = quoteXML(reply: "在吗", quoted: "我先睡了", fromID: "wxid_bot")
        let event = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: xml))
        XCTAssertTrue(evaluateGroup(event.plainText, triggers: [.quote], keywords: [],
                                    rawJSON: event.rawJSON).shouldReply)
    }

    /// 群 ID 不能当发送者；selfID 未知时也不能瞎猜。
    func testGroupQuoteTriggerRejectsGroupIDAndUnknownSelf() throws {
        let groupOnly = quoteXML(reply: "嗯", quoted: "原文", fromID: "123@chatroom")
        let groupEvent = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: groupOnly))
        XCTAssertFalse(evaluateGroup(groupEvent.plainText, triggers: [.quote], keywords: [],
                                     rawJSON: groupEvent.rawJSON).shouldReply)

        let botQuote = quoteXML(reply: "嗯", quoted: "原文", senderID: "wxid_bot", fromID: "123@chatroom")
        let botEvent = try XCTUnwrap(makeEvent(text: WeChatAppmsg.placeholderText, rawMessage: botQuote))
        XCTAssertFalse(evaluateGroup(botEvent.plainText, triggers: [.quote], keywords: [],
                                     rawJSON: botEvent.rawJSON, selfID: "").shouldReply)
    }

    /// 触发方式是设置项：可编码/解码，且 `effectiveGroupTriggers` 保留新选项。
    func testQuoteTriggerIsSelectableAndCodable() throws {
        XCTAssertTrue(TriggerMode.groupOptions.contains(.quote))
        XCTAssertEqual(TriggerMode.quote.rawValue, "quote")
        XCTAssertEqual(TriggerMode.quote.groupLabel, "引用机器人")

        var bot = BotSettings()
        bot.groupTriggers = [.mention, .quote]
        XCTAssertEqual(bot.effectiveGroupTriggers, [.mention, .quote])

        let data = try JSONEncoder().encode(bot.groupTriggers)
        let decoded = try JSONDecoder().decode([TriggerMode].self, from: data)
        XCTAssertEqual(decoded, [.mention, .quote])
    }

    // MARK: - 历史消息修复

    func testRepairAppmsgMessageTextsIsIdempotentAndRefreshesPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-appmsg-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        let conversation = Conversation(id: "123@chatroom", kind: .group, title: "测试群")
        try await store.upsertConversations([conversation])

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        func rawEvent(text: String, rawMessage: String, at: String? = nil) -> String {
            var segments: [[String: Any]] = [["type": "text", "data": ["text": text]]]
            var object: [String: Any] = [
                "self_id": "wxid_bot",
                "user_id": "wxid_lisi",
                "group_id": conversation.id,
                "message_id": "m-\(UUID().uuidString)",
                "message": segments,
                "raw_message": rawMessage,
                "message_type": "group",
                "msg_type": 49
            ]
            if let at {
                segments.append(["type": "at", "data": ["qq": at]])
                object["message"] = segments
                object["mentions"] = [at]
            }
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(data: data, encoding: .utf8)!
        }

        func message(
            id: String,
            text: String,
            rawJSON: String,
            offset: TimeInterval
        ) -> ChatMessage {
            ChatMessage(
                id: id,
                conversationID: conversation.id,
                senderID: "wxid_lisi",
                senderName: "李四",
                direction: .incoming,
                text: text,
                timestamp: now.addingTimeInterval(offset),
                rawJSON: rawJSON
            )
        }

        try await store.upsertMessages([
            message(id: "m-link", text: WeChatAppmsg.placeholderText,
                    rawJSON: rawEvent(text: WeChatAppmsg.placeholderText, rawMessage: Sample.linkXML),
                    offset: 0),
            message(id: "m-healthy", text: "普通消息", rawJSON: rawEvent(text: "普通消息", rawMessage: "普通消息"),
                    offset: 10),
            // 带结构化 at 段的历史文本是 `[链接/文件] @wxid_…`：只替换占位前缀、保留 at。
            message(id: "m-at", text: "\(WeChatAppmsg.placeholderText) @wxid_zhangsan",
                    rawJSON: rawEvent(text: WeChatAppmsg.placeholderText, rawMessage: Sample.quoteXML,
                                      at: "wxid_zhangsan"),
                    offset: 15),
            message(id: "m-broken", text: WeChatAppmsg.placeholderText,
                    rawJSON: #"{"raw_message":"不是 XML"}"#, offset: 20),
            // 最新一条设为引用回复：修复后会话预览应刷新为可读文本。
            message(id: "m-quote", text: WeChatAppmsg.placeholderText,
                    rawJSON: rawEvent(text: WeChatAppmsg.placeholderText, rawMessage: Sample.quoteXML),
                    offset: 30)
        ])

        let result = try await store.repairAppmsgMessageTexts()
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.repairedMessages, 3)
        XCTAssertEqual(result.affectedConversationIDs, [conversation.id])

        let messages = try await store.fetchMessages(conversationID: conversation.id, limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        XCTAssertEqual(byID["m-link"]?.text, "[链接] 一篇值得一读的文章")
        XCTAssertEqual(byID["m-quote"]?.text,
                       "火锅局改到明晚吧\n【引用 张三：明天晚上七点老地方吃火锅】")
        XCTAssertEqual(byID["m-at"]?.text,
                       "火锅局改到明晚吧\n【引用 张三：明天晚上七点老地方吃火锅】 @wxid_zhangsan")
        // 普通消息与解析不出的占位保持原样（幂等、保守）。
        XCTAssertEqual(byID["m-healthy"]?.text, "普通消息")
        XCTAssertEqual(byID["m-broken"]?.text, WeChatAppmsg.placeholderText)

        let conversations = try await store.fetchConversations()
        let preview = try XCTUnwrap(conversations.first?.lastMessagePreview)
        XCTAssertEqual(preview, "火锅局改到明晚吧\n【引用 张三：明天晚上七点老地方吃火锅】")

        // 再跑一次：没有可修复项，不能重复写库。
        let second = try await store.repairAppmsgMessageTexts()
        XCTAssertFalse(second.didChange)
        XCTAssertEqual(second.repairedMessages, 0)
    }

    // MARK: - 引用定界符迁移（旧 `[引用 …]` → `【引用 …】`）

    /// 触发判定兼容新旧定界符：只保留回复正文。
    func testTriggerTextStripsNewAndLegacyQuoteDelimiters() {
        XCTAssertEqual(RuleEngine.triggerText("好的\n【引用 张三：原文】"), "好的")
        XCTAssertEqual(RuleEngine.triggerText("好的\n【引用：原文】"), "好的")
        XCTAssertEqual(RuleEngine.triggerText("【引用 张三：原文】"), "")
        XCTAssertEqual(RuleEngine.triggerText("【引用：原文】"), "")
        XCTAssertEqual(RuleEngine.triggerText("【引用】"), "")
        // 旧格式兼容（历史库迁移前/迁移失败时）。
        XCTAssertEqual(RuleEngine.triggerText("好的\n[引用 张三] 原文"), "好的")
        XCTAssertEqual(RuleEngine.triggerText("[引用 张三] 原文"), "")
        // 普通文本原样返回。
        XCTAssertEqual(RuleEngine.triggerText("普通消息"), "普通消息")
    }

    func testRerenderLegacyQuoteTextsMigratesDelimitersAndIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-quote-format-\(UUID().uuidString)", isDirectory: true)
        let store = MemoryStore(databaseURL: directory.appendingPathComponent("chatbot.sqlite"))
        try await store.open()
        defer {
            Task { await store.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        let conversation = Conversation(id: "123@chatroom", kind: .group, title: "测试群")
        try await store.upsertConversations([conversation])
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        func rawEventJSON(text: String, rawMessage: String, at: [String] = []) -> String {
            var segments: [[String: Any]] = [["type": "text", "data": ["text": text]]]
            segments += at.map { ["type": "at", "data": ["qq": $0]] }
            var object: [String: Any] = [
                "self_id": "wxid_bot",
                "user_id": "wxid_lisi",
                "group_id": conversation.id,
                "message_id": "m-\(UUID().uuidString)",
                "message": segments,
                "raw_message": rawMessage,
                "message_type": "group",
                "msg_type": 49
            ]
            if !at.isEmpty { object["mentions"] = at }
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(data: data, encoding: .utf8)!
        }

        let quoteRaw = quoteXML(reply: "好的", quoted: "原文", senderID: "wxid_zhangsan",
                                fromID: conversation.id)

        func message(id: String, text: String, rawJSON: String, offset: TimeInterval) -> ChatMessage {
            ChatMessage(
                id: id,
                conversationID: conversation.id,
                senderID: "wxid_lisi",
                senderName: "李四",
                direction: .incoming,
                text: text,
                timestamp: now.addingTimeInterval(offset),
                rawJSON: rawJSON
            )
        }

        try await store.upsertMessages([
            // 旧格式 + 结构化 at 后缀（真实历史数据里出现过）。
            message(id: "m-legacy",
                    text: "好的\n[引用 张三] 原文 @wxid_zhangsan",
                    rawJSON: rawEventJSON(text: WeChatAppmsg.placeholderText,
                                          rawMessage: quoteRaw, at: ["wxid_zhangsan"]),
                    offset: 0),
            // 用户自己打的文本，raw 不是 appmsg：不能被迁移误伤。
            message(id: "m-user",
                    text: "我打的是 [引用 格式",
                    rawJSON: rawEventJSON(text: "我打的是 [引用 格式", rawMessage: "我打的是 [引用 格式"),
                    offset: 10),
            // 最新一条：迁移后会话预览应刷新。
            message(id: "m-legacy-latest",
                    text: "在吗\n[引用 张三] 原文",
                    rawJSON: rawEventJSON(
                        text: WeChatAppmsg.placeholderText,
                        rawMessage: quoteXML(reply: "在吗", quoted: "原文",
                                             senderID: "wxid_zhangsan", fromID: conversation.id)
                    ),
                    offset: 20)
        ])

        let migrated = try await store.rerenderLegacyQuoteTexts()
        XCTAssertEqual(migrated, 2)

        let messages = try await store.fetchMessages(conversationID: conversation.id, limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        XCTAssertEqual(byID["m-legacy"]?.text, "好的\n【引用 张三：原文】 @wxid_zhangsan")
        XCTAssertEqual(byID["m-legacy-latest"]?.text, "在吗\n【引用 张三：原文】")
        XCTAssertEqual(byID["m-user"]?.text, "我打的是 [引用 格式")

        let conversations = try await store.fetchConversations()
        let preview = try XCTUnwrap(conversations.first?.lastMessagePreview)
        XCTAssertEqual(preview, "在吗\n【引用 张三：原文】")

        // 幂等：旧定界符已不存在，第二次运行 0 条。
        let second = try await store.rerenderLegacyQuoteTexts()
        XCTAssertEqual(second, 0)
    }
}
