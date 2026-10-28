import SwiftUI

/// 会话工作时间相对全局的来源。三种状态互斥，同一时间只有一种被选中。
///
/// 保存到 `Conversation.workingHours` 的映射见 `savedValue(custom:)`：
/// 跟随全局 → `nil`；不限时段 → `WorkingHours(enabled: false)`；自定义 → 收敛后的时段。
enum WorkingHoursChoice: String, CaseIterable, Identifiable {
    case followGlobal
    case custom
    case unrestricted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followGlobal: "跟随全局"
        case .custom: "自定义时段"
        case .unrestricted: "不限时段"
        }
    }

    /// 每个状态的一句话说明，在会话编辑器中始终可见，避免用户只能从名称猜测语义。
    var explanation: String {
        switch self {
        case .followGlobal:
            "使用「机器人 → 节奏 → 工作时间」的全局设置，全局改动会同步生效。"
        case .custom:
            "为这个会话单独设置时段，不再受全局设置影响。"
        case .unrestricted:
            "这个会话在任何时间都允许自动回复，规则引擎不会因时间拦截。"
        }
    }

    var symbol: String {
        switch self {
        case .followGlobal: "globe"
        case .custom: "clock.badge.checkmark"
        case .unrestricted: "infinity"
        }
    }

    /// 从会话覆盖值（`nil` 表示跟随全局）推导当前状态。
    init(_ hours: WorkingHours?) {
        switch hours {
        case nil:
            self = .followGlobal
        case let hours? where !hours.enabled:
            self = .unrestricted
        default:
            self = .custom
        }
    }

    /// 保存到 `Conversation.workingHours` 的映射。
    func savedValue(custom: WorkingHours) -> WorkingHours? {
        switch self {
        case .followGlobal: nil
        case .custom: custom.sanitized
        case .unrestricted: WorkingHours(enabled: false)
        }
    }
}

/// 可复用的工作时间编辑器。
///
/// - `.global`：只有「启用 / 不限时段」+ 时段编辑，用于「机器人 → 节奏 → 工作时间」。
/// - `.conversation(global:)`：三态来源（跟随全局 / 自定义时段 / 不限时段）+ 时段编辑，
///   用于会话级弹窗；同一时间只有一种来源被选中。
///
/// 编辑器统一负责：当前生效状态徽标、时段摘要、星期多选（不允许清空）、开始/结束时间、
/// 快捷预设、零长度窗口自动顺延提示，以及「全局默认 vs 会话覆盖」的说明。
struct WorkingHoursEditor: View {
    enum Mode: Equatable {
        case global
        case conversation(global: WorkingHours)
    }

    let mode: Mode
    @Binding private var hours: WorkingHours
    @Binding private var choice: WorkingHoursChoice

    /// 尝试取消最后一个星期时显示提示，而不是真的清空（清空会让 `contains` 永远 false）。
    @State private var weekdayWarning = false
    /// 开始 == 结束被自动顺延后的结束分钟；nil 表示当前没有触发。
    @State private var zeroLengthAdjustedEnd: Int?

    init(
        mode: Mode,
        hours: Binding<WorkingHours>,
        choice: Binding<WorkingHoursChoice> = .constant(.custom)
    ) {
        self.mode = mode
        _hours = hours
        _choice = choice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let global = conversationGlobal {
                choiceSection(global: global)
                statusSection
                if choice == .custom {
                    scheduleSection
                    if !global.enabled {
                        InlineNotice(
                            kind: .warning,
                            title: "自定义会开启时间限制",
                            message: "全局当前为「不限时段」；保存后这个会话将只在 \(effectiveHours.summaryText) 自动回复。"
                        )
                    }
                }
                validationNotices
                InlineNotice(
                    kind: .info,
                    title: "全局默认 vs 会话覆盖",
                    message: "会话设置优先于全局：选「跟随全局」时同步全局；选「自定义时段」或「不限时段」后，此会话不再随全局变化。"
                )
            } else {
                globalEnabledToggle
                statusSection
                if hours.enabled {
                    scheduleSection
                }
                validationNotices
                InlineNotice(
                    kind: .info,
                    title: "全局默认",
                    message: "这里是全局默认时段，只影响没有单独设置的会话；单个会话可在「会话」页覆盖或设为「不限时段」。"
                )
            }
        }
    }

    // MARK: 模式判断

    private var conversationGlobal: WorkingHours? {
        if case let .conversation(global) = mode { return global }
        return nil
    }

    private var isScheduleEditable: Bool {
        conversationGlobal == nil ? hours.enabled : choice == .custom
    }

    /// 保存后会真正生效的时段：跟随全局用全局值，自定义强制启用，不限时段关闭。
    private var effectiveHours: WorkingHours {
        guard let global = conversationGlobal else { return hours }
        switch choice {
        case .followGlobal:
            return global
        case .unrestricted:
            return WorkingHours(enabled: false)
        case .custom:
            var draft = hours
            draft.enabled = true
            return draft.sanitized
        }
    }

    // MARK: 来源三态

    private func choiceSection(global: WorkingHours) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(WorkingHoursChoice.allCases) { option in
                choiceRow(option, global: global)
            }
        }
    }

    private func choiceRow(_ option: WorkingHoursChoice, global: WorkingHours) -> some View {
        let selected = choice == option
        return Button {
            select(option)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Theme.warning : Color.secondary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selected ? Theme.warning : Color.secondary)
                        Text(L(option.title))
                            .font(.callout.weight(selected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    Text(L(option.explanation))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if option == .followGlobal {
                        Text(Lf("当前全局：%@", global.summaryText))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.warning.opacity(0.09) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selected ? Theme.warning.opacity(0.45) : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: 状态与摘要

    private var statusSection: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 5) {
                if let global = conversationGlobal {
                    HStack(spacing: 6) {
                        Text(L("当前全局："))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(global.summaryText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Text(L("保存后此会话："))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        let status = effectiveHours.status(at: context.date)
                        PillLabel(text: status.label, color: status.tint, symbol: status.symbol)
                        Text(effectiveHours.summaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(L("当前状态："))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        let status = hours.status(at: context.date)
                        PillLabel(text: status.label, color: status.tint, symbol: status.symbol)
                        Text(hours.summaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: 全局启用开关

    private var globalEnabledToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L("启用工作时间限制"), isOn: enabledBinding)
                .toggleStyle(.switch)
                .font(.callout)
            Text(L("关闭后为「不限时段」：任何时间都会自动回复；单个会话仍可在「会话」页单独覆盖。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { hours.enabled },
            set: { isOn in
                var draft = hours
                draft.enabled = isOn
                if isOn {
                    if draft.weekdays.isEmpty { draft.weekdays = Set(1...7) }
                    if draft.startMinute == draft.endMinute {
                        draft.endMinute = (draft.startMinute + 60) % 1440
                        zeroLengthAdjustedEnd = draft.endMinute
                    }
                }
                weekdayWarning = false
                commit(draft)
            }
        )
    }

    // MARK: 时段编辑

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                ForEach(UIFormat.weekdayOptions, id: \.value) { option in
                    FilterChip(
                        title: option.label,
                        isSelected: hours.weekdays.contains(option.value),
                        tint: Theme.warning
                    ) {
                        toggleWeekday(option.value)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 14) {
                DatePicker(
                    L("开始"),
                    selection: minuteBinding(\.startMinute),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    L("结束"),
                    selection: minuteBinding(\.endMinute),
                    displayedComponents: .hourAndMinute
                )
                Spacer(minLength: 0)
            }

            presetRow

            Text(L("跨夜时段会自动识别；结束分钟不计入时段（如 09:00–18:00 到 18:00 结束）。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            Text(L("快捷"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            FilterChip(title: "每天 9–23", isSelected: matchesDailyPreset, tint: Theme.warning) {
                applyPreset(startMinute: 9 * 60, endMinute: 23 * 60, weekdays: Set(1...7))
            }
            FilterChip(title: "工作日 9–18", isSelected: matchesWorkdayPreset, tint: Theme.warning) {
                applyPreset(startMinute: 9 * 60, endMinute: 18 * 60, weekdays: Set(2...6))
            }
            FilterChip(title: "不限时段", isSelected: isUnrestricted, tint: Theme.warning) {
                applyUnlimitedPreset()
            }
            Spacer(minLength: 0)
        }
    }

    private var isUnrestricted: Bool {
        conversationGlobal == nil ? !hours.enabled : choice == .unrestricted
    }

    private var matchesDailyPreset: Bool {
        hours.enabled
            && hours.weekdays == Set(1...7)
            && hours.startMinute == 9 * 60
            && hours.endMinute == 23 * 60
    }

    private var matchesWorkdayPreset: Bool {
        hours.enabled
            && hours.weekdays == Set(2...6)
            && hours.startMinute == 9 * 60
            && hours.endMinute == 18 * 60
    }

    // MARK: 校验提示

    @ViewBuilder
    private var validationNotices: some View {
        if let end = zeroLengthAdjustedEnd {
            InlineNotice(
                kind: .warning,
                title: "已自动顺延结束时间",
                message: "开始与结束相同会形成零长度时段（规则永远不会命中），已把结束时间顺延到 \(WorkingHours.minuteText(end))。"
            )
        }
        if weekdayWarning {
            InlineNotice(
                kind: .warning,
                title: "至少保留一天",
                message: conversationGlobal == nil
                    ? "如需在任何时间都自动回复，请关闭「启用工作时间限制」。"
                    : "如需在任何时间都自动回复，请选择「不限时段」。"
            )
        }
        if isScheduleEditable, hours.needsRepair {
            VStack(alignment: .leading, spacing: 6) {
                InlineNotice(
                    kind: .danger,
                    title: "时段配置无效",
                    message: "当前时段包含非法分钟/星期，或启用后永远不会命中；可一键修复为有效设置。"
                )
                Button(L("修复设置")) { repair() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    // MARK: 操作

    private func select(_ option: WorkingHoursChoice) {
        guard conversationGlobal != nil, choice != option else { return }
        choice = option
        weekdayWarning = false
        zeroLengthAdjustedEnd = nil
        guard option == .custom else { return }
        var draft = hours
        draft.enabled = true
        if draft.weekdays.isEmpty { draft.weekdays = Set(1...7) }
        if draft.startMinute == draft.endMinute {
            draft.endMinute = (draft.startMinute + 60) % 1440
            zeroLengthAdjustedEnd = draft.endMinute
        }
        commit(draft)
    }

    private func applyPreset(startMinute: Int, endMinute: Int, weekdays: Set<Int>) {
        if conversationGlobal != nil { choice = .custom }
        var draft = hours
        draft.enabled = true
        draft.startMinute = startMinute
        draft.endMinute = endMinute
        draft.weekdays = weekdays
        zeroLengthAdjustedEnd = nil
        weekdayWarning = false
        commit(draft)
    }

    private func applyUnlimitedPreset() {
        zeroLengthAdjustedEnd = nil
        weekdayWarning = false
        if conversationGlobal != nil {
            choice = .unrestricted
        } else {
            var draft = hours
            draft.enabled = false
            commit(draft)
        }
    }

    /// 会话自定义模式始终按「启用」保存；全局模式保留用户关闭限制的选择。
    private func commit(_ draft: WorkingHours) {
        var value = draft
        if conversationGlobal != nil, choice == .custom {
            value.enabled = true
        }
        hours = value.sanitized
    }

    private func repair() {
        var draft = hours
        if conversationGlobal != nil, choice == .custom {
            draft.enabled = true
        }
        zeroLengthAdjustedEnd = nil
        weekdayWarning = false
        hours = draft.sanitized
    }

    private func toggleWeekday(_ weekday: Int) {
        var draft = hours
        if draft.weekdays.contains(weekday) {
            guard draft.weekdays.count > 1 else {
                weekdayWarning = true
                return
            }
            draft.weekdays.remove(weekday)
        } else {
            draft.weekdays.insert(weekday)
            weekdayWarning = false
        }
        zeroLengthAdjustedEnd = nil
        commit(draft)
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<WorkingHours, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = hours[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                var draft = hours
                draft[keyPath: keyPath] = minute
                var adjustedEnd: Int?
                if draft.startMinute == draft.endMinute {
                    draft.endMinute = (draft.startMinute + 60) % 1440
                    adjustedEnd = draft.endMinute
                }
                zeroLengthAdjustedEnd = adjustedEnd
                weekdayWarning = false
                commit(draft)
            }
        )
    }
}

// MARK: - 统一状态文案

extension WorkingHours.Status {
    /// 徽标、编辑器与全局卡片共用的统一文案。
    /// 注意：`PillLabel` 会自己调用 `L()`，这里返回源语言 key。
    var label: String {
        switch self {
        case .unrestricted: "不限时段"
        case .active: "工作时段"
        case .paused: "非工作时段"
        }
    }

    var symbol: String {
        switch self {
        case .unrestricted: "infinity"
        case .active: "clock.fill"
        case .paused: "clock.badge.xmark"
        }
    }

    var tint: Color {
        switch self {
        case .unrestricted: .secondary
        case .active: Theme.success
        case .paused: Theme.warning
        }
    }
}
