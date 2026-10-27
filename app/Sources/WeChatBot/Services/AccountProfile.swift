import Foundation
import SQLite3

// MARK: - Layout

/// 账号数据目录布局。
///
/// ```
/// <root>/
/// ├── config.json                     # 全局设置
/// ├── account-state.json              # {"schemaVersion":1,"lastAccountID":…,"updatedAt":…}
/// ├── accounts/
/// │   ├── _unassigned/{chatbot.sqlite, profile.json, media/, logs/}
/// │   └── <id>/{chatbot.sqlite(+wal/shm), profile.json, media/, logs/, legacy-migration.json}
/// ├── media/                          # 旧版遗留媒体，只读保留
/// └── chatbot.sqlite                  # 旧版单库，迁移后保留
/// ```
///
/// `root` 可注入（单测用 temporaryDirectory）；生产默认 `AppPaths.supportDirectory`。
struct AccountLayout: Equatable, Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    var accountsDirectory: URL { root.appendingPathComponent("accounts", isDirectory: true) }
    var stateFile: URL { root.appendingPathComponent("account-state.json") }
    var legacyDatabaseFile: URL { root.appendingPathComponent("chatbot.sqlite") }
    var legacyMediaDirectory: URL { root.appendingPathComponent("media", isDirectory: true) }
    var legacyConfigFile: URL { root.appendingPathComponent("config.json") }

    func directory(for id: String) -> URL {
        accountsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    func databaseFile(for id: String) -> URL {
        directory(for: id).appendingPathComponent("chatbot.sqlite")
    }

    func profileFile(for id: String) -> URL {
        directory(for: id).appendingPathComponent("profile.json")
    }

    func mediaDirectory(for id: String) -> URL {
        directory(for: id).appendingPathComponent("media", isDirectory: true)
    }

    func logsDirectory(for id: String) -> URL {
        directory(for: id).appendingPathComponent("logs", isDirectory: true)
    }

    /// 旧版迁移标记（仅迁移目标账号有）。
    func legacyMigrationMarkerFile(for id: String) -> URL {
        directory(for: id).appendingPathComponent("legacy-migration.json")
    }

    /// 幂等创建账号目录（accounts/、账号目录、media/、logs/）。
    /// 非法 ID（含 `_unassigned` 以外的保留名/路径穿越）直接忽略；调用方负责先校验。
    func ensureDirectories(for id: String) {
        guard id == AppAccount.unassignedID || AppAccount.isValidID(id) else { return }
        let fileManager = FileManager.default
        for url in [
            accountsDirectory,
            directory(for: id),
            mediaDirectory(for: id),
            logsDirectory(for: id),
        ] {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - State & models

/// `account-state.json`。`updatedAt` 用 Unix epoch 秒（与契约示例一致）。
struct AccountState: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var lastAccountID: String = AppAccount.unassignedID
    var updatedAt: TimeInterval = 0
    /// 旧版单库是否已经真正迁移完成。`false` 时即使 state 存在，
    /// 下次启动仍会重试迁移；只有迁移/无旧库初始化成功后才置 `true`。
    /// 默认 `false` 以兼容早期不带该键的 state 文件。
    var legacyMigrationDone: Bool = false

    init(
        schemaVersion: Int = 1,
        lastAccountID: String = AppAccount.unassignedID,
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        legacyMigrationDone: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.lastAccountID = lastAccountID
        self.updatedAt = updatedAt
        self.legacyMigrationDone = legacyMigrationDone
    }
}

// 容忍旧版/半写入/手改的 state：缺键或类型不对时回退默认值，不整份丢弃。
extension AccountState {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, lastAccountID, updatedAt, legacyMigrationDone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AccountState()
        schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion))
            ?? defaults.schemaVersion
        lastAccountID = (try? container.decodeIfPresent(String.self, forKey: .lastAccountID))
            ?? defaults.lastAccountID
        updatedAt = (try? container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt))
            ?? defaults.updatedAt
        legacyMigrationDone = (try? container.decodeIfPresent(Bool.self, forKey: .legacyMigrationDone))
            ?? defaults.legacyMigrationDone
    }
}

/// 设置页「已保存的账号」一行。
struct SavedWeChatAccount: Identifiable, Equatable, Sendable {
    var id: String
    var maskedID: String
    var directory: URL
    var lastUsedAt: Date?
    var isActive: Bool
}

/// 旧版迁移结果。`notice` 非 nil 时应展示给用户（中文说明）。
struct LegacyMigrationOutcome: Equatable, Sendable {
    var activeAccountID: String
    var didMigrate: Bool
    var legacyOwnerAccountID: String?
    var notice: String?
}

/// 启动时把 `_unassigned` 临时档案归入已识别账号的结果。
struct UnassignedClaimOutcome: Equatable, Sendable {
    var didClaim: Bool
    var activeAccountID: String
    var notice: String?
}

/// `AccountProfile` 可恢复错误（非法账号 ID、旧库迁移失败等）。
enum AccountProfileError: LocalizedError, Equatable {
    case invalidAccountID(String)
    case legacyDatabaseUnavailable(String)
    case legacyMigrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAccountID(let id):
            return "非法账号 ID：\(id)；账号目录名只能包含字母、数字、下划线与连字符。"
        case .legacyDatabaseUnavailable(let detail):
            return "无法读取旧版数据库：\(detail)"
        case .legacyMigrationFailed(let detail):
            return "旧版数据库复制失败：\(detail)"
        }
    }
}

// MARK: - AccountProfile

/// 当前微信账号档案的进程级静态状态。
///
/// - `preparePaths()` 在启动早期同步调用：只做 stat / JSON 读取，**不打开 SQLite**。
/// - `runLegacyMigrationIfNeeded()` 会读旧库并复制文件，是阻塞 IO，调用方必须放后台线程。
/// - 所有静态状态的读写都由 `NSLock` 保护；`preparePaths` 可重复调用。
/// - 文件写入一律原子（`Data.write(options: .atomic)` / 临时文件 + move）。
/// - 迁移只 copy，绝不 `removeItem` 任何用户数据（临时文件除外）。
enum AccountProfile {
    // MARK: Static state (lock-protected)

    private static let stateLock = NSLock()
    /// 迁移是阻塞 IO 且只应执行一次；与 AppStore 的后台 bootstrapping 串行化。
    private static let migrationLock = NSLock()

    private static var _layout = AccountLayout(root: AppPaths.supportDirectory)
    private static var _activeID = AppAccount.unassignedID
    private static var _pendingNotice: String?
    /// 生产为 nil（使用真实微信容器）；单测注入临时 `documentsRoot`。
    private static var _resolver: WeChatAccountResolver?

    // MARK: Paths

    static var layout: AccountLayout {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _layout
    }

    static var activeID: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _activeID
    }

    static var isUnassigned: Bool { activeID == AppAccount.unassignedID }

    static var maskedActiveID: String { AppAccount.maskedID(activeID) }

    static var pendingNotice: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _pendingNotice
    }

    static var activeDirectory: URL {
        let snapshot = currentState()
        return snapshot.layout.directory(for: snapshot.activeID)
    }

    static var databaseFile: URL {
        let snapshot = currentState()
        return snapshot.layout.databaseFile(for: snapshot.activeID)
    }

    static var profileFile: URL {
        let snapshot = currentState()
        return snapshot.layout.profileFile(for: snapshot.activeID)
    }

    static var mediaDirectory: URL {
        let snapshot = currentState()
        return snapshot.layout.mediaDirectory(for: snapshot.activeID)
    }

    static var logsDirectory: URL {
        let snapshot = currentState()
        return snapshot.layout.logsDirectory(for: snapshot.activeID)
    }

    // MARK: Detection

    /// 启动早期同步调用：依据 resolver + account-state.json 决定 provisional activeID。
    ///
    /// 只 stat 微信容器与读取 `account-state.json`（JSON），不打开任何 SQLite；
    /// 缺少 state 时保持 `_unassigned`，等 `runLegacyMigrationIfNeeded()` 在后台做旧库归位。
    /// 若检测到的账号与 state 记录不同，设置 `pendingNotice`（供总览页提示「微信账号已切换」）。
    static func preparePaths() {
        let snapshot = currentState()
        let resolution = snapshot.resolver.resolve()
        let storedState = readState(at: snapshot.layout.stateFile)
        let storedID = storedState.flatMap { validStoredID($0.lastAccountID) }
        let detectedID = resolution?.accountID
        let unassignedHasData = hasUnassignedData(layout: snapshot.layout)

        // state 还停在 `_unassigned` 且临时档案里已有数据：不能直接改 active，
        // 否则 bootstrap 的旧库迁移会因 state 存在而早退，`_unassigned` 永远不会被认领。
        // 这里保持 active = _unassigned，等 performBootstrap 在开库前 claim 后再切到 detected。
        let shouldClaimUnassigned = storedID == AppAccount.unassignedID
            && detectedID != nil
            && unassignedHasData
        let provisional = shouldClaimUnassigned
            ? AppAccount.unassignedID
            : (detectedID ?? storedID ?? AppAccount.unassignedID)

        var notice: String?
        if let detectedID, let storedID, detectedID != storedID {
            if shouldClaimUnassigned {
                notice = "已识别微信账号 \(AppAccount.maskedID(detectedID))，"
                    + "正在把未识别账号的临时数据归入该账号。"
            } else {
                notice = "检测到微信账号已切换：\(AppAccount.maskedID(detectedID))"
                // 检测到的账号与 state 不同时把新账号原子写回 state（只写 JSON，不碰 SQLite）：
                // 这样下次启动即使微信已退出/检测失败，也会继续使用同一个账号档案，
                // 不会回退到旧账号，也不会每次启动重复提示切号。
                // `legacyMigrationDone` 必须沿用旧值：activate/切号不能替迁移“盖章”。
                try? persistState(
                    detectedID,
                    layout: snapshot.layout,
                    legacyMigrationDone: storedState?.legacyMigrationDone
                )
            }
        }

        stateLock.lock()
        _activeID = provisional
        _pendingNotice = notice
        stateLock.unlock()

        snapshot.layout.ensureDirectories(for: provisional)
    }

    /// 当前微信客户端最近登录账号（resolver 结果），供切号前检测。
    static func detectedAccountID() -> String? {
        currentState().resolver.resolve()?.accountID
    }

    /// 当前账号对应的微信图片临时目录（无则 nil）。
    static func activeImageDirectory() -> URL? {
        let snapshot = currentState()
        return snapshot.resolver.imageDirectory(forAccountID: snapshot.activeID)
    }

    // MARK: Activation

    /// 校验 id、建目录、原子写 `account-state.json` 并切换 active。
    ///
    /// `_unassigned` 仅允许内部显式回退使用；UI/微信账号应传真实 wxid。
    static func activate(_ id: String) throws {
        guard id == AppAccount.unassignedID || AppAccount.isValidID(id) else {
            throw AccountProfileError.invalidAccountID(id)
        }
        let snapshot = currentState()
        snapshot.layout.ensureDirectories(for: id)
        // 只切换 active；旧版迁移是否完成由 state 里的 legacyMigrationDone 决定，
        // 不能因为一次切号/回滚就跳过尚未完成的旧库迁移。
        try persistState(id, layout: snapshot.layout)
        updateActive(id)
    }

    // MARK: Legacy claim

    /// active 仍为 `_unassigned` 且目标账号目录没有库时，把 `_unassigned/` 内容
    /// 归入 `accounts/<id>/`（DB + profile + media），不删除源；返回是否复制了内容。
    ///
    /// 调用方必须先 suspend/关闭数据库（SQLite 文件可能在 WAL 中）。
    @discardableResult
    static func claimUnassigned(by id: String) throws -> Bool {
        guard id != AppAccount.unassignedID, AppAccount.isValidID(id) else {
            throw AccountProfileError.invalidAccountID(id)
        }
        let snapshot = currentState()
        guard snapshot.activeID == AppAccount.unassignedID else { return false }
        return try claimContents(from: AppAccount.unassignedID, to: id, layout: snapshot.layout)
    }

    /// 启动阶段认领：不要求 active 仍为 `_unassigned`（preparePaths 可能已按 resolver
    /// 选了别的 provisional），但只在目标账号库不存在时复制，绝不覆盖已有账号数据。
    ///
    /// 调用方必须在 `MemoryStore.open()` 之前、数据库仍处于 suspend/closed 时调用。
    static func claimUnassignedForStartup(detectedAccountID: String?) -> UnassignedClaimOutcome {
        let snapshot = currentState()
        let layout = snapshot.layout
        guard hasUnassignedData(layout: layout) else {
            return UnassignedClaimOutcome(
                didClaim: false,
                activeAccountID: snapshot.activeID,
                notice: nil
            )
        }

        let targetID: String
        if snapshot.activeID != AppAccount.unassignedID {
            targetID = snapshot.activeID
        } else if let detected = detectedAccountID,
                  detected != AppAccount.unassignedID,
                  AppAccount.isValidID(detected) {
            targetID = detected
        } else {
            return UnassignedClaimOutcome(
                didClaim: false,
                activeAccountID: snapshot.activeID,
                notice: nil
            )
        }

        do {
            let claimed = try claimContents(from: AppAccount.unassignedID, to: targetID, layout: layout)
            if snapshot.activeID == AppAccount.unassignedID {
                try activate(targetID)
            }
            let masked = AppAccount.maskedID(targetID)
            return UnassignedClaimOutcome(
                didClaim: claimed,
                activeAccountID: targetID,
                notice: claimed
                    ? "已把未识别账号的临时数据归入微信账号 \(masked)。原临时目录已保留。"
                    : "未识别账号的临时数据已在微信账号 \(masked) 中，已切换到该账号。"
            )
        } catch {
            return UnassignedClaimOutcome(
                didClaim: false,
                activeAccountID: snapshot.activeID,
                notice: "未识别账号的临时数据认领失败：\(error.localizedDescription)。数据已保留，下次启动会重试。"
            )
        }
    }

    /// 递归 copy `source` 下的条目：目标已存在则跳过（目录则合并），源一律保留。
    private static func copyContents(of source: URL, into destination: URL) throws -> Bool {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var copied = false
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    copied = try copyContents(of: entry, into: target) || copied
                }
                continue
            }
            try fileManager.copyItem(at: entry, to: target)
            copied = true
        }
        return copied
    }

    /// 把 `_unassigned` 的完整内容先复制到 staging 目录，再逐项 move 到目标账号目录；
    /// 数据库进程已 suspend 时源文件是稳定的。中断时源目录完整保留，下次重试；
    /// 目标已有数据库时拒绝覆盖（最后防线）。
    private static func claimContents(from sourceID: String, to targetID: String, layout: AccountLayout) throws -> Bool {
        let fileManager = FileManager.default
        let source = layout.directory(for: sourceID)
        guard fileManager.fileExists(atPath: source.path) else { return false }

        let destination = layout.directory(for: targetID)
        let destinationDatabase = layout.databaseFile(for: targetID)
        let destinationHasDatabase = fileManager.fileExists(atPath: destinationDatabase.path)
        let sourceHasDatabase = fileManager.fileExists(atPath: layout.databaseFile(for: sourceID).path)
        if destinationHasDatabase {
            // 目标已有完整库：不覆盖。只有目标库是“空库”（之前中断留下的壳）时才继续，
            // 交给 mergeStaged 用 staging 里的库替换。
            if !databaseIsEffectivelyEmpty(destinationDatabase) { return false }
        }
        guard sourceHasDatabase || fileManager.fileExists(atPath: layout.profileFile(for: sourceID).path) else {
            return false
        }

        layout.ensureDirectories(for: targetID)
        let staging = layout.accountsDirectory.appendingPathComponent(
            ".\(targetID).claiming-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        _ = try copyContents(of: source, into: staging)
        let copied = try mergeStagedContents(of: staging, into: destination)

        if copied {
            let marker: [String: Any] = [
                "schemaVersion": 1,
                "claimedAt": Date().timeIntervalSince1970,
                "source": sourceID,
                "target": targetID,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: marker,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(
                    to: destination.appendingPathComponent("unassigned-claim.json"),
                    options: .atomic
                )
            }
        }
        return copied
    }

    /// 把 staging 中条目移到目标：目录合并、文件已存在则跳过（保留目标），
    /// 唯一例外是目标 `chatbot.sqlite` 为空壳时用 staging 的完整库替换。
    @discardableResult
    private static func mergeStagedContents(of staging: URL, into destination: URL) throws -> Bool {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var copied = false
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if fileManager.fileExists(atPath: target.path) {
                if isDirectory {
                    copied = try mergeStagedContents(of: entry, into: target) || copied
                    continue
                }
                if entry.lastPathComponent == "chatbot.sqlite",
                   databaseIsEffectivelyEmpty(target) {
                    // 空壳库可能残留 -wal/-shm；替换主库前清掉，避免旧 WAL 套到新库上。
                    try? fileManager.removeItem(atPath: target.path + "-wal")
                    try? fileManager.removeItem(atPath: target.path + "-shm")
                    _ = try fileManager.replaceItemAt(target, withItemAt: entry)
                    copied = true
                }
                continue
            }
            try fileManager.moveItem(at: entry, to: target)
            copied = true
        }
        return copied
    }

    /// `_unassigned/` 是否已有可认领的数据（库或 profile）。
    private static func hasUnassignedData(layout: AccountLayout) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: layout.databaseFile(for: AppAccount.unassignedID).path)
            || fileManager.fileExists(atPath: layout.profileFile(for: AppAccount.unassignedID).path)
    }

    /// 目标库是否“实际为空”：只含 schema、没有会话/消息。只读打开，失败按非空处理。
    private static func databaseIsEffectivelyEmpty(_ databaseURL: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return false
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 500)
        // 会话/消息/记忆/设置任一有内容都视为“已有数据”，绝不覆盖。
        // 只看业务表不看 logs：旧版提前开库时可能先写了日志，仍应允许用旧库快照替换。
        for table in ["conversations", "messages", "memories", "settings"] {
            var statement: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM \(table) LIMIT 1;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            if sqlite3_column_int64(statement, 0) > 0 { return false }
        }
        return true
    }

    // MARK: Legacy migration

    /// 旧版单库/单配置一次性归位。
    ///
    /// **阻塞 IO**：调用方必须在后台线程执行（AppStore 用 `Task.detached`）。
    /// - 幂等：`account-state.json` 已存在（且可用）时直接返回当前 active，不碰任何文件。
    /// - 无旧库：若存在旧 `config.json`（顶层含 `bot/personas/schedules`）且当前 active
    ///   不是 `_unassigned`、目标 `profile.json` 不存在，则只种子化 profile（“只剩配置”升级）；
    ///   最后写 state，`didMigrate` 表示是否有内容被恢复。
    /// - 有旧库：owner = 旧库只读 `select value from settings where key='onebot.self_id'`；
    ///   旧库用 SQLite Backup API 复制到 `valid(owner) ? owner : 当前 active`；
    ///   目标 profile 缺失时从旧 `config.json` 顶层 `bot/personas/schedules` 种子化；
    ///   写 `legacy-migration.json`。
    /// - finalActive：当前 active 非 unassigned → 保持；否则 owner 有效 → owner；否则 target。
    /// - 旧文件（DB/WAL/SHM/config/media）一律保留，只 copy 不移动、不删除。
    static func runLegacyMigrationIfNeeded() -> LegacyMigrationOutcome {
        migrationLock.lock()
        defer { migrationLock.unlock() }

        let snapshot = currentState()
        let layout = snapshot.layout

        // 已完成过迁移（state 可用且 legacyMigrationDone=true）：直接返回当前 active。
        // 注意：activate/切号写的 state 默认不会把 legacyMigrationDone 置 true，
        // 因此“迁移失败后同一会话切过号”不会让下次启动永久跳过迁移。
        if let state = readState(at: layout.stateFile),
           validStoredID(state.lastAccountID) != nil,
           state.legacyMigrationDone {
            return LegacyMigrationOutcome(
                activeAccountID: snapshot.activeID,
                didMigrate: false,
                legacyOwnerAccountID: nil,
                notice: nil
            )
        }

        let legacyDatabase = layout.legacyDatabaseFile
        guard FileManager.default.fileExists(atPath: legacyDatabase.path) else {
            // root 可能还不存在（首次启动/直接调用）：先确保目录再写 state。
            layout.ensureDirectories(for: snapshot.activeID)
            // “只剩配置”的升级：旧库不存在时也能从旧 config.json 恢复账号级设置。
            let seededProfile = snapshot.activeID != AppAccount.unassignedID
                && seedProfileFromLegacyConfig(layout: layout, targetID: snapshot.activeID)
            // 没有旧库也要落 state，让下次启动知道已经初始化过（避免每次探测）。
            try? persistState(snapshot.activeID, layout: layout, legacyMigrationDone: true)
            return LegacyMigrationOutcome(
                activeAccountID: snapshot.activeID,
                didMigrate: seededProfile,
                legacyOwnerAccountID: nil,
                notice: seededProfile
                    ? "已从旧版配置恢复当前微信账号的机器人设置。原配置文件已保留。"
                    : nil
            )
        }

        let owner = readLegacyOwner(from: legacyDatabase).flatMap { raw in
            AppAccount.isValidID(raw) ? raw : nil
        }
        let targetID = owner ?? snapshot.activeID

        do {
            layout.ensureDirectories(for: targetID)
            let targetDatabase = layout.databaseFile(for: targetID)
            let markerExists = FileManager.default.fileExists(
                atPath: layout.legacyMigrationMarkerFile(for: targetID).path
            )
            // 目标库存在但迁移 marker 不存在且库实际为空（例如旧版提前开库/中断留下
            // 的壳）：允许用旧库快照替换；非空目标库绝不覆盖。
            let allowReplaceEmpty = FileManager.default.fileExists(atPath: targetDatabase.path)
                && !markerExists
                && databaseIsEffectivelyEmpty(targetDatabase)
            let copiedDatabase = try copyLegacyDatabase(
                from: legacyDatabase,
                to: targetDatabase,
                allowReplaceEmpty: allowReplaceEmpty
            )
            let seededProfile = seedProfileFromLegacyConfig(layout: layout, targetID: targetID)
            writeLegacyMigrationMarker(
                layout: layout,
                targetID: targetID,
                owner: owner,
                legacyDatabase: legacyDatabase,
                copiedDatabase: copiedDatabase,
                seededProfile: seededProfile
            )

            let finalActive = snapshot.activeID != AppAccount.unassignedID
                ? snapshot.activeID
                : (owner ?? targetID)
            do {
                try persistState(finalActive, layout: layout, legacyMigrationDone: true)
            } catch {
                // 数据已复制成功，只是状态没写下去；下次启动会重试（目标库已存在则跳过复制）。
                return LegacyMigrationOutcome(
                    activeAccountID: snapshot.activeID,
                    didMigrate: true,
                    legacyOwnerAccountID: owner,
                    notice: "旧版数据已迁移，但写入账号状态失败：\(error.localizedDescription)。下次启动会自动重试。"
                )
            }
            updateActive(finalActive)
            return LegacyMigrationOutcome(
                activeAccountID: finalActive,
                didMigrate: true,
                legacyOwnerAccountID: owner,
                notice: migrationNotice(owner: owner, finalActive: finalActive)
            )
        } catch {
            // 保持当前 active / 不写 state，下次启动自动重试；旧文件全部保留。
            return LegacyMigrationOutcome(
                activeAccountID: snapshot.activeID,
                didMigrate: false,
                legacyOwnerAccountID: owner,
                notice: "旧版数据迁移失败：\(error.localizedDescription)。旧数据已保留，下次启动会自动重试。"
            )
        }
    }

    /// 只读打开旧库读取 `settings.onebot.self_id`（微信账号 owner）。失败/空值 → nil。
    private static func readLegacyOwner(from databaseURL: URL) -> String? {
        var handle: OpaquePointer?
        // 旧库是 WAL 模式；旧 App 干净退出后可能只剩主库、没有 -wal/-shm。
        // 此时 READONLY 连接无法初始化 WAL，prepare 会返回 CANTOPEN；
        // 用 READWRITE 打开允许 SQLite 恢复/创建 WAL 辅助文件（仍只读查询/备份）。
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return nil
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 2_000)

        var statement: OpaquePointer?
        let sql = "SELECT value FROM settings WHERE key = 'onebot.self_id' LIMIT 1;"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 用 SQLite Backup API 把旧库复制到目标路径（不复制 `-wal` / `-shm`）。
    ///
    /// - 目标主库已存在 → 视为迁移过，直接返回 false（绝不覆盖已有数据）。
    /// - 只读打开旧库，即使旧 App 实例还持有着库/WAL，Backup API 也会在页级锁下
    ///   得到一致快照，不需要裸 copy WAL/SHM（裸 copy 在并发写时可能得到不一致的库）。
    /// - 先写到目标目录里的临时文件，成功后再 move 到位，避免中途失败留下半个库。
    private static func copyLegacyDatabase(
        from source: URL,
        to destination: URL,
        allowReplaceEmpty: Bool = false
    ) throws -> Bool {
        let fileManager = FileManager.default
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        if destinationExists, !allowReplaceEmpty { return false }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let staged = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).migrating-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: staged) }

        var sourceHandle: OpaquePointer?
        // 同 readLegacyOwner：WAL 主库没有 -wal/-shm 时 READONLY 会 CANTOPEN；
        // READWRITE + Backup API 仍能拿到一致快照，且不会改写业务数据。
        guard sqlite3_open_v2(source.path, &sourceHandle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let sourceHandle else {
            let message = sourceHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开"
            if let sourceHandle { sqlite3_close_v2(sourceHandle) }
            throw AccountProfileError.legacyDatabaseUnavailable(message)
        }
        defer { sqlite3_close_v2(sourceHandle) }
        sqlite3_busy_timeout(sourceHandle, 2_000)

        var destinationHandle: OpaquePointer?
        guard sqlite3_open_v2(
            staged.path,
            &destinationHandle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let destinationHandle else {
            let message = destinationHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法创建目标库"
            if let destinationHandle { sqlite3_close_v2(destinationHandle) }
            throw AccountProfileError.legacyMigrationFailed(message)
        }

        let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main")
        guard let backup else {
            let message = String(cString: sqlite3_errmsg(destinationHandle))
            sqlite3_close_v2(destinationHandle)
            throw AccountProfileError.legacyMigrationFailed(message)
        }

        var stepResult = sqlite3_backup_step(backup, -1)
        var retries = 0
        while (stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED) && retries < 10 {
            sqlite3_sleep(50)
            stepResult = sqlite3_backup_step(backup, -1)
            retries += 1
        }
        let finishResult = sqlite3_backup_finish(backup)
        let destinationMessage = String(cString: sqlite3_errmsg(destinationHandle))
        sqlite3_close_v2(destinationHandle)

        guard (stepResult == SQLITE_DONE || stepResult == SQLITE_OK), finishResult == SQLITE_OK else {
            throw AccountProfileError.legacyMigrationFailed(destinationMessage)
        }
        if destinationExists {
            // 空壳库可能残留 -wal/-shm；替换主库前清掉。
            try? fileManager.removeItem(atPath: destination.path + "-wal")
            try? fileManager.removeItem(atPath: destination.path + "-shm")
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
        return true
    }

    /// 从旧 `config.json` 顶层抽 `bot/personas/schedules` 作为目标 `profile.json` 种子。
    /// 三项都缺/类型不符时不写（保留 SettingsStore 的 `.default` 行为）；返回是否写入。
    private static func seedProfileFromLegacyConfig(layout: AccountLayout, targetID: String) -> Bool {
        let fileManager = FileManager.default
        let profileURL = layout.profileFile(for: targetID)
        guard !fileManager.fileExists(atPath: profileURL.path),
              let data = try? Data(contentsOf: layout.legacyConfigFile),
              let object = try? JSONSerialization.jsonObject(with: data),
              let config = object as? [String: Any],
              let bot = config["bot"] as? [String: Any],
              let personas = config["personas"] as? [Any],
              let schedules = config["schedules"] as? [Any] else { return false }

        let profile: [String: Any] = [
            "schemaVersion": 1,
            "bot": bot,
            "personas": personas,
            "schedules": schedules,
        ]
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: profile,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try fileManager.createDirectory(
                at: layout.directory(for: targetID),
                withIntermediateDirectories: true
            )
            try encoded.write(to: profileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func writeLegacyMigrationMarker(
        layout: AccountLayout,
        targetID: String,
        owner: String?,
        legacyDatabase: URL,
        copiedDatabase: Bool,
        seededProfile: Bool
    ) {
        var marker: [String: Any] = [
            "schemaVersion": 1,
            "migratedAt": Date().timeIntervalSince1970,
            "targetAccountID": targetID,
            "legacyDatabasePath": legacyDatabase.path,
            "copiedDatabase": copiedDatabase,
            "seededProfile": seededProfile,
        ]
        if let owner {
            marker["legacyOwnerAccountID"] = owner
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: marker,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: layout.legacyMigrationMarkerFile(for: targetID), options: .atomic)
    }

    private static func migrationNotice(owner: String?, finalActive: String) -> String? {
        if let owner {
            if finalActive != owner {
                return "旧版数据已归入微信账号 \(AppAccount.maskedID(owner))；"
                    + "当前微信账号为 \(AppAccount.maskedID(finalActive))。原数据文件已保留。"
            }
            return "旧版数据已归入微信账号 \(AppAccount.maskedID(owner))。原数据文件已保留。"
        }
        if finalActive == AppAccount.unassignedID {
            return "暂未识别微信账号，旧版数据已暂存到未识别账号；登录微信后会自动认领，原数据文件已保留。"
        }
        return "旧版数据已归入当前微信账号 \(AppAccount.maskedID(finalActive))。原数据文件已保留。"
    }

    // MARK: Saved accounts

    /// `accounts/` 下已有真实账号（不含 `_unassigned`），按最近使用时间倒序。
    ///
    /// “最近使用”取账号库 / profile / 目录 mtime 的最新值；当前账号若 state 有
    /// `updatedAt` 则优先用 state 时间。返回最多 `limit` 条。
    static func savedAccounts(limit: Int = 10) -> [SavedWeChatAccount] {
        guard limit > 0 else { return [] }
        let snapshot = currentState()
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: snapshot.layout.accountsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let state = readState(at: snapshot.layout.stateFile)
        let stateDate: Date? = {
            guard let updatedAt = state?.updatedAt, updatedAt > 0 else { return nil }
            return Date(timeIntervalSince1970: updatedAt)
        }()

        var accounts: [SavedWeChatAccount] = []
        for entry in entries {
            let id = entry.lastPathComponent
            guard id != AppAccount.unassignedID, AppAccount.isValidID(id) else { continue }
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }

            let directory = snapshot.layout.directory(for: id)
            let activity = modificationDate(snapshot.layout.databaseFile(for: id))
                ?? modificationDate(snapshot.layout.profileFile(for: id))
                ?? modificationDate(directory)
            let isActive = id == snapshot.activeID
            accounts.append(
                SavedWeChatAccount(
                    id: id,
                    maskedID: AppAccount.maskedID(id),
                    directory: directory,
                    lastUsedAt: isActive ? (stateDate ?? activity) : activity,
                    isActive: isActive
                )
            )
        }

        accounts.sort { lhs, rhs in
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case let (left?, right?):
                if left != right { return left > right }
                return lhs.id < rhs.id
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.id < rhs.id
            }
        }
        return Array(accounts.prefix(limit))
    }

    // MARK: Testing hooks

    /// 仅供单测：替换静态 layout / 微信容器根目录，并重置 active 与 notice。
    /// 生产代码不要调用。
    static func configureForTesting(layout: AccountLayout, resolver: WeChatAccountResolver? = nil) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _layout = layout
        _resolver = resolver
        _activeID = AppAccount.unassignedID
        _pendingNotice = nil
    }

    /// 仅供单测：恢复到生产默认 layout / 真实微信容器。
    static func resetForTesting() {
        configureForTesting(layout: AccountLayout(root: AppPaths.supportDirectory), resolver: nil)
    }

    // MARK: Private helpers

    private static func currentState() -> (
        layout: AccountLayout,
        activeID: String,
        resolver: WeChatAccountResolver
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (_layout, _activeID, _resolver ?? WeChatAccountResolver())
    }

    private static func updateActive(_ id: String) {
        stateLock.lock()
        _activeID = id
        stateLock.unlock()
    }

    /// `_unassigned` 视为可用（表示“尚未识别”）；非法字符返回 nil。
    private static func validStoredID(_ raw: String) -> String? {
        if raw == AppAccount.unassignedID { return raw }
        return AppAccount.isValidID(raw) ? raw : nil
    }

    private static func readState(at url: URL) -> AccountState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AccountState.self, from: data)
    }

    /// 原子写 `account-state.json`（不更新内存中的 active）。
    /// `legacyMigrationDone` 省略时沿用现有 state 的值；没有 state 时按“是否存在旧库”推断，
    /// 避免 activate/切号把尚未完成的迁移误标成已完成。
    private static func persistState(
        _ id: String,
        layout: AccountLayout,
        legacyMigrationDone: Bool? = nil
    ) throws {
        let existing = readState(at: layout.stateFile)
        let done = legacyMigrationDone
            ?? existing?.legacyMigrationDone
            ?? !FileManager.default.fileExists(atPath: layout.legacyDatabaseFile.path)
        let state = AccountState(
            schemaVersion: 1,
            lastAccountID: id,
            updatedAt: Date().timeIntervalSince1970,
            legacyMigrationDone: done
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: layout.stateFile, options: .atomic)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
