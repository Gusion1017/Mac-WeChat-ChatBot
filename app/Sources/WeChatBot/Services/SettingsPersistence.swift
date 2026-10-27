import Foundation

/// Serialized, atomic persistence for `AppSettings` (docs/architecture.md §5).
///
/// 设置分成两个文件（实施契约 §2.3）：
/// - `config.json`：全局设置 + 完整 `AppSettings` 镜像（兼容旧版），不随账号切换；
/// - `accounts/<id>/profile.json`：账号级 `bot / personas / schedules`，随账号切换。
///
/// - Loading reuses `SettingsStore` so corruption fallback stays in one place.
/// - Saving is done here off the main actor: encode once per file, write once, atomic replace.
/// - Identical consecutive saves are skipped **per file** after comparing encoded bytes.
/// - All writes funnel through this actor, so a burst of UI mutations can never
///   interleave partial files.
actor SettingsPersistence {
    /// 应用实例：`config.json` + **当前账号**的 `profile.json`。
    ///
    /// profile 路径不缓存在实例里：`load()` / `scheduleSave()` 每次取
    /// `AppPaths.profileFile`，`save(_:profileURL:)` 由调用方在保存时传入
    /// （`AppStore.persist()` 在 MainActor 上捕获），切号后不会串写旧/新账号。
    static let shared = SettingsPersistence(configURL: AppPaths.configFile)

    private let configURL: URL
    /// `true` = 应用实例（`init(configURL:)`）；`false` = 测试/旧调用实例
    /// （`init(fileURL:)`，只读写 config、不碰 profile）。
    private let persistsActiveAccountProfile: Bool
    private let encoder: JSONEncoder
    private var lastSavedConfigData: Data?
    private var lastSavedProfileData: Data?
    /// 上次写 profile 的目标路径：切号后即使 bytes 相同也要在新账号目录落一份。
    private var lastSavedProfileURL: URL?
    private var pendingSave: Task<Void, Error>?

    /// config-only persistence（测试与旧调用）；`init(fileURL:)` 保持兼容。
    init(fileURL: URL = AppPaths.configFile) {
        self.configURL = fileURL
        self.persistsActiveAccountProfile = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    /// 应用持久化：config.json + 当前账号 profile.json。
    init(configURL: URL) {
        self.configURL = configURL
        self.persistsActiveAccountProfile = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    /// Loads settings synchronously. Reuses the shared `SettingsStore` implementation
    /// so the corrupt-file backup path and defaults stay centralised.
    /// (Called from a background task; blocking file IO must not run on the main actor.)
    nonisolated func load() -> AppSettings {
        guard persistsActiveAccountProfile else {
            return SettingsStore.load(configURL: configURL, profileURL: nil)
        }
        AppPaths.ensureDirectories()
        return SettingsStore.load(configURL: configURL, profileURL: AppPaths.profileFile)
    }

    /// 旧签名：只写全局 `config.json`（测试与旧调用兼容）。账号字段由调用方通过
    /// `save(_:profileURL:)` 显式双写（`AppStore.persist()` 在调用时捕获 profile 路径）。
    @discardableResult
    func save(_ settings: AppSettings) throws -> Bool {
        try save(settings, profileURL: nil)
    }

    /// Encodes and atomically persists `settings`. `profileURL` 非 nil 时双写：
    /// config 始终写（按 encoded bytes 去重），profile 同样按文件去重；
    /// 返回是否有任一文件发生变化。Throws so callers can surface failures.
    @discardableResult
    func save(_ settings: AppSettings, profileURL: URL?) throws -> Bool {
        let configData = try encoder.encode(settings)
        var changed = false

        if configData != lastSavedConfigData {
            try write(configData, to: configURL)
            lastSavedConfigData = configData
            changed = true
        }

        if let profileURL {
            let profileData = try encoder.encode(settings.profile)
            // 路径变化（切号）时即使内容相同也必须写：新账号目录可能还没有 profile.json。
            if profileData != lastSavedProfileData || profileURL != lastSavedProfileURL {
                try write(profileData, to: profileURL)
                lastSavedProfileData = profileData
                lastSavedProfileURL = profileURL
                changed = true
            }
        }

        return changed
    }

    /// Coalescing save for high-frequency callers (e.g. toggling a switch).
    /// A newer call replaces the pending one; the last settings always win.
    /// 应用实例会在**调用时**捕获当前账号 profile 路径，避免延迟写入跨号。
    func scheduleSave(_ settings: AppSettings) {
        let profileURL = persistsActiveAccountProfile ? AppPaths.profileFile : nil
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            guard let self else { return }
            try await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            _ = try await self.save(settings, profileURL: profileURL)
        }
    }

    /// Waits for a scheduled save (used on termination).
    func flush() async {
        if let pendingSave {
            _ = try? await pendingSave.value
            self.pendingSave = nil
        }
    }

    private func write(_ data: Data, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw SettingsPersistenceError.writeFailed(error)
        }
    }
}

enum SettingsPersistenceError: LocalizedError {
    case writeFailed(Error)

    var errorDescription: String? {
        if case .writeFailed(let error) = self {
            return "配置写入失败：\(error.localizedDescription)"
        }
        return "配置写入失败"
    }
}
