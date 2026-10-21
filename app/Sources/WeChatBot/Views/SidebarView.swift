import SwiftUI

/// Custom sidebar: brand header, three navigation groups and a live status capsule.
/// Visual language follows native macOS sidebars while keeping the app's green identity.
struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredItem: SidebarItem?

    private struct SidebarSection: Identifiable {
        let id: String
        let title: String
        let items: [SidebarItem]
    }

    private let sections: [SidebarSection] = [
        SidebarSection(id: "main", title: "常用", items: SidebarItem.main),
        SidebarSection(id: "automation", title: "自动化", items: SidebarItem.automation),
        SidebarSection(id: "system", title: "系统", items: SidebarItem.system)
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                brand
                    .padding(.top, Theme.titlebarInset)
                    .padding(.horizontal, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(sections) { section in
                            sidebarSection(section)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)

                Divider().opacity(0.5)

                VStack(spacing: 4) {
                    SidebarStatusCapsule()
                    footer
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 9)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }

    // MARK: Brand

    private var brand: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentStrong],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 30, height: 30)
                    .shadow(color: Theme.accent.opacity(0.3), radius: 5, y: 2)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("WeChat AI")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                Text(L("微信智能助手"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("WeChat AI 微信智能助手"))
    }

    // MARK: Navigation

    private func sidebarSection(_ section: SidebarSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 9)
                .padding(.bottom, 2)
            ForEach(section.items) { item in
                sidebarItem(item)
            }
        }
    }

    private func sidebarItem(_ item: SidebarItem) -> some View {
        let isSelected = store.sidebarSelection == item
        return Button {
            if item == .conversations, isSelected {
                // 会话页内再次点击「会话」：收起当前打开的对话（列表保持可见）。
                // 已没有打开对话时保持当前页面，不做额外动作。
                if store.selectedConversationID != nil {
                    store.selectedConversationID = nil
                }
                return
            }
            store.sidebarSelection = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.uiSymbol)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(item.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if item == .conversations, totalUnread > 0 {
                    Text("\(totalUnread)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(itemBackground(item, isSelected: isSelected))
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
                }
            }
            // Scoped to the row highlight only: color-only animation, no layout change.
            .animation(reduceMotion ? nil : .smooth(duration: 0.14), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { hoveredItem = $0 ? item : (hoveredItem == item ? nil : hoveredItem) }
        .help(helpText(for: item, isSelected: isSelected))
        .accessibilityLabel(item.title)
        .accessibilityHint(hintText(for: item, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func helpText(for item: SidebarItem, isSelected: Bool) -> String {
        if item == .conversations, isSelected, store.selectedConversationID != nil {
            return "再次点击收起当前对话（\(item.shortcutLabel)）"
        }
        return "\(item.title)（\(item.shortcutLabel)）"
    }

    private func hintText(for item: SidebarItem, isSelected: Bool) -> String {
        guard item == .conversations, isSelected, store.selectedConversationID != nil else {
            return ""
        }
        return "收起当前对话"
    }

    private func itemBackground(_ item: SidebarItem, isSelected: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.15) }
        if hoveredItem == item { return Color.primary.opacity(0.045) }
        return .clear
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.grid.2x2")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(appVersion)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 2)
            Button {
                store.sidebarSelection = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("设置（⌘,）"))
            .accessibilityLabel(L("打开设置"))
        }
        .padding(.horizontal, 4)
        .padding(.top, 3)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "版本 \(version)"
    }

    private var totalUnread: Int {
        store.conversations.reduce(0) { $0 + max(0, $1.unreadCount) }
    }
}

// MARK: - Status capsule

/// Bottom status capsule: 机器人运行状态 + 微信 / Hook / AI 三个指示灯.
struct SidebarStatusCapsule: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            store.sidebarSelection = .bot
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    StatusDot(
                        color: store.isBotRunning ? Theme.success : .secondary,
                        size: 6,
                        pulsing: store.isBotRunning
                    )
                    Text(store.isBotRunning ? "机器人运行中" : "机器人已停止")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(store.isBotRunning ? Theme.success : Color.secondary)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                Divider().opacity(0.45)

                statusLine(
                    symbol: "iphone",
                    label: "微信",
                    value: wechatValue,
                    color: wechatColor
                )
                statusLine(
                    symbol: "link",
                    label: "Hook",
                    value: hookValue,
                    color: hookColor
                )
                statusLine(
                    symbol: "sparkles",
                    label: "AI",
                    value: aiValue,
                    color: aiColor
                )
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .glassEffect(
                .regular.tint((store.isBotRunning ? Theme.accent : Color.primary).opacity(0.045)),
                in: .rect(cornerRadius: 13)
            )
        }
        .buttonStyle(.plain)
        .help(L("查看机器人状态"))
        .accessibilityLabel(L("机器人状态"))
        .accessibilityValue("机器人\(store.isBotRunning ? "运行中" : "已停止")，微信\(wechatValue)，Hook \(hookValue)，AI \(aiValue)")
    }

    private func statusLine(symbol: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 11)
            Text(L(label))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            Spacer(minLength: 2)
            StatusDot(color: color, size: 5)
            Text(value)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var wechatValue: String {
        if store.hookStatus.wechatRunning { return "运行中" }
        if !store.hookStatus.wechatVersion.isEmpty { return "未运行" }
        return "未检测"
    }

    private var wechatColor: Color {
        store.hookStatus.wechatRunning ? Theme.success : .secondary
    }

    private var hookValue: String {
        store.hookStatus.state.label
    }

    private var hookColor: Color {
        Theme.hookColor(store.hookStatus.state)
    }

    private var aiValue: String {
        guard let provider = store.defaultProvider else { return "未配置" }
        if !provider.enabled { return "已停用" }
        if provider.kind == .ollama || provider.hasAPIKey { return "已配置" }
        return "缺少密钥"
    }

    private var aiColor: Color {
        guard let provider = store.defaultProvider, provider.enabled else { return .secondary }
        if provider.kind == .ollama || provider.hasAPIKey { return Theme.success }
        return Theme.warning
    }
}

// MARK: - Sidebar metadata helpers

extension SidebarItem {
    /// macOS 26 renders `person.crop.circle.badge.quote` inconsistently; the
    /// sidebar uses a stable alternative while Models keeps its declared symbol.
    var uiSymbol: String {
        switch self {
        case .personas: "person.crop.circle"
        default: symbol
        }
    }

    var shortcutLabel: String {
        guard let index = SidebarItem.allCases.firstIndex(of: self) else { return "" }
        if index < 9 { return "⌘\(index + 1)" }
        return "⌘0"
    }
}
