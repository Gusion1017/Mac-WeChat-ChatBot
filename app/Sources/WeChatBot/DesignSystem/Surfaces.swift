import SwiftUI

// MARK: - Glass surfaces

/// Liquid Glass card used for the app's primary content blocks.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = Theme.cardPadding
    var cornerRadius: CGFloat = Theme.cornerRadius
    var tint: Color = Theme.accent
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                .regular.tint(tint.opacity(0.045)),
                in: .rect(cornerRadius: cornerRadius)
            )
    }
}

/// Card with a standard title / subtitle / accessory header.
struct SectionCard<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = Theme.accent
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        tint: Color = Theme.accent,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        GlassCard(tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(title)).font(.headline)
                        if let subtitle {
                            Text(L(subtitle)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                content
            }
        }
    }
}

extension SectionCard where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        tint: Color = Theme.accent,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tint: tint, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Page chrome

/// Sticky page header with a translucent material, matching native macOS toolbars.
struct GlassToolbar<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title))
                    .font(Theme.pageTitle)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(L(subtitle))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { trailing }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }
}

extension GlassToolbar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Standard scrolling page: translucent toolbar + scrollable padded content.
struct ScrollingPage<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassToolbar(title: title, subtitle: subtitle) { actions }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    content
                }
                .padding(Theme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .background(PageBackground())
    }
}

extension ScrollingPage where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, actions: { EmptyView() }, content: content)
    }
}

// MARK: - Small identity pieces

/// Rounded-square symbol tile used for providers / status cards / onboarding.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint, tint.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: tint.opacity(0.28), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}

/// Placeholder avatar for a conversation: stable per-title tint + initial or kind symbol.
struct AvatarView: View {
    let title: String
    var kind: ConversationKind = .direct
    var size: CGFloat = 38

    private var initial: String? {
        guard let first = title.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        return String(first).uppercased()
    }

    var body: some View {
        // Resolve the stable tint once per body instead of hashing the title twice.
        let tint = Theme.avatarTint(for: title)
        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if let initial, kind != .group {
                Text(initial)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

// MARK: - Status pieces

/// Colored presence dot. A static halo communicates "live" without a
/// continuous animation (repeat-forever effects inside Liquid Glass cause
/// constant backdrop re-rendering and measurable idle CPU).
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var pulsing: Bool = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: size * 2.1, height: size * 2.1)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .frame(width: size * 1.9, height: size * 1.9)
        .accessibilityHidden(true)
    }
}

/// Capsule label, e.g. "已连接", "默认", "工作时段".
struct PillLabel: View {
    let text: String
    var color: Color = Theme.accent
    var symbol: String?
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(L(text)).font(.caption2.weight(.medium))
        }
        .foregroundStyle(filled ? Color.white : color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(filled ? color : color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Headline section title with optional subtitle.
struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).font(.title2.weight(.semibold))
            if let subtitle {
                Text(L(subtitle)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Metrics

/// Compact statistic tile used on the dashboard.
struct MetricTile: View {
    let title: String
    let value: String
    var unit: String?
    var symbol: String
    var tint: Color = Theme.accent
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(L(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.metricSmall)
                    .contentTransition(.numericText())
                if let unit {
                    Text(L(unit)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(L(detail))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
