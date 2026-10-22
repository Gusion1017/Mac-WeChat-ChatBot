import XCTest

@testable import WeChatAI

/// 群聊唤醒后免唤醒词窗口（2026-10-23）。
///
/// 语义：群聊命中任一触发方式后，**同一发送者**在窗口内继续发言无需再次唤醒；
/// 每条被放行的消息都会续期（滑动窗口）；窗口只放宽触发判定，不绕过其它门槛。
final class WakeWindowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)
    private let groupID = "g1@chatroom"

    private func makeSettings(
        wakeWindow: WakeWindowSettings? = WakeWindowSettings(enabled: true, seconds: 300)
    ) -> AppSettings {
        var settings = AppSettings.default
        settings.bot.groupTriggers = [.mention]
        settings.bot.cooldownSeconds = 0
        settings.bot.maxRepliesPerMinute = 0
        settings.bot.workingHours.enabled = false
        settings.bot.wakeWindow = wakeWindow
        return settings
    }

    private func context(
        _ text: String,
        senderID: String = "wxid_user",
        at date: Date? = nil,
        settings: AppSettings,
        conversation: Conversation? = nil
    ) -> RuleEngine.Context {
        let timestamp = date ?? start
        let target = conversation ?? Conversation(id: groupID, kind: .group, title: "测试群")
        let message = ChatMessage(
            id: UUID().uuidString,
            conversationID: target.id,
            senderID: senderID,
            senderName: senderID,
            direction: .incoming,
            text: text,
            timestamp: timestamp
        )
        return RuleEngine.Context(
            conversation: target,
            message: message,
            settings: settings,
            now: timestamp,
            selfID: "wxid_bot"
        )
    }

    // MARK: 配置兼容

    func testLegacyConfigWithoutWakeWindowDecodesAsDisabled() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any]
        )
        var bot = try XCTUnwrap(object["bot"] as? [String: Any])
        XCTAssertNil(bot["wakeWindow"], "默认配置不应写入唤醒窗口键")
        bot.removeValue(forKey: "wakeWindow")
        object["bot"] = bot

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertNil(decoded.bot.wakeWindow)
        XCTAssertFalse(decoded.bot.wakeWindowEnabled)
        XCTAssertEqual(decoded.bot.effectiveWakeWindowSeconds, 0)
    }

    func testWakeWindowSettingsRoundtripAndClamping() throws {
        var settings = AppSettings.default
        settings.bot.wakeWindowEnabled = true
        XCTAssertEqual(settings.bot.wakeWindowSeconds, 300)

        settings.bot.wakeWindowSeconds = 30
        XCTAssertEqual(settings.bot.effectiveWakeWindowSeconds, 30)

        // 上限 60 分钟，与 UI 的 1–60 分钟 Stepper 一致。
        settings.bot.wakeWindowSeconds = 7_200
        XCTAssertEqual(settings.bot.wakeWindowSeconds, 3_600)

        let data = try JSONEncoder().encode(settings)
        var decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.bot.wakeWindow, WakeWindowSettings(enabled: true, seconds: 3_600))
        XCTAssertEqual(decoded.bot.effectiveWakeWindowSeconds, 3_600)

        decoded.bot.wakeWindowEnabled = false
        XCTAssertEqual(decoded.bot.effectiveWakeWindowSeconds, 0)
    }

    // MARK: 触发行为

    func testDisabledWakeWindowKeepsTriggerRequired() {
        let settings = makeSettings(wakeWindow: nil)
        let engine = RuleEngine()

        XCTAssertTrue(engine.evaluate(context("@wxid_bot 你好", settings: settings)).shouldReply)
        XCTAssertFalse(
            engine.evaluate(context("继续", at: start.addingTimeInterval(10), settings: settings)).shouldReply
        )
    }

    func testWakeWindowAllowsSameSenderAndSlides() {
        let settings = makeSettings()
        let engine = RuleEngine()

        let woke = engine.evaluate(context("@wxid_bot 你好", settings: settings))
        XCTAssertTrue(woke.shouldReply)
        XCTAssertEqual(woke.triggerLabel, "群聊·@")

        let followUp = engine.evaluate(context("继续", at: start.addingTimeInterval(60), settings: settings))
        XCTAssertTrue(followUp.shouldReply)
        XCTAssertEqual(followUp.triggerLabel, "群聊·唤醒窗口")

        // 滑动续期：距上次命中 180 秒仍放行（距最初唤醒 240 秒）。
        XCTAssertTrue(
            engine.evaluate(context("再继续", at: start.addingTimeInterval(240), settings: settings)).shouldReply
        )
        // 距上次命中 260 秒仍放行（距最初唤醒 500 秒）。
        XCTAssertTrue(
            engine.evaluate(context("还在说", at: start.addingTimeInterval(500), settings: settings)).shouldReply
        )
        // 超过窗口后恢复需要唤醒词。
        XCTAssertFalse(
            engine.evaluate(context("还在吗", at: start.addingTimeInterval(801), settings: settings)).shouldReply
        )
    }

    func testWakeWindowIsPerSenderAndPerConversation() {
        let settings = makeSettings()
        let engine = RuleEngine()

        XCTAssertTrue(
            engine.evaluate(context("@wxid_bot 你好", senderID: "wxid_a", settings: settings)).shouldReply
        )

        // 同一会话的其他人不继承窗口。
        XCTAssertFalse(
            engine.evaluate(
                context("我也来聊", senderID: "wxid_b", at: start.addingTimeInterval(10), settings: settings)
            ).shouldReply
        )
        // 同一发送者在其它群也不继承窗口。
        let otherGroup = Conversation(id: "g2@chatroom", kind: .group, title: "另一个群")
        XCTAssertFalse(
            engine.evaluate(
                context("继续", senderID: "wxid_a", at: start.addingTimeInterval(10),
                        settings: settings, conversation: otherGroup)
            ).shouldReply
        )
        // 唤醒者本人仍在窗口内。
        XCTAssertTrue(
            engine.evaluate(
                context("继续", senderID: "wxid_a", at: start.addingTimeInterval(10), settings: settings)
            ).shouldReply
        )
    }

    func testWakeWindowDoesNotBypassHardGatesOrCooldown() {
        let settings = makeSettings()
        let engine = RuleEngine()
        XCTAssertTrue(engine.evaluate(context("@wxid_bot 你好", settings: settings)).shouldReply)

        // 黑名单优先于窗口。
        var blocked = settings
        blocked.bot.blacklistEntries = ["wxid_user"]
        XCTAssertFalse(
            engine.evaluate(context("继续", at: start.addingTimeInterval(10), settings: blocked)).shouldReply
        )

        // 工作时段外同样拦截。
        var outsideHours = settings
        outsideHours.bot.workingHours.enabled = true
        outsideHours.bot.workingHours.weekdays = []
        XCTAssertFalse(
            engine.evaluate(context("继续", at: start.addingTimeInterval(10), settings: outsideHours)).shouldReply
        )

        // 冷却拦截的消息不会放行，也不会续期；冷却结束后窗口仍按上次唤醒时间计算。
        var cooled = settings
        cooled.bot.cooldownSeconds = 60
        let cooledEngine = RuleEngine()
        XCTAssertTrue(cooledEngine.evaluate(context("@wxid_bot 你好", settings: cooled)).shouldReply)
        cooledEngine.noteReply(conversationID: groupID, at: start)
        XCTAssertFalse(
            cooledEngine.evaluate(context("继续", at: start.addingTimeInterval(10), settings: cooled)).shouldReply
        )
        XCTAssertTrue(
            cooledEngine.evaluate(context("继续", at: start.addingTimeInterval(120), settings: cooled)).shouldReply
        )
    }
}
