import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 运行日志：实时流、级别/来源过滤、暂停、清空与导出。
struct LogsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var levels: Set<LogLevel> = Set(LogLevel.allCases)
    @State private var sourceFilter: String?
    @State private var search = ""
    @State private var isPaused = false
    @State private var pausedSnapshot: [LogEntry] = []
    @State private var autoFollow = true
    @State private var showClearConfirm = false

    /// 节流后的日志缓冲快照：运行时在 MainActor 上以每秒数条到十几条的频率追加日志，
    /// 若 `body` 直接读取 `store.logs`，整个 2000 行日志页会为每一行日志重建一次。
    /// 这里以约 2 Hz 采样，既保持「实时」观感，又让布局更新频率与日志追加频率解耦。
    @State private var feed = LogFeedSnapshot()
    /// 合并自动到底部滚动。在布局更新过程中调用 `scrollTo` 会再次弄脏 lazy 布局，
    /// 是 AppKit display-cycle 布局次数超限（崩溃栈 LazyLayoutViewCache.signalPrefetch）
    /// 的已知触发路径，因此滚出当前布局周期后再执行。
    @State private var scrollTask: Task<Void, Never>?

    var body: some View {
        let displayLogs = filteredLogs(in: isPaused ? pausedSnapshot : feed.logs)
        VStack(spacing: 0) {
            toolbar(displayLogs: displayLogs)

            filterBar(displayLogs: displayLogs)

            Divider().opacity(0.5)

            logList(displayLogs: displayLogs)
        }
        .background(PageBackground())
        .task { await runFeedLoop() }
        .onDisappear { scrollTask?.cancel() }
        .sheet(isPresented: $showClearConfirm) {
            ConfirmSheet(
                title: "清空运行日志",
                message: "将清空 App 内存中的日志缓冲（最多 2000 条）。已落盘的日志文件不受影响。",
                details: ["清空后无法恢复。", "如需保留，请先使用「导出」保存日志文件。"],
                confirmTitle: "清空",
                cancelTitle: "取消"
            ) {
                store.clearLogs()
                refreshFeed()
                toast.show("运行日志已清空", tone: .info, symbol: "trash")
            }
        }
    }

    // MARK: Toolbar

    private func toolbar(displayLogs: [LogEntry]) -> some View {
        GlassToolbar(title: "运行日志", subtitle: subtitle) {
            Button {
                togglePause()
            } label: {
                Label(isPaused ? "继续" : "暂停", systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.glass)

            Button {
                exportLogs()
            } label: {
                Label(L("导出"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glass)
            .disabled(displayLogs.isEmpty)

            Button {
                showClearConfirm = true
            } label: {
                Label(L("清空"), systemImage: "trash")
            }
            .buttonStyle(.glass)
            .disabled(feed.logs.isEmpty)
        }
    }

    // MARK: Filter bar

    private func filterBar(displayLogs: [LogEntry]) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                FilterChip(
                    title: "全部",
                    count: feed.logs.count,
                    isSelected: levels.count == LogLevel.allCases.count
                ) {
                    levels = Set(LogLevel.allCases)
                }
                ForEach(LogLevel.allCases) { level in
                    FilterChip(
                        title: level.label,
                        symbol: levelSymbol(level),
                        count: feed.levelCounts[level] ?? 0,
                        isSelected: levels.contains(level),
                        tint: level.color
                    ) {
                        toggleLevel(level)
                    }
                }
                Spacer(minLength: 8)
                SearchField(text: $search, placeholder: "搜索日志内容或来源")
                    .frame(width: 220)
            }

            HStack(spacing: 8) {
                Picker(L("来源"), selection: $sourceFilter) {
                    Text(L("全部来源")).tag(String?.none)
                    ForEach(feed.sources, id: \.self) { source in
                        Text(source).tag(Optional(source))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)

                Toggle(L("自动滚动"), isOn: $autoFollow)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption2)
                    .help(L("新日志到达时自动滚动到底部"))

                Spacer()

                HStack(spacing: 5) {
                    StatusDot(
                        color: isPaused ? Theme.warning : Theme.success,
                        size: 6,
                        pulsing: !isPaused
                    )
                    Text(isPaused ? "已暂停 · 显示暂停时的快照" : "实时更新")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(L("\(displayLogs.count) / \(feed.logs.count) 条"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    // MARK: List

    private func logList(displayLogs: [LogEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if displayLogs.isEmpty {
                        EmptyState(
                            symbol: "text.alignleft",
                            title: feed.logs.isEmpty ? "暂无日志" : "没有匹配的日志",
                            message: feed.logs.isEmpty
                                ? "启动机器人或安装 Hook 后，运行日志会实时显示在这里。"
                                : "尝试调整级别、来源或搜索条件。"
                        )
                    } else {
                        ForEach(displayLogs) { entry in
                            LogRow(entry: entry)
                                .equatable()
                            Divider().opacity(0.25)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("logs-bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: displayLogs.last?.id) { _, _ in
                guard autoFollow, !isPaused else { return }
                scheduleScrollToBottom(proxy)
            }
            .onAppear {
                guard autoFollow, !isPaused else { return }
                scheduleScrollToBottom(proxy, delay: .zero)
            }
        }
        .background(.regularMaterial)
        .padding(Theme.pagePadding)
    }

    // MARK: Derived / feed

    private var subtitle: String {
        "\(feed.logs.count) 条缓冲 · 上限 \(AppStore.logBufferLimit) 条 · \(isPaused ? "已暂停" : "实时")"
    }

    /// 在节流快照上应用当前筛选条件。每次 body 只调用一次（结果传给工具栏/筛选栏/列表），
    /// 避免旧实现里 `displayLogs` 在同一个 body 中被重复过滤 3-4 次。
    private func filteredLogs(in base: [LogEntry]) -> [LogEntry] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsAllLevels = levels.count == LogLevel.allCases.count
        if keyword.isEmpty, sourceFilter == nil, showsAllLevels { return base }
        return base.filter { entry in
            guard levels.contains(entry.level) else { return false }
            if let sourceFilter, entry.source != sourceFilter { return false }
            if !keyword.isEmpty {
                guard entry.message.localizedCaseInsensitiveContains(keyword)
                    || entry.source.localizedCaseInsensitiveContains(keyword)
                else { return false }
            }
            return true
        }
    }

    private func levelSymbol(_ level: LogLevel) -> String {
        switch level {
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    @MainActor
    private func refreshFeed() {
        let logs = store.logs
        var counts: [LogLevel: Int] = [:]
        counts.reserveCapacity(LogLevel.allCases.count)
        var sources = Set<String>()
        for entry in logs {
            counts[entry.level, default: 0] += 1
            sources.insert(entry.source)
        }
        feed = LogFeedSnapshot(logs: logs, levelCounts: counts, sources: sources.sorted())
    }

    private func runFeedLoop() async {
        refreshFeed()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            refreshFeed()
        }
    }

    /// 合并多次滚动请求，并把 `scrollTo` 推迟到当前布局周期之外执行。
    /// - Parameter delay: 新日志到达时留一小段时间让 layout 收敛；进入页面时只需等到
    ///   下一个 main-actor tick，避免列表先停在顶部的闪烁。
    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, delay: Duration = .milliseconds(60)) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            proxy.scrollTo("logs-bottom", anchor: .bottom)
        }
    }

    // MARK: Actions

    private func toggleLevel(_ level: LogLevel) {
        if levels.contains(level) {
            levels.remove(level)
        } else {
            levels.insert(level)
        }
    }

    private func togglePause() {
        if isPaused {
            isPaused = false
            refreshFeed()
        } else {
            pausedSnapshot = store.logs
            isPaused = true
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .log]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "wechatai-\(UIFormat.fileDate.string(from: Date())).log"
        panel.title = "导出运行日志"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let displayed = filteredLogs(in: isPaused ? pausedSnapshot : store.logs)
        let text = displayed.map(UIFormat.logLine).joined(separator: "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            toast.show("日志已导出到 \(url.lastPathComponent)", tone: .success, symbol: "square.and.arrow.up")
        } catch {
            toast.show("导出失败：\(error.localizedDescription)", tone: .error)
        }
    }
}

/// 日志页的节流快照：`logs` 与 store 中的数组共享存储（写时复制），
/// 因此取快照只是一次廉价 retain，而不是 2000 条记录的逐条复制。
private struct LogFeedSnapshot {
    var logs: [LogEntry] = []
    var levelCounts: [LogLevel: Int] = [:]
    var sources: [String] = []
}
