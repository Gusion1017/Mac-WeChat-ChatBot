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
            .accessibilityLabel(accessibilityText(for: status))
    }

    // MARK: 文案

    /// 统一措辞：工作时段 / 非工作时段 / 不限时段（见 `WorkingHoursEditor.swift`）。
    private var sourceText: String {
        isOverride ? "此会话自定义" : "跟随全局默认"
    }

    private func helpText(for status: WorkingHours.Status) -> String {
        switch status {
        case .unrestricted:
            return isOverride
                ? "此会话已设为「不限时段」：任何时间都允许自动回复，规则引擎不会因时间拦截。"
                : "全局未启用工作时间限制（不限时段）：任何时间都允许自动回复，规则引擎不会因时间拦截。"
        case .active:
            return "当前处于「工作时段」，规则引擎不会因时间拦截自动回复（手动发送不受影响）。\n"
                + "来源：\(L(sourceText)) · \(workingHours.summaryText)"
                + neverEffectiveNote
        case .paused:
            return "当前处于「非工作时段」，规则引擎会拦截此会话的自动回复（手动发送不受影响）。\n"
                + "来源：\(L(sourceText)) · \(workingHours.summaryText)"
                + neverEffectiveNote
        }
    }

    /// 零长度窗口在摘要里只显示为「09:00–09:00」，需要额外说明；空星期已由
    /// `summaryText` 直接说明，不再重复。
    private var neverEffectiveNote: String {
        guard workingHours.enabled else { return "" }
        if workingHours.hasZeroLengthWindow {
            return L("\n注意：开始与结束相同，时段永远不会生效。")
        }
        return ""
    }

    private func accessibilityText(for status: WorkingHours.Status) -> String {
        let source = L(sourceText)
        switch status {
        case .unrestricted:
            return Lf("工作时间：不限时段（%@）", source)
        case .active:
            return Lf("工作时间：工作时段（%@ · %@）", source, workingHours.summaryText)
        case .paused:
            return Lf("工作时间：非工作时段（%@ · %@）", source, workingHours.summaryText)
        }
    }
}
