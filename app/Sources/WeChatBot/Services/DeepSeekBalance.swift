import Foundation

// MARK: - Models

/// DeepSeek 账户余额中的一种币种。金额按 API 返回的字符串保存，避免
/// Decimal/Double 转换把 `110.00` 显示成 `110` 或引入浮点误差。
struct DeepSeekBalanceInfo: Equatable, Sendable, Identifiable {
    var currency: String
    var totalBalance: String
    var grantedBalance: String
    var toppedUpBalance: String

    var id: String { currency }

    var currencySymbol: String {
        switch currency.uppercased() {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        default: return ""
        }
    }

    /// 展示用总额，如 `¥110.00`；币种未知时退化为 `110.00 USD`。
    var displayTotal: String {
        let symbol = currencySymbol
        if symbol.isEmpty { return "\(totalBalance) \(currency)" }
        return symbol + totalBalance
    }
}

/// `GET /user/balance` 的一次成功响应。
struct DeepSeekBalanceSnapshot: Equatable, Sendable {
    var isAvailable: Bool
    var infos: [DeepSeekBalanceInfo]
    var fetchedAt: Date

    /// 优先人民币账户；多币种账户只展示主要币种，详情行里仍能看到其它金额。
    var primary: DeepSeekBalanceInfo? {
        infos.first(where: { $0.currency.uppercased() == "CNY" }) ?? infos.first
    }
}

/// 总览 / 菜单栏展示的余额状态。`unavailable` 表示尚未配置（不是故障），
/// `failed` 表示请求或解析失败；两者用不同的视觉与文案区分。
enum DeepSeekBalanceState: Equatable, Sendable {
    case idle
    case loading
    case unavailable(String)
    case loaded(DeepSeekBalanceSnapshot)
    case failed(String)
}

// MARK: - Errors

enum DeepSeekBalanceError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case missingAPIKey
    case unauthorized
    case httpStatus(Int, String)
    case malformedResponse(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let raw):
            return "余额接口地址无效：\(raw)"
        case .missingAPIKey:
            return "缺少 DeepSeek API Key，请在「AI 模型」中填写"
        case .unauthorized:
            return "DeepSeek API Key 无效或已过期（HTTP 401）"
        case .httpStatus(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty { return "余额查询失败（HTTP \(status)）" }
            return "余额查询失败（HTTP \(status)）：\(detail.prefix(160))"
        case .malformedResponse(let detail):
            return "余额响应解析失败：\(detail)"
        case .transport(let message):
            return "网络错误：\(message)"
        }
    }
}

// MARK: - Provider resolution

/// 选择用于查询余额的 DeepSeek 通道。
///
/// 聊天默认通道是 DeepSeek 时直接用它；默认通道是 OpenAI/Ollama 时，余额仍应
/// 显示账户信息，因此回退到第一个已启用且配置了 Key 的 DeepSeek 通道。
/// 完全没有 DeepSeek 通道时返回 nil，由 UI 提示去「AI 模型」添加。
enum DeepSeekProviderResolver {
    static func resolve(providers: [AIProvider], defaultProvider: AIProvider?) -> AIProvider? {
        if let defaultProvider, defaultProvider.kind == .deepSeek { return defaultProvider }
        let deepSeek = providers.filter { $0.kind == .deepSeek }
        return deepSeek.first(where: { $0.enabled && $0.hasAPIKey })
            ?? deepSeek.first(where: { $0.hasAPIKey })
            ?? deepSeek.first(where: { $0.enabled })
            ?? deepSeek.first
    }
}

// MARK: - Client

/// DeepSeek 余额查询客户端。
///
/// 余额接口固定在 API 根路径：`https://api.deepseek.com/user/balance`，
/// 与聊天 base URL 是否带 `/v1` 无关（`/v1/user/balance` 会 404）。
final class DeepSeekBalanceClient: @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 15) {
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// 由聊天 base URL 推导余额地址：保留 scheme/host/port，路径固定为 `/user/balance`。
    static func balanceURL(baseURL: String) throws -> URL {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { raw = ProviderKind.deepSeek.defaultBaseURL }
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else {
            throw DeepSeekBalanceError.invalidBaseURL(raw)
        }
        components.path = "/user/balance"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw DeepSeekBalanceError.invalidBaseURL(raw)
        }
        return url
    }

    /// 解析响应。拆成静态函数便于用固定 JSON 做单元测试，不发起网络请求。
    static func parse(
        data: Data,
        statusCode: Int,
        fetchedAt: Date = Date()
    ) throws -> DeepSeekBalanceSnapshot {
        if statusCode == 401 || statusCode == 403 { throw DeepSeekBalanceError.unauthorized }
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw DeepSeekBalanceError.httpStatus(statusCode, body)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekBalanceError.malformedResponse(
                String(data: data.prefix(200), encoding: .utf8) ?? "非 JSON"
            )
        }
        guard let rawInfos = object["balance_infos"] as? [[String: Any]] else {
            throw DeepSeekBalanceError.malformedResponse("缺少 balance_infos")
        }
        let infos = rawInfos.compactMap(DeepSeekBalanceInfo.init(apiObject:))
        guard !infos.isEmpty else {
            throw DeepSeekBalanceError.malformedResponse("balance_infos 为空或缺少金额")
        }
        return DeepSeekBalanceSnapshot(
            isAvailable: bool(object["is_available"]) ?? true,
            infos: infos,
            fetchedAt: fetchedAt
        )
    }

    /// 请求余额。Key 由调用方从 Keychain 读出后传入，本类型不接触密钥存储。
    func fetch(apiKey: String, baseURL: String) async throws -> DeepSeekBalanceSnapshot {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DeepSeekBalanceError.missingAPIKey }
        let url = try Self.balanceURL(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError { throw error }
            throw DeepSeekBalanceError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.parse(data: data, statusCode: status)
    }

    // MARK: Tolerant value readers

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let string as String:
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}

private extension DeepSeekBalanceInfo {
    /// 兼容字符串金额（官方文档）与数字金额（部分兼容端点）。
    init?(apiObject: [String: Any]) {
        guard let currency = apiObject["currency"] as? String,
              let total = Self.amount(apiObject["total_balance"])
        else { return nil }
        self.init(
            currency: currency,
            totalBalance: total,
            grantedBalance: Self.amount(apiObject["granted_balance"]) ?? "0",
            toppedUpBalance: Self.amount(apiObject["topped_up_balance"]) ?? "0"
        )
    }

    private static func amount(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
