import XCTest
@testable import WeChatAI

/// 工作时间编辑器依赖的 `WorkingHours` 纯函数：收敛无效配置、摘要文案与
/// 「永远不会生效」判断。`contains()` 的既有语义不在本测试里改动，只固定其行为。
final class WorkingHoursEditorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    // MARK: sanitized

    func testSanitizedClampsMinutesAndWeekdays() {
        let raw = WorkingHours(
            enabled: true,
            startMinute: -20,
            endMinute: 2000,
            weekdays: [0, 1, 8, 7]
        )
        let sanitized = raw.sanitized

        XCTAssertEqual(sanitized.startMinute, 0)
        XCTAssertEqual(sanitized.endMinute, 1439)
        XCTAssertEqual(sanitized.weekdays, [1, 7])
        XCTAssertTrue(raw.needsRepair)
        // 收敛一次后即为稳定配置，UI 不再显示「修复设置」。
        XCTAssertFalse(sanitized.needsRepair)
    }

    func testSanitizedFallsBackToEveryDayWhenEnabledWithoutWeekdays() {
        // 旧配置可能存在「已启用但没有星期」，contains 会永远是 false。
        let raw = WorkingHours(enabled: true, startMinute: 9 * 60, endMinute: 18 * 60, weekdays: [])
        XCTAssertTrue(raw.isNeverEffective)
        XCTAssertFalse(raw.contains(date(2026, 10, 19, 12, 0), calendar: calendar))

        let sanitized = raw.sanitized
        XCTAssertEqual(sanitized.weekdays, Set(1...7))
        XCTAssertFalse(sanitized.isNeverEffective)
        // 2026-10-19 是周一，收敛后 12:00 命中 09:00–18:00。
        XCTAssertTrue(sanitized.contains(date(2026, 10, 19, 12, 0), calendar: calendar))
    }

    func testSanitizedKeepsNoWeekdaysWhenDisabled() {
        let raw = WorkingHours(enabled: false, startMinute: 9 * 60, endMinute: 18 * 60, weekdays: [])
        let sanitized = raw.sanitized

        XCTAssertFalse(sanitized.enabled)
        XCTAssertTrue(sanitized.weekdays.isEmpty)
        XCTAssertFalse(sanitized.isNeverEffective)
        XCTAssertEqual(sanitized.summaryText, L("不限时段"))
    }

    func testSanitizedShiftsZeroLengthWindowByOneHour() {
        let raw = WorkingHours(enabled: true, startMinute: 9 * 60, endMinute: 9 * 60, weekdays: [2])
        XCTAssertTrue(raw.hasZeroLengthWindow)
        XCTAssertTrue(raw.isNeverEffective)
        // contains 的既有语义：开始 == 结束时永远为 false。
        XCTAssertFalse(raw.contains(date(2026, 10, 19, 12, 0), calendar: calendar))

        let sanitized = raw.sanitized
        XCTAssertEqual(sanitized.endMinute, 10 * 60)
        XCTAssertFalse(sanitized.hasZeroLengthWindow)
        XCTAssertFalse(sanitized.isNeverEffective)
        XCTAssertTrue(sanitized.contains(date(2026, 10, 19, 9, 30), calendar: calendar))
        // 结束分钟仍是开区间。
        XCTAssertFalse(sanitized.contains(date(2026, 10, 19, 10, 0), calendar: calendar))
    }

    func testSanitizedWrapsZeroLengthWindowAcrossMidnight() {
        let raw = WorkingHours(enabled: true, startMinute: 1439, endMinute: 1439, weekdays: [1])
        let sanitized = raw.sanitized

        // 23:59 + 1 小时 → 次日 00:59，仍是非零长度窗口。
        XCTAssertEqual(sanitized.endMinute, 59)
        XCTAssertEqual(sanitized.timeRangeText, "23:59–\(L("次日")) 00:59")
        XCTAssertFalse(sanitized.isNeverEffective)
    }

    func testSanitizedDoesNotShiftDisabledZeroLengthWindow() {
        let raw = WorkingHours(enabled: false, startMinute: 10 * 60, endMinute: 10 * 60, weekdays: [])
        let sanitized = raw.sanitized
        XCTAssertFalse(sanitized.enabled)
        XCTAssertEqual(sanitized.startMinute, 10 * 60)
        XCTAssertEqual(sanitized.endMinute, 10 * 60)
        XCTAssertFalse(sanitized.needsRepair)
    }

    // MARK: needsRepair / isNeverEffective

    func testValidConfigurationNeedsNoRepair() {
        let valid = WorkingHours(
            enabled: true,
            startMinute: 9 * 60,
            endMinute: 18 * 60,
            weekdays: [2, 3, 4, 5, 6]
        )
        XCTAssertFalse(valid.needsRepair)
        XCTAssertFalse(valid.isNeverEffective)
        XCTAssertFalse(valid.hasZeroLengthWindow)
    }

    func testDisabledConfigurationIsNeverEffective() {
        // 未启用时约等于「不限时段」，空星期与零长度窗口都不需要提示。
        let disabled = WorkingHours(enabled: false, startMinute: 0, endMinute: 0, weekdays: [])
        XCTAssertFalse(disabled.isNeverEffective)
        XCTAssertFalse(disabled.needsRepair)
    }

    // MARK: summaryText / timeRangeText / minuteText

    func testSummaryTextForDisabledIsUnrestricted() {
        XCTAssertEqual(WorkingHours(enabled: false).summaryText, L("不限时段"))
    }

    func testSummaryTextForWorkdaysAndEveryDay() {
        let workdays = WorkingHours(
            enabled: true,
            startMinute: 9 * 60,
            endMinute: 18 * 60,
            weekdays: [2, 3, 4, 5, 6]
        )
        XCTAssertEqual(
            workdays.summaryText,
            "\(UIFormat.weekdaySummary([2, 3, 4, 5, 6])) 09:00–18:00"
        )

        let everyDay = WorkingHours(
            enabled: true,
            startMinute: 9 * 60,
            endMinute: 23 * 60,
            weekdays: Set(1...7)
        )
        XCTAssertEqual(everyDay.summaryText, "\(L("每天")) 09:00–23:00")
    }

    func testSummaryTextMarksOvernightWindowAndEmptyWeekdays() {
        let overnight = WorkingHours(
            enabled: true,
            startMinute: 22 * 60,
            endMinute: 6 * 60,
            weekdays: Set(1...7)
        )
        XCTAssertEqual(overnight.timeRangeText, "22:00–\(L("次日")) 06:00")
        XCTAssertTrue(overnight.summaryText.contains(overnight.timeRangeText))

        let noWeekdays = WorkingHours(enabled: true, weekdays: [])
        XCTAssertEqual(noWeekdays.summaryText, L("未选择任何星期，不会生效"))
    }

    func testMinuteTextClampsOutOfRangeValues() {
        XCTAssertEqual(WorkingHours.minuteText(9 * 60 + 5), "09:05")
        XCTAssertEqual(WorkingHours.minuteText(-1), "00:00")
        XCTAssertEqual(WorkingHours.minuteText(1500), "23:59")
    }

    // MARK: successful conversation override

    func testConversationOverrideUsesCustomHoursForStatus() {
        let global = WorkingHours(
            enabled: true,
            startMinute: 9 * 60,
            endMinute: 18 * 60,
            weekdays: [2, 3, 4, 5, 6]
        )
        var conversation = Conversation(id: "c1", kind: .direct, title: "测试")
        conversation.workingHours = WorkingHours(
            enabled: true,
            startMinute: 19 * 60,
            endMinute: 22 * 60,
            weekdays: [2, 3, 4, 5, 6]
        )

        // 2026-10-19 周一 20:00 命中会话自定义 19:00–22:00，而不是全局 09:00–18:00。
        let evening = date(2026, 10, 19, 20, 0)
        XCTAssertEqual(
            conversation.effectiveWorkingHours(global: global).status(at: evening, calendar: calendar),
            .active
        )
    }
}
