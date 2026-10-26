import Foundation

// MARK: - Errors

/// CosyVoice3 本地服务客户端的错误（全部带可读中文，供日志与设置页展示）。
enum CosyVoiceError: Error, LocalizedError, Equatable {
    /// 未安装（缺运行环境/模型/音色）。
    case notInstalled
    /// 文本为空或参数非法（请求未发出）。
    case invalidRequest(String)
    /// 服务地址非法（非 http(s) 或无 host）。
    case invalidEndpoint(String)
    /// 无法连接本地服务（进程未启动/端口错误）。
    case serviceNotRunning(String)
    /// 服务正在加载模型（/health 返回 503 loading），稍后重试即可。
    case serviceLoading(String)
    /// 服务可达但状态异常（端口被其他程序占用、5xx、超时等）。
    case serviceUnavailable(String)
    /// 非 2xx 且服务给了结构化错误。
    case httpError(status: Int, message: String)
    /// 响应不是预期格式（非 JSON/非 WAV/字段缺失）。
    case invalidResponse(String)
    /// 返回的音频无法解码（空音频/不支持的 WAV 编码）。
    case audioDecodeFailed(String)
    /// 原始 WAV 落盘失败（不影响合成，仅诊断文件）。
    case outputWriteFailed(String)
    /// 任务被取消。
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "CosyVoice3 尚未安装"
        case .invalidRequest(let reason):
            return "CosyVoice3 请求无效：\(reason)"
        case .invalidEndpoint(let raw):
            return "CosyVoice3 服务地址无效：\(raw)"
        case .serviceNotRunning(let reason):
            return "CosyVoice3 本地服务未运行：\(reason)"
        case .serviceLoading(let reason):
            return "CosyVoice3 正在加载模型：\(reason)"
        case .serviceUnavailable(let reason):
            return "CosyVoice3 服务不可用：\(reason)"
        case .httpError(let status, let message):
            return "CosyVoice3 服务返回错误（HTTP \(status)）：\(message)"
        case .invalidResponse(let reason):
            return "CosyVoice3 响应无法解析：\(reason)"
        case .audioDecodeFailed(let reason):
            return "CosyVoice3 音频无法使用：\(reason)"
        case .outputWriteFailed(let reason):
            return "CosyVoice3 音频写入失败：\(reason)"
        case .cancelled:
            return "CosyVoice3 合成已取消"
        }
    }

    /// 是否值得重试（加载中/超时/连接抖动）。
    var isRetryable: Bool {
        switch self {
        case .serviceLoading, .serviceNotRunning, .serviceUnavailable:
            return true
        case .notInstalled, .invalidRequest, .invalidEndpoint, .httpError,
             .invalidResponse, .audioDecodeFailed, .outputWriteFailed, .cancelled:
            return false
        }
    }

    /// 服务是否「还活着/在加载」——用于启动阶段的健康轮询。
    var isServiceAlive: Bool {
        switch self {
        case .serviceLoading, .serviceUnavailable:
            return true
        case .notInstalled, .invalidRequest, .invalidEndpoint, .serviceNotRunning,
             .httpError, .invalidResponse, .audioDecodeFailed, .outputWriteFailed, .cancelled:
            return false
        }
    }

    /// 端口是否被判为「被其他程序占用」（启动时应直接给出明确提示，不要再等 90 秒）。
    var isPortConflict: Bool {
        if case .httpError = self { return true }
        if case .invalidResponse = self { return true }
        return false
    }
}

// MARK: - 原始合成结果（与 VoiceSynthesisService 的调用面）

/// 一次 CosyVoice3 合成的原始输出：24 kHz 单声道 float PCM（-1...1）。
///
/// `VoiceSynthesisService` 负责后续统一处理（时长/截断/写 WAV），这里只保证
/// 「文本 → 本机 HTTP 服务 → PCM 采样」这段链路正确。
struct CosyVoiceRawSynthesis: Sendable, Equatable {
    var samples: [Float]
    var sampleRate: Int
    /// 服务端原始 24k WAV 在本机的落盘路径（诊断用；可能为 nil）。
    var sourceWAVURL: URL?

    init(samples: [Float], sampleRate: Int, sourceWAVURL: URL? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.sourceWAVURL = sourceWAVURL
    }

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }
}

// MARK: - HTTP transport（URLSession 注入点）

/// 一次 HTTP 往返的最小抽象。单测用 `URLProtocol` 注入 `URLSession` 即可，
/// 这个协议只是为了让 client 内部不绑定全局 `URLSession.shared`。
protocol CosyVoiceHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct CosyVoiceURLSessionTransport: CosyVoiceHTTPTransport {
    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CosyVoiceError.invalidResponse("非 HTTP 响应")
        }
        return (data, http)
    }
}

// MARK: - Client

/// CosyVoice3 本地 HTTP 服务客户端（`devtools/cosyvoice/CONTRACT.md`）。
///
/// 设计边界：
/// - **actor**：串行化请求与配置读写；模型常驻服务进程，HTTP 本身无状态；
/// - **只负责「文本 → PCM」**：WAV 的最终落盘/重采样/截断由 `VoiceSynthesisService` 统一做；
/// - 原始 24k WAV 仍会落一份到 `media/tts/cosyvoice/`（诊断用，24h 清理），
///   解码后用内存采样返回，不阻塞调用方；
/// - 所有网络错误都映射成可读中文，并区分「未运行 / 加载中 / 端口冲突」，
///   启动器据此决定是继续等待还是直接报错。
actor CosyVoiceClient {
    /// 服务默认地址（`127.0.0.1:5051`）。
    static let defaultEndpoint = URL(string: "http://127.0.0.1:5051")!
    /// 模型原生采样率（CosyVoice3 固定 24k）。
    static let defaultSampleRate = 24_000
    /// 服务端限制的最大文本长度（超过会被服务拒绝；App 正常已截断到 500 内）。
    static let maxTextCharacters = 500

    static let shared = CosyVoiceClient()

    struct Configuration: Sendable, Equatable {
        var endpoint: URL
        var healthTimeout: TimeInterval
        var voicesTimeout: TimeInterval
        var synthesisTimeout: TimeInterval
        /// 原始 WAV 落盘目录（诊断用）。
        var outputDirectory: URL

        init(
            endpoint: URL = CosyVoiceClient.defaultEndpoint,
            healthTimeout: TimeInterval = 3,
            voicesTimeout: TimeInterval = 5,
            // 非流式 /tts；CPU 热态 RTF ≈1.8，100+ 字可能超过 2 分钟（runtime 侧实测建议 ≥180s）。
            synthesisTimeout: TimeInterval = 180,
            outputDirectory: URL = CosyVoiceClient.defaultOutputDirectory
        ) {
            self.endpoint = endpoint
            self.healthTimeout = healthTimeout
            self.voicesTimeout = voicesTimeout
            self.synthesisTimeout = synthesisTimeout
            self.outputDirectory = outputDirectory
        }

        static var `default`: Configuration { Configuration() }
    }

    /// 原始 WAV 目录：`~/Library/Application Support/WeChatAI/media/tts/cosyvoice/`。
    nonisolated static var defaultOutputDirectory: URL {
        AppPaths.mediaDirectory
            .appendingPathComponent("tts", isDirectory: true)
            .appendingPathComponent("cosyvoice", isDirectory: true)
    }

    /// 默认 URLSession：短超时 + 不缓存 + 不等待网络（本地服务必须快速失败）。
    nonisolated static var defaultSession: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }

    private var configuration: Configuration
    private let transport: any CosyVoiceHTTPTransport
    private let fileManager: FileManager
    /// 原始 WAV 保留时长（与 TTS 产物一致）。
    static let rawWAVRetention: TimeInterval = 24 * 60 * 60

    init(
        configuration: Configuration = .default,
        session: URLSession? = nil,
        transport: (any CosyVoiceHTTPTransport)? = nil,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.transport = transport
            ?? CosyVoiceURLSessionTransport(session: session ?? Self.defaultSession)
        self.fileManager = fileManager
    }

    // MARK: 配置

    func currentConfiguration() -> Configuration { configuration }

    func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    func updateEndpoint(_ endpoint: URL) {
        configuration.endpoint = endpoint
    }

    // MARK: Health / voices

    /// `GET /health`。加载中（503）抛 `.serviceLoading`；连接失败抛 `.serviceNotRunning`；
    /// 端口被其他程序占用（非预期 JSON/非 2xx）抛 `.httpError`/`.invalidResponse`。
    func health() async throws -> CosyVoiceHealth {
        try await health(timeout: configuration.healthTimeout)
    }

    func health(timeout: TimeInterval) async throws -> CosyVoiceHealth {
        try await health(timeout: timeout, endpoint: configuration.endpoint)
    }

    /// 指定 endpoint 的健康检查（启动器在探测阶段使用，不改全局配置）。
    func health(timeout: TimeInterval, endpoint: URL?) async throws -> CosyVoiceHealth {
        let endpoint = endpoint ?? configuration.endpoint
        let request = try Self.healthRequest(endpoint: endpoint, timeout: timeout)
        let (data, response) = try await perform(request)
        let health: CosyVoiceHealth
        do {
            health = try JSONDecoder().decode(CosyVoiceHealth.self, from: data)
        } catch {
            // 端口被其他 HTTP 服务占用（返回 HTML/纯文本）时，不能误判为「服务在加载」。
            throw CosyVoiceError.invalidResponse(
                Self.errorMessage(from: data, status: response.statusCode))
        }
        switch response.statusCode {
        case 200:
            guard health.isReady else {
                let reason = health.progress ?? health.failureReason ?? "模型尚未就绪"
                if health.loading { throw CosyVoiceError.serviceLoading(reason) }
                throw CosyVoiceError.serviceUnavailable(health.failureReason ?? reason)
            }
            return health
        case 503:
            throw CosyVoiceError.serviceLoading(
                health.progress ?? health.failureReason ?? "模型加载中")
        default:
            throw CosyVoiceError.httpError(
                status: response.statusCode,
                message: health.failureReason
                    ?? Self.errorMessage(from: data, status: response.statusCode))
        }
    }

    /// `GET /voices`；坏条目跳过，空列表由调用方回退本地默认三音色。
    func voices() async throws -> [CosyVoiceVoice] {
        try await voices(endpoint: configuration.endpoint)
    }

    /// 指定 endpoint 的音色列表（设置页按当前设置地址刷新）。
    func voices(endpoint: URL?) async throws -> [CosyVoiceVoice] {
        let request = try Self.voicesRequest(
            endpoint: endpoint ?? configuration.endpoint, timeout: configuration.voicesTimeout)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CosyVoiceError.httpError(
                status: response.statusCode,
                message: Self.errorMessage(from: data, status: response.statusCode))
        }
        do {
            return try JSONDecoder().decode(CosyVoiceVoiceList.self, from: data).voices
        } catch {
            throw CosyVoiceError.invalidResponse("音色列表不是有效 JSON")
        }
    }

    /// `POST /voices/reload`：让服务重新读取 `voices.json` 并返回最新音色。
    ///
    /// 设置页新增/编辑/删除音色后调用；服务未运行时由调用方跳过（下次启动生效）。
    func reloadVoices() async throws -> [CosyVoiceVoice] {
        let request = try Self.reloadVoicesRequest(
            endpoint: configuration.endpoint,
            timeout: max(5, configuration.voicesTimeout * 2))
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CosyVoiceError.httpError(
                status: response.statusCode,
                message: Self.errorMessage(from: data, status: response.statusCode))
        }
        if let list = try? JSONDecoder().decode(CosyVoiceVoiceList.self, from: data) {
            return list.voices
        }
        if let voices = try? JSONDecoder().decode([CosyVoiceVoice].self, from: data) {
            return voices
        }
        throw CosyVoiceError.invalidResponse("音色重载响应无法解析")
    }

    /// `POST /voices/reload` 的纯请求构造（单测用）。
    static func reloadVoicesRequest(endpoint: URL, timeout: TimeInterval) throws -> URLRequest {
        try makeRequest(
            url: endpointURL(endpoint, path: "voices/reload"),
            method: "POST",
            timeout: timeout,
            body: Data("{}".utf8)
        )
    }

    // MARK: TTS

    /// `POST /tts` → 24 kHz 单声道 float PCM。
    ///
    /// - `voiceID`: 空白回退 `girl`；未知 id 交给服务端判定（400 时报错）。
    /// - `speed`: 收敛到 0.5...2.0。
    func synthesizeRaw(
        text: String,
        voiceID: String,
        speed: Double
    ) async throws -> CosyVoiceRawSynthesis {
        try await synthesizeRaw(
            text: text,
            voiceID: voiceID,
            speed: speed,
            timeout: configuration.synthesisTimeout
        )
    }

    func synthesizeRaw(
        text: String,
        voiceID: String,
        speed: Double,
        timeout: TimeInterval
    ) async throws -> CosyVoiceRawSynthesis {
        try await synthesizeRaw(
            text: text, voiceID: voiceID, speed: speed,
            timeout: timeout, endpoint: configuration.endpoint)
    }

    /// 指定 endpoint 的合成（试听/多地址场景使用，不改全局配置）。
    func synthesizeRaw(
        text: String,
        voiceID: String,
        speed: Double,
        timeout: TimeInterval,
        endpoint: URL?
    ) async throws -> CosyVoiceRawSynthesis {
        let endpoint = endpoint ?? configuration.endpoint
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            throw CosyVoiceError.invalidRequest("文本为空")
        }
        guard spoken.count <= Self.maxTextCharacters else {
            throw CosyVoiceError.invalidRequest(
                "文本 \(spoken.count) 字超过服务上限 \(Self.maxTextCharacters) 字")
        }
        let resolvedVoiceID = CosyVoiceVoiceCatalog.resolvedVoiceID(voiceID)
        // 不能把空选择交给服务端（服务端会默认 girl，违反「App 不内置音色」）。
        guard !resolvedVoiceID.isEmpty else {
            throw CosyVoiceError.invalidRequest("未选择 CosyVoice3 音色")
        }
        let clampedSpeed = speed.isFinite ? min(max(speed, 0.5), 2.0) : 1.0
        let request = try Self.ttsRequest(
            endpoint: endpoint,
            text: spoken,
            voiceID: resolvedVoiceID,
            speed: clampedSpeed,
            timeout: timeout
        )
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CosyVoiceError.httpError(
                status: response.statusCode,
                message: Self.errorMessage(from: data, status: response.statusCode))
        }
        guard !data.isEmpty else {
            throw CosyVoiceError.audioDecodeFailed("服务返回空音频")
        }
        // 服务异常时可能仍返回 200 + JSON（不会发生，但防御一下）。
        if Self.looksLikeJSON(data) {
            throw CosyVoiceError.invalidResponse(Self.errorMessage(from: data, status: -1))
        }
        if Task.isCancelled { throw CosyVoiceError.cancelled }

        let decoded: CosyVoiceWAVDecoder.Decoded
        do {
            decoded = try CosyVoiceWAVDecoder.decode(data)
        } catch let error as CosyVoiceError {
            throw error
        } catch {
            throw CosyVoiceError.audioDecodeFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        guard !decoded.samples.isEmpty else {
            throw CosyVoiceError.audioDecodeFailed("服务返回空音频")
        }

        let rawURL = persistRawWAV(data)
        return CosyVoiceRawSynthesis(
            samples: decoded.samples,
            sampleRate: decoded.sampleRate,
            sourceWAVURL: rawURL
        )
    }

    // MARK: 请求构造（纯函数，便于单测）

    /// CosyVoice3 只接受**本机回环**地址：文本不出设备是产品承诺，
    /// 允许远程 host 会把聊天文本发到用户填写的任意服务器。
    static func isLoopbackHost(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value == "::1" || value == "[::1]" { return true }
        // 127.0.0.0/8 全部是回环。
        return value.hasPrefix("127.")
    }

    static func normalizedEndpoint(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "http://" + value
        }
        guard var components = URLComponents(string: value) else { return nil }
        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        guard let host = components.host, !host.isEmpty,
              isLoopbackHost(host) else {
            return nil
        }
        components.path = components.path.isEmpty ? "" : components.path
        return components.url
    }

    static func endpointURL(_ base: URL, path: String) -> URL {
        base.appendingPathComponent(path)
    }

    static func healthRequest(endpoint: URL, timeout: TimeInterval) throws -> URLRequest {
        try makeRequest(
            url: endpointURL(endpoint, path: "health"),
            method: "GET",
            timeout: timeout,
            body: nil
        )
    }

    static func voicesRequest(endpoint: URL, timeout: TimeInterval) throws -> URLRequest {
        try makeRequest(
            url: endpointURL(endpoint, path: "voices"),
            method: "GET",
            timeout: timeout,
            body: nil
        )
    }

    static func ttsRequest(
        endpoint: URL,
        text: String,
        voiceID: String,
        speed: Double,
        timeout: TimeInterval
    ) throws -> URLRequest {
        struct Payload: Encodable {
            let text: String
            let voice_id: String
            let speed: Double
        }
        let data = try JSONEncoder().encode(
            Payload(text: text, voice_id: voiceID, speed: speed))
        return try makeRequest(
            url: endpointURL(endpoint, path: "tts"),
            method: "POST",
            timeout: timeout,
            body: data
        )
    }

    private static func makeRequest(
        url: URL,
        method: String,
        timeout: TimeInterval,
        body: Data?
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = max(0.5, timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: 错误解析

    /// 从错误回包解析可读原因：兼容 `error`/`detail`/`message`/`reason` 字段。
    static func errorMessage(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let code = Self.stringValue(object["error"])
            let detail = Self.stringValue(object["detail"])
            let message = Self.stringValue(object["message"])
            let reason = Self.stringValue(object["reason"])
            let preferred = [detail, message, reason]
                .compactMap { $0 }
                .joined(separator: "；")
            if !preferred.isEmpty {
                if let code, !preferred.contains(code) {
                    return "\(code)：\(preferred)"
                }
                return preferred
            }
            if let code { return code }
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            return String(text.prefix(240))
        }
        return status >= 0 ? "HTTP \(status)" : "响应为空"
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let text = any as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = any as? NSNumber { return number.stringValue }
        return nil
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    // MARK: 网络

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        do {
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            return (data, response)
        } catch let error as CosyVoiceError {
            throw error
        } catch is CancellationError {
            throw CosyVoiceError.cancelled
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    static func mapTransportError(_ error: Error) -> CosyVoiceError {
        if let error = error as? CosyVoiceError { return error }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return .cancelled
            case NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorResourceUnavailable:
                return .serviceNotRunning(nsError.localizedDescription)
            case NSURLErrorTimedOut:
                return .serviceUnavailable("请求超时（服务可能在加载模型）")
            default:
                return .serviceUnavailable(nsError.localizedDescription)
            }
        }
        return .serviceUnavailable(nsError.localizedDescription)
    }

    // MARK: 原始 WAV 落盘 / 清理

    private func persistRawWAV(_ data: Data) -> URL? {
        let directory = configuration.outputDirectory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: Date())
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let url = directory.appendingPathComponent("cosyvoice-\(stamp)-\(suffix).wav")
            try data.write(to: url, options: .atomic)
            pruneRawWAVs(in: directory)
            return url
        } catch {
            // 诊断文件写失败不影响合成结果。
            return nil
        }
    }

    private func pruneRawWAVs(in directory: URL) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Self.rawWAVRetention)
        for file in files where file.pathExtension.lowercased() == "wav" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

// MARK: - WAV 解码

/// 解析服务端 24k WAV（PCM 16-bit 为主；兼容 8/24/32-bit PCM 与 float32），
/// 多声道下混为单声道 float，供 `VoiceSynthesisService` 统一处理。
///
/// 不依赖 `AVAudioFile`：服务返回的内存数据直接解析，失败时能给出精确原因，
/// 也不会因 `AVAudioFile` 的松散格式推断掩盖服务端格式错误。
enum CosyVoiceWAVDecoder {
    struct Decoded: Sendable, Equatable {
        var samples: [Float]
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        var duration: TimeInterval {
            guard sampleRate > 0 else { return 0 }
            return Double(samples.count) / Double(sampleRate)
        }
    }

    static func decode(_ data: Data) throws -> Decoded {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else {
            throw CosyVoiceError.audioDecodeFailed("音频数据过短")
        }
        guard ascii(bytes, 0) == "RIFF", ascii(bytes, 8) == "WAVE" else {
            throw CosyVoiceError.audioDecodeFailed("不是 RIFF/WAVE 音频")
        }
        var format = 0
        var channels = 0
        var sampleRate = 0
        var bits = 0
        var dataStart = -1
        var dataSize = 0
        var offset = 12
        while offset + 8 <= bytes.count {
            let identifier = ascii(bytes, offset)
            let size = intFromLE(bytes, offset + 4, 4)
            let bodyOffset = offset + 8
            guard size >= 0, bodyOffset <= bytes.count else { break }
            if identifier == "fmt " {
                guard bodyOffset + 16 <= bytes.count else {
                    throw CosyVoiceError.audioDecodeFailed("fmt 块不完整")
                }
                format = intFromLE(bytes, bodyOffset, 2)
                channels = intFromLE(bytes, bodyOffset + 2, 2)
                sampleRate = intFromLE(bytes, bodyOffset + 4, 4)
                bits = intFromLE(bytes, bodyOffset + 14, 2)
            } else if identifier == "data" {
                dataStart = bodyOffset
                dataSize = min(size, bytes.count - bodyOffset)
            }
            offset = bodyOffset + size + (size % 2)
        }
        guard format != 0, channels > 0, sampleRate > 0, bits > 0 else {
            throw CosyVoiceError.audioDecodeFailed("缺少 fmt 音频格式信息")
        }
        guard dataStart >= 0, dataSize > 0 else {
            throw CosyVoiceError.audioDecodeFailed("缺少 data 音频数据")
        }
        let bytesPerSample = bits / 8
        guard bytesPerSample > 0 else {
            throw CosyVoiceError.audioDecodeFailed("不支持 \(bits)-bit 音频")
        }
        let frameBytes = bytesPerSample * channels
        let frameCount = dataSize / frameBytes
        guard frameCount > 0 else {
            throw CosyVoiceError.audioDecodeFailed("音频帧数为 0")
        }
        var samples = [Float](repeating: 0, count: frameCount)
        switch (format, bits, bytesPerSample) {
        case (1, 8, 1):
            for frame in 0..<frameCount {
                samples[frame] = average8(
                    bytes, start: dataStart + frame * frameBytes, channels: channels)
            }
        case (1, 16, 2):
            for frame in 0..<frameCount {
                samples[frame] = average16(
                    bytes, start: dataStart + frame * frameBytes, channels: channels)
            }
        case (1, 24, 3):
            for frame in 0..<frameCount {
                samples[frame] = average24(
                    bytes, start: dataStart + frame * frameBytes, channels: channels)
            }
        case (1, 32, 4), (3, 32, 4):
            for frame in 0..<frameCount {
                samples[frame] = average32(
                    bytes, start: dataStart + frame * frameBytes,
                    channels: channels, isFloat: format == 3)
            }
        default:
            throw CosyVoiceError.audioDecodeFailed(
                "不支持的 WAV 编码（format \(format), \(bits)-bit）")
        }
        for index in samples.indices {
            let value = samples[index]
            samples[index] = value.isFinite ? min(max(value, -1), 1) : 0
        }
        return Decoded(
            samples: samples,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bits
        )
    }

    // MARK: 内部

    private static func ascii(_ bytes: [UInt8], _ offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }

    private static func intFromLE(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> Int {
        guard offset >= 0, offset + length <= bytes.count else { return 0 }
        var value = 0
        for index in 0..<length {
            value |= Int(bytes[offset + index]) << (8 * index)
        }
        return value
    }

    private static func average8(_ bytes: [UInt8], start: Int, channels: Int) -> Float {
        var sum: Float = 0
        for channel in 0..<channels {
            let value = bytes[start + channel]
            sum += (Float(value) - 128) / 128
        }
        return sum / Float(channels)
    }

    private static func average16(_ bytes: [UInt8], start: Int, channels: Int) -> Float {
        var sum: Float = 0
        for channel in 0..<channels {
            let raw = Int(bytes[start + channel * 2])
                | (Int(bytes[start + channel * 2 + 1]) << 8)
            let value = raw >= 32_768 ? raw - 65_536 : raw
            sum += Float(value) / 32_768
        }
        return sum / Float(channels)
    }

    private static func average24(_ bytes: [UInt8], start: Int, channels: Int) -> Float {
        var sum: Float = 0
        for channel in 0..<channels {
            let base = start + channel * 3
            var raw = Int(bytes[base])
                | (Int(bytes[base + 1]) << 8)
                | (Int(bytes[base + 2]) << 16)
            if raw >= 8_388_608 { raw -= 16_777_216 }
            sum += Float(raw) / 8_388_608
        }
        return sum / Float(channels)
    }

    private static func average32(
        _ bytes: [UInt8],
        start: Int,
        channels: Int,
        isFloat: Bool
    ) -> Float {
        var sum: Float = 0
        for channel in 0..<channels {
            let base = start + channel * 4
            let raw = UInt32(bytes[base])
                | (UInt32(bytes[base + 1]) << 8)
                | (UInt32(bytes[base + 2]) << 16)
                | (UInt32(bytes[base + 3]) << 24)
            if isFloat {
                sum += Float(bitPattern: raw)
            } else {
                sum += Float(Int32(bitPattern: raw)) / 2_147_483_648
            }
        }
        return sum / Float(channels)
    }
}
