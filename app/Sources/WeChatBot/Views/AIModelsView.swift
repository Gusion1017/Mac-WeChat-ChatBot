import SwiftUI

/// AI 模型：多通道管理、Keychain 密钥、连接测试与全局请求参数。
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
                Label("添加通道", systemImage: "plus")
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
            }

            SectionCard(
                title: "模型温度",
                subtitle: "按模型单独配置；未配置时使用模型自身默认温度",
                symbol: "thermometer.medium",
                tint: Theme.warning
            ) {
                VStack(spacing: 0) {
                    if knownModels.isEmpty {
                        Text("先添加通道并填写模型名称。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        ForEach(Array(knownModels.enumerated()), id: \.element) { index, model in
                            if index > 0 { SettingsDivider() }
                            modelTemperatureRow(model)
                        }
                    }
                }
                .padding(.vertical, -4)
            }

            SectionCard(
                title: "全局请求",
                subtitle: "新会话没有单独指定时使用",
                symbol: "gearshape.2.fill",
                tint: Theme.violet
            ) {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "默认通道",
                        subtitle: "自动回复优先使用的模型",
                        symbol: "star.fill",
                        tint: Theme.warning
                    ) {
                        Picker("默认通道", selection: defaultProviderBinding) {
                            Text("无").tag(String?.none)
                            ForEach(store.providers) { provider in
                                Text(provider.name).tag(Optional(provider.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "流式回复",
                        subtitle: "总开关：关闭后所有通道都不流式；开启时跟随各通道的流式设置",
                        symbol: "waveform",
                        tint: Theme.info
                    ) {
                        Toggle("流式回复", isOn: streamBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "请求超时",
                        subtitle: "单次 AI 请求的最长等待时间",
                        symbol: "timer",
                        tint: Theme.warning
                    ) {
                        Stepper(
                            "\(Int(store.settings.ai.requestTimeoutSeconds)) 秒",
                            value: timeoutBinding,
                            in: 5...300,
                            step: 5
                        )
                        .font(.caption)
                        .frame(width: 116)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "失败重试",
                        subtitle: "请求失败后自动重试的次数",
                        symbol: "arrow.clockwise",
                        tint: .secondary
                    ) {
                        Stepper(
                            "\(store.settings.ai.retryCount) 次",
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

            SectionCard(
                title: "密钥与安全",
                subtitle: "本机运行，不经过第三方服务器",
                symbol: "lock.shield.fill",
                tint: Theme.success
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("API Key 仅保存在 macOS Keychain，配置文件只记录引用名。", systemImage: "key.fill")
                    Label("测试连接会向所选通道发送一次最小聊天请求。", systemImage: "bolt.horizontal")
                    Label("Ollama 本地通道无需密钥，默认地址为 127.0.0.1。", systemImage: "desktopcomputer")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                PathRow(label: "配置文件", path: AppPaths.configFile.path)
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditorSheet(
                provider: provider,
                isNew: isEditingNew,
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
            Button("删除 \(provider.name)", role: .destructive) {
                delete(provider)
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("只会删除本机通道配置，不会影响远端服务。")
        }
    }

    // MARK: Derived

    private var subtitle: String {
        let count = store.providers.count
        guard let provider = store.settings.provider(id: store.settings.ai.defaultProviderID) else {
            return "未配置通道"
        }
        return "\(count) 个通道 · 默认 \(provider.name) · \(provider.model)"
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
        store.settings.ai.defaultProviderID == provider.id
            || (store.settings.ai.defaultProviderID == nil && provider.isDefault)
    }

    // MARK: Per-model temperature

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
        return models
    }

    private func modelTemperatureRow(_ model: String) -> some View {
        SettingsRow(
            title: model,
            subtitle: modelTemperature(for: model) == nil ? "使用模型默认温度" : "自定义温度",
            symbol: "cpu",
            tint: Theme.warning
        ) {
            HStack(spacing: 8) {
                if let temperature = modelTemperature(for: model) {
                    Slider(value: temperatureBinding(for: model), in: 0...2, step: 0.1)
                        .tint(Theme.accent)
                        .frame(width: 150)
                        .accessibilityLabel("\(model) 温度")
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
                    .help("恢复模型默认温度")
                    .accessibilityLabel("恢复 \(model) 默认温度")
                } else {
                    Button("设置温度") {
                        setModelTemperature(0.7, for: model)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
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

    // MARK: Bindings

    private var defaultProviderBinding: Binding<String?> {
        Binding(
            get: { store.settings.ai.defaultProviderID },
            set: { newValue in
                store.settings.ai.defaultProviderID = newValue
                store.settings.bot.defaultProviderID = newValue
                for index in store.providers.indices {
                    store.providers[index].isDefault = store.providers[index].id == newValue
                }
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

    private var timeoutBinding: Binding<Double> {
        Binding(
            get: { store.settings.ai.requestTimeoutSeconds },
            set: { store.settings.ai.requestTimeoutSeconds = $0; store.persist() }
        )
    }

    private var retryBinding: Binding<Int> {
        Binding(
            get: { store.settings.ai.retryCount },
            set: { store.settings.ai.retryCount = $0; store.persist() }
        )
    }

    // MARK: Actions

    private func addProvider() {
        var draft = AIProvider(
            name: "新通道",
            kind: .custom,
            baseURL: "",
            model: "",
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

    private func save(_ updated: AIProvider, secret: String?) {
        if let index = store.providers.firstIndex(where: { $0.id == updated.id }) {
            store.providers[index] = updated
            toast.show("通道已保存", tone: .success)
        } else {
            store.providers.append(updated)
            toast.show("通道已添加", tone: .success)
        }
        if updated.isDefault || store.settings.ai.defaultProviderID == nil {
            setDefaultSilently(updated)
        }
        store.persist()
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

    private func setDefaultSilently(_ provider: AIProvider) {
        store.settings.ai.defaultProviderID = provider.id
        store.settings.bot.defaultProviderID = provider.id
        for index in store.providers.indices {
            store.providers[index].isDefault = store.providers[index].id == provider.id
        }
    }

    private func setEnabled(_ provider: AIProvider, _ enabled: Bool) {
        guard let index = store.providers.firstIndex(where: { $0.id == provider.id }) else { return }
        store.providers[index].enabled = enabled
        store.persist()
    }

    private func delete(_ provider: AIProvider) {
        pendingDelete = nil
        store.providers.removeAll { $0.id == provider.id }
        testStates[provider.id] = nil
        if store.settings.ai.defaultProviderID == provider.id {
            let next = store.providers.first
            store.settings.ai.defaultProviderID = next?.id
            store.settings.bot.defaultProviderID = next?.id
            if let next, let index = store.providers.firstIndex(where: { $0.id == next.id }) {
                store.providers[index].isDefault = true
            }
        }
        store.persist()
        toast.show("已删除通道 \(provider.name)", tone: .info, symbol: "trash")
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
