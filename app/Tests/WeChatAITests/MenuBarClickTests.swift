import AppKit
import XCTest
@testable import WeChatAI

/// 菜单栏点击语义与图标状态映射的纯函数单测。
///
/// 只覆盖 `MenuBarClickIntent.resolve` 与 `MenuBarIconState`，不触碰
/// `NSStatusItem` / `NSPopover` / 窗口，因此不依赖 WindowServer。
///
/// 当前语义：左键单击 = 开合状态面板；右键 / Control-左键 = 不执行操作。
final class MenuBarClickTests: XCTestCase {
    // MARK: - 左键

    func testLeftClickTogglesPanel() {
        XCTAssertEqual(
            MenuBarClickIntent.resolve(eventType: .leftMouseDown, modifiers: []),
            .togglePanel
        )
        XCTAssertEqual(
            MenuBarClickIntent.resolve(eventType: .leftMouseUp, modifiers: []),
            .togglePanel
        )
    }

    // MARK: - 右键：已移除操作

    func testRightClickIsIgnored() {
        XCTAssertEqual(
            MenuBarClickIntent.resolve(eventType: .rightMouseDown, modifiers: []),
            .ignore
        )
        XCTAssertEqual(
            MenuBarClickIntent.resolve(eventType: .rightMouseUp, modifiers: []),
            .ignore
        )
    }

    // MARK: - Control-左键：按右键处理，不执行操作

    func testControlLeftClickIsIgnored() {
        XCTAssertEqual(
            MenuBarClickIntent.resolve(eventType: .leftMouseDown, modifiers: .control),
            .ignore
        )
        XCTAssertEqual(
            MenuBarClickIntent.resolve(eventType: .leftMouseUp, modifiers: .control),
            .ignore
        )
    }

    func testControlLeftClickWithOtherModifiersIsStillIgnored() {
        XCTAssertEqual(
            MenuBarClickIntent.resolve(
                eventType: .leftMouseUp,
                modifiers: [.control, .shift, .option]
            ),
            .ignore
        )
    }

    // MARK: - 其它修饰键不改变左键语义

    func testNonControlModifiersKeepLeftClickTogglingPanel() {
        XCTAssertEqual(
            MenuBarClickIntent.resolve(eventType: .leftMouseUp, modifiers: [.shift, .option]),
            .togglePanel
        )
        XCTAssertEqual(
            MenuBarClickIntent.resolve(eventType: .leftMouseDown, modifiers: .command),
            .togglePanel
        )
        XCTAssertEqual(
            MenuBarClickIntent.resolve(eventType: .leftMouseUp, modifiers: [.capsLock, .numericPad]),
            .togglePanel
        )
        XCTAssertEqual(
            MenuBarClickIntent.resolve(eventType: .leftMouseUp, modifiers: [.shift, .command]),
            .togglePanel
        )
    }

    func testDeviceDependentModifierBitsAreIgnored() {
        // 只检查 `.deviceIndependentFlagsMask` 内的位，设备相关标志位不应影响分流。
        XCTAssertEqual(
            MenuBarClickIntent.resolve(
                eventType: .leftMouseUp,
                modifiers: [.control, .numericPad]
            ),
            .ignore
        )
        XCTAssertEqual(
            MenuBarClickIntent.resolve(
                eventType: .leftMouseUp,
                modifiers: [.numericPad, .capsLock]
            ),
            .togglePanel
        )
    }

    // MARK: - 合成/未知事件：VoiceOver 兜底

    func testUnknownOrSynthesizedEventTypeTogglesPanel() {
        // VoiceOver / 键盘触发时 `NSApp.currentEvent` 可能是非鼠标事件甚至为 nil，
        // 控制器会退回 `.leftMouseDown`；这里直接验证纯映射对未知类型按左键语义处理。
        for eventType in [NSEvent.EventType.applicationDefined, .systemDefined, .otherMouseUp, .keyDown] {
            XCTAssertEqual(
                MenuBarClickIntent.resolve(eventType: eventType, modifiers: []),
                .togglePanel,
                "eventType \(eventType.rawValue) 应兜底为 togglePanel"
            )
        }
    }

    // MARK: - 图标状态

    func testIconStateSymbolNamesFollowBotRunningState() {
        XCTAssertEqual(MenuBarIconState.running.symbolName, "bubble.left.and.bubble.right.fill")
        XCTAssertEqual(MenuBarIconState.idle.symbolName, "bubble.left.and.bubble.right")
    }

    func testIconStateInitializesFromBotRunningFlag() {
        XCTAssertEqual(MenuBarIconState(isBotRunning: true), .running)
        XCTAssertEqual(MenuBarIconState(isBotRunning: false), .idle)
        XCTAssertEqual(MenuBarIconState(isBotRunning: true).symbolName, MenuBarIconState.running.symbolName)
        XCTAssertEqual(MenuBarIconState(isBotRunning: false).symbolName, MenuBarIconState.idle.symbolName)
    }
}
