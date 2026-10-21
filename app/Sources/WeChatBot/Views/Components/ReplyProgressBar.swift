import SwiftUI

// MARK: - Reply pipeline status (auto-reply progress)

/// 会话输入区上方的回复流水线状态条。
///
/// 它是「发送信息倒计时」的主展示面：
/// - `generating`：显示 AI 已等待时长（生成耗时不可预知，因此正向计时）；
/// - `waitingToSend`：拟人化延迟，显示真实的「N 秒后发送」倒计时与收缩进度条；
/// - `sending`：显示等待 bridge 回执的时长，R3 未就绪时补充具体原因；
/// - `completed` / `failed`：完成后自动收起，失败保留并提供手动关闭。
struct ReplyProgressBar: View {
    let progress: ReplyProgress
    /// 4.1.15.55 R3 原生发送状态：用于在「发送中」阶段说明是否在等待发送句柄。
    var r3Active = false
    var r3Seeded = false
    var r3Queued = 0
    var onDismiss: (() -> Void)?

    var body: some View {
        Group {
            if progress.stage.needsTicking {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    content(now: context.date)
                }
            } else {
                content(now: Date())
            }
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 7) {
                icon

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(progress.stage.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(tint)
                        if progress.stage.isActive {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.72)
                        }
                    }
                    if let detail = detailText {
                        Text(L(detail))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                Text(timerText(now: now))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .fixedSize()

                if let onDismiss, !progress.stage.isActive {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("收起状态"))
                    .accessibilityLabel(L("收起回复状态"))
                }
            }

            if let fraction = remainingFraction(at: now) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(tint.opacity(0.72))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("回复状态：\(progress.stage.label)，\(timerText(now: now))"))
    }

    // MARK: Derived

    private var tint: Color {
        switch progress.stage {
        case .generating: Theme.info
        case .waitingToSend, .sending: Theme.accent
        case .completed: Theme.success
        case .failed: Theme.danger
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch progress.stage {
        case .generating:
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        case .waitingToSend:
            Image(systemName: "hourglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        case .sending:
            Image(systemName: "paperplane.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    private var detailText: String? {
        switch progress.stage {
        case .generating:
            let parts = [progress.providerName ?? "", progress.model ?? ""]
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
            return progress.note
        case .waitingToSend:
            return "拟人化延迟" + segmentText
        case .sending:
            if let r3Hint { return segmentText.isEmpty ? r3Hint : "\(segmentText) · \(r3Hint)" }
            return segmentText.isEmpty ? "等待 bridge 回执" : segmentText + " · 等待 bridge 回执"
        case .completed:
            return progress.note
        case .failed:
            return progress.errorText ?? "详见运行日志"
        }
    }

    private var segmentText: String {
        guard let index = progress.segmentIndex, let count = progress.segmentCount, count > 0 else {
            return ""
        }
        return "第 \(index)/\(count) 段"
    }

    /// R3 原生发送可能在没有发送句柄时排队；把这一层原因直接显示出来，
    /// 否则用户只会看到「正在发送」却迟迟没有回执。
    private var r3Hint: String? {
        guard progress.stage == .sending, r3Active else { return nil }
        if !r3Seeded {
            return "R3 发送句柄未就绪（微信重启后需在本机微信手动发一条消息）"
        }
        if r3Queued > 0 {
            return "R3 队列 \(r3Queued) 条"
        }
        return nil
    }

    private func timerText(now: Date) -> String {
        switch progress.stage {
        case .generating:
            return "已等待 \(UIFormat.liveSeconds(progress.elapsedSeconds(at: now)))"
        case .waitingToSend:
            guard let remaining = progress.remainingSeconds(at: now) else { return "即将发送…" }
            if remaining <= 0.05 { return "即将发送…" }
            return String(format: "%.1f 秒后发送", remaining)
        case .sending:
            return "回执 \(UIFormat.liveSeconds(progress.stageElapsedSeconds(at: now)))"
        case .completed, .failed:
            // 完成/失败后不再计时：用结束时刻减去流水线开始时刻，得到固定的总耗时。
            let total = max(0, progress.stageStartedAt.timeIntervalSince(progress.startedAt))
            return "总用时 \(UIFormat.liveSeconds(total))"
        }
    }

    /// 倒计时阶段剩余比例：进度条随倒计时收缩（而非增长）。
    private func remainingFraction(at date: Date) -> Double? {
        guard progress.stage == .waitingToSend,
              let total = progress.countdownTotal, total > 0,
              let remaining = progress.remainingSeconds(at: date) else { return nil }
        return min(1, max(0, remaining / total))
    }
}

// MARK: - Compact header badge

/// 会话标题下方的紧凑状态：即使消息区滚动、输入区不在视线内，也能看到当前卡在哪一步。
struct ReplyStatusBadge: View {
    let progress: ReplyProgress

    var body: some View {
        Group {
            if progress.stage.needsTicking {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    badge(now: context.date)
                }
            } else {
                badge(now: Date())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("回复状态：\(progress.stage.label)，\(text(now: Date()))"))
    }

    private func badge(now: Date) -> some View {
        HStack(spacing: 3) {
            if progress.stage.isActive {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
            } else {
                Image(systemName: progress.stage == .failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 8.5))
            }
            Text(text(now: now))
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch progress.stage {
        case .generating: Theme.info
        case .waitingToSend, .sending: Theme.accent
        case .completed: Theme.success
        case .failed: Theme.danger
        }
    }

    private func text(now: Date) -> String {
        switch progress.stage {
        case .generating:
            return "AI 生成中 · \(UIFormat.liveSeconds(progress.elapsedSeconds(at: now)))"
        case .waitingToSend:
            let remaining = progress.remainingSeconds(at: now) ?? 0
            return remaining <= 0.05 ? "即将发送…" : String(format: "%.1f 秒后发送", remaining)
        case .sending:
            return "正在发送…"
        case .completed:
            return "回复已发送"
        case .failed:
            return "回复失败"
        }
    }
}

// MARK: - Conversation row marker

/// 会话列表行的精简进度标记，替代相对时间显示；用于同时处理多个会话时快速定位。
struct ReplyMiniStatus: View {
    let progress: ReplyProgress

    var body: some View {
        Group {
            if progress.stage.needsTicking {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    label(now: context.date)
                }
            } else {
                label(now: Date())
            }
        }
    }

    private func label(now: Date) -> some View {
        Text(text(now: now))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("\(progress.stage.label)，\(text(now: now))")
    }

    private var tint: Color {
        switch progress.stage {
        case .generating: Theme.info
        case .waitingToSend, .sending: Theme.accent
        case .completed: Theme.success
        case .failed: Theme.danger
        }
    }

    private func text(now: Date) -> String {
        switch progress.stage {
        case .generating:
            return "生成 \(Int(progress.elapsedSeconds(at: now).rounded(.down)))s"
        case .waitingToSend:
            let remaining = progress.remainingSeconds(at: now) ?? 0
            return remaining <= 0.05 ? "即将发送" : "\(Int(remaining.rounded(.up)))s 后发送"
        case .sending:
            return "发送中"
        case .completed:
            return "已发送"
        case .failed:
            return "失败"
        }
    }
}
