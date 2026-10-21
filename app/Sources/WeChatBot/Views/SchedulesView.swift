import SwiftUI

/// 定时任务：列表 + 新建/编辑 + 下次执行时间。
struct SchedulesView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var filter: ScheduleFilter = .all
    @State private var editingTask: ScheduledTask?
    @State private var isEditingNew = false
    @State private var pendingDelete: ScheduledTask?

    enum ScheduleFilter: String, CaseIterable, Identifiable {
        case all
        case enabled
        case disabled

        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "全部"
            case .enabled: "启用"
            case .disabled: "停用"
            }
        }
    }

    var body: some View {
        ScrollingPage(title: "定时任务", subtitle: subtitle) {
            Button {
                addTask()
            } label: {
                Label(L("新建任务"), systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
        } content: {
            if store.schedules.isEmpty {
                GlassCard {
                    EmptyState(
                        symbol: "calendar.badge.clock",
                        title: "还没有定时任务",
                        message: "可以定时向某个会话发送消息，例如每日问候、整点提醒。",
                        actionTitle: "新建定时任务"
                    ) {
                        addTask()
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(ScheduleFilter.allCases) { option in
                        FilterChip(
                            title: option.label,
                            count: count(for: option),
                            isSelected: filter == option,
                            tint: Theme.info
                        ) {
                            filter = option
                        }
                    }
                    Spacer()
                }

                if filteredTasks.isEmpty {
                    EmptyState(
                        symbol: "calendar.badge.clock",
                        title: "没有匹配的任务",
                        message: "切换筛选条件查看其他任务。"
                    )
                } else {
                    VStack(spacing: 9) {
                        ForEach(filteredTasks) { task in
                            ScheduleRow(
                                task: task,
                                nextFire: task.nextFireAt ?? ScheduleMath.nextFire(for: task),
                                conversationLabel: conversationLabel(for: task),
                                onToggle: { enabled in setEnabled(task, enabled) },
                                onEdit: {
                                    isEditingNew = false
                                    editingTask = task
                                },
                                onDelete: { pendingDelete = task }
                            )
                        }
                    }
                }
            }

            InlineNotice(
                kind: .info,
                title: "执行条件",
                message: "定时任务由 App 内调度器执行，仅当机器人运行且 OneBot 已连接时才会真正发送。时间以系统时区为准。"
            )
        }
        .sheet(item: $editingTask) { task in
            ScheduleEditorSheet(task: task, isNew: isEditingNew) { updated in
                save(updated)
            }
        }
        .confirmationDialog(
            "删除定时任务",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { task in
            Button(L("删除") + " \(task.name)", role: .destructive) {
                delete(task)
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text(L("删除后不会再触发，历史发送记录保留。"))
        }
    }

    private var subtitle: String {
        let enabled = store.schedules.filter(\.enabled).count
        return "\(store.schedules.count) 个任务 · \(enabled) 个启用"
    }

    private var filteredTasks: [ScheduledTask] {
        var list = store.schedules
        switch filter {
        case .all: break
        case .enabled: list = list.filter(\.enabled)
        case .disabled: list = list.filter { !$0.enabled }
        }
        return list.sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled }
            let lhsNext = lhs.nextFireAt ?? ScheduleMath.nextFire(for: lhs) ?? .distantFuture
            let rhsNext = rhs.nextFireAt ?? ScheduleMath.nextFire(for: rhs) ?? .distantFuture
            return lhsNext < rhsNext
        }
    }

    private func count(for filter: ScheduleFilter) -> Int {
        switch filter {
        case .all: store.schedules.count
        case .enabled: store.schedules.filter(\.enabled).count
        case .disabled: store.schedules.filter { !$0.enabled }.count
        }
    }

    /// 任务目标会话的展示名：优先按当前会话解析，避免旧任务里存下的 wxid 标题直接露出。
    private func conversationLabel(for task: ScheduledTask) -> String? {
        if let conversation = store.conversations.first(where: { $0.id == task.conversationID }) {
            return conversation.displayTitle
        }
        guard !task.conversationID.isEmpty else { return nil }
        let kind: ConversationKind = task.conversationID.contains("@chatroom") ? .group : .direct
        return ConversationName.displayTitle(
            kind: kind,
            conversationID: task.conversationID,
            storedTitle: task.conversationTitle
        )
    }

    private func addTask() {
        var draft = ScheduledTask(
            name: "新任务",
            enabled: true,
            conversationID: store.conversations.first?.id ?? "",
            conversationTitle: store.conversations.first?.displayTitle ?? "",
            content: ""
        )
        draft.id = UUID().uuidString
        isEditingNew = true
        editingTask = draft
    }

    private func save(_ task: ScheduledTask) {
        if let index = store.schedules.firstIndex(where: { $0.id == task.id }) {
            store.schedules[index] = task
            toast.show("定时任务已保存", tone: .success)
        } else {
            store.schedules.append(task)
            toast.show("定时任务已添加", tone: .success)
        }
        store.persist()
    }

    private func setEnabled(_ task: ScheduledTask, _ enabled: Bool) {
        guard let index = store.schedules.firstIndex(where: { $0.id == task.id }) else { return }
        store.schedules[index].enabled = enabled
        store.persist()
    }

    private func delete(_ task: ScheduledTask) {
        pendingDelete = nil
        store.schedules.removeAll { $0.id == task.id }
        store.persist()
        toast.show("定时任务已删除", tone: .info, symbol: "trash")
    }
}

/// Add / edit sheet for a scheduled message.
struct ScheduleEditorSheet: View {
    let task: ScheduledTask
    let isNew: Bool
    let onSave: (ScheduledTask) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScheduledTask
    @State private var usesManualConversation: Bool
    @State private var manualConversationID = ""
    @State private var manualConversationTitle = ""
    @State private var validationMessage: String?

    init(task: ScheduledTask, isNew: Bool, onSave: @escaping (ScheduledTask) -> Void) {
        self.task = task
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: task)
        _usesManualConversation = State(initialValue: task.conversationID.isEmpty)
        _manualConversationID = State(initialValue: task.conversationID)
        _manualConversationTitle = State(initialValue: task.conversationTitle)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: "calendar.badge.clock", tint: Theme.info, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(isNew ? "新建定时任务" : "编辑定时任务")).font(.headline)
                    Text(L("按计划向指定会话发送消息"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    FormField(label: "任务名称") {
                        TextField(L("例如：每日早安问候"), text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    FormField(
                        label: "目标会话",
                        hint: usesManualConversation ? "手动输入会话 ID；标题仅用于列表展示。" : "选择一个已同步的会话"
                    ) {
                        VStack(alignment: .leading, spacing: 7) {
                            Toggle(L("手动输入会话 ID"), isOn: $usesManualConversation)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                            if usesManualConversation {
                                HStack(spacing: 8) {
                                    TextField(L("会话 ID / wxid / xxx@chatroom"), text: $manualConversationID)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption, design: .monospaced))
                                    TextField(L("显示名称（可选）"), text: $manualConversationTitle)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 160)
                                }
                            } else if store.conversations.isEmpty {
                                Text(L("暂无已同步会话，请先连接微信或改用手动输入。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker(L("目标会话"), selection: conversationIDBinding) {
                                    ForEach(store.conversations) { conversation in
                                        Text(conversation.displayTitle).tag(conversation.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 320)
                            }
                        }
                    }

                    FormField(label: "发送内容") {
                        TextEditor(text: $draft.content)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 110)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Theme.hairline, lineWidth: 1)
                            }
                            .accessibilityLabel(L("发送内容"))
                    }

                    FormField(label: "重复方式") {
                        Picker(L("重复方式"), selection: $draft.repeatRule) {
                            ForEach(ScheduleRepeat.allCases) { repeatRule in
                                Text(repeatRule.label).tag(repeatRule)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    if draft.repeatRule == .weekly {
                        FormField(label: "星期", hint: "选择任务在一周中哪些天执行") {
                            HStack(spacing: 5) {
                                ForEach(UIFormat.weekdayOptions, id: \.value) { option in
                                    FilterChip(
                                        title: option.label,
                                        isSelected: draft.weekdays.contains(option.value),
                                        tint: Theme.info
                                    ) {
                                        toggleWeekday(option.value)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }

                    FormField(
                        label: draft.repeatRule == .once ? "执行时间" : "每日时间",
                        hint: draft.repeatRule == .once ? "仅执行一次" : "以后每天/每周在该时间执行"
                    ) {
                        DatePicker(
                            "执行时间",
                            selection: $draft.fireAt,
                            displayedComponents: draft.repeatRule == .once ? [.date, .hourAndMinute] : [.hourAndMinute]
                        )
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }

                    if let next = ScheduleMath.nextFire(for: draft) {
                        InlineNotice(
                            kind: .success,
                            title: "下次执行",
                            message: "\(UIFormat.fullDateTime.string(from: next))（\(UIFormat.relative(next))）→ \(targetTitle)"
                        )
                    } else {
                        InlineNotice(
                            kind: .warning,
                            title: "尚未安排执行",
                            message: draft.enabled
                                ? "当前设置不会产生下一次执行时间，请检查重复方式与时间。"
                                : "任务已停用，启用后会按计划执行。"
                        )
                    }

                    if let validationMessage {
                        InlineNotice(kind: .danger, title: "无法保存", message: validationMessage)
                    }

                    Toggle(L("启用此任务"), isOn: $draft.enabled)
                        .toggleStyle(.switch)
                        .font(.callout)
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 9) {
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "添加任务" : "保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 620, height: 720)
        .background(.regularMaterial)
        .onChange(of: draft.repeatRule) { _, newValue in
            if newValue != .once, draft.fireAt < Date() {
                draft.fireAt = Date().addingTimeInterval(60)
            }
        }
    }

    private var conversationIDBinding: Binding<String> {
        Binding(
            get: { draft.conversationID },
            set: { newValue in
                draft.conversationID = newValue
                if let conversation = store.conversations.first(where: { $0.id == newValue }) {
                    draft.conversationTitle = conversation.displayTitle
                }
            }
        )
    }

    private var targetTitle: String {
        if usesManualConversation {
            return manualConversationTitle.isEmpty ? manualConversationID : manualConversationTitle
        }
        if let conversation = store.conversations.first(where: { $0.id == draft.conversationID }) {
            return conversation.displayTitle
        }
        guard !draft.conversationID.isEmpty else { return "未选择会话" }
        return ConversationName.displayTitle(
            kind: draft.conversationID.contains("@chatroom") ? .group : .direct,
            conversationID: draft.conversationID,
            storedTitle: draft.conversationTitle
        )
    }

    private func toggleWeekday(_ value: Int) {
        if draft.weekdays.contains(value) {
            draft.weekdays.removeAll { $0 == value }
        } else {
            draft.weekdays.append(value)
        }
    }

    private func save() {
        var candidate = draft
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)

        if usesManualConversation {
            candidate.conversationID = manualConversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            candidate.conversationTitle = manualConversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let conversation = store.conversations.first(where: { $0.id == candidate.conversationID }) {
            // 保存时刷新展示名，避免旧任务把 wxid 标题一直留在数据库/列表里。
            candidate.conversationTitle = conversation.displayTitle
        }

        guard !candidate.name.isEmpty else {
            validationMessage = "请填写任务名称。"
            return
        }
        guard !candidate.conversationID.isEmpty else {
            validationMessage = "请选择目标会话或填写会话 ID。"
            return
        }
        guard !candidate.content.isEmpty else {
            validationMessage = "请填写要发送的内容。"
            return
        }
        if candidate.repeatRule == .weekly, candidate.weekdays.isEmpty {
            validationMessage = "每周重复至少需要选择一个星期。"
            return
        }
        if candidate.repeatRule == .once, candidate.fireAt <= Date() {
            validationMessage = "一次性任务的执行时间必须晚于当前时间。"
            return
        }

        validationMessage = nil
        onSave(candidate)
        dismiss()
    }
}
