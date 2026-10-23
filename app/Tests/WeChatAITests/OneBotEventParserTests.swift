import Foundation
import XCTest
@testable import WeChatAI

/// 入站帧解析的性能改造：`handleInbound` 只做一次 `JSONSerialization`，
/// 事件解析复用已反序列化的对象与原始帧文本（不再二次解析/重新序列化）。
final class OneBotEventParserTests: XCTestCase {
    private let singleFrame = #"{"self_id":"wxid_bot","user_id":"wxid_friend","message_id":"m1","time":1760000000,"message_type":"private","message":[{"type":"text","data":{"text":"hi"}}],"raw_message":"hi"}"#

    /// 单事件帧：`rawJSON` 必须就是传入的原始帧文本，而不是重新序列化的结果。
    func testParseObjectKeepsOriginalFrameTextAsRawJSON() throws {
        let object = try JSONSerialization.jsonObject(with: Data(singleFrame.utf8))
        let events = OneBotEventParser.parse(object: object, rawText: singleFrame)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.rawJSON, singleFrame)
        XCTAssertEqual(events.first?.messageID, "m1")
        XCTAssertEqual(events.first?.plainText, "hi")
    }

    /// 数组帧仍解析出多条事件（与 `parse(data:)` 的旧行为一致）。
    func testParseObjectHandlesArrayFrame() throws {
        let frame = #"[{"self_id":"wxid_bot","user_id":"wxid_a","message_id":"a1","time":1760000000,"message":[{"type":"text","data":{"text":"one"}}],"raw_message":"one"},{"self_id":"wxid_bot","user_id":"wxid_b","message_id":"b1","time":1760000001,"message":[{"type":"text","data":{"text":"two"}}],"raw_message":"two"}]"#
        let object = try JSONSerialization.jsonObject(with: Data(frame.utf8))
        let events = OneBotEventParser.parse(object: object, rawText: frame)
        XCTAssertEqual(events.map(\.messageID), ["a1", "b1"])
        XCTAssertEqual(events.map(\.plainText), ["one", "two"])
        // 数组帧按旧行为逐元素解析：整帧文本不能当作单条事件的 rawJSON。
        XCTAssertTrue(events.allSatisfy { !$0.rawJSON.isEmpty && $0.rawJSON != frame })
    }

    /// `{"data":{...}}` 包装帧：解析嵌套事件，且保留原始帧文本。
    func testParseObjectHandlesWrappedDataFrameAndKeepsRawText() throws {
        let frame = #"{"post_type":"message","data":{"self_id":"wxid_bot","user_id":"wxid_friend","message_id":"m9","time":1760000000,"message":[{"type":"text","data":{"text":"wrapped"}}],"raw_message":"wrapped"}}"#
        let object = try JSONSerialization.jsonObject(with: Data(frame.utf8))
        let events = OneBotEventParser.parse(object: object, rawText: frame)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.rawJSON, frame)
        XCTAssertEqual(events.first?.conversationID, "wxid_friend")
        XCTAssertEqual(events.first?.plainText, "wrapped")
    }

    /// 非字典/数组对象、无法识别的帧保持返回空数组。
    func testParseObjectRejectsUnknownFrames() {
        let rejected: [Any] = ["nope", NSNull(), 42, [String: Any](), [[String: Any]]()]
        for object in rejected {
            XCTAssertTrue(
                OneBotEventParser.parse(object: object, rawText: nil).isEmpty,
                "对象 \(object) 不应解析出事件"
            )
        }
    }

    /// `parse(data:)` 旧 API 行为不回归：单帧 / 数组帧 / 包装帧 / 非法 JSON。
    func testParseDataLegacyBehaviourIsPreserved() {
        let singleEvents = OneBotEventParser.parse(data: Data(singleFrame.utf8))
        XCTAssertEqual(singleEvents.count, 1)
        XCTAssertEqual(singleEvents.first?.messageID, "m1")
        XCTAssertEqual(singleEvents.first?.plainText, "hi")
        // 没有原始帧文本时仍会重新序列化出非空 rawJSON。
        XCTAssertFalse(singleEvents.first?.rawJSON.isEmpty ?? true)

        let array = #"[{"user_id":"a","message_id":"a1","time":1760000000,"message":[{"type":"text","data":{"text":"a1"}}]},{"user_id":"b","message_id":"b1","time":1760000001,"message":[{"type":"text","data":{"text":"b1"}}]}]"#
        XCTAssertEqual(
            OneBotEventParser.parse(data: Data(array.utf8)).map(\.messageID),
            ["a1", "b1"]
        )

        let wrapped = #"{"data":{"user_id":"c","message_id":"c1","time":1760000000,"message":[{"type":"text","data":{"text":"wrapped"}}]}}"#
        let wrappedEvents = OneBotEventParser.parse(data: Data(wrapped.utf8))
        XCTAssertEqual(wrappedEvents.count, 1)
        XCTAssertEqual(wrappedEvents.first?.messageID, "c1")

        XCTAssertTrue(OneBotEventParser.parse(data: Data("not-json".utf8)).isEmpty)
        XCTAssertTrue(OneBotEventParser.parse(data: Data("[]".utf8)).isEmpty)
    }
}
