import SwiftUI

/// 「机器人」页的子栏目。2026-10-26 起把原本的单页长列表拆成子栏目：
/// 状态与基础开关、触发方式、唤醒与互动、名单、节奏（频率/时段/拟人化）、
/// 定时任务与语音。
enum BotTab: String, CaseIterable, Identifiable, PageTabItem {
    case general
    case trigger
    case interaction
    case lists
    case rhythm
    case schedules
    case voice

    var id: String { rawValue }

    var tabTitle: String {
        switch self {
        case .general: "常规"
        case .trigger: "触发"
        case .interaction: "互动"
        case .lists: "名单"
        case .rhythm: "节奏"
        case .schedules: "定时"
        case .voice: "语音"
        }
    }

    var tabSymbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .trigger: "bolt.fill"
        case .interaction: "hand.tap.fill"
        case .lists: "checklist"
        case .rhythm: "gauge.with.dots.needle.33percent"
        case .schedules: "calendar.badge.clock"
        case .voice: "waveform"
        }
    }

    var tabHelp: String? {
        switch self {
        case .general: "运行状态、基础开关与默认人格"
        case .trigger: "群聊触发方式与关键词"
        case .interaction: "唤醒窗口与拍一拍回复"
        case .lists: "白名单与黑名单"
        case .rhythm: "频率、工作时间与拟人化"
        case .schedules: "定时向指定会话发送固定内容"
        case .voice: "语音转写、TTS 与音色"
        }
    }
}

/// 机器人：状态、策略、名单、节奏、定时任务与语音，按子栏目组织，减少单页滚动。
struct BotView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    /// 子栏目选择按窗口记忆：切到别的页面再回来仍停留在上次的分栏。
    @SceneStorage("bot.subTab") private var selectedTabID: String = BotTab.general.rawValue

    @State private var newKeyword = ""

    /// 唤醒窗口的快捷时长（分钟）；其余数值用 Slider 调整。
    private static let wakeWindowPresets = [1, 3, 5, 10, 30, 60]

    var body: some View {
        VStack(spacing: 0) {
            GlassToolbar(title: "机器人", subtitle: subtitle) {
                Button(L("保存设置")) {
                    store.persist()
                    toast.show("机器人设置已保存", tone: .success)
                }
                .buttonStyle(.glass)

                Button {
                    toggleBot()
                } label: {
                    Label(L(store.isBotRunning ? "停止" : "启动"), systemImage: store.isBotRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(store.isBotRunning ? Theme.danger : Theme.accent)
            }

            // 分栏条不随内容滚动，始终可切换；`.id(selectedTab)` 让切换后回到顶部。
            PageTabBar(tabs: BotTab.allCases, selection: selectedTabBinding)
                .accessibilityLabel(L("机器人子栏目"))
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 10)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    tabContent
                }
                .padding(Theme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selectedTab)
            .scrollIndicators(.automatic)
        }
        .background(PageBackground())
        .onAppear {
            // 子栏目 key 被外部改坏时回落到「常规」，避免停留在空白分栏。
            if BotTab(rawValue: selectedTabID) == nil {
                selectedTabID = BotTab.general.rawValue
            }
        }
        .onDisappear { store.persist() }
    }

    // MARK: Sub-tabs

    private var selectedTab: BotTab {
        BotTab(rawValue: selectedTabID) ?? .general
    }

    private var selectedTabBinding: Binding<BotTab> {
        Binding(
            get: { selectedTab },
            set: { selectedTabID = $0.rawValue }
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            heroCard
            basicsCard
            defaultPersonaCard
        case .trigger:
            groupTriggerCard
        case .interaction:
            wakeAndPatCard
        case .lists:
            allowListCard
        case .rhythm:
            limitsCard
            workingHoursCard
            humanizeCard
        case .schedules:
            SchedulesPanel()
        case .voice:
            VoiceSettingsPanel()
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        GlassCard(tint: store.isBotRunning ? Theme.accent : Color.secondary) {
            HStack(alignment: .center, spacing: 15) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: store.isBotRunning
                                    ? [Theme.accent, Theme.accentStrong]
                                    : [Color.secondary.opacity(0.5), Color.secondary.opacity(0.28)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                    Image(systemName: store.isBotRunning ? "bolt.fill" : "bolt.slash.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: store.isBotRunning ? Theme.accent.opacity(0.3) : .clear, radius: 7, y: 3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(L(store.isBotRunning ? "机器人运行中" : "机器人已停止"))
                            .font(.title3.weight(.semibold))
                        PillLabel(
                            text: store.settings.bot.dryRun ? "演练模式" : "真实发送",
                            color: store.settings.bot.dryRun ? Theme.warning : Theme.success,
                            symbol: store.settings.bot.dryRun ? "eye" : "paperplane.fill"
                        )
                        if !store.settings.bot.enabled {
                            PillLabel(text: "配置已停用", color: .secondary)
                        }
                    }
                    Text(store.isBotRunning
                         ? "正在监听微信消息；符合触发条件时会按人设与上下文自动回复。可在页面顶部停止机器人。"
                         : "启动后连接本地 OneBot 服务，开始接收并自动回复微信消息。可在页面顶部启动机器人。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 5) {
                        StatusDot(
                            color: store.gatewayConnected ? Theme.success : .secondary,
                            size: 6,
                            pulsing: store.gatewayConnected
                        )
                        Text(L(store.gatewayConnected ? "OneBot 已连接" : "OneBot 未连接"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(store.hookStatus.state.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Basics

    private var basicsCard: some View {
        SectionCard(
            title: "基础开关",
            subtitle: "演练模式、私聊与忽略规则",
            symbol: "power",
            tint: Theme.info
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "演练模式",
                    subtitle: "只生成回复并写入日志，不真正发送到微信",
                    symbol: "eye",
                    tint: Theme.warning
                ) {
                    Toggle(L("演练模式"), isOn: bind(\.bot.dryRun))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "私聊自动回复",
                    subtitle: "开启后所有私聊都会自动回复",
                    symbol: "person.fill",
                    tint: Theme.accent
                ) {
                    Toggle(L("私聊自动回复"), isOn: bind(\.bot.replyToDirect))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "忽略自己发送的消息",
                    subtitle: "防止机器人回复自己，建议保持开启",
                    symbol: "person.crop.circle.badge.xmark",
                    tint: .secondary
                ) {
                    Toggle(L("忽略自己发送的消息"), isOn: bind(\.bot.ignoreSelf))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "忽略公众号消息",
                    subtitle: "公众号推送不进入自动回复流程",
                    symbol: "megaphone.fill",
                    tint: .secondary
                ) {
                    Toggle(L("忽略公众号消息"), isOn: bind(\.bot.ignoreOfficialAccounts))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Trigger

    private var groupTriggerCard: some View {
        SectionCard(
            title: "群聊触发",
            subtitle: "可多选；「所有消息」与其他方式互斥；「引用机器人」= 别人引用机器人发的消息时唤醒",
            symbol: "person.3.fill",
            tint: Theme.violet
        ) {
            VStack(alignment: .leading, spacing: 14) {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(TriggerMode.groupOptions) { mode in
                        FilterChip(
                            title: mode.groupLabel,
                            isSelected: selectedGroupTriggers.contains(mode),
                            tint: mode == .always ? Theme.warning : Theme.violet
                        ) {
                            toggleGroupTrigger(mode)
                        }
                        .help(mode == .quote
                              ? L("引用机器人：别人引用机器人发的消息时唤醒机器人（正文无需 @ 或关键词）")
                              : "")
                    }
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(L("群聊关键词"))
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(L(groupKeywordEnabled ? "已启用「关键词」触发" : "勾选「关键词」后生效"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !store.settings.bot.keywords.isEmpty {
                        FlowLayout(spacing: 5, lineSpacing: 5) {
                            ForEach(store.settings.bot.keywords, id: \.self) { keyword in
                                TagChip(title: keyword, tint: Theme.info) {
                                    removeKeyword(keyword)
                                }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        TextField(L("添加关键词，例如 AI"), text: $newKeyword)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addKeyword() }
                            .frame(maxWidth: 220)
                        Button(L("添加"), action: addKeyword)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    // MARK: Wake window & pat reply

    private var wakeAndPatCard: some View {
        SectionCard(
            title: "唤醒与互动",
            subtitle: "被唤醒后的免唤醒窗口与拍一拍回复",
            symbol: "hand.tap.fill",
            tint: Theme.info
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "唤醒后免唤醒词",
                    subtitle: "群聊被唤醒后，同一发送者在此时长内继续发言无需再次 @ / 关键词 / 引用；仅群聊生效",
                    symbol: "hourglass",
                    tint: Theme.info
                ) {
                    Toggle(L("唤醒后免唤醒词"), isOn: wakeWindowBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if store.settings.bot.wakeWindowEnabled {
                    wakeWindowEditor
                }
                SettingsDivider()
                SettingsRow(
                    title: "拍一拍回复",
                    subtitle: "别人拍机器人时，发送自定义文字和/或 AI 回复，可 @ 拍的人；不再回拍。",
                    symbol: "hand.tap.fill",
                    tint: Theme.info
                ) {
                    Toggle(L("拍一拍回复"), isOn: patReplyBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if store.settings.bot.patReplyEnabled {
                    patReplyEditor
                }
            }
        }
    }

    private var wakeWindowEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L("窗口时长"))
                    .font(.callout)
                Spacer()
                Text(Lf("%d 分钟", wakeWindowMinutes))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: wakeWindowSliderBinding, in: 1...60, step: 1)
                .tint(Theme.info)
                .accessibilityLabel(L("唤醒后免唤醒词"))
                .accessibilityValue(Lf("%d 分钟", wakeWindowMinutes))
            HStack(spacing: 5) {
                ForEach(Self.wakeWindowPresets, id: \.self) { minutes in
                    FilterChip(
                        title: Lf("%d 分钟", minutes),
                        isSelected: wakeWindowMinutes == minutes,
                        tint: Theme.info
                    ) {
                        setWakeWindowMinutes(minutes)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var patReplyEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("发送自定义文字"), isOn: patFixedTextBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
            if store.settings.bot.patFixedTextEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L("AI 前文字（留空不发送）"), text: patBeforeTextBinding)
                    TextField(L("AI 后文字（留空不发送）"), text: patAfterTextBinding)
                    Text(L("自定义文字支持 {name} 占位符（替换为对方昵称）。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .textFieldStyle(.roundedBorder)
            }
            Toggle(L("附带 AI 回复"), isOn: patAIBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle(L("群聊被拍后 @ 拍的人"), isOn: patMentionBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
            if store.settings.bot.patMentionPatterEnabled {
                Text(L("仅群聊生效；@ 附在第一条回复前（自定义前文字 → AI 首段 → 自定义后文字）。bridge 解析不到群昵称时按普通文本发送。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if store.settings.bot.patFixedTextEnabled || store.settings.bot.patAIEnabled {
                Text(L("发送顺序：自定义文字（前）→ AI 回复 → 自定义文字（后）；AI 失败时仍发送文字。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Allow / deny lists

    private var allowListCard: some View {
        SectionCard(
            title: "白名单 / 黑名单",
            subtitle: "统一填写会话 ID 或用户 wxid；白名单为空表示全部允许，黑名单优先",
            symbol: "checklist",
            tint: Theme.warning
        ) {
            VStack(alignment: .leading, spacing: 16) {
                IDListEditor(
                    title: "白名单",
                    subtitle: "只自动回复这些会话或发送者；留空表示全部允许。",
                    placeholder: "会话 ID 或用户 wxid",
                    items: whitelistBinding,
                    suggestions: conversationSuggestions
                )
                Divider().opacity(0.5)
                IDListEditor(
                    title: "黑名单",
                    subtitle: "这些会话或发送者永不自动回复，优先级高于白名单。",
                    placeholder: "会话 ID 或用户 wxid",
                    items: blacklistBinding,
                    suggestions: conversationSuggestions
                )

                if !conflictingIDs.isEmpty {
                    InlineNotice(
                        kind: .warning,
                        title: "白名单与黑名单存在重叠",
                        message: "以下 ID 同时出现在两个列表中，黑名单将生效：\(conflictingIDs.joined(separator: "、"))"
                    )
                }
            }
        }
    }

    private var conversationSuggestions: [(id: String, label: String)] {
        store.conversations.map { ($0.id, $0.displayTitle) }
    }

    private var whitelistBinding: Binding<[String]> {
        Binding(
            get: { store.settings.bot.effectiveWhitelist },
            set: { value in
                store.settings.bot.whitelistEntries = value
                store.persist()
            }
        )
    }

    private var blacklistBinding: Binding<[String]> {
        Binding(
            get: { store.settings.bot.effectiveBlacklist },
            set: { value in
                store.settings.bot.blacklistEntries = value
                store.persist()
            }
        )
    }

    private var conflictingIDs: [String] {
        let bot = store.settings.bot
        return Set(bot.effectiveWhitelist).intersection(Set(bot.effectiveBlacklist)).sorted()
    }

    // MARK: Limits

    private var limitsCard: some View {
        SectionCard(
            title: "频率与上下文",
            subtitle: "防止刷屏与 API 过载",
            symbol: "gauge.with.dots.needle.33percent",
            tint: Theme.violet
        ) {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(L("每条回复冷却"))
                            .font(.callout)
                        Spacer()
                        Text(Lf("%.0f 秒", store.settings.bot.cooldownSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: bind(\.bot.cooldownSeconds), in: 0...60, step: 1)
                        .tint(Theme.accent)
                        .accessibilityLabel(L("每条回复冷却时间"))
                        .accessibilityValue("\(Int(store.settings.bot.cooldownSeconds)) 秒")
                }

                HStack(spacing: 22) {
                    Stepper(
                        Lf("每分钟最多 %d 条回复", store.settings.bot.maxRepliesPerMinute),
                        value: bind(\.bot.maxRepliesPerMinute),
                        in: 1...60
                    )
                    .font(.callout)
                    Stepper(
                        Lf("临时记忆最多 %d 条 · 累计 %d 条旧消息后批量总结", store.settings.bot.maxContextMessages, ChatEngine.overflowBatchThreshold),
                        value: bind(\.bot.maxContextMessages),
                        in: 2...ChatEngine.shortTermMemoryLimit
                    )
                    .font(.callout)
                }
            }
        }
    }

    // MARK: Working hours

    private var workingHoursCard: some View {
        SectionCard(
            title: "工作时间",
            subtitle: "全局默认；非工作时段不自动回复，单个会话可在「会话」页覆盖",
            symbol: "clock",
            tint: Theme.warning
        ) {
            WorkingHoursEditor(mode: .global, hours: workingHoursBinding)
        }
    }

    /// 全局工作时间写入前统一收敛：越界分钟/星期、空星期与零长度窗口都兜底修正，
    /// 避免出现「看起来开着却永远不会生效」的配置。
    private var workingHoursBinding: Binding<WorkingHours> {
        Binding(
            get: { store.settings.bot.workingHours },
            set: { hours in
                store.settings.bot.workingHours = hours.sanitized
                store.persist()
            }
        )
    }

    // MARK: Humanize

    private var humanizeCard: some View {
        SectionCard(
            title: "拟人化",
            subtitle: "延迟与分段发送，让回复更像真人",
            symbol: "person.wave.2.fill",
            tint: Theme.accent
        ) {
            VStack(alignment: .leading, spacing: 13) {
                Toggle(L("启用拟人化（输入延迟 / 分段）"), isOn: bind(\.bot.humanize.enabled))
                    .toggleStyle(.switch)
                    .font(.callout)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(L("随机延迟范围"))
                            .font(.callout)
                        Spacer()
                        Text(Lf("%.1f – %.1f 秒",
                                    Double(store.settings.bot.humanize.minDelayMs) / 1000,
                                    Double(store.settings.bot.humanize.maxDelayMs) / 1000))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Slider(value: minDelayBinding, in: 0...5000, step: 100)
                            .tint(Theme.accent)
                            .accessibilityLabel(L("最小回复延迟"))
                        Slider(value: maxDelayBinding, in: 0...8000, step: 100)
                            .tint(Theme.accent)
                            .accessibilityLabel(L("最大回复延迟"))
                    }
                }

                HStack(spacing: 18) {
                    Toggle(L("拆分为多条消息"), isOn: bind(\.bot.humanize.splitMessages))
                        .toggleStyle(.switch)
                    Stepper(
                        Lf("最多 %d 段", store.settings.bot.humanize.maxSegments),
                        value: bind(\.bot.humanize.maxSegments),
                        in: 1...10
                    )
                    Toggle(L("显示输入中状态"), isOn: bind(\.bot.humanize.typingIndicator))
                        .toggleStyle(.switch)
                }
                .font(.callout)
                .disabled(!store.settings.bot.humanize.enabled)
                .opacity(store.settings.bot.humanize.enabled ? 1 : 0.55)
            }
        }
    }

    // MARK: Default persona

    private var defaultPersonaCard: some View {
        SectionCard(
            title: "默认人格",
            subtitle: "会话没有单独指定时使用；提示词在「人格设定」中编辑",
            symbol: "quote.bubble",
            tint: Theme.violet
        ) {
            HStack(spacing: 18) {
                Picker(L("默认人格"), selection: bind(\.bot.defaultPersonaID)) {
                    Text(L("跟随全局")).tag(String?.none)
                    ForEach(store.personas) { persona in
                        Text(persona.name).tag(Optional(persona.id))
                    }
                }
                .frame(maxWidth: 260)

                Text(L("默认通道在「AI 模型 → 默认通道」设置"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Bindings

    private func bind<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.settings[keyPath: keyPath] = newValue
                store.persist()
            }
        )
    }

    private var patReplyBinding: Binding<Bool> {
        Binding(
            get: { store.settings.bot.patReplyEnabled },
            set: { enabled in
                store.settings.bot.patReplyEnabled = enabled
                store.persist()
            }
        )
    }

    // MARK: Wake window

    private var wakeWindowBinding: Binding<Bool> {
        Binding(
            get: { store.settings.bot.wakeWindowEnabled },
            set: { enabled in
                store.settings.bot.wakeWindowEnabled = enabled
                store.persist()
            }
        )
    }

    private var wakeWindowMinutes: Int {
        min(60, max(1, Int((store.settings.bot.wakeWindowSeconds / 60).rounded())))
    }

    /// Slider 的 Double 绑定；快捷 chips 与 Slider 共用同一写入函数。
    private var wakeWindowSliderBinding: Binding<Double> {
        Binding(
            get: { Double(wakeWindowMinutes) },
            set: { value in
                setWakeWindowMinutes(Int(value.rounded()))
            }
        )
    }

    private func setWakeWindowMinutes(_ minutes: Int) {
        store.settings.bot.wakeWindowSeconds = Double(min(max(minutes, 1), 60)) * 60
        store.persist()
    }

    private var patFixedTextBinding: Binding<Bool> {
        Binding(
            get: { store.settings.bot.patFixedTextEnabled },
            set: { enabled in
                store.settings.bot.patFixedTextEnabled = enabled
                store.persist()
            }
        )
    }

    private var patAIBinding: Binding<Bool> {
        Binding(
            get: { store.settings.bot.patAIEnabled },
            set: { enabled in
                store.settings.bot.patAIEnabled = enabled
                store.persist()
            }
        )
    }

    private var patMentionBinding: Binding<Bool> {
        Binding(
            get: { store.settings.bot.patMentionPatterEnabled },
            set: { enabled in
                store.settings.bot.patMentionPatterEnabled = enabled
                store.persist()
            }
        )
    }

    private var patBeforeTextBinding: Binding<String> {
        Binding(
            get: { store.settings.bot.patBeforeText },
            set: { text in
                store.settings.bot.patBeforeText = text
                store.persist()
            }
        )
    }

    private var patAfterTextBinding: Binding<String> {
        Binding(
            get: { store.settings.bot.patAfterText },
            set: { text in
                store.settings.bot.patAfterText = text
                store.persist()
            }
        )
    }

    private var minDelayBinding: Binding<Double> {
        Binding(
            get: { Double(store.settings.bot.humanize.minDelayMs) },
            set: { value in
                let v = Int(value)
                store.settings.bot.humanize.minDelayMs = v
                if store.settings.bot.humanize.maxDelayMs < v {
                    store.settings.bot.humanize.maxDelayMs = v
                }
                store.persist()
            }
        )
    }

    private var maxDelayBinding: Binding<Double> {
        Binding(
            get: { Double(store.settings.bot.humanize.maxDelayMs) },
            set: { value in
                let v = Int(value)
                store.settings.bot.humanize.maxDelayMs = v
                if store.settings.bot.humanize.minDelayMs > v {
                    store.settings.bot.humanize.minDelayMs = v
                }
                store.persist()
            }
        )
    }

    // MARK: Group triggers

    private var selectedGroupTriggers: Set<TriggerMode> {
        Set(store.settings.bot.effectiveGroupTriggers)
    }

    private var groupKeywordEnabled: Bool {
        selectedGroupTriggers.contains(.keyword)
    }

    /// 「所有消息」独占，其余多选；始终至少保留一种触发方式。
    private func toggleGroupTrigger(_ mode: TriggerMode) {
        var selected = selectedGroupTriggers
        if mode == .always {
            selected = [.always]
        } else {
            selected.remove(.always)
            if selected.contains(mode) {
                guard selected.count > 1 else { return }
                selected.remove(mode)
            } else {
                selected.insert(mode)
            }
        }
        let ordered = TriggerMode.groupOptions.filter { selected.contains($0) }
        store.settings.bot.groupTriggers = ordered
        // 同步旧字段，供历史版本/外部读取。
        store.settings.bot.groupTrigger = ordered.first ?? .mention
        store.persist()
    }

    // MARK: Actions

    private var subtitle: String {
        let state = L(store.isBotRunning ? "运行中" : "已停止")
        let mode = L(store.settings.bot.dryRun ? "演练模式" : "真实发送")
        let gateway = L(store.gatewayConnected ? "OneBot 已连接" : "OneBot 未连接")
        return Lf("%@ · %@ · %@", state, mode, gateway)
    }

    private func addKeyword() {
        let keyword = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        guard !store.settings.bot.keywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) else {
            newKeyword = ""
            return
        }
        store.settings.bot.keywords.append(keyword)
        newKeyword = ""
        store.persist()
    }

    private func removeKeyword(_ keyword: String) {
        store.settings.bot.keywords.removeAll { $0 == keyword }
        store.persist()
    }

    private func toggleBot() {
        Task {
            if store.isBotRunning {
                await store.stopBot()
                toast.show("机器人已停止", tone: .info)
            } else {
                await store.startBot()
                toast.show(store.isBotRunning ? "机器人已启动" : "启动请求已提交", tone: store.isBotRunning ? .success : .warning)
            }
        }
    }
}

// MARK: - ID list editor

/// Editable list of wxid / conversation IDs rendered as removable chips.
private struct IDListEditor: View {
    let title: String
    var subtitle: String?
    let placeholder: String
    @Binding var items: [String]
    var suggestions: [(id: String, label: String)] = []

    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(L(title))
                    .font(.callout.weight(.medium))
                Spacer()
                if !suggestions.isEmpty {
                    Menu(L("从会话选择")) {
                        ForEach(suggestions, id: \.id) { suggestion in
                            Button {
                                add(suggestion.id)
                            } label: {
                                if items.contains(suggestion.id) {
                                    Label(suggestion.label, systemImage: "checkmark")
                                } else {
                                    Text(suggestion.label)
                                }
                            }
                            .disabled(items.contains(suggestion.id))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption)
                }
            }

            if let subtitle {
                Text(L(subtitle))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if items.isEmpty {
                Text(L("未限制"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04), in: Capsule())
            } else {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(items, id: \.self) { item in
                        TagChip(title: displayName(item), tint: Theme.warning) {
                            remove(item)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField(placeholder, text: $newValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { add(newValue) }
                    .frame(maxWidth: 260)
                Button(L("添加")) {
                    add(newValue)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func displayName(_ id: String) -> String {
        if let suggestion = suggestions.first(where: { $0.id == id }) {
            return suggestion.label
        }
        return id
    }

    private func add(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !items.contains(value) else {
            newValue = ""
            return
        }
        items.append(value)
        newValue = ""
    }

    private func remove(_ value: String) {
        items.removeAll { $0 == value }
    }
}
