import SwiftUI

/// 会话级工作时间编辑器：跟随全局 / 自定义时段 / 不限时段三态互斥。
///
/// 保存映射：
/// - 跟随全局 → `nil`（`Conversation.workingHours = nil`）
/// - 不限时段 → `WorkingHours(enabled: false)`
/// - 自定义时段 → 收敛后的 `WorkingHours`（`enabled == true`）
struct ConversationWorkingHoursSheet: View {
    let conversationTitle: String
    let global: WorkingHours
    let onSave: (WorkingHours?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice: WorkingHoursChoice
    @State private var draft: WorkingHours

    init(
        conversationTitle: String,
        current: WorkingHours?,
        global: WorkingHours,
        onSave: @escaping (WorkingHours?) -> Void
    ) {
        self.conversationTitle = conversationTitle
        self.global = global
        self.onSave = onSave
        _choice = State(initialValue: WorkingHoursChoice(current))

        // 自定义缓冲始终按「启用」准备：全局未启用时切到自定义，编辑器会明确提示
        // 「保存后将开启时间限制」，不会让用户以为只是编辑时段。
        // 会话当前是「不限时段」时没有有意义的时段，自定义从全局默认开始。
        var buffer = current.flatMap { $0.enabled ? $0 : nil } ?? global
        buffer.enabled = true
        if buffer.weekdays.isEmpty { buffer.weekdays = Set(1...7) }
        if buffer.startMinute == buffer.endMinute {
            buffer.endMinute = (buffer.startMinute + 60) % 1440
        }
        _draft = State(initialValue: buffer.sanitized)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                WorkingHoursEditor(
                    mode: .conversation(global: global),
                    hours: $draft,
                    choice: $choice
                )
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 580, height: 620)
        .background(.regularMaterial)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "clock.badge.checkmark", tint: Theme.warning, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("会话工作时间")).font(.headline)
                Text(conversationTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PillLabel(
                text: choice.title,
                color: choice == .unrestricted ? .secondary : Theme.warning,
                symbol: choice.symbol
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 9) {
            Text(L("仅影响此会话的自动回复；手动发送不受影响。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(L("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("保存")) {
                onSave(choice.savedValue(custom: draft))
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
