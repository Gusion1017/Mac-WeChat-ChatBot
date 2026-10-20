import Foundation

/// Serialized, atomic persistence for `AppSettings` (docs/architecture.md §5).
///
/// - Loading reuses `SettingsStore.load()` so corruption fallback stays in one place.
/// - Saving is done here off the main actor: encode once, write once, atomic replace.
/// - Identical consecutive saves are skipped after comparing encoded bytes.
/// - All writes funnel through this actor, so a burst of UI mutations can never
///   interleave partial files.
actor SettingsPersistence {
    static let shared = SettingsPersistence()

    private let fileURL: URL
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private var lastSavedData: Data?
    private var pendingSave: Task<Void, Error>?

    init(fileURL: URL = AppPaths.configFile) {
        self.fileURL = fileURL
        self.directoryURL = fileURL.deletingLastPathComponent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    /// Loads settings synchronously. Reuses the shared `SettingsStore` implementation
    /// so the corrupt-file backup path and defaults stay centralised.
    /// (Called from a background task; blocking file IO must not run on the main actor.)
    nonisolated func load() -> AppSettings {
        SettingsStore.load()
    }

    /// Encodes and atomically persists `settings`. Throws so callers can surface failures.
    @discardableResult
    func save(_ settings: AppSettings) throws -> Bool {
        let data = try encoder.encode(settings)
        if data == lastSavedData { return false }
        try write(data)
        lastSavedData = data
        return true
    }

    /// Coalescing save for high-frequency callers (e.g. toggling a switch).
    /// A newer call replaces the pending one; the last settings always win.
    func scheduleSave(_ settings: AppSettings) {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            guard let self else { return }
            try await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            _ = try await self.save(settings)
        }
    }

    /// Waits for a scheduled save (used on termination).
    func flush() async {
        if let pendingSave {
            _ = try? await pendingSave.value
            self.pendingSave = nil
        }
    }

    private func write(_ data: Data) throws {
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
