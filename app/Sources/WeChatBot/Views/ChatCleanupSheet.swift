import SwiftUI

/// 具体会话内的聊天记录清理确认：只删本地 `messages`，不碰记忆卡与全量记录。
struct ChatCleanupSheet: View {
    let conversationTitle: String
    let messageCount: Int
    let isBusy: Bool
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 11) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("清理聊天记录")).font(.headline)
                    Text(L("此操作不可撤销")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(L("删除当前会话在本地 SQLite 中保存的聊天记录。微信端消息、记忆卡与全量记录都不受影响。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversationTitle).font(.callout.weight(.medium))
                    Text(Lf("%d 条消息", messageCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            InlineNotice(
                kind: .warning,
                title: "清理前请确认",
                message: "清理后无法恢复，AI 将失去该会话的聊天上下文。建议先在「设置 → 数据」中备份。"
            )

            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isBusy ? "清理中…" : "确认清理") {
                    onClear()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.danger)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
            }
        }
        .padding(22)
        .frame(width: 470)
        .background(.regularMaterial)
    }
}
