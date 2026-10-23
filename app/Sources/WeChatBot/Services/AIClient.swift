import Foundation
import Security

// MARK: - Types

struct AIMessage: Codable, Sendable, Hashable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    var role: Role
    var content: String
    /// 多模态图片（`data:image/jpeg;base64,…` 或 http(s) URL）。仅 user 消息使用；
    /// 为空时请求体保持旧的字符串 content，文本通道行为完全不变。
    var imageURLs: [String] = []

    init(role: Role, content: String, imageURLs: [String] = []) {
        self.role = role
        self.content = content
        self.imageURLs = imageURLs
    }

    static func system(_ content: String) -> AIMessage { .init(role: .system, content: content) }
    static func user(_ content: String, images: [String] = []) -> AIMessage {
        .init(role: .user, content: content, imageURLs: images)
    }
    static func assistant(_ content: String) -> AIMessage { .init(role: .assistant, content: content) }
}

struct AIUsage: Codable, Sendable, Hashable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0
}

struct AICompletionResult: Sendable {
    var text: String
    var model: String
    var usage: AIUsage
    var latencyMs: Double
    var finishReason: String?
    var streamed: Bool

    var approxTokens: Int {
        usage.totalTokens > 0 ? usage.totalTokens : max(1, text.count / 2)
    }
}

enum AIError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidBaseURL(String)
    case malformedResponse(String)
    case httpStatus(Int, String)
    case providerError(String)
    case timedOut
    case cancelled
    case emptyResponse
    case transport(String)

    var isRetryable: Bool {
        switch self {
        case .httpStatus(let status, _):
            return status == 408 || status == 409 || status == 429 || (500...599).contains(status)
        case .timedOut, .transport, .emptyResponse:
            return true
        case .missingAPIKey, .invalidBaseURL, .malformedResponse, .providerError, .cancelled:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置 API Key，请在「AI 模型」中填写"
        case .invalidBaseURL(let url):
            return "API 地址无效：\(url)"
        case .malformedResponse(let detail):
            return "AI 响应解析失败：\(detail)"
        case .httpStatus(let status, let body):
            switch status {
            case 401, 403: return "API 鉴权失败（HTTP \(status)），请检查 Key"
            case 404: return "API 地址或模型不存在（HTTP 404）"
            case 429: return "请求过于频繁或额度不足（HTTP 429）"
            default: return "AI 服务错误（HTTP \(status)）：\(body.prefix(200))"
            }
        case .providerError(let message):
            return "AI 服务返回错误：\(message)"
        case .timedOut:
            return "AI 请求超时"
        case .cancelled:
            return "AI 请求已取消"
        case .emptyResponse:
            return "AI 返回了空内容"
        case .transport(let message):
            return "AI 网络错误：\(message)"
        }
    }
}

// MARK: - Client

/// DeepSeek 思考模式开关（OpenAI 兼容请求体里的顶层 `thinking` 字段）。
///
/// 识图请求默认关闭：思考内容会占用输出额度，短描述场景既慢又容易把
/// `max_tokens` 全部消耗在推理上，导致 `content` 为空（2026-10-23 真机日志）。
enum AIThinkingMode: String, Sendable, Equatable {
    case enabled
    case disabled
}

/// AI 凭据可用性。`.unreadable` 表示 Keychain 条目存在但当前签名无权读取，
/// 与「用户还没填 Key」是两种不同的故障，UI/日志需要分别提示。
enum ProviderCredentialState: Sendable, Equatable {
    case available
    case missing
    case unreadable(OSStatus)
}

/// OpenAI-compatible `/chat/completions` client with SSE streaming.
///
/// Supports DeepSeek / OpenAI / Ollama / custom endpoints. API keys are read from
/// the Keychain via `provider.apiKeyReference`; secrets never appear in settings JSON.
/// Blocking work is URLSession-async only; safe to call from a background task.
final class AIClient: @unchecked Sendable {
    private let keychain: KeychainStore
    private let session: URLSession

    init(keychain: KeychainStore = .shared) {
        self.keychain = keychain
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate"]
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: Endpoint helpers (also used by diagnostics)

    static func endpoint(for provider: AIProvider) throws -> URL {
        var raw = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { raw = provider.kind.defaultBaseURL }
        guard !raw.isEmpty else { throw AIError.invalidBaseURL("(空)") }
        if raw.hasSuffix("/") { raw.removeLast() }
        if !raw.lowercased().hasSuffix("/chat/completions") {
            raw += "/chat/completions"
        }
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            throw AIError.invalidBaseURL(raw)
        }
        return url
    }

    static func effectiveModel(for provider: AIProvider) -> String {
        let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? provider.kind.defaultModel : model
    }

    /// Builds the chat-completions body. `temperature` is omitted unless the model
    /// has an explicit per-model value, so each model can use its own default.
    ///
    /// 带图片的 user 消息使用 OpenAI 多模态 content 数组：
    /// `[{"type":"text","text":…},{"type":"image_url","image_url":{"url":…}}]`；
    /// 无图片时仍发送字符串 content，兼容只支持纯文本的旧端点。
    static func requestBody(
        messages: [AIMessage],
        provider: AIProvider,
        temperature: Double? = nil,
        stream: Bool,
        thinking: AIThinkingMode? = nil
    ) throws -> Data {
        var payload: [String: Any] = [
            "model": effectiveModel(for: provider),
            "messages": messages.map { message in
                var encoded: [String: Any] = ["role": message.role.rawValue]
                if message.imageURLs.isEmpty {
                    encoded["content"] = message.content
                } else {
                    var parts: [[String: Any]] = []
                    if !message.content.isEmpty {
                        parts.append(["type": "text", "text": message.content])
                    }
                    for url in message.imageURLs {
                        parts.append(["type": "image_url", "image_url": ["url": url]])
                    }
                    encoded["content"] = parts
                }
                return encoded
            },
            "max_tokens": max(1, provider.maxTokens),
            "stream": stream
        ]
        if let temperature {
            payload["temperature"] = min(max(temperature, 0), 2)
        }
        if let thinking {
            // DeepSeek 扩展字段：顶层 {"thinking": {"type": "enabled/disabled"}}。
            payload["thinking"] = ["type": thinking.rawValue]
        }
        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            throw AIError.malformedResponse("请求体编码失败：\(error.localizedDescription)")
        }
    }

    /// Whether the provider has a usable credential. Ollama/custom may be keyless.
    func hasCredential(for provider: AIProvider) -> Bool {
        credentialState(for: provider) == .available
    }

    /// 凭据状态：能区分「未配置」和「Keychain 读取被拒」。
    ///
    /// 后者常见于 app 重新构建/重签后：ad-hoc 签名的 designated requirement 是
    /// cdhash，Keychain 授权仍绑定旧签名，读取会返回 errSecAuthFailed /
    /// errSecInteractionNotAllowed。旧实现把这两种情况都报成「缺少 API Key」，
    /// 用户会误以为密钥没保存。启动时应在后台线程调用本方法，避免 Keychain
    /// 授权弹窗把主线程卡住（曾实测 8 秒卡顿）。
    func credentialState(for provider: AIProvider) -> ProviderCredentialState {
        guard !provider.apiKeyReference.isEmpty else {
            return (provider.kind == .ollama || provider.kind == .custom) ? .available : .missing
        }
        do {
            guard let key = try keychain.apiKey(for: provider.apiKeyReference),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .missing
            }
            return .available
        } catch let KeychainError.osStatus(status) {
            return .unreadable(status)
        } catch {
            return .unreadable(errSecInternalError)
        }
    }

    func apiKey(for provider: AIProvider) -> String? {
        guard !provider.apiKeyReference.isEmpty else { return nil }
        return try? keychain.apiKey(for: provider.apiKeyReference)
    }

    // MARK: Completion

    /// Runs one completion. Streaming is selected by `forceStream ?? provider.stream`.
    /// `onDelta` is invoked for each content delta (streaming only) off the main actor.
    func complete(
        messages: [AIMessage],
        provider: AIProvider,
        temperature: Double? = nil,
        forceStream: Bool? = nil,
        thinking: AIThinkingMode? = nil,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> AICompletionResult {
        let useStream = forceStream ?? provider.stream
        let started = Date()
        let text: String
        let usage: AIUsage
        let model: String
        let finishReason: String?

        if useStream {
            let outcome = try await performStream(
                messages: messages,
                provider: provider,
                temperature: temperature,
                thinking: thinking,
                onDelta: onDelta
            )
            text = outcome.text
            usage = outcome.usage
            model = outcome.model
            finishReason = outcome.finishReason
        } else {
            let outcome = try await performJSON(
                messages: messages,
                provider: provider,
                temperature: temperature,
                thinking: thinking
            )
            text = outcome.text
            usage = outcome.usage
            model = outcome.model
            finishReason = outcome.finishReason
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.emptyResponse }
        return AICompletionResult(
            text: trimmed,
            model: model.isEmpty ? Self.effectiveModel(for: provider) : model,
            usage: usage,
            latencyMs: Date().timeIntervalSince(started) * 1000,
            finishReason: finishReason,
            streamed: useStream
        )
    }

    // MARK: Requests

    private struct Outcome {
        var text: String
        var model: String
        var usage: AIUsage
        var finishReason: String?
    }

    private func makeRequest(
        messages: [AIMessage],
        provider: AIProvider,
        temperature: Double?,
        stream: Bool,
        thinking: AIThinkingMode? = nil
    ) throws -> URLRequest {
        let url = try Self.endpoint(for: provider)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = max(5, provider.timeoutSeconds)
        if !provider.stream {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        } else {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        if let key = apiKey(for: provider), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if provider.kind != .ollama && !provider.apiKeyReference.isEmpty {
            throw AIError.missingAPIKey
        } else if provider.kind == .deepSeek || provider.kind == .openAI {
            if provider.apiKeyReference.isEmpty { throw AIError.missingAPIKey }
        }

        request.httpBody = try Self.requestBody(
            messages: messages,
            provider: provider,
            temperature: temperature,
            stream: stream,
            thinking: thinking
        )
        return request
    }

    private func performJSON(
        messages: [AIMessage],
        provider: AIProvider,
        temperature: Double?,
        thinking: AIThinkingMode? = nil
    ) async throws -> Outcome {
        let request = try makeRequest(
            messages: messages,
            provider: provider,
            temperature: temperature,
            stream: false,
            thinking: thinking
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        try Self.validate(response: response, body: data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.malformedResponse(String(data: data.prefix(300), encoding: .utf8) ?? "非 JSON")
        }
        if let error = Self.providerError(from: object) { throw AIError.providerError(error) }

        let choice = (object["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        let text = Self.contentString(message?["content"]) ?? Self.contentString(message?["reasoning_content"]) ?? ""
        let usage = Self.usage(from: object["usage"])
        let model = object["model"] as? String ?? ""
        let finish = choice?["finish_reason"] as? String
        guard !text.isEmpty else { throw AIError.emptyResponse }
        return Outcome(text: text, model: model, usage: usage, finishReason: finish)
    }

    private func performStream(
        messages: [AIMessage],
        provider: AIProvider,
        temperature: Double?,
        thinking: AIThinkingMode? = nil,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> Outcome {
        let request = try makeRequest(
            messages: messages,
            provider: provider,
            temperature: temperature,
            stream: true,
            thinking: thinking
        )
        let timeout = max(5, provider.timeoutSeconds)

        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                let (bytes, response) = try await self.session.bytes(for: request)
                var collected = ""
                var usage = AIUsage()
                var model = ""
                var finishReason: String?

                // Validate status before consuming the stream body.
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    var body = ""
                    for try await line in bytes.lines {
                        body += line
                        if body.count > 2000 { break }
                    }
                    throw AIError.httpStatus(http.statusCode, body)
                }

                for try await line in bytes.lines {
                    if Task.isCancelled { throw AIError.cancelled }
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    guard trimmedLine.hasPrefix("data:") else { continue }
                    let payload = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload.isEmpty { continue }
                    if payload == "[DONE]" { break }
                    guard let chunkData = payload.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                        continue
                    }
                    if let modelName = object["model"] as? String, !modelName.isEmpty { model = modelName }
                    if let streamUsage = object["usage"] as? [String: Any] {
                        usage = AIUsage(
                            promptTokens: Self.int(streamUsage["prompt_tokens"]),
                            completionTokens: Self.int(streamUsage["completion_tokens"]),
                            totalTokens: Self.int(streamUsage["total_tokens"])
                        )
                    }
                    if let error = Self.providerError(from: object) { throw AIError.providerError(error) }
                    guard let choice = (object["choices"] as? [[String: Any]])?.first else { continue }
                    let delta = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any])
                    if let content = Self.contentString(delta?["content"]), !content.isEmpty {
                        collected += content
                        onDelta?(content)
                    }
                    if let reason = choice["finish_reason"] as? String { finishReason = reason }
                }
                return Outcome(text: collected, model: model, usage: usage, finishReason: finishReason)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AIError.timedOut
            }
            guard let first = try await group.next() else { throw AIError.emptyResponse }
            group.cancelAll()
            return first
        }
    }

    // MARK: Error mapping

    private static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AIError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: body.prefix(600), encoding: .utf8) ?? ""
            var detail = text
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let message = providerError(from: object) {
                detail = message
            }
            throw AIError.httpStatus(http.statusCode, detail)
        }
    }

    private static func providerError(from object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["type"] as? String) ?? "未知错误"
        }
        if let error = object["error"] as? String { return error }
        if let status = object["status"] as? String, status == "failed" {
            return (object["message"] as? String) ?? (object["error"] as? String) ?? "failed"
        }
        return nil
    }

    static func mapTransportError(_ error: Error) -> AIError {
        if error is CancellationError { return .cancelled }
        if let aiError = error as? AIError { return aiError }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorCancelled: return .cancelled
            default: return .transport(nsError.localizedDescription)
            }
        }
        return .transport(nsError.localizedDescription)
    }

    // MARK: Tolerant JSON helpers

    private static func contentString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let parts = value as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func usage(from value: Any?) -> AIUsage {
        guard let dictionary = value as? [String: Any] else { return AIUsage() }
        return AIUsage(
            promptTokens: int(dictionary["prompt_tokens"]),
            completionTokens: int(dictionary["completion_tokens"]),
            totalTokens: int(dictionary["total_tokens"])
        )
    }

    private static func int(_ value: Any?) -> Int {
        switch value {
        case let int as Int: return int
        case let double as Double: return Int(double)
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string) ?? 0
        default: return 0
        }
    }
}
