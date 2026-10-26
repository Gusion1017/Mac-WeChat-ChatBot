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

    /// 测试结果详情（成功耗时/tokens 或失败原因）。UI 直接展开显示，不再只放在 tooltip 里。
    var detail: String? {
        switch self {
        case .success(let detail), .failure(let detail): return detail
        case .idle, .testing: return nil
        }
    }

    var isFailure: Bool {
        if case .failure = self { return true }
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
    /// 全局流式总开关。关闭时「流式」标签需要说明暂不生效，避免和实际请求行为矛盾。
    var globalStreamingEnabled: Bool = true
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
                    Text(provider.model.isEmpty ? L("未设置模型") : provider.model)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    apiKeyState
                    Text(Lf("输出上限 %d tokens", provider.maxTokens))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(Lf("超时 %d 秒", Int(provider.timeoutSeconds)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    streamPill
                }

                if let detail = testState.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(testState.isFailure ? Theme.danger : Theme.success)
                        .lineLimit(2)
                        .help(detail)
                        .accessibilityLabel(L("连接测试结果"))
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
                    .accessibilityLabel(Lf("启用 %@", provider.name))
                }

                HStack(spacing: 6) {
                    Button(L("编辑")) { onEdit() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.danger)
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.glass)
                    .disabled(!canDelete)
                    .help(canDelete ? "删除通道" : "至少保留一个通道")
                    .accessibilityLabel(L("删除通道"))
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

    private var keyStatus: (text: String, color: Color, symbol: String) {
        if provider.hasAPIKey {
            return ("密钥已登记", Theme.success, "key.fill")
        }
        if provider.requiresAPIKey {
            return ("缺少 API Key", Theme.warning, "key.slash")
        }
        if provider.kind == .ollama {
            return ("无需密钥", .secondary, "key.slash")
        }
        return ("密钥可选", .secondary, "key.slash")
    }

    private var apiKeyState: some View {
        let status = keyStatus
        return HStack(spacing: 3) {
            Image(systemName: status.symbol)
                .font(.system(size: 8.5, weight: .semibold))
            Text(L(status.text))
                .font(.caption2)
        }
        .foregroundStyle(status.color)
    }

    @ViewBuilder
    private var streamPill: some View {
        if provider.stream && globalStreamingEnabled {
            PillLabel(text: "流式", color: Theme.info, symbol: "waveform")
        } else if provider.stream {
            PillLabel(text: "流式已暂停", color: .secondary, symbol: "pause.circle")
        } else {
            PillLabel(text: "非流式", color: .secondary, symbol: "text.alignleft")
        }
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
