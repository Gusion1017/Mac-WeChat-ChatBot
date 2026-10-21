import SwiftUI

/// Add / edit sheet for an OpenAI-compatible AI channel.
struct ProviderEditorSheet: View {
    let provider: AIProvider
    let isNew: Bool
    let onDeleteKey: (() -> Void)?
    let onSave: (AIProvider, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AIProvider
    @State private var secret: String = ""
    @State private var showsSecret = false
    @State private var validationMessage: String?

    init(
        provider: AIProvider,
        isNew: Bool,
        onDeleteKey: (() -> Void)? = nil,
        onSave: @escaping (AIProvider, String?) -> Void
    ) {
        self.provider = provider
        self.isNew = isNew
        self.onDeleteKey = onDeleteKey
        self.onSave = onSave
        _draft = State(initialValue: provider)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    basicsSection
                    keySection
                    parametersSection
                    statusSection

                    if let validationMessage {
                        InlineNotice(kind: .danger, title: "无法保存", message: validationMessage)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 580, height: 640)
        .background(.regularMaterial)
        .onAppear {
            if draft.baseURL.isEmpty { draft.baseURL = draft.kind.defaultBaseURL }
            if draft.model.isEmpty { draft.model = draft.kind.defaultModel }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 11) {
            IconTile(symbol: draft.kind.uiSymbol, tint: Theme.providerTint(draft.kind), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(isNew ? "添加 AI 通道" : "编辑 AI 通道"))
                    .font(.headline)
                Text(L("OpenAI 兼容接口 · 密钥安全存储"))
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
            if !isNew {
                PillLabel(
                    text: draft.hasAPIKey ? "密钥已登记" : "未登记密钥",
                    color: draft.hasAPIKey ? Theme.success : .secondary,
                    symbol: draft.hasAPIKey ? "key.fill" : "key.slash"
                )
            }
            Spacer()
            Button(L("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "添加通道" : "保存") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    // MARK: Sections

    private var basicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("基本信息")).font(.subheadline.weight(.semibold))

            FormField(label: "名称") {
                TextField(L("例如：DeepSeek 主力"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .bottom, spacing: 10) {
                FormField(label: "类型") {
                    Picker(L("类型"), selection: $draft.kind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200, alignment: .leading)
                }
                Button(L("填入默认地址与模型")) {
                    draft.baseURL = draft.kind.defaultBaseURL
                    draft.model = draft.kind.defaultModel
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            FormField(
                label: "Base URL",
                hint: "OpenAI 兼容接口根地址，例如 https://api.deepseek.com/v1"
            ) {
                TextField("https://…", text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            FormField(label: "模型", hint: "请求时使用的模型名称，例如 deepseek-chat") {
                TextField(L("模型名称"), text: $draft.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API Key").font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                Group {
                    if showsSecret {
                        TextField("sk-…", text: $secret)
                    } else {
                        SecureField("sk-…", text: $secret)
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

            InlineNotice(
                kind: .info,
                title: "密钥不会写入配置文件",
                message: "API Key 保存在 macOS Keychain（service com.gusionw.wechatai），config.json 仅保存 Keychain 引用名。"
            )

            if draft.hasAPIKey {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.success)
                    Text(L("已登记 Keychain 引用：\(draft.apiKeyReference)"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button(L("清除已保存密钥"), role: .destructive) {
                        onDeleteKey?()
                        dismiss()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .disabled(onDeleteKey == nil)
                }
            }
        }
    }

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("生成参数")).font(.subheadline.weight(.semibold))

            Text(L("温度不随通道设置，改在「模型温度」中按模型单独配置；未配置时由模型使用自身默认值。"))
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 16) {
                Stepper(
                    "最大 \(draft.maxTokens) tokens",
                    value: $draft.maxTokens,
                    in: 64...32_000,
                    step: 128
                )
                .font(.callout)
                Stepper(
                    "超时 \(Int(draft.timeoutSeconds)) 秒",
                    value: $draft.timeoutSeconds,
                    in: 5...300,
                    step: 5
                )
                .font(.callout)
            }

            Toggle(L("流式返回（逐字输出）"), isOn: $draft.stream)
                .toggleStyle(.switch)
                .font(.callout)

            Text(L("仅在「AI 模型 → 全局请求」开启流式回复时生效；全局关闭时所有通道都不流式。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("状态")).font(.subheadline.weight(.semibold))
            Text(L("启用 / 停用请在通道列表使用开关；新添加的通道默认启用。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(L("默认通道在「AI 模型 → 全局请求」中设置。停用后不会用于自动回复。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Validation

    private func save() {
        var candidate = draft
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.baseURL = candidate.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.model = candidate.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if secret.isEmpty == false {
            candidate.apiKeyReference = candidate.apiKeyReference.isEmpty ? candidate.id : candidate.apiKeyReference
        }

        guard !candidate.name.isEmpty else {
            validationMessage = "请填写通道名称。"
            return
        }
        guard !candidate.model.isEmpty else {
            validationMessage = "请填写模型名称，例如 deepseek-chat。"
            return
        }
        guard let url = URL(string: candidate.baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            validationMessage = "Base URL 必须是合法的 http(s) 地址。"
            return
        }
        guard candidate.maxTokens > 0 else {
            validationMessage = "最大 token 必须大于 0。"
            return
        }
        guard candidate.timeoutSeconds >= 5 else {
            validationMessage = "超时时间至少为 5 秒。"
            return
        }

        validationMessage = nil
        onSave(candidate, secret.isEmpty ? nil : secret)
        dismiss()
    }
}
