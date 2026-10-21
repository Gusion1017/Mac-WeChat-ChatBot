import SwiftUI

/// Visual state of an AI provider connection test.
enum ProviderTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)

    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

extension ProviderKind {
    /// SF Symbol used to identify the provider channel.
    var uiSymbol: String {
        switch self {
        case .deepSeek: "sparkle"
        case .openAI: "circle.hexagongrid.fill"
        case .ollama: "desktopcomputer"
        case .custom: "slider.horizontal.3"
        }
    }
}

struct ProviderRow: View {
    let provider: AIProvider
    let isDefault: Bool
    var testState: ProviderTestState = .idle
    var canDelete: Bool = true
    var onEdit: () -> Void
    var onTest: () -> Void
    var onDelete: () -> Void
    var onToggleEnabled: (Bool) -> Void

    private var tint: Color { Theme.providerTint(provider.kind) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: provider.kind.uiSymbol, tint: tint, size: 36)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    PillLabel(text: provider.kind.label, color: tint)
                    if isDefault {
                        PillLabel(text: "默认", color: Theme.accent, symbol: "star.fill", filled: true)
                    }
                    if !provider.enabled {
                        PillLabel(text: "已停用", color: .secondary)
                    }
                }

                HStack(spacing: 8) {
                    Text(hostLabel)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(provider.model.isEmpty ? "未设置模型" : provider.model)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    apiKeyState
                    Text("≤ \(provider.maxTokens) tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if provider.stream {
                        PillLabel(text: "流式", color: Theme.info, symbol: "waveform")
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 8) {
                    testStatusView
                    Toggle(
                        "启用",
                        isOn: Binding(get: { provider.enabled }, set: { onToggleEnabled($0) })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(provider.enabled ? "停用此通道" : "启用此通道")
                    .accessibilityLabel(L("启用 \(provider.name)"))
                }

                HStack(spacing: 6) {
                    Button(L("编辑")) { onEdit() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Menu {
                        Button(L("编辑…"), action: onEdit)
                        Button(L("测试连接"), action: onTest)
                        Divider()
                        Button(L("删除通道…"), role: .destructive, action: onDelete)
                            .disabled(!canDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L("更多操作"))
                    .accessibilityLabel(L("\(provider.name) 更多操作"))
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isDefault ? Theme.accent.opacity(0.25) : Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var hostLabel: String {
        guard let url = URL(string: provider.baseURL), let host = url.host else {
            return provider.baseURL.isEmpty ? "未设置地址" : provider.baseURL
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    private var apiKeyState: some View {
        HStack(spacing: 3) {
            Image(systemName: provider.hasAPIKey ? "key.fill" : "key.slash")
                .font(.system(size: 8.5, weight: .semibold))
            Text(provider.hasAPIKey ? "密钥已登记" : "未配置密钥")
                .font(.caption2)
        }
        .foregroundStyle(provider.hasAPIKey ? Theme.success : Color.secondary)
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testState {
        case .idle:
            Button {
                onTest()
            } label: {
                Label(L("测试"), systemImage: "bolt.horizontal")
                    .font(.caption2)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(L("测试此通道连接"))
        case .testing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(L("测试中")).font(.caption2).foregroundStyle(.secondary)
            }
        case .success(let detail):
            Label(L("连接正常"), systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.success)
                .help(detail)
        case .failure(let detail):
            Label(L("连接失败"), systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.danger)
                .help(detail)
        }
    }
}
