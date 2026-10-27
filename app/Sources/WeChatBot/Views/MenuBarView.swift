import AppKit
import SwiftUI

/// 菜单栏面板的共享布局常量（`MenuBarController` 也用它做尺寸兜底）。
enum MenuBarPanelLayout {
    /// 272pt：状态值与三列统计不换行，同时保持控制中心式的紧凑节奏。
    static let width: CGFloat = 272
}

/// 菜单栏快捷面板：实时状态、启动/停止、打开主窗口、页面直达与退出。
///
/// 左键单击菜单栏图标现在直接弹出本面板（不再打开主窗口），因此面板里必须有
/// 「打开主窗口」入口；所有导航/打开主窗口动作完成后都会由 `onNavigate` 收起面板。
struct MenuBarView: View {
    /// 面板内导航结束后的回调（由 `MenuBarController` 用于收起面板）。
    var onNavigate: (() -> Void)?

    @Environment(AppStore.self) private var store
    /// 启动/停止是异步的，本地状态只用于避免重复点击与给出静态文字反馈。
    @State private var isToggling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            sectionDivider
            statusSection
            sectionDivider
            actionsSection
            sectionDivider
            footer
        }
        .frame(width: MenuBarPanelLayout.width)
        // NSPopover 自带 popover 材质；这里不再叠加 regularMaterial，
        // 避免双层实时模糊在弹出/悬停期间掉帧。
        // 面板级不挂 .animation：统计/余额等数值变化必须即时刷新，不能触发整面板隐式动画。
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.horizontal, 10)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentStrong],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("WeChat AI")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                RunStatePill(isRunning: store.isBotRunning)
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                statusRow(
                    symbol: "iphone",
                    label: "微信",
                    value: store.hookStatus.wechatRunning ? "运行中" : (store.hookStatus.wechatVersion.isEmpty ? "未检测" : "未运行"),
                    color: store.hookStatus.wechatRunning ? Theme.success : .secondary
                )
                statusRow(
                    symbol: "link",
                    label: "Hook",
                    value: store.hookStatus.state.label,
                    color: Theme.hookColor(store.hookStatus.state)
                )
                statusRow(
                    symbol: "sparkles",
                    label: "AI",
                    value: store.defaultProvider?.name ?? "未配置",
                    color: store.defaultProvider?.enabled == true ? Theme.success : .secondary
                )
                statusRow(
                    symbol: batteryMenuSymbol,
                    label: "电量",
                    value: batteryMenuValue,
                    color: batteryMenuColor
                )
                statusRow(
                    symbol: "creditcard",
                    label: "余额",
                    value: balanceMenuValue,
                    color: balanceMenuColor
                )
            }

            statsStrip
                .padding(.top, 6)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("状态")))
    }

    /// 一行状态：固定图标 + 定宽 label 列 + 右对齐的「圆点 + 值」。
    ///
    /// label 与 value 同为 `.caption` 单行文本，因此同一行基线天然对齐；
    /// 值列右对齐让五行的读取节奏一致，长 provider 名/余额只在值列内截断。
    private func statusRow(
        symbol: String,
        label: String,
        value: String,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(L(label))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 44, alignment: .leading)
            Spacer(minLength: 4)
            StatusDot(color: color, size: 5)
            Text(L(value))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                // 截断时用 tooltip 兜底完整内容（AI 通道名、余额、长状态文案）。
                .help(L(value))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L(label)))
        .accessibilityValue(Text(L(value)))
    }

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statCell(icon: "arrow.down.message", value: "\(store.stats.receivedToday)", label: "收到")
            statDivider
            statCell(icon: "arrow.up.message", value: "\(store.stats.repliedToday)", label: "回复")
            statDivider
            statCell(icon: "timer", value: UIFormat.duration(milliseconds: store.stats.aiLatencyAverageMs), label: "延迟")
        }
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1, height: 16)
            .accessibilityHidden(true)
    }

    private func statCell(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            Text(L(label))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L(label)))
        .accessibilityValue(Text(value))
    }

    // MARK: - System vitals

    private var batteryMenuSymbol: String {
        let status = store.batteryStatus
        guard status.isPresent else { return "desktopcomputer" }
        switch status.percentage {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var batteryMenuValue: String {
        let status = store.batteryStatus
        guard status.isPresent else { return L("未检测到") }
        let stateText: String
        if status.isCharging {
            stateText = L("充电中")
        } else if status.isFullyCharged {
            stateText = L("已充满")
        } else if status.isOnExternalPower {
            stateText = L("已接电源")
        } else {
            stateText = L("电池供电")
        }
        return "\(status.percentage)% · \(stateText)"
    }

    private var batteryMenuColor: Color {
        let status = store.batteryStatus
        guard status.isPresent else { return .secondary }
        if status.percentage < 20 { return Theme.danger }
        if status.isCharging || status.isOnExternalPower { return Theme.accent }
        return status.percentage < 50 ? Theme.warning : Theme.success
    }

    private var balanceMenuValue: String {
        switch store.deepSeekBalance {
        case .idle, .loading: return L("查询中…")
        case .unavailable: return L("未配置")
        case .failed: return L("查询失败")
        case .loaded(let snapshot): return snapshot.primary?.displayTotal ?? L("无余额数据")
        }
    }

    private var balanceMenuColor: Color {
        switch store.deepSeekBalance {
        case .loaded(let snapshot): return snapshot.isAvailable ? Theme.success : Theme.danger
        case .failed: return Theme.warning
        case .idle, .loading, .unavailable: return .secondary
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 4) {
            // 1. 主操作：启动/停止，语义色 + 唯一带底色的按钮。
            MenuBarPrimaryButton(
                title: toggleTitle,
                symbol: toggleSymbol,
                tint: toggleTint,
                help: toggleHelp,
                isBusy: isToggling || store.isSwitchingAccount
            ) {
                toggleBot()
            }

            // 2. 左键直接弹面板后，打开主窗口是面板的必备出口。
            MenuBarRowButton(
                title: "打开主窗口",
                symbol: "macwindow",
                iconTint: Theme.accent,
                help: "打开主窗口并收起面板",
                showsChevron: true
            ) {
                openMainWindow()
            }

            // 3. 三个高频页面直达，横向紧凑排列，与上面两级操作区分层级。
            quickLinks
                .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("快捷操作")))
    }

    private var quickLinks: some View {
        HStack(spacing: 0) {
            navButton(title: "会话", symbol: "bubble.left.and.bubble.right", help: "打开会话") {
                open(.conversations)
            }
            navDivider
            navButton(title: "机器人", symbol: "bolt.horizontal.circle", help: "查看机器人状态") {
                open(.bot)
            }
            navDivider
            navButton(title: "设置", symbol: "gearshape", help: "打开设置") {
                open(.settings)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var navDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1, height: 12)
            .accessibilityHidden(true)
    }

    private func navButton(
        title: String,
        symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(L(title))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuBarHoverHighlight(cornerRadius: 6)
        .accessibilityLabel(Text(L(title)))
        .accessibilityHint(Text(L(help)))
        .help(L(help))
    }

    private var toggleTitle: String {
        if store.isSwitchingAccount { return "正在切换微信账号…" }
        if isToggling { return store.isBotRunning ? "正在停止…" : "正在启动…" }
        return store.isBotRunning ? "停止机器人" : "启动机器人"
    }

    private var toggleSymbol: String {
        store.isBotRunning ? "stop.fill" : "play.fill"
    }

    private var toggleTint: Color {
        store.isBotRunning ? Theme.danger : Theme.success
    }

    private var toggleHelp: String {
        store.isBotRunning ? "停止后台机器人" : "在后台启动机器人并自动回复"
    }

    /// 启停不收起面板：用户可能连续查看状态或再点其它入口。
    private func toggleBot() {
        guard !isToggling, !store.isSwitchingAccount, !store.isBotTransitioning else { return }
        isToggling = true
        Task {
            if store.isBotRunning {
                await store.stopBot()
            } else {
                await store.startBot()
            }
            isToggling = false
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text(versionText)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(versionText)
            Spacer(minLength: 6)
            Button {
                NSApp.terminate(nil)
            } label: {
                Label(L("退出"), systemImage: "power")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .menuBarHoverHighlight(cornerRadius: 6)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(L("退出 WeChat AI")))
            .help(L("退出 WeChat AI（⌥⌘Q）"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "WeChat AI \(version)"
    }

    // MARK: - Navigation

    private func openMainWindow() {
        MainWindowRegistry.showOrOpen()
        onNavigate?()
    }

    private func open(_ item: SidebarItem) {
        store.sidebarSelection = item
        // 面板由 NSPopover 承载，不在 SwiftUI Scene 内，必须走注册表里的主场景动作。
        MainWindowRegistry.showOrOpen()
        onNavigate?()
    }
}

// MARK: - Run state pill

/// 运行状态胶囊。动画只作用于这一个胶囊（dot/文字/底色的颜色过渡 0.12s），
/// 面板其它区域不挂隐式动画；开启「减少动态效果」时直接切换、不做动画。
private struct RunStatePill: View {
    let isRunning: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color { isRunning ? Theme.success : .secondary }
    private var title: String { L(isRunning ? "机器人运行中" : "机器人已停止") }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .animation(Theme.animation(reduceMotion, .easeOut(duration: 0.12)), value: isRunning)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("机器人状态")))
        .accessibilityValue(Text(title))
    }
}

// MARK: - Buttons

/// 面板的主操作按钮（启动/停止）：唯一带语义色底色的按钮。
private struct MenuBarPrimaryButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let help: String
    var isBusy: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(L(title))
                    .font(.system(.callout, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.12))
                    // 悬停只叠一层 opacity，不重新解析材质/颜色。
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.07))
                        .opacity(isHovered && !isBusy ? 1 : 0)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1)
        .onHover { isHovered = $0 }
        .animation(Theme.animation(reduceMotion, .easeOut(duration: 0.10)), value: isHovered)
        .animation(Theme.animation(reduceMotion, .easeOut(duration: 0.12)), value: isBusy)
        .accessibilityLabel(Text(L(title)))
        .accessibilityHint(Text(L(help)))
        .help(L(help))
    }
}

/// 面板内的普通操作行（打开主窗口等）：hover 时只做一层 opacity 高亮。
private struct MenuBarRowButton: View {
    let title: String
    let symbol: String
    var iconTint: Color = .secondary
    var help: String? = nil
    var showsChevron: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(L(title))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuBarHoverHighlight(cornerRadius: 7)
        .accessibilityLabel(Text(L(title)))
        .accessibilityHint(Text(L(help ?? title)))
        .help(L(help ?? title))
    }
}

/// 鼠标移入时显示圆角底色高亮；「减少动态效果」开启时只改变颜色、不做动画。
///
/// 只对高亮层的 `opacity` 做 0.10s 过渡（GPU 合成），不对文字/布局做隐式动画。
private struct MenuBarHoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .opacity(isHovered ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(Theme.animation(reduceMotion, .easeOut(duration: 0.10)), value: isHovered)
    }
}

private extension View {
    func menuBarHoverHighlight(cornerRadius: CGFloat = 6) -> some View {
        modifier(MenuBarHoverHighlight(cornerRadius: cornerRadius))
    }
}
