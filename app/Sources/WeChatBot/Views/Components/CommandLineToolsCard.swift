import SwiftUI

/// Xcode Command Line Tools 状态卡片。
///
/// 首启向导的 Hook 步骤与设置页的 Hook 区共用：展示 python3/otool 是否就绪、
/// 引导安装、安装后轮询检测。组件自包含，不依赖 AppStore。
struct CommandLineToolsCard: View {
    /// 每次检测/轮询后回调最新状态；父视图可据此禁用 Hook 安装按钮。
    var onStatusChange: ((CommandLineToolsStatus) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var status: CommandLineToolsStatus?
    @State private var isDetecting = false
    @State private var isRequestingInstall = false
    @State private var isWaitingForInstall = false
    @State private var noticeKind: NoticeKind = .info
    @State private var noticeMessage: String?
    @State private var pollTask: Task<Void, Never>?

    /// 安装轮询上限：系统安装向导可能等待用户操作，给足 10 分钟。
    private static let pollInterval: Duration = .seconds(3)
    private static let pollTimeout: TimeInterval = 10 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            Text(L("Hook 安装与状态检测需要 Xcode Command Line Tools（提供 python3 与 otool）。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            details
            if let noticeMessage {
                InlineNotice(kind: noticeKind, message: noticeMessage)
            }
            actions
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .animation(Theme.animation(reduceMotion), value: status)
        .accessibilityElement(children: .contain)
        .task {
            await detect()
        }
        .onDisappear {
            stopPolling()
        }
    }

    // MARK: Header / details

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "hammer.fill", tint: headerTint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("运行环境"))
                    .font(.callout.weight(.medium))
                Text(L("Command Line Tools"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PillLabel(
                text: statusText,
                color: statusColor,
                symbol: statusSymbol
            )
            .accessibilityLabel(L("Command Line Tools 状态") + "：" + L(statusText))
        }
    }

    @ViewBuilder
    private var details: some View {
        if let status {
            VStack(alignment: .leading, spacing: 4) {
                if let version = status.pythonVersion {
                    Text("Python \(version)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("Python 版本") + " \(version)")
                }
                if let developer = status.developerDirectory {
                    Text(UIFormat.compactPath(developer))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(L("开发者目录") + "：" + developer)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            if status?.isReady != true {
                Button {
                    Task { await requestInstall() }
                } label: {
                    Label(L("安装 Command Line Tools"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(isDetecting || isRequestingInstall || isWaitingForInstall)
                .accessibilityLabel(L("安装 Command Line Tools"))
                .help(L("安装 Command Line Tools"))
            }

            Button {
                Task { await detect(announceReady: true) }
            } label: {
                Label(L(isDetecting ? "检测中…" : "重新检测"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .disabled(isDetecting || isRequestingInstall)
            .accessibilityLabel(L("重新检测"))
            .help(L("重新检测"))

            Spacer(minLength: 6)

            if isWaitingForInstall {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("等待安装完成…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("等待安装完成…"))
            }
        }
    }

    // MARK: Derived

    private var statusText: String {
        guard let status else { return "检测中…" }
        if isDetecting { return "检测中…" }
        return status.isReady ? "已安装" : "未安装"
    }

    private var statusColor: Color {
        guard let status, !isDetecting else { return .secondary }
        return status.isReady ? Theme.success : Theme.warning
    }

    private var statusSymbol: String? {
        guard let status, !isDetecting else { return nil }
        return status.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var headerTint: Color {
        status?.isReady == true ? Theme.success : Theme.warning
    }

    // MARK: Detection / polling

    private func detect(announceReady: Bool = false) async {
        guard !isDetecting else { return }
        isDetecting = true
        let newStatus = await CommandLineTools.status()
        isDetecting = false
        if newStatus.isReady {
            isWaitingForInstall = false
            stopPolling()
        }
        _ = apply(newStatus, announceReady: announceReady)
    }

    @discardableResult
    private func apply(_ newStatus: CommandLineToolsStatus, announceReady: Bool) -> Bool {
        let wasReady = status?.isReady ?? false
        status = newStatus
        onStatusChange?(newStatus)
        guard newStatus.isReady else { return false }
        if announceReady, !wasReady {
            noticeKind = .success
            noticeMessage = "Command Line Tools 已就绪。"
        }
        return true
    }

    private func requestInstall() async {
        guard !isRequestingInstall else { return }
        isRequestingInstall = true
        noticeMessage = nil
        let result = await CommandLineTools.requestInstall()
        isRequestingInstall = false

        if result.ok {
            isWaitingForInstall = true
            noticeKind = .info
            noticeMessage = "已打开系统安装窗口，请按提示完成安装，然后点「重新检测」。"
            startPolling()
        } else {
            isWaitingForInstall = false
            noticeKind = .warning
            noticeMessage = result.message
                ?? "无法打开 Command Line Tools 安装窗口，请在终端运行 xcode-select --install。"
            // 系统可能提示“已安装”但状态确实过期；重新检测一次比继续等待更有用。
            await detect(announceReady: true)
        }
    }

    private func startPolling() {
        stopPolling()
        let deadline = Date().addingTimeInterval(Self.pollTimeout)
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                let newStatus = await CommandLineTools.status()
                guard !Task.isCancelled else { return }
                if apply(newStatus, announceReady: true) {
                    stopPolling()
                    return
                }
                if Date() >= deadline {
                    isWaitingForInstall = false
                    noticeKind = .warning
                    noticeMessage = "等待安装超时，请完成安装后点「重新检测」。"
                    return
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
