import XCTest
@testable import WeChatAI

final class PatReplySettingsTests: XCTestCase {
    func testLegacyConfigWithoutPatKeyDecodesAsDisabled() throws {
        // 旧 config.json 没有 bot.pat 键：必须保持可解码，且默认关闭拍一拍回复。
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any]
        )
        var bot = try XCTUnwrap(object["bot"] as? [String: Any])
        bot.removeValue(forKey: "pat")
        object["bot"] = bot

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.bot.patReplyEnabled)
        XCTAssertNil(decoded.bot.pat)
    }

    func testPatReplyEnabledRoundtrips() throws {
        var settings = AppSettings.default
        settings.bot.patReplyEnabled = true
        settings.bot.patFixedTextEnabled = true
        settings.bot.patAIEnabled = true
        settings.bot.patBeforeText = "收到，回你一下"
        settings.bot.patAfterText = "拍了拍 {name} 的肩膀"
        XCTAssertEqual(settings.bot.pat?.enabled, true)

        let data = try JSONEncoder().encode(settings)
        var decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.bot.patReplyEnabled)
        XCTAssertTrue(decoded.bot.patFixedTextEnabled)
        XCTAssertTrue(decoded.bot.patAIEnabled)
        XCTAssertEqual(decoded.bot.patBeforeText, "收到，回你一下")
        XCTAssertEqual(decoded.bot.patAfterText, "拍了拍 {name} 的肩膀")

        decoded.bot.patReplyEnabled = false
        XCTAssertFalse(decoded.bot.patReplyEnabled)
        XCTAssertEqual(decoded.bot.pat?.beforeText, "收到，回你一下")
    }

    /// 旧配置已有 beforeText/afterText：升级后继续作为自定义文字发送。
    func testLegacyTextResolvesFixedMode() throws {
        let json = #"{"enabled":true,"patOnly":true,"aiPosition":"before","beforeText":"收到","afterText":"拍完"}"#
        let decoded = try JSONDecoder().decode(PatReplySettings.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertTrue(decoded.resolvedFixedTextEnabled)
        XCTAssertFalse(decoded.resolvedAIEnabled)
        XCTAssertFalse(decoded.resolvedMentionPatterInGroup)
        XCTAssertEqual(decoded.beforeText, "收到")
        XCTAssertEqual(decoded.afterText, "拍完")
    }

    /// 群聊 @ 拍的人默认关闭，开启后随配置持久化并可关闭。
    func testPatMentionPatterDefaultsOffAndRoundtrips() throws {
        var settings = AppSettings.default
        XCTAssertFalse(settings.bot.patMentionPatterEnabled)
        XCTAssertNil(settings.bot.pat?.mentionPatterInGroup)

        settings.bot.patMentionPatterEnabled = true
        XCTAssertEqual(settings.bot.pat?.mentionPatterInGroup, true)

        let data = try JSONEncoder().encode(settings)
        var decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.bot.patMentionPatterEnabled)

        decoded.bot.patMentionPatterEnabled = false
        XCTAssertFalse(decoded.bot.patMentionPatterEnabled)
        XCTAssertEqual(decoded.bot.pat?.mentionPatterInGroup, false)
    }

    /// 固定文字与 AI 回复不再互斥，可以独立开关。
    func testFixedTextAndAIReplyAreIndependent() {
        var settings = AppSettings.default
        XCTAssertFalse(settings.bot.patFixedTextEnabled)
        XCTAssertFalse(settings.bot.patAIEnabled)

        settings.bot.patFixedTextEnabled = true
        XCTAssertTrue(settings.bot.patFixedTextEnabled)
        XCTAssertFalse(settings.bot.patAIEnabled)

        settings.bot.patAIEnabled = true
        XCTAssertTrue(settings.bot.patFixedTextEnabled)
        XCTAssertTrue(settings.bot.patAIEnabled)

        settings.bot.patFixedTextEnabled = false
        XCTAssertFalse(settings.bot.patFixedTextEnabled)
        XCTAssertTrue(settings.bot.patAIEnabled)
    }

    func testEmptyPatTextClearsStoredValue() {
        var settings = AppSettings.default
        settings.bot.patBeforeText = "abc"
        XCTAssertEqual(settings.bot.pat?.beforeText, "abc")
        settings.bot.patBeforeText = ""
        XCTAssertNil(settings.bot.pat?.beforeText)
    }

    func testPatTextTemplateReplacesName() {
        XCTAssertEqual(PatTextTemplate.render("你好，{name}", name: "小明"), "你好，小明")
        XCTAssertEqual(PatTextTemplate.render("{name}{name}", name: "小明"), "小明小明")
        XCTAssertEqual(PatTextTemplate.render("拍了拍", name: "小明"), "拍了拍")
        XCTAssertEqual(PatTextTemplate.render("  ", name: "小明"), "")
        XCTAssertEqual(PatTextTemplate.render("拍了拍 {name}", name: "  "), "拍了拍 对方")
    }
}
