import Foundation
import SQLite3

// MARK: - Errors

enum CharacterStoreError: LocalizedError {
    case notActive
    case characterNotFound(String)
    case openFailed(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .notActive:
            return "记忆卡存储尚未就绪"
        case .characterNotFound(let id):
            return "未找到会话 \(id) 的记忆卡"
        case .openFailed(let message):
            return "记忆卡打开失败：\(message)"
        case .sqlite(let message):
            return "记忆卡数据库错误：\(message)"
        }
    }
}

private let characterSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Character database

/// 单个角色目录里的 `memory.sqlite`。只在 `CharacterStore` actor 内使用。
private final class CharacterDatabase {
    let directory: URL
    let url: URL
    private(set) var handle: OpaquePointer?

    init(directory: URL) throws {
        self.directory = directory
        self.url = directory.appendingPathComponent("memory.sqlite")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &pointer, flags, nil)
        guard status == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 code \(status)"
            if let pointer { sqlite3_close_v2(pointer) }
            throw CharacterStoreError.openFailed(message)
        }
        handle = pointer
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("PRAGMA busy_timeout=3000;")
            try execute("PRAGMA foreign_keys=ON;")
            try migrate()
        } catch {
            sqlite3_close_v2(pointer)
            handle = nil
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    // MARK: Schema

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memories (
            id                 TEXT PRIMARY KEY NOT NULL,
            category           TEXT NOT NULL,
            kind               TEXT NOT NULL,
            content            TEXT NOT NULL,
            compressed_content TEXT,
            keywords           TEXT NOT NULL DEFAULT '',
            importance         REAL NOT NULL DEFAULT 3.0,
            pinned             INTEGER NOT NULL DEFAULT 0,
            archived           INTEGER NOT NULL DEFAULT 0,
            superseded_by      TEXT,
            supersedes         TEXT,
            superseded_at      REAL,
            source             TEXT NOT NULL DEFAULT 'extraction',
            source_message_ids TEXT NOT NULL DEFAULT '',
            merge_count        INTEGER NOT NULL DEFAULT 0,
            access_count       INTEGER NOT NULL DEFAULT 0,
            created_at         REAL NOT NULL,
            updated_at         REAL NOT NULL,
            last_accessed_at   REAL
        );
        CREATE INDEX IF NOT EXISTS idx_character_memories_recall
            ON memories (archived, superseded_by, kind, category, updated_at DESC);

        CREATE TABLE IF NOT EXISTS interactions (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id  TEXT NOT NULL UNIQUE,
            direction   TEXT NOT NULL,
            sender_id   TEXT NOT NULL DEFAULT '',
            sender_name TEXT NOT NULL DEFAULT '',
            content     TEXT NOT NULL,
            timestamp   REAL NOT NULL,
            created_at  REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_character_interactions_time
            ON interactions (timestamp DESC, id DESC);
        """)
        if try userVersion() < 1 {
            try setUserVersion(1)
        }
        try migrateLegacyOriginMemories()
    }

    /// 2026-10-28 移除「起点记忆」：生成型起点直接删除；用户编辑过的起点
    /// 转成普通置顶记忆，避免丢失手写内容。
    private func migrateLegacyOriginMemories() throws {
        let edited = (try? meta("origin_edited")) == "1"
        if edited {
            try execute("""
            UPDATE memories
            SET kind = 'normal',
                pinned = 1,
                importance = MAX(importance, 10),
                source = 'manual'
            WHERE kind = 'origin';
            """)
        } else {
            try execute("DELETE FROM memories WHERE kind = 'origin';")
        }
        try execute("DELETE FROM meta WHERE key = 'origin_edited';")
    }

    // MARK: Statement helpers

    func execute(_ sql: String) throws {
        guard let handle else { throw CharacterStoreError.notActive }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if status != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "sqlite3_exec code \(status)"
            if let errorPointer { sqlite3_free(errorPointer) }
            throw CharacterStoreError.sqlite(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw CharacterStoreError.notActive }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw CharacterStoreError.sqlite(
                "prepare 失败（\(status)）：\(String(cString: sqlite3_errmsg(handle)))")
        }
        return statement
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version=\(version);")
    }

    func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) throws {
        let status: Int32
        if let value {
            status = sqlite3_bind_text(statement, index, value, -1, characterSQLiteTransient)
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else {
            throw CharacterStoreError.sqlite("绑定文本失败（\(status)）")
        }
    }

    func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw CharacterStoreError.sqlite("绑定整数失败")
        }
    }

    func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int32) throws {
        guard sqlite3_bind_int(statement, index, value) == SQLITE_OK else {
            throw CharacterStoreError.sqlite("绑定整数失败")
        }
    }

    func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) throws {
        let status: Int32
        if let value {
            status = sqlite3_bind_double(statement, index, value)
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else {
            throw CharacterStoreError.sqlite("绑定数值失败（\(status)）")
        }
    }

    func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int32?) throws {
        let status: Int32
        if let value {
            status = sqlite3_bind_int(statement, index, value)
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else {
            throw CharacterStoreError.sqlite("绑定可空整数失败（\(status)）")
        }
    }

    func stepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw CharacterStoreError.sqlite("执行失败（\(status)）")
        }
    }

    func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    func int(_ statement: OpaquePointer, _ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }

    func double(_ statement: OpaquePointer, _ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func optionalDouble(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    func date(_ statement: OpaquePointer, _ column: Int32) -> Date {
        Date(timeIntervalSince1970: double(statement, column))
    }

    func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard let value = optionalDouble(statement, column) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    // MARK: Meta

    func meta(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    func setMeta(_ key: String, _ value: String) throws {
        let statement = try prepare("""
        INSERT INTO meta (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, key)
        try bind(statement, 2, value)
        try stepDone(statement)
    }

    func metaDate(_ key: String) throws -> Date? {
        guard let raw = try meta(key), let value = Double(raw), value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    func setMetaDate(_ key: String, _ date: Date) throws {
        try setMeta(key, String(format: "%.3f", date.timeIntervalSince1970))
    }
}

// MARK: - CharacterStore

/// 记忆 v2 的角色目录存储。
///
/// ```
/// accounts/<id>/characters/<conversation-key>/
/// └── memory.sqlite          # 每会话记忆卡；人格统一来自「人格设定」
/// ```
///
/// - 所有文件/DB 操作在本 actor 内串行，不占主线程；
/// - 每个角色目录一个 SQLite，按需打开，LRU 最多缓存 4 个连接；
/// - 账号切换时 `suspend()` 关闭全部连接，`activate()` 指向新账号目录。
actor CharacterStore {
    static let shared = CharacterStore()

    /// 全局共享记忆的固定角色 ID；对应目录 `characters/c-__global__/memory.sqlite`。
    static let globalConversationID = "__global__"
    static let globalTitle = "全局共享"

    private var root: URL?
    private var connections: [String: CharacterDatabase] = [:]
    private var accessOrder: [String] = []
    private var suspended = true
    private let maxConnections = 4

    init() {}

    /// 测试用：直接以某个目录作为角色根目录。
    init(rootDirectory: URL) {
        self.root = rootDirectory
        self.suspended = false
        try? FileManager.default.createDirectory(
            at: rootDirectory, withIntermediateDirectories: true)
    }

    // MARK: Lifecycle

    var activeRoot: URL? {
        root
    }

    /// 打开（或切到）当前账号的角色根目录。
    func activate(rootDirectory: URL? = nil) throws {
        let target = rootDirectory ?? AppPaths.charactersDirectory
        if !suspended, let root, root.standardizedFileURL == target.standardizedFileURL {
            return
        }
        closeAll()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        root = target
        suspended = false
    }

    /// 切号/退出前关闭全部连接；之后 `ensureOpen` 不再隐式打开。
    func suspend() {
        suspended = true
        closeAll()
    }

    private func closeAll() {
        for database in connections.values { database.close() }
        connections.removeAll()
        accessOrder.removeAll()
    }

    private func requireRoot() throws -> URL {
        guard !suspended, let root else { throw CharacterStoreError.notActive }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func directory(for conversationID: String, create: Bool) throws -> URL {
        let root = try requireRoot()
        let url = root.appendingPathComponent(
            CharacterDirectory.key(for: conversationID), isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private func database(
        for conversationID: String,
        createIfNeeded: Bool
    ) throws -> CharacterDatabase {
        let key = CharacterDirectory.key(for: conversationID)
        if let existing = connections[key] {
            touch(key)
            return existing
        }
        let dir = try directory(for: conversationID, create: createIfNeeded)
        let dbURL = dir.appendingPathComponent("memory.sqlite")
        if !createIfNeeded, !FileManager.default.fileExists(atPath: dbURL.path) {
            throw CharacterStoreError.characterNotFound(conversationID)
        }
        let databaseExisted = FileManager.default.fileExists(atPath: dbURL.path)
        let database = try CharacterDatabase(directory: dir)
        if !databaseExisted {
            // 新库默认不提取历史互动；ensureCharacter 首次建卡会把游标改到
            // 触发消息时间戳前 1ms，让本轮对话进入第一批提取。
            try database.setMetaDate("last_extracted_at", Date())
        }
        connections[key] = database
        touch(key)
        evictIfNeeded()
        return database
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictIfNeeded() {
        while connections.count > maxConnections, let victim = accessOrder.first {
            accessOrder.removeFirst()
            connections[victim]?.close()
            connections.removeValue(forKey: victim)
        }
    }

    private func close(conversationID: String) {
        let key = CharacterDirectory.key(for: conversationID)
        connections[key]?.close()
        connections.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }

    // MARK: Character

    /// 确保全局共享记忆卡存在；只建空记忆卡，不创建任何会话/互动。
    func ensureGlobalCharacter(now: Date = Date()) throws {
        let conversation = Conversation(
            id: Self.globalConversationID, kind: .direct, title: Self.globalTitle)
        try ensureCharacter(conversation: conversation, persona: nil, now: now)
    }

    func hasCharacter(conversationID: String) -> Bool {
        guard let root, !suspended else { return false }
        let database = root
            .appendingPathComponent(CharacterDirectory.key(for: conversationID), isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        return FileManager.default.fileExists(atPath: database.path)
    }

    /// 首次回复前调用：创建/更新记忆卡（人格只来自「人格设定」，不再写人设卡副本）。
    ///
    /// - Parameter activationTimestamp: 首次创建时的触发消息时间，用于初始化提取游标，
    ///   让本轮触发消息与其回复进入第一批提取、但不回挖历史聊天。
    func ensureCharacter(
        conversation: Conversation,
        persona: Persona?,
        activationTimestamp: Date? = nil,
        now: Date = Date()
    ) throws {
        let dir = try directory(for: conversation.id, create: true)
        removeLegacyPersonaCard(in: dir)
        let databaseURL = dir.appendingPathComponent("memory.sqlite")
        let databaseExisted = FileManager.default.fileExists(atPath: databaseURL.path)
        let database = try self.database(for: conversation.id, createIfNeeded: true)
        try database.setMeta("conversation_id", conversation.id)
        try database.setMeta("conversation_title", conversation.displayTitle)
        try database.setMeta("conversation_kind", conversation.kind.rawValue)
        try database.setMeta("schema_version", "1")
        let reference = PersonaReference(persona)
        if !reference.id.isEmpty {
            try database.setMeta("persona_id", reference.id)
        }
        if !reference.name.isEmpty {
            try database.setMeta("persona_name", reference.name)
        }
        if !databaseExisted {
            let activation = (activationTimestamp ?? now).timeIntervalSince1970 - 0.001
            try database.setMetaDate(
                "last_extracted_at", Date(timeIntervalSince1970: activation))
        }
    }

    /// 旧版本会在每个角色目录复制 `persona.md`；统一人格设定后它只是冗余副本，
    /// 首次创建/加载时移到废纸篓（可恢复），不删除记忆卡。
    private func removeLegacyPersonaCard(in directory: URL) {
        let legacy = directory.appendingPathComponent("persona.md")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.trashItem(at: legacy, resultingItemURL: nil)
    }

    // MARK: Character summaries

    /// 记忆页左栏：列出全部记忆卡与计数；人格名由运行时传入的「人格设定」映射解析。
    func listCharacters(
        settings: MemorySettings = .default,
        personas: [String: PersonaReference] = [:],
        now: Date = Date()
    ) throws -> [CharacterSummary] {
        let root = try requireRoot()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        var result: [CharacterSummary] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            guard isDirectory else { continue }
            let databaseURL = entry.appendingPathComponent("memory.sqlite")
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { continue }
            removeLegacyPersonaCard(in: entry)
            do {
                // 先读 meta 得到权威会话 ID；随后走连接缓存打开同一文件。
                let metaDatabase = try CharacterDatabase(directory: entry)
                let conversationID = try metaDatabase.meta("conversation_id") ?? ""
                let storedTitle = try metaDatabase.meta("conversation_title") ?? ""
                let storedKind = try metaDatabase.meta("conversation_kind")
                    .flatMap(ConversationKind.init(rawValue:)) ?? .direct
                let storedPersonaName = try metaDatabase.meta("persona_name") ?? ""
                metaDatabase.close()
                guard !conversationID.isEmpty else { continue }

                let database = try database(for: conversationID, createIfNeeded: true)
                let conversation = Conversation(
                    id: conversationID,
                    kind: storedKind,
                    title: storedTitle.isEmpty ? conversationID : storedTitle
                )
                let reference = personas[conversationID]
                let counts = try memoryCounts(
                    database: database, settings: settings, now: now)
                result.append(CharacterSummary(
                    conversationID: conversationID,
                    title: conversationID == Self.globalConversationID
                        ? Self.globalTitle
                        : conversation.displayTitle,
                    kind: storedKind,
                    personaName: reference?.name.isEmpty == false
                        ? (reference?.name ?? storedPersonaName)
                        : storedPersonaName,
                    isGlobal: conversationID == Self.globalConversationID,
                    memoryCount: counts.active,
                    importantCount: counts.important,
                    todoCount: counts.todo,
                    lastUpdated: counts.lastUpdated ?? now,
                    directoryPath: entry.path
                ))
            } catch {
                // 单个角色损坏不阻塞整页；跳过并继续。
                continue
            }
        }
        return result.sorted {
            let lhs = $0.lastUpdated ?? .distantPast
            let rhs = $1.lastUpdated ?? .distantPast
            if lhs != rhs { return lhs > rhs }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private struct MemoryCounts {
        var active = 0
        var important = 0
        var todo = 0
        var lastUpdated: Date?
    }

    private func memoryCounts(
        database: CharacterDatabase,
        settings: MemorySettings,
        now: Date
    ) throws -> MemoryCounts {
        var counts = MemoryCounts()
        let statement = try database.prepare("""
        SELECT
            SUM(CASE WHEN archived = 0 AND superseded_by IS NULL THEN 1 ELSE 0 END),
            SUM(CASE WHEN archived = 0 AND superseded_by IS NULL
                      AND (pinned = 1 OR kind = 'important') THEN 1 ELSE 0 END),
            SUM(CASE WHEN archived = 0 AND superseded_by IS NULL AND category = 'todo' THEN 1 ELSE 0 END),
            MAX(updated_at)
        FROM memories;
        """)
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            counts.active = database.optionalInt(statement, 0) ?? 0
            counts.important = database.optionalInt(statement, 1) ?? 0
            counts.todo = database.optionalInt(statement, 2) ?? 0
            counts.lastUpdated = database.optionalDate(statement, 3)
        }
        return counts
    }

    // MARK: Memories

    private static let memoryColumns = """
    id, category, kind, content, compressed_content, keywords, importance, pinned,
    archived, superseded_by, supersedes, superseded_at, source, source_message_ids,
    merge_count, access_count, created_at, updated_at, last_accessed_at
    """

    func fetchMemories(conversationID: String) throws -> [CharacterMemory] {
        let db: CharacterDatabase
        do {
            db = try database(for: conversationID, createIfNeeded: false)
        } catch CharacterStoreError.characterNotFound {
            return []
        }
        let statement = try db.prepare("""
        SELECT \(Self.memoryColumns)
        FROM memories
        ORDER BY updated_at DESC, created_at DESC;
        """)
        defer { sqlite3_finalize(statement) }
        var result: [CharacterMemory] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(decodeMemory(statement, characterID: conversationID))
        }
        return result
    }

    func fetchAllMemories(limit: Int = 2000) throws -> [CharacterMemory] {
        let root = try requireRoot()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        var result: [CharacterMemory] = []
        for entry in entries {
            let databaseURL = entry.appendingPathComponent("memory.sqlite")
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { continue }
            removeLegacyPersonaCard(in: entry)
            guard let meta = try? CharacterDatabase(directory: entry) else { continue }
            let conversationID = (try? meta.meta("conversation_id")) ?? nil
            meta.close()
            guard let conversationID, !conversationID.isEmpty else { continue }
            if let memories = try? fetchMemories(conversationID: conversationID) {
                result.append(contentsOf: memories)
            }
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    func fetchMemory(conversationID: String, id: String) throws -> CharacterMemory? {
        let database = try database(for: conversationID, createIfNeeded: false)
        let statement = try database.prepare("""
        SELECT \(Self.memoryColumns) FROM memories WHERE id = ? LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeMemory(statement, characterID: conversationID)
    }

    func upsertMemory(_ memory: CharacterMemory, now: Date = Date()) throws {
        var updated = memory
        updated.updatedAt = now
        if updated.createdAt > now { updated.createdAt = now }
        let database = try database(for: memory.characterID, createIfNeeded: true)
        try insertMemory(updated, database: database)
    }

    func deleteMemory(conversationID: String, id: String) throws {
        let database = try database(for: conversationID, createIfNeeded: false)
        let statement = try database.prepare("DELETE FROM memories WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try database.bind(statement, 1, id)
        try database.stepDone(statement)
    }

    func recordAccess(conversationID: String, ids: [String], at date: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        let db: CharacterDatabase
        do {
            db = try database(for: conversationID, createIfNeeded: false)
        } catch CharacterStoreError.characterNotFound {
            return
        }
        let statement = try db.prepare("""
        UPDATE memories
        SET access_count = access_count + 1, last_accessed_at = ?
        WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try db.transaction {
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try db.bind(statement, 1, date.timeIntervalSince1970)
                try db.bind(statement, 2, id)
                try db.stepDone(statement)
            }
        }
    }

    func memoryCount(conversationID: String) throws -> Int {
        guard let database = try? database(for: conversationID, createIfNeeded: false) else {
            return 0
        }
        let statement = try database.prepare("SELECT COUNT(*) FROM memories;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return database.int(statement, 0)
    }

    // MARK: Interactions (full memory)

    /// 会话已有角色卡时，把最近消息 upsert 进全量互动；没有角色卡时返回 0。
    @discardableResult
    func upsertInteractions(
        conversationID: String,
        records: [CharacterInteractionInput],
        now: Date = Date()
    ) throws -> Int {
        guard !records.isEmpty else { return 0 }
        let db: CharacterDatabase
        do {
            db = try database(for: conversationID, createIfNeeded: false)
        } catch CharacterStoreError.characterNotFound {
            return 0
        }
        var seen = Set<String>()
        let prepared: [CharacterInteractionInput] = records.compactMap { record in
            let content = String(
                record.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
            guard !content.isEmpty, seen.insert(record.messageID).inserted else { return nil }
            var value = record
            value.content = content
            return value
        }
        guard !prepared.isEmpty else { return 0 }
        let statement = try db.prepare("""
        INSERT INTO interactions (
            message_id, direction, sender_id, sender_name, content, timestamp, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(message_id) DO UPDATE SET
            direction = excluded.direction,
            sender_id = excluded.sender_id,
            sender_name = excluded.sender_name,
            content = excluded.content,
            timestamp = excluded.timestamp;
        """)
        defer { sqlite3_finalize(statement) }
        try db.transaction {
            for record in prepared {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try db.bind(statement, 1, record.messageID)
                try db.bind(statement, 2, record.direction.rawValue)
                try db.bind(statement, 3, record.senderID)
                try db.bind(statement, 4, record.senderName)
                try db.bind(statement, 5, record.content)
                try db.bind(statement, 6, record.timestamp.timeIntervalSince1970)
                try db.bind(statement, 7, now.timeIntervalSince1970)
                try db.stepDone(statement)
            }
        }
        return prepared.count
    }

    /// 是否已经做过一次全量历史回填（只回填一次，之后增量同步最近消息）。
    func isInteractionsBackfilled(conversationID: String) throws -> Bool {
        let database = try database(for: conversationID, createIfNeeded: false)
        return (try database.meta("interactions_backfilled")) == "1"
    }

    func markInteractionsBackfilled(conversationID: String, at date: Date = Date()) throws {
        let database = try database(for: conversationID, createIfNeeded: false)
        try database.setMeta("interactions_backfilled", "1")
        try database.setMetaDate("interactions_backfilled_at", date)
    }

    /// 增量同步游标：最近一次已写入 `interactions` 的消息时间。
    func lastInteractionSyncedAt(conversationID: String) throws -> Date? {
        let database = try database(for: conversationID, createIfNeeded: false)
        return try database.metaDate("interactions_synced_at")
    }

    func markInteractionsSynced(conversationID: String, through date: Date) throws {
        let database = try database(for: conversationID, createIfNeeded: false)
        if let current = try database.metaDate("interactions_synced_at"), date <= current {
            return
        }
        try database.setMetaDate("interactions_synced_at", date)
    }

    func fetchInteractions(
        conversationID: String,
        limit: Int = 500,
        offset: Int = 0,
        search: String? = nil
    ) throws -> [CharacterInteraction] {
        guard let database = try? database(for: conversationID, createIfNeeded: false) else {
            return []
        }
        let keyword = (search ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        if keyword.isEmpty {
            sql = """
            SELECT id, message_id, direction, sender_id, sender_name, content, timestamp, created_at
            FROM interactions ORDER BY timestamp DESC, id DESC LIMIT ? OFFSET ?;
            """
        } else {
            sql = """
            SELECT id, message_id, direction, sender_id, sender_name, content, timestamp, created_at
            FROM interactions WHERE content LIKE ? ESCAPE '\\'
            ORDER BY timestamp DESC, id DESC LIMIT ? OFFSET ?;
            """
        }
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        if keyword.isEmpty {
            try database.bind(statement, 1, Int32(max(1, limit)))
            try database.bind(statement, 2, Int32(max(0, offset)))
        } else {
            let escaped = keyword
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            try database.bind(statement, 1, "%\(escaped)%")
            try database.bind(statement, 2, Int32(max(1, limit)))
            try database.bind(statement, 3, Int32(max(0, offset)))
        }
        var result: [CharacterInteraction] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let direction = ChatDirection(rawValue: database.text(statement, 2)) ?? .incoming
            result.append(CharacterInteraction(
                id: Int64(database.int(statement, 0)),
                messageID: database.text(statement, 1),
                direction: direction,
                senderID: database.text(statement, 3),
                senderName: database.text(statement, 4),
                content: database.text(statement, 5),
                timestamp: database.date(statement, 6),
                createdAt: database.date(statement, 7)
            ))
        }
        return result
    }

    func interactionCount(conversationID: String) throws -> Int {
        guard let database = try? database(for: conversationID, createIfNeeded: false) else {
            return 0
        }
        let statement = try database.prepare("SELECT COUNT(*) FROM interactions;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return database.int(statement, 0)
    }

    // MARK: Extraction cursor

    func pendingInteractions(
        conversationID: String,
        minCount: Int,
        maxMessages: Int
    ) throws -> [CharacterInteraction]? {
        guard let database = try? database(for: conversationID, createIfNeeded: false) else {
            return nil
        }
        let cursor = try database.metaDate("last_extracted_at") ?? .distantPast
        let countStatement = try database.prepare(
            "SELECT COUNT(*) FROM interactions WHERE timestamp > ?;")
        defer { sqlite3_finalize(countStatement) }
        try database.bind(countStatement, 1, cursor.timeIntervalSince1970)
        guard sqlite3_step(countStatement) == SQLITE_ROW else { return nil }
        guard database.int(countStatement, 0) >= max(1, minCount) else { return nil }

        return try fetchPending(conversationID: conversationID,
                                database: database,
                                cursor: cursor,
                                maxMessages: maxMessages)
    }

    private func fetchPending(
        conversationID: String,
        database: CharacterDatabase,
        cursor: Date,
        maxMessages: Int
    ) throws -> [CharacterInteraction] {
        let statement = try database.prepare("""
        SELECT id, message_id, direction, sender_id, sender_name, content, timestamp, created_at
        FROM interactions
        WHERE timestamp > ?
        ORDER BY timestamp ASC, id ASC
        LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement, 1, cursor.timeIntervalSince1970)
        try database.bind(statement, 2, Int32(max(1, maxMessages)))
        var result: [CharacterInteraction] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let direction = ChatDirection(rawValue: database.text(statement, 2)) ?? .incoming
            result.append(CharacterInteraction(
                id: Int64(database.int(statement, 0)),
                messageID: database.text(statement, 1),
                direction: direction,
                senderID: database.text(statement, 3),
                senderName: database.text(statement, 4),
                content: database.text(statement, 5),
                timestamp: database.date(statement, 6),
                createdAt: database.date(statement, 7)
            ))
        }
        return result
    }

    func markExtracted(conversationID: String, through timestamp: Date) throws {
        let database = try database(for: conversationID, createIfNeeded: false)
        let current = try database.metaDate("last_extracted_at") ?? .distantPast
        if timestamp > current {
            try database.setMetaDate("last_extracted_at", timestamp)
        }
    }

    func lastArchiveAt(conversationID: String) throws -> Date? {
        let database = try database(for: conversationID, createIfNeeded: false)
        return try database.metaDate("last_archive_at")
    }

    func markArchiveRun(conversationID: String, at date: Date) throws {
        let database = try database(for: conversationID, createIfNeeded: false)
        try database.setMetaDate("last_archive_at", date)
    }

    // MARK: Snapshot / export

    func snapshot(conversationID: String) throws -> CharacterSnapshot? {
        guard let database = try? database(for: conversationID, createIfNeeded: false) else {
            return nil
        }
        let title = (try database.meta("conversation_title")) ?? conversationID
        let kind = (try database.meta("conversation_kind"))
            .flatMap(ConversationKind.init(rawValue:)) ?? .direct
        let memories = (try? fetchMemories(conversationID: conversationID)) ?? []
        let interactions = (try? fetchInteractions(
            conversationID: conversationID, limit: 100_000)) ?? []
        return CharacterSnapshot(
            conversationID: conversationID,
            conversationTitle: title.isEmpty ? conversationID : title,
            conversationKind: kind,
            memories: memories,
            interactions: Array(interactions.reversed())
        )
    }

    // MARK: Delete

    /// 删除整个角色目录（移到废纸篓；失败时退回删除）。
    func deleteCharacter(conversationID: String) throws {
        close(conversationID: conversationID)
        guard let root, !suspended else { return }
        let dir = root.appendingPathComponent(
            CharacterDirectory.key(for: conversationID), isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: Legacy import

    /// 把旧版长期记忆导入当前记忆卡；返回新增/合并条数。
    /// 旧表本身不修改；调用方负责筛选「本会话 + 全局」。
    @discardableResult
    func importLegacyMemories(
        conversationID: String,
        memories legacyMemories: [LongTermMemory],
        settings: MemorySettings = .default,
        now: Date = Date()
    ) throws -> Int {
        guard !legacyMemories.isEmpty else { return 0 }
        let database = try database(for: conversationID, createIfNeeded: false)
        var existing = try fetchMemories(conversationID: conversationID)
        var changed = 0
        for legacy in legacyMemories {
            let candidates = LegacyMemoryMapper.map(legacy, characterID: conversationID)
            for var candidate in candidates {
                candidate.normalizeKind(threshold: settings.importanceThreshold)
                if let index = existing.firstIndex(where: {
                    $0.category == candidate.category
                        && !$0.isSuperseded
                        && MemorySimilarity.isDuplicate(
                            $0.content, candidate.content,
                            threshold: settings.mergeSimilarity)
                }) {
                    var merged = existing[index]
                    if candidate.content.count > merged.content.count {
                        merged.content = candidate.content
                        merged.compressedContent = nil
                    }
                    merged.keywords = Array(Set(merged.keywords + candidate.keywords))
                    merged.importance = max(merged.importance, candidate.importance)
                    merged.pinned = merged.pinned || candidate.pinned
                    merged.mergeCount += 1
                    merged.updatedAt = now
                    merged.normalizeKind(threshold: settings.importanceThreshold)
                    try insertMemory(merged, database: database)
                    existing[index] = merged
                } else {
                    try insertMemory(candidate, database: database)
                    existing.append(candidate)
                }
                changed += 1
            }
        }
        return changed
    }

    // MARK: Private memory DB helpers

    private func insertMemory(
        _ memory: CharacterMemory,
        database: CharacterDatabase
    ) throws {
        let statement = try database.prepare("""
        INSERT INTO memories (
            id, category, kind, content, compressed_content, keywords, importance, pinned,
            archived, superseded_by, supersedes, superseded_at, source, source_message_ids,
            merge_count, access_count, created_at, updated_at, last_accessed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            category = excluded.category,
            kind = excluded.kind,
            content = excluded.content,
            compressed_content = excluded.compressed_content,
            keywords = excluded.keywords,
            importance = excluded.importance,
            pinned = excluded.pinned,
            archived = excluded.archived,
            superseded_by = excluded.superseded_by,
            supersedes = excluded.supersedes,
            superseded_at = excluded.superseded_at,
            source = excluded.source,
            source_message_ids = excluded.source_message_ids,
            merge_count = excluded.merge_count,
            access_count = excluded.access_count,
            updated_at = excluded.updated_at,
            last_accessed_at = excluded.last_accessed_at;
        """)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement, 1, memory.id)
        try database.bind(statement, 2, memory.category.rawValue)
        try database.bind(statement, 3, memory.kind.rawValue)
        try database.bind(statement, 4, memory.content)
        try database.bind(statement, 5, memory.compressedContent)
        try database.bind(statement, 6, memory.keywords.joined(separator: " "))
        try database.bind(statement, 7, memory.importance)
        try database.bind(statement, 8, Int32(memory.pinned ? 1 : 0))
        try database.bind(statement, 9, Int32(memory.archived ? 1 : 0))
        try database.bind(statement, 10, memory.supersededBy)
        try database.bind(statement, 11, memory.supersedes)
        try database.bind(statement, 12, memory.supersededAt?.timeIntervalSince1970)
        try database.bind(statement, 13, memory.source.rawValue)
        try database.bind(statement, 14, Self.encodeMessageIDs(memory.sourceMessageIDs))
        try database.bind(statement, 15, Int32(memory.mergeCount))
        try database.bind(statement, 16, Int32(memory.accessCount))
        try database.bind(statement, 17, memory.createdAt.timeIntervalSince1970)
        try database.bind(statement, 18, memory.updatedAt.timeIntervalSince1970)
        try database.bind(statement, 19, memory.lastAccessedAt?.timeIntervalSince1970)
        try database.stepDone(statement)
    }

    private func decodeMemory(
        _ statement: OpaquePointer,
        characterID: String
    ) -> CharacterMemory {
        let category = MemoryCategory(rawValue: text(statement, 1)) ?? .fact
        let kind = MemoryKind(rawValue: text(statement, 2)) ?? .normal
        return CharacterMemory(
            id: text(statement, 0),
            characterID: characterID,
            category: category,
            kind: kind,
            content: text(statement, 3),
            compressedContent: optionalText(statement, 4),
            keywords: Self.decodeKeywords(text(statement, 5)),
            importance: sqlite3_column_double(statement, 6),
            pinned: sqlite3_column_int(statement, 7) != 0,
            archived: sqlite3_column_int(statement, 8) != 0,
            supersededBy: optionalText(statement, 9),
            supersedes: optionalText(statement, 10),
            supersededAt: optionalDate(statement, 11),
            source: MemorySource(rawValue: text(statement, 12)) ?? .extraction,
            sourceMessageIDs: Self.decodeMessageIDs(text(statement, 13)),
            mergeCount: Int(sqlite3_column_int(statement, 14)),
            accessCount: Int(sqlite3_column_int(statement, 15)),
            createdAt: date(statement, 16),
            updatedAt: date(statement, 17),
            lastAccessedAt: optionalDate(statement, 18)
        )
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func date(_ statement: OpaquePointer, _ column: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static func encodeMessageIDs(_ ids: [String]) -> String {
        guard !ids.isEmpty,
              let data = try? JSONEncoder().encode(Array(Set(ids)).sorted()),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func decodeMessageIDs(_ text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    private static func decodeKeywords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Legacy memory → v2 mapping

/// 旧版滚动摘要 → 多条原子记忆的确定性映射。
enum LegacyMemoryMapper {
    static func map(_ legacy: LongTermMemory, characterID: String) -> [CharacterMemory] {
        let pieces = split(legacy.summary)
        let baseKind: MemoryKind = legacy.isCore ? .important : .normal
        let importance: Double = legacy.isCore ? 8 : (legacy.source == "manual" ? 6 : 4)
        return pieces.compactMap { raw in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return nil }
            let content = String(text.prefix(300))
            return CharacterMemory(
                characterID: characterID,
                category: category(for: content),
                kind: baseKind,
                content: content,
                keywords: keywords(for: content),
                importance: importance,
                pinned: legacy.isCore,
                archived: false,
                source: .legacyImport,
                mergeCount: max(0, legacy.sourceCount),
                accessCount: max(0, legacy.accessCount),
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                lastAccessedAt: legacy.lastAccessedAt
            )
        }
    }

    static func split(_ summary: String) -> [String] {
        let lines = summary
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var bullets: [String] = []
        var buffer: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let isBullet = ["- ", "* ", "• ", "· ", "– ", "— "].contains { line.hasPrefix($0) }
            if isBullet {
                if !buffer.isEmpty {
                    bullets.append(buffer.joined(separator: " "))
                    buffer.removeAll()
                }
                var body = line
                for prefix in ["- ", "* ", "• ", "· ", "– ", "— "] where body.hasPrefix(prefix) {
                    body = String(body.dropFirst(prefix.count))
                }
                buffer.append(body)
            } else {
                buffer.append(line)
            }
        }
        if !buffer.isEmpty { bullets.append(buffer.joined(separator: " ")) }
        if bullets.count <= 1 { return [summary] }
        return bullets
    }

    static func category(for text: String) -> MemoryCategory {
        if containsAny(text, ["提醒", "记得", "下次", "待办", "未完成", "别忘", "回头"]) {
            return .todo
        }
        if containsAny(text, ["约定", "决定", "说好", "答应", "以后", "计划", "定了"]) {
            return .decision
        }
        if containsAny(text, ["规律", "经验", "一般", "通常", "每次", "看来", "适合", "不要"]) {
            return .lesson
        }
        return .fact
    }

    static func keywords(for text: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters)
                .contains(scalar) {
                if buffer.count >= 2 { result.append(buffer) }
                buffer = ""
            } else {
                buffer.unicodeScalars.append(scalar)
                if buffer.count >= 12 {
                    if buffer.count >= 2 { result.append(buffer) }
                    buffer = ""
                }
            }
            if result.count >= 4 { break }
        }
        if buffer.count >= 2, result.count < 4 { result.append(buffer) }
        return result
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
