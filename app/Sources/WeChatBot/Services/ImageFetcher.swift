import Foundation

/// 入站图片获取的串行队列（2026-10-23）。
///
/// 语义与边界：
/// - **串行**：一次只向 bridge 发送一条 `/fetch_image`，避免同时触发多个微信下载。
/// - **去重**：同一 `chatMessageID` 只入队一次；成功/失败/取消后都不再重试。
/// - **不持有** AppStore / OneBotClient：请求与回调全部通过闭包注入，便于单测。
/// - `cancelAll()` 后（设置关闭 / 停止机器人）不再回调任何 onFetched/onFailed。
///
/// 只在主线程（MainActor）访问状态；`fetch` 闭包内部自行 await 网络请求。
@MainActor
final class ImageFetcher {
    /// 一条待获取图片的请求。
    ///
    /// 两个 ID 不能混用：`bridgeMessageID` 是 bridge 事件里的原始 OneBot
    /// `message_id`（请求 `/fetch_image` 时用），`chatMessageID` 是 App 内
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

    private var fetch: (@MainActor (String) async throws -> String)?
    private var onFetched: (@MainActor (Request, String) async -> Void)?
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
        fetch: @escaping @MainActor (String) async throws -> String,
        onFetched: @escaping @MainActor (Request, String) async -> Void,
        onFailed: @escaping @MainActor (Request, String) -> Void,
        onIdle: (@MainActor () -> Void)? = nil
    ) {
        self.fetch = fetch
        self.onFetched = onFetched
        self.onFailed = onFailed
        self.onIdle = onIdle
    }

    /// 入队一条图片获取请求。重复/已处理/参数不全时返回 `false` 且不产生任何请求。
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
            onFailed?(request, "图片获取未配置")
            return
        }
        do {
            let path = try await fetch(request.bridgeMessageID)
            // fetch 期间可能已 cancelAll()：任务取消后不再回调。
            guard !Task.isCancelled else { return }
            if let onFetched { await onFetched(request, path) }
        } catch {
            guard !Task.isCancelled else { return }
            onFailed?(request, error.localizedDescription)
        }
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
}

/// 「收到这张图片后要不要向 bridge 获取」的纯判定，方便单测覆盖所有门槛。
enum ImageFetchPolicy {
    static func shouldFetch(
        kind: MessageKind,
        enabled: Bool,
        isSelf: Bool,
        messageID: String,
        mediaPath: String?,
        mediaURL: String?
    ) -> Bool {
        guard enabled, !isSelf, kind == .image else { return false }
        guard !messageID.isEmpty else { return false }
        return (mediaPath ?? "").isEmpty && (mediaURL ?? "").isEmpty
    }
}
