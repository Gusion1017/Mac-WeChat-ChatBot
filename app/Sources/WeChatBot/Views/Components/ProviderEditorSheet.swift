import SwiftUI

/// Add / edit sheet for an OpenAI-compatible AI channel.
///
/// The form is deliberately split into three levels so the page stays scannable:
/// 1. 基本信息：名称、类型、地址与模型；
/// 2. API Key：按通道类型区分「必填 / 可选」，已有密钥时明确「留空保持不变」；
/// 3. 高级参数（默认折叠）：回复上限、超时与流式返回，折叠时仍显示当前摘要。
struct ProviderEditorSheet: View {
    let provider: AIProvider
    let isNew: Bool
    /// 全局流式总开关。关闭时通道级开关暂不生效，表单会明确提示而不是假装可用。
    let globalStreamingEnabled: Bool
    let onDeleteKey: (() -> Void)?
    let onSave: (AIProvider, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AIProvider
    @State private var secret: String = ""
    @State private var showsSecret = false
    @State private var showsAdvanced = false
    @State private var showsClearKeyConfirm = false
    @State private var validationMessage: String?
    @State private var invalidField: Field?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case baseURL
        case model
    }

    init(
        provider: AIProvider,
        isNew: Bool,
        globalStreamingEnabled: Bool = true,
        onDeleteKey: (() -> Void)? = nil,
        onSave: @escaping (AIProvider, String?) -> Void
    ) {
        self.provider = provider
        self.isNew = isNew
        self.globalStreamingEnabled = globalStreamingEnabled
        self.onDeleteKey = onDeleteKey
        self.onSave = onSave
        _draft = State(initialValue: provider)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    basicsSection
                    keySection
                    parametersSection
                }
                .padding(20)
            }

            if let validationMessage {
                InlineNotice(kind: .danger, title: "无法保存", message: validationMessage)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            Divider()
            footer
        }
        .frame(width: 600, height: 660)
        .background(.regularMaterial)
        .onAppear(perform: applyEmptyDefaults)
        .onChange(of: draft.kind) { oldKind, newKind in
            applyKindDefaults(from: oldKind, to: newKind)
        }
        .confirmationDialog(
            "清除已保存密钥",
            isPresented: $showsClearKeyConfirm
        ) {
            Button(L("清除密钥"), role: .destructive) {
                onDeleteKey?()
                dismiss()
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("清除后该通道将无法调用需要鉴权的服务；可重新填写并保存。"))
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 11) {
            IconTile(symbol: draft.kind.uiSymbol, tint: Theme.providerTint(draft.kind), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(L(isNew ? "添加 AI 通道" : "编辑 AI 通道"))
                        .font(.headline)
                    if !isNew {
                        PillLabel(
                            text: draft.enabled ? "已启用" : "已停用",
                            color: draft.enabled ? Theme.success : .secondary
                        )
                    }
                }
                Text(L("OpenAI 兼容接口 · 密钥只保存在本机"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            keyStatusPill
            Spacer()
            Button(L("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L(isNew ? "添加通道" : "保存")) {
                save()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var keyStatusPill: some View {
        if !trimmedSecret.isEmpty {
            PillLabel(text: "待保存新密钥", color: Theme.info, symbol: "key.fill")
        } else if draft.hasAPIKey {
            PillLabel(text: "密钥已保存", color: Theme.success, symbol: "key.fill")
        } else if draft.requiresAPIKey {
            PillLabel(text: "缺少密钥", color: Theme.warning, symbol: "key.slash")
        } else {
            PillLabel(text: "无需密钥", color: .secondary, symbol: "key.slash")
        }
    }

    // MARK: Sections

    private var basicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("基本信息")).font(.subheadline.weight(.semibold))

            FormField(label: "名称", error: fieldError(.name)) {
                TextField(L("例如：DeepSeek 主力"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .onChange(of: draft.name) { _, _ in clearError(.name) }
            }

            HStack(alignment: .bottom, spacing: 10) {
                FormField(
                    label: "类型",
                    hint: "切换类型会自动填入默认地址与模型；手动修改过的值不会被覆盖。"
                ) {
                    Picker(L("类型"), selection: $draft.kind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 190, alignment: .leading)
                }
                Button(L("恢复默认")) {
                    draft.baseURL = draft.kind.defaultBaseURL
                    draft.model = draft.kind.defaultModel
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(L("恢复所选类型的默认地址与模型"))
            }

            FormField(label: "Base URL", hint: baseURLHint, error: fieldError(.baseURL)) {
                TextField("https://…", text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedField, equals: .baseURL)
                    .onChange(of: draft.baseURL) { _, _ in clearError(.baseURL) }
            }

            FormField(label: "模型", hint: modelHint, error: fieldError(.model)) {
                TextField(L("模型名称"), text: $draft.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedField, equals: .model)
                    .onChange(of: draft.model) { _, _ in clearError(.model) }
            }
        }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("API Key").font(.subheadline.weight(.semibold))
                PillLabel(
                    text: draft.requiresAPIKey ? "需密钥" : "可选",
                    color: draft.requiresAPIKey ? Theme.warning : .secondary
                )
                Spacer()
            }

            HStack(spacing: 8) {
                Group {
                    if showsSecret {
                        TextField(secretPlaceholder, text: $secret)
                    } else {
                        SecureField(secretPlaceholder, text: $secret)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                Button {
                    showsSecret.toggle()
                } label: {
                    Image(systemName: showsSecret ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                }
                .buttonStyle(.glass)
                .help(showsSecret ? "隐藏密钥" : "显示密钥")
                .accessibilityLabel(showsSecret ? "隐藏密钥" : "显示密钥")
            }

            if draft.kind == .ollama {
                Text(L("本地 Ollama 通常无需密钥；仅在代理要求鉴权时填写。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if draft.hasAPIKey {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.success)
                    Text(L("已保存到 macOS Keychain"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(L("清除已保存密钥…"), role: .destructive) {
                        showsClearKeyConfirm = true
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .disabled(onDeleteKey == nil)
                }
            } else if !trimmedSecret.isEmpty {
                Label(L("保存后写入 Keychain"), systemImage: "key.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.info)
            } else if draft.requiresAPIKey {
                Label(L("尚未填写密钥；保存后可在通道列表继续编辑"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
            }

            Text(L("只保存在 macOS Keychain；配置文件仅记录引用名，不包含明文密钥。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("生成参数")).font(.subheadline.weight(.semibold))

            DisclosureGroup(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    FormField(
                        label: "回复最大长度",
                        hint: "单次回复最多生成的 token 数；越大回复可能越长，也越消耗额度。"
                    ) {
                        Stepper(
                            Lf("%d tokens", draft.maxTokens),
                            value: $draft.maxTokens,
                            in: 64...32_000,
                            step: 128
                        )
                        .font(.callout)
                    }

                    FormField(
                        label: "请求超时",
                        hint: "单次请求的最长等待时间；本地模型或长回复可适当调大。"
                    ) {
                        Stepper(
                            Lf("%d 秒", Int(draft.timeoutSeconds)),
                            value: $draft.timeoutSeconds,
                            in: 5...300,
                            step: 5
                        )
                        .font(.callout)
                    }

                    Toggle(L("流式返回（逐字输出）"), isOn: $draft.stream)
                        .toggleStyle(.switch)
                        .font(.callout)

                    if globalStreamingEnabled {
                        Text(L("开启后逐字显示；部分兼容端点可能不支持流式。"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Label(
                            L("全局「请求策略 → 流式回复」已关闭，此开关当前不生效。"),
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 8) {
                    Label(L("高级参数"), systemImage: "slider.horizontal.3")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(advancedSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Derived

    private var trimmedSecret: String {
        secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var secretPlaceholder: String {
        draft.hasAPIKey ? L("已保存，留空保持不变") : "sk-…"
    }

    private var advancedSummary: String {
        Lf(
            "%d tokens · 超时 %d 秒 · %@",
            draft.maxTokens,
            Int(draft.timeoutSeconds),
            draft.stream ? L("流式") : L("非流式")
        )
    }

    private var baseURLHint: String {
        switch draft.kind {
        case .deepSeek:
            return L("OpenAI 兼容接口根地址，例如 https://api.deepseek.com/v1")
        case .openAI:
            return L("OpenAI 兼容接口根地址，例如 https://api.openai.com/v1")
        case .ollama:
            return L("本地服务地址，例如 http://127.0.0.1:11434/v1")
        case .custom:
            return L("填写服务的 OpenAI 兼容根地址，通常以 /v1 结尾")
        }
    }

    private var modelHint: String {
        switch draft.kind {
        case .deepSeek:
            return L("请求时使用的模型名称，例如 deepseek-chat")
        case .openAI:
            return L("例如 gpt-4o-mini")
        case .ollama:
            return L("例如 qwen3:8b")
        case .custom:
            return L("填写服务端实际的模型 ID")
        }
    }

    private func fieldError(_ field: Field) -> String? {
        invalidField == field ? validationMessage : nil
    }

    // MARK: Defaults

    private func applyEmptyDefaults() {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = draft.kind.label
        }
        if draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.baseURL = draft.kind.defaultBaseURL
        }
        if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.model = draft.kind.defaultModel
        }
    }

    /// 切换类型时只为「空值 / 仍等于旧类型默认值」的字段填入新类型默认值，
    /// 不覆盖用户手改的地址或模型；名称规则相同（未改过名称才跟随类型）。
    private func applyKindDefaults(from oldKind: ProviderKind, to newKind: ProviderKind) {
        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty || baseURL == oldKind.defaultBaseURL {
            draft.baseURL = newKind.defaultBaseURL
        }

        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty || model == oldKind.defaultModel {
            draft.model = newKind.defaultModel
        }

        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == oldKind.label || name == L("新通道") {
            draft.name = newKind.label
        }
    }

    // MARK: Validation

    private func clearError(_ field: Field) {
        guard invalidField == field else { return }
        invalidField = nil
        validationMessage = nil
    }

    private func fail(_ field: Field, _ message: String) {
        invalidField = field
        validationMessage = message
        focusedField = field
    }

    private func save() {
        var candidate = draft
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.baseURL = candidate.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.model = candidate.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            candidate.apiKeyReference = candidate.apiKeyReference.isEmpty ? candidate.id : candidate.apiKeyReference
        }

        guard !candidate.name.isEmpty else {
            fail(.name, "请填写通道名称。")
            return
        }
        guard isValidBaseURL(candidate.baseURL) else {
            fail(.baseURL, "Base URL 必须是合法的 http(s) 地址。")
            return
        }
        guard !candidate.model.isEmpty else {
            fail(.model, "请填写模型名称，例如 deepseek-chat。")
            return
        }

        invalidField = nil
        validationMessage = nil
        onSave(candidate, trimmedSecret.isEmpty ? nil : trimmedSecret)
        dismiss()
    }

    private func isValidBaseURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else {
            return false
        }
        return true
    }
}
