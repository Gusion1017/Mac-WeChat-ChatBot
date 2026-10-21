import SwiftUI

/// 会话重命名：微信 4.1.15 的入站事件只带 wxid（消息对象不含昵称、通讯录是加密 DB），
/// 因此这里让用户给会话起名，避免列表与 AI 提示词里出现裸 ID。
/// 留空保存 = 恢复自动名称（系统账号中文名 / `群聊 · 尾号` / `微信好友 · 尾号`）。
struct ConversationRenameSheet: View {
    let conversation: Conversation
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var name: String

    init(conversation: Conversation, onSave: @escaping (String) -> Void) {
        self.conversation = conversation
        self.onSave = onSave
        _name = State(initialValue: conversation.customTitle ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 460)
        .background(.regularMaterial)
        .onAppear { isNameFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(title: conversation.displayTitle, kind: conversation.kind, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("重命名会话")).font(.headline)
                Text(conversation.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("会话名称"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(save)
            Text(L(hint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("微信接口只下发会话 ID，App 取不到真实昵称；给常用会话起名后，列表、AI 提示词与日志都会使用它。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Spacer()
            Button(L("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("保存")) { save() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 留空（或只输入 ID 形式的占位值）时，保存后使用的自动名称。
    private var automaticName: String {
        ConversationName.displayTitle(kind: conversation.kind, conversationID: conversation.id, storedTitle: "")
    }

    private var hint: String {
        if trimmedName.isEmpty {
            return "留空使用自动名称「\(automaticName)」。"
        }
        if ConversationName.isPlaceholderTitle(
            trimmedName,
            conversationID: conversation.id,
            kind: conversation.kind
        ) {
            return "该名称是 ID 形式，会继续显示自动名称「\(automaticName)」。"
        }
        return "保存后立即生效。"
    }

    private func save() {
        onSave(trimmedName)
        dismiss()
    }
}
