import Foundation

// MARK: - Public transport types

enum OneBotConnectionState: String, Sendable, Equatable {
    case stopped
    case connecting
    case connected
    case reconnecting

    var label: String {
        switch self {
        case .stopped: "已停止"
        case .connecting: "连接中"
        case .connected: "已连接"
        case .reconnecting: "重连中"
        }
    }
}

/// One message segment as delivered by the bridge. `type` is one of
/// `text` / `image` / `record` / `voice` / `face` / `file` / `video` / `at` / unknown.
///
/// 入站语音（2026-10-26）：bridge 会把 `[语音]` 文本段替换成无文件的
/// `{"type":"voice","data":{"duration_ms":5200}}`；`durationMs` 只用于气泡展示
/// 与提示词里的 `[语音 4s]` 标签，音频需要通过 `POST /fetch_voice` 单独获取。
struct OneBotSegment: Sendable, Hashable {
    var type: String
    var text: String?
    var url: String?
    var file: String?
    var targetID: String?
    /// 语音时长（毫秒）；仅 `voice` 段可能携带，缺省表示 bridge/旧版本未提供。
    var durationMs: Int?

    init(
        type: String,
        text: String? = nil,
        url: String? = nil,
        file: String? = nil,
        targetID: String? = nil,
        durationMs: Int? = nil
    ) {
        self.type = type
        self.text = text
        self.url = url
        self.file = file
        self.targetID = targetID
        self.durationMs = durationMs
    }

    static func text(_ value: String) -> OneBotSegment {
        OneBotSegment(type: "text", text: value)
    }
}

/// Parsed inbound event. Pure value type so it can cross actors/threads.
struct OneBotEvent: Sendable {
    var messageID: String
    var selfID: String
    var userID: String
    var groupID: String?
    /// 会话目标：私聊=对方 wxid，群聊=群 ID。自消息的 `userID` 是发送者（自己），
    /// 不能用来定位会话；bridge 会为自消息补上 `target_id`。
    var targetID: String
    var senderName: String
    var timestamp: Date
    var segments: [OneBotSegment]
    var rawMessage: String
    var messageType: String
    var isSelf: Bool
    var isEchoOfLocal: Bool
    var rawJSON: String
    var mentions: [String]
    var mediaPath: String?

    /// 只有合法 `@chatroom` 群 ID 才算群聊。旧 hook 曾把私聊拍一拍的 wxid
    /// 写进 `group_id`，若仍按「非空即群」判定，会把消息记进伪群会话。
    var isGroup: Bool { ConversationIdentity.isGroupID(groupID ?? "") }

    var conversationID: String {
        // 群 → 群 ID；自消息（私聊）→ target_id；其余 → 发送者 userID（空则 target_id）。
        if let groupID, ConversationIdentity.isGroupID(groupID) { return groupID }
        // 自消息（自己发出的私聊）必须落进对方会话，而不是「自己 wxid」的会话。
        // 旧 bridge 没有 target_id 时退回 userID，并由启动时的一次性数据修复兜底。
        if isSelf, !targetID.isEmpty { return targetID }
        if !userID.isEmpty { return userID }
        return targetID
    }

    var conversationKind: ConversationKind {
        isGroup ? .group : .direct
    }

    var plainText: String {
        segments.compactMap { segment -> String? in
            switch segment.type {
            case "text":
                return segment.text
            case "image":
                return "[图片]"
            case "record", "voice":
                return "[语音]"
            case "video":
                return "[视频]"
            case "face":
                return "[表情]"
            case "file":
                return "[文件]"
            case "at":
                if let target = segment.targetID { return "@\(target)" }
                return nil
            default:
                return segment.text
            }
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First non-text media segment, if any.
    var primaryMediaSegment: OneBotSegment? {
        segments.first { ["image", "record", "voice", "face", "file", "video"].contains($0.type) }
    }

    var primaryMessageKind: MessageKind {
        switch primaryMediaSegment?.type {
        case "image": return .image
        case "record", "voice": return .voice
        case "face": return .emoji
        case "file": return .file
        case "video": return .video
        default: return .text
        }
    }

    /// 入站语音时长（毫秒）；非语音消息或 bridge 未提供时为 nil。
    var voiceDurationMs: Int? {
        guard primaryMessageKind == .voice, let duration = primaryMediaSegment?.durationMs else {
            return nil
        }
        return duration > 0 ? duration : nil
    }
}

enum OneBotError: LocalizedError {
    case notRunning
    case invalidURL(String)
    case sendFailed(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "OneBot 连接未启动"
        case .invalidURL(let url): return "OneBot 地址无效：\(url)"
        case .sendFailed(let reason): return "消息发送失败：\(reason)"
        case .badResponse(let reason): return "OneBot 返回异常：\(reason)"
        }
    }
}

/// `POST /fetch_voice` 成功回包。
///
/// bridge 契约（`docs/voice.md` §2.2）：
/// `{"ok":true,"path":"file:///…/voice_x_16k.wav","silk_path":"file:///…x.silk","duration_ms":5200}`；
/// 也兼容 OneBot 风格的 `{"status":"ok","data":{...}}` 包装。`path`/`silkPath`
/// 已从 `file://` 转成本地路径（不含 scheme）。
struct VoiceFetchPayload: Sendable, Equatable {
    var path: String
    var silkPath: String?
    var durationMs: Int?
}

// MARK: - Client

/// OneBot v11-ish bridge client.
///
/// - Receives events via `URLSessionWebSocketTask` at `ws://host:port/ws`.
/// - Sends messages via HTTP `POST /send_private_msg` / `/send_group_msg`
///   with `Authorization: Bearer <token>` (see docs/architecture.md §3).
/// - Reconnects with exponential backoff + jitter; sends WS pings to detect
///   half-open sockets. No polling loops.
/// - Thread model: a private serial `DispatchQueue` owns all mutable state; the
///   socket receive loop lives in a structured `Task`. Callbacks (`onEvent`,
///   `onStateChange`, `onLog`) are delivered off the main thread; the runtime hops
///   to `MainActor` itself.
final class OneBotClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    struct Configuration: Sendable, Equatable {
        var host: String = "127.0.0.1"
        var port: Int = 58080
        var token: String = ""
        var requestTimeout: TimeInterval = 20
        var connectTimeout: TimeInterval = 15
        var reconnectBaseDelay: TimeInterval = 1
        var reconnectMaxDelay: TimeInterval = 30
        var pingInterval: TimeInterval = 20

        var webSocketURL: URL? {
            URL(string: "ws://\(host):\(port)/ws")
        }

        var httpBaseURL: URL? {
            URL(string: "http://\(host):\(port)")
        }
    }

    // Callbacks (invoked off the main thread).
    var onEvent: (@Sendable (OneBotEvent) -> Void)?
    var onStateChange: (@Sendable (OneBotConnectionState) -> Void)?
    var onLog: (@Sendable (LogLevel, String) -> Void)?
    /// 连接建立后向 bridge 询问 `get_login_info`，拿到权威的 self wxid。
    var onLoginInfo: (@Sendable (String) -> Void)?
    /// 通讯录目录快照（`get_contact_directory` 回包）；`ok == false` 时表示暂时读不到。
    var onContactDirectory: (@Sendable (ContactDirectorySnapshot) -> Void)?

    /// 通讯录目录刷新节奏：拿到成功快照后 10 分钟刷新一次；失败时每 60 秒重试，
    /// 连续 5 分钟拿不到就暂停（等重连后重新尝试），不阻塞消息链路。
    static let contactDirectoryRefreshInterval: TimeInterval = 600
    static let contactDirectoryRetryInterval: TimeInterval = 60
    static let contactDirectoryRetryWindow: TimeInterval = 300

    private let configuration: Configuration
    private let stateQueue = DispatchQueue(label: "com.gusionw.wechatai.onebot.state")

    // State guarded by `stateQueue`.
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var running = false
    private var connected = false
    private var generation = 0
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var seenMessageIDs: [String] = []
    private var outgoingEchoes: [(conversationID: String, text: String, date: Date)] = []
    // 通讯录目录抓取（全部由 `stateQueue` 保护）。
    private var contactDirectoryTask: Task<Void, Never>?
    private var contactDirectoryReceivedOK = false
    private var contactDirectoryFirstRequestAt: Date?
    private let httpSession: URLSession

    private let maxSeenMessages = 1024
    private let echoWindow: TimeInterval = 20

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        let httpConfig = URLSessionConfiguration.ephemeral
        httpConfig.timeoutIntervalForRequest = configuration.requestTimeout
        httpConfig.timeoutIntervalForResource = configuration.requestTimeout * 2
        httpConfig.waitsForConnectivity = false
        self.httpSession = URLSession(configuration: httpConfig)
        super.init()
    }

    deinit {
        receiveTask?.cancel()
        pingTask?.cancel()
        reconnectTask?.cancel()
        connectTimeoutTask?.cancel()
        contactDirectoryTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    var isConnected: Bool {
        stateQueue.sync { connected }
    }

    // MARK: Lifecycle

    func start() {
        stateQueue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.reconnectAttempt = 0
            self.notifyState(.connecting)
            self.connectLocked()
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.connected = false
            self.generation += 1
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.receiveTask?.cancel()
            self.receiveTask = nil
            self.pingTask?.cancel()
            self.pingTask = nil
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = nil
            self.cancelContactDirectoryRequestsLocked()
            self.socket?.cancel(with: .goingAway, reason: nil)
            self.socket = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            self.notifyState(.stopped)
        }
    }

    private var activeConfiguration: Configuration {
        configuration
    }

    // MARK: WebSocket

    private func connectLocked() {
        guard running else { return }
        let config = activeConfiguration
        guard let url = config.webSocketURL else {
            notifyLog(.error, "无效的 OneBot WebSocket 地址")
            notifyState(.stopped)
            running = false
            return
        }
        generation += 1
        let currentGeneration = generation
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
        notifyState(reconnectAttempt == 0 ? .connecting : .reconnecting)

        let session = makeSessionLocked()
        // bridge 的 /ws 与 HTTP 接口共用同一个 OneBot token（见 docs/bridge.md §6）。
        // URLSessionWebSocketTask(with: URL) 无法携带自定义头，必须传 URLRequest；
        // 旧版 bridge 不校验该头，带上也兼容。
        let task: URLSessionWebSocketTask
        let trimmedToken = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            task = session.webSocketTask(with: url)
        } else {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
            task = session.webSocketTask(with: request)
        }
        socket = task
        task.resume()

        connectTimeoutTask?.cancel()
        let timeoutSeconds = UInt64(max(1, config.connectTimeout) * 1_000_000_000)
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutSeconds)
            guard !Task.isCancelled, let self else { return }
            self.stateQueue.async {
                guard self.running, self.generation == currentGeneration, !self.connected else { return }
                self.notifyLog(.warning, "OneBot WebSocket 连接超时")
                self.socket?.cancel(with: .goingAway, reason: nil)
                self.handleDisconnectLocked(reason: "connect timeout")
            }
        }
    }

    private func makeSessionLocked() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = activeConfiguration.requestTimeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.gusionw.wechatai.onebot.delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        return session
    }

    private func markConnectedLocked(task: URLSessionWebSocketTask, currentGeneration: Int) {
        guard running, socket === task else { return }
        connected = true
        reconnectAttempt = 0
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        notifyState(.connected)
        notifyLog(.info, "OneBot WebSocket 已连接 \(activeConfiguration.host):\(activeConfiguration.port)")
        startReceiveLocked(task: task, currentGeneration: currentGeneration)
        startPingLocked(task: task, currentGeneration: currentGeneration)
        // 主动查询一次登录账号：self_id 是消息方向/会话归属的权威来源，
        // 不能只靠消息启发式（历史回放/自消息会干扰）。
        Task {
            let payload = #"{"action":"get_login_info","echo":"login-info","params":{}}"#
            try? await task.send(.string(payload))
        }
    }

    private func startReceiveLocked(task: URLSessionWebSocketTask, currentGeneration: Int) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard self.isCurrent(generation: currentGeneration, task: task) else { return }
                    self.handleInbound(message)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.stateQueue.async {
                        guard self.running, self.generation == currentGeneration else { return }
                        self.handleDisconnectLocked(reason: error.localizedDescription)
                    }
                    return
                }
            }
        }
    }

    private func startPingLocked(task: URLSessionWebSocketTask, currentGeneration: Int) {
        pingTask?.cancel()
        let interval = UInt64(max(5, activeConfiguration.pingInterval) * 1_000_000_000)
        pingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                do {
                    try await Self.ping(task)
                } catch {
                    self.stateQueue.async {
                        guard self.running, self.generation == currentGeneration else { return }
                        self.handleDisconnectLocked(reason: "ping failed: \(error.localizedDescription)")
                    }
                    return
                }
            }
        }
    }

    private static func ping(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func isCurrent(generation expected: Int, task: URLSessionWebSocketTask) -> Bool {
        stateQueue.sync {
            running && generation == expected && socket === task && connected
        }
    }

    private func handleDisconnectLocked(reason: String) {
        guard running else { return }
        if connected { notifyLog(.warning, "OneBot 连接断开：\(reason)") }
        connected = false
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        cancelContactDirectoryRequestsLocked()
        socket?.cancel(with: .abnormalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        scheduleReconnectLocked()
    }

    private func scheduleReconnectLocked() {
        guard running else { return }
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        reconnectAttempt += 1
        let base = max(0.5, activeConfiguration.reconnectBaseDelay)
        let maxDelay = max(base, activeConfiguration.reconnectMaxDelay)
        let backoff = min(maxDelay, base * pow(2, Double(attempt)))
        let delay = backoff + Double.random(in: 0...0.35)
        notifyState(.reconnecting)
        notifyLog(.info, String(format: "OneBot 将在 %.1f 秒后重连（第 %d 次）", delay, attempt + 1))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.stateQueue.async {
                guard self.running else { return }
                self.connectLocked()
            }
        }
    }

    // MARK: Inbound parsing

    private func handleInbound(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let string):
            data = string.data(using: .utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            data = nil
        }
        guard let data, !data.isEmpty else { return }
        // 一帧只解析一次 JSON：动作回包（通讯录 / 登录信息）与消息事件共用同一对象。
        // 旧实现的解析链路会再解析一次整帧、并为每条事件重新序列化字典生成 rawJSON，
        // 历史回放时 JSON 开销成倍放大；这里把原始帧文本直接交给事件解析器复用。
        let frameText = String(data: data, encoding: .utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            if let frameText {
                notifyLog(.debug, "忽略无法识别的 OneBot 帧：\(frameText.prefix(180))")
            }
            return
        }
        let dictionary = object as? [String: Any]
        // 通讯录目录回包（echo = contact-directory）不是消息事件。失败也回调，
        // 让运行时能解释「为什么昵称仍是兜底名」，且绝不进入事件解析链路。
        if let dictionary, let snapshot = OneBotContactDirectory.parseReply(object: dictionary) {
            stateQueue.async { [weak self] in
                self?.handleContactDirectoryReplyLocked(snapshot)
            }
            onContactDirectory?(snapshot)
            return
        }
        // get_login_info 的动作回包（{"status":"ok","data":{"user_id":...}}）不是消息事件，
        // 单独解析；否则会被当成「无法识别的帧」丢弃，self_id 只能靠启发式。
        if let dictionary,
           let status = dictionary["status"] as? String, status == "ok",
           let payload = dictionary["data"] as? [String: Any],
           let userID = payload["user_id"] as? String, !userID.isEmpty {
            notifyLoginInfo(userID)
            // 登录信息成功说明 bridge 已就绪：此时才开始要通讯录目录。
            stateQueue.async { [weak self] in
                self?.startContactDirectoryRequestsLocked()
            }
            return
        }
        let events = OneBotEventParser.parse(object: object, rawText: frameText)
        if events.isEmpty {
            if let frameText {
                notifyLog(.debug, "忽略无法识别的 OneBot 帧：\(frameText.prefix(180))")
            }
            return
        }
        for event in events {
            guard let event = decorateAndDedupe(event) else { continue }
            onEvent?(event)
        }
    }

    /// Remembers message IDs (bounded) and matches echoes of locally sent messages.
    private func decorateAndDedupe(_ event: OneBotEvent) -> OneBotEvent? {
        stateQueue.sync {
            if !event.messageID.isEmpty {
                if seenMessageIDs.contains(event.messageID) { return nil }
                seenMessageIDs.append(event.messageID)
                if seenMessageIDs.count > maxSeenMessages {
                    seenMessageIDs.removeFirst(seenMessageIDs.count - maxSeenMessages / 2)
                }
            }
            var decorated = event
            if event.isSelf {
                let now = Date()
                outgoingEchoes.removeAll { now.timeIntervalSince($0.date) > echoWindow }
                let normalized = event.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = outgoingEchoes.firstIndex(where: {
                    $0.conversationID == event.conversationID
                        && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
                }) {
                    outgoingEchoes.remove(at: index)
                    decorated.isEchoOfLocal = true
                }
            }
            return decorated
        }
    }

    /// Must be called after a successful HTTP send so self-echo events can be de-duplicated.
    func noteOutgoing(conversationID: String, text: String) {
        stateQueue.async {
            self.outgoingEchoes.append((conversationID, text, Date()))
            if self.outgoingEchoes.count > 64 {
                self.outgoingEchoes.removeFirst(self.outgoingEchoes.count - 64)
            }
        }
    }

    // MARK: HTTP send

    /// Sends a text message. Splitting long replies is the caller's responsibility.
    @discardableResult
    func sendText(conversationID: String, isGroup: Bool, text: String) async throws -> String {
        try await send(
            conversationID: conversationID,
            isGroup: isGroup,
            segments: [.text(text)],
            echoText: text
        )
    }

    /// Sends one message made of one or more segments via the HTTP API.
    /// Returns the bridge response body (usually `{"status":"ok"}`).
    @discardableResult
    func send(
        conversationID: String,
        isGroup: Bool,
        segments: [OneBotSegment],
        echoText: String? = nil
    ) async throws -> String {
        guard !conversationID.isEmpty else { throw OneBotError.sendFailed("会话 ID 为空") }
        let config = activeConfiguration
        guard let base = config.httpBaseURL else { throw OneBotError.invalidURL("http://\(config.host):\(config.port)") }
        let action = isGroup ? "send_group_msg" : "send_private_msg"
        guard let url = URL(string: "/\(action)", relativeTo: base) else {
            throw OneBotError.invalidURL(base.absoluteString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = config.requestTimeout

        var payload: [String: Any] = [
            "message": Self.encodeSegments(segments)
        ]
        payload[isGroup ? "group_id" : "user_id"] = conversationID
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await httpSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OneBotError.badResponse("非 HTTP 响应")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OneBotError.sendFailed("HTTP \(httpResponse.statusCode) \(body.prefix(300))")
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = object["status"] as? String {
            guard status == "ok" || status == "async" else {
                let error = (object["error"] as? String) ?? (object["message"] as? String) ?? body
                throw OneBotError.sendFailed(error)
            }
        }
        if let echoText {
            noteOutgoing(conversationID: conversationID, text: echoText)
        }
        return body
    }

    /// 请求 bridge 从微信下载一条入站图片，返回本机文件路径（不含 `file://`）。
    ///
    /// 只负责 `POST /fetch_image` 的一次请求与响应解析；队列/去重/失败重试策略由
    /// `ImageFetcher` 负责。`messageID` 必须是 bridge 事件里的原始 OneBot
    /// `message_id`，不能用 App 内的 `ChatMessage.id`（`ob-<message_id>`）。
    func fetchImage(messageID: String) async throws -> String {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OneBotError.sendFailed("消息 ID 为空") }
        let config = activeConfiguration
        guard let base = config.httpBaseURL else {
            throw OneBotError.invalidURL("http://\(config.host):\(config.port)")
        }
        var request = try Self.fetchImageRequest(baseURL: base, token: config.token, messageID: trimmed)
        // bridge 侧下载预算是 12 秒；给 HTTP 留出足够的余量，且不短于 30 秒。
        request.timeoutInterval = max(config.requestTimeout, 30)

        let (data, response) = try await httpSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OneBotError.badResponse("非 HTTP 响应")
        }
        return try Self.parseImageFetchResponse(data: data, statusCode: httpResponse.statusCode)
    }

    /// Builds the `POST /fetch_image` request. Pure function so it can be unit-tested.
    static func fetchImageRequest(baseURL: URL, token: String, messageID: String) throws -> URLRequest {
        guard let url = URL(string: "/fetch_image", relativeTo: baseURL) else {
            throw OneBotError.invalidURL(baseURL.absoluteString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message_id": messageID], options: [])
        return request
    }

    /// Parses the bridge `POST /fetch_image` response and converts `file://…` into a
    /// plain local file path. Pure function so it can be unit-tested.
    static func parseImageFetchResponse(data: Data, statusCode: Int) throws -> String {
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(statusCode) else {
            if statusCode == 404 {
                throw OneBotError.badResponse("当前 bridge 不支持图片获取（HTTP 404），请更新 bridge")
            }
            throw OneBotError.badResponse("HTTP \(statusCode) \(body.prefix(300))")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OneBotError.badResponse("图片获取响应无法解析")
        }
        guard object["status"] as? String == "ok" else {
            let reason = (object["error"] as? String)
                ?? (object["message"] as? String)
                ?? body
            throw OneBotError.badResponse(reason.isEmpty ? "图片获取失败" : reason)
        }
        guard let payload = object["data"] as? [String: Any],
              let file = payload["file"] as? String,
              !file.isEmpty else {
            throw OneBotError.badResponse("图片获取响应缺少文件路径")
        }
        return localFilePath(from: file)
    }

    /// `file://` URL → 本地路径（百分号解码）；普通路径原样返回。
    static func localFilePath(from file: String) -> String {
        guard file.hasPrefix("file://") else { return file }
        if let path = URL(string: file)?.path, !path.isEmpty {
            return path
        }
        var path = String(file.dropFirst("file://".count))
        if let decoded = path.removingPercentEncoding {
            path = decoded
        }
        return path
    }

    // MARK: 入站语音获取

    /// 请求 bridge 解密/解码一条入站语音，返回 16k WAV 的本地路径。
    ///
    /// 只负责 `POST /fetch_voice` 的一次请求与响应解析；队列/去重/重试由
    /// `VoiceFetcher` 负责。`messageID` 必须是 bridge 事件里的原始 OneBot
    /// `message_id`（不是 `ChatMessage.id` 的 `ob-<id>`）。
    /// bridge 侧下载＋解密＋SILK 解码总预算 ≤25s，这里给到 ≥35s。
    func fetchVoice(messageID: String) async throws -> VoiceFetchPayload {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OneBotError.sendFailed("消息 ID 为空") }
        let config = activeConfiguration
        guard let base = config.httpBaseURL else {
            throw OneBotError.invalidURL("http://\(config.host):\(config.port)")
        }
        var request = try Self.fetchVoiceRequest(baseURL: base, token: config.token, messageID: trimmed)
        request.timeoutInterval = max(config.requestTimeout, 35)
        let (data, response) = try await httpSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OneBotError.badResponse("非 HTTP 响应")
        }
        return try Self.parseVoiceFetchResponse(data: data, statusCode: httpResponse.statusCode)
    }

    /// Builds the `POST /fetch_voice` request. Pure function so it can be unit-tested.
    static func fetchVoiceRequest(baseURL: URL, token: String, messageID: String) throws -> URLRequest {
        guard let url = URL(string: "/fetch_voice", relativeTo: baseURL) else {
            throw OneBotError.invalidURL(baseURL.absoluteString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message_id": messageID], options: [])
        return request
    }

    /// Parses the bridge `POST /fetch_voice` response. Pure function so it can be unit-tested.
    ///
    /// 兼容两种成功形状（spec §2.2 顶层 `ok` / OneBot 风格 `status`+`data`）与
    /// 两种失败形状（HTTP 200 + `ok:false`；或非 2xx）。失败文案直接取自 bridge，
    /// 但不包含 aeskey / CDN key（bridge 已保证）。
    static func parseVoiceFetchResponse(data: Data, statusCode: Int) throws -> VoiceFetchPayload {
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(statusCode) else {
            if statusCode == 404 {
                throw OneBotError.badResponse("当前 bridge 不支持语音获取（HTTP 404），请更新 bridge")
            }
            throw OneBotError.badResponse("HTTP \(statusCode) \(body.prefix(300))")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OneBotError.badResponse("语音获取响应无法解析")
        }
        let payload = (object["data"] as? [String: Any]) ?? object
        let explicitOK = bool(object["ok"]) ?? bool(payload["ok"])
        let statusOK = (object["status"] as? String) == "ok"
        guard explicitOK ?? statusOK else {
            let reason = (object["error"] as? String)
                ?? (payload["error"] as? String)
                ?? (object["message"] as? String)
                ?? body
            throw OneBotError.badResponse(reason.isEmpty ? "语音获取失败" : reason)
        }
        guard let file = (payload["path"] as? String) ?? (payload["file"] as? String),
              !file.isEmpty else {
            throw OneBotError.badResponse("语音获取响应缺少音频路径")
        }
        let silk = ((payload["silk_path"] as? String) ?? (payload["silkPath"] as? String))
            .map(localFilePath(from:))
        let duration = integer(payload["duration_ms"]) ?? integer(payload["durationMs"])
        return VoiceFetchPayload(
            path: localFilePath(from: file),
            silkPath: (silk?.isEmpty == false) ? silk : nil,
            durationMs: (duration ?? 0) > 0 ? duration : nil
        )
    }

    // MARK: 出站语音发送

    /// `POST /send_voice` 成功回包（实际时长由 bridge 按 SILK 帧计算）。
    struct VoiceSendResult: Sendable, Equatable {
        var durationMs: Int
    }

    /// 把 16k WAV 交给 bridge 编码成 Tencent SILK 并发送语音消息。
    ///
    /// - Parameters:
    ///   - wavURL: `VoiceSynthesisService` 产出的 16k 单声道 WAV（bridge 兼容 WAV base64）。
    ///   - durationHintMs: 时长提示；实际发送时长以 bridge 返回为准。
    /// - Throws: `OneBotError.sendFailed("voice_send_unsupported")` 表示 Hook 未支持，
    ///   调用方应降级为文字（不重试语音，避免重复发送）。
    func sendVoice(
        conversationID: String,
        isGroup: Bool,
        wavURL: URL,
        durationHintMs: Int
    ) async throws -> VoiceSendResult {
        guard !conversationID.isEmpty else { throw OneBotError.sendFailed("会话 ID 为空") }
        let wavData = try Data(contentsOf: wavURL)
        guard !wavData.isEmpty else { throw OneBotError.sendFailed("语音文件为空") }
        let config = activeConfiguration
        guard let base = config.httpBaseURL else {
            throw OneBotError.invalidURL("http://\(config.host):\(config.port)")
        }
        var request = try Self.sendVoiceRequest(
            baseURL: base,
            token: config.token,
            conversationID: conversationID,
            isGroup: isGroup,
            wavBase64: wavData.base64EncodedString(),
            durationHintMs: durationHintMs
        )
        request.timeoutInterval = max(config.requestTimeout, 40)
        let (data, response) = try await httpSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OneBotError.badResponse("非 HTTP 响应")
        }
        return try Self.parseSendVoiceResponse(data: data, statusCode: httpResponse.statusCode)
    }

    /// Builds `POST /send_voice`. Pure function so it can be unit-tested.
    static func sendVoiceRequest(
        baseURL: URL,
        token: String,
        conversationID: String,
        isGroup: Bool,
        wavBase64: String,
        durationHintMs: Int
    ) throws -> URLRequest {
        guard let url = URL(string: "/send_voice", relativeTo: baseURL) else {
            throw OneBotError.invalidURL(baseURL.absoluteString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var payload: [String: Any] = [
            "pcm16k": wavBase64,
            "duration_ms": max(0, durationHintMs)
        ]
        payload[isGroup ? "group_id" : "user_id"] = conversationID
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        return request
    }

    /// Parses `POST /send_voice` response. Pure function so it can be unit-tested.
    static func parseSendVoiceResponse(data: Data, statusCode: Int) throws -> VoiceSendResult {
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(statusCode) else {
            if statusCode == 404 {
                throw OneBotError.badResponse("当前 bridge 不支持语音发送（HTTP 404），请更新 bridge")
            }
            throw OneBotError.badResponse("HTTP \(statusCode) \(body.prefix(300))")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OneBotError.badResponse("语音发送响应无法解析")
        }
        let payload = (object["data"] as? [String: Any]) ?? object
        let explicitOK = bool(object["ok"]) ?? bool(payload["ok"])
        let statusOK = (object["status"] as? String) == "ok"
        guard explicitOK ?? statusOK else {
            let reason = (object["error"] as? String)
                ?? (payload["error"] as? String)
                ?? (object["message"] as? String)
                ?? body
            throw OneBotError.sendFailed(reason.isEmpty ? "语音发送失败" : reason)
        }
        let duration = integer(payload["duration_ms"]) ?? integer(object["duration_ms"]) ?? 0
        return VoiceSendResult(durationMs: max(0, duration))
    }

    // MARK: 语音发送运行时状态

    /// 请求 bridge `/voice_status`：登录稳定倒计时、文本/语音句柄、CdnManager。
    func fetchVoiceStatus() async throws -> VoiceRuntimeStatus {
        let config = activeConfiguration
        guard let base = config.httpBaseURL else {
            throw OneBotError.invalidURL("http://\(config.host):\(config.port)")
        }
        var request = try Self.voiceStatusRequest(baseURL: base, token: config.token)
        request.timeoutInterval = min(max(config.requestTimeout, 5), 10)
        let (data, response) = try await httpSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OneBotError.badResponse("非 HTTP 响应")
        }
        return try Self.parseVoiceStatus(data: data, statusCode: httpResponse.statusCode)
    }

    /// Builds `GET /voice_status`. Pure function so it can be unit-tested.
    static func voiceStatusRequest(baseURL: URL, token: String) throws -> URLRequest {
        guard let url = URL(string: "/voice_status", relativeTo: baseURL) else {
            throw OneBotError.invalidURL(baseURL.absoluteString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Parses `/voice_status`. Pure function so it can be unit-tested.
    ///
    /// `ok:false` 不抛错：App 需要把「bridge 未连接/版本不支持」显示为状态，
    /// 而不是让语音设置页报错。网络层失败才抛 `OneBotError`。
    static func parseVoiceStatus(data: Data, statusCode: Int) throws -> VoiceRuntimeStatus {
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(statusCode) else {
            if statusCode == 404 {
                return VoiceRuntimeStatus(
                    available: false, configured: false, voiceSend: false,
                    textSeed: false, voiceSeed: false, cdnReady: false,
                    loginSettled: false, warmupRemainingMs: 0, voiceReady: false,
                    error: "当前 bridge 不支持语音状态（HTTP 404）", receivedAt: Date()
                )
            }
            throw OneBotError.badResponse("HTTP \(statusCode) \(body.prefix(200))")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OneBotError.badResponse("语音状态响应无法解析")
        }
        let ok = bool(object["ok"]) ?? false
        let configured = bool(object["configured"]) ?? false
        guard ok, let hook = object["hook"] as? [String: Any] else {
            let reason = (object["error"] as? String) ?? "语音状态不可用"
            return VoiceRuntimeStatus(
                available: false, configured: configured, voiceSend: false,
                textSeed: false, voiceSeed: false, cdnReady: false,
                loginSettled: false, warmupRemainingMs: 0, voiceReady: false,
                error: reason, receivedAt: Date()
            )
        }
        return VoiceRuntimeStatus(
            available: true,
            configured: configured,
            voiceSend: bool(hook["voiceSend"]) ?? false,
            textSeed: bool(hook["textSeed"]) ?? false,
            voiceSeed: bool(hook["voiceSeed"]) ?? false,
            cdnReady: bool(hook["cdnReady"]) ?? false,
            loginSettled: bool(hook["loginSettled"]) ?? false,
            warmupRemainingMs: integer(hook["warmupRemainingMs"]) ?? 0,
            voiceReady: bool(hook["voiceReady"]) ?? false,
            error: nil,
            receivedAt: Date()
        )
    }

    /// Encodes segments into the OneBot message array. Base64 files pass through.
    static func encodeSegments(_ segments: [OneBotSegment]) -> [[String: Any]] {
        segments.map { segment in
            var data: [String: Any] = [:]
            if let text = segment.text { data["text"] = text }
            if let url = segment.url { data["url"] = url }
            if let file = segment.file { data["file"] = file }
            if let targetID = segment.targetID { data["qq"] = targetID }
            return ["type": segment.type, "data": data]
        }
    }

    // MARK: Notification helpers

    private func notifyState(_ state: OneBotConnectionState) {
        onStateChange?(state)
    }

    private func notifyLog(_ level: LogLevel, _ message: String) {
        onLog?(level, message)
    }

    private func notifyLoginInfo(_ userID: String) {
        onLoginInfo?(userID)
    }

    // MARK: Contact directory

    /// `get_login_info` 成功后在 `stateQueue` 上启动目录抓取：立即请求一次，
    /// 成功前每 60 秒重试（最多 5 分钟），成功后每 10 分钟刷新；断开即取消。
    ///
    /// 定时器是「一次请求 + 一次延时」的事件驱动链，没有忙轮询；
    /// 全部网络发送在 `Task` 里异步执行，不占主线程，也不阻塞 WS 收消息。
    private func startContactDirectoryRequestsLocked() {
        guard running, connected else { return }
        contactDirectoryTask?.cancel()
        contactDirectoryReceivedOK = false
        contactDirectoryFirstRequestAt = nil
        sendContactDirectoryRequestLocked()
        scheduleContactDirectoryRequestLocked(after: Self.contactDirectoryRetryInterval)
    }

    private func handleContactDirectoryReplyLocked(_ snapshot: ContactDirectorySnapshot) {
        guard running, connected else { return }
        guard snapshot.ok, !contactDirectoryReceivedOK else { return }
        // 首次成功：把 60 秒重试节奏换成 10 分钟刷新（取消尚未到点的重试）。
        contactDirectoryReceivedOK = true
        scheduleContactDirectoryRequestLocked(after: Self.contactDirectoryRefreshInterval)
    }

    private func sendContactDirectoryRequestLocked() {
        guard running, connected, let socket else { return }
        if contactDirectoryFirstRequestAt == nil {
            contactDirectoryFirstRequestAt = Date()
        }
        let payload = OneBotContactDirectory.requestPayload()
        Task {
            try? await socket.send(.string(payload))
        }
    }

    private func scheduleContactDirectoryRequestLocked(after delay: TimeInterval) {
        contactDirectoryTask?.cancel()
        let generation = generation
        let nanos = UInt64(max(0, delay) * 1_000_000_000)
        contactDirectoryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.stateQueue.async {
                guard self.running, self.connected, self.generation == generation else { return }
                self.performScheduledContactDirectoryRequestLocked()
            }
        }
    }

    private func performScheduledContactDirectoryRequestLocked() {
        guard running, connected else { return }
        if contactDirectoryReceivedOK {
            sendContactDirectoryRequestLocked()
            scheduleContactDirectoryRequestLocked(after: Self.contactDirectoryRefreshInterval)
            return
        }
        if let first = contactDirectoryFirstRequestAt,
           Date().timeIntervalSince(first) >= Self.contactDirectoryRetryWindow {
            contactDirectoryFirstRequestAt = nil
            notifyLog(.debug, "通讯录目录 \(Int(Self.contactDirectoryRetryWindow)) 秒内不可用，暂停自动重试")
            return
        }
        sendContactDirectoryRequestLocked()
        scheduleContactDirectoryRequestLocked(after: Self.contactDirectoryRetryInterval)
    }

    private func cancelContactDirectoryRequestsLocked() {
        contactDirectoryTask?.cancel()
        contactDirectoryTask = nil
        contactDirectoryReceivedOK = false
        contactDirectoryFirstRequestAt = nil
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.markConnectedLocked(task: webSocketTask, currentGeneration: self.generation)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        stateQueue.async { [weak self] in
            guard let self, self.socket === webSocketTask else { return }
            self.handleDisconnectLocked(reason: "closed with code \(closeCode.rawValue)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        stateQueue.async { [weak self] in
            guard let self, self.socket === task else { return }
            self.handleDisconnectLocked(reason: error.localizedDescription)
        }
    }

    // MARK: Response value helpers

    /// JSON 布尔（顶层 `ok` / `data.ok`），只接受真正的布尔或 0/1。
    private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            switch number.intValue {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }
        return value as? Bool
    }

    /// JSON 整数（bridge 可能用数字或字符串下发毫秒时长）。
    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

// MARK: - Parser

enum OneBotEventParser {
    /// Parses one or more bridge events from a WS frame. Returns `[]` for unknown frames.
    static func parse(data: Data) -> [OneBotEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        // 旧 API 保持行为不变：没有原始帧文本，`rawJSON` 由事件字典重新序列化。
        return parse(object: object, rawText: nil)
    }

    /// 用已经反序列化好的帧对象解析事件，避免调用方（`OneBotClient.handleInbound`）
    /// 为了判断动作回包而解析一次、事件链路又解析一次。
    ///
    /// - Parameter rawText: 原始帧文本。单事件帧直接用它作为 `rawJSON`，不再重新序列化。
    ///   数组帧按旧行为逐元素解析（`rawText: nil`）；嵌套包装帧同样保留原始帧文本。
    static func parse(object: Any, rawText: String?) -> [OneBotEvent] {
        if let array = object as? [[String: Any]] {
            return array.compactMap { parseEvent($0, rawText: nil) }
        }
        if let dictionary = object as? [String: Any] {
            if let event = parseEvent(dictionary, rawText: rawText) { return [event] }
            // Some bridge versions wrap the event: {"post_type":"message","data":{...}}
            if let nested = dictionary["data"] as? [String: Any],
               let event = parseEvent(nested, rawText: rawText) {
                return [event]
            }
        }
        return []
    }

    /// Exposed for diagnostics/self-test.
    static func parseEvent(_ raw: [String: Any], rawText: String?) -> OneBotEvent? {
        let selfID = string(raw["self_id"]) ?? string(raw["selfId"]) ?? ""
        let sender = raw["sender"] as? [String: Any]
        let userID = string(sender?["user_id"]) ?? string(raw["user_id"]) ?? string(raw["userId"]) ?? ""
        var groupID = string(raw["group_id"]) ?? string(raw["groupId"])
        if groupID?.isEmpty == true { groupID = nil }
        let senderName = string(sender?["nickname"])
            ?? string(sender?["card"])
            ?? string(sender?["remark"])
            ?? string(raw["sender_name"])
            ?? ""
        let messageID = string(raw["message_id"]) ?? string(raw["messageId"]) ?? ""
        let messageType = string(raw["message_type"]) ?? (groupID == nil ? "private" : "group")
        let rawMessage = string(raw["raw_message"]) ?? string(raw["rawMessage"]) ?? ""

        var segments = normalizeAppmsgSegments(parseSegments(raw["message"]), rawMessage: rawMessage)
        // 群系统消息（如拍一拍 appmsg）可能把 group_id 同时写进 self_id/user_id，
        // 不能仅凭两者相等就判定为「自己发出」。
        var isSelf = !selfID.isEmpty && selfID == userID
            && !(groupID != nil && userID == groupID)
        // bridge 归一化后会显式标记 is_self（旧 bridge 没有该字段，保持启发式）。
        if let explicit = bool(raw["is_self"]) {
            isSelf = explicit
        }
        let targetID = string(raw["target_id"]) ?? string(raw["targetId"]) ?? ""
        guard !(userID.isEmpty && groupID == nil) || !segments.isEmpty else { return nil }

        let timeValue = (raw["time"] as? Double) ?? Double(string(raw["time"]) ?? "") ?? Date().timeIntervalSince1970
        let timestamp = Date(timeIntervalSince1970: timeValue > 10_000_000_000 ? timeValue / 1000 : timeValue)

        var mentions: [String] = segments.compactMap { segment in
            segment.type == "at" ? segment.targetID : nil
        }
        if mentions.isEmpty, let explicit = raw["mentions"] as? [String] {
            mentions = explicit
        }
        if mentions.isEmpty, let at = raw["at"] as? [String] { mentions = at }
        let jsonText: String
        if let rawText {
            jsonText = rawText
        } else {
            jsonText = (try? JSONSerialization.data(withJSONObject: raw))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        return OneBotEvent(
            messageID: messageID,
            selfID: selfID,
            userID: userID,
            groupID: groupID,
            targetID: targetID,
            senderName: senderName,
            timestamp: timestamp,
            segments: segments,
            rawMessage: rawMessage,
            messageType: messageType,
            isSelf: isSelf,
            isEchoOfLocal: false,
            rawJSON: jsonText,
            mentions: mentions,
            mediaPath: OneBotMediaStore.localPath(for: segments.first {
                ["image", "record", "face", "file", "video"].contains($0.type)
            } ?? OneBotSegment(type: "none"))
        )
    }

    /// 旧 hook 对「拍一拍」以外的 appmsg（引用回复 / 链接 / 文件 / 表情 / 聊天记录 /
    /// 转账 / 视频号 …）统一写占位文本 `[链接/文件]`，引用回复的正文与被引用原文
    /// 因此对 UI、规则引擎和 AI 都不可见。这里在事件入口用 App 侧解析器
    /// （`WeChatAppmsg`）从 `raw_message` 还原本地展示文本。
    ///
    /// 只替换四种文本：
    /// - hook 的笼统占位 `[链接/文件]`；
    /// - hook 误把「正文含『拍了拍』的引用回复」当拍一拍时写入的 title——
    ///   该 title 其实就是 appmsg `<title>`（引用正文），替换后补回引用上下文；
    /// - 旧 bridge（4.1.12 legacy 出站路径）把 appmsg XML 原样当正文，这里一并还原；
    /// - 旧 bridge 已渲染好的 `正文\n[引用 发送者] 原文`（旧定界符）：历史回放会绕过
    ///   启动迁移重新入库，必须在入口统一改成 `【引用 发送者：原文】`，否则提示词里的
    ///   引用规则与真实消息格式不一致，模型会把被引用内容误当成当前发言。
    ///
    /// 拍一拍（appmsg type 62）的正文、`at` 段与媒体段一律不动，避免回归。
    private static func normalizeAppmsgSegments(
        _ segments: [OneBotSegment],
        rawMessage: String
    ) -> [OneBotSegment] {
        guard let appmsg = WeChatAppmsg.parse(rawMessage), !appmsg.text.isEmpty else { return segments }
        var replaced = false
        return segments.map { segment in
            guard !replaced, segment.type == "text" else { return segment }
            let text = segment.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isPlaceholder = text == WeChatAppmsg.placeholderText
            let isHookPatTitle = !appmsg.isPat && !appmsg.title.isEmpty && text == appmsg.title
            // 旧 bridge 的 appmsg 正文就是原始 XML（解析器已确保含 `<appmsg`）。
            let isRawXMLText = text.hasPrefix("<") || text.hasPrefix("<?xml")
            // 真实引用 appmsg 的旧定界符文本；用户手打的 `[引用 …]` 没有 quote 结构，不误伤。
            let isLegacyQuote = appmsg.quote != nil
                && (text.contains("[引用 ") || text.contains("[引用] "))
            guard isPlaceholder || isHookPatTitle || isRawXMLText || isLegacyQuote else { return segment }
            replaced = true
            return .text(appmsg.text)
        }
    }

    static func parseSegments(_ value: Any?) -> [OneBotSegment] {
        if let string = value as? String {
            if string.isEmpty { return [] }
            return [.text(string)]
        }
        if let array = value as? [[String: Any]] {
            return array.map { item in
                let type = string(item["type"]) ?? "text"
                let data = item["data"] as? [String: Any] ?? [:]
                return OneBotSegment(
                    type: type,
                    text: string(data["text"]),
                    url: string(data["url"]),
                    file: string(data["file"]),
                    targetID: string(data["qq"]) ?? string(data["user_id"]) ?? string(data["target_id"]),
                    durationMs: integer(data["duration_ms"]) ?? integer(data["duration"])
                )
            }
        }
        if let dictionary = value as? [String: Any] {
            return parseSegments([dictionary])
        }
        return []
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let int as Int:
            return String(int)
        default:
            return nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        // JSONSerialization 的 true/false 是 NSNumber(__NSCFBoolean)，不是 Swift Bool；
        // 只接受 0/1，避免把普通数字误当成布尔。
        if let number = value as? NSNumber {
            switch number.intValue {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }
        return value as? Bool
    }
}

// MARK: - Media

/// Copies `file://` / base64 media referenced by OneBot segments into
/// `~/Library/Application Support/WeChatAI/media/<yyyy-MM-dd>/`.
enum OneBotMediaStore {
    static let maxImportBytes = 40 * 1024 * 1024
    private static let lock = NSLock()
    private static var importedPaths: [String: String] = [:]

    /// Local path if this segment has already been imported in this process.
    static func localPath(for segment: OneBotSegment) -> String? {
        if let file = segment.file, file.hasPrefix("file://") {
            return importFileURL(file)
        }
        if let url = segment.url, url.hasPrefix("file://") {
            return importFileURL(url)
        }
        if let file = segment.file, file.hasPrefix("base64://") {
            return importBase64(String(file.dropFirst("base64://".count)), hint: segment.type)
        }
        if let file = segment.file, looksLikeBase64(file) {
            return importBase64(file, hint: segment.type)
        }
        return nil
    }

    static func importedPath(for source: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return importedPaths[source]
    }

    static func importFileURL(_ raw: String) -> String? {
        if let cached = importedPath(for: raw) { return cached }
        let url: URL
        if let parsed = URL(string: raw), parsed.isFileURL {
            url = parsed
        } else if let decoded = raw.removingPercentEncoding,
                  let parsed = URL(string: decoded), parsed.isFileURL {
            url = parsed
        } else {
            return nil
        }
        let sourcePath = url.path
        guard FileManager.default.fileExists(atPath: sourcePath) else { return nil }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: sourcePath)
            if let size = attributes[.size] as? Int, size > maxImportBytes { return nil }
            let ext = url.pathExtension.isEmpty ? fallbackExtension(for: nil) : url.pathExtension
            let destination = try destinationURL(extension: ext)
            try FileManager.default.copyItem(at: url, to: destination)
            let path = destination.path
            lock.lock()
            importedPaths[raw] = path
            lock.unlock()
            return path
        } catch {
            NSLog("[WeChatAI] media import failed: \(error)")
            return nil
        }
    }

    static func importBase64(_ encoded: String, hint: String?) -> String? {
        let cacheKey = "base64:" + String(encoded.prefix(32)) + ":\(encoded.count)"
        if let cached = importedPath(for: cacheKey) { return cached }
        let cleaned = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]),
              !data.isEmpty, data.count <= maxImportBytes else { return nil }
        do {
            let destination = try destinationURL(extension: fallbackExtension(for: hint))
            try data.write(to: destination, options: .atomic)
            let path = destination.path
            lock.lock()
            importedPaths[cacheKey] = path
            lock.unlock()
            return path
        } catch {
            NSLog("[WeChatAI] base64 media import failed: \(error)")
            return nil
        }
    }

    private static func destinationURL(extension ext: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let directory = AppPaths.mediaDirectory.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = ext.isEmpty ? "bin" : ext
        return directory.appendingPathComponent("\(UUID().uuidString).\(suffix)")
    }

    private static func fallbackExtension(for type: String?) -> String {
        switch type {
        case "image": return "jpg"
        case "record": return "silk"
        case "video": return "mp4"
        case "face": return "gif"
        default: return "bin"
        }
    }

    private static func looksLikeBase64(_ value: String) -> Bool {
        guard value.count > 64, value.count % 4 == 0 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
