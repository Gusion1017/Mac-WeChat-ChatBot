import Observation
import SwiftUI

// MARK: - Empty / loading states

/// Unified empty state used by every list page.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent.opacity(0.16), Theme.info.opacity(0.07)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 4) {
                Text(title).font(.headline)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .accessibilityElement(children: .combine)
    }
}

struct LoadingState: View {
    var title: String = "加载中…"

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
    }
}

/// Pulsing placeholder for content that is still loading.
struct SkeletonBlock: View {
    var height: CGFloat = 12
    var width: CGFloat?
    var radius: CGFloat = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(reduceMotion ? 0.07 : (animate ? 0.105 : 0.055)))
            .frame(width: width, height: height)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                value: animate
            )
            .onAppear { animate = true }
            .accessibilityHidden(true)
    }
}

/// Indeterminate or determinate progress block for long-running operations
/// (Hook install, restore...).
struct ProgressPanel: View {
    let title: String
    var detail: String?
    var progress: Double?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(tint)
                Text(title).font(.callout.weight(.medium))
                Spacer(minLength: 6)
                if let progress {
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(tint)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Confirmation sheet

/// Reusable destructive confirmation sheet with optional detail bullets.
struct ConfirmSheet: View {
    let title: String
    let message: String
    var details: [String] = []
    var confirmTitle: String = "确认"
    var cancelTitle: String = "取消"
    var isDestructive: Bool = true
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var tint: Color { isDestructive ? Theme.danger : Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                Image(systemName: isDestructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("请确认此操作")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(details, id: \.self) { item in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(tint)
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text(item)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            HStack(spacing: 9) {
                Spacer()
                Button(cancelTitle, role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(.regularMaterial)
    }
}

// MARK: - Toast

enum ToastTone {
    case info
    case success
    case warning
    case error

    var tint: Color {
        switch self {
        case .info: Theme.info
        case .success: Theme.success
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let tone: ToastTone
    let symbol: String
}

@MainActor
@Observable
final class ToastCenter {
    private(set) var current: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, tone: ToastTone = .info, symbol: String? = nil) {
        dismissTask?.cancel()
        withAnimation(.snappy(duration: 0.22)) {
            current = ToastMessage(text: text, tone: tone, symbol: symbol ?? tone.symbol)
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.2)) { self?.current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

struct ToastView: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(message.tone.tint)
            Text(message.text)
                .font(.callout)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(
            .regular.tint(message.tone.tint.opacity(0.12)),
            in: .capsule
        )
    }
}

struct ToastOverlay: View {
    @Environment(ToastCenter.self) private var center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let message = center.current {
                ToastView(message: message)
                    .padding(.bottom, 18)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: center.current?.id)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Bottom-anchored toast overlay; require a `ToastCenter` in the environment.
    func toastOverlay() -> some View {
        overlay(alignment: .bottom) { ToastOverlay() }
    }
}
