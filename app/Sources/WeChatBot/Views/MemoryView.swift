import AppKit
import SwiftUI

private enum MemoryMode: String, CaseIterable, Identifiable {
    case longTerm
    case chat

    var id: String { rawValue }
    var label: String {
        switch self {
        case .longTerm: "长期记忆"
        case .chat: "聊天记录"
        }
    }
}

/// 长期记忆文件夹：全部 / 全局 / 按会话（含已删除会话的兜底文件夹）。
private enum MemoryFolder: Hashable, Identifiable {
    case all
    case global
    case conversation(id: String, title: String, kind: ConversationKind)
    case orphaned(id: String)

    var id: String {
        switch self {
        case .all: "all"
        case .global: "global"
        case .conversation(let id, _, _), .orphaned(let id): "conversation:\(id)"
        }
    }

    var title: String {
        switch self {
        case .all: "全部记忆"
        case .global: "全局记忆"
        case .conversation(_, let title, _): title.isEmpty ? "未命名会话" : title
        case .orphaned(let id): id
        }
    }

    var symbol: String {
        switch self {
        case .all: "brain.head.profile"
        case .global: "globe"
        case .conversation(_, _, let kind): kind.symbol
        case .orphaned: "questionmark.folder"
        }
    }

    /// 新增记忆时的预填会话 ID：全局/全部文件夹为空。
    var conversationID: String {
        switch self {
        case .all, .global: ""
        case .conversation(let id, _, _), .orphaned(let id): id
        }
    }

    /// 无搜索时按文件夹过滤记忆。
    func contains(_ memory: LongTermMemory) -> Bool {
        switch self {
        case .all: true
        case .global: memory.isGlobal
        case .conversation(let id, _, _), .orphaned(let id): memory.conversationID == id
        }
    }
}

/// 侧栏分区：按会话类型（私聊/群聊/公众号）分组，或「未关联会话」兜底。
private struct MemoryFolderSection: Identifiable {
    var id: String
    var title: String
    var folders: [MemoryFolder]
}

/// 记忆库：长期记忆的新增/编辑/核心标记 + 会话/消息浏览与清理。
struct MemoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var mode: MemoryMode = .longTerm
    @State private var search = ""
    @State private var selectedConversationID: String?
    @State private var selectedFolder: MemoryFolder = .all
    @State private var showCleanup = false
    @State private var isClearing = false
    @State private var editingMemory: LongTermMemory?
    @State private var pendingDeletion: LongTermMemory?

    var body: some View {
        VStack(spacing: 0) {
            GlassToolbar(title: "记忆库", subtitle: subtitle) {
                Picker("", selection: $mode) {
                    ForEach(MemoryMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 176)

                SearchField(
                    text: $search,
                    placeholder: mode == .longTerm ? "搜索长期记忆" : "搜索会话或消息内容"
                )
                .frame(width: 230)

                if mode == .longTerm {
                    Button {
                        startNewMemory()
                    } label: {
                        Label("新增记忆", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint("新增一条长期记忆，可标记为核心记忆")
                }

                IconActionButton(symbol: "folder", help: "在 Finder 中显示数据库") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.databaseFile])
                }

                if mode == .chat {
                    Button {
                        showCleanup = true
                    } label: {
                        Label("清理…", systemImage: "trash")
                    }
                    .buttonStyle(.glass)
                    .disabled(totalMessages == 0)
                }
            }

            if mode == .longTerm {
                longTermPane
            } else {
                chatPanes
            }
        }
        .background(PageBackground())
        .onAppear {
            selectFirstIfNeeded()
            Task { await store.loadLongTermMemories() }
        }
        .sheet(isPresented: $showCleanup) {
            MemoryCleanupSheet(
                conversationTitle: selectedConversation?.displayTitle,
                conversationMessages: selectedMessages.count,
                totalMessages: totalMessages,
                isBusy: isClearing
            ) { scope in
                clear(scope)
            }
        }
        .sheet(item: $editingMemory) { memory in
            MemoryEditorSheet(
                original: memory,
                isNew: !store.longTermMemories.contains(where: { $0.id == memory.id }),
                conversations: store.conversations,
                onSave: saveMemory,
                onDelete: deleteMemory
            )
        }
        .confirmationDialog(
            "删除这条长期记忆？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { memory in
            Button("删除", role: .destructive) {
                deleteMemory(memory)
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { memory in
            Text("「\(memory.summary.prefix(40))」删除后无法恢复，但不会影响微信聊天记录。")
        }
    }

    // MARK: Chat browse

    private var chatPanes: some View {
        HStack(spacing: 0) {
            conversationPane
                .frame(width: 300)
                .background(.ultraThinMaterial)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .accessibilityHidden(true)

            messagePane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Long-term memory

    /// 左侧文件夹栏 + 右侧记忆列表（与聊天模式的双栏结构一致）。
    private var longTermPane: some View {
        HStack(spacing: 0) {
            memoryFolderPane
                .frame(width: 250)
                .background(.ultraThinMaterial)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .accessibilityHidden(true)

            memoryListPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Memory folders

    private var memoryFolderPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文件夹")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.longTermMemories.count) 条记忆")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 7)

            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    memoryFolderRow(.all)
                    memoryFolderRow(.global)
                    ForEach(memoryFolderSections) { section in
                        Text(section.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(section.folders) { folder in
                            memoryFolderRow(folder)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }

            Divider().opacity(0.5)

            HStack(spacing: 5) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.violet)
                Text("核心 \(coreMemoryCount) 条")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(folderCount) 个会话文件夹")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private func memoryFolderRow(_ folder: MemoryFolder) -> some View {
        let isSelected = activeFolder.id == folder.id
        let counts = memoryCounts(for: folder)
        return Button {
            selectedFolder = folder
        } label: {
            HStack(spacing: 8) {
                Image(systemName: folder.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                    .frame(width: 18)
                Text(folder.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if counts.core > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill").font(.system(size: 8))
                        Text("\(counts.core)").font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(Theme.violet)
                }
                Text("\(counts.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Theme.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(folder.title) · \(counts.total) 条长期记忆 · 核心 \(counts.core) 条")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Memory list

    private var memoryListPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isSearching ? "magnifyingglass" : activeFolder.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(listTitle)
                    .font(.caption.weight(.semibold))
                Text("\(filteredMemories.count) 条")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if isSearching {
                    PillLabel(text: "跨全部记忆", color: Theme.info)
                }
                let coreCount = filteredMemories.filter(\.isCore).count
                if coreCount > 0 {
                    PillLabel(text: "★ 核心 \(coreCount)", color: Theme.violet)
                }
                Spacer(minLength: 8)
                Text("权重 = 基础 × 重要度(合并条数对数) × 使用(召回≤+40%) × 30 天半衰期")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thinMaterial)

            Divider().opacity(0.5)

            if filteredMemories.isEmpty {
                VStack(spacing: 12) {
                    EmptyState(
                        symbol: "brain.head.profile",
                        title: emptyTitle,
                        message: emptyMessage
                    )
                    if !isSearching {
                        Button {
                            startNewMemory()
                        } label: {
                            Label(emptyActionTitle, systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredMemories) { memory in
                            LongTermMemoryCard(
                                memory: memory,
                                onEdit: { editMemory(memory) },
                                onToggleCore: {
                                    Task {
                                        await store.setLongTermMemoryCore(memory, isCore: !memory.isCore)
                                        toast.show(memory.isCore ? "已取消核心记忆" : "已设为核心记忆",
                                                   tone: .success,
                                                   symbol: memory.isCore ? "star.slash" : "star.fill")
                                    }
                                },
                                onDelete: { pendingDeletion = memory }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Memory folder derivation

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isAllFolder: Bool {
        if case .all = activeFolder { return true }
        return false
    }

    /// 选中的文件夹若已没有记忆（例如删掉最后一条），回退到「全部」。
    private var activeFolder: MemoryFolder {
        folderExists(selectedFolder) ? selectedFolder : .all
    }

    private func folderExists(_ folder: MemoryFolder) -> Bool {
        switch folder {
        case .all, .global: return true
        case .conversation(let id, _, _), .orphaned(let id):
            return store.longTermMemories.contains { $0.conversationID == id }
        }
    }

    /// 全部/全局之外，按会话类型分组的会话文件夹（只显示有记忆的会话）。
    private var memoryFolderSections: [MemoryFolderSection] {
        let conversationIDs = Set(store.longTermMemories.map(\.conversationID).filter { !$0.isEmpty })
        guard !conversationIDs.isEmpty else { return [] }
        let known = Dictionary(
            store.conversations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var sections: [MemoryFolderSection] = []
        var claimed = Set<String>()
        for kind in [ConversationKind.direct, .group, .official] {
            let folders = conversationIDs
                .filter { id in known[id]?.kind == kind }
                .compactMap { id -> MemoryFolder? in
                    guard let conversation = known[id] else { return nil }
                    return .conversation(id: id, title: conversation.displayTitle, kind: kind)
                }
                .sorted { lhs, rhs in
                    let left = memoryCounts(for: lhs).total
                    let right = memoryCounts(for: rhs).total
                    if left != right { return left > right }
                    return lhs.title.localizedCompare(rhs.title) == .orderedAscending
                }
            guard !folders.isEmpty else { continue }
            for folder in folders { claimed.insert(folder.conversationID) }
            sections.append(MemoryFolderSection(id: kind.rawValue, title: kind.label, folders: folders))
        }

        let orphanedIDs = conversationIDs.subtracting(claimed).sorted()
        if !orphanedIDs.isEmpty {
            sections.append(MemoryFolderSection(
                id: "orphaned",
                title: "未关联会话",
                folders: orphanedIDs.map { MemoryFolder.orphaned(id: $0) }
            ))
        }
        return sections
    }

    private var folderCount: Int {
        memoryFolderSections.reduce(0) { $0 + $1.folders.count }
    }

    private var coreMemoryCount: Int {
        store.longTermMemories.filter(\.isCore).count
    }

    private func memoryCounts(for folder: MemoryFolder) -> (total: Int, core: Int) {
        let matches: [LongTermMemory]
        switch folder {
        case .all: matches = store.longTermMemories
        case .global: matches = store.longTermMemories.filter(\.isGlobal)
        case .conversation(let id, _, _), .orphaned(let id):
            matches = store.longTermMemories.filter { $0.conversationID == id }
        }
        return (matches.count, matches.filter(\.isCore).count)
    }

    private var listTitle: String {
        isSearching ? "搜索结果" : activeFolder.title
    }

    private var emptyTitle: String {
        if isSearching { return "没有匹配的长期记忆" }
        return isAllFolder ? "还没有长期记忆" : "此文件夹暂无长期记忆"
    }

    private var emptyMessage: String {
        if isSearching {
            return "尝试其他关键词；搜索会跨全部记忆匹配摘要、会话标题与 ID。"
        }
        if isAllFolder {
            return "短期窗口外攒够 \(ChatEngine.overflowBatchThreshold) 条旧消息后会自动批量总结；也可以手动新增核心记忆。"
        }
        return "新增的记忆默认归入当前文件夹，也可以在编辑器中改到其它会话。"
    }

    private var emptyActionTitle: String {
        isAllFolder ? "新增第一条长期记忆" : "新增记忆"
    }

    private var filteredMemories: [LongTermMemory] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let list: [LongTermMemory]
        if keyword.isEmpty {
            list = store.longTermMemories.filter { activeFolder.contains($0) }
        } else {
            list = store.longTermMemories.filter {
                $0.summary.localizedCaseInsensitiveContains(keyword)
                    || $0.conversationTitle.localizedCaseInsensitiveContains(keyword)
                    || $0.conversationID.localizedCaseInsensitiveContains(keyword)
            }
        }
        return list.sorted {
            if $0.isCore != $1.isCore { return $0.isCore && !$1.isCore }
            let left = $0.timeWeight(), right = $1.timeWeight()
            if abs(left - right) > 0.000001 { return left > right }
            return $0.updatedAt > $1.updatedAt
        }
    }

    /// 新增记忆时若选中会话文件夹则预填 conversationID；全局/全部文件夹预填空。
    private func startNewMemory() {
        let prefill: String
        switch activeFolder {
        case .all, .global: prefill = ""
        case .conversation, .orphaned: prefill = activeFolder.conversationID
        }
        editingMemory = LongTermMemory(conversationID: prefill, summary: "")
    }

    private func editMemory(_ memory: LongTermMemory) {
        editingMemory = memory
    }

    private func saveMemory(_ memory: LongTermMemory) {
        Task {
            await store.saveLongTermMemory(memory)
            toast.show("长期记忆已保存", tone: .success, symbol: "checkmark.circle.fill")
        }
    }

    private func deleteMemory(_ memory: LongTermMemory) {
        Task {
            await store.deleteLongTermMemory(id: memory.id)
            toast.show("已删除长期记忆", tone: .info, symbol: "trash")
        }
    }

    // MARK: Conversation pane

    private var conversationPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.conversations.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 7)

            Divider().opacity(0.5)

            if filteredConversations.isEmpty {
                EmptyState(
                    symbol: "brain",
                    title: "记忆库为空",
                    message: search.isEmpty
                        ? "收到和发送的消息会写入本地 SQLite，可在这里浏览。"
                        : "没有匹配的会话或消息。"
                )
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredConversations) { conversation in
                            memoryConversationRow(conversation)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }

            Divider().opacity(0.5)
            HStack(spacing: 5) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("\(totalMessages) 条消息")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: AppPaths.databaseFile.path, accessibilityText: "复制数据库路径")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private func memoryConversationRow(_ conversation: Conversation) -> some View {
        let isSelected = selectedConversationID == conversation.id
        let count = (store.messages[conversation.id] ?? []).count
        return Button {
            selectedConversationID = conversation.id
        } label: {
            HStack(spacing: 8) {
                AvatarView(title: conversation.displayTitle, kind: conversation.kind, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.displayTitle)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text("\(count) 条 · \(conversation.kind.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let date = conversation.lastMessageAt {
                    Text(UIFormat.relativeShort(date))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Theme.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Message pane

    private var messagePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !search.isEmpty {
                    Label("搜索结果", systemImage: "magnifyingglass")
                        .font(.caption.weight(.medium))
                    Text("\(searchResults.count) 条匹配")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let conversation = selectedConversation {
                    AvatarView(title: conversation.displayTitle, kind: conversation.kind, size: 22)
                    Text(conversation.displayTitle)
                        .font(.caption.weight(.semibold))
                    Text("\(selectedMessages.count) 条消息")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("消息")
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                Text(UIFormat.compactPath(AppPaths.databaseFile.path))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thinMaterial)

            Divider().opacity(0.5)

            if search.isEmpty {
                if selectedConversation != nil {
                    if selectedMessages.isEmpty {
                        EmptyState(
                            symbol: "text.bubble",
                            title: "此会话暂无记录",
                            message: "新的消息会自动写入记忆库。"
                        )
                    } else {
                        messageList(selectedMessages, showConversation: false)
                    }
                } else {
                    EmptyState(
                        symbol: "brain",
                        title: "选择左侧会话",
                        message: "浏览本地保存的聊天记录。"
                    )
                }
            } else {
                if searchResults.isEmpty {
                    EmptyState(
                        symbol: "magnifyingglass",
                        title: "没有匹配的消息",
                        message: "尝试其他关键词，搜索会匹配消息文本与会话标题。"
                    )
                } else {
                    messageList(searchResults, showConversation: true)
                }
            }
        }
    }

    private func messageList(_ messages: [ChatMessage], showConversation: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(messages) { message in
                    MemoryMessageRow(
                        message: message,
                        conversationTitle: showConversation ? conversationTitle(for: message.conversationID) : nil
                    )
                    Divider().opacity(0.35)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Derived

    private var subtitle: String {
        if mode == .longTerm {
            let core = store.longTermMemories.filter(\.isCore).count
            return "\(store.longTermMemories.count) 条长期记忆 · 核心 \(core)"
                + " · 短期窗口 \(ChatEngine.shortTermMemoryLimit) 条"
                + " · 每 \(ChatEngine.overflowBatchThreshold) 条批量总结 · 本地 SQLite"
        }
        let conversationCount = store.conversations.count
        return "\(conversationCount) 个会话 · \(totalMessages) 条消息 · 本地 SQLite"
    }

    private var totalMessages: Int {
        store.messages.values.reduce(0) { $0 + $1.count }
    }

    private var searchedMessages: [ChatMessage] {
        store.messages.values.flatMap { $0 }
    }

    private var searchResults: [ChatMessage] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        return searchedMessages
            .filter {
                $0.text.localizedCaseInsensitiveContains(keyword)
                    || $0.senderName.localizedCaseInsensitiveContains(keyword)
                    || (conversationTitle(for: $0.conversationID).localizedCaseInsensitiveContains(keyword))
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var filteredConversations: [Conversation] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = store.conversations
        if !keyword.isEmpty {
            let matchedIDs = Set(searchResults.map(\.conversationID))
            list = list.filter {
                matchedIDs.contains($0.id)
                    || $0.displayTitle.localizedCaseInsensitiveContains(keyword)
                    || $0.id.localizedCaseInsensitiveContains(keyword)
            }
        }
        return list.sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    }

    private var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return store.conversations.first(where: { $0.id == selectedConversationID })
    }

    private var selectedMessages: [ChatMessage] {
        guard let selectedConversationID else { return [] }
        return (store.messages[selectedConversationID] ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    private func conversationTitle(for id: String) -> String {
        store.conversations.first(where: { $0.id == id })?.displayTitle ?? id
    }

    private func selectFirstIfNeeded() {
        if selectedConversationID == nil
            || !store.conversations.contains(where: { $0.id == selectedConversationID }) {
            selectedConversationID = store.conversations.first?.id
        }
    }

    // MARK: Cleanup

    private func clear(_ scope: MemoryClearScope) {
        isClearing = true
        Task {
            if scope == .current, let conversationID = selectedConversationID {
                await store.clearMessages(conversationID: conversationID)
                toast.show("已清理当前会话记忆", tone: .success, symbol: "trash")
            } else {
                await store.clearMessages(conversationID: nil)
                toast.show("已清空记忆库", tone: .success, symbol: "trash")
            }
            isClearing = false
            showCleanup = false
        }
    }
}

// MARK: - Long-term memory card

private struct LongTermMemoryCard: View {
    let memory: LongTermMemory
    let onEdit: () -> Void
    let onToggleCore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggleCore) {
                Image(systemName: memory.isCore ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(memory.isCore ? Theme.violet : Color.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(memory.isCore ? "取消核心记忆" : "设为核心记忆")
            .accessibilityLabel(memory.isCore ? "取消核心记忆" : "设为核心记忆")

            VStack(alignment: .leading, spacing: 7) {
                Text(memory.summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    PillLabel(
                        text: memory.isGlobal ? "全局" : (memory.conversationTitle.isEmpty ? memory.conversationID : memory.conversationTitle),
                        color: memory.isGlobal ? Theme.info : Theme.accent
                    )
                    if memory.isCore {
                        PillLabel(text: "★ 核心", color: Theme.violet)
                    }
                    PillLabel(text: "权重 \(memory.weightLabel)", color: Theme.success)
                    Spacer(minLength: 4)
                    Text(activitySummary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Menu {
                Button("编辑…", systemImage: "pencil", action: onEdit)
                Button(memory.isCore ? "取消核心记忆" : "设为核心记忆",
                       systemImage: memory.isCore ? "star.slash" : "star",
                       action: onToggleCore)
                Divider()
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityLabel("长期记忆操作")
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(memory.isCore ? Theme.violet.opacity(0.28) : Color.primary.opacity(0.05), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .contain)
    }

    /// 合并条数/召回次数与更新时间合并成一行，避免卡片徽标过多挤压布局。
    private var activitySummary: String {
        var parts = ["更新 \(UIFormat.relativeShort(memory.updatedAt))"]
        if memory.sourceCount > 0 { parts.append("合并 \(memory.sourceCount) 条") }
        if memory.accessCount > 0 { parts.append("召回 \(memory.accessCount) 次") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Long-term memory editor

private struct MemoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let original: LongTermMemory
    let isNew: Bool
    let conversations: [Conversation]
    let onSave: (LongTermMemory) -> Void
    let onDelete: (LongTermMemory) -> Void

    @State private var summary: String
    @State private var conversationID: String
    @State private var isCore: Bool
    @State private var confirmDelete = false

    init(
        original: LongTermMemory,
        isNew: Bool,
        conversations: [Conversation],
        onSave: @escaping (LongTermMemory) -> Void,
        onDelete: @escaping (LongTermMemory) -> Void
    ) {
        self.original = original
        self.isNew = isNew
        self.conversations = conversations
        self.onSave = onSave
        self.onDelete = onDelete
        _summary = State(initialValue: original.summary)
        _conversationID = State(initialValue: original.conversationID)
        _isCore = State(initialValue: original.isCore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 11) {
                Image(systemName: isCore ? "star.fill" : "brain.head.profile")
                    .font(.system(size: 22))
                    .foregroundStyle(isCore ? Theme.violet : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "新增长期记忆" : "编辑长期记忆").font(.headline)
                    Text("核心记忆始终加入上下文；普通记忆按综合权重参与召回")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("记忆内容").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $summary)
                    .font(.body)
                    .frame(minHeight: 150, maxHeight: 220)
                    .padding(6)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                Text("例如：对方叫小林，喜欢猫；我们约好周五晚上讨论旅行计划。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("关联会话").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("关联会话", selection: $conversationID) {
                        Text("全局记忆（所有会话）").tag("")
                        ForEach(conversations) { conversation in
                            Text(conversation.displayTitle).tag(conversation.id)
                        }
                        if !conversationID.isEmpty,
                           !conversations.contains(where: { $0.id == conversationID }) {
                            Text(conversationID).tag(conversationID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 200, alignment: .leading)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Toggle("核心记忆", isOn: $isCore)
                        .toggleStyle(.switch)
                        .tint(Theme.violet)
                    Text("核心记忆始终加入上下文，不受权重淘汰")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            InlineNotice(
                kind: .info,
                title: "综合权重",
                message: "权重 = 基础权重 × 重要度(1 + 0.12 × log2(1 + 合并条数))"
                    + " × 使用强化(1 + 0.02 × 召回次数，最多 +40%)"
                    + " × 0.5^(距最近更新/召回天数 / 30)。编辑或更新后权重会升高；越近、越常用的长期记忆优先级越高。"
            )

            HStack {
                if !isNew {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        confirmDelete = true
                    }
                    .buttonStyle(.glass)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(.regularMaterial)
        .confirmationDialog("删除这条长期记忆？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                onDelete(original)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，但不会影响微信聊天记录。")
        }
    }

    private func save() {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = original
        updated.summary = trimmed
        updated.conversationID = conversationID
        updated.conversationTitle = conversations.first(where: { $0.id == conversationID })?.displayTitle
            ?? (conversationID.isEmpty ? "" : conversationID)
        updated.isCore = isCore
        updated.updatedAt = Date()
        // 用户编辑后转为手动记忆，避免后续自动总结覆盖手写内容。
        updated.source = "manual"
        onSave(updated)
        dismiss()
    }
}

// MARK: - Cleanup sheet

enum MemoryClearScope {
    case current
    case all
}

private struct MemoryCleanupSheet: View {
    let conversationTitle: String?
    let conversationMessages: Int
    let totalMessages: Int
    let isBusy: Bool
    let onClear: (MemoryClearScope) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scope: MemoryClearScope = .current
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 11) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("清理记忆库").font(.headline)
                    Text("此操作不可撤销").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("删除本地 SQLite 中保存的聊天记录。微信端的消息不会受影响。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                if let conversationTitle {
                    scopeRow(
                        scope: .current,
                        title: "仅清理当前会话",
                        detail: "\(conversationTitle) · \(conversationMessages) 条消息"
                    )
                }
                scopeRow(
                    scope: .all,
                    title: "清空全部记忆",
                    detail: "\(totalMessages) 条消息，所有会话"
                )
            }
            .padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            InlineNotice(
                kind: .warning,
                title: "清理前请确认",
                message: "清理后无法恢复，AI 也将失去这段上下文。建议先在「设置 → 数据」中备份。"
            )

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isBusy ? "清理中…" : "确认清理") {
                    onClear(scope)
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
        .onAppear {
            if conversationTitle == nil { scope = .all }
        }
    }

    private func scopeRow(scope target: MemoryClearScope, title: String, detail: String) -> some View {
        Button {
            scope = target
        } label: {
            HStack(spacing: 8) {
                Image(systemName: scope == target ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(scope == target ? Theme.danger : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout)
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scope == target ? [.isSelected] : [])
    }
}

// MARK: - Message row

private struct MemoryMessageRow: View {
    let message: ChatMessage
    var conversationTitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(title: message.displaySender, kind: .direct, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.displaySender)
                        .font(.caption.weight(.medium))
                    if message.isOutgoing {
                        PillLabel(text: "我", color: Theme.accent)
                    }
                    if let conversationTitle {
                        PillLabel(text: conversationTitle, color: Theme.info)
                    }
                    Spacer(minLength: 4)
                    Text(UIFormat.stamp(message.timestamp))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(displayText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var displayText: String {
        if !message.text.isEmpty { return message.text }
        switch message.kind {
        case .image: return "[图片]"
        case .voice: return "[语音]"
        case .emoji: return "[表情]"
        case .file: return "[文件]"
        case .video: return "[视频]"
        case .link: return "[链接]"
        case .system: return "[系统消息]"
        case .text: return "[空消息]"
        }
    }
}
