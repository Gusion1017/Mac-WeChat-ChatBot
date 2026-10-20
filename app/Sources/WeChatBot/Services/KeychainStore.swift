import Foundation
import Security

/// Thin wrapper around the macOS Keychain for API keys.
///
/// Contract (docs/architecture.md §5):
/// - `kSecClassGenericPassword`
/// - `kSecAttrService == AppPaths.bundleID` (`com.gusionw.wechatai`)
/// - `kSecAttrAccount == AIProvider.apiKeyReference`
///
/// Secrets never touch `config.json`; only the account reference does.
struct KeychainStore: Sendable {
    static let shared = KeychainStore()

    let service: String

    init(service: String = AppPaths.bundleID) {
        self.service = service
    }

    /// Creates or replaces the key for `account`.
    func setAPIKey(_ key: String, for account: String) throws {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { throw KeychainError.invalidAccount }
        guard let data = key.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let query = baseQuery(account: trimmedAccount)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
            return
        }
        guard status == errSecItemNotFound else { throw KeychainError.osStatus(status) }

        var addQuery = query
        for (key, value) in attributes { addQuery[key] = value }
        status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    /// Reads a secret. Returns `nil` when the item does not exist.
    func apiKey(for account: String) throws -> String? {
        guard !account.isEmpty else { return nil }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.decodingFailed }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Non-throwing existence probe. Used by UI to show "已配置 / 未配置".
    func hasAPIKey(for account: String) -> Bool {
        (try? apiKey(for: account))?.isEmpty == false
    }

    /// Deletes the secret. Succeeds when the item is already absent.
    func deleteAPIKey(for account: String) throws {
        guard !account.isEmpty else { return }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    /// Lists account names stored under this service. Never returns secrets.
    func listAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum KeychainError: LocalizedError, Equatable {
    case invalidAccount
    case encodingFailed
    case decodingFailed
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAccount:
            return "Keychain 账户名不能为空"
        case .encodingFailed:
            return "API Key 编码失败"
        case .decodingFailed:
            return "Keychain 数据解码失败"
        case .osStatus(let status):
            return "Keychain 操作失败 (OSStatus \(status))"
        }
    }
}
