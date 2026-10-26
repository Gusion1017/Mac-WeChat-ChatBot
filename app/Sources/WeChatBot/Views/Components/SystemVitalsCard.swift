import SwiftUI

/// 总览「设备与账户」卡：左栏本机电量，右栏 DeepSeek 账户余额。
///
/// 独立成视图的原因与总览「最近活动」卡相同：电量每 30 秒刷新一次，
/// 只让这张卡重绘，不触发状态卡、快捷操作与最近日志的整页布局。
struct DashboardSystemVitalsCard: View {
    @Environment(AppStore.self) private var store
    @State private var isRefreshing = false

    var body: some View {
        SectionCard(
            title: "设备与账户",
            subtitle: "本机电量与 DeepSeek 余额",
            symbol: "battery.75percent",
            tint: Theme.info,
            trailing: { refreshButton },
            content: {
                HStack(alignment: .top, spacing: 0) {
                    batteryPanel
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                        .padding(.vertical, 2)
                        .padding(.horizontal, 18)
                    balancePanel
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        )
    }

    // MARK: Battery

    private var batteryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                IconTile(symbol: batterySymbol, tint: batteryTint, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("电量"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if store.batteryStatus.isPresent {
                            Text("\(store.batteryStatus.percentage)%")
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        } else {
                            Text(L("未检测到电池"))
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                        }
                        if store.batteryStatus.isCharging {
                            Image(systemName: "bolt.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if store.batteryStatus.isPresent {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(batteryTint)
                            .frame(width: max(6, proxy.size.width * CGFloat(store.batteryStatus.percentage) / 100))
                    }
                }
                .frame(height: 6)
                .accessibilityElement()
                .accessibilityLabel(L("电量"))
                .accessibilityValue("\(store.batteryStatus.percentage)%")
            }

            Text(batteryDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var batteryDetail: String {
        let status = store.batteryStatus
        guard status.isPresent else { return L("台式机或未检测到内部电池") }
        if status.isCharging {
            if let minutes = status.timeRemainingMinutes {
                return Lf("充电中 · 预计 %@ 充满", durationText(minutes))
            }
            return L("充电中 · 已接电源")
        }
        if status.isFullyCharged { return L("已充满 · 已接电源") }
        if !status.isOnExternalPower, let minutes = status.timeRemainingMinutes {
            return Lf("电池供电 · 预计剩余 %@", durationText(minutes))
        }
        return status.isOnExternalPower ? L("已接电源") : L("电池供电")
    }

    private func durationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 { return Lf("%d 小时 %d 分", hours, remainder) }
        return Lf("%d 分钟", remainder)
    }

    private var batterySymbol: String {
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

    private var batteryTint: Color {
        let status = store.batteryStatus
        guard status.isPresent else { return .secondary }
        if status.percentage < 20 { return Theme.danger }
        if status.isCharging || status.isOnExternalPower { return Theme.accent }
        if status.percentage < 50 { return Theme.warning }
        return Theme.success
    }

    // MARK: DeepSeek balance

    private var balancePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L("DeepSeek 余额"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.isBalanceRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 4)
                if case .loaded(let snapshot) = store.deepSeekBalance {
                    PillLabel(
                        text: snapshot.isAvailable ? "可用" : "余额不足",
                        color: snapshot.isAvailable ? Theme.success : Theme.danger
                    )
                }
            }

            switch store.deepSeekBalance {
            case .idle, .loading:
                loadingView
            case .unavailable(let reason):
                unavailableView(reason)
            case .failed(let message):
                failureView(message)
            case .loaded(let snapshot):
                loadedView(snapshot)
            }
        }
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("正在查询 DeepSeek 余额…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }

    private func unavailableView(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "key.slash")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                Text(L(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L("前往 AI 模型配置")) { store.sidebarSelection = .ai }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                Text(L(message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L("重试")) { refresh() }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }

    private func loadedView(_ snapshot: DeepSeekBalanceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let primary = snapshot.primary {
                Text(primary.displayTotal)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text(Lf(
                    "赠送 %@ · 充值 %@",
                    amount(primary.grantedBalance, primary),
                    amount(primary.toppedUpBalance, primary)
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                let others = snapshot.infos.filter { $0.id != primary.id }
                if !others.isEmpty {
                    Text(others.map(\.displayTotal).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Text(Lf("%@ · 更新于 %@", balanceProviderName, UIFormat.time.string(from: snapshot.fetchedAt)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }

    private func amount(_ value: String, _ info: DeepSeekBalanceInfo) -> String {
        info.currencySymbol.isEmpty ? "\(value) \(info.currency)" : info.currencySymbol + value
    }

    private var balanceProviderName: String {
        DeepSeekProviderResolver.resolve(
            providers: store.providers,
            defaultProvider: store.defaultProvider
        )?.name ?? "DeepSeek"
    }

    // MARK: Refresh

    private var refreshButton: some View {
        Group {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 24)
            } else {
                IconActionButton(symbol: "arrow.clockwise", help: "刷新电量与余额") {
                    refresh()
                }
            }
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await store.refreshSystemVitals()
            isRefreshing = false
        }
    }
}
