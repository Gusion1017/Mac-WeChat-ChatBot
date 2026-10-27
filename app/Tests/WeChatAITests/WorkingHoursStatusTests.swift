import XCTest
@testable import WeChatAI

/// 会话详情头部的工作时间徽标依赖 `WorkingHours.status(at:calendar:)` 做展示判定；
/// 这里固定时区与日期，覆盖起止边界、跨夜、星期过滤和会话覆盖优先级。
final class WorkingHoursStatusTests: XCTestCase {
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

    func testStatusUnrestrictedWhenDisabled() {
        let hours = WorkingHours(enabled: false)
        // 周六凌晨不在默认时段，但限制关闭后仍是不限制状态。
        XCTAssertEqual(
            hours.status(at: date(2026, 10, 24, 3, 0), calendar: calendar),
            .unrestricted
        )
    }

    func testStatusHonorsMinuteBoundariesAndWeekdays() {
        let hours = WorkingHours(
            enabled: true,
            startMinute: 9 * 60,
            endMinute: 18 * 60,
            weekdays: [2, 3, 4, 5, 6]
        )
        // 2026-10-19 是周一（Calendar.weekday == 2）。
        XCTAssertEqual(hours.status(at: date(2026, 10, 19, 8, 59), calendar: calendar), .paused)
        XCTAssertEqual(hours.status(at: date(2026, 10, 19, 9, 0), calendar: calendar), .active)
        XCTAssertEqual(hours.status(at: date(2026, 10, 19, 17, 59), calendar: calendar), .active)
        // 结束分钟为开区间：18:00 已不在时段内，与 RuleEngine 一致。
        XCTAssertEqual(hours.status(at: date(2026, 10, 19, 18, 0), calendar: calendar), .paused)
        // 2026-10-24 是周六，不在工作日集合内。
        XCTAssertEqual(hours.status(at: date(2026, 10, 24, 12, 0), calendar: calendar), .paused)
    }

    func testStatusHandlesOvernightWindow() {
        let hours = WorkingHours(
            enabled: true,
            startMinute: 22 * 60,
            endMinute: 6 * 60,
            weekdays: [1, 2, 3, 4, 5, 6, 7]
        )
        XCTAssertEqual(hours.status(at: date(2026, 10, 19, 21, 59), calendar: calendar), .paused)
        XCTAssertEqual(hours.status(at: date(2026, 10, 19, 22, 0), calendar: calendar), .active)
        XCTAssertEqual(hours.status(at: date(2026, 10, 20, 2, 0), calendar: calendar), .active)
        XCTAssertEqual(hours.status(at: date(2026, 10, 20, 6, 0), calendar: calendar), .paused)
        XCTAssertEqual(hours.status(at: date(2026, 10, 20, 12, 0), calendar: calendar), .paused)
    }

    func testOvernightWindowUsesPreviousWeekdayForAfterMidnight() {
        // 周一~周五 22:00–06:00：周五晚的窗口延续到周六凌晨，星期要按周五算。
        let hours = WorkingHours(
            enabled: true,
            startMinute: 22 * 60,
            endMinute: 6 * 60,
            weekdays: [2, 3, 4, 5, 6]
        )
        // 2026-10-23 是周五，2026-10-24 是周六，2026-10-25 是周日，2026-10-26 是周一。
        XCTAssertEqual(hours.status(at: date(2026, 10, 23, 22, 30), calendar: calendar), .active)
        XCTAssertEqual(hours.status(at: date(2026, 10, 24, 0, 30), calendar: calendar), .active)
        XCTAssertEqual(hours.status(at: date(2026, 10, 24, 3, 0), calendar: calendar), .active)
        XCTAssertEqual(hours.status(at: date(2026, 10, 24, 6, 0), calendar: calendar), .paused)
        // 周六晚不在工作日集合内，周日凌晨也不该被周五/周六的窗口误判为 active。
        XCTAssertEqual(hours.status(at: date(2026, 10, 24, 22, 30), calendar: calendar), .paused)
        XCTAssertEqual(hours.status(at: date(2026, 10, 25, 0, 30), calendar: calendar), .paused)
        // 周日不是工作日，周一 00:30 也不该激活。
        XCTAssertEqual(hours.status(at: date(2026, 10, 26, 0, 30), calendar: calendar), .paused)
        XCTAssertEqual(hours.status(at: date(2026, 10, 26, 22, 30), calendar: calendar), .active)
        XCTAssertEqual(hours.status(at: date(2026, 10, 27, 0, 30), calendar: calendar), .active)
    }

    func testStatusPausedWhenNoWeekdaySelected() {
        let hours = WorkingHours(
            enabled: true,
            startMinute: 0,
            endMinute: 24 * 60,
            weekdays: []
        )
        XCTAssertEqual(hours.status(at: date(2026, 10, 19, 12, 0), calendar: calendar), .paused)
    }

    func testConversationOverrideWinsForStatus() {
        let global = WorkingHours(
            enabled: true,
            startMinute: 9 * 60,
            endMinute: 18 * 60,
            weekdays: [2, 3, 4, 5, 6]
        )
        let noon = date(2026, 10, 19, 12, 0)
        var conversation = Conversation(id: "c1", kind: .direct, title: "测试")

        // 未设置会话时段时跟随全局，午间在工作时段内。
        XCTAssertFalse(conversation.usesCustomWorkingHours)
        XCTAssertEqual(
            conversation.effectiveWorkingHours(global: global).status(at: noon, calendar: calendar),
            .active
        )

        // 会话自定义 19:00–08:00 覆盖全局，午间被判定为非工作时段。
        conversation.workingHours = WorkingHours(
            enabled: true,
            startMinute: 19 * 60,
            endMinute: 8 * 60,
            weekdays: [1, 2, 3, 4, 5, 6, 7]
        )
        XCTAssertTrue(conversation.usesCustomWorkingHours)
        XCTAssertEqual(
            conversation.effectiveWorkingHours(global: global).status(at: noon, calendar: calendar),
            .paused
        )

        // 会话显式不限制时，即使全局不包含当前时间也显示为不限时段。
        conversation.workingHours = WorkingHours(enabled: false)
        XCTAssertEqual(
            conversation.effectiveWorkingHours(global: global).status(at: noon, calendar: calendar),
            .unrestricted
        )
    }
}
