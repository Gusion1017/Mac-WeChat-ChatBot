import SwiftUI

/// 「机器人 → 主动」：会话静默后由 AI 主动开口的完整设置面板。
///
/// 与「定时任务」区分：定时任务是固定时间发固定内容；主动聊天在会话静默后由 AI
/// 结合人格、最近聊天与记忆现场生成内容，因此这里配置的是「什么时候可以发、
/// 对谁发、发多频繁、发什么方向」，而不是具体某条消息。
struct ProactiveChatPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var newTopic = ""

    private var settings: ProactiveChatSettings {
        store.settings.bot.proactiveSettings
    }

    var body: some View {
        statusCard
        targetsCard
        rhythmCard
        windowCard
        contentCard
    }

    // MARK: 状态

    /// 至少一个主动对象当前处于其生效时段内（会话独立 > 全局工作时间 > 主动页）。
    private var isAnyTargetInWindow: Bool {
        let now = Date()
        return settings.normalizedConversationIDs.contains { id in
            guard let conversation = store.conversations.first(where: { $0.id == id }) else {
                return false
            }
            return ProactiveChatPlanner.isWithinWindow(
                settings: settings,
                bot: store.settings.bot,
                conversation: conversation,
                now: now
            )
        }
    }

    private var statusCard: some View {
        SectionCard(
            title: "主动聊天",
            symbol: "hand.wave.fill",
            tint: Theme.violet,
            trailing: {
                Toggle(L("启用主动聊天"), isOn: boolBinding(\.enabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("静默够久后，由 AI 结合人格、最近聊天与记忆现场生成一条消息；不是定时任务。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if settings.enabled {
                        PillLabel(
                            text: isAnyTargetInWindow ? "当前在生效时段" : "当前不在生效时段",
                            color: isAnyTargetInWindow ? Theme.info : .secondary,
                            symbol: isAnyTargetInWindow ? "clock.fill" : "clock.badge.xmark"
                        )
                    }
                    PillLabel(
                        text: Lf("今日已发 %d 条", store.proactiveSentToday),
                        color: Theme.violet,
                        symbol: "paperplane.fill"
                    )
                    if let last = store.proactiveLastSentAt {
                        Text(Lf("上次 %@", Self.timeFormatter.string(from: last)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }

                if let checkedAt = store.proactiveLastCheckAt, !store.proactiveLastCheckNote.isEmpty {
                    Text(Lf("上次检查 %@：%@",
                            Self.timeFormatter.string(from: checkedAt),
                            store.proactiveLastCheckNote))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if settings.enabled {
                    if settings.normalizedConversationIDs.isEmpty {
                        InlineNotice(
                            kind: .warning,
                            title: "未选择主动对象",
                            message: "没有选中任何会话，不会发送消息。"
                        )
                    }
                    if store.defaultProvider == nil {
                        InlineNotice(
                            kind: .warning,
                            title: "未配置 AI 通道",
                            message: "请先在「AI 模型」配置默认通道。"
                        )
                    }
                    if !store.isBotRunning {
                        InlineNotice(
                            kind: .info,
                            title: "机器人未运行",
                            message: "启动机器人后才会开始检查。"
                        )
                    }
                }
            }
        }
    }

    // MARK: 对象

    private var targetsCard: some View {
        SectionCard(
            title: "主动对象",
            subtitle: "私聊、群聊均可选择；未选择时不会发送",
            symbol: "person.2.fill",
            tint: Theme.info
        ) {
            VStack(alignment: .leading, spacing: 13) {
                let selected = settings.normalizedConversationIDs
                if selected.isEmpty {
                    Text(L("未选择任何会话"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.04), in: Capsule())
                } else {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(selected, id: \.self) { id in
                            TagChip(title: displayName(for: id), tint: tint(for: id)) {
                                removeTarget(id)
                            }
                        }
                    }
                }

                let candidates = targetCandidates
                if candidates.isEmpty {
                    Text(L("暂无可选会话；启动机器人并收到消息后会出现在这里。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Menu {
                        ForEach(candidates) { conversation in
                            Button {
                                addTarget(conversation.id)
                            } label: {
                                if selected.contains(conversation.id) {
                                    Label(conversation.displayTitle, systemImage: "checkmark")
                                } else {
                                    Text(conversation.displayTitle)
                                }
                            }
                            .disabled(selected.contains(conversation.id))
                        }
                    } label: {
                        Label(L("从会话选择…"), systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

            }
        }
    }

    // MARK: 节奏

    /// 静默时长的快捷选项（分钟）。
    private static let idlePresets = [30, 60, 3 * 60, 6 * 60, 12 * 60, 24 * 60, 2 * 24 * 60, 3 * 24 * 60, 7 * 24 * 60]

    private var rhythmCard: some View {
        SectionCard(
            title: "节奏与上限",
            subtitle: "静默多久才主动，以及每个会话每天最多发几条",
            symbol: "gauge.with.dots.needle.33percent",
            tint: Theme.accent
        ) {
            VStack(alignment: .leading, spacing: 16) {
                idleSection
                SettingsDivider()
                dailyLimitSection

                Text(Lf("生成或发送失败后会固定等待 %@ 再重试，避免反复调用 AI。",
                        ProactiveChatSettings.idleLabel(minutes: ProactiveChatSettings.retryBackoffMinutes)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsDivider()

                SettingsRow(
                    title: "对方未回复时不再主动",
                    subtitle: "上一条主动消息发出后对方还没回，就跳过该会话，避免自说自话和催促感。",
                    symbol: "bubble.left.and.exclamationmark.bubble.right",
                    tint: Theme.warning
                ) {
                    Toggle(L("对方未回复时不再主动"), isOn: boolBinding(\.skipIfUnanswered))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    /// 静默时长：快捷预设 + 精确微调；不再用一条 15 分钟–7 天的大范围 Slider。
    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L("静默多久后主动"))
                    .font(.callout.weight(.medium))
                Spacer()
                Text(ProactiveChatSettings.idleLabel(minutes: settings.idleMinutes))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            Text(L("最后一条消息距今超过该时长才考虑；主动发送后会重新计时。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(Self.idlePresets, id: \.self) { minutes in
                    FilterChip(
                        title: ProactiveChatSettings.idleLabel(minutes: minutes),
                        isSelected: settings.idleMinutes == minutes,
                        tint: Theme.accent
                    ) {
                        setSetting(\.idleMinutes, minutes)
                    }
                }
            }

            Stepper(
                value: intBinding(\.idleMinutes),
                in: ProactiveChatSettings.idleMinutesRange,
                step: idleStep
            ) {
                Text(L("微调"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(Lf("每次调整 %@", ProactiveChatSettings.idleLabel(minutes: idleStep)))
            }
        }
    }

    /// 每日上限：只限制每个会话自己的条数，不设跨会话合计上限。
    private var dailyLimitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("每个会话每日上限"))
                .font(.callout.weight(.medium))

            Stepper(
                value: intBinding(\.maxPerConversationPerDay),
                in: ProactiveChatSettings.dailyPerConversationRange
            ) {
                Text(Lf("这个会话每天最多主动 %d 条", settings.maxPerConversationPerDay))
                    .font(.callout)
                    .monospacedDigit()
            }

            Text(L("每个会话单独计算，不同会话不共享额度。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 静默时长的微调步长：短时长精细一点，长时长按小时调整。
    private var idleStep: Int {
        let value = settings.idleMinutes
        if value < 60 { return 15 }
        if value < 24 * 60 { return 30 }
        return 60
    }

    // MARK: 时段

    private var windowCard: some View {
        SectionCard(
            title: "发送时段",
            subtitle: "优先级：会话独立时段 → 节奏的工作时间 → 本页时段（兜底）",
            symbol: "clock",
            tint: Theme.warning
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L("启用主动页时段（兜底）"), isOn: hourBinding(\.enabled))
                    .toggleStyle(.switch)
                    .font(.callout)

                Text(L("仅当前两级时段都未启用时生效；不影响正常自动回复。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 5) {
                    ForEach(UIFormat.weekdayOptions, id: \.value) { option in
                        FilterChip(
                            title: option.label,
                            isSelected: settings.activeHours.weekdays.contains(option.value),
                            tint: Theme.warning
                        ) {
                            toggleWeekday(option.value)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .disabled(!settings.activeHours.enabled)
                .opacity(settings.activeHours.enabled ? 1 : 0.5)

                HStack(spacing: 16) {
                    DatePicker(
                        L("开始"),
                        selection: timeBinding(isStart: true),
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        L("结束"),
                        selection: timeBinding(isStart: false),
                        displayedComponents: .hourAndMinute
                    )
                    Spacer(minLength: 0)
                    Text(L("跨夜自动识别；结束等于开始时顺延 1 小时"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .disabled(!settings.activeHours.enabled)
                .opacity(settings.activeHours.enabled ? 1 : 0.5)

                HStack(spacing: 6) {
                    Text(L("快捷"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    FilterChip(title: "每天 9–23", isSelected: false, tint: Theme.warning) {
                        applyWindow(start: 9 * 60, end: 23 * 60, weekdays: Set(1...7))
                    }
                    FilterChip(title: "工作日 9–18", isSelected: false, tint: Theme.warning) {
                        applyWindow(start: 9 * 60, end: 18 * 60, weekdays: [2, 3, 4, 5, 6])
                    }
                    Spacer(minLength: 0)
                }

                if !settings.normalizedConversationIDs.isEmpty {
                    Divider().opacity(0.5)
                    Text(L("各对象实际时段"))
                        .font(.callout.weight(.medium))
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(settings.normalizedConversationIDs.prefix(5)), id: \.self) { id in
                            HStack(spacing: 8) {
                                Text(displayName(for: id))
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(effectiveWindowSummary(for: id))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if settings.normalizedConversationIDs.count > 5 {
                            Text(Lf("…另有 %d 个主动对象", settings.normalizedConversationIDs.count - 5))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 内容

    private var contentCard: some View {
        SectionCard(
            title: "聊什么",
            subtitle: "主动权提示词与可选话题；最终消息由 AI 生成",
            symbol: "text.bubble.fill",
            tint: Theme.info
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("主动权提示词"))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button(L("恢复默认")) {
                        var updated = settings
                        updated.prompt = ProactiveChatSettings.defaultPrompt
                        store.settings.bot.proactiveSettings = updated
                        store.persist()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                TextEditor(text: promptBinding)
                    .font(.callout)
                    .frame(minHeight: 86)
                    .padding(6)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    }
                    .accessibilityLabel(L("主动权提示词"))

                Text(L("会和人格、最近聊天与记忆一起交给模型；写「怎么开口」，不要写死具体内容。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.5)

                Text(L("可选话题（最多 8 个，留空由 AI 决定）"))
                    .font(.callout.weight(.medium))
                if !settings.normalizedTopics.isEmpty {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(settings.normalizedTopics, id: \.self) { topic in
                            TagChip(title: topic, tint: Theme.info) {
                                removeTopic(topic)
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField(L("例如：周末计划、最近的考试、天气"), text: $newTopic)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTopic() }
                        .frame(maxWidth: 280)
                    Button(L("添加"), action: addTopic)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(newTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || settings.normalizedTopics.count >= ProactiveChatSettings.maxTopics)
                }
            }
        }
    }

    // MARK: 会话辅助

    private var targetCandidates: [Conversation] {
        store.conversations
            .filter { $0.kind != .official }
            .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    }

    private func isDirectConversation(_ id: String) -> Bool {
        guard let conversation = store.conversations.first(where: { $0.id == id }) else {
            return !id.contains("@chatroom")
        }
        return conversation.kind == .direct
    }

    /// 该会话实际使用的主动时段摘要（会话独立 > 全局工作时间 > 主动页时段）。
    private func effectiveWindowSummary(for id: String) -> String {
        guard let conversation = store.conversations.first(where: { $0.id == id }) else {
            return L("会话未加载")
        }
        let window = ProactiveChatPlanner.effectiveWindow(
            settings: settings,
            bot: store.settings.bot,
            conversation: conversation
        )
        guard let hours = window.hours else { return L(window.source.label) }
        return "\(L(window.source.label)) · \(hours.summaryText)"
    }

    private func displayName(for id: String) -> String {
        store.conversations.first(where: { $0.id == id })?.displayTitle ?? id
    }

    private func tint(for id: String) -> Color {
        isDirectConversation(id) ? Theme.info : .secondary
    }

    private func addTarget(_ id: String) {
        var updated = settings
        guard !updated.normalizedConversationIDs.contains(id) else { return }
        updated.conversationIDs.append(id)
        store.settings.bot.proactiveSettings = updated
        store.persist()
    }

    private func removeTarget(_ id: String) {
        var updated = settings
        updated.conversationIDs.removeAll { $0 == id }
        store.settings.bot.proactiveSettings = updated
        store.persist()
    }

    private func addTopic() {
        let topic = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }
        var updated = settings
        guard updated.normalizedTopics.count < ProactiveChatSettings.maxTopics else {
            toast.show("最多添加 \(ProactiveChatSettings.maxTopics) 个话题", tone: .warning)
            return
        }
        updated.topics.append(topic)
        store.settings.bot.proactiveSettings = updated
        newTopic = ""
        store.persist()
    }

    private func removeTopic(_ topic: String) {
        var updated = settings
        updated.topics.removeAll { $0 == topic }
        store.settings.bot.proactiveSettings = updated
        store.persist()
    }

    private func applyWindow(start: Int, end: Int, weekdays: Set<Int>) {
        var updated = settings
        updated.activeHours.enabled = true
        updated.activeHours.startMinute = start
        updated.activeHours.endMinute = end
        updated.activeHours.weekdays = weekdays
        store.settings.bot.proactiveSettings = updated
        store.persist()
    }

    private func toggleWeekday(_ weekday: Int) {
        var updated = settings
        var days = updated.activeHours.weekdays
        if days.contains(weekday) {
            guard days.count > 1 else {
                toast.show("至少保留一天；如需完全不限制请关闭「启用主动页时段（兜底）」", tone: .warning)
                return
            }
            days.remove(weekday)
        } else {
            days.insert(weekday)
        }
        updated.activeHours.weekdays = days
        store.settings.bot.proactiveSettings = updated
        store.persist()
    }

    // MARK: 绑定

    private func boolBinding(_ keyPath: WritableKeyPath<ProactiveChatSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                var updated = settings
                updated[keyPath: keyPath] = value
                store.settings.bot.proactiveSettings = updated
                store.persist()
            }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<ProactiveChatSettings, Int>) -> Binding<Int> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                var updated = settings
                updated[keyPath: keyPath] = value
                store.settings.bot.proactiveSettings = updated
                store.persist()
            }
        )
    }

    /// 直接写入一个设置值（用于快捷预设）。
    private func setSetting<T>(_ keyPath: WritableKeyPath<ProactiveChatSettings, T>, _ value: T) {
        var updated = settings
        updated[keyPath: keyPath] = value
        store.settings.bot.proactiveSettings = updated
        store.persist()
    }

    private func hourBinding(_ keyPath: WritableKeyPath<WorkingHours, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.activeHours[keyPath: keyPath] },
            set: { value in
                var updated = settings
                updated.activeHours[keyPath: keyPath] = value
                store.settings.bot.proactiveSettings = updated
                store.persist()
            }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { settings.prompt },
            set: { value in
                var updated = settings
                updated.prompt = value
                store.settings.bot.proactiveSettings = updated
                store.persist()
            }
        )
    }

    private func timeBinding(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minutes = isStart
                    ? settings.activeHours.startMinute
                    : settings.activeHours.endMinute
                return Calendar.current.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                var updated = settings
                if isStart {
                    updated.activeHours.startMinute = minutes
                    if updated.activeHours.endMinute == minutes {
                        updated.activeHours.endMinute = (minutes + 60) % 1440
                    }
                } else {
                    updated.activeHours.endMinute = minutes
                    if updated.activeHours.startMinute == minutes {
                        updated.activeHours.startMinute = (minutes + 1380) % 1440
                    }
                }
                store.settings.bot.proactiveSettings = updated
                store.persist()
            }
        )
    }

    // MARK: 其他

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
