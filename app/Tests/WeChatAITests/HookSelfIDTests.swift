import XCTest
@testable import WeChatAI

final class HookSelfIDTests: XCTestCase {
    private func imagePath(_ accountDir: String) -> URL {
        URL(fileURLWithPath: "/tmp/xwechat_files/\(accountDir)/temp", isDirectory: true)
    }

    func testKeepsSelfIDMatchingImagePathAccount() {
        let path = imagePath("wxid_bot_abcd")
        XCTAssertEqual(HookManager.validatedSelfID("wxid_bot", imagePath: path), "wxid_bot")
        XCTAssertEqual(HookManager.validatedSelfID("WXID_BOT", imagePath: path), "WXID_BOT")
    }

    /// 测试/历史事件污染 self_id 时不要让 bridge 用它覆盖真实账号。
    func testDropsSelfIDNotMatchingImagePathAccount() {
        let path = imagePath("wxid_bot_abcd")
        XCTAssertEqual(HookManager.validatedSelfID("wxid_self", imagePath: path), "")
        XCTAssertEqual(HookManager.validatedSelfID("wxid_other", imagePath: path), "")
    }

    func testEmptySelfIDStaysEmpty() {
        XCTAssertEqual(HookManager.validatedSelfID("  ", imagePath: imagePath("wxid_bot_abcd")), "")
    }

    /// 自定义/旧版 image_path 无法判断账号时保留原值，由 bridge 自行推导。
    func testKeepsSelfIDWhenPathHasNoAccountDirectory() {
        let path = URL(fileURLWithPath: "/tmp/wechat-media/Img", isDirectory: true)
        XCTAssertEqual(HookManager.validatedSelfID("wxid_bot", imagePath: path), "wxid_bot")
    }
}
