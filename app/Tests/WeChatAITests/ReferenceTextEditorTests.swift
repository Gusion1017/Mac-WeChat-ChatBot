import AppKit
import SwiftUI
import XCTest

@testable import WeChatAI

/// `ReferenceTextEditor`（原生 NSTextView 包装）的输入链路回归测试：
/// 文本变化要回写 Binding，字符上限要阻止超限输入 —— 这两条是手动输入参考文本的基础。
final class ReferenceTextEditorTests: XCTestCase {
    func testCoordinatorWritesTextChangesBackToBinding() {
        var value = ""
        let editor = ReferenceTextEditor(
            text: Binding(get: { value }, set: { value = $0 }))
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView()
        textView.string = "这是参考文本。"
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(value, "这是参考文本。")
    }

    func testCoordinatorKeepsBindingInSyncOnlyOnChange() {
        var value = "已经是这个文本"
        var changes = 0
        let editor = ReferenceTextEditor(
            text: Binding(get: { value }, set: { value = $0; changes += 1 }))
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView()
        textView.string = value
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(changes, 0, "内容未变化时不应重复回写 Binding")
    }

    func testCharacterLimitBlocksOverflowAndReportsLimit() {
        var value = "abc"
        var limitReached = false
        let editor = ReferenceTextEditor(
            text: Binding(get: { value }, set: { value = $0 }),
            characterLimit: 5,
            onReachLimit: { limitReached = true }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView()
        textView.string = "abc"
        XCTAssertTrue(
            coordinator.textView(
                textView,
                shouldChangeTextIn: NSRange(location: 3, length: 0),
                replacementString: "de"),
            "恰好达到上限应允许")
        XCTAssertFalse(
            coordinator.textView(
                textView,
                shouldChangeTextIn: NSRange(location: 3, length: 0),
                replacementString: "def"),
            "超过上限应阻止")
        XCTAssertTrue(limitReached)
        XCTAssertEqual(value, "abc", "被阻止的输入不应改动 Binding")
    }
}
