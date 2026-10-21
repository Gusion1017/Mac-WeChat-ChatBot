import SwiftUI

/// Client-side next-fire estimation used only for display. The authoritative
/// scheduler lives in Core; when Core provides `nextFireAt` we prefer it.
enum ScheduleMath {
    static func nextFire(for task: ScheduledTask, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard task.enabled else { return nil }
        let comps = calendar.dateComponents([.hour, .minute], from: task.fireAt)
        guard let hour = comps.hour, let minute = comps.minute else { return nil }

        switch task.repeatRule {
        case .once:
            return task.fireAt > now ? task.fireAt : nil

        case .daily:
            var candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            if candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            return candidate

        case .weekdays:
            return nextMatchingDay(
                hour: hour, minute: minute, now: now, calendar: calendar,
                allowed: { (2...6).contains($0) }
            )

        case .weekly:
            let days = task.weekdays.isEmpty ? [2, 3, 4, 5, 6] : task.weekdays
            return nextMatchingDay(
                hour: hour, minute: minute, now: now, calendar: calendar,
                allowed: { days.contains($0) }
            )
        }
    }

    private static func nextMatchingDay(
        hour: Int,
        minute: Int,
        now: Date,
        calendar: Calendar,
        allowed: (Int) -> Bool
    ) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 0...14 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard allowed(weekday) else { continue }
            guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if candidate > now { return candidate }
        }
        return nil
    }

    static func dayLabel(for date: Date?, calendar: Calendar = .current) -> String {
        guard let date else { return "—" }
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        return UIFormat.weekdayName(calendar.component(.weekday, from: date))
    }
}

/// Scheduled task row with next-fire emphasis.
struct ScheduleRow: View {
    let task: ScheduledTask
    var nextFire: Date?
    /// 目标会话的展示名（调用方按当前会话解析，避免旧数据里的 wxid 标题直接露出）。
    var conversationLabel: String?
    var onToggle: (Bool) -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    private var tint: Color { task.enabled ? Theme.accent : .secondary }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 1) {
                Text(nextFire.map { UIFormat.time.string(from: $0) } ?? "--:--")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(task.enabled ? Color.primary : Color.secondary)
                Text(nextFire.map { ScheduleMath.dayLabel(for: $0) } ?? "已结束")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 62)
            .padding(.top, 1)

            Rectangle()
                .fill(tint.opacity(0.25))
                .frame(width: 2)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.name.isEmpty ? "未命名任务" : task.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    PillLabel(text: task.repeatRule.label, color: Theme.info, symbol: "repeat")
                    if task.repeatRule == .weekly {
                        PillLabel(text: UIFormat.weekdaySummary(task.weekdays), color: Theme.violet)
                    }
                    if !task.enabled {
                        PillLabel(text: "已暂停", color: .secondary)
                    }
                }
                Text(task.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 9) {
                    Label(conversationLabel ?? (task.conversationTitle.isEmpty ? task.conversationID : task.conversationTitle),
                          systemImage: "bubble.left")
                    if let nextFire {
                        Label(L("下次 \(UIFormat.relative(nextFire))"), systemImage: "calendar.badge.clock")
                    }
                    if let last = task.lastFiredAt {
                        Label(L("上次 \(UIFormat.relative(last))"), systemImage: "clock.arrow.circlepath")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 7) {
                Toggle(
                    "启用",
                    isOn: Binding(get: { task.enabled }, set: { onToggle($0) })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(task.enabled ? "暂停此任务" : "启用此任务")
                .accessibilityLabel(L("启用任务 \(task.name)"))

                HStack(spacing: 6) {
                    Button(L("编辑")) { onEdit() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Menu {
                        Button(L("编辑…"), action: onEdit)
                        Divider()
                        Button(L("删除任务…"), role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(L("\(task.name) 更多操作"))
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
