import AppKit
import SwiftUI

private enum MemoryMode: String, CaseIterable, Identifiable {
    case longTerm
    case chat

    var id: String { rawValue }
    var label: String {
        switch self {
        case .longTerm: L("长期记忆")
        case .chat: L("聊天记录")
        }
    }
}

/// 长期记忆文件夹：全部 / 全局 / 按会话（含已删除会话的兜底文件夹）。
private enum MemoryFolder: Hashable, Identifiable {
    case all
    case global
    case conversation(id: String, title: String, kind: ConversationKind)
    case orphaned(id: String)

    /// 会话文件夹的稳定 id；派生快照用同一规则建索引，避免字面量漂移。
    static func conversationFolderID(_ conversationID: String) -> String {
        "conversation:\(conversationID)"
    }

    var id: String {
        switch self {
        case .all: "all"
        case .global: "global"
        case .conversation(let id, _, _), .orphaned(let id): Self.conversationFolderID(id)
        }
    }

    var title: String {
        switch self {
        case .all: L("全部记忆")
        case .global: L("全局记忆")
        case .conversation(_, let title, _): title.isEmpty ? L("未命名会话") : title
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

/// 长期记忆列表排序：默认「综合权重」（核心优先），或「最近更新」（不强制核心前置）。
private enum MemorySortMode: String, CaseIterable, Identifiable {
    case weight
    case recentlyUpdated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weight: L("综合权重")
        case .recentlyUpdated: L("最近更新")
        }
    }

    var symbol: String {
        switch self {
        case .weight: "scalemass"
        case .recentlyUpdated: "clock.arrow.circlepath"
        }
    }
}

/// 文件夹计数（总数 / 核心数），随长期记忆遍历一次算出。
private struct MemoryCounts: Equatable {
    var total = 0
    var core = 0
}

/// 长期记忆页的派生数据：一次遍历 + 一次排序，body 内只构建一次。
private struct LongTermSnapshot {
    let activeFolder: MemoryFolder
    let isSearching: Bool
    /// 已按当前文件夹/搜索/仅核心/排序模式处理好的列表。
    let memories: [LongTermMemory]
    let filteredCoreCount: Int
    let totalMemoryCount: Int
    let coreMemoryCount: Int
    let folderSections: [MemoryFolderSection]
    let folderSessionCount: Int
    let folderCounts: [String: MemoryCounts]
}

/// 聊天记录页的派生数据：会话标题表、消息计数与搜索结果都只构建一次。
private struct ChatSnapshot {
    let conversationCount: Int
    let totalMessages: Int
    let messageCounts: [String: Int]
    let searchResults: [ChatMessage]
    let filteredConversations: [Conversation]
    let selectedMessages: [ChatMessage]
    let conversationTitles: [String: String]
}

/// 记忆库：长期记忆的新增/编辑/核心标记 + 会话/消息浏览与清理。
struct MemoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var mode: MemoryMode = .longTerm
    @State private var search = ""
    @State private var selectedConversationID: String?
    @State private var selectedFolder: MemoryFolder = .all
    @State private var sortMode: MemorySortMode = .weight
    @State private var onlyCore = false
    @State private var showWeightInfo = false
    @State private var showCleanup = false
    @State private var isClearing = false
    @State private var editingMemory: LongTermMemory?
    @State private var pendingDeletion: LongTermMemory?

    var body: some View {
        // Derived collections are built exactly once per body evaluation (the old code
        // re-filtered/re-sorted memories and messages 3-4 times per body, and did
        // O(folders x memories) count lookups while rendering folder rows).
        let longTerm = mode == .longTerm ? makeLongTermSnapshot() : nil
        let chat = mode == .chat ? makeChatSnapshot() : nil

        VStack(spacing: 0) {
            GlassToolbar(title: "记忆库", subtitle: subtitle(longTerm: longTerm, chat: chat)) {
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
                        Label(L("新增记忆"), systemImage: "plus")
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
                        Label(L("清理…"), systemImage: "trash")
                    }
                    .buttonStyle(.glass)
                    .disabled((chat?.totalMessages ?? 0) == 0)
                }
            }

            if let longTerm {
                longTermPane(longTerm)
            } else if let chat {
                chatPanes(chat)
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
            Button(L("删除"), role: .destructive) {
                deleteMemory(memory)
                pendingDeletion = nil
            }
            Button(L("取消"), role: .cancel) { pendingDeletion = nil }
        } message: { memory in
            Text(L("「\(memory.summary.prefix(40))」删除后无法恢复，但不会影响微信聊天记录。"))
        }
    }

    // MARK: Chat browse

    private func chatPanes(_ chat: ChatSnapshot) -> some View {
        HStack(spacing: 0) {
            conversationPane(chat)
                .frame(width: 300)
                .background(.ultraThinMaterial)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .accessibilityHidden(true)

            messagePane(chat)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Long-term memory

    /// 左侧文件夹栏 + 右侧记忆列表（与聊天模式的双栏结构一致）。
    private func longTermPane(_ snapshot: LongTermSnapshot) -> some View {
        HStack(spacing: 0) {
            memoryFolderPane(snapshot)
                .frame(width: 250)
                .background(.ultraThinMaterial)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .accessibilityHidden(true)

            memoryListPane(snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Memory folders

    private func memoryFolderPane(_ snapshot: LongTermSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("文件夹"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("\(snapshot.totalMemoryCount) 条记忆"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 7)

            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    memoryFolderRow(
                        .all,
                        counts: snapshot.folderCounts[MemoryFolder.all.id] ?? MemoryCounts(),
                        isSelected: snapshot.activeFolder.id == MemoryFolder.all.id
                    )
                    memoryFolderRow(
                        .global,
                        counts: snapshot.folderCounts[MemoryFolder.global.id] ?? MemoryCounts(),
                        isSelected: snapshot.activeFolder.id == MemoryFolder.global.id
                    )
                    ForEach(snapshot.folderSections) { section in
                        Text(L(section.title))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(section.folders) { folder in
                            memoryFolderRow(
                                folder,
                                counts: snapshot.folderCounts[folder.id] ?? MemoryCounts(),
                                isSelected: snapshot.activeFolder.id == folder.id
                            )
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
                Text(L("核心 \(snapshot.coreMemoryCount) 条"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("\(snapshot.folderSessionCount) 个会话文件夹"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private func memoryFolderRow(
        _ folder: MemoryFolder,
        counts: MemoryCounts,
        isSelected: Bool
    ) -> some View {
        Button {
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
        .help(L("\(folder.title) · \(counts.total) 条长期记忆 · 核心 \(counts.core) 条"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Memory list

    private func memoryListPane(_ snapshot: LongTermSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: snapshot.isSearching ? "magnifyingglass" : snapshot.activeFolder.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(listTitle(snapshot))
                    .font(.caption.weight(.semibold))
                Text(L("\(snapshot.memories.count) 条"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if snapshot.isSearching {
                    PillLabel(text: "跨全部记忆", color: Theme.info)
                }
                if snapshot.filteredCoreCount > 0 {
                    PillLabel(text: "★ 核心 \(snapshot.filteredCoreCount)", color: Theme.violet)
                }
                Spacer(minLength: 8)
                FilterChip(
                    title: "仅核心",
                    symbol: "star.fill",
                    isSelected: onlyCore,
                    tint: Theme.violet
                ) {
                    onlyCore.toggle()
                }
                .help(onlyCore ? "显示全部记忆" : "只显示核心记忆")
                memorySortMenu
                memoryWeightInfoButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thinMaterial)

            Divider().opacity(0.5)

            if snapshot.memories.isEmpty {
                VStack(spacing: 12) {
                    EmptyState(
                        symbol: "brain.head.profile",
                        title: emptyTitle(snapshot),
                        message: emptyMessage(snapshot)
                    )
                    if !snapshot.isSearching {
                        Button {
                            if onlyCore {
                                onlyCore = false
                            } else {
                                startNewMemory()
                            }
                        } label: {
                            Label(
                                onlyCore ? "显示全部记忆" : emptyActionTitle(snapshot),
                                systemImage: onlyCore ? "line.3.horizontal.decrease.circle" : "plus"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(snapshot.memories) { memory in
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

    /// 排序菜单：菜单里直接列出两种模式，标签只显示当前模式，避免挤压顶栏。
    private var memorySortMenu: some View {
        Menu {
            Section(L("排序方式")) {
                ForEach(MemorySortMode.allCases) { mode in
                    Button {
                        sortMode = mode
                    } label: {
                        Label(
                            mode.label,
                            systemImage: sortMode == mode ? "checkmark" : mode.symbol
                        )
                    }
                }
            }
        } label: {
            Label(sortMode.label, systemImage: sortMode.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("排序方式：综合权重（核心优先）/ 最近更新"))
        .accessibilityLabel(L("排序方式：\(sortMode.label)"))
    }

    /// 顶栏只保留「权重」短标签；公式放进 help 与点击弹出的 popover。
    private var memoryWeightInfoButton: some View {
        Button {
            showWeightInfo.toggle()
        } label: {
            Label(L("权重"), systemImage: "info.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("综合权重公式：点击查看说明"))
        .accessibilityLabel(L("综合权重公式说明"))
        .popover(isPresented: $showWeightInfo, arrowEdge: .bottom) {
            weightInfoPopover
        }
    }

    private var weightInfoPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("综合权重"), systemImage: "scalemass")
                .font(.headline)
            Text(Lf("权重越高越优先进入提示词；核心记忆优先占用注入名额（最多 %d 条），核心之间也按权重排序。基础权重可在记忆编辑器中自由调整（0.1~10×）。", ChatEngine.longTermMemoryLimit))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(weightFormula)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("编辑、合并或召回都会抬高权重；基础权重可手工调整并参与排序；越近、越常用的记忆优先级越高。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 350, alignment: .leading)
    }

    /// 公式引用模型里的系数常量，避免界面说明与实现漂移。
    private var weightFormula: String {
        let importanceGrowth = String(format: "%.2f", LongTermMemory.importanceGrowth)
        let usageGrowth = String(format: "%.2f", LongTermMemory.usageGrowth)
        let halfLifeDays = Int(LongTermMemory.halfLifeDays)
        return """
        权重 = 基础权重 × 重要度 × 使用强化 × 时间衰减
        重要度 = 1 + \(importanceGrowth) × log₂(1 + 合并条数)
        使用强化 = 1 + \(usageGrowth) × min(召回次数, \(LongTermMemory.usageCap))
        时间衰减 = 0.5^(距最近更新或召回天数 / \(halfLifeDays))
        """
    }

    // MARK: Memory folder derivation

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

    private func conversationPane(_ chat: ChatSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("会话"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(chat.conversationCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 7)

            Divider().opacity(0.5)

            if chat.filteredConversations.isEmpty {
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
                        ForEach(chat.filteredConversations) { conversation in
                            memoryConversationRow(
                                conversation,
                                count: chat.messageCounts[conversation.id] ?? 0
                            )
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
                Text(L("\(chat.totalMessages) 条消息"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: AppPaths.databaseFile.path, accessibilityText: "复制数据库路径")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private func memoryConversationRow(_ conversation: Conversation, count: Int) -> some View {
        let isSelected = selectedConversationID == conversation.id
        return Button {
            selectedConversationID = conversation.id
        } label: {
            HStack(spacing: 8) {
                AvatarView(title: conversation.displayTitle, kind: conversation.kind, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.displayTitle)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(L("\(count) 条 · \(conversation.kind.label)"))
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

    private func messagePane(_ chat: ChatSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !search.isEmpty {
                    Label(L("搜索结果"), systemImage: "magnifyingglass")
                        .font(.caption.weight(.medium))
                    Text(L("\(chat.searchResults.count) 条匹配"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let conversation = selectedConversation {
                    AvatarView(title: conversation.displayTitle, kind: conversation.kind, size: 22)
                    Text(conversation.displayTitle)
                        .font(.caption.weight(.semibold))
                    Text(L("\(chat.selectedMessages.count) 条消息"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("消息"))
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
                    if chat.selectedMessages.isEmpty {
                        EmptyState(
                            symbol: "text.bubble",
                            title: "此会话暂无记录",
                            message: "新的消息会自动写入记忆库。"
                        )
                    } else {
                        messageList(chat.selectedMessages, showConversation: false, titles: chat.conversationTitles)
                    }
                } else {
                    EmptyState(
                        symbol: "brain",
                        title: "选择左侧会话",
                        message: "浏览本地保存的聊天记录。"
                    )
                }
            } else {
                if chat.searchResults.isEmpty {
                    EmptyState(
                        symbol: "magnifyingglass",
                        title: "没有匹配的消息",
                        message: "尝试其他关键词，搜索会匹配消息文本与会话标题。"
                    )
                } else {
                    messageList(chat.searchResults, showConversation: true, titles: chat.conversationTitles)
                }
            }
        }
    }

    private func messageList(
        _ messages: [ChatMessage],
        showConversation: Bool,
        titles: [String: String]
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(messages) { message in
                    MemoryMessageRow(
                        message: message,
                        conversationTitle: showConversation
                            ? (titles[message.conversationID] ?? message.conversationID)
                            : nil
                    )
                    .equatable()
                    Divider().opacity(0.35)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Snapshot derivation

    /// 长期记忆页的一次性派生数据。旧实现里 `filteredMemories` 每次 body 至少求值
    /// 3-4 次，`memoryFolderSections`/`memoryCounts(for:)` 还会对每个文件夹、每次
    /// 排序比较都重新遍历全部记忆（O(文件夹 × 记忆数)）；这里统一为一次遍历 + 一次排序。
    private func makeLongTermSnapshot() -> LongTermSnapshot {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !keyword.isEmpty
        let allMemories = store.longTermMemories

        var allCounts = MemoryCounts()
        var globalCounts = MemoryCounts()
        var perConversation: [String: MemoryCounts] = [:]
        var existingConversationIDs = Set<String>()
        for memory in allMemories {
            allCounts.total += 1
            if memory.isCore { allCounts.core += 1 }
            if memory.isGlobal {
                globalCounts.total += 1
                if memory.isCore { globalCounts.core += 1 }
            }
            let conversationID = memory.conversationID
            guard !conversationID.isEmpty else { continue }
            existingConversationIDs.insert(conversationID)
            var counts = perConversation[conversationID] ?? MemoryCounts()
            counts.total += 1
            if memory.isCore { counts.core += 1 }
            perConversation[conversationID] = counts
        }

        var folderCounts: [String: MemoryCounts] = [:]
        folderCounts[MemoryFolder.all.id] = allCounts
        folderCounts[MemoryFolder.global.id] = globalCounts
        for (conversationID, counts) in perConversation {
            folderCounts[MemoryFolder.conversationFolderID(conversationID)] = counts
        }

        let activeFolder: MemoryFolder = folderStillExists(selectedFolder, ids: existingConversationIDs)
            ? selectedFolder
            : .all

        var filtered: [LongTermMemory]
        if isSearching {
            filtered = allMemories.filter {
                $0.summary.localizedCaseInsensitiveContains(keyword)
                    || $0.conversationTitle.localizedCaseInsensitiveContains(keyword)
                    || $0.conversationID.localizedCaseInsensitiveContains(keyword)
            }
        } else {
            filtered = allMemories.filter { activeFolder.contains($0) }
        }
        if onlyCore {
            filtered = filtered.filter(\.isCore)
        }
        let filteredCoreCount = filtered.reduce(0) { $0 + ($1.isCore ? 1 : 0) }

        // 排序键只计算一次（timeWeight 涉及 log/exp/日期运算）。旧实现让排序闭包
        // 对每次比较都调用 timeWeight()，是记忆较多时 body 变慢的主要原因之一。
        let weighted = filtered.map { (memory: $0, weight: $0.timeWeight()) }
        let sorted: [LongTermMemory]
        switch sortMode {
        case .weight:
            sorted = weighted.sorted { lhs, rhs in
                if lhs.memory.isCore != rhs.memory.isCore { return lhs.memory.isCore && !rhs.memory.isCore }
                if abs(lhs.weight - rhs.weight) > 0.000001 { return lhs.weight > rhs.weight }
                return lhs.memory.updatedAt > rhs.memory.updatedAt
            }.map { $0.memory }
        case .recentlyUpdated:
            sorted = weighted.sorted { lhs, rhs in
                if lhs.memory.updatedAt != rhs.memory.updatedAt {
                    return lhs.memory.updatedAt > rhs.memory.updatedAt
                }
                return lhs.weight > rhs.weight
            }.map { $0.memory }
        }

        let known = Dictionary(
            store.conversations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var sections: [MemoryFolderSection] = []
        var claimed = Set<String>()
        for kind in [ConversationKind.direct, .group, .official] {
            let folders = existingConversationIDs
                .filter { id in known[id]?.kind == kind }
                .compactMap { id -> MemoryFolder? in
                    guard let conversation = known[id] else { return nil }
                    return .conversation(id: id, title: conversation.displayTitle, kind: kind)
                }
                .sorted { lhs, rhs in
                    let left = folderCounts[lhs.id]?.total ?? 0
                    let right = folderCounts[rhs.id]?.total ?? 0
                    if left != right { return left > right }
                    return lhs.title.localizedCompare(rhs.title) == .orderedAscending
                }
            guard !folders.isEmpty else { continue }
            for folder in folders { claimed.insert(folder.conversationID) }
            sections.append(MemoryFolderSection(id: kind.rawValue, title: kind.label, folders: folders))
        }

        let orphanedIDs = existingConversationIDs.subtracting(claimed).sorted()
        if !orphanedIDs.isEmpty {
            sections.append(MemoryFolderSection(
                id: "orphaned",
                title: "未关联会话",
                folders: orphanedIDs.map { MemoryFolder.orphaned(id: $0) }
            ))
        }

        return LongTermSnapshot(
            activeFolder: activeFolder,
            isSearching: isSearching,
            memories: sorted,
            filteredCoreCount: filteredCoreCount,
            totalMemoryCount: allMemories.count,
            coreMemoryCount: allCounts.core,
            folderSections: sections,
            folderSessionCount: sections.reduce(0) { $0 + $1.folders.count },
            folderCounts: folderCounts
        )
    }

    private func folderStillExists(_ folder: MemoryFolder, ids: Set<String>) -> Bool {
        switch folder {
        case .all, .global: return true
        case .conversation(let id, _, _), .orphaned(let id): return ids.contains(id)
        }
    }

    private func isAllFolderScope(_ folder: MemoryFolder) -> Bool {
        if case .all = folder { return true }
        return false
    }

    private func listTitle(_ snapshot: LongTermSnapshot) -> String {
        snapshot.isSearching ? "搜索结果" : snapshot.activeFolder.title
    }

    private func emptyTitle(_ snapshot: LongTermSnapshot) -> String {
        if snapshot.isSearching { return "没有匹配的长期记忆" }
        if onlyCore { return "没有核心记忆" }
        return isAllFolderScope(snapshot.activeFolder) ? "还没有长期记忆" : "此文件夹暂无长期记忆"
    }

    private func emptyMessage(_ snapshot: LongTermSnapshot) -> String {
        if snapshot.isSearching {
            var text = "尝试其他关键词；搜索会跨全部记忆匹配摘要、会话标题与 ID。"
            if onlyCore { text += "当前仅显示核心记忆。" }
            return text
        }
        if onlyCore {
            return "当前范围没有标记★的核心记忆；关闭「仅核心」可查看全部记忆。"
        }
        if isAllFolderScope(snapshot.activeFolder) {
            return "短期窗口外攒够 \(ChatEngine.overflowBatchThreshold) 条旧消息后会自动批量总结；也可以手动新增一条手写记忆。"
        }
        return "新增的记忆默认归入当前文件夹，也可以在编辑器中改到其它会话。"
    }

    private func emptyActionTitle(_ snapshot: LongTermSnapshot) -> String {
        isAllFolderScope(snapshot.activeFolder) ? "新增第一条长期记忆" : "新增记忆"
    }

    private func subtitle(longTerm: LongTermSnapshot?, chat: ChatSnapshot?) -> String {
        if mode == .longTerm {
            return "\(longTerm?.totalMemoryCount ?? 0) 条长期记忆 · 核心 \(longTerm?.coreMemoryCount ?? 0)"
                + " · 短期窗口 \(ChatEngine.shortTermMemoryLimit) 条"
                + " · 每 \(ChatEngine.overflowBatchThreshold) 条批量总结 · 本地 SQLite"
        }
        return "\(chat?.conversationCount ?? 0) 个会话 · \(chat?.totalMessages ?? 0) 条消息 · 本地 SQLite"
    }

    /// 聊天记录页的一次性派生数据。旧实现里 `searchResults` 每个 body 被求值 2-3 次，
    /// 且逐条消息调用 `conversationTitle(for:)` 做线性查找（O(消息 × 会话)）。
    private func makeChatSnapshot() -> ChatSnapshot {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !keyword.isEmpty
        let conversations = store.conversations

        var titles: [String: String] = [:]
        titles.reserveCapacity(conversations.count)
        for conversation in conversations {
            titles[conversation.id] = conversation.displayTitle
        }

        var totalMessages = 0
        var messageCounts: [String: Int] = [:]
        messageCounts.reserveCapacity(store.messages.count)
        for (conversationID, list) in store.messages {
            totalMessages += list.count
            messageCounts[conversationID] = list.count
        }

        let searchResults: [ChatMessage]
        if isSearching {
            var matches: [ChatMessage] = []
            for list in store.messages.values {
                for message in list {
                    let title = titles[message.conversationID] ?? message.conversationID
                    if message.text.localizedCaseInsensitiveContains(keyword)
                        || message.senderName.localizedCaseInsensitiveContains(keyword)
                        || title.localizedCaseInsensitiveContains(keyword) {
                        matches.append(message)
                    }
                }
            }
            matches.sort { $0.timestamp > $1.timestamp }
            searchResults = matches
        } else {
            searchResults = []
        }

        let filteredConversations: [Conversation]
        if isSearching {
            let matchedIDs = Set(searchResults.map(\.conversationID))
            filteredConversations = conversations
                .filter {
                    matchedIDs.contains($0.id)
                        || $0.displayTitle.localizedCaseInsensitiveContains(keyword)
                        || $0.id.localizedCaseInsensitiveContains(keyword)
                }
                .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
        } else {
            filteredConversations = conversations
                .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
        }

        // store.messages 中每个会话数组由 appendMessage/loadMessages 保持 timestamp
        // 升序，因此不再为每次 body 重新排序。
        let selectedMessages: [ChatMessage] = selectedConversationID.flatMap { store.messages[$0] } ?? []

        return ChatSnapshot(
            conversationCount: conversations.count,
            totalMessages: totalMessages,
            messageCounts: messageCounts,
            searchResults: searchResults,
            filteredConversations: filteredConversations,
            selectedMessages: selectedMessages,
            conversationTitles: titles
        )
    }

    // MARK: Derived

    private var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return store.conversations.first(where: { $0.id == selectedConversationID })
    }

    /// 仅供清理确认弹窗计数使用；消息数组本身已按时间升序维护。
    private var selectedMessages: [ChatMessage] {
        guard let selectedConversationID else { return [] }
        return store.messages[selectedConversationID] ?? []
    }

    /// 仅供清理确认弹窗计数使用（弹窗内容按需求值，不参与页面 body 渲染）。
    private var totalMessages: Int {
        store.messages.values.reduce(0) { $0 + $1.count }
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
                    PillLabel(
                        text: memory.source == "manual" ? "手写" : "自动滚动",
                        color: memory.source == "manual" ? Theme.warning : Color.secondary
                    )
                    if memory.isCore {
                        PillLabel(text: "★ 核心", color: Theme.violet)
                    }
                    if memory.hasCustomBaseWeight {
                        PillLabel(
                            text: "基础 ×\(String(format: "%.1f", memory.baseWeight))",
                            color: Theme.info
                        )
                        .help(L("手工调整的基础权重，会改变该记忆的排序"))
                    }
                    PillLabel(text: "权重 \(memory.weightLabel)", color: Theme.success)
                    Spacer(minLength: 4)
                    Text(activitySummary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(activityHelp)
                }
            }

            Menu {
                Button(L("编辑…"), systemImage: "pencil", action: onEdit)
                Button(memory.isCore ? "取消核心记忆" : "设为核心记忆",
                       systemImage: memory.isCore ? "star.slash" : "star",
                       action: onToggleCore)
                Divider()
                Button(L("删除"), systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityLabel(L("长期记忆操作"))
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
        var parts: [String] = []
        if isStale { parts.append("7 天以上未更新") }
        parts.append("更新 \(UIFormat.relativeShort(memory.updatedAt))")
        if memory.sourceCount > 0 { parts.append("合并 \(memory.sourceCount) 条") }
        if memory.accessCount > 0 { parts.append("召回 \(memory.accessCount) 次") }
        return parts.joined(separator: " · ")
    }

    /// 超过 7 天没更新时给出衰减提示；只读现有字段，不新增模型属性。
    private var isStale: Bool {
        Date().timeIntervalSince(memory.updatedAt) > 7 * 86_400
    }

    private var activityHelp: String {
        var text = "最近更新 \(UIFormat.fullDateTime.string(from: memory.updatedAt))"
        if let lastAccessedAt = memory.lastAccessedAt {
            text += "；最近召回 \(UIFormat.fullDateTime.string(from: lastAccessedAt))"
        }
        text += "。距最近更新/召回越久，权重按 \(Int(LongTermMemory.halfLifeDays)) 天半衰期衰减。"
        if isStale { text += "该记忆已超过 7 天未更新。" }
        return text
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
    @State private var baseWeight: Double
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
        _baseWeight = State(initialValue: LongTermMemory.clampBaseWeight(original.baseWeight))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 11) {
                Image(systemName: isCore ? "star.fill" : "brain.head.profile")
                    .font(.system(size: 22))
                    .foregroundStyle(isCore ? Theme.violet : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "新增长期记忆" : "编辑长期记忆").font(.headline)
                    Text(L("核心记忆在所属会话内优先注入并可自由调整权重；关联“全局记忆”时对所有会话生效"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("记忆内容")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $summary)
                    .font(.body)
                    .frame(minHeight: 150, maxHeight: 220)
                    .padding(6)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                Text(L("例如：对方叫小林，喜欢猫；我们约好周五晚上讨论旅行计划。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if isNew {
                InlineNotice(
                    kind: .info,
                    title: "手写记忆",
                    message: "自动总结不会覆盖手写内容，并会作为后续合并的权威参考。"
                )
            } else if original.source != "manual" {
                InlineNotice(
                    kind: .warning,
                    title: "保存后转为手写记忆",
                    message: "自动总结不再覆盖这条记忆，并作为后续合并的权威参考。"
                )
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("关联会话")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker(L("关联会话"), selection: $conversationID) {
                        Text(L("全局记忆（所有会话）")).tag("")
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
                    Toggle(L("核心记忆"), isOn: $isCore)
                        .toggleStyle(.switch)
                        .tint(Theme.violet)
                    Text(L("核心记忆优先注入；核心之间也按综合权重排序"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(L("基础权重")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f×", baseWeight))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(hasCustomWeight ? Theme.accent : Color.secondary)
                    Button(L("重置")) { baseWeight = LongTermMemory.defaultBaseWeight }
                        .buttonStyle(.plain)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .disabled(!hasCustomWeight)
                        .help(L("恢复默认基础权重 1.0×"))
                }
                Slider(
                    value: $baseWeight,
                    in: LongTermMemory.baseWeightRange,
                    step: 0.1
                ) {
                    Text(L("基础权重"))
                } minimumValueLabel: {
                    Text("0.1×").font(.system(size: 9)).foregroundStyle(.tertiary)
                } maximumValueLabel: {
                    Text("10×").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .tint(baseWeight >= LongTermMemory.defaultBaseWeight ? Theme.accent : Theme.warning)
                .accessibilityLabel(L("基础权重"))
                .accessibilityValue(String(format: "%.1f 倍", baseWeight))

                HStack(spacing: 6) {
                    ForEach(LongTermMemory.baseWeightPresets, id: \.self) { preset in
                        FilterChip(
                            title: String(format: "%.1f×", preset),
                            isSelected: abs(baseWeight - preset) < 0.0001,
                            action: { baseWeight = preset }
                        )
                    }
                    Spacer(minLength: 4)
                    Text(Lf("保存后综合权重约 %.2f", estimatedWeight))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(L("按当前基础权重与保存时刷新的更新时间估算"))
                }
                Text(Lf("核心记忆优先占用注入名额（最多 %d 条），核心之间也按综合权重排序；保存会刷新更新时间，时间衰减从头计算。", ChatEngine.longTermMemoryLimit))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InlineNotice(
                kind: .info,
                title: "综合权重",
                message: "权重 = 基础权重 × 重要度(1 + 0.12 × log2(1 + 合并条数))"
                    + " × 使用强化(1 + 0.02 × 召回次数，最多 +40%)"
                    + " × 0.5^(距最近更新/召回天数 / 30)。基础权重可在上方自由调整；"
                    + "保存会刷新更新时间，越近、越常用的长期记忆优先级越高。"
            )

            HStack {
                if !isNew {
                    Button(L("删除"), systemImage: "trash", role: .destructive) {
                        confirmDelete = true
                    }
                    .buttonStyle(.glass)
                }
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存")) { save() }
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
            Button(L("删除"), role: .destructive) {
                onDelete(original)
                dismiss()
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("删除后无法恢复，但不会影响微信聊天记录。"))
        }
    }

    /// 基础权重是否偏离默认值。
    private var hasCustomWeight: Bool {
        abs(baseWeight - LongTermMemory.defaultBaseWeight) > 0.0001
    }

    /// 保存后的综合权重估算：沿用现有重要度/召回因子，更新时间按保存时刻计算。
    private var estimatedWeight: Double {
        var preview = original
        preview.baseWeight = LongTermMemory.clampBaseWeight(baseWeight)
        preview.updatedAt = Date()
        return preview.timeWeight()
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
        updated.baseWeight = LongTermMemory.clampBaseWeight(baseWeight)
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
                    Text(L("清理记忆库")).font(.headline)
                    Text(L("此操作不可撤销")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(L("删除本地 SQLite 中保存的聊天记录。微信端的消息不会受影响。"))
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
                Button(L("取消")) { dismiss() }
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
                    Text(L(title)).font(.callout)
                    Text(L(detail)).font(.caption2).foregroundStyle(.secondary)
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

private struct MemoryMessageRow: View, Equatable {
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
