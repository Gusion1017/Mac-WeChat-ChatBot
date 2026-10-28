import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 记忆卡列表筛选（docs/memory.md §10.1）。
private enum MemoryFilter: String, CaseIterable, Identifiable {
    case all
    case recent
    case important
    case todo
    case fact
    case decision
    case lesson
    case archived
    case superseded

    var id: String { rawValue }

    /// 动态标签（「最近」按当前设置的窗口小时数生成），其余直接本地化。
    func label(settings: MemorySettings) -> String {
        switch self {
        case .all: L("全部")
        case .recent: Lf("最近 %dh", settings.recentWindowHours)
        case .important: L("重要")
        case .todo: L("待办")
        case .fact: L("事实")
        case .decision: L("决策")
        case .lesson: L("经验")
        case .archived: L("已归档")
        case .superseded: L("已被取代")
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .recent: "clock"
        case .important: "exclamationmark.circle"
        case .todo: "checklist"
        case .fact: "text.book.closed"
        case .decision: "arrow.triangle.branch"
        case .lesson: "lightbulb"
        case .archived: "archivebox"
        case .superseded: "arrow.triangle.branch"
        }
    }

    var tint: Color {
        switch self {
        case .all: Theme.accent
        case .recent: Theme.info
        case .important: Theme.warning
        case .todo: Theme.accent
        case .fact: Theme.info
        case .decision: Theme.violet
        case .lesson: Theme.warning
        case .archived: .secondary
        case .superseded: Theme.danger
        }
    }

    func matches(
        _ memory: CharacterMemory,
        settings: MemorySettings,
        now: Date
    ) -> Bool {
        let isActive = !memory.archived && !memory.isSuperseded
        switch self {
        case .all:
            return isActive
        case .recent:
            return isActive && memory.isRecent(now: now, settings: settings)
        case .important:
            return isActive
                && memory.resolvedKind(threshold: settings.importanceThreshold) == .important
        case .todo:
            return isActive && memory.category == .todo
        case .fact:
            return isActive && memory.category == .fact
        case .decision:
            return isActive && memory.category == .decision
        case .lesson:
            return isActive && memory.category == .lesson
        case .archived:
            return memory.archived
        case .superseded:
            return memory.isSuperseded
        }
    }
}

/// 记忆卡列表排序。
private enum MemorySortMode: String, CaseIterable, Identifiable {
    case weight
    case recentlyUpdated
    case importance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weight: L("综合权重")
        case .recentlyUpdated: L("最近更新")
        case .importance: L("重要度")
        }
    }

    var symbol: String {
        switch self {
        case .weight: "scalemass"
        case .recentlyUpdated: "clock.arrow.circlepath"
        case .importance: "exclamationmark.circle"
        }
    }
}

/// 一条记忆 + 一次性算好的综合权重；body 内不再重复求值。
private struct ScoredMemory: Identifiable {
    var id: String { memory.id }
    let memory: CharacterMemory
    let score: Double
}

/// 记忆卡页面的计数（与 `CharacterStore.memoryCounts` 同口径：
/// 「生效」只算未归档、未被取代）。
private struct MemoryCardCounts: Equatable {
    var active = 0
}

/// 角色列表派生数据：一次遍历，body 只构建一次。
private struct CharacterListSnapshot {
    let all: [CharacterSummary]
    let global: CharacterSummary?
    let visible: [CharacterSummary]
    let totalActive: Int
    let totalImportant: Int
    let totalTodo: Int
    let isSearching: Bool
}

/// 记忆卡右栏派生数据：计数、筛选、搜索、权重与排序都只算一次。
private struct MemoryCardSnapshot {
    let now: Date
    let settings: MemorySettings
    let isAggregate: Bool
    let characterID: String?
    let summary: CharacterSummary?
    let counts: MemoryCardCounts
    let filterCounts: [MemoryFilter: Int]
    let visible: [ScoredMemory]
    let totalLoaded: Int
    let characterTitles: [String: String]
    let hasSearch: Bool

    var title: String {
        if let summary, !summary.title.isEmpty { return summary.title }
        return isAggregate ? L("全部角色") : (characterID ?? L("未命名角色"))
    }

    var kind: ConversationKind {
        summary?.kind ?? .direct
    }
}

/// 记忆库：记忆卡的新增/编辑/筛选/导出。
struct MemoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var characterSearch = ""
    @State private var memorySearch = ""
    @State private var filter: MemoryFilter = .all
    @State private var sortMode: MemorySortMode = .weight
    @State private var showWeightInfo = false
    @State private var editingMemory: CharacterMemory?
    @State private var editingMemoryIsNew = false
    @State private var pendingDeleteMemory: CharacterMemory?
    @State private var showFullArchive = false
    @State private var showSettings = false
    @State private var showRecallPreview = false
    @State private var showDeleteCard = false
    @State private var showCreateCardsConfirm = false
    /// 切换角色时旧记忆仍留在 store 里，先隐藏列表再等新数据，避免短暂的错位展示。
    @State private var isLoadingSelection = false

    var body: some View {
        let characters = makeCharacterListSnapshot()
        let cards = makeCardSnapshot()

        VStack(spacing: 0) {
            GlassToolbar(
                title: "记忆库",
                subtitle: subtitle(characters: characters, cards: cards)
            ) {
                IconActionButton(symbol: "arrow.clockwise", help: "刷新角色与记忆卡") {
                    refresh()
                }
                IconActionButton(symbol: "gearshape", help: "记忆设置") {
                    showSettings = true
                }
            }

            GeometryReader { proxy in
                cardsPanes(characters, cards)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PageBackground())
        .onAppear {
            store.isMemoryPageVisible = true
        }
        .onDisappear {
            store.isMemoryPageVisible = false
        }
        .task(id: store.activeAccountID) {
            await loadTask()
        }
        .sheet(item: $editingMemory) { memory in
            MemoryEditorSheet(
                original: memory,
                isNew: editingMemoryIsNew,
                conversationTitle: characterTitle(memory.characterID),
                settings: store.settings.bot.memorySettings
            )
        }
        .sheet(isPresented: $showFullArchive) {
            if let conversationID = store.selectedCharacterID {
                CharacterFullArchive(
                    conversationID: conversationID,
                    title: characterTitle(conversationID)
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            MemorySettingsSheet(settings: store.settings.bot.memorySettings)
        }
        .sheet(isPresented: $showRecallPreview) {
            if let conversationID = store.selectedCharacterID {
                RecallPreviewSheet(
                    conversationID: conversationID,
                    title: characterTitle(conversationID)
                )
            }
        }
        .confirmationDialog(
            "删除这条记忆？",
            isPresented: Binding(
                get: { pendingDeleteMemory != nil },
                set: { if !$0 { pendingDeleteMemory = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteMemory
        ) { memory in
            Button(L("删除"), role: .destructive) {
                deleteMemory(memory)
                pendingDeleteMemory = nil
            }
            Button(L("取消"), role: .cancel) { pendingDeleteMemory = nil }
        } message: { _ in
            Text(L("删除后无法恢复；不会影响微信聊天记录与其它记忆。"))
        }
        .confirmationDialog(
            "删除记忆卡？",
            isPresented: $showDeleteCard,
            titleVisibility: .visible
        ) {
            Button(L("删除记忆卡"), role: .destructive) {
                deleteSelectedCharacterCard()
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("整个角色目录会移到废纸篓（记忆 + 全量记录）。人格设定不受影响；下次机器人回复时会重建空记忆卡。"))
        }
        .confirmationDialog(
            "为现有会话创建记忆卡？",
            isPresented: $showCreateCardsConfirm,
            titleVisibility: .visible
        ) {
            Button(L("创建记忆卡")) { performCreateMissingCards() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("将为还没有记忆卡的现有微信会话创建空记忆卡，不会提取旧聊天；之后可在各角色中导入旧记忆。"))
        }
    }

    // MARK: - Memory card panes

    @ViewBuilder
    private func cardsPanes(_ characters: CharacterListSnapshot, _ cards: MemoryCardSnapshot) -> some View {
        HStack(spacing: 0) {
            characterPane(characters, cards)
                .frame(width: 290)
                .background(.ultraThinMaterial)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .accessibilityHidden(true)

            Group {
                if !store.isAllCharactersSelected, store.selectedCharacterID == nil {
                    EmptyState(
                        symbol: "person.crop.rectangle.stack",
                        title: "选择一个角色",
                        message: "从左侧选择会话角色查看记忆；点「全部角色」才会打开聚合视图。",
                        actionTitle: "查看全部角色"
                    ) {
                        selectCharacter(nil)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    memoryPane(cards)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Character list

    private func characterPane(
        _ characters: CharacterListSnapshot,
        _ cards: MemoryCardSnapshot
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(L("角色"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Lf("%d 个", characters.all.count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 7)

            Divider().opacity(0.5)

            SearchField(text: $characterSearch, placeholder: "搜索角色或人格")
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider().opacity(0.5)

            if characters.all.isEmpty && characters.global == nil {
                VStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text(L("还没有记忆卡"))
                        .font(.caption.weight(.semibold))
                    Text(L("机器人为某个会话生成第一次回复后会自动创建。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("刷新")) { refresh() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(18)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        aggregateRow(characters)
                        if let global = characters.global {
                            globalRow(global)
                        }
                        if characters.isSearching && characters.visible.isEmpty {
                            Text(L("没有匹配的角色"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        ForEach(characters.visible) { summary in
                            characterRow(summary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                counterBadge("star.fill", count: characters.totalImportant, color: Theme.violet)
                counterBadge("checklist", count: characters.totalTodo, color: Theme.accent)
                Spacer()
                Text(Lf("%d 条记忆", characters.totalActive))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private func aggregateRow(_ characters: CharacterListSnapshot) -> some View {
        let isSelected = store.isAllCharactersSelected
        return Button {
            selectCharacter(nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("全部角色"))
                        .font(.caption.weight(.medium))
                    Text(Lf("%d 个会话角色 · %d 条记忆",
                            characters.all.count, characters.totalActive))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
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
        .help(L("聚合显示所有角色的记忆；选择具体角色后可查看全量记录与导出"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func globalRow(_ summary: CharacterSummary) -> some View {
        let isSelected = store.selectedCharacterID == summary.conversationID
        return Button {
            selectCharacter(summary.conversationID)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.violet)
                    .frame(width: 26, height: 26)
                    .background(Theme.violet.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(L("所有会话共享"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Lf("%d 条", summary.memoryCount))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
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
        .help(L("全局共享记忆会注入所有会话；只能手动维护"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func characterRow(_ summary: CharacterSummary) -> some View {
        let isSelected = store.selectedCharacterID == summary.conversationID
        return Button {
            selectCharacter(summary.conversationID)
        } label: {
            HStack(spacing: 8) {
                AvatarView(title: summary.title, kind: summary.kind, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(summary.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(rowSubtitle(summary))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Lf("%d 条", summary.memoryCount))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        if summary.importantCount > 0 {
                            counterBadge("exclamationmark.circle.fill",
                                         count: summary.importantCount, color: Theme.warning)
                        }
                        if summary.todoCount > 0 {
                            counterBadge("checklist", count: summary.todoCount, color: Theme.accent)
                        }
                    }
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
        .help(summary.directoryPath.isEmpty ? summary.title : summary.directoryPath)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 左栏第二行：人格名 · 会话类型（标题、类型、人格名与计数都由 CharacterSummary 提供）。
    private func rowSubtitle(_ summary: CharacterSummary) -> String {
        let persona = summary.personaName.isEmpty ? L("未命名角色") : summary.personaName
        return persona + " · " + summary.kind.label
    }

    private func counterBadge(_ symbol: String, count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(color)
        .accessibilityLabel(Lf("%d 条", count))
    }

    // MARK: Memory card pane

    private func memoryPane(_ cards: MemoryCardSnapshot) -> some View {
        VStack(spacing: 0) {
            memoryHeader(cards)
            Divider().opacity(0.5)

            if !cards.settings.enabled {
                memoryDisabledNotice(cards)
            }

            filterBar(cards)

            Divider().opacity(0.5)

            listToolbar(cards)

            Divider().opacity(0.5)

            memoryList(cards)
        }
    }

    private func memoryHeader(_ cards: MemoryCardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(
                    title: cards.isAggregate ? L("全部角色") : cards.title,
                    kind: cards.isAggregate ? .group : cards.kind,
                    size: 34
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(cards.title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if cards.isAggregate {
                            PillLabel(text: "聚合视图", color: Theme.info)
                        } else if cards.summary?.isGlobal == true {
                            PillLabel(text: "全局共享", color: Theme.violet)
                        } else {
                            PillLabel(text: cards.kind.label, color: .secondary)
                        }
                    }

                    Text(headerContext(cards))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                HStack(spacing: 7) {
                    Button {
                        showFullArchive = true
                    } label: {
                        Label(L("全量记录"), systemImage: "archivebox")
                    }
                    .buttonStyle(.glass)
                    .disabled(cards.isAggregate || cards.summary?.isGlobal == true)
                    .help(cards.isAggregate
                        ? L("聚合视图没有单一全量记录；请先在左侧选择角色")
                        : (cards.summary?.isGlobal == true
                            ? L("全局共享记忆不属于具体会话，没有全量互动记录")
                            : L("查看该会话永久保存的全量互动记录")))

                    Menu {
                        Button(L("Markdown")) { exportCard(format: "markdown") }
                        Button(L("JSON")) { exportCard(format: "json") }
                    } label: {
                        Label(L("导出"), systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(cards.isAggregate)
                    .help(cards.isAggregate
                        ? L("聚合视图不能导出；请先在左侧选择角色")
                        : L("导出记忆卡（Markdown / JSON）"))

                    Menu {
                        Button(L("预览注入…"), systemImage: "text.magnifyingglass") {
                            showRecallPreview = true
                        }
                        .disabled(cards.isAggregate)
                        Button(L("导入旧记忆…"), systemImage: "tray.and.arrow.down") {
                            importLegacyMemories()
                        }
                        .disabled(cards.isAggregate)
                        Divider()
                        Button(L("为缺失会话创建记忆卡…"), systemImage: "rectangle.stack.badge.plus") {
                            showCreateCardsConfirm = true
                        }
                        Divider()
                        Button(L("删除记忆卡…"), systemImage: "trash", role: .destructive) {
                            showDeleteCard = true
                        }
                        .disabled(cards.isAggregate || cards.summary?.isGlobal == true)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L("更多：预览注入 / 导入旧记忆 / 为缺失会话创建记忆卡 / 删除记忆卡"))
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func headerContext(_ cards: MemoryCardSnapshot) -> String {
        if cards.isAggregate {
            let globalCount = cards.characterTitles[CharacterStore.globalConversationID] == nil ? 0 : 1
            let characters = max(0, cards.characterTitles.count - globalCount)
            return Lf("聚合 %d 个会话角色 · 全局记忆同时并入", characters)
        }
        if cards.summary?.isGlobal == true {
            let date = cards.summary?.lastUpdated
            let updated = date.map { UIFormat.relativeShort($0, now: cards.now) } ?? "—"
            return Lf("注入所有会话 · 更新 %@", updated)
        }
        let name = cards.summary?.personaName.isEmpty == false
            ? (cards.summary?.personaName ?? cards.title)
            : cards.title
        let date = cards.summary?.lastUpdated
        let updated = date.map { UIFormat.relativeShort($0, now: cards.now) } ?? "—"
        return Lf("人设：%@（人格设定）· 更新 %@", name, updated)
    }

    private func memoryDisabledNotice(_ cards: MemoryCardSnapshot) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text(L("记忆功能已关闭：不提取、不召回；已保存的记忆仍可浏览、编辑和导出。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(L("打开设置")) { showSettings = true }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.warning.opacity(0.08))
    }

    private func filterBar(_ cards: MemoryCardSnapshot) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(MemoryFilter.allCases) { item in
                FilterChip(
                    title: item.label(settings: cards.settings),
                    symbol: item.symbol,
                    count: cards.filterCounts[item] ?? 0,
                    isSelected: filter == item,
                    tint: item.tint
                ) {
                    filter = item
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    private func listToolbar(_ cards: MemoryCardSnapshot) -> some View {
        HStack(spacing: 9) {
            memorySortMenu
            Text(Lf("显示 %d / %d 条", cards.visible.count, cards.totalLoaded))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if store.isLoadingCharacter {
                ProgressView().controlSize(.small)
            }
            weightInfoButton(cards.settings)
            SearchField(text: $memorySearch, placeholder: "搜索正文或关键词")
                .frame(width: 200)
            Button {
                newMemory()
            } label: {
                Label(L("新增记忆"), systemImage: "plus")
            }
            .buttonStyle(.glass)
            .disabled(cards.isAggregate)
            .help(cards.isAggregate
                ? L("先在左侧选择一个角色")
                : L("新增一条手写记忆"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var memorySortMenu: some View {
        Menu {
            Section(L("排序方式")) {
                ForEach(MemorySortMode.allCases) { item in
                    Button {
                        sortMode = item
                    } label: {
                        Label(
                            item.label,
                            systemImage: sortMode == item ? "checkmark" : item.symbol
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
        .help(L("排序方式：综合权重（默认）/ 最近更新 / 重要度"))
        .accessibilityLabel(Lf("排序方式：%@", sortMode.label))
    }

    private func weightInfoButton(_ settings: MemorySettings) -> some View {
        Button {
            showWeightInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("综合权重公式：点击查看说明"))
        .accessibilityLabel(L("综合权重公式说明"))
        .popover(isPresented: $showWeightInfo, arrowEdge: .bottom) {
            weightInfoPopover(settings)
        }
    }

    private func weightInfoPopover(_ settings: MemorySettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("综合权重"), systemImage: "scalemass")
                .font(.headline)
            Text(Lf(
                "权重越高越优先召回；置顶记忆不衰减，最近 %d 小时内的记忆最多获得 1.5× 加成。半衰期 %d/%d 天。",
                settings.recentWindowHours, settings.normalHalfLifeDays,
                settings.importantHalfLifeDays
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(weightFormula(settings))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("编辑、置顶或召回都会改变权重锚点；来源与召回次数不会因编辑丢失。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    /// 公式引用当前设置，避免界面说明与实现漂移（§5.1）。
    private func weightFormula(_ settings: MemorySettings) -> String {
        if L10n.language == "en" {
            return """
            score = importance × recency × usage × decay
            recency = 1 + 0.5 × max(0, 1 − hours since activity / \(settings.recentWindowHours))
            usage = 1 + 0.02 × min(recalls, 20)
            decay = 1 (pinned)
            decay = 0.5^(days / \(settings.normalHalfLifeDays)) (normal)
            decay = 0.5^(days / \(settings.importantHalfLifeDays)) (important)
            """
        }
        return """
        权重 = 重要度 × 最近加成 × 使用强化 × 时间衰减
        最近加成 = 1 + 0.5 × max(0, 1 − 距最近活动小时数 / \(settings.recentWindowHours))
        使用强化 = 1 + 0.02 × min(召回次数, 20)
        时间衰减 = 1（置顶）
        时间衰减 = 0.5^(距最近活动天数 / \(settings.normalHalfLifeDays))（普通）
        时间衰减 = 0.5^(距最近活动天数 / \(settings.importantHalfLifeDays))（重要）
        """
    }

    @ViewBuilder
    private func memoryList(_ cards: MemoryCardSnapshot) -> some View {
        if isLoadingSelection || (store.isLoadingCharacter && cards.totalLoaded == 0) {
            LoadingState(title: "读取记忆卡…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !cards.isAggregate, cards.summary == nil, !store.isLoadingCharacter {
            EmptyState(
                symbol: "exclamationmark.triangle",
                title: "无法读取记忆卡",
                message: "角色目录可能已被删除，或账号正在切换。重新选择角色或查看全部角色。",
                actionTitle: "查看全部角色"
            ) {
                selectCharacter(nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if cards.totalLoaded == 0 {
            if cards.isAggregate, cards.characterTitles.isEmpty {
                EmptyState(
                    symbol: "brain.head.profile",
                    title: "还没有记忆卡",
                    message: "机器人为某个会话生成第一次回复后会自动创建记忆卡，之后每批维护把聊天内容提取成原子记忆。",
                    actionTitle: "刷新"
                ) {
                    refresh()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cards.isAggregate {
                EmptyState(
                    symbol: "sparkles",
                    title: "记忆卡还是空的",
                    message: "选中左侧角色后可新增手写记忆；机器人下一次回复后也会自动提取。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(
                    symbol: "sparkles",
                    title: cards.summary?.isGlobal == true ? "全局记忆还是空的" : "这个角色还没有记忆",
                    message: cards.summary?.isGlobal == true
                        ? "新增的记忆会注入所有会话；全局记忆只支持手动维护。"
                        : "可以新增一条手写记忆，或等待机器人回复后自动提取。",
                    actionTitle: "新增记忆"
                ) {
                    newMemory()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if cards.visible.isEmpty {
            EmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                title: emptyTitle(cards),
                message: emptyMessage(cards),
                actionTitle: "显示全部"
            ) {
                resetFilters()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards.visible) { item in
                        CharacterMemoryCard(
                            memory: item.memory,
                            score: item.score,
                            settings: cards.settings,
                            characterTitle: cards.isAggregate
                                ? cards.characterTitles[item.memory.characterID]
                                : nil,
                            now: cards.now,
                            onEdit: { editMemory(item.memory) },
                            onTogglePinned: { togglePinned(item.memory) },
                            onToggleArchived: { toggleArchived(item.memory) },
                            onCompress: { compress(item.memory) },
                            onCancelSupersede: { cancelSupersede(item.memory) },
                            onDelete: { pendingDeleteMemory = item.memory }
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private func emptyTitle(_ cards: MemoryCardSnapshot) -> String {
        if cards.hasSearch { return L("没有匹配的记忆") }
        return L("当前筛选暂无记忆")
    }

    private func emptyMessage(_ cards: MemoryCardSnapshot) -> String {
        if cards.hasSearch {
            return L("尝试其它关键词；搜索匹配正文与关键词。也可以点「显示全部」清除筛选。")
        }
        return L("切换其它筛选条件，或点「显示全部」回到全部记忆；已归档与已被取代的记忆在对应筛选中查看。")
    }

    // MARK: - Snapshot derivation

    private func makeCharacterListSnapshot() -> CharacterListSnapshot {
        let keyword = characterSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let everySummary = store.characterSummaries
        let global = everySummary.first { $0.isGlobal }
        let all = everySummary.filter { !$0.isGlobal }
        let visible: [CharacterSummary]
        if keyword.isEmpty {
            visible = all
        } else {
            visible = all.filter {
                $0.title.localizedCaseInsensitiveContains(keyword)
                    || $0.personaName.localizedCaseInsensitiveContains(keyword)
                    || $0.conversationID.localizedCaseInsensitiveContains(keyword)
            }
        }
        var totalActive = 0
        var totalImportant = 0
        var totalTodo = 0
        for summary in everySummary {
            totalActive += summary.memoryCount
            totalImportant += summary.importantCount
            totalTodo += summary.todoCount
        }
        return CharacterListSnapshot(
            all: all,
            global: global,
            visible: visible,
            totalActive: totalActive,
            totalImportant: totalImportant,
            totalTodo: totalTodo,
            isSearching: !keyword.isEmpty
        )
    }

    private func makeCardSnapshot() -> MemoryCardSnapshot {
        let now = Date()
        let settings = store.settings.bot.memorySettings
        let characterID = store.selectedCharacterID
        let isAggregate = store.isAllCharactersSelected
        let summary = characterID.flatMap { id in
            store.characterSummaries.first(where: { $0.conversationID == id })
        }
        var titles: [String: String] = [:]
        titles.reserveCapacity(store.characterSummaries.count)
        for item in store.characterSummaries {
            titles[item.conversationID] = item.title
        }

        let keyword = memorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        var counts = MemoryCardCounts()
        var filterCounts: [MemoryFilter: Int] = [:]
        var filtered: [ScoredMemory] = []

        for memory in store.characterMemories {
            let score = memory.score(now: now, settings: settings)
            let isActive = !memory.archived && !memory.isSuperseded
            if isActive {
                counts.active += 1
            }

            for item in MemoryFilter.allCases
            where item.matches(memory, settings: settings, now: now) {
                filterCounts[item, default: 0] += 1
            }

            guard filter.matches(memory, settings: settings, now: now) else { continue }
            if !keyword.isEmpty && !Self.matchesSearch(memory, keyword: keyword) { continue }
            filtered.append(ScoredMemory(memory: memory, score: score))
        }

        let sorted: [ScoredMemory]
        switch sortMode {
        case .weight:
            sorted = filtered.sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.000_001 { return lhs.score > rhs.score }
                return lhs.memory.updatedAt > rhs.memory.updatedAt
            }
        case .recentlyUpdated:
            sorted = filtered.sorted { lhs, rhs in
                if lhs.memory.updatedAt != rhs.memory.updatedAt {
                    return lhs.memory.updatedAt > rhs.memory.updatedAt
                }
                return lhs.score > rhs.score
            }
        case .importance:
            sorted = filtered.sorted { lhs, rhs in
                if lhs.memory.importance != rhs.memory.importance {
                    return lhs.memory.importance > rhs.memory.importance
                }
                return lhs.score > rhs.score
            }
        }

        return MemoryCardSnapshot(
            now: now,
            settings: settings,
            isAggregate: isAggregate,
            characterID: characterID,
            summary: summary,
            counts: counts,
            filterCounts: filterCounts,
            visible: sorted,
            totalLoaded: store.characterMemories.count,
            characterTitles: titles,
            hasSearch: !keyword.isEmpty
        )
    }

    private static func matchesSearch(_ memory: CharacterMemory, keyword: String) -> Bool {
        if memory.content.localizedCaseInsensitiveContains(keyword) { return true }
        if let compressed = memory.compressedContent,
           compressed.localizedCaseInsensitiveContains(keyword) {
            return true
        }
        return memory.keywords.contains { $0.localizedCaseInsensitiveContains(keyword) }
    }

    private func subtitle(
        characters: CharacterListSnapshot,
        cards: MemoryCardSnapshot
    ) -> String {
        let count = characters.all.count + (characters.global == nil ? 0 : 1)
        if store.settings.bot.memorySettings.enabled {
            return Lf("%d 个记忆卡 · %d 条生效记忆 · 本地 SQLite",
                      count, characters.totalActive)
        }
        return Lf("%d 个记忆卡 · 记忆功能已关闭 · 本地 SQLite", count)
    }

    // MARK: - Selection & loading

    private func loadTask() async {
        store.isMemoryPageVisible = true
        await store.loadCharacterSummaries()
        // 栏目入口只展示列表；聚合页也必须由用户点击后才打开。
        store.clearCharacterSelection()
    }

    private func refresh() {
        Task {
            await store.loadCharacterSummaries()
            if store.isAllCharactersSelected {
                await store.selectCharacter(nil)
            } else if let id = store.selectedCharacterID {
                await store.selectCharacter(id)
            } else {
                store.clearCharacterSelection()
            }
        }
    }

    private func selectCharacter(_ conversationID: String?) {
        if conversationID == store.selectedCharacterID,
           (conversationID != nil || store.isAllCharactersSelected) {
            return
        }
        memorySearch = ""
        isLoadingSelection = true
        Task {
            await store.selectCharacter(conversationID)
            isLoadingSelection = false
        }
    }

    private func resetFilters() {
        filter = .all
        memorySearch = ""
    }

    private func characterTitle(_ conversationID: String) -> String {
        if let summary = store.characterSummaries.first(
            where: { $0.conversationID == conversationID }) {
            return summary.title
        }
        if store.selectedCharacterID == conversationID,
           let summary = store.characterSummaries.first(
                where: { $0.conversationID == conversationID }) {
            return summary.title.isEmpty ? conversationID : summary.title
        }
        return conversationID
    }

    // MARK: - Memory actions

    private func performCreateMissingCards() {
        Task {
            let count = await store.createMissingCharacterCards()
            if count > 0 {
                toast.show(
                    Lf("已为 %d 个会话创建记忆卡", count),
                    tone: .success,
                    symbol: "rectangle.stack.badge.plus"
                )
            } else {
                toast.show(
                    L("没有可创建的会话：可能都已创建，或只剩系统会话"),
                    tone: .info,
                    symbol: "info.circle"
                )
            }
        }
    }

    private func newMemory() {
        guard let characterID = store.selectedCharacterID else {
            toast.show(L("请先在左侧选择一个角色"), tone: .warning)
            return
        }
        var memory = CharacterMemory(characterID: characterID, content: "")
        memory.source = .manual
        memory.category = .fact
        editingMemoryIsNew = true
        editingMemory = memory
    }

    private func editMemory(_ memory: CharacterMemory) {
        editingMemoryIsNew = false
        editingMemory = memory
    }

    private func togglePinned(_ memory: CharacterMemory) {
        var updated = memory
        updated.pinned.toggle()
        Task {
            let saved = await store.saveCharacterMemory(updated)
            if saved {
                toast.show(
                    updated.pinned ? L("已置顶记忆") : L("已取消置顶"),
                    tone: .success,
                    symbol: updated.pinned ? "pin.fill" : "pin.slash"
                )
            } else {
                toast.show(L("保存记忆失败，请查看日志"), tone: .error)
            }
        }
    }

    private func toggleArchived(_ memory: CharacterMemory) {
        var updated = memory
        updated.archived.toggle()
        Task {
            let saved = await store.saveCharacterMemory(updated)
            if saved {
                toast.show(
                    updated.archived ? L("已归档记忆") : L("已恢复记忆"),
                    tone: .info,
                    symbol: updated.archived ? "archivebox" : "tray.and.arrow.up"
                )
            } else {
                toast.show(L("保存记忆失败，请查看日志"), tone: .error)
            }
        }
    }

    private func compress(_ memory: CharacterMemory) {
        Task {
            await store.compressCharacterMemory(memory)
            toast.show(L("压缩完成，结果可在日志中查看"), tone: .info, symbol: "rectangle.compress.vertical")
        }
    }

    private func cancelSupersede(_ memory: CharacterMemory) {
        Task {
            await store.cancelSupersede(memory)
            toast.show(L("已取消取代标记"), tone: .success, symbol: "arrow.uturn.backward")
        }
    }

    private func deleteMemory(_ memory: CharacterMemory) {
        Task {
            await store.deleteCharacterMemory(memory)
            toast.show(L("已删除记忆"), tone: .info, symbol: "trash")
        }
    }

    private func importLegacyMemories() {
        guard let conversationID = store.selectedCharacterID else { return }
        Task {
            let count = await store.importLegacyMemories(conversationID: conversationID)
            if count > 0 {
                toast.show(Lf("已导入 %d 条旧记忆", count), tone: .success)
            } else {
                toast.show(L("没有可导入的旧记忆"), tone: .info)
            }
        }
    }

    private func deleteSelectedCharacterCard() {
        guard let conversationID = store.selectedCharacterID else { return }
        Task {
            await store.deleteCharacterCard(conversationID: conversationID)
            await store.selectCharacter(nil)
            await store.loadCharacterSummaries()
            resetFilters()
            toast.show(L("已删除记忆卡"), tone: .info, symbol: "trash")
        }
    }

    // MARK: - Export

    private func exportCard(format: String) {
        guard let conversationID = store.selectedCharacterID else { return }
        let title = characterTitle(conversationID)
        Task {
            guard let text = await store.exportCharacter(
                conversationID: conversationID, format: format) else {
                toast.show(L("导出失败：没有可导出的记忆卡"), tone: .error)
                return
            }
            presentSavePanel(text: text, format: format, title: title)
        }
    }

    /// 导出内容在后台生成，NSSavePanel 回到 MainActor 再弹（模态），最后写 UTF-8。
    private func presentSavePanel(text: String, format: String, title: String) {
        let isJSON = format == "json"
        let panel = NSSavePanel()
        panel.title = L("导出记忆卡")
        panel.nameFieldStringValue = Lf("记忆卡-%@", safeFileTitle(title))
            + "." + (isJSON ? "json" : "md")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [isJSON ? .json : .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            toast.show(Lf("已导出到 %@", url.path), tone: .success)
        } catch {
            toast.show(Lf("导出失败：%@", error.localizedDescription), tone: .error)
        }
    }

    private func safeFileTitle(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "character" }
        return String(cleaned.prefix(60))
    }
}

// MARK: - Memory card

/// 一条记忆的卡片：正文、类别/状态徽标、关键词、权重与操作菜单。
private struct CharacterMemoryCard: View {
    let memory: CharacterMemory
    let score: Double
    let settings: MemorySettings
    var characterTitle: String?
    let now: Date
    let onEdit: () -> Void
    let onTogglePinned: () -> Void
    let onToggleArchived: () -> Void
    let onCompress: () -> Void
    let onCancelSupersede: () -> Void
    let onDelete: () -> Void

    private var tint: Color { memory.category.tint }

    private var resolvedKind: MemoryKind {
        memory.resolvedKind(threshold: settings.importanceThreshold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: memory.category.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)

                Text(memory.content)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    Button(L("编辑…"), systemImage: "pencil", action: onEdit)
                    Button(
                        memory.pinned ? L("取消置顶") : L("置顶"),
                        systemImage: memory.pinned ? "pin.slash" : "pin",
                        action: onTogglePinned
                    )
                    Button(
                        memory.archived ? L("恢复") : L("归档"),
                        systemImage: memory.archived ? "tray.and.arrow.up" : "archivebox",
                        action: onToggleArchived
                    )
                    Button(L("压缩"), systemImage: "rectangle.compress.vertical", action: onCompress)
                        .disabled(memory.content.count <= 300 && memory.compressedContent == nil)
                    if memory.isSuperseded || memory.supersedes != nil {
                        Button(L("取消取代"), systemImage: "arrow.uturn.backward") {
                            onCancelSupersede()
                        }
                    }
                    Divider()
                    Button(L("删除"), systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(L("记忆操作"))
            }

            badges

            if !memory.keywords.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(memory.keywords, id: \.self) { keyword in
                        Text(keyword)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                }
            }

            HStack(spacing: 8) {
                Text(activitySummary)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Lf("权重 %.2f", score))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.success)
                    .help(L("综合权重；置顶记忆不衰减"))
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var badges: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            PillLabel(text: memory.category.label, color: tint, symbol: memory.category.symbol)
            if memory.pinned {
                PillLabel(text: "置顶", color: Theme.accent, symbol: "pin.fill")
            }
            if resolvedKind == .important && !memory.pinned {
                PillLabel(text: "重要", color: Theme.warning,
                          symbol: "exclamationmark.circle.fill")
            }
            if memory.archived {
                PillLabel(text: "已归档", color: .secondary, symbol: "archivebox")
            }
            if memory.isSuperseded {
                PillLabel(text: "已被取代", color: Theme.danger,
                          symbol: "arrow.triangle.branch")
            }
            if let characterTitle {
                Text(characterTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.info)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.info.opacity(0.12), in: Capsule())
                    .lineLimit(1)
            }
            PillLabel(text: memory.source.label, color: .secondary)
            if memory.mergeCount > 0 {
                PillLabel(text: Lf("合并 %d", memory.mergeCount), color: .secondary)
            }
            if memory.accessCount > 0 {
                PillLabel(text: Lf("召回 %d", memory.accessCount), color: .secondary)
            }
            PillLabel(
                text: Lf("重要度 %d", Int(memory.importance.rounded())),
                color: .secondary
            )
        }
    }

    private var borderColor: Color {
        if memory.isSuperseded { return Theme.danger.opacity(0.25) }
        if memory.pinned { return Theme.violet.opacity(0.28) }
        if resolvedKind == .important { return Theme.warning.opacity(0.22) }
        return Color.primary.opacity(0.05)
    }

    private var activitySummary: String {
        var parts: [String] = [Lf("更新 %@", UIFormat.relativeShort(memory.updatedAt, now: now))]
        if let lastAccessedAt = memory.lastAccessedAt {
            parts.append(Lf("召回 %@", UIFormat.relativeShort(lastAccessedAt, now: now)))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Recall preview

/// 「预览注入」：输入一句模拟消息，展示该会话当前会注入的「相关历史记忆」。
///
/// 只读：`recordAccess: false`，不会累加召回次数、不修改记忆（§8.3）。
private struct RecallPreviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let conversationID: String
    let title: String

    @State private var query = ""
    @State private var result: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.info)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("预览注入")).font(.headline)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            InlineNotice(
                kind: .info,
                title: "只读预览",
                message: "预览不会累加召回次数，也不会修改记忆内容；关闭记忆功能后仍可用于检查。"
            )

            HStack(spacing: 8) {
                TextField(
                    L("模拟消息"),
                    text: $query,
                    prompt: Text(L("输入一句话，预览会命中哪些记忆"))
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await loadPreview() } }
                Button(L("预览")) { Task { await loadPreview() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(isLoading)
            }

            Divider().opacity(0.5)

            Group {
                if isLoading {
                    LoadingState(title: "生成预览…")
                } else if let result, !result.isEmpty {
                    ScrollView {
                        Text(result)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(
                        Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                } else {
                    EmptyState(
                        symbol: "text.magnifyingglass",
                        title: "没有可注入的记忆",
                        message: "当前没有命中的生效记忆，或该会话还没有记忆卡。可先输入关键词再试。"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Button(L("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 580)
        .background(.regularMaterial)
        .task { await loadPreview() }
    }

    private func loadPreview() async {
        isLoading = true
        result = await store.previewCharacterRecall(
            conversationID: conversationID,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isLoading = false
    }
}
