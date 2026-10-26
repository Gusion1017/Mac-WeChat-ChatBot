import SwiftUI

/// AI 模型：多通道管理、Keychain 密钥、连接测试、默认通道与请求策略。
struct AIModelsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var editingProvider: AIProvider?
    @State private var isEditingNew = false
    @State private var testStates: [String: ProviderTestState] = [:]
    @State private var pendingDelete: AIProvider?

    var body: some View {
        ScrollingPage(title: "AI 模型", subtitle: subtitle) {
            Button {
                addProvider()
            } label: {
                Label(L("添加通道"), systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
        } content: {
            if store.providers.isEmpty {
                GlassCard {
                    EmptyState(
                        symbol: "sparkles",
                        title: "还没有 AI 通道",
                        message: "添加一个 OpenAI 兼容通道后，机器人才会生成回复。",
                        actionTitle: "添加通道"
                    ) {
                        addProvider()
                    }
                }
            } else {
                VStack(spacing: 9) {
                    ForEach(sortedProviders) { provider in
                        ProviderRow(
                            provider: provider,
                            isDefault: isDefault(provider),
                            testState: testStates[provider.id] ?? .idle,
                            canDelete: store.providers.count > 1,
                            globalStreamingEnabled: store.settings.ai.streamReplies,
                            onEdit: {
                                isEditingNew = false
                                editingProvider = provider
                            },
                            onTest: { test(provider) },
                            onDelete: { pendingDelete = provider },
                            onToggleEnabled: { enabled in setEnabled(provider, enabled) }
                        )
                    }
                }

                defaultChannelCard
            }

            requestPolicyCard
            visionCard
            temperatureCard
            securityCard
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditorSheet(
                provider: provider,
                isNew: isEditingNew,
                globalStreamingEnabled: store.settings.ai.streamReplies,
                onDeleteKey: {
                    deleteKey(for: provider)
                }
            ) { updated, secret in
                save(updated, secret: secret)
            }
        }
        .confirmationDialog(
            "删除 AI 通道",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { provider in
            Button(L("删除") + " \(provider.name)", role: .destructive) {
                delete(provider)
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text(L("会删除本机通道配置与该通道在 Keychain 中的密钥，不影响远端服务。"))
        }
    }

    // MARK: Derived

    private var subtitle: String {
        guard !store.providers.isEmpty,
              let provider = store.settings.provider(id: store.settings.ai.defaultProviderID)
        else {
            return L("未配置通道")
        }
        return Lf("%d 个通道 · 默认 %@ · %@", store.providers.count, provider.name, provider.model)
    }

    private var sortedProviders: [AIProvider] {
        store.providers.sorted { lhs, rhs in
            let lhsDefault = isDefault(lhs)
            let rhsDefault = isDefault(rhs)
            if lhsDefault != rhsDefault { return lhsDefault }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private func isDefault(_ provider: AIProvider) -> Bool {
        store.settings.provider(id: store.settings.ai.defaultProviderID)?.id == provider.id
    }

    /// 默认通道失效时给出可直接行动的原因（停用 / 缺少 Key），而不是让回复静默失败。
    private var defaultChannelWarning: String? {
        guard let provider = store.defaultProvider else { return nil }
        if !provider.enabled {
            return "默认通道已停用；请在通道列表启用，或更换默认通道。"
        }
        if !provider.hasUsableCredential {
            return "默认通道缺少 API Key；请编辑该通道填写密钥。"
        }
        return nil
    }

    // MARK: Default channel

    private var defaultChannelCard: some View {
        SectionCard(
            title: "默认通道",
            subtitle: "自动回复默认使用此通道",
            symbol: "star.fill",
            tint: Theme.warning
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "默认通道",
                    subtitle: "自动回复使用此通道；停用或缺少密钥时无法生成回复。",
                    symbol: "star.fill",
                    tint: Theme.warning
                ) {
                    Picker(L("默认通道"), selection: defaultProviderBinding) {
                        ForEach(store.providers) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }

                if let warning = defaultChannelWarning {
                    SettingsDivider()
                    Label(L(warning), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, -4)
        }
    }

    // MARK: Request policy

    private var requestPolicyCard: some View {
        SectionCard(
            title: "请求策略",
            subtitle: "对所有通道生效的流式与重试策略",
            symbol: "slider.horizontal.3",
            tint: Theme.violet
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "流式回复",
                    subtitle: "关闭后所有通道都等待完整回复；开启时由各通道的「流式返回」决定。",
                    symbol: "waveform",
                    tint: Theme.info
                ) {
                    Toggle(L("流式回复"), isOn: streamBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "失败重试",
                    subtitle: "一次回复失败后额外重试的次数（0 = 不重试）。",
                    symbol: "arrow.clockwise",
                    tint: .secondary
                ) {
                    Stepper(
                        Lf("%d 次", store.settings.ai.retryCount),
                        value: retryBinding,
                        in: 0...5,
                        step: 1
                    )
                    .font(.caption)
                    .frame(width: 96)
                }
            }
            .padding(.vertical, -4)
        }
    }

    // MARK: Vision

    private var visionCard: some View {
        SectionCard(
            title: "识图模型",
            subtitle: "可选：先让视觉模型描述图片，再把描述交给回复模型参考",
            symbol: "eye.fill",
            tint: Theme.info
        ) {
            VStack(spacing: 0) {
                if store.providers.isEmpty {
                    Text(L("先添加通道并填写模型名称。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    SettingsRow(
                        title: "启用识图",
                        subtitle: "关闭时只显示图片占位，不发起视觉请求。",
                        symbol: "eye.fill",
                        tint: Theme.info
                    ) {
                        Toggle(L("启用识图"), isOn: visionEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "识图通道",
                        subtitle: "默认跟随「默认通道」；可为识图单独指定通道。",
                        symbol: "point.3.connected.trianglepath.dotted",
                        tint: Theme.info
                    ) {
                        Picker(L("识图通道"), selection: visionProviderBinding) {
                            Text(L("跟随默认通道")).tag(String?.none)
                            ForEach(store.providers) { provider in
                                Text(provider.name).tag(Optional(provider.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                        .disabled(!store.settings.isVisionEnabled)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "识图模型覆盖",
                        subtitle: "留空时跟随所选通道的模型；填写则覆盖，需支持 OpenAI 兼容的 image_url 输入。",
                        symbol: "cpu",
                        tint: Theme.info
                    ) {
                        HStack(spacing: 7) {
                            TextField(visionModelPlaceholder, text: visionModelBinding)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 170)
                                .disabled(!store.settings.isVisionEnabled)
                            if visionModelOverride != nil {
                                Button {
                                    clearVisionModelOverride()
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .help(L("跟随通道模型"))
                                .accessibilityLabel(L("跟随通道模型"))
                            }
                        }
                    }
                    Label(
                        L("识图结果只保存在本机，并随消息作为后续回复的上下文；建议选择支持图片输入的多模态模型。"),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, -4)
        }
    }

    // MARK: Model temperature

    private var temperatureCard: some View {
        SectionCard(
            title: "模型温度",
            subtitle: "按模型单独配置；未设置时不发送 temperature，使用模型自身默认值",
            symbol: "thermometer.medium",
            tint: Theme.warning,
            trailing: {
                if hasCustomTemperatures {
                    Button(L("全部恢复默认")) {
                        store.settings.ai.modelTemperatures = [:]
                        store.persist()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            },
            content: {
                VStack(spacing: 0) {
                    if knownModels.isEmpty {
                        Text(L("先添加通道并填写模型名称。"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        ForEach(Array(knownModels.enumerated()), id: \.element) { index, model in
                            if index > 0 { SettingsDivider() }
                            modelTemperatureRow(model)
                        }
                        SettingsDivider()
                        Text(L("温度范围 0–2：越低越稳定克制，越高越随机发散；列表包含通道与人格中使用的模型。"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, -4)
            }
        )
    }

    /// 所有在通道或人格中实际使用的模型名（去重并保持顺序）。
    private var knownModels: [String] {
        var seen = Set<String>()
        var models: [String] = []
        func add(_ raw: String?) {
            guard let raw else { return }
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return }
            models.append(model)
        }
        for provider in store.providers {
            add(AIClient.effectiveModel(for: provider))
        }
        for persona in store.personas {
            add(persona.model)
        }
        // 旧配置/已移除模型仍可能留下自定义温度；列出它们才能看到并恢复，
        // 否则「全部恢复默认」按钮会出现在没有任何可见自定义行的页面上。
        for model in (store.settings.ai.modelTemperatures ?? [:]).keys.sorted() {
            add(model)
        }
        return models
    }

    private var hasCustomTemperatures: Bool {
        !(store.settings.ai.modelTemperatures?.isEmpty ?? true)
    }

    private func modelTemperatureRow(_ model: String) -> some View {
        SettingsRow(
            title: model,
            subtitle: modelTemperature(for: model) == nil ? "使用模型默认值" : "自定义温度",
            symbol: "cpu",
            tint: Theme.warning
        ) {
            HStack(spacing: 8) {
                if let temperature = modelTemperature(for: model) {
                    Slider(value: temperatureBinding(for: model), in: 0...2, step: 0.1)
                        .tint(Theme.accent)
                        .frame(width: 150)
                        .accessibilityLabel(Lf("%@ 温度", model))
                        .accessibilityValue(String(format: "%.1f", temperature))
                    Text(String(format: "%.1f", temperature))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    Button {
                        clearModelTemperature(model)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(L("恢复模型默认温度"))
                    .accessibilityLabel(Lf("恢复 %@ 默认温度", model))
                } else {
                    Button(L("自定义")) {
                        setModelTemperature(0.7, for: model)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(Lf("为 %@ 设置自定义温度", model))
                }
            }
        }
    }

    private func modelTemperature(for model: String) -> Double? {
        store.settings.ai.temperature(forModel: model)
    }

    private func temperatureBinding(for model: String) -> Binding<Double> {
        Binding(
            get: { store.settings.ai.temperature(forModel: model) ?? 0.7 },
            set: { setModelTemperature($0, for: model) }
        )
    }

    private func setModelTemperature(_ value: Double, for model: String) {
        var map = store.settings.ai.modelTemperatures ?? [:]
        map[model] = min(max(value, 0), 2)
        store.settings.ai.modelTemperatures = map
        store.persist()
    }

    private func clearModelTemperature(_ model: String) {
        var map = store.settings.ai.modelTemperatures ?? [:]
        map.removeValue(forKey: model)
        store.settings.ai.modelTemperatures = map
        store.persist()
    }

    // MARK: Security

    private var securityCard: some View {
        SectionCard(
            title: "密钥与安全",
            subtitle: "本机运行，不经过第三方服务器",
            symbol: "lock.shield.fill",
            tint: Theme.success
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("API Key 仅保存在 macOS Keychain，配置文件只记录引用名。"), systemImage: "key.fill")
                Label(L("测试连接会向所选通道发送一次最小聊天请求。"), systemImage: "bolt.horizontal")
                Label(L("Ollama 本地通道无需密钥，默认地址为 127.0.0.1。"), systemImage: "desktopcomputer")
                Label(L("删除通道会同时删除该通道在 Keychain 中的密钥。"), systemImage: "trash")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            PathRow(label: "配置文件", path: AppPaths.configFile.path)
        }
    }

    // MARK: Vision bindings

    /// 当前识图模型覆盖值；空字符串/空白视为「跟随通道」。
    private var visionModelOverride: String? {
        store.settings.ai.vision?.modelOverride
    }

    /// 未填写覆盖值时 TextField 的水位文案：显示识图通道实际生效的模型名。
    private var visionModelPlaceholder: String {
        guard let provider = store.settings.visionProvider else { return L("跟随通道模型") }
        let model = store.settings.visionModel(for: provider)
        return model.isEmpty ? L("跟随通道模型") : model
    }

    /// 修改 `vision` 时按需创建默认配置，然后持久化；关闭状态也保留其它字段。
    private func updateVision(_ mutate: (inout VisionSettings) -> Void) {
        var vision = store.settings.ai.vision ?? VisionSettings()
        mutate(&vision)
        store.settings.ai.vision = vision
        store.persist()
    }

    private func clearVisionModelOverride() {
        updateVision { $0.model = "" }
    }

    // MARK: Bindings

    /// 默认通道 Picker：列表非空时始终选中一个具体通道。
    /// 旧配置 `defaultProviderID == nil` 时显示实际回退到的第一个通道，
    /// 不再提供含义不清的「无」选项（选择「无」仍会回退，和界面不一致）。
    private var defaultProviderBinding: Binding<String> {
        Binding(
            get: { store.settings.provider(id: store.settings.ai.defaultProviderID)?.id ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                setDefaultProvider(id: newValue)
                store.persist()
            }
        )
    }

    private var streamBinding: Binding<Bool> {
        Binding(
            get: { store.settings.ai.streamReplies },
            set: { store.settings.ai.streamReplies = $0; store.persist() }
        )
    }

    private var retryBinding: Binding<Int> {
        Binding(
            get: { store.settings.ai.retryCount },
            set: { store.settings.ai.retryCount = $0; store.persist() }
        )
    }

    /// 首次打开开关时创建默认 `VisionSettings`（默认关闭，避免旧配置被意外改写）。
    private var visionEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.ai.vision?.enabled ?? false },
            set: { enabled in
                updateVision { $0.enabled = enabled }
            }
        )
    }

    private var visionProviderBinding: Binding<String?> {
        Binding(
            get: { store.settings.ai.vision?.providerID },
            set: { providerID in
                updateVision { $0.providerID = providerID }
            }
        )
    }

    private var visionModelBinding: Binding<String> {
        Binding(
            get: { store.settings.ai.vision?.model ?? "" },
            set: { model in
                updateVision { $0.model = model }
            }
        )
    }

    // MARK: Actions

    private func addProvider() {
        let kind: ProviderKind = .deepSeek
        var draft = AIProvider(
            name: suggestedName(for: kind),
            kind: kind,
            baseURL: kind.defaultBaseURL,
            model: kind.defaultModel,
            apiKeyReference: "",
            temperature: 0.7,
            maxTokens: 800,
            timeoutSeconds: 60,
            stream: true,
            enabled: true,
            isDefault: store.providers.isEmpty
        )
        draft.id = UUID().uuidString
        isEditingNew = true
        editingProvider = draft
    }

    /// 新建通道的默认名称：与已有通道重名时追加序号（DeepSeek、DeepSeek 2…）。
    private func suggestedName(for kind: ProviderKind) -> String {
        let base = kind.label
        let names = Set(store.providers.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func save(_ updated: AIProvider, secret: String?) {
        let isExisting = store.providers.contains { $0.id == updated.id }
        if let index = store.providers.firstIndex(where: { $0.id == updated.id }) {
            store.providers[index] = updated
        } else {
            store.providers.append(updated)
        }

        if updated.isDefault || store.settings.provider(id: store.settings.ai.defaultProviderID) == nil {
            setDefaultProvider(id: updated.id)
        }
        store.persist()

        if updated.requiresAPIKey && !updated.hasAPIKey {
            toast.show("通道已保存，尚未填写 API Key", tone: .warning, symbol: "key.slash")
        } else {
            toast.show(isExisting ? "通道已保存" : "通道已添加", tone: .success)
        }

        if let secret, !secret.isEmpty {
            do {
                try store.saveAPIKey(secret, for: updated.id)
                toast.show("API Key 已安全存入 Keychain", tone: .success, symbol: "key.fill")
            } catch {
                toast.show("通道已保存，但密钥写入失败：\(error.localizedDescription)", tone: .error, symbol: "key.slash")
            }
        }
    }

    private func deleteKey(for provider: AIProvider) {
        do {
            try store.deleteAPIKey(for: provider.id)
            toast.show("已从 Keychain 删除 \(provider.name) 的密钥", tone: .info, symbol: "key.slash")
        } catch {
            toast.show("删除密钥失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func setDefaultProvider(id: String) {
        store.settings.ai.defaultProviderID = id
        store.settings.bot.defaultProviderID = id
        for index in store.providers.indices {
            store.providers[index].isDefault = store.providers[index].id == id
        }
    }

    private func setEnabled(_ provider: AIProvider, _ enabled: Bool) {
        guard let index = store.providers.firstIndex(where: { $0.id == provider.id }) else { return }
        store.providers[index].enabled = enabled
        store.persist()
    }

    private func delete(_ provider: AIProvider) {
        pendingDelete = nil
        let wasDefault = isDefault(provider)

        var keychainError: String?
        if provider.hasAPIKey {
            do {
                try store.deleteAPIKey(for: provider.id)
            } catch {
                keychainError = error.localizedDescription
            }
        }

        store.providers.removeAll { $0.id == provider.id }
        testStates[provider.id] = nil

        if wasDefault {
            if let next = store.providers.first {
                setDefaultProvider(id: next.id)
            } else {
                store.settings.ai.defaultProviderID = nil
                store.settings.bot.defaultProviderID = nil
            }
        }
        store.persist()

        if let keychainError {
            toast.show(
                Lf("通道已删除，但 Keychain 密钥删除失败：%@", keychainError),
                tone: .warning,
                symbol: "key.slash"
            )
        } else {
            toast.show("已删除通道 \(provider.name)", tone: .info, symbol: "trash")
        }
    }

    private func test(_ provider: AIProvider) {
        testStates[provider.id] = .testing
        Task {
            let result = await store.testProvider(provider)
            switch result {
            case .success(let message):
                testStates[provider.id] = .success(message.isEmpty ? "连接成功" : message)
                toast.show("\(provider.name) 连接正常", tone: .success)
            case .failure(let error):
                testStates[provider.id] = .failure(error.localizedDescription)
                toast.show("\(provider.name) 连接失败", tone: .error)
            }
        }
    }
}
