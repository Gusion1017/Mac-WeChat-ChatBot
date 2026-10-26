import Foundation

/// `POST /fetch_voice` 的返回快照（与 `OneBotClient.VoiceFetchPayload` 同构，
/// 但只依赖值类型，便于 `VoiceFetcher` 注入闭包做单测）。
struct VoiceFetchResult: Sendable, Equatable {
    /// 16k 单声道 WAV 的本地路径。
    var path: String
    /// 原始 SILK 文件（可选，仅诊断用）。
    var silkPath: String?
    /// bridge 给出的时长（毫秒）；缺省时由 WAV 采样数推断或沿用段里的 `duration_ms`。
    var durationMs: Int?
}

/// 入站语音获取的串行队列（2026-10-26）。
///
/// 语义与 `ImageFetcher` 一致，额外增加「失败重试 1 次」：
/// - **串行**：一次只向 bridge 发一条 `/fetch_voice`，避免同时触发多个微信下载；
/// - **去重**：同一 `chatMessageID` 只尝试一次（含重试），成功/失败/取消后都不再重试；
/// - 重试只发生在队列内部（bridge 返回失败/超时），同一请求最多请求 2 次；
/// - 不持有 AppStore / OneBotClient：请求与回调全部通过闭包注入，便于单测；
/// - `cancelAll()` 后（停止机器人）不再回调任何 onFetched/onFailed。
///
/// 只在主线程（MainActor）访问状态；`fetch` 闭包内部自行 await 网络请求。
@MainActor
final class VoiceFetcher {
    /// 一条待获取语音的请求。
    ///
    /// 两个 ID 不能混用：`bridgeMessageID` 是 bridge 事件里的原始 OneBot
    /// `message_id`（请求 `/fetch_voice` 时用），`chatMessageID` 是 App 内
    /// `ChatMessage.id`（`ob-<message_id>`，更新消息时用）。
    struct Request: Sendable, Equatable {
        let bridgeMessageID: String
        let chatMessageID: String
        let conversationID: String

        init(bridgeMessageID: String, chatMessageID: String, conversationID: String) {
            self.bridgeMessageID = bridgeMessageID
            self.chatMessageID = chatMessageID
            self.conversationID = conversationID
        }
    }

    /// 已处理过的 message ID 上限；超出后按 FIFO 淘汰最旧的记录。
    static let attemptedLimit = 1024
    /// 单条请求最多尝试次数（首次 + 重试 1 次）。
    static let maxAttempts = 2
    /// 重试前的等待时间；bridge 侧下载/解码失败通常需要一点时间去重试。
    static let retryDelay: Duration = .milliseconds(400)

    private var fetch: (@MainActor (String) async throws -> VoiceFetchResult)?
    private var onFetched: (@MainActor (Request, VoiceFetchResult) async -> Void)?
    private var onFailed: (@MainActor (Request, String) -> Void)?
    private var onIdle: (@MainActor () -> Void)?

    private var queue: [Request] = []
    private var queuedIDs: Set<String> = []
    private var inFlight: Request?
    private var attempted: [String] = []
    private var attemptedSet: Set<String> = []
    private var worker: Task<Void, Never>?

    /// 尚未处理完的请求数（含正在请求中的一条）；用于测试/日志。
    var pendingCount: Int {
        queue.count + (inFlight == nil ? 0 : 1)
    }

    /// 注入请求与回调。可重复调用（例如运行时重新启动后刷新客户端闭包）。
    func configure(
        fetch: @escaping @MainActor (String) async throws -> VoiceFetchResult,
        onFetched: @escaping @MainActor (Request, VoiceFetchResult) async -> Void,
        onFailed: @escaping @MainActor (Request, String) -> Void,
        onIdle: (@MainActor () -> Void)? = nil
    ) {
        self.fetch = fetch
        self.onFetched = onFetched
        self.onFailed = onFailed
        self.onIdle = onIdle
    }

    /// 入队一条语音获取请求。重复/已处理/参数不全时返回 `false` 且不产生任何请求。
    @discardableResult
    func enqueue(_ request: Request) -> Bool {
        guard !request.bridgeMessageID.isEmpty, !request.chatMessageID.isEmpty else { return false }
        guard !attemptedSet.contains(request.chatMessageID),
              !queuedIDs.contains(request.chatMessageID) else { return false }
        queue.append(request)
        queuedIDs.insert(request.chatMessageID)
        startWorkerIfNeeded()
        return true
    }

    /// 用户点击「重试」：忘掉失败记录后重新入队。仍在排队/进行中时返回 false。
    @discardableResult
    func retry(_ request: Request) -> Bool {
        guard !request.bridgeMessageID.isEmpty, !request.chatMessageID.isEmpty else { return false }
        guard !queuedIDs.contains(request.chatMessageID),
              inFlight?.chatMessageID != request.chatMessageID else { return false }
        forgetAttempt(request.chatMessageID)
        return enqueue(request)
    }

    /// 取消所有未完成的请求。`worker` 的 `fetch` 返回后不会再触发回调；
    /// 已处理记录保留，避免取消后又被同一消息重新入队。
    func cancelAll() {
        worker?.cancel()
        worker = nil
        queue.removeAll()
        queuedIDs.removeAll()
        inFlight = nil
    }

    // MARK: Worker

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        while !queue.isEmpty {
            if Task.isCancelled { return }
            let request = queue.removeFirst()
            queuedIDs.remove(request.chatMessageID)
            recordAttempt(request.chatMessageID)
            inFlight = request
            await perform(request)
            inFlight = nil
            if Task.isCancelled { return }
        }
        worker = nil
        onIdle?()
    }

    private func perform(_ request: Request) async {
        guard let fetch else {
            onFailed?(request, "语音获取未配置")
            return
        }
        var lastError: String = "语音获取失败"
        for attempt in 1...Self.maxAttempts {
            if Task.isCancelled { return }
            do {
                let result = try await fetch(request.bridgeMessageID)
                guard !Task.isCancelled else { return }
                await onFetched?(request, result)
                return
            } catch {
                lastError = error.localizedDescription
                if attempt < Self.maxAttempts {
                    try? await Task.sleep(for: Self.retryDelay)
                }
            }
        }
        guard !Task.isCancelled else { return }
        if let onFailed { onFailed(request, lastError) }
    }

    /// 记录已处理 ID；超过 `attemptedLimit` 时按 FIFO 淘汰最旧记录。
    private func recordAttempt(_ chatMessageID: String) {
        guard attemptedSet.insert(chatMessageID).inserted else { return }
        attempted.append(chatMessageID)
        let overflow = attempted.count - Self.attemptedLimit
        guard overflow > 0 else { return }
        let removed = attempted.prefix(overflow)
        attempted.removeFirst(overflow)
        attemptedSet.subtract(removed)
    }

    private func forgetAttempt(_ chatMessageID: String) {
        guard attemptedSet.remove(chatMessageID) != nil else { return }
        attempted.removeAll { $0 == chatMessageID }
    }
}

/// 「收到这条语音后要不要向 bridge 获取音频」的纯判定，方便单测覆盖所有门槛。
enum VoiceFetchPolicy {
    static func shouldFetch(
        kind: MessageKind,
        enabled: Bool,
        isSelf: Bool,
        messageID: String,
        voiceMediaPath: String?,
        mediaPath: String?
    ) -> Bool {
        guard enabled, !isSelf, kind == .voice else { return false }
        guard !messageID.isEmpty else { return false }
        return (voiceMediaPath ?? "").isEmpty && (mediaPath ?? "").isEmpty
    }
}
