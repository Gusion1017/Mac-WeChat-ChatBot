import SwiftUI

/// 会话级工作时间编辑器：跟随全局，或为该会话单独设置不限制 / 指定时段。
struct ConversationWorkingHoursSheet: View {
    let conversationTitle: String
    let global: WorkingHours
    let onSave: (WorkingHours?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var followsGlobal: Bool
    @State private var hours: WorkingHours

    init(
        conversationTitle: String,
        current: WorkingHours?,
        global: WorkingHours,
        onSave: @escaping (WorkingHours?) -> Void
    ) {
        self.conversationTitle = conversationTitle
        self.global = global
        self.onSave = onSave
        _followsGlobal = State(initialValue: current == nil)
        _hours = State(initialValue: current ?? WorkingHours(
            enabled: true,
            startMinute: global.startMinute,
            endMinute: global.endMinute,
            weekdays: global.weekdays
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: "clock.badge.checkmark", tint: Theme.warning, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("会话工作时间").font(.headline)
                    Text(conversationTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("时段来源", selection: $followsGlobal) {
                        Text("跟随全局").tag(true)
                        Text("自定义").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if followsGlobal {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("当前全局工作时间")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(globalSummary)
                                .font(.callout)
                            Text("之后在「机器人 → 工作时间」修改全局设置时，此会话会同步生效。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Toggle("启用时间限制", isOn: $hours.enabled)
                            .toggleStyle(.switch)
                            .font(.callout)

                        if hours.enabled {
                            HStack(spacing: 5) {
                                ForEach(UIFormat.weekdayOptions, id: \.value) { option in
                                    FilterChip(
                                        title: option.label,
                                        isSelected: hours.weekdays.contains(option.value),
                                        tint: Theme.warning
                                    ) {
                                        toggleWeekday(option.value)
                                    }
                                }
                                Spacer()
                            }

                            HStack(spacing: 16) {
                                DatePicker(
                                    "开始",
                                    selection: minuteBinding(\.startMinute),
                                    displayedComponents: .hourAndMinute
                                )
                                DatePicker(
                                    "结束",
                                    selection: minuteBinding(\.endMinute),
                                    displayedComponents: .hourAndMinute
                                )
                                Spacer()
                                Text("跨夜时段会自动识别")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            Text("关闭限制后，此会话在任何时间都会自动回复。")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 9) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(followsGlobal ? nil : hours)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 540, height: 470)
        .background(.regularMaterial)
    }

    // MARK: Helpers

    private var globalSummary: String {
        summary(global)
    }

    private func summary(_ hours: WorkingHours) -> String {
        guard hours.enabled else { return "不限制时间" }
        return "\(UIFormat.weekdaySummary(Array(hours.weekdays))) · \(minuteLabel(hours.startMinute))–\(minuteLabel(hours.endMinute))"
    }

    private func minuteLabel(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private func toggleWeekday(_ weekday: Int) {
        if hours.weekdays.contains(weekday) {
            hours.weekdays.remove(weekday)
        } else {
            hours.weekdays.insert(weekday)
        }
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<WorkingHours, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = hours[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                hours[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }
}
