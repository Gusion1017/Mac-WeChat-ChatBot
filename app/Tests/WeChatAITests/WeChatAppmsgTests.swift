import XCTest
@testable import WeChatAI

/// appmsg（`msg_type=49`）解析器测试。
///
/// 所有昵称、wxid、正文均为虚构数据：真实抓包样本只保留在本机 `_local/`，
/// 不进入仓库（隐私红线见 CONTRIBUTING）。
final class WeChatAppmsgTests: XCTestCase {
    // MARK: - 1. 文字引用

    func testTextQuoteRendersReplyThenQuotedText() throws {
        let xml = appmsgXML(
            type: 57,
            title: "好呀，那就周六",
            extra: referXML(type: 1, displayName: "李四", content: "\n周末去爬山吗")
        )
        let appmsg = try XCTUnwrap(WeChatAppmsg.parse(xml))
        XCTAssertEqual(appmsg.type, 57)
        XCTAssertEqual(appmsg.title, "好呀，那就周六")
        XCTAssertEqual(appmsg.text, "好呀，那就周六\n[引用 李四] 周末去爬山吗")
        XCTAssertFalse(appmsg.text.contains(WeChatAppmsg.placeholderText))
        XCTAssertEqual(
            appmsg.quote,
            WeChatAppmsg.Quote(senderName: "李四", snippet: "周末去爬山吗", messageType: 1)
        )
    }

    // MARK: - 2. 引用图片

    func testImageQuoteSummarizesAsImage() throws {
        let inner = #"<?xml version="1.0"?><msg><img aeskey="fake-key" cdnthumburl="fake-thumb" /></msg>"#
        let xml = appmsgXML(
            type: 57,
            title: "这是什么",
            extra: referXML(type: 3, displayName: "张三", content: escapedXML(inner))
        )
        let appmsg = try XCTUnwrap(WeChatAppmsg.parse(xml))
        XCTAssertEqual(appmsg.text, "这是什么\n[引用 张三] [图片]")
        XCTAssertEqual(appmsg.quote?.snippet, "[图片]")
        XCTAssertEqual(appmsg.quote?.messageType, 3)
    }

    /// refermsg 只有 `<type>`、没有 `<content>` 时按媒体类型兜底。
    func testQuoteMediaWithoutContentFallsBackToTypeLabel() throws {
        let xml = appmsgXML(
            type: 57,
            title: "看这个",
            extra: referXML(type: 3, displayName: "张三", content: nil)
        )
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(xml)).text, "看这个\n[引用 张三] [图片]")
    }

    // MARK: - 3. 引用表情

    func testEmojiQuoteSummarizesAsEmoji() throws {
        let inner = #"<msg><emoji fromusername="wxid_lisi" type="2" md5="fake-md5" /></msg>"#
        let xml = appmsgXML(
            type: 57,
            title: "笑死",
            extra: referXML(type: 47, displayName: "李四", content: escapedXML(inner))
        )
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(xml)).text, "笑死\n[引用 李四] [表情]")
    }

    // MARK: - 4. 引用链接

    func testLinkQuoteUsesNestedAppmsgDisplayText() throws {
        let inner = #"<msg><appmsg appid="" sdkver="0"><title>示例文章标题</title><type>5</type><url>https://example.com/a</url></appmsg></msg>"#
        let xml = appmsgXML(
            type: 57,
            title: "原帖不错",
            extra: referXML(type: 49, displayName: "张三", content: escapedXML(inner))
        )
        let appmsg = try XCTUnwrap(WeChatAppmsg.parse(xml))
        XCTAssertEqual(appmsg.text, "原帖不错\n[引用 张三] [链接] 示例文章标题")
        XCTAssertEqual(appmsg.quote?.snippet, "[链接] 示例文章标题")
    }

    // MARK: - 5. 嵌套引用

    func testNestedQuoteSnippetOnlyUsesInnerTitle() throws {
        let inner = #"""
        <msg><appmsg><title>内层引用正文</title><type>57</type>\
        <refermsg><type>1</type><displayname>王五</displayname><content>层内原文</content></refermsg>\
        </appmsg></msg>
        """#
        let xml = appmsgXML(
            type: 57,
            title: "说得对",
            extra: referXML(type: 49, displayName: "张三", content: escapedXML(inner))
        )
        let appmsg = try XCTUnwrap(WeChatAppmsg.parse(xml))
        XCTAssertEqual(appmsg.text, "说得对\n[引用 张三] 内层引用正文")
        XCTAssertEqual(appmsg.quote?.snippet, "内层引用正文")
        XCTAssertFalse(
            appmsg.quote?.snippet.contains("[引用") ?? true,
            "嵌套引用摘要不能再套一层 [引用 …]"
        )
    }

    // MARK: - 6. 链接/文件/视频/表情/聊天记录等卡片

    func testCardTypesUseLabels() throws {
        func text(type: Int, title: String) throws -> String {
            try XCTUnwrap(WeChatAppmsg.parse(appmsgXML(type: type, title: title))).text
        }

        XCTAssertEqual(try text(type: 5, title: "示例文章标题"), "[链接] 示例文章标题")
        XCTAssertEqual(try text(type: 6, title: "季度报告.pdf"), "[文件] 季度报告.pdf")
        XCTAssertEqual(try text(type: 4, title: "示例视频标题"), "[视频] 示例视频标题")
        XCTAssertEqual(try text(type: 19, title: "群聊的聊天记录"), "[聊天记录] 群聊的聊天记录")
        XCTAssertEqual(try text(type: 33, title: "示例小程序"), "[小程序] 示例小程序")
        XCTAssertEqual(try text(type: 36, title: "另一个小程序"), "[小程序] 另一个小程序")
        XCTAssertEqual(try text(type: 42, title: "示例名片"), "[名片] 示例名片")
        XCTAssertEqual(try text(type: 48, title: "示例位置"), "[位置] 示例位置")
        XCTAssertEqual(try text(type: 53, title: "示例直播"), "[视频号直播] 示例直播")
        XCTAssertEqual(try text(type: 87, title: "群公告内容"), "[群公告] 群公告内容")
        XCTAssertEqual(try text(type: 2001, title: "恭喜发财"), "[红包] 恭喜发财")
        XCTAssertEqual(try text(type: 2003, title: "示例音乐"), "[音乐] 示例音乐")
        XCTAssertEqual(try text(type: 8, title: ""), "[表情]")
        XCTAssertEqual(try text(type: 17, title: ""), "[位置共享]")
        XCTAssertEqual(try text(type: 999, title: "未知卡片"), "[卡片] 未知卡片")
    }

    /// 卡片内容压缩空白、按 200 字符截断；没有内容时只输出 label。
    func testCardContentCompressesWhitespaceAndTruncates() throws {
        let multiline = appmsgXML(type: 5, title: "第一行\n\n第二行   第三行")
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(multiline)).text, "[链接] 第一行 第二行 第三行")

        let longTitle = String(repeating: "长", count: 250)
        let long = try XCTUnwrap(WeChatAppmsg.parse(appmsgXML(type: 5, title: longTitle)))
        XCTAssertEqual(long.text, "[链接] " + String(repeating: "长", count: 200) + "…")
    }

    // MARK: - 7. 转账

    func testTransferPrefersFeeAndMemo() throws {
        let xml = appmsgXML(
            type: 2000,
            title: "微信转账",
            extra: "<wcpayinfo><feedesc><![CDATA[￥12.34]]></feedesc>"
                + "<pay_memo><![CDATA[夜宵钱]]></pay_memo></wcpayinfo>"
        )
        let appmsg = try XCTUnwrap(WeChatAppmsg.parse(xml))
        XCTAssertEqual(appmsg.text, "[转账] ￥12.34 夜宵钱")
        XCTAssertEqual(appmsg.title, "微信转账", "title 只作为最后的兜底")
    }

    func testTransferFallsBackToDescriptionThenTitle() throws {
        let descriptionOnly = appmsgXML(type: 2000, title: "微信转账", extra: "<des>收到转账 12.34 元</des>")
        XCTAssertEqual(
            try XCTUnwrap(WeChatAppmsg.parse(descriptionOnly)).text,
            "[转账] 收到转账 12.34 元"
        )

        let titleOnly = appmsgXML(type: 2000, title: "微信转账")
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(titleOnly)).text, "[转账] 微信转账")
    }

    // MARK: - 8. 视频号

    func testFinderFeedPrefersNicknameAndDescOverPlaceholderTitle() throws {
        let xml = appmsgXML(
            type: 51,
            title: "当前版本不支持展示该内容，请升级至最新版本。",
            extra: "<finderFeed><nickname>示例创作者</nickname>"
                + "<desc>#测试 #视频号</desc></finderFeed>"
        )
        let appmsg = try XCTUnwrap(WeChatAppmsg.parse(xml))
        XCTAssertEqual(appmsg.text, "[视频号] 示例创作者：#测试 #视频号")
        XCTAssertFalse(appmsg.text.contains("当前版本不支持"), "不能使用微信的升级占位文案")
    }

    func testFinderFeedFallsBackWhenOnlyOneFieldOrNone() throws {
        let nicknameOnly = appmsgXML(
            type: 51,
            title: "当前版本不支持展示该内容，请升级至最新版本。",
            extra: "<finderFeed><nickname>示例创作者</nickname></finderFeed>"
        )
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(nicknameOnly)).text, "[视频号] 示例创作者")

        let descOnly = appmsgXML(
            type: 51,
            title: "当前版本不支持展示该内容，请升级至最新版本。",
            extra: "<finderFeed><desc>#测试</desc></finderFeed>"
        )
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(descOnly)).text, "[视频号] #测试")

        let empty = appmsgXML(
            type: 51,
            title: "当前版本不支持展示该内容，请升级至最新版本。",
            extra: "<finderFeed></finderFeed>"
        )
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(empty)).text, "[视频号]")
    }

    // MARK: - 9. CDATA / 自闭合 / 实体 / 字面量转义

    func testCDATATitleAndSelfClosingTitle() throws {
        let cdata = appmsgXML(type: 5, title: nil, extra: "<title><![CDATA[张三 & 李四]]></title>")
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(cdata)).text, "[链接] 张三 & 李四")

        let selfClosing = appmsgXML(type: 8, title: nil, extra: "<title />")
        let appmsg = try XCTUnwrap(WeChatAppmsg.parse(selfClosing))
        XCTAssertEqual(appmsg.title, "")
        XCTAssertEqual(appmsg.text, "[表情]")
    }

    func testXMLEntitiesAndLiteralUnicodeEscapes() throws {
        let entity = appmsgXML(
            type: 5,
            title: "&quot;引号&quot; &amp; &lt;尖括号&gt; &#39;单引号&#x27;"
        )
        XCTAssertEqual(
            try XCTUnwrap(WeChatAppmsg.parse(entity)).text,
            "[链接] \"引号\" & <尖括号> '单引号'"
        )

        // Go bridge 的 encoding/json 有时把 `<` 写成 \u003c；历史数据还可能被编码两次，
        // 这里直接喂字面量形态，parse 必须先解转义再找 <appmsg。
        let escaped = #"\u003cmsg\u003e\u003cappmsg\u003e\u003ctitle\u003e示例标题\u003c/title\u003e\u003ctype\u003e5\u003c/type\u003e\u003c/appmsg\u003e\u003c/msg\u003e"#
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(escaped)).text, "[链接] 示例标题")
    }

    // MARK: - 10. 普通消息不误判

    func testNonAppmsgPayloadsReturnNil() {
        XCTAssertNil(WeChatAppmsg.parse(nil))
        XCTAssertNil(WeChatAppmsg.parse(""))
        XCTAssertNil(WeChatAppmsg.parse("   \n\t "))
        XCTAssertNil(WeChatAppmsg.parse("你好，世界"))
        XCTAssertNil(WeChatAppmsg.parse(#"<msg><img aeskey="fake-key" /></msg>"#))
        XCTAssertNil(WeChatAppmsg.parse(#"<msg><voicemsg voicelength="1200" /></msg>"#))
        XCTAssertNil(WeChatAppmsg.parse(
            #"<sysmsg type="pat"><pat><fromusername>wxid_zhangsan</fromusername></pat></sysmsg>"#
        ))
    }

    // MARK: - 11. parse(eventJSON:)

    func testParseEventJSONFindsRawMessageUnderDataWrapper() throws {
        let xml = appmsgXML(type: 5, title: "示例文章标题")
        let event: [String: Any] = [
            "post_type": "message",
            "data": ["msg_type": 49, "raw_message": xml]
        ]
        let json = try jsonString(event)
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(eventJSON: json)).text, "[链接] 示例文章标题")
    }

    func testParseEventJSONTopLevelRawMessageAndCamelCase() throws {
        let xml = appmsgXML(type: 6, title: "季度报告.pdf")
        let topLevel = try jsonString(["msg_type": 49, "raw_message": xml])
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(eventJSON: topLevel)).text, "[文件] 季度报告.pdf")

        let camelCase = try jsonString(["msgType": 49, "rawMessage": xml])
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(eventJSON: camelCase)).text, "[文件] 季度报告.pdf")
    }

    func testParseEventJSONAcceptsRawXMLAndDoubleEscapedRawMessage() throws {
        let xml = appmsgXML(type: 5, title: "示例文章标题")
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(eventJSON: xml)).text, "[链接] 示例文章标题")

        // JSON 里是 `\\u003c`：JSON 解码后 raw_message 仍是字面量 `\u003c`，
        // 模拟被二次转义的历史事件。
        let doubleEscaped = #"{"msg_type":49,"raw_message":"\\u003cmsg\\u003e\\u003cappmsg\\u003e\\u003ctitle\\u003e示例标题\\u003c/title\\u003e\\u003ctype\\u003e5\\u003c/type\\u003e\\u003c/appmsg\\u003e\\u003c/msg\\u003e"}"#
        XCTAssertEqual(
            try XCTUnwrap(WeChatAppmsg.parse(eventJSON: doubleEscaped)).text,
            "[链接] 示例标题"
        )
    }

    func testParseEventJSONWithoutRawMessageReturnsNil() throws {
        XCTAssertNil(WeChatAppmsg.parse(eventJSON: nil))
        XCTAssertNil(WeChatAppmsg.parse(eventJSON: ""))
        XCTAssertNil(WeChatAppmsg.parse(eventJSON: #"{"raw_message":"你好，世界"}"#))
        XCTAssertNil(WeChatAppmsg.parse(eventJSON: #"{"msg_type":49}"#))
    }

    // MARK: - 12. 占位符与拍一拍

    func testPlaceholderAndPatFlags() throws {
        XCTAssertEqual(WeChatAppmsg.placeholderText, "[链接/文件]")

        let pat = appmsgXML(type: 62, title: "&quot;小明&quot; 拍了拍 &quot;测试机器人&quot;")
        let parsedPat = try XCTUnwrap(WeChatAppmsg.parse(pat))
        XCTAssertTrue(parsedPat.isPat)
        XCTAssertEqual(parsedPat.text, "\"小明\" 拍了拍 \"测试机器人\"", "拍一拍只输出模板，不加 label")

        let emptyPat = appmsgXML(type: 62, title: nil)
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(emptyPat)).text, "[拍一拍]")

        let link = try XCTUnwrap(WeChatAppmsg.parse(appmsgXML(type: 5, title: "示例文章标题")))
        XCTAssertFalse(link.isPat)
    }

    // MARK: - 引用边界

    func testBrokenEmptyRefermsgKeepsReplyTextOnly() throws {
        // 真实历史数据里出现过 `<refermsg></refermsg>`（内层全丢）。
        let xml = appmsgXML(type: 57, title: "只有回复正文", extra: "<refermsg></refermsg>")
        let appmsg = try XCTUnwrap(WeChatAppmsg.parse(xml))
        XCTAssertEqual(appmsg.text, "只有回复正文")
        XCTAssertEqual(appmsg.quote?.senderName, "")
        XCTAssertEqual(appmsg.quote?.snippet, "")
        XCTAssertNil(appmsg.quote?.messageType)
    }

    func testQuoteWithoutReplyTitleUsesQuoteLineOnly() throws {
        let xml = appmsgXML(
            type: 57,
            title: nil,
            extra: referXML(type: 1, displayName: "张三", content: "被引用的原文")
        )
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(xml)).text, "[引用 张三] 被引用的原文")

        let noSender = appmsgXML(
            type: 57,
            title: nil,
            extra: referXML(type: 1, displayName: nil, content: "没有昵称的原文")
        )
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(noSender)).text, "[引用] 没有昵称的原文")

        let bare = appmsgXML(type: 57, title: nil, extra: "<refermsg />")
        XCTAssertEqual(try XCTUnwrap(WeChatAppmsg.parse(bare)).text, "[引用]")
    }

    func testQuoteSnippetTruncatesAt160ButReplyIsNotTruncated() throws {
        let longSnippet = String(repeating: "原", count: 180)
        let longReply = String(repeating: "回", count: 220)
        let xml = appmsgXML(
            type: 57,
            title: longReply,
            extra: referXML(type: 1, displayName: "张三", content: longSnippet)
        )
        let appmsg = try XCTUnwrap(WeChatAppmsg.parse(xml))
        XCTAssertEqual(appmsg.quote?.snippet, String(repeating: "原", count: 160) + "…")
        XCTAssertEqual(
            appmsg.text,
            longReply + "\n[引用 张三] " + String(repeating: "原", count: 160) + "…"
        )
    }

    // MARK: - WeChatXML 工具

    func testWeChatXMLHelpers() {
        XCTAssertEqual(
            WeChatXML.field("title", in: "<appmsg><title a=\"1\">\n小标题\n</title></appmsg>"),
            "小标题"
        )
        XCTAssertEqual(
            WeChatXML.field("title", in: "<appmsg><title><![CDATA[CDATA 标题]]></title></appmsg>"),
            "CDATA 标题"
        )
        XCTAssertNil(WeChatXML.field("title", in: "<appmsg><title /></appmsg>"))
        XCTAssertNil(WeChatXML.field("title", in: "<appmsg><title></title></appmsg>"))
        XCTAssertNil(WeChatXML.field("title", in: "<appmsg><title>未闭合</appmsg>"))

        XCTAssertEqual(
            WeChatXML.block("refermsg", in: "<appmsg><refermsg><type>1</type></refermsg></appmsg>"),
            "<type>1</type>"
        )
        XCTAssertNil(WeChatXML.block("refermsg", in: "<appmsg><refermsg /></appmsg>"))

        XCTAssertTrue(WeChatXML.containsTag("appmsg", in: "<APPMSG appid=\"\">"))
        XCTAssertFalse(WeChatXML.containsTag("appmsg", in: "<appmsgx>"))
        XCTAssertFalse(WeChatXML.containsTag("img", in: #"<x value="<img">"#))

        // `&amp;` 必须最后解：`&amp;lt;` 只能还原成 `&lt;`，不能被当成 `<`。
        XCTAssertEqual(WeChatXML.unescape("&amp;lt; &lt; &amp;"), "&lt; < &")
        XCTAssertEqual(
            WeChatXML.decodeEscapes(#"\u003cmsg\u003e \"q\" \/p"#),
            #"<msg> "q" /p"#
        )
    }

    // MARK: - Helpers

    /// 组装一个最小 appmsg XML。`title: nil` 表示不写 title 标签。
    private func appmsgXML(type: Int?, title: String?, extra: String = "") -> String {
        var body = ""
        if let title {
            body += "<title>\(title)</title>"
        }
        if let type {
            body += "<type>\(type)</type>"
        }
        body += extra
        return "<msg><appmsg appid=\"\" sdkver=\"0\">\(body)</appmsg>"
            + "<fromusername>wxid_zhangsan</fromusername></msg>"
    }

    /// 组装引用块；content 需要调用方自行按原始 XML 形态传入（纯文本或转义 XML）。
    private func referXML(type: Int?, displayName: String?, content: String?) -> String {
        var body = ""
        if let type {
            body += "<type>\(type)</type>"
        }
        if let displayName {
            body += "<displayname>\(displayName)</displayname>"
        }
        if let content {
            body += "<content>\(content)</content>"
        }
        return "<refermsg>\(body)</refermsg>"
    }

    /// 把一段 XML 转成 `<content>` 里常见的实体转义形态（只转 & < >，保留引号）。
    private func escapedXML(_ xml: String) -> String {
        xml.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
