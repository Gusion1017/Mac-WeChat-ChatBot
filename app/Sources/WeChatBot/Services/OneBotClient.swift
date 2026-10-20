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
/// `text` / `image` / `record` / `face` / `file` / `video` / `at` / unknown.
struct OneBotSegment: Sendable, Hashable {
    var type: String
    var text: String?
    var url: String?
    var file: String?
    var targetID: String?

    init(type: String, text: String? = nil, url: String? = nil, file: String? = nil, targetID: String? = nil) {
        self.type = type
        self.text = text
        self.url = url
        self.file = file
        self.targetID = targetID
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

    var isGroup: Bool { groupID?.isEmpty == false }

    var conversationID: String {
        if let groupID, !groupID.isEmpty { return groupID }
        // 自消息（自己发出的私聊）必须落进对方会话，而不是「自己 wxid」的会话。
        // 旧 bridge 没有 target_id 时退回 userID，并由启动时的一次性数据修复兜底。
        if isSelf, !targetID.isEmpty { return targetID }
        return userID
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
            case "record":
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
        segments.first { ["image", "record", "face", "file", "video"].contains($0.type) }
    }

    var primaryMessageKind: MessageKind {
        switch primaryMediaSegment?.type {
        case "image": return .image
        case "record": return .voice
        case "face": return .emoji
        case "file": return .file
        case "video": return .video
        default: return .text
        }
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
        let task = session.webSocketTask(with: url)
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
        // get_login_info 的动作回包（{"status":"ok","data":{"user_id":...}}）不是消息事件，
        // 单独解析；否则会被当成「无法识别的帧」丢弃，self_id 只能靠启发式。
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let status = object["status"] as? String, status == "ok",
           let payload = object["data"] as? [String: Any],
           let userID = payload["user_id"] as? String, !userID.isEmpty {
            notifyLoginInfo(userID)
            return
        }
        let events = OneBotEventParser.parse(data: data)
        if events.isEmpty {
            if let text = String(data: data, encoding: .utf8) {
                notifyLog(.debug, "忽略无法识别的 OneBot 帧：\(text.prefix(180))")
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
}

// MARK: - Parser

enum OneBotEventParser {
    /// Parses one or more bridge events from a WS frame. Returns `[]` for unknown frames.
    static func parse(data: Data) -> [OneBotEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let array = object as? [[String: Any]] {
            return array.compactMap { parseEvent($0, rawText: nil) }
        }
        if let dictionary = object as? [String: Any] {
            if let event = parseEvent(dictionary, rawText: nil) { return [event] }
            // Some bridge versions wrap the event: {"post_type":"message","data":{...}}
            if let nested = dictionary["data"] as? [String: Any],
               let event = parseEvent(nested, rawText: nil) {
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

        let segments = parseSegments(raw["message"])
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
                    targetID: string(data["qq"]) ?? string(data["user_id"]) ?? string(data["target_id"])
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
