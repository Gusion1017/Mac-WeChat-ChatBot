import SwiftUI

/// 会话详情头部的工作时间状态徽标。
///
/// 规则引擎按「会话自定义优先、否则跟随全局」的生效时段决定是否自动回复；这里用同一个
/// `WorkingHours.contains` 判定，并把「现在是否在工作时段」直接显示出来，避免用户只能
/// 看配置猜当前是否生效。`.everyMinute` 只刷新徽标自身，不用定时器驱动整个会话页。
struct WorkingHoursBadge: View {
    /// 已合并会话覆盖后的生效时段。
    let workingHours: WorkingHours
    /// 生效时段是否来自会话自定义（false 表示跟随全局）。
    let isOverride: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            badge(at: context.date)
        }
    }

    private func badge(at date: Date) -> some View {
        let status = workingHours.status(at: date)
        return PillLabel(text: status.label, color: status.tint, symbol: status.symbol)
            .help(L(helpText(for: status)))
            .accessibilityLabel(L(accessibilityText(for: status)))
    }

    // MARK: Copy

    private var sourceLabel: String {
        isOverride ? "会话时段" : "全局时段"
    }

    private func helpText(for status: WorkingHours.Status) -> String {
        switch status {
        case .unrestricted:
            let reason = isOverride ? "此会话已取消工作时间限制" : "全局未启用工作时间限制"
            return "\(reason)，规则引擎不会因时间拦截自动回复。"
        case .active:
            return "当前处于工作时段，规则引擎不会因时间拦截自动回复。\n"
                + "\(sourceLabel)：\(scheduleSummary)"
        case .paused:
            return "当前不在工作时段，规则引擎会拦截自动回复（手动发送不受影响）。\n"
                + "\(sourceLabel)：\(scheduleSummary)"
        }
    }

    private func accessibilityText(for status: WorkingHours.Status) -> String {
        switch status {
        case .unrestricted:
            return "工作时间：不限时段"
        case .active:
            return "工作时间：当前处于工作时段，\(sourceLabel) \(scheduleSummary)"
        case .paused:
            return "工作时间：当前不在工作时段，\(sourceLabel) \(scheduleSummary)"
        }
    }

    /// 例如「工作日 09:00–18:00」；跨夜时标注「次日」，未选任何星期时直接说明。
    private var scheduleSummary: String {
        guard !workingHours.weekdays.isEmpty else { return "未选择任何星期" }
        let days = UIFormat.weekdaySummary(Array(workingHours.weekdays))
        let start = Self.minuteLabel(workingHours.startMinute)
        let end = Self.minuteLabel(workingHours.endMinute)
        let range = workingHours.startMinute > workingHours.endMinute
            ? "\(start)–次日 \(end)"
            : "\(start)–\(end)"
        return "\(days) \(range)"
    }

    private static func minuteLabel(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

private extension WorkingHours.Status {
    var label: String {
        switch self {
        case .unrestricted: "不限时段"
        case .active: "工作时段"
        case .paused: "非工作时段"
        }
    }

    var symbol: String {
        switch self {
        case .unrestricted: "infinity"
        case .active: "clock.fill"
        case .paused: "clock.badge.xmark"
        }
    }

    var tint: Color {
        switch self {
        case .unrestricted: .secondary
        case .active: Theme.success
        case .paused: Theme.warning
        }
    }
}
