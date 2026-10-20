import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置：通用 / 外观 / 通知 / Hook / OneBot / 数据与备份 / 关于。
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var category: SettingsCategory = .general
    @State private var hookAction: HookAction?
    @State private var showToken = false
    @State private var isWorking = false
    @State private var progress: Double?
    @State private var progressMessage: String?
    @State private var sleepCenter = SleepPreventionCenter.shared

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case general
        case appearance
        case notifications
        case hook
        case onebot
        case data
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "通用"
            case .appearance: "外观"
            case .notifications: "通知"
            case .hook: "Hook"
            case .onebot: "OneBot"
            case .data: "数据与备份"
            case .about: "关于"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintbrush"
            case .notifications: "bell"
            case .hook: "link"
            case .onebot: "network"
            case .data: "externaldrive"
            case .about: "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .general: .secondary
            case .appearance: Theme.violet
            case .notifications: Theme.warning
            case .hook: Theme.info
            case .onebot: Theme.accent
            case .data: Theme.info
            case .about: .secondary
            }
        }
    }

    private enum HookAction: String, Identifiable {
        case install
        case restore

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassToolbar(title: "设置", subtitle: "WeChat AI \(appVersion) · 配置保存在本机") { EmptyView() }

            HStack(spacing: 0) {
                categorySidebar
                    .frame(width: 196)
                    .background(.ultraThinMaterial)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .accessibilityHidden(true)

                ScrollView {
                    content
                        .padding(Theme.pagePadding)
                        .frame(maxWidth: 780, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(PageBackground())
        .sheet(item: $hookAction) { action in
            switch action {
            case .install:
                ConfirmSheet(
                    title: "安装 Frida Gadget 到微信",
                    message: "此操作会修改官方微信的应用包。请先完全退出微信。",
                    details: [
                        "完整备份 /Applications/WeChat.app → 注入 Gadget → ad-hoc 重签。",
                        "微信更新后需要重新安装；部分功能可能受影响。",
                        "安装耗时约 1–2 分钟，期间请勿打开微信。",
                        "可在设置中从备份还原官方微信。"
                    ],
                    confirmTitle: "备份并安装"
                ) {
                    installHook()
                }
            case .restore:
                ConfirmSheet(
                    title: "还原官方微信",
                    message: "将使用安装 Hook 时创建的完整备份替换当前微信，并重新签名。",
                    details: [
                        "机器人会先停止，微信会被退出。",
                        "还原后需要重启微信；Hook 与桥接将不可用。",
                        "若备份不存在，操作会失败且不会修改微信。"
                    ],
                    confirmTitle: "还原备份"
                ) {
                    restoreBackup()
                }
            }
        }
    }

    // MARK: Sidebar

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            sidebarGroup("应用", items: [.general, .appearance, .notifications])
            sidebarGroup("集成", items: [.hook, .onebot])
            sidebarGroup("数据", items: [.data, .about])
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                Text("全部数据仅保存在本机")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(.top, 14)
        .padding(.horizontal, 8)
    }

    private func sidebarGroup(_ title: String, items: [SettingsCategory]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
                .padding(.bottom, 2)
            ForEach(items) { item in
                Button {
                    category = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 16)
                            .foregroundStyle(category == item ? Color.accentColor : Color.secondary)
                        Text(item.title)
                            .font(.system(size: 12.5, weight: category == item ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 2)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .background(
                        category == item ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == item ? [.isSelected] : [])
            }
        }
    }

    // MARK: Content router

    @ViewBuilder
    private var content: some View {
        switch category {
        case .general: generalSettings
        case .appearance: appearanceSettings
        case .notifications: notificationSettings
        case .hook: hookSettings
        case .onebot: oneBotSettings
        case .data: dataSettings
        case .about: aboutSettings
        }
    }

    // MARK: General

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(
                title: "启动与窗口",
                footer: "登录项需要 App 以 .app 形式安装后生效；Dock 图标切换会立即生效。关闭 Dock 图标后会保留菜单栏入口。"
            ) {
                SettingsRow(
                    title: "显示菜单栏图标",
                    subtitle: "在菜单栏快速查看状态、启停机器人",
                    symbol: "menubar.rectangle",
                    tint: Theme.accent
                ) {
                    Toggle("显示菜单栏图标", isOn: showInMenuBarBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "登录时启动",
                    subtitle: "开机后自动启动 WeChat AI",
                    symbol: "power",
                    tint: .secondary
                ) {
                    Toggle("登录时启动", isOn: bind(\.general.launchAtLogin))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "显示 Dock 图标",
                    subtitle: "关闭后仅保留菜单栏入口",
                    symbol: "dock.rectangle",
                    tint: .secondary
                ) {
                    Toggle("显示 Dock 图标", isOn: showDockIconBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "退出前确认",
                    subtitle: "机器人运行中退出时提醒",
                    symbol: "exclamationmark.circle",
                    tint: Theme.warning
                ) {
                    Toggle("退出前确认", isOn: bind(\.general.confirmBeforeQuit))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            if StageManagerSupport.isEnabled && !store.settings.general.showDockIcon {
                InlineNotice(
                    kind: .info,
                    title: "台前调度已开启",
                    message: "Dock 图标已按设置隐藏，App 不会出现在台前调度应用条；窗口隐藏后可从菜单栏图标重新打开。"
                )
            }

            SettingsSection(
                title: "节能与睡眠",
                footer: "仅阻止系统因空闲进入睡眠，不会阻止合盖睡眠、手动睡眠，也不会让显示器保持点亮。使用电池且选择「接入电源时」时不会阻止。"
            ) {
                SettingsRow(
                    title: "防止系统睡眠",
                    subtitle: "按当前电源状态阻止系统空闲睡眠",
                    symbol: "moon.zzz",
                    tint: Theme.violet
                ) {
                    VStack(alignment: .trailing, spacing: 5) {
                        Picker("防止系统睡眠", selection: sleepPreventionBinding) {
                            ForEach(SleepPreventionMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 330)

                        Text(store.settings.general.sleepPrevention.detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 330, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "当前状态",
                    subtitle: sleepStatusDetail,
                    symbol: "powerplug",
                    tint: sleepStatusTint
                ) {
                    PillLabel(text: sleepStatusText, color: sleepStatusTint, symbol: sleepStatusSymbol)
                }
            }

            if let lastError = sleepCenter.lastError {
                InlineNotice(kind: .warning, title: "防睡眠未生效", message: lastError)
            }

            SettingsSection(title: "语言") {
                SettingsRow(
                    title: "界面语言",
                    subtitle: "首版仅提供简体中文",
                    symbol: "character.bubble",
                    tint: Theme.info
                ) {
                    Picker("界面语言", selection: bind(\.general.language)) {
                        Text("简体中文").tag("zh-Hans")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            SettingsSection(title: "首次启动") {
                SettingsRow(
                    title: "重新打开首次启动向导",
                    subtitle: "检测微信、安装 Hook、配置 AI 与启动机器人",
                    symbol: "sparkles.rectangle.stack",
                    tint: Theme.accent
                ) {
                    Button("打开向导") {
                        store.isOnboardingPresented = true
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            // Re-assert the persisted preference when the page appears (launch already
            // did this, but the settings window can outlive external config edits).
            sleepCenter.apply(mode: store.settings.general.sleepPrevention)
        }
    }

    // MARK: Sleep prevention

    private var sleepPreventionBinding: Binding<SleepPreventionMode> {
        Binding(
            get: { store.settings.general.sleepPrevention },
            set: { newValue in
                store.settings.general.sleepPrevention = newValue
                sleepCenter.apply(mode: newValue)
                store.persist()
            }
        )
    }

    private var sleepStatusText: String {
        switch store.settings.general.sleepPrevention {
        case .never:
            "已关闭"
        default:
            sleepCenter.isPreventingSleep ? "已生效（阻止空闲睡眠）" : (sleepCenter.isOnExternalPower ? "未生效" : "未生效（使用电池）")
        }
    }

    private var sleepStatusDetail: String {
        switch store.settings.general.sleepPrevention {
        case .never:
            "不阻止系统按节能设置进入空闲睡眠"
        default:
            if sleepCenter.isPreventingSleep {
                "已持有防睡眠断言，Mac 不会因空闲自动睡眠"
            } else if !sleepCenter.isOnExternalPower {
                "当前使用电池，按设置不阻止睡眠"
            } else {
                "未能持有防睡眠断言，请查看下方错误信息"
            }
        }
    }

    private var sleepStatusTint: Color {
        switch store.settings.general.sleepPrevention {
        case .never:
            .secondary
        default:
            sleepCenter.isPreventingSleep ? Theme.success : Theme.warning
        }
    }

    private var sleepStatusSymbol: String {
        switch store.settings.general.sleepPrevention {
        case .never:
            "minus"
        default:
            sleepCenter.isPreventingSleep ? "checkmark" : "exclamationmark"
        }
    }

    // MARK: Appearance

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(
                title: "外观模式",
                footer: "选择「跟随系统」时，App 会实时响应 macOS 的浅色/深色切换。"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("外观模式", selection: bind(\.general.appearance)) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)

                    HStack(spacing: 10) {
                        ForEach(AppearanceMode.allCases) { mode in
                            appearancePreview(mode)
                        }
                    }
                }
                .padding(14)
            }

            SettingsSection(title: "辅助功能") {
                SettingsRow(
                    title: "减少动态效果",
                    subtitle: "由系统「辅助功能 → 显示」控制，App 会自动降级动画",
                    symbol: "waveform.path",
                    tint: Theme.violet
                ) {
                    PillLabel(
                        text: reduceMotion ? "已开启" : "关闭",
                        color: reduceMotion ? Theme.success : .secondary,
                        symbol: reduceMotion ? "checkmark" : "minus"
                    )
                }
                SettingsDivider()
                SettingsRow(
                    title: "动态字体",
                    subtitle: "界面使用语义字体，跟随系统文字大小设置",
                    symbol: "textformat.size",
                    tint: Theme.info
                ) {
                    PillLabel(text: "已支持", color: Theme.success, symbol: "checkmark")
                }
            }

            SettingsSection(title: "设计说明") {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Liquid Glass 卡片、半透明侧边栏与系统材质。", systemImage: "circle.lefthalf.filled")
                    Label("SF Symbols + SF Pro / 苹方系统字体，支持 1x / 2x 渲染。", systemImage: "textformat")
                    Label("中文排版：语义行距、宽松留白、克制动效。", systemImage: "character.textbox")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)
            }
        }
    }

    private func appearancePreview(_ mode: AppearanceMode) -> some View {
        let isSelected = store.settings.general.appearance == mode
        let background: Color = {
            switch mode {
            case .light: Color(white: 0.96)
            case .dark: Color(white: 0.13)
            case .system: Color(white: 0.55)
            }
        }()
        return Button {
            store.settings.general.appearance = mode
            store.persist()
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(background)
                        .frame(height: 48)
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(.white.opacity(0.14))
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.28)).frame(width: 34, height: 4)
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.18)).frame(width: 46, height: 4)
                        }
                        .padding(.leading, 7)
                        Spacer()
                    }
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2 : 1)
                }
                Text(mode.label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .frame(width: 108)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Notifications

    private var notificationSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(
                title: "通知",
                footer: "通知权限由 macOS 控制；首次开启时系统会请求授权。"
            ) {
                SettingsRow(
                    title: "启用通知",
                    subtitle: "收到新消息或机器人异常时提醒",
                    symbol: "bell.badge",
                    tint: Theme.warning
                ) {
                    Toggle("启用通知", isOn: bind(\.general.notificationsEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "通知声音",
                    subtitle: "发送通知时播放系统提示音",
                    symbol: "speaker.wave.2",
                    tint: Theme.info
                ) {
                    Toggle("通知声音", isOn: bind(\.general.soundEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!store.settings.general.notificationsEnabled)
                }
            }

            InlineNotice(
                kind: .info,
                title: "通知说明",
                message: "当前版本优先保证聊天窗口内的实时反馈；系统通知会在 Core 接入通知服务后按上述开关发送。"
            )
        }
    }

    // MARK: Hook

    private var hookSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(title: "微信与 Hook 状态") {
                hookStatusRow("微信版本", value: versionText, symbol: "iphone")
                SettingsDivider()
                hookStatusRow(
                    "微信进程",
                    value: store.hookStatus.wechatRunning ? "运行中" : "未运行",
                    symbol: "checkmark.seal",
                    tint: store.hookStatus.wechatRunning ? Theme.success : .secondary
                )
                SettingsDivider()
                hookStatusRow(
                    "Gadget",
                    value: store.hookStatus.gadgetInstalled ? "已安装" : "未安装",
                    symbol: "link",
                    tint: store.hookStatus.gadgetInstalled ? Theme.success : Theme.warning
                )
                SettingsDivider()
                hookStatusRow(
                    "Bridge",
                    value: store.hookStatus.bridgeRunning
                        ? "运行中\(store.hookStatus.bridgePID > 0 ? " · PID \(store.hookStatus.bridgePID)" : "")"
                        : "未运行",
                    symbol: "arrow.triangle.branch",
                    tint: store.hookStatus.bridgeRunning ? Theme.success : .secondary
                )
                SettingsDivider()
                hookStatusRow(
                    "网关连接",
                    value: store.hookStatus.gatewayConnected ? "已连接" : "未连接",
                    symbol: "network",
                    tint: store.hookStatus.gatewayConnected ? Theme.success : .secondary
                )
                SettingsDivider()
                hookStatusRow(
                    "版本匹配",
                    value: store.hookStatus.matchedVersion ? "已匹配" : "未匹配",
                    symbol: "checkmark.shield",
                    tint: store.hookStatus.matchedVersion ? Theme.success : Theme.warning
                )
                if store.hookStatus.r3Active || store.hookStatus.r3Seeded || !store.settings.hook.enableNativeSend {
                    SettingsDivider()
                    hookStatusRow(
                        "R3 原生发送",
                        value: store.hookStatus.r3Seeded
                            ? "句柄就绪"
                            : (store.hookStatus.r3Active ? "等待信号" : (store.settings.hook.enableNativeSend ? "待启动" : "已关闭")),
                        symbol: "paperplane",
                        tint: store.hookStatus.r3Seeded ? Theme.success : Theme.warning
                    )
                }
                if !store.hookStatus.detail.isEmpty {
                    SettingsDivider()
                    SettingsRow(title: "详情", symbol: "info.circle", tint: .secondary) {
                        Text(store.hookStatus.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 320, alignment: .trailing)
                    }
                }
            }

            if isWorking {
                ProgressPanel(
                    title: "正在处理微信 Hook",
                    detail: progressMessage ?? "备份、注入与重签中，请稍候…",
                    progress: progress
                )
            }

            SettingsSection(title: "安装与恢复") {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await store.refreshStatus() }
                        } label: {
                            Label("刷新状态", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .disabled(isWorking)

                        Button {
                            hookAction = .install
                        } label: {
                            Label("安装 Hook", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.warning)
                        .disabled(isWorking)

                        Button {
                            hookAction = .restore
                        } label: {
                            Label("还原官方微信", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.glass)
                        .tint(Theme.danger)
                        .disabled(isWorking)
                        Spacer()
                    }

                    Text("安装流程：完整备份 → 注入 Frida Gadget → ad-hoc 重签 → 校验。安装前请退出微信。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
            }

            InlineNotice(
                kind: .warning,
                title: "风险提示",
                message: "修改官方微信可能导致无法启动、无法更新或触发安全检查。请仅在了解风险的本机环境使用，并保留备份。"
            )

            SettingsSection(title: "路径与参数") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        FormField(label: "微信路径") {
                            TextField("/Applications/WeChat.app", text: bind(\.hook.wechatPath))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Button("选择…") { chooseWeChatApp() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    FormField(label: "版本配置文件", hint: "留空则自动匹配 hook/versions 中的版本配置") {
                        HStack(spacing: 8) {
                            TextField("自动匹配", text: bind(\.hook.versionConfigPath))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            Button("选择…") { chooseVersionConfig() }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                    }
                    SettingsRow(title: "Gadget 端口", symbol: "number", tint: .secondary) {
                        Stepper("\(store.settings.hook.gadgetPort)", value: bind(\.hook.gadgetPort), in: 1024...65_535)
                            .font(.caption)
                            .frame(width: 106)
                    }
                    SettingsDivider()
                    SettingsRow(title: "自动启动微信", subtitle: "机器人启动时若微信未运行则自动打开", symbol: "play.circle", tint: .secondary) {
                        Toggle("自动启动微信", isOn: bind(\.hook.autoLaunchWeChat))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(title: "自动启动 Bridge", subtitle: "机器人启动时自动拉起 OneBot 桥接进程", symbol: "arrow.triangle.branch", tint: .secondary) {
                        Toggle("自动启动 Bridge", isOn: bind(\.hook.autoStartBridge))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "R3 原生发送",
                        subtitle: "微信 4.1.15.55 专用（构造 newsendmsg task + slot13 提交）。首次使用前需在本机微信手动发一条消息以捕获发送句柄；排队消息会在拿到句柄后自动重发。",
                        symbol: "paperplane",
                        tint: .secondary
                    ) {
                        Toggle("R3 原生发送", isOn: bind(\.hook.enableNativeSend))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    PathRow(label: "最近备份", path: store.settings.hook.lastBackupPath, revealInFinder: true)
                }
                .padding(14)
            }
        }
    }

    private func hookStatusRow(_ title: String, value: String, symbol: String, tint: Color = .secondary) -> some View {
        SettingsRow(title: title, symbol: symbol, tint: tint) {
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var versionText: String {
        store.hookStatus.wechatVersion.isEmpty ? "未检测" : "微信 \(store.hookStatus.wechatVersion)"
    }

    // MARK: OneBot

    private var oneBotSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(
                title: "连接参数",
                footer: "仅监听本机回环地址；启动机器人后自动连接。Token 只保存在本机配置中。"
            ) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 12) {
                        FormField(label: "Host") {
                            TextField("127.0.0.1", text: bind(\.onebot.host))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 150)
                        }
                        FormField(label: "Port") {
                            TextField("58080", value: bind(\.onebot.port), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 100)
                        }
                        FormField(label: "连接类型") {
                            Picker("连接类型", selection: bind(\.onebot.connType)) {
                                Text("WebSocket").tag("websocket")
                                Text("HTTP").tag("http")
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                        Spacer()
                    }

                    FormField(label: "Token") {
                        HStack(spacing: 7) {
                            Group {
                                if showToken {
                                    TextField("token", text: bind(\.onebot.token))
                                } else {
                                    SecureField("token", text: bind(\.onebot.token))
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))

                            Button {
                                showToken.toggle()
                            } label: {
                                Image(systemName: showToken ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.glass)
                            .help(showToken ? "隐藏 Token" : "显示 Token")
                            CopyButton(text: store.settings.onebot.token, accessibilityText: "复制 Token")
                        }
                    }

                    FormField(label: "Bridge 可执行文件", hint: "留空时使用 App 内置 bridge；开发环境可指定绝对路径") {
                        TextField("内置 bridge", text: bind(\.onebot.bridgePath))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }

                    FormField(label: "图片临时目录", hint: "bridge 读取微信图片的目录，留空则自动探测") {
                        TextField("自动探测", text: bind(\.onebot.imagePath))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack(spacing: 8) {
                        Text("WS 地址")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(wsURL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        CopyButton(text: wsURL, accessibilityText: "复制 WS 地址")
                        Spacer()
                        Text(store.gatewayConnected ? "已连接" : "未连接")
                            .font(.caption2)
                            .foregroundStyle(store.gatewayConnected ? Theme.success : Color.secondary)
                    }
                }
                .padding(14)
            }

            InlineNotice(
                kind: .info,
                title: "安全",
                message: "OneBot 仅监听 127.0.0.1，不暴露到局域网。请勿将端口转发到公网；如更换 Token，需要同时更新正在运行的 bridge。"
            )
        }
    }

    private var wsURL: String {
        "ws://\(store.settings.onebot.host):\(store.settings.onebot.port)/ws"
    }

    // MARK: Data

    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(
                title: "本机数据",
                footer: "所有配置、聊天记忆与日志均保存在 Application Support，不上传云端。"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    PathRow(label: "数据目录", path: AppPaths.supportDirectory.path, revealInFinder: true)
                    PathRow(label: "配置文件", path: AppPaths.configFile.path, revealInFinder: true)
                    PathRow(label: "记忆数据库", path: AppPaths.databaseFile.path, revealInFinder: true)
                    PathRow(label: "日志目录", path: AppPaths.logsDirectory.path, revealInFinder: true)
                    PathRow(label: "备份目录", path: AppPaths.backupsDirectory.path, revealInFinder: true)
                    PathRow(label: "媒体目录", path: AppPaths.mediaDirectory.path, revealInFinder: true)
                }
                .padding(14)
            }

            SettingsSection(title: "备份与还原") {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 8) {
                        Button {
                            exportConfiguration()
                        } label: {
                            Label("导出配置", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)

                        Button {
                            NSWorkspace.shared.open(AppPaths.supportDirectory)
                        } label: {
                            Label("打开数据目录", systemImage: "folder")
                        }
                        .buttonStyle(.glass)

                        Button {
                            store.reload()
                            toast.show("已重新加载配置文件", tone: .success)
                        } label: {
                            Label("重新加载配置", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        Spacer()
                    }
                    Text("数据库与日志的完整备份请直接复制数据目录；微信官方备份由 Hook 安装流程自动创建。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if !store.settings.hook.lastBackupPath.isEmpty {
                        PathRow(label: "微信备份", path: store.settings.hook.lastBackupPath, revealInFinder: true)
                    }
                }
                .padding(14)
            }

            SettingsSection(title: "维护") {
                LogBufferMaintenanceRow()
            }
        }
    }

    // MARK: About

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            GlassCard {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.accent, Theme.accentStrong],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 68, height: 68)
                            .shadow(color: Theme.accent.opacity(0.3), radius: 10, y: 4)
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WeChat AI")
                            .font(.title2.weight(.semibold))
                        Text("微信 AI 聊天助手 · 原生 macOS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            PillLabel(text: "版本 \(appVersion)", color: Theme.accent)
                            PillLabel(text: "Build \(buildNumber)", color: .secondary)
                            PillLabel(text: "macOS 26+", color: Theme.info)
                        }
                    }
                    Spacer()
                }
            }

            SettingsSection(title: "运行信息") {
                aboutRow("Bundle ID", AppPaths.bundleID)
                SettingsDivider()
                aboutRow("系统版本", ProcessInfo.processInfo.operatingSystemVersionString)
                SettingsDivider()
                aboutRow("处理器架构", architecture)
                SettingsDivider()
                aboutRow("应用资源", Bundle.main.bundlePath)
            }

            SettingsSection(title: "技术栈与许可") {
                TechLinkRow(
                    title: "SwiftUI / Swift 6 · macOS 26 Liquid Glass",
                    symbol: "swift",
                    subtitle: "App 全部界面与服务层：Swift Concurrency、SQLite WAL 记忆库、Keychain、IOKit 防睡眠",
                    repo: "github.com/swiftlang/swift",
                    license: "Apache-2.0",
                    urlString: "https://github.com/swiftlang/swift",
                    tint: Theme.warning
                )
                SettingsDivider()
                TechLinkRow(
                    title: "Frida Gadget 注入官方微信（本机）",
                    symbol: "syringe",
                    subtitle: "唯一实例方案：Gadget 注入后由 bridge 经 frida-core 附加，脚本读取/调用 wechat.dylib 内部函数",
                    repo: "github.com/frida/frida",
                    license: "LGPL-2.1",
                    urlString: "https://github.com/frida/frida",
                    tint: Theme.violet
                )
                SettingsDivider()
                TechLinkRow(
                    title: "OneBot 桥接（Go，GPL-3.0 衍生）",
                    symbol: "arrow.triangle.branch",
                    subtitle: "bridge 进程：附加 Gadget、接收事件、HTTP/WS 发送接口与鉴权、媒体上传/下载",
                    repo: "github.com/yincongcyincong/weixin-macos",
                    license: "GPL-3.0",
                    urlString: "https://github.com/yincongcyincong/weixin-macos",
                    tint: Theme.info
                )
                SettingsDivider()
                TechLinkRow(
                    title: "OpenAI 兼容接口（DeepSeek / OpenAI / Ollama）",
                    symbol: "sparkles",
                    subtitle: "AI 回复生成：SSE 流式、按模型温度/超时、多通道与人格覆盖",
                    repo: "github.com/openai/openai-openapi",
                    license: "MIT",
                    urlString: "https://github.com/openai/openai-openapi",
                    tint: Theme.accent
                )
            }

            SettingsSection(
                title: "自研研究与实现",
                footer: "Hook 地址移植、4.1.15 收发适配、R3 原生发送与真机验证均为本项目自研；上游仅提供基线脚本、地址查找工具与 OneBot 协议实现。"
            ) {
                researchRow(
                    "微信 4.1.15.55（270135）地址移植",
                    "addrfind 两段跳（4.1.12 → 4.1.13 → 4.1.15）+ vtable/RTTI 交叉验证；18/18 地址（req2buf、buf2Resp、上传/下载链），全部落盘可复现",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: Theme.info
                )
                SettingsDivider()
                researchRow(
                    "req2buf 双布局 ABI 适配",
                    "4.1.15 重编译：栈帧 0x1c0、taskId/容器寄存器重排、编码 ABI 变化、AutoBuffer 预写、found 路径 erase/delete；旧版本（≤4.1.12）零回归",
                    symbol: "arrow.left.arrow.right",
                    tint: Theme.warning
                )
                SettingsDivider()
                researchRow(
                    "R3 原生发送（4.1.15 自研路线）",
                    "解析 service→classA、用真 ctor 0x30C2DE4 构造 newsendmsg task、fake B1 serializer 注入 protobuf、运行时 __clone() 真实 hand-off 闭包、slot13 原生提交；2026-10-20 真机文本私聊已送达手机",
                    symbol: "paperplane",
                    tint: Theme.accent
                )
                SettingsDivider()
                researchRow(
                    "发送句柄（种子）捕获与排队",
                    "slot13 只读 onEnter 捕获种子闭包、发送前 detach 防 JS 重入；无句柄时排队（≤8 条 / 10 分钟），句柄就绪后自动重发",
                    symbol: "tray.and.arrow.down",
                    tint: Theme.violet
                )
                SettingsDivider()
                researchRow(
                    "接收适配：Message finalizer",
                    "以 0x4cbc3ac 通用终结器替代 buf2Resp，解析 libc++ std::string 与消息字段，接收/发送链路解耦",
                    symbol: "envelope.open",
                    tint: Theme.success
                )
                SettingsDivider()
                researchRow(
                    "安全边界与复盘方法",
                    "拒绝伪造 map 节点（C2 已证伪）、不在 owl coroutine 上执行 JS、不做 mid-function PC 跳转；崩溃报告/canary 复盘 + 只读真机探针 + 离线渲染/逻辑测试",
                    symbol: "shield.lefthalf.filled",
                    tint: .secondary
                )
                SettingsDivider()
                researchRow(
                    "分析工具链（自建/复用）",
                    "Capstone 反汇编、addrfind 地址移植、pointer_owner 解 chained fixups、frida-python 只读探针；研究证据保留在 _research/（地址/反汇编/崩溃复盘/真机日志）",
                    symbol: "wrench.adjustable",
                    tint: Theme.info
                )
            }

            SettingsSection(title: "上游开源项目") {
                TechLinkRow(
                    title: "weixin-macos（Hook / OneBot / addrfind）",
                    symbol: "shippingbox",
                    repo: "github.com/yincongcyincong/weixin-macos",
                    license: "GPL-3.0",
                    urlString: "https://github.com/yincongcyincong/weixin-macos",
                    tint: Theme.accent
                )
                SettingsDivider()
                TechLinkRow(
                    title: "wechat-mac-hook（macOS 4.x 集成与运维）",
                    symbol: "wrench.and.screwdriver",
                    repo: "github.com/xiaoguiwucan/wechat-mac-hook",
                    license: "GPL-3.0",
                    urlString: "https://github.com/xiaoguiwucan/wechat-mac-hook",
                    tint: Theme.warning
                )
                SettingsDivider()
                TechLinkRow(
                    title: "Frida 运行时（LGPL-2.1）",
                    symbol: "syringe",
                    repo: "github.com/frida/frida",
                    license: "LGPL-2.1",
                    urlString: "https://github.com/frida/frida",
                    tint: Theme.violet
                )
            }
        }
    }

    private func researchRow(
        _ title: String,
        _ detail: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    /// Keeps at least one entry point visible. Closing the Dock icon while the menu
    /// bar icon is hidden would leave no way to reopen the app after its window closes.
    private var showDockIconBinding: Binding<Bool> {
        Binding(
            get: { store.settings.general.showDockIcon },
            set: { newValue in
                store.settings.general.showDockIcon = newValue
                if !newValue, !store.settings.general.showInMenuBar {
                    store.settings.general.showInMenuBar = true
                    toast.show("已同时开启菜单栏图标，避免关闭 Dock 后无法打开应用", tone: .warning)
                }
                store.persist()
            }
        )
    }

    private var showInMenuBarBinding: Binding<Bool> {
        Binding(
            get: { store.settings.general.showInMenuBar },
            set: { newValue in
                store.settings.general.showInMenuBar = newValue
                if !newValue, !store.settings.general.showDockIcon {
                    store.settings.general.showDockIcon = true
                    toast.show("已同时开启 Dock 图标，避免关闭菜单栏后无法打开应用", tone: .warning)
                }
                store.persist()
            }
        )
    }

    // MARK: Actions

    private func chooseWeChatApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择微信"
        panel.message = "选择 /Applications/WeChat.app"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.hook.wechatPath = url.path
        store.hookStatus.wechatVersion = AppStore.installedWeChatVersion(path: url.path) ?? ""
        store.persist()
        toast.show("已更新微信路径", tone: .success)
    }

    private func chooseVersionConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "选择版本配置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.hook.versionConfigPath = url.path
        store.persist()
        toast.show("已更新版本配置路径", tone: .success)
    }

    private func installHook() {
        isWorking = true
        progress = 0.02
        progressMessage = "正在准备安装…"
        Task {
            do {
                try await store.installHook(onProgress: { value, message in
                    Task { @MainActor in
                        progress = value
                        progressMessage = message
                    }
                })
                progress = 1
                progressMessage = "安装完成"
                toast.show("Hook 安装完成", tone: .success)
            } catch {
                toast.show("安装失败：\(error.localizedDescription)", tone: .error)
            }
            await store.refreshStatus()
            isWorking = false
            progress = nil
            progressMessage = nil
        }
    }

    private func restoreBackup() {
        isWorking = true
        progress = nil
        progressMessage = "正在从备份还原微信…"
        Task {
            do {
                try await store.restoreWeChatBackup()
                toast.show("已从备份还原官方微信", tone: .success)
            } catch {
                toast.show("还原失败：\(error.localizedDescription)", tone: .error)
            }
            await store.refreshStatus()
            isWorking = false
            progressMessage = nil
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "wechatai-config-\(UIFormat.fileDate.string(from: Date())).json"
        panel.title = "导出配置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(store.settings)
            try data.write(to: url, options: .atomic)
            toast.show("配置已导出", tone: .success, symbol: "square.and.arrow.up")
        } catch {
            toast.show("导出失败：\(error.localizedDescription)", tone: .error)
        }
    }

    // MARK: Info

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0-dev"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

// MARK: - About link row

/// A full-width About row that opens a GitHub project page.
///
/// Links are file-private and hard-coded: the app never fetches anything by itself,
/// the default browser is only opened when the row is clicked. Explicit foreground
/// styles keep the label readable in both appearances instead of inheriting the
/// default blue link tint, while `arrow.up.right` marks the row as leaving the app.
private struct TechLinkRow: View {
    let title: String
    let symbol: String
    /// 本项目中的实际用途/角色。
    var subtitle: String? = nil
    /// Display path, e.g. `github.com/frida/frida`.
    let repo: String
    let license: String
    /// Destination shown to the browser; a literal so no network work happens on render.
    let urlString: String
    var tint: Color = .secondary

    var body: some View {
        if let destination = URL(string: urlString) {
            Link(destination: destination) {
                label
            }
            .buttonStyle(.plain)
            .help("在 GitHub 打开 \(title)")
            .accessibilityLabel(Text("在 GitHub 打开 \(title)，\(repo)，\(license)"))
        } else {
            label
        }
    }

    private var label: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Monospaced repo path plus the license in the standard caption. Rendered as a
    /// single attributed line, so `.middle` truncation keeps both the owner and the
    /// license visible in narrow windows.
    private var detail: AttributedString {
        var path = AttributedString(repo)
        path.font = .system(.caption, design: .monospaced)
        var suffix = AttributedString(" · \(license)")
        suffix.font = .caption
        path.append(suffix)
        return path
    }
}

// MARK: - Log buffer maintenance

/// 维护区的“清空日志”行独立成子视图：只有它观察 `store.logs`，日志高频追加时
/// 不会让整个设置页（大量玻璃卡片）随每条日志重新求值。
private struct LogBufferMaintenanceRow: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    var body: some View {
        SettingsRow(
            title: "日志缓冲",
            subtitle: "内存中最多保留 2000 条运行日志",
            symbol: "text.alignleft",
            tint: Theme.info
        ) {
            Button("清空日志") {
                store.clearLogs()
                toast.show("日志已清空", tone: .info, symbol: "trash")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(store.logs.isEmpty)
        }
    }
}
