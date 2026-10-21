import AppKit
import SwiftUI

/// Menu bar popover: live status, quick start/stop, navigation and quit.
struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            statusSection
            Divider()
            actionsSection
            Divider()
            footer
        }
        .frame(width: 304)
        .background(.regularMaterial)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentStrong],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 27, height: 27)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("WeChat AI")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                Text(store.isBotRunning ? "机器人运行中" : "机器人已停止")
                    .font(.caption2)
                    .foregroundStyle(store.isBotRunning ? Theme.success : Color.secondary)
            }
            Spacer()
            StatusDot(
                color: store.isBotRunning ? Theme.success : .secondary,
                size: 7,
                pulsing: store.isBotRunning
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(spacing: 6) {
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
            HStack(spacing: 8) {
                statPill(icon: "arrow.down.message", value: "\(store.stats.receivedToday)", label: "收到")
                statPill(icon: "arrow.up.message", value: "\(store.stats.repliedToday)", label: "回复")
                statPill(icon: "timer", value: UIFormat.duration(milliseconds: store.stats.aiLatencyAverageMs), label: "延迟")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func statusRow(symbol: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 13)
            Text(L(label))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Spacer()
            StatusDot(color: color, size: 5)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func statPill(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
            Text(L(label))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: Capsule())
    }

    // MARK: Actions

    private var actionsSection: some View {
        VStack(spacing: 2) {
            Button {
                Task {
                    if store.isBotRunning {
                        await store.stopBot()
                    } else {
                        await store.startBot()
                    }
                }
            } label: {
                Label(
                    store.isBotRunning ? "停止机器人" : "启动机器人",
                    systemImage: store.isBotRunning ? "stop.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.isBotRunning ? Theme.danger : Theme.success)

            Divider().padding(.vertical, 3)

            menuButton("打开主窗口", symbol: "macwindow") {
                open(nil)
            }
            menuButton("总览", symbol: "rectangle.grid.2x2") {
                open(.dashboard)
            }
            menuButton("会话", symbol: "bubble.left.and.bubble.right") {
                open(.conversations)
            }
            menuButton("AI 模型", symbol: "sparkles") {
                open(.ai)
            }
            menuButton("设置", symbol: "gearshape") {
                open(.settings)
            }

            Divider().padding(.vertical, 3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func menuButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
                Text(L(title))
                    .font(.callout)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text(versionText)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label(L("退出"), systemImage: "power")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("退出 WeChat AI（⌥⌘Q）"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "WeChat AI \(version)"
    }

    private func open(_ item: SidebarItem?) {
        if let item {
            store.sidebarSelection = item
        }
        if MainWindowRegistry.show() { return }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
