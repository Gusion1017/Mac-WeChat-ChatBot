import SwiftUI

/// Compact status card: icon, current value, live indicator and detail line.
/// Used on the dashboard for 微信 / Hook / AI 三个健康状态。
struct StatusCard: View {
    let title: String
    let value: String
    var detail: String?
    let symbol: String
    var tint: Color = Theme.accent
    var statusText: String?
    var statusTint: Color = .secondary
    var isLive: Bool = false
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { card }.buttonStyle(.plain)
            } else {
                card
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)\(statusText.map { "，\($0)" } ?? "")")
    }

    private var card: some View {
        GlassCard(padding: 15, cornerRadius: 16, tint: tint) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    IconTile(symbol: symbol, tint: tint, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L(title))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        StatusDot(color: statusTint, size: 7, pulsing: isLive)
                        if let statusText {
                            Text(statusText)
                                .font(.caption2)
                                .foregroundStyle(statusTint)
                                .lineLimit(1)
                        }
                    }
                }
                if let detail {
                    Text(L(detail))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Large tap target used by the dashboard quick-actions block.
struct QuickActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.accent
    var isBusy: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.12))
                        .frame(width: 32, height: 32)
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                Text(L(title))
                    .font(.caption)
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(title)
    }
}
