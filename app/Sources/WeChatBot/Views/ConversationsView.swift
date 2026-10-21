import SwiftUI

/// 会话：会话列表 + 聊天详情 + 输入区。三栏由主窗口侧边栏、会列表和详情组成。
struct ConversationsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var search = ""
    @State private var filter: ConversationFilter = .all
    @State private var draft = ""
    @State private var isSending = false
    @State private var workingHoursTarget: Conversation?
    @State private var renameTarget: Conversation?
    /// Coalesces deferred programmatic scrolling (see `scheduleScrollToBottom`).
    @State private var autoScrollTask: Task<Void, Never>?

    enum ConversationFilter: String, CaseIterable, Identifiable {
        case all
        case unread
        case aiOn

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "全部"
            case .unread: "未读"
            case .aiOn: "AI 开启"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            conversationList
                .frame(width: Theme.listWidth)
                .background(.ultraThinMaterial)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .accessibilityHidden(true)

            chatDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PageBackground())
        .onAppear { selectFirstIfNeeded() }
        .onDisappear { autoScrollTask?.cancel() }
        .onChange(of: store.selectedConversationID) { _, newValue in
            // nil 是用户「再次点击当前会话行收起对话」的合法状态，不再自动选回第一条。
            guard let newValue else { return }
            markRead(conversationID: newValue)
        }
        .sheet(item: $workingHoursTarget) { conversation in
            ConversationWorkingHoursSheet(
                conversationTitle: conversation.displayTitle,
                current: conversation.workingHours,
                global: store.settings.bot.workingHours
            ) { hours in
                setWorkingHours(hours, for: conversation)
            }
        }
        .sheet(item: $renameTarget) { conversation in
            ConversationRenameSheet(conversation: conversation) { name in
                rename(conversation, to: name)
            }
        }
    }

    // MARK: Conversation list

    private var conversationList: some View {
        // Derived once per body instead of re-filtering/re-sorting for the empty
        // check and the ForEach separately.
        let visibleConversations = filteredConversations
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L("会话"))
                        .font(.system(.title3, design: .default, weight: .semibold))
                    Spacer(minLength: 4)
                    if totalUnread > 0 {
                        PillLabel(text: "\(totalUnread) 未读", color: Theme.accent)
                    }
                }
                SearchField(text: $search, placeholder: "搜索会话或消息")
                HStack(spacing: 5) {
                    ForEach(ConversationFilter.allCases) { option in
                        FilterChip(
                            title: option.label,
                            count: count(for: option),
                            isSelected: filter == option
                        ) {
                            filter = option
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider().opacity(0.5)

            if visibleConversations.isEmpty {
                EmptyState(
                    symbol: store.conversations.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                    title: store.conversations.isEmpty ? "还没有会话" : "没有匹配的会话",
                    message: store.conversations.isEmpty
                        ? "连接微信后，私聊与群聊会自动出现在这里。"
                        : "尝试调整搜索关键词或筛选条件。"
                )
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visibleConversations) { conversation in
                            SessionRow(
                                conversation: conversation,
                                isSelected: store.selectedConversationID == conversation.id,
                                replyProgress: store.replyProgress[conversation.id],
                                onSelect: { select(conversation) }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.automatic)
            }

            Divider().opacity(0.5)
            connectionFooter
        }
    }

    private var connectionFooter: some View {
        HStack(spacing: 5) {
            StatusDot(
                color: store.gatewayConnected ? Theme.success : .secondary,
                size: 6,
                pulsing: store.gatewayConnected
            )
            Text(store.gatewayConnected ? "OneBot 已连接" : "OneBot 未连接")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(L("\(store.conversations.count) 个会话"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    // MARK: Chat detail

    @ViewBuilder
    private var chatDetail: some View {
        if let conversation = selectedConversation {
            VStack(spacing: 0) {
                chatHeader(conversation)
                Divider().opacity(0.5)
                messageList(conversation)
                composer(conversation)
            }
        } else {
            VStack {
                Spacer()
                EmptyState(
                    symbol: "bubble.left.and.bubble.right",
                    title: "选择一个会话",
                    message: "从左侧选择一个聊天，查看消息并在需要时手动发送回复；再次点击当前会话行可收起对话。",
                    actionTitle: store.conversations.isEmpty ? "启动机器人" : nil
                ) {
                    store.sidebarSelection = .bot
                }
                Spacer()
            }
        }
    }

    private func chatHeader(_ conversation: Conversation) -> some View {
        HStack(spacing: 9) {
            AvatarView(title: conversation.displayTitle, kind: conversation.kind, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(conversation.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    PillLabel(text: conversation.kind.label, color: Theme.info)
                    if conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    WorkingHoursBadge(
                        workingHours: conversation.effectiveWorkingHours(
                            global: store.settings.bot.workingHours
                        ),
                        isOverride: conversation.usesCustomWorkingHours
                    )
                }
                HStack(spacing: 6) {
                    Text(conversation.id)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let progress = store.replyProgress[conversation.id] {
                        ReplyStatusBadge(progress: progress)
                    }
                }
            }
            Spacer(minLength: 8)

            Toggle(
                "AI 自动回复",
                isOn: Binding(
                    get: { conversation.aiEnabled },
                    set: { _ in toggleAI(conversation) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)
            .help(L("控制此会话是否自动回复"))

            Menu {
                Section("人格") {
                    Button {
                        setPersona(nil, for: conversation)
                    } label: {
                        Label(L("跟随默认"), systemImage: conversation.personaID == nil ? "checkmark" : "person.crop.circle")
                    }
                    ForEach(store.personas) { persona in
                        Button {
                            setPersona(persona.id, for: conversation)
                        } label: {
                            Label(persona.name, systemImage: conversation.personaID == persona.id ? "checkmark" : "circle")
                        }
                    }
                }
                Section("工作时间") {
                    Button {
                        setWorkingHours(nil, for: conversation)
                    } label: {
                        Label(L("跟随全局"), systemImage: conversation.workingHours == nil ? "checkmark" : "clock")
                    }
                    Button {
                        workingHoursTarget = conversation
                    } label: {
                        Label(
                            conversation.workingHours == nil ? "自定义时段…" : "编辑自定义时段…",
                            systemImage: "clock.badge.checkmark"
                        )
                    }
                    Button {
                        setWorkingHours(WorkingHours(enabled: false), for: conversation)
                    } label: {
                        Label(L("此会话不限制"), systemImage: "infinity")
                    }
                }
                Section("名称") {
                    Button {
                        renameTarget = conversation
                    } label: {
                        Label(L("重命名会话…"), systemImage: "pencil")
                    }
                    if conversation.customTitle != nil {
                        Button {
                            rename(conversation, to: "")
                        } label: {
                            Label(L("恢复自动名称"), systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                Section("会话") {
                    Button(conversation.isPinned ? "取消置顶" : "置顶会话") {
                        togglePin(conversation)
                    }
                    Button(L("标记为已读")) {
                        markRead(conversationID: conversation.id)
                    }
                    .disabled(conversation.unreadCount == 0)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("会话设置"))
            .accessibilityLabel(L("会话设置"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func messageList(_ conversation: Conversation) -> some View {
        let messages = store.messages[conversation.id] ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if messages.isEmpty {
                        EmptyState(
                            symbol: "text.bubble",
                            title: "还没有消息",
                            message: "微信收到的新消息会实时出现在这里。"
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || message.timestamp.timeIntervalSince(messages[index - 1].timestamp) > 300 {
                                DateSeparator(date: message.timestamp)
                                    .equatable()
                            }
                            MessageBubble(
                                message: message,
                                showsSender: conversation.kind == .group
                            )
                            .equatable()
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("conversation-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            // NOTE: `.defaultScrollAnchor(.bottom)` is intentionally gone. It re-anchors
            // the scroll view on every content-size change, which keeps a LazyVStack
            // dirty while it prefetches (crash stack: LazyLayoutViewCache.signalPrefetch
            // -> NSHostingView.requestUpdate -> setNeedsUpdateConstraints). The bottom
            // position is restored explicitly after the layout update instead.
            .onChange(of: messages.last?.id) { _, _ in
                scheduleScrollToBottom(proxy)
            }
            .onChange(of: conversation.id) { _, _ in
                scheduleScrollToBottom(proxy, delay: .zero)
            }
            .onAppear {
                scheduleScrollToBottom(proxy, delay: .zero)
            }
        }
    }

    private func composer(_ conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)

            // 回复流水线状态：AI 生成耗时、拟人化发送倒计时、bridge 回执与失败原因。
            if let progress = store.replyProgress[conversation.id] {
                ReplyProgressBar(
                    progress: progress,
                    r3Active: store.hookStatus.r3Active,
                    r3Seeded: store.hookStatus.r3Seeded,
                    r3Queued: store.hookStatus.r3Queued,
                    onDismiss: { store.dismissReplyProgress(conversationID: conversation.id) }
                )
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            VStack(spacing: 7) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(L("输入消息…"), text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1...6)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 1)
                        }
                        .accessibilityLabel(L("消息输入框"))

                    Button {
                        send(to: conversation)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(canSend ? Theme.accent : Color.primary.opacity(0.08))
                                .frame(width: 30, height: 30)
                            if isSending {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(canSend ? .white : Color.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help(L("发送消息（⌘↩）"))
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityLabel(L("发送消息"))
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 4)

                    if store.gatewayConnected {
                        Text(L("⌘↩ 发送"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Label(L("服务未连接，手动发送已禁用"), systemImage: "bolt.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: Derived

    private var selectedConversation: Conversation? {
        store.selectedConversation
    }

    private var filteredConversations: [Conversation] {
        var list = store.conversations
        switch filter {
        case .all: break
        case .unread: list = list.filter { $0.unreadCount > 0 }
        case .aiOn: list = list.filter(\.aiEnabled)
        }
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            list = list.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(keyword)
                    || $0.lastMessagePreview.localizedCaseInsensitiveContains(keyword)
                    || $0.id.localizedCaseInsensitiveContains(keyword)
            }
        }
        return list.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast)
        }
    }

    private var totalUnread: Int {
        store.conversations.reduce(0) { $0 + max(0, $1.unreadCount) }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending
            && store.gatewayConnected
    }

    private func count(for filter: ConversationFilter) -> Int {
        switch filter {
        case .all: store.conversations.count
        case .unread: store.conversations.filter { $0.unreadCount > 0 }.count
        case .aiOn: store.conversations.filter(\.aiEnabled).count
        }
    }

    /// 把自动滚动推迟到当前布局周期之外执行，并合并连续消息到达产生的多次滚动请求。
    /// 在懒惰容器的布局过程中直接 `scrollTo` 会再次触发 lazy prefetch / 布局更新，
    /// 正是 AppKit display-cycle 布局次数超限崩溃的触发路径。
    /// - Parameter delay: 新消息到达时留出一小段时间让 layout 收敛；切换会话/首次出现
    ///   只需等到下一个 main-actor tick，避免用户看到列表先停在顶部的闪烁。
    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, delay: Duration = .milliseconds(50)) {
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    // MARK: Actions

    private func selectFirstIfNeeded() {
        if store.selectedConversationID == nil
            || !store.conversations.contains(where: { $0.id == store.selectedConversationID }) {
            let id = filteredConversations.first?.id ?? store.conversations.first?.id
            store.selectedConversationID = id
            if let id { markRead(conversationID: id) }
        }
    }

    /// 点击会话行：未选中时打开；已选中时再次点击收起当前对话（回到空状态）。
    private func select(_ conversation: Conversation) {
        if store.selectedConversationID == conversation.id {
            store.selectedConversationID = nil
            return
        }
        store.selectedConversationID = conversation.id
        markRead(conversationID: conversation.id)
    }

    private func toggleAI(_ conversation: Conversation) {
        guard var updated = store.conversations.first(where: { $0.id == conversation.id }) else { return }
        updated.aiEnabled.toggle()
        store.saveConversation(updated)
    }

    private func setPersona(_ personaID: String?, for conversation: Conversation) {
        guard var updated = store.conversations.first(where: { $0.id == conversation.id }) else { return }
        updated.personaID = personaID
        store.saveConversation(updated)
    }

    private func setWorkingHours(_ hours: WorkingHours?, for conversation: Conversation) {
        guard var updated = store.conversations.first(where: { $0.id == conversation.id }) else { return }
        updated.workingHours = hours
        store.saveConversation(updated)
        if let hours {
            toast.show(
                hours.enabled ? "已保存此会话的工作时段" : "此会话已取消工作时间限制",
                tone: .success,
                symbol: "clock.badge.checkmark"
            )
        } else {
            toast.show("此会话已跟随全局工作时间", tone: .success, symbol: "clock")
        }
    }

    private func togglePin(_ conversation: Conversation) {
        guard var updated = store.conversations.first(where: { $0.id == conversation.id }) else { return }
        updated.isPinned.toggle()
        store.saveConversation(updated)
    }

    /// 保存用户起的会话名；空字符串表示恢复自动名称（见 `ConversationName`）。
    private func rename(_ conversation: Conversation, to name: String) {
        guard var updated = store.conversations.first(where: { $0.id == conversation.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.title = trimmed
        store.saveConversation(updated)
        if trimmed.isEmpty {
            toast.show("已恢复自动名称「\(updated.displayTitle)」", tone: .success, symbol: "arrow.uturn.backward")
        } else {
            toast.show("已重命名为「\(trimmed)」", tone: .success, symbol: "pencil")
        }
    }

    /// 标记指定会话为已读。按 id 读取 store 的最新状态，而不是使用行视图的快照，
    /// 避免「消息刚到时行未刷新 → 第一次点击无效 → 需要点第二次」的问题。
    private func markRead(conversationID: String) {
        guard let index = store.conversations.firstIndex(where: { $0.id == conversationID }),
              store.conversations[index].unreadCount > 0
        else { return }
        var updated = store.conversations[index]
        updated.unreadCount = 0
        store.saveConversation(updated)
    }

    private func send(to conversation: Conversation) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard store.gatewayConnected else {
            toast.show("OneBot 服务未连接，请先启动机器人", tone: .warning)
            return
        }
        draft = ""
        isSending = true
        Task {
            await store.sendManualMessage(conversationID: conversation.id, text: text)
            isSending = false
            toast.show("消息已提交发送", tone: .success, symbol: "paperplane.fill")
        }
    }
}
