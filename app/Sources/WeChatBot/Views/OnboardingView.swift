import SwiftUI

/// 首次启动向导：欢迎 → 检测微信/安装 Hook → 配置 AI → 启动机器人。
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var step = 0
    @State private var showRiskConfirm = false
    @State private var isDetecting = false
    @State private var isInstalling = false
    @State private var installProgress: Double?
    @State private var installMessage: String?
    @State private var installError: String?
    @State private var selectedProviderID: String?
    @State private var apiKeyDraft = ""
    @State private var isTestingAI = false
    @State private var aiTestResult: (success: Bool, message: String)?
    @State private var shouldStartBot = true

    private let stepTitles = ["欢迎", "微信 Hook", "AI 模型", "启动"]

    var body: some View {
        ZStack {
            PageBackground()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)

                ScrollView {
                    stepContent
                        .padding(.horizontal, 36)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 660, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)

                Divider().opacity(0.6)
                footer
            }
        }
        .frame(width: 720, height: 620)
        .interactiveDismissDisabled(isInstalling)
        .sheet(isPresented: $showRiskConfirm) {
            ConfirmSheet(
                title: "备份并安装 Hook 到微信",
                message: "此操作会修改官方微信的应用包，用于注入消息收发 Hook。请先完全退出微信。",
                details: [
                    "会先完整备份 /Applications/WeChat.app，再注入 Frida Gadget 并 ad-hoc 重签。",
                    "微信更新后需要重新安装；小程序、自动更新等功能可能受影响。",
                    "仅在本机运行，不修改微信服务器数据；可随时从备份还原。",
                    "安装约需 1–2 分钟，期间请勿打开微信。"
                ],
                confirmTitle: "备份并安装",
                cancelTitle: "取消"
            ) {
                installHook()
            }
        }
    }

    // MARK: Header

    private var languageBinding: Binding<String> {
        Binding(
            get: { store.settings.general.language },
            set: { store.setLanguage($0) }
        )
    }

    private var header: some View {
        VStack(spacing: 13) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accentStrong],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("WeChat AI 设置向导"))
                        .font(.headline)
                    Text(L("4 步完成本机配置，随时可以跳过或在设置中修改"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L("语言 / Language"), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 170)
                .help(L("语言 / Language"))

                if step < stepTitles.count - 1 {
                    Button(L("跳过向导")) { skip() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(L("跳过剩余步骤，之后可在设置或菜单中重新打开"))
                }
            }

            HStack(spacing: 0) {
                ForEach(Array(stepTitles.enumerated()), id: \.offset) { index, title in
                    VStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(index <= step ? Theme.accent : Color.primary.opacity(0.07))
                                .frame(width: 22, height: 22)
                            if index < step {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(index == step ? .white : Color.secondary)
                            }
                        }
                        Text(L(title))
                            .font(.system(size: 9.5, weight: index == step ? .semibold : .regular))
                            .foregroundStyle(index <= step ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    if index < stepTitles.count - 1 {
                        Rectangle()
                            .fill(index < step ? Theme.accent : Color.primary.opacity(0.08))
                            .frame(height: 2)
                            .clipShape(Capsule())
                            .padding(.bottom, 17)
                    }
                }
            }
            .padding(.horizontal, 46)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Step content

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch step {
            case 0: welcomeStep
            case 1: hookStep
            case 2: aiStep
            default: launchStep
            }
        }
        .id(step)
        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent.opacity(0.2), Theme.info.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 84, height: 84)
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.accent)
                }
                Text(L("欢迎使用 WeChat AI"))
                    .font(.title.weight(.semibold))
                Text(L("把 AI 接进你的微信，同时保留完整的本机控制权。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            VStack(spacing: 10) {
                featureRow(
                    symbol: "macwindow",
                    tint: Theme.accent,
                    title: "原生 macOS 体验",
                    message: "SwiftUI + Liquid Glass，没有 WebView，空闲时占用低。"
                )
                featureRow(
                    symbol: "lock.shield.fill",
                    tint: Theme.success,
                    title: "本地优先，数据不上云",
                    message: "配置、聊天记忆、日志都保存在本机；API Key 存入 Keychain。"
                )
                featureRow(
                    symbol: "sparkles",
                    tint: Theme.violet,
                    title: "多模型 + 人格",
                    message: "DeepSeek / OpenAI / Ollama 任一兼容通道，按会话切换。"
                )
            }

            InlineNotice(
                kind: .warning,
                title: "开始前的准备",
                message: "需要已安装官方微信 4.1.15.55（arm64）。安装 Hook 会修改微信应用包，请先退出微信并确认了解风险。"
            )
        }
    }

    private func featureRow(symbol: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            IconTile(symbol: symbol, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.callout.weight(.medium))
                Text(L(message)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var hookStep: some View {
        VStack(alignment: .leading, spacing: 15) {
            stepHeading(
                title: "检测微信并安装 Hook",
                message: "App 通过 Frida Gadget 注入官方微信，再经本地 OneBot 桥接收发消息。"
            )

            SettingsSection(title: "检测结果") {
                SettingsRow(title: "微信路径", symbol: "iphone", tint: Theme.accent) {
                    Text(UIFormat.compactPath(store.settings.hook.wechatPath))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                SettingsDivider()
                SettingsRow(title: "版本", symbol: "number", tint: .secondary) {
                    HStack(spacing: 6) {
                        Text(store.hookStatus.wechatVersion.isEmpty ? L("未检测") : store.hookStatus.wechatVersion)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        PillLabel(
                            text: store.hookStatus.matchedVersion ? "已匹配" : "待匹配",
                            color: store.hookStatus.matchedVersion ? Theme.success : Theme.warning
                        )
                    }
                }
                SettingsDivider()
                SettingsRow(title: "微信进程", symbol: "checkmark.seal", tint: .secondary) {
                    PillLabel(
                        text: store.hookStatus.wechatRunning ? "运行中" : "未运行",
                        color: store.hookStatus.wechatRunning ? Theme.success : .secondary
                    )
                }
                SettingsDivider()
                SettingsRow(title: "Gadget", symbol: "link", tint: .secondary) {
                    PillLabel(
                        text: store.hookStatus.gadgetInstalled ? "已安装" : "未安装",
                        color: store.hookStatus.gadgetInstalled ? Theme.success : Theme.warning
                    )
                }
            }

            if isInstalling {
                ProgressPanel(
                    title: "正在安装 Hook",
                    detail: installMessage ?? "备份、注入与重签名中，请勿打开微信…",
                    progress: installProgress
                )
            }

            if let installError {
                InlineNotice(kind: .danger, title: "安装失败", message: installError)
            }

            HStack(spacing: 9) {
                Button {
                    detectWeChat()
                } label: {
                    Label(L(isDetecting ? "检测中…" : "检测微信"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.glass)
                .disabled(isDetecting || isInstalling)

                Button {
                    showRiskConfirm = true
                } label: {
                    Label(
                        store.hookStatus.gadgetInstalled ? "重新安装 Hook" : "备份并安装 Hook…",
                        systemImage: "wrench.and.screwdriver"
                    )
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.warning)
                .disabled(isInstalling || isDetecting)

                Spacer()
            }

            if store.hookStatus.gadgetInstalled {
                InlineNotice(
                    kind: .success,
                    title: "Hook 已安装",
                    message: "下一步配置 AI 模型；之后启动机器人即可连接微信。"
                )
            } else {
                Text(L("暂时不安装也可以继续；之后可在「设置 → Hook」中备份并安装。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 15) {
            stepHeading(
                title: "配置 AI 模型",
                message: "选择一个 OpenAI 兼容通道并保存 API Key。密钥只写入 macOS Keychain。"
            )

            if store.providers.isEmpty {
                GlassCard {
                    EmptyState(
                        symbol: "sparkles",
                        title: "还没有 AI 通道",
                        message: "添加一个默认 DeepSeek 通道后即可继续；模型可以稍后修改。",
                        actionTitle: "创建默认通道"
                    ) {
                        createDefaultProvider()
                    }
                }
            } else {
                SettingsSection(title: "默认通道") {
                    SettingsRow(title: "通道", symbol: "sparkles", tint: Theme.violet) {
                        Picker(L("通道"), selection: providerSelection) {
                            ForEach(store.providers) { provider in
                                Text("\(provider.name) · \(provider.kind.label)").tag(Optional(provider.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    if let provider = selectedProvider {
                        SettingsDivider()
                        SettingsRow(title: "Base URL", symbol: "network", tint: .secondary) {
                            Text(provider.baseURL)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        SettingsDivider()
                        SettingsRow(title: "模型", symbol: "cpu", tint: .secondary) {
                            Text(provider.model)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let provider = selectedProvider, provider.kind != .ollama {
                    SettingsSection(
                        title: "API Key",
                        footer: "密钥保存在 Keychain（service com.gusionw.wechatai），不会写入 config.json。"
                    ) {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 8) {
                                SecureField("sk-…", text: $apiKeyDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                if provider.hasAPIKey {
                                    PillLabel(text: "已保存", color: Theme.success, symbol: "key.fill")
                                }
                            }
                            if !provider.hasAPIKey, apiKeyDraft.isEmpty {
                                Text(L("尚未配置密钥；保存后才能测试连接并生成回复。"))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(14)
                    }
                }

                HStack(spacing: 9) {
                    Button {
                        testAI()
                    } label: {
                        Label(L(isTestingAI ? "测试中…" : "保存并测试连接"), systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(isTestingAI)

                    Button(L("打开 AI 模型页")) {
                        store.isOnboardingPresented = false
                        store.sidebarSelection = .ai
                    }
                    .buttonStyle(.glass)

                    Spacer()
                }

                if let aiTestResult {
                    InlineNotice(
                        kind: aiTestResult.success ? .success : .danger,
                        title: aiTestResult.success ? "连接正常" : "连接失败",
                        message: aiTestResult.message
                    )
                }

                Text(L("也可以暂时跳过；没有可用 AI 时机器人不会自动回复。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            if selectedProviderID == nil {
                selectedProviderID = store.settings.ai.defaultProviderID ?? store.providers.first?.id
            }
        }
    }

    private var launchStep: some View {
        VStack(alignment: .leading, spacing: 15) {
            stepHeading(
                title: "启动机器人",
                message: "确认以下状态后完成向导。启动后可在总览实时查看运行情况。"
            )

            SettingsSection(title: "配置检查") {
                checklistRow(
                    title: "微信",
                    detail: store.hookStatus.wechatVersion.isEmpty ? "未检测到版本" : "版本 \(store.hookStatus.wechatVersion)",
                    ready: !store.hookStatus.wechatVersion.isEmpty,
                    icon: "iphone"
                )
                SettingsDivider()
                checklistRow(
                    title: "Hook",
                    detail: store.hookStatus.gadgetInstalled ? (store.hookStatus.matchedVersion ? "已安装 · 版本已匹配" : "已安装 · 待匹配版本") : "尚未安装（可稍后在设置中安装）",
                    ready: store.hookStatus.gadgetInstalled,
                    icon: "link"
                )
                SettingsDivider()
                checklistRow(
                    title: "AI 模型",
                    detail: aiSummary,
                    ready: selectedProvider != nil,
                    icon: "sparkles"
                )
            }

            Toggle(L("完成向导后立即启动机器人"), isOn: $shouldStartBot)
                .toggleStyle(.switch)
                .font(.callout)

            InlineNotice(
                kind: .info,
                title: "启动后",
                message: "机器人会连接本地 OneBot 服务并按触发设置与人设自动回复。所有开关都可以在侧边栏「机器人」中随时调整。"
            )
        }
    }

    private func checklistRow(title: String, detail: String, ready: Bool, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(L(title)).font(.callout)
                Text(L(detail)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(ready ? Theme.success : Theme.warning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func stepHeading(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).font(.title3.weight(.semibold))
            Text(L(message))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 9) {
            Button {
                goBack()
            } label: {
                Label(L("上一步"), systemImage: "chevron.left")
            }
            .buttonStyle(.glass)
            .disabled(step == 0 || isInstalling)

            Spacer()

            Text("\(step + 1) / \(stepTitles.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                if step == stepTitles.count - 1 {
                    finish()
                } else {
                    goNext()
                }
            } label: {
                Label(
                    step == stepTitles.count - 1 ? "完成并开始" : "下一步",
                    systemImage: step == stepTitles.count - 1 ? "checkmark" : "chevron.right"
                )
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(isInstalling)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
    }

    // MARK: Derived

    private var selectedProvider: AIProvider? {
        if let selectedProviderID, let provider = store.providers.first(where: { $0.id == selectedProviderID }) {
            return provider
        }
        return store.defaultProvider
    }

    private var providerSelection: Binding<String?> {
        Binding(
            get: { selectedProviderID ?? store.settings.ai.defaultProviderID ?? store.providers.first?.id },
            set: { newValue in
                selectedProviderID = newValue
                store.settings.ai.defaultProviderID = newValue
                store.settings.bot.defaultProviderID = newValue
                for index in store.providers.indices {
                    store.providers[index].isDefault = store.providers[index].id == newValue
                }
                store.persist()
            }
        )
    }

    private var aiSummary: String {
        guard let provider = selectedProvider else { return "尚未配置通道" }
        if provider.kind == .ollama { return "\(provider.name) · \(provider.model) · 本地" }
        if !provider.hasAPIKey, apiKeyDraft.isEmpty { return "\(provider.name) · 尚未保存密钥" }
        return "\(provider.name) · \(provider.model)"
    }

    // MARK: Actions

    private func goNext() {
        guard step < stepTitles.count - 1 else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            step += 1
        }
    }

    private func goBack() {
        guard step > 0 else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            step -= 1
        }
    }

    private func skip() {
        hasCompletedOnboarding = true
        store.isOnboardingPresented = false
        dismiss()
    }

    private func finish() {
        hasCompletedOnboarding = true
        store.isOnboardingPresented = false
        if shouldStartBot {
            Task {
                await store.startBot()
                toast.show(
                    store.isBotRunning ? "机器人已启动" : "启动请求已提交，请在总览查看状态",
                    tone: store.isBotRunning ? .success : .warning,
                    symbol: "play.circle.fill"
                )
            }
        } else {
            toast.show("向导已完成", tone: .success, symbol: "checkmark.circle.fill")
        }
        dismiss()
    }

    private func detectWeChat() {
        isDetecting = true
        store.hookStatus.wechatVersion = AppStore.installedWeChatVersion(path: store.settings.hook.wechatPath) ?? ""
        Task {
            await store.refreshStatus()
            isDetecting = false
            toast.show(
                store.hookStatus.wechatVersion.isEmpty ? "未检测到微信，请检查路径" : "已检测到微信 \(store.hookStatus.wechatVersion)",
                tone: store.hookStatus.wechatVersion.isEmpty ? .warning : .success
            )
        }
    }

    private func installHook() {
        isInstalling = true
        installError = nil
        installProgress = 0.02
        installMessage = "正在备份微信…"
        Task {
            do {
                try await store.installHook(onProgress: { value, message in
                    Task { @MainActor in
                        installProgress = value
                        installMessage = message
                    }
                })
                installProgress = 1
                installMessage = "安装完成"
                toast.show("Hook 安装完成", tone: .success)
            } catch {
                installError = error.localizedDescription
                toast.show("安装失败：\(error.localizedDescription)", tone: .error)
            }
            await store.refreshStatus()
            isInstalling = false
        }
    }

    private func testAI() {
        guard let provider = selectedProvider else { return }
        isTestingAI = true
        aiTestResult = nil
        Task {
            if !apiKeyDraft.isEmpty {
                do {
                    try store.saveAPIKey(apiKeyDraft, for: provider.id)
                    apiKeyDraft = ""
                } catch {
                    aiTestResult = (false, "保存 API Key 失败：\(error.localizedDescription)")
                    isTestingAI = false
                    return
                }
            }
            let updated = store.providers.first(where: { $0.id == provider.id }) ?? provider
            let result = await store.testProvider(updated)
            switch result {
            case .success(let message):
                aiTestResult = (true, message.isEmpty ? "连接成功" : message)
                toast.show("AI 连接正常", tone: .success)
            case .failure(let error):
                aiTestResult = (false, error.localizedDescription)
                toast.show("AI 连接失败", tone: .error)
            }
            isTestingAI = false
        }
    }

    private func createDefaultProvider() {
        var provider = AppSettings.makeDefaultProvider()
        provider.id = UUID().uuidString
        provider.isDefault = true
        store.providers.append(provider)
        store.settings.ai.defaultProviderID = provider.id
        store.settings.bot.defaultProviderID = provider.id
        selectedProviderID = provider.id
        store.persist()
        toast.show("已创建默认 DeepSeek 通道", tone: .success)
    }
}
