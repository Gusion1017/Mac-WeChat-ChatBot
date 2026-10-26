import AppKit
import SwiftUI

// MARK: - Layout

/// Simple wrapping layout for keyword chips and filter rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            contentWidth = max(contentWidth, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? min(contentWidth, maxWidth) : contentWidth
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Chips

/// Selectable capsule used for filters (log levels, schedule filters...).
struct FilterChip: View {
    let title: String
    var symbol: String?
    var count: Int?
    var isSelected: Bool
    var tint: Color = Theme.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                }
                Text(L(title)).font(.caption.weight(.medium))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            (isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)),
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isSelected ? tint : Color.primary.opacity(0.055), in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Non-interactive tag, optionally removable (keywords, weekdays...).
struct TagChip: View {
    let title: String
    var tint: Color = Theme.accent
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(L(title)).font(.caption.weight(.medium))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("移除") + " \(title)")
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Buttons

/// Icon-only glass button used in toolbars and row accessories.
struct IconActionButton: View {
    let symbol: String
    var help: String
    var tint: Color = .secondary
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .disabled(!isEnabled)
        .help(L(help))
        .accessibilityLabel(L(help))
    }
}

/// Copy-to-pasteboard button with transient checkmark feedback.
struct CopyButton: View {
    let text: String
    var accessibilityText: String = "复制"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(copied ? Theme.success : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(L(accessibilityText))
        .accessibilityLabel(L(accessibilityText))
    }
}

// MARK: - Forms & rows

/// Labelled form control with hint / validation error.
struct FormField<Content: View>: View {
    let label: String
    var hint: String?
    var error: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(label))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            content
            if let error {
                Label(L(error), systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            } else if let hint {
                Text(L(hint))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Compact read-only key/value row for details panels.
struct KeyValueRow: View {
    let label: String
    let value: String
    var mono: Bool = false
    var valueColor: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L(label))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Monospaced path row with copy button.
struct PathRow: View {
    let label: String
    let path: String
    var showCopy: Bool = true
    var revealInFinder: Bool = false
    var labelWidth: CGFloat = 96

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(L(label))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(UIFormat.compactPath(path))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer(minLength: 4)
            if showCopy, !path.isEmpty {
                CopyButton(text: path, accessibilityText: L("复制路径"))
            }
            if revealInFinder, !path.isEmpty {
                Button {
                    let url = URL(fileURLWithPath: path)
                    let target = FileManager.default.fileExists(atPath: path) ? url : url.deletingLastPathComponent()
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("在 Finder 中显示"))
                .accessibilityLabel(L("在 Finder 中显示") + " \(L(label))")
            }
        }
    }
}

/// Inline informational banner (service unavailable, Keychain notice, risks...).
enum NoticeKind {
    case info
    case success
    case warning
    case danger

    var tint: Color {
        switch self {
        case .info: Theme.info
        case .success: Theme.success
        case .warning: Theme.warning
        case .danger: Theme.danger
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }
}

struct InlineNotice: View {
    var kind: NoticeKind = .info
    var title: String?
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind.tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(L(title))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(kind.tint)
                }
                Text(L(message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(kind.tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(kind.tint.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Search

/// Compact custom search field that fits the app's toolbar styling.
struct SearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L(placeholder), text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("清除搜索"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }
}

// MARK: - Settings forms

/// Grouped settings card: title + material container + optional footer.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L(title))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
            if let footer {
                Text(L(footer))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = .secondary
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 18, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.callout)
                if let subtitle {
                    Text(L(subtitle))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.leading, 14)
            .accessibilityHidden(true)
    }
}

/// A small inline "未连接 / 未配置" state label used in settings rows.
struct UnavailableLabel: View {
    var text: String = "服务未连接"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 9, weight: .semibold))
            Text(L(text)).font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Page sub-navigation

/// One entry of a `PageTabBar`. Titles are Chinese source strings and get
/// localized by the bar itself, so pages only declare the raw section names.
protocol PageTabItem: Identifiable, Hashable {
    var tabTitle: String { get }
    var tabSymbol: String { get }
    /// Optional tooltip / VoiceOver hint describing what the section contains.
    var tabHelp: String? { get }
}

extension PageTabItem {
    var tabHelp: String? { nil }
}

/// Sticky sub-navigation for pages whose settings no longer fit on one screen
/// (currently 机器人). Pill tabs inside a translucent capsule track: the
/// selected tab keeps the brand tint, the others stay quiet until hover.
struct PageTabBar<Tab: PageTabItem>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    var tint: Color = Theme.accent

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabRow
            // 极端窄窗口或超大字号时退化为横向滚动，避免 pill 被截断。
            ScrollView(.horizontal, showsIndicators: false) {
                tabRow
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.045), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var tabRow: some View {
        HStack(spacing: 3) {
            ForEach(tabs) { tab in
                PageTabButton(
                    title: tab.tabTitle,
                    help: tab.tabHelp,
                    symbol: tab.tabSymbol,
                    isSelected: selection == tab,
                    tint: tint
                ) {
                    guard selection != tab else { return }
                    selection = tab
                }
            }
        }
    }
}

private struct PageTabButton: View {
    let title: String
    let help: String?
    let symbol: String
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .accessibilityHidden(true)
                Text(L(title))
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.82)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: tint.opacity(0.24), radius: 4, y: 1.5)
                } else if isHovering {
                    Capsule().fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(L(help ?? title))
        .animation(Theme.animation(reduceMotion, .easeOut(duration: 0.12)), value: isSelected)
        .animation(Theme.animation(reduceMotion, .easeOut(duration: 0.12)), value: isHovering)
        .accessibilityLabel(L(title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
