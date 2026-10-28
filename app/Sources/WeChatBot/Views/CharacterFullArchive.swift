import SwiftUI

/// 全量互动记录 sheet：`characters/<key>/memory.sqlite` 的 `interactions` 表。
///
/// 全量记录不参与衰减、不被压缩，清理聊天记录也不会删除；只有删除记忆卡/会话
/// 才会移除（docs/memory.md §4.2、§10.1）。
struct CharacterFullArchive: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let conversationID: String
    let title: String

    @State private var search = ""
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 720, height: 620)
        .background(.regularMaterial)
        .task(id: search) {
            await load()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "archivebox")
                .font(.system(size: 22))
                .foregroundStyle(Theme.info)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("全量记录")).font(.headline)
                Text(title.isEmpty ? conversationID : title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(Lf("%d 条互动", store.characterInteractions.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            SearchField(text: $search, placeholder: "搜索全量记录")
                .frame(maxWidth: 320)
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Text(L("永久保存 · 不受清理聊天记录影响"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading && store.characterInteractions.isEmpty {
            LoadingState(title: "读取全量记录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.characterInteractions.isEmpty {
            EmptyState(
                symbol: search.isEmpty ? "archivebox" : "magnifyingglass",
                title: search.isEmpty ? "还没有全量记录" : "没有匹配的记录",
                message: search.isEmpty
                    ? "机器人为该会话生成第一次回复后回填最多 5000 条历史消息，之后按游标增量同步。"
                    : "尝试其它关键词；搜索只匹配互动正文。"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.characterInteractions) { interaction in
                        interactionRow(interaction)
                        Divider().opacity(0.3)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func interactionRow(_ interaction: CharacterInteraction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(UIFormat.dateTime.string(from: interaction.timestamp))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .leading)
                .padding(.top, 2)
            Text(speaker(interaction))
                .font(.caption2.weight(.medium))
                .foregroundStyle(interaction.direction == .outgoing ? Theme.accent : Theme.info)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    (interaction.direction == .outgoing ? Theme.accent : Theme.info).opacity(0.12),
                    in: Capsule()
                )
            Text(interaction.content)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func speaker(_ interaction: CharacterInteraction) -> String {
        if interaction.direction == .outgoing { return L("我") }
        let name = interaction.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != "self", name != "system" { return name }
        return interaction.senderID.isEmpty ? L("对方") : interaction.senderID
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Label(L("全量记录永久保存，不随聊天记录清理删除"), systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button(L("关闭")) { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    // MARK: Actions

    private func load() async {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
        }
        isLoading = true
        await store.loadCharacterInteractions(
            conversationID: conversationID,
            search: keyword.isEmpty ? nil : keyword
        )
        isLoading = false
    }
}
