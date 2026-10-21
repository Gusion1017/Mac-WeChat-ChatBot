import SwiftUI

/// One row in the conversation list: avatar, title, preview, time, unread and a
/// read-only AI status marker. The AI switch itself lives once in the chat detail
/// header, so each conversation setting has a single control.
struct SessionRow: View {
    let conversation: Conversation
    let isSelected: Bool
    /// 该会话正在处理的自动回复进度；有值时用阶段计时替代相对时间。
    var replyProgress: ReplyProgress?
    var onSelect: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                AvatarView(title: conversation.displayTitle, kind: conversation.kind, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(conversation.displayTitle)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if conversation.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 7.5))
                                .foregroundStyle(.tertiary)
                        }
                        if !conversation.aiEnabled {
                            Image(systemName: "bolt.slash.fill")
                                .font(.system(size: 7.5))
                                .foregroundStyle(.tertiary)
                                .help(L("AI 自动回复已关闭"))
                        }
                        Spacer(minLength: 4)
                        if let replyProgress {
                            ReplyMiniStatus(progress: replyProgress)
                        } else if let date = conversation.lastMessageAt {
                            Text(UIFormat.relativeShort(date))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    HStack(spacing: 5) {
                        Text(conversation.lastMessagePreview.isEmpty ? L("暂无消息") : conversation.lastMessagePreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if conversation.unreadCount > 0 {
                            Text("\(conversation.unreadCount)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 15, minHeight: 15)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "再次点击收起当前对话" : "打开会话")
        .accessibilityLabel("\(conversation.displayTitle)，\(conversation.kind.label)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isSelected ? "再次点击收起当前对话" : "打开会话")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(background)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.28), lineWidth: 1)
            }
        }
        .onHover { isHovering = $0 }
    }

    private var accessibilityValue: String {
        var parts = [conversation.unreadCount > 0 ? "\(conversation.unreadCount) 条未读" : "无未读"]
        if !conversation.aiEnabled { parts.append("AI 自动回复已关闭") }
        return parts.joined(separator: "，")
    }

    private var background: Color {
        if isSelected {
            return Theme.accent.opacity(colorScheme == .dark ? 0.22 : 0.13)
        }
        return isHovering ? Color.primary.opacity(0.045) : .clear
    }
}
