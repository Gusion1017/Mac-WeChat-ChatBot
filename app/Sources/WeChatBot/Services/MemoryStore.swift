import Foundation
import SQLite3

// MARK: - Types

struct MemorySearchHit: Sendable, Hashable {
    var message: ChatMessage
    var conversationTitle: String
}

/// 短期窗口溢出的一批消息；`lastRowID` 用于推进总结游标。
struct MemoryOverflow: Sendable, Equatable {
    var messages: [ChatMessage]
    var lastRowID: Int64
}

/// 历史自消息归位结果（一次性数据修复）。
struct SelfRoutingRepairResult: Sendable, Equatable {
    var movedMessages: Int = 0
    var affectedConversationIDs: [String] = []
    var removedSelfConversation: Bool = false
    /// 从历史事件反推、且与传入 selfID 不一致的账号；用于自愈被旧事件污染的 selfID。
    var inferredSelfID: String? = nil

    var didChange: Bool { movedMessages > 0 || removedSelfConversation }
}

/// 历史「误归类会话」修复结果（自己/占位会话、伪群会话）。
struct MisroutedConversationRepairResult: Sendable, Equatable {
    /// 按 `raw_json` 明确推导出目标后搬走的消息条数。
    var movedMessages: Int = 0
    /// 受影响的目标会话 + 修正过 kind 的会话（不含被删除的会话，见 `removedConversationIDs`）。
    var affectedConversationIDs: [String] = []
    /// 搬空后被删除的嫌疑会话。
    var removedConversationIDs: [String] = []
    /// 修正了会话类型（伪群 → 私聊、群 ID → 群聊）的会话数。
    var fixedKinds: Int = 0

    var didChange: Bool { movedMessages > 0 || !removedConversationIDs.isEmpty || fixedKinds > 0 }
}

enum MemoryStoreError: LocalizedError {
    case openFailed(String)
    case sqlite(String)
    case notOpen

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "数据库打开失败：\(message)"
        case .sqlite(let message): return "数据库错误：\(message)"
        case .notOpen: return "数据库尚未打开"
        }
    }
}

// MARK: - MemoryStore

/// SQLite-backed persistence for conversations / messages / logs / schedules / kv settings.
///
/// Concurrency model:
/// - This is an `actor`; every statement executes serially inside the actor.
/// - `SQLITE_OPEN_FULLMUTEX` is still requested as a belt-and-braces measure.
/// - Callers on the main actor must `await` these methods; the UI never blocks on IO.
/// - WAL mode + `synchronous=NORMAL` give cheap durable writes.
actor MemoryStore {
    static let shared = MemoryStore()

    private let databaseURL: URL
    private var db: OpaquePointer?
    private var isOpen = false
    private(set) var openedAt: Date?

    nonisolated var path: String { databaseURL.path }

    init(databaseURL: URL = AppPaths.databaseFile) {
        self.databaseURL = databaseURL
    }

    deinit {
        if let db {
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_close_v2(db)
        }
    }

    // MARK: Lifecycle

    func open() throws {
        guard !isOpen else { return }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 code \(status)"
            if let handle { sqlite3_close_v2(handle) }
            throw MemoryStoreError.openFailed(message)
        }
        db = handle

        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("PRAGMA foreign_keys=ON;")
            try execute("PRAGMA busy_timeout=3000;")
            try migrate()
        } catch {
            sqlite3_close_v2(handle)
            db = nil
            throw error
        }
        isOpen = true
        openedAt = Date()
    }

    /// Closes the handle after a WAL checkpoint. Safe to call multiple times.
    func close() {
        guard let db else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        sqlite3_close_v2(db)
        self.db = nil
        isOpen = false
        openedAt = nil
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            subtitle TEXT,
            unread_count INTEGER NOT NULL DEFAULT 0,
            last_message_at REAL,
            last_message_preview TEXT NOT NULL DEFAULT '',
            ai_enabled INTEGER NOT NULL DEFAULT 1,
            provider_id TEXT,
            model TEXT,
            persona_id TEXT,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            is_muted INTEGER NOT NULL DEFAULT 0,
            note TEXT NOT NULL DEFAULT '',
            working_hours TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_conversations_last_message
            ON conversations (is_pinned DESC, last_message_at DESC);

        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY NOT NULL,
            conversation_id TEXT NOT NULL,
            sender_id TEXT NOT NULL DEFAULT '',
            sender_name TEXT NOT NULL DEFAULT '',
            direction TEXT NOT NULL DEFAULT 'incoming',
            kind TEXT NOT NULL DEFAULT 'text',
            text TEXT NOT NULL DEFAULT '',
            media_path TEXT,
            media_url TEXT,
            timestamp REAL NOT NULL,
            status TEXT NOT NULL DEFAULT 'received',
            reply_to_id TEXT,
            raw_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_messages_conversation_time
            ON messages (conversation_id, timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_messages_time ON messages (timestamp DESC);

        CREATE TABLE IF NOT EXISTS logs (
            id TEXT PRIMARY KEY NOT NULL,
            date REAL NOT NULL,
            level TEXT NOT NULL,
            source TEXT NOT NULL,
            message TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_logs_date ON logs (date DESC);

        CREATE TABLE IF NOT EXISTS schedules (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            conversation_id TEXT NOT NULL DEFAULT '',
            conversation_title TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL DEFAULT 'outgoing',
            content TEXT NOT NULL DEFAULT '',
            repeat_rule TEXT NOT NULL DEFAULT 'daily',
            fire_at REAL NOT NULL,
            weekdays TEXT NOT NULL DEFAULT '',
            last_fired_at REAL,
            next_fire_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_schedules_next ON schedules (enabled, next_fire_at);

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY NOT NULL,
            conversation_id TEXT NOT NULL DEFAULT '',
            summary TEXT NOT NULL,
            is_core INTEGER NOT NULL DEFAULT 0,
            base_weight REAL NOT NULL DEFAULT 1.0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_accessed_at REAL,
            source_count INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'summary',
            access_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_memories_conversation
            ON memories (conversation_id, is_core DESC, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_memories_core
            ON memories (is_core DESC, updated_at DESC);

        CREATE TABLE IF NOT EXISTS memory_state (
            conversation_id TEXT PRIMARY KEY NOT NULL,
            last_summarized_rowid INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS contact_directory (
            username TEXT PRIMARY KEY NOT NULL,
            display TEXT NOT NULL,
            nickname TEXT,
            remark TEXT,
            kind TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        // v3: per-conversation working hours stored as nullable JSON
        // (NULL means “follow the global bot setting”).
        if try !columnExists(in: "conversations", column: "working_hours") {
            try execute("ALTER TABLE conversations ADD COLUMN working_hours TEXT;")
        }

        let version = try userVersion()
        if version < 2 {
            // 已有历史消息不批量补总结（避免升级时产生大量 AI 调用）；
            // 从当前最新 rowid 开始只总结升级后的新消息。
            try execute("""
            INSERT OR IGNORE INTO memory_state (conversation_id, last_summarized_rowid, updated_at)
            SELECT c.id,
                   COALESCE((SELECT MAX(m.rowid) FROM messages m WHERE m.conversation_id = c.id), 0),
                   CAST(strftime('%s','now') AS REAL)
            FROM conversations c;
            """)
            try execute("PRAGMA user_version=2;")
        }

        // v4: 长期记忆记录提示词召回次数（使用强化）。旧库用列探测补列，
        // 新建库已在上面的 CREATE TABLE 中带有该列。
        if try !columnExists(in: "memories", column: "access_count") {
            try execute("ALTER TABLE memories ADD COLUMN access_count INTEGER NOT NULL DEFAULT 0;")
        }
        if version < 4 {
            try execute("PRAGMA user_version=4;")
        }
    }

    // MARK: - Conversations

    func upsertConversation(_ conversation: Conversation) throws {
        try ensureOpen()
        try executeConversationUpsert([conversation])
    }

    func upsertConversations(_ conversations: [Conversation]) throws {
        guard !conversations.isEmpty else { return }
        try ensureOpen()
        try executeConversationUpsert(conversations)
    }

    /// Newest activity first. Pinned conversations float to the top.
    func fetchConversations(limit: Int = 200, offset: Int = 0) throws -> [Conversation] {
        try ensureOpen()
        let sql = """
        SELECT id, kind, title, subtitle, unread_count, last_message_at, last_message_preview,
               ai_enabled, provider_id, model, persona_id, is_pinned, is_muted, note, working_hours
        FROM conversations
        ORDER BY is_pinned DESC, COALESCE(last_message_at, 0) DESC
        LIMIT ? OFFSET ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, Int32(max(1, limit)))
        try bind(statement, 2, Int32(max(0, offset)))
        var result: [Conversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeConversation(statement))
        }
        return result
    }

    func conversation(id: String) throws -> Conversation? {
        try ensureOpen()
        let statement = try prepare("""
        SELECT id, kind, title, subtitle, unread_count, last_message_at, last_message_preview,
               ai_enabled, provider_id, model, persona_id, is_pinned, is_muted, note, working_hours
        FROM conversations WHERE id = ? LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeConversation(statement)
    }

    func deleteConversation(id: String) throws {
        try ensureOpen()
        try transaction {
            let deleteMessages = try prepare("DELETE FROM messages WHERE conversation_id = ?;")
            defer { sqlite3_finalize(deleteMessages) }
            try bind(deleteMessages, 1, id)
            try stepDone(deleteMessages)

            let deleteConversation = try prepare("DELETE FROM conversations WHERE id = ?;")
            defer { sqlite3_finalize(deleteConversation) }
            try bind(deleteConversation, 1, id)
            try stepDone(deleteConversation)

            let deleteMemories = try prepare("DELETE FROM memories WHERE conversation_id = ?;")
            defer { sqlite3_finalize(deleteMemories) }
            try bind(deleteMemories, 1, id)
            try stepDone(deleteMemories)

            let deleteState = try prepare("DELETE FROM memory_state WHERE conversation_id = ?;")
            defer { sqlite3_finalize(deleteState) }
            try bind(deleteState, 1, id)
            try stepDone(deleteState)
        }
    }

    /// 一次性修复旧 hook 造成的「自消息进错会话」。
    ///
    /// 旧 hook 对**本账号发出的私聊消息**写的是 `self_id=对方`、`user_id=自己`，
    /// App 因此判成「对方发来的」，并按 user_id 建出一个以自己 wxid 命名的会话。
    /// 修复规则（只动 `conversation_id == 当前账号` 的会话，幂等、可重复执行）：
    ///   - 目标会话 = raw_json 的 `group_id`（群）或 `self_id`（私聊对方）；
    ///   - 消息改为 outgoing / sender=自己 / status=sent，并搬到目标会话；
    ///   - 目标会话不存在时创建（标题留空，由 `ConversationName` 生成可读展示名）；
    ///   - 重算目标会话的 last_message_at / preview；
    ///   - 自己会话清空后删除（含 memories/memory_state 残留）。
    ///
    /// 安全阀：`selfID` 可能被旧事件污染成某个好友 wxid。这里优先从历史事件的
    /// `self_id` 反推账号（账号会作为 self_id 出现在**多个不同发送者**的消息里，
    /// 好友只会出现在自己发出的消息里，distinct 发送者通常只有 1 个）；
    /// 推不出来时退回传入的 selfID。
    func repairSelfRoutedMessages(selfID: String) throws -> SelfRoutingRepairResult {
        let storedSelfID = selfID.trimmingCharacters(in: .whitespacesAndNewlines)
        try ensureOpen()

        let inferredSelfID = try inferAccountIDFromRawEvents()
        let effectiveSelfID = inferredSelfID ?? storedSelfID
        guard !effectiveSelfID.isEmpty else { return SelfRoutingRepairResult() }

        struct Move {
            var messageID: String
            var targetID: String
            var targetIsGroup: Bool
            var text: String
            var timestamp: Double
        }

        let statement = try prepare("""
        SELECT id, raw_json, text, timestamp
        FROM messages WHERE conversation_id = ? ORDER BY timestamp ASC;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, effectiveSelfID)

        var moves: [Move] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = try text(statement, 0)
            let raw = optionalText(statement, 1) ?? ""
            let messageText = try text(statement, 2)
            let timestamp = sqlite3_column_double(statement, 3)
            guard let data = raw.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            // 只有合法 `@chatroom` 群 ID 才能当群目标；旧 hook 写进 group_id 的
            // 私聊 wxid 会在这里被忽略，让下面的私聊兜底接管。
            let rawGroupID = Self.routingString(object["group_id"]) ?? ""
            let groupID = ConversationIdentity.isGroupID(rawGroupID) ? rawGroupID : ""
            // 私聊兜底：target_id 优先，其次旧事件的 self_id；必须像真实对象且不是自己，
            // 避免再次创建 `wxid_self` / 非法群会话。
            let peerID = [Self.routingString(object["target_id"]), Self.routingString(object["self_id"])]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first {
                    ConversationIdentity.isPlausiblePeerID($0)
                        && !Self.isSameID($0, effectiveSelfID)
                } ?? ""
            let target = !groupID.isEmpty ? groupID : peerID
            // 目标为空或就是自己（真正的「自己和自己」会话）时保持原样。
            guard !target.isEmpty, !Self.isSameID(target, effectiveSelfID) else { continue }
            moves.append(Move(
                messageID: messageID,
                targetID: target,
                targetIsGroup: !groupID.isEmpty,
                text: messageText,
                timestamp: timestamp
            ))
        }
        guard !moves.isEmpty else { return SelfRoutingRepairResult() }

        var targets = Set<String>()
        let affected = moves.map(\.targetID)
        targets.formUnion(affected)

        var removedSelfConversation = false
        try transaction {
            let insertConversation = try prepare("""
            INSERT OR IGNORE INTO conversations (id, kind, title)
            VALUES (?, ?, ?);
            """)
            defer { sqlite3_finalize(insertConversation) }

            var seenTargets = Set<String>()
            for move in moves where seenTargets.insert(move.targetID).inserted {
                sqlite3_reset(insertConversation)
                sqlite3_clear_bindings(insertConversation)
                try bind(insertConversation, 1, move.targetID)
                try bind(insertConversation, 2, move.targetIsGroup ? ConversationKind.group.rawValue : ConversationKind.direct.rawValue)
                try bind(insertConversation, 3, "")
                try stepDone(insertConversation)
            }

            let updateMessage = try prepare("""
            UPDATE messages
            SET conversation_id = ?, direction = ?, sender_id = ?, sender_name = ?, status = ?
            WHERE id = ?;
            """)
            defer { sqlite3_finalize(updateMessage) }
            for move in moves {
                sqlite3_reset(updateMessage)
                sqlite3_clear_bindings(updateMessage)
                try bind(updateMessage, 1, move.targetID)
                try bind(updateMessage, 2, ChatDirection.outgoing.rawValue)
                try bind(updateMessage, 3, effectiveSelfID)
                try bind(updateMessage, 4, "我")
                try bind(updateMessage, 5, DeliveryStatus.sent.rawValue)
                try bind(updateMessage, 6, move.messageID)
                try stepDone(updateMessage)
            }

            try refreshConversationPreviewRows(conversationIDs: targets)
            removedSelfConversation = try removeConversationIfEmpty(effectiveSelfID)
        }

        return SelfRoutingRepairResult(
            movedMessages: moves.count,
            affectedConversationIDs: targets.sorted(),
            removedSelfConversation: removedSelfConversation,
            inferredSelfID: inferredSelfID != storedSelfID ? inferredSelfID : nil
        )
    }

    // MARK: - Misrouted conversation repair

    /// 一条待搬移的消息及其归位后的字段。
    private struct MisroutedMove {
        var messageID: String
        var targetID: String
        var targetKind: ConversationKind
        var direction: ChatDirection
        var senderID: String
        var senderName: String
        var status: DeliveryStatus
    }

    /// 一次性修复「误归类会话」：自己 wxid 会话、字面量 `wxid_self`/`self` 占位会话，
    /// 以及 `kind=group` 但 ID 不是 `@chatroom` 的伪群会话（旧 hook 把私聊拍一拍的
    /// wxid 当群 ID 写入 `group_id`）。
    ///
    /// 安全阀：
    /// - 只扫描上述嫌疑会话，健康会话一律不碰；
    /// - 只搬 `raw_json` 能明确推导出目标（`@chatroom` 群 ID 或可辨认的私聊对象）的消息，
    ///   目标等于当前会话/自己、或推导不出来的消息原样保留；
    /// - 搬完重算预览、删除搬空的会话（含 memories/memory_state），并把剩余嫌疑会话的
    ///   kind 归一化（伪群 → 私聊，`@chatroom` → 群聊）；幂等。
    func repairMisroutedConversations(selfID: String) throws -> MisroutedConversationRepairResult {
        let storedSelfID = selfID.trimmingCharacters(in: .whitespacesAndNewlines)
        try ensureOpen()

        let inferredSelfID = try inferAccountIDFromRawEvents()
        let effectiveSelfID = (inferredSelfID ?? storedSelfID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effectiveSelfID.isEmpty else { return MisroutedConversationRepairResult() }
        // 传入账号本身是占位值时无法可靠判定消息方向（区分不了「自己发出」与
        // 「对方发来」），先不动数据；等 `get_login_info` 的权威账号到达后再修。
        if inferredSelfID == nil, ConversationIdentity.isPlaceholderSelfID(effectiveSelfID) {
            return MisroutedConversationRepairResult()
        }

        let suspicious = try suspiciousMisroutedConversations(effectiveSelfID: effectiveSelfID)
        guard !suspicious.isEmpty else { return MisroutedConversationRepairResult() }

        var moves: [MisroutedMove] = []
        for conversation in suspicious {
            moves.append(contentsOf: try misroutedMoves(
                from: conversation,
                effectiveSelfID: effectiveSelfID
            ))
        }

        var targetKinds: [String: ConversationKind] = [:]
        for move in moves {
            targetKinds[move.targetID] = move.targetKind
        }

        var affected = Set(moves.map(\.targetID))
        var removedConversationIDs: [String] = []
        var fixedKinds = 0
        // 已存在的目标会话若 kind 与推导结果不一致（旧 bug 可能把好友建成伪群、
        // 或把群建成私聊），搬入前一并修正；公众号等明确类型不覆盖。
        // 目标本身也是嫌疑会话时交给下面的 kind 归一化统一处理，避免重复计数。
        let suspiciousIDs = Set(suspicious.map(\.id))
        var targetKindFixes: [String: ConversationKind] = [:]
        for (targetID, kind) in targetKinds where !suspiciousIDs.contains(targetID) {
            guard let existing = try conversation(id: targetID),
                  existing.kind != kind,
                  existing.kind != .official else { continue }
            targetKindFixes[targetID] = kind
        }
        try transaction {
            // 目标会话不存在时创建，标题留空交给 `ConversationName` 生成可读展示名。
            let insert = try prepare("""
            INSERT OR IGNORE INTO conversations (id, kind, title) VALUES (?, ?, ?);
            """)
            defer { sqlite3_finalize(insert) }
            for (targetID, kind) in targetKinds.sorted(by: { $0.key < $1.key }) {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                try bind(insert, 1, targetID)
                try bind(insert, 2, kind.rawValue)
                try bind(insert, 3, "")
                try stepDone(insert)
            }

            if !targetKindFixes.isEmpty {
                let fixTargetKind = try prepare("UPDATE conversations SET kind = ? WHERE id = ?;")
                defer { sqlite3_finalize(fixTargetKind) }
                for (targetID, kind) in targetKindFixes.sorted(by: { $0.key < $1.key }) {
                    sqlite3_reset(fixTargetKind)
                    sqlite3_clear_bindings(fixTargetKind)
                    try bind(fixTargetKind, 1, kind.rawValue)
                    try bind(fixTargetKind, 2, targetID)
                    try stepDone(fixTargetKind)
                    fixedKinds += 1
                }
            }

            let update = try prepare("""
            UPDATE messages
            SET conversation_id = ?, direction = ?, sender_id = ?, sender_name = ?, status = ?
            WHERE id = ?;
            """)
            defer { sqlite3_finalize(update) }
            for move in moves {
                sqlite3_reset(update)
                sqlite3_clear_bindings(update)
                try bind(update, 1, move.targetID)
                try bind(update, 2, move.direction.rawValue)
                try bind(update, 3, move.senderID)
                try bind(update, 4, move.senderName)
                try bind(update, 5, move.status.rawValue)
                try bind(update, 6, move.messageID)
                try stepDone(update)
            }

            // 搬空的嫌疑会话直接删除（含 memories / memory_state 残留）。
            for conversation in suspicious where try removeConversationIfEmpty(conversation.id) {
                removedConversationIDs.append(conversation.id)
            }

            // kind 归一化：`@chatroom` → 群聊，其余 → 私聊。只处理仍然存在的嫌疑会话。
            let removed = Set(removedConversationIDs)
            let fixKind = try prepare("UPDATE conversations SET kind = ? WHERE id = ?;")
            defer { sqlite3_finalize(fixKind) }
            for conversation in suspicious where !removed.contains(conversation.id) {
                // 部分消息被搬走但会话仍有留存消息：预览也要重算。
                affected.insert(conversation.id)
                let expected: ConversationKind = ConversationIdentity.isGroupID(conversation.id)
                    ? .group
                    : .direct
                guard conversation.kind != expected else { continue }
                sqlite3_reset(fixKind)
                sqlite3_clear_bindings(fixKind)
                try bind(fixKind, 1, expected.rawValue)
                try bind(fixKind, 2, conversation.id)
                try stepDone(fixKind)
                fixedKinds += 1
                affected.insert(conversation.id)
            }

            // 搬入消息会改变目标会话预览；kind 改动/留存消息的嫌疑会话也顺带刷新。
            try refreshConversationPreviewRows(conversationIDs: affected)
        }

        guard !moves.isEmpty || !removedConversationIDs.isEmpty || fixedKinds > 0 else {
            return MisroutedConversationRepairResult()
        }
        return MisroutedConversationRepairResult(
            movedMessages: moves.count,
            affectedConversationIDs: affected.sorted(),
            removedConversationIDs: removedConversationIDs.sorted(),
            fixedKinds: fixedKinds
        )
    }

    /// 嫌疑会话：自己 wxid 会话、`wxid_self`/`self` 占位会话、kind=group 但 ID 非群 ID。
    private func suspiciousMisroutedConversations(effectiveSelfID: String) throws -> [Conversation] {
        let statement = try prepare("SELECT id, kind, title FROM conversations;")
        defer { sqlite3_finalize(statement) }
        var result: [Conversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = try text(statement, 0)
            let kind = ConversationKind(rawValue: try text(statement, 1)) ?? .direct
            let title = try text(statement, 2)
            let isSelfConversation = Self.isSameID(id, effectiveSelfID)
            let isPlaceholderSelf = ConversationIdentity.isPlaceholderSelfID(id)
            let isFakeGroup = kind == .group && !ConversationIdentity.isGroupID(id)
            guard isSelfConversation || isPlaceholderSelf || isFakeGroup else { continue }
            result.append(Conversation(id: id, kind: kind, title: title))
        }
        return result
    }

    /// 逐条推导嫌疑会话里能明确归位的消息；推导不出或目标就是当前会话时跳过。
    private func misroutedMoves(
        from conversation: Conversation,
        effectiveSelfID: String
    ) throws -> [MisroutedMove] {
        let statement = try prepare("""
        SELECT id, sender_id, sender_name, raw_json
        FROM messages WHERE conversation_id = ? ORDER BY timestamp ASC;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, conversation.id)

        var moves: [MisroutedMove] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = try text(statement, 0)
            let currentSenderID = try text(statement, 1)
            let currentSenderName = try text(statement, 2)
            guard let raw = optionalText(statement, 3),
                  let object = Self.rawObject(raw),
                  let target = Self.relocationTarget(
                    for: object,
                    sourceID: conversation.id,
                    selfID: effectiveSelfID
                  ) else { continue }

            let outgoing = Self.rawIndicatesOutgoing(object, selfID: effectiveSelfID)
            let movedSenderID: String
            let movedSenderName: String
            let status: DeliveryStatus
            if outgoing {
                movedSenderID = effectiveSelfID
                movedSenderName = "我"
                status = .sent
            } else {
                let rawSenderID = [Self.routingString(object["sender_wxid"]),
                                   Self.routingString(object["user_id"])]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                movedSenderID = rawSenderID.isEmpty ? currentSenderID : rawSenderID
                let rawNickname = (object["sender"] as? [String: Any])
                    .flatMap { Self.routingString($0["nickname"]) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if Self.isReadableSenderName(
                    currentSenderName,
                    senderID: movedSenderID,
                    sourceID: conversation.id,
                    selfID: effectiveSelfID
                ) {
                    movedSenderName = currentSenderName
                } else if Self.isReadableSenderName(
                    rawNickname,
                    senderID: movedSenderID,
                    sourceID: conversation.id,
                    selfID: effectiveSelfID
                ) {
                    movedSenderName = rawNickname
                } else {
                    movedSenderName = currentSenderName
                }
                status = .received
            }

            moves.append(MisroutedMove(
                messageID: messageID,
                targetID: target.id,
                targetKind: target.kind,
                direction: outgoing ? .outgoing : .incoming,
                senderID: movedSenderID,
                senderName: movedSenderName,
                status: status
            ))
        }
        return moves
    }

    /// 目标推导：优先 `@chatroom` 群（group_id / to_wxid / pat_chat_wxid），
    /// 其次私聊对象（from_wxid、to_wxid、target_id/self_id）。
    private static func relocationTarget(
        for object: [String: Any],
        sourceID: String,
        selfID: String
    ) -> (id: String, kind: ConversationKind)? {
        let groupFields = ["group_id", "to_wxid", "pat_chat_wxid"]
        for field in groupFields {
            guard let raw = routingString(object[field]) else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ConversationIdentity.isGroupID(value) else { continue }
            // raw 明确指向当前会话：已经在正确群里，保持原样。
            if isSameID(value, sourceID) { return nil }
            if isSameID(value, selfID) { continue }
            return (value, .group)
        }

        // 私聊对象兜底：可辨认、不是自己、且不是当前会话。
        let peerFields = ["from_wxid", "to_wxid", "target_id", "self_id"]
        for field in peerFields {
            guard let raw = routingString(object[field]) else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ConversationIdentity.isPlausiblePeerID(value),
                  !isSameID(value, selfID),
                  !isSameID(value, sourceID) else { continue }
            return (value, .direct)
        }
        return nil
    }

    /// 方向判定：显式 `is_self`，或 from/sender_wxid 等于当前账号。
    private static func rawIndicatesOutgoing(_ object: [String: Any], selfID: String) -> Bool {
        if boolValue(object["is_self"]) == true { return true }
        for key in ["from_wxid", "sender_wxid"] {
            if let value = routingString(object[key]), isSameID(value, selfID) { return true }
        }
        return false
    }

    private static func rawObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func routingString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        // JSONSerialization 的 true/false 是 NSNumber(__NSCFBoolean)；只接受 0/1，
        // 避免把普通数字误当布尔（与 `OneBotEventParser` 保持一致）。
        if let number = value as? NSNumber {
            switch number.intValue {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }
        return value as? Bool
    }

    private static func isSameID(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// 昵称是否可读（不是「我/自己」、裸 wxid、群 ID、占位自己、会话/账号 ID）。
    private static func isReadableSenderName(
        _ name: String,
        senderID: String,
        sourceID: String,
        selfID: String
    ) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if value == "我" || value == "自己" { return false }
        if ConversationIdentity.isPlaceholderSelfID(value) { return false }
        if ConversationIdentity.isGroupID(value) { return false }
        let lower = value.lowercased()
        if lower.hasPrefix("wxid_") || lower.hasPrefix("gh_") { return false }
        if !senderID.isEmpty, lower == senderID.lowercased() { return false }
        if lower == sourceID.lowercased() || lower == selfID.lowercased() { return false }
        return true
    }

    /// 从历史事件反推当前账号 wxid。
    ///
    /// 普通入站消息的 `self_id` 恒为当前账号，而 `user_id` 是不同好友/群成员；
    /// 被旧 bug 误路由的自消息里 `self_id` 是收件人、`user_id` 才是账号。
    /// 因此「作为 self_id 出现在多个不同发送者消息里」的候选就是账号；
    /// 好友只会作为 self_id 出现在自己发出的那几条上（发送者单一）。
    /// 置信不足时返回 nil，调用方回退到传入的 selfID、不冒险搬数据。
    private func inferAccountIDFromRawEvents() throws -> String? {
        let statement = try prepare("SELECT raw_json FROM messages WHERE raw_json IS NOT NULL;")
        defer { sqlite3_finalize(statement) }
        var counts: [String: Int] = [:]
        var senders: [String: Set<String>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = optionalText(statement, 0),
                  let data = raw.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            let candidate = (object["self_id"] as? String) ?? ""
            let sender = (object["user_id"] as? String)
                ?? ((object["sender"] as? [String: Any])?["user_id"] as? String)
                ?? ""
            // 旧 bridge/设置把 self_id 污染成 `wxid_self`/`self` 时，绝不能把它
            // 反推成账号；群 ID 也不是账号。
            guard !candidate.isEmpty,
                  !ConversationIdentity.isPlaceholderSelfID(candidate),
                  !ConversationIdentity.isGroupID(candidate),
                  candidate != sender else { continue }
            counts[candidate, default: 0] += 1
            if !sender.isEmpty { senders[candidate, default: []].insert(sender) }
        }
        let ranked = counts.keys.sorted { lhs, rhs in
            let left = senders[lhs]?.count ?? 0
            let right = senders[rhs]?.count ?? 0
            if left != right { return left > right }
            return (counts[lhs] ?? 0) > (counts[rhs] ?? 0)
        }
        guard let top = ranked.first,
              (counts[top] ?? 0) >= 3,
              (senders[top]?.count ?? 0) >= 2 else { return nil }
        if ranked.count > 1 {
            let second = ranked[1]
            let topDistinct = senders[top]?.count ?? 0
            let secondDistinct = senders[second]?.count ?? 0
            if topDistinct == secondDistinct, (counts[top] ?? 0) <= (counts[second] ?? 0) {
                return nil
            }
        }
        return top
    }

    /// 清理旧版本写入的裸 ID 标题（`wxid_*` / `*@chatroom` / `wxid==id` / 「群聊 <id>」）。
    ///
    /// 旧 App 直接把事件里的 wxid 写成 `conversations.title`，这些值会渗透到列表、
    /// AI 提示词与日志。展示层已兜底，这里把库里也恢复为「空标题 = 自动名称」。
    /// 只清理占位值，用户重命名或真实昵称保持不变；幂等，返回更新的行数。
    func repairPlaceholderConversationTitles() throws -> Int {
        try ensureOpen()
        let select = try prepare("SELECT id, kind, title FROM conversations;")
        defer { sqlite3_finalize(select) }

        var targets: [String] = []
        while sqlite3_step(select) == SQLITE_ROW {
            let id = try text(select, 0)
            let kind = ConversationKind(rawValue: try text(select, 1)) ?? .direct
            let title = try text(select, 2)
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if ConversationName.isPlaceholderTitle(title, conversationID: id, kind: kind) {
                targets.append(id)
            }
        }
        guard !targets.isEmpty else { return 0 }

        let update = try prepare("UPDATE conversations SET title = '' WHERE id = ?;")
        defer { sqlite3_finalize(update) }
        var changed = 0
        try transaction {
            for id in targets {
                sqlite3_reset(update)
                sqlite3_clear_bindings(update)
                try bind(update, 1, id)
                try stepDone(update)
                changed += 1
            }
        }
        return changed
    }

    /// Assumes an open database and an active transaction.
    private func refreshConversationPreviewRows(conversationIDs: Set<String>) throws {
        guard !conversationIDs.isEmpty else { return }
        let select = try prepare("""
        SELECT text, timestamp, kind FROM messages
        WHERE conversation_id = ? ORDER BY timestamp DESC LIMIT 1;
        """)
        defer { sqlite3_finalize(select) }
        let update = try prepare("""
        UPDATE conversations SET last_message_at = ?, last_message_preview = ? WHERE id = ?;
        """)
        defer { sqlite3_finalize(update) }
        for id in conversationIDs {
            sqlite3_reset(select)
            sqlite3_clear_bindings(select)
            try bind(select, 1, id)
            guard sqlite3_step(select) == SQLITE_ROW else { continue }
            let previewText = try text(select, 0)
            let timestamp = sqlite3_column_double(select, 1)
            let kind = try text(select, 2)
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
            let preview = previewText.isEmpty ? "[\(kind)]" : String(previewText.prefix(80))
            try bind(update, 1, timestamp)
            try bind(update, 2, preview)
            try bind(update, 3, id)
            try stepDone(update)
        }
    }

    /// Assumes an open database and an active transaction.
    /// Returns true when the conversation row was removed.
    @discardableResult
    private func removeConversationIfEmpty(_ conversationID: String) throws -> Bool {
        let count = try prepare("SELECT COUNT(*) FROM messages WHERE conversation_id = ?;")
        defer { sqlite3_finalize(count) }
        try bind(count, 1, conversationID)
        guard sqlite3_step(count) == SQLITE_ROW, int(count, 0) == 0 else { return false }
        for sql in [
            "DELETE FROM conversations WHERE id = ?;",
            "DELETE FROM memories WHERE conversation_id = ?;",
            "DELETE FROM memory_state WHERE conversation_id = ?;"
        ] {
            let delete = try prepare(sql)
            defer { sqlite3_finalize(delete) }
            try bind(delete, 1, conversationID)
            try stepDone(delete)
        }
        return true
    }

    private func executeConversationUpsert(_ conversations: [Conversation]) throws {
        try transaction {
            try upsertConversationRows(conversations)
        }
    }

    /// Assumes an open database and an active transaction.
    private func upsertConversationRows(_ conversations: [Conversation]) throws {
        guard !conversations.isEmpty else { return }
        let sql = """
        INSERT INTO conversations (
            id, kind, title, subtitle, unread_count, last_message_at, last_message_preview,
            ai_enabled, provider_id, model, persona_id, is_pinned, is_muted, note, working_hours
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            title = excluded.title,
            subtitle = excluded.subtitle,
            unread_count = excluded.unread_count,
            last_message_at = excluded.last_message_at,
            last_message_preview = excluded.last_message_preview,
            ai_enabled = excluded.ai_enabled,
            provider_id = excluded.provider_id,
            model = excluded.model,
            persona_id = excluded.persona_id,
            is_pinned = excluded.is_pinned,
            is_muted = excluded.is_muted,
            note = excluded.note,
            working_hours = excluded.working_hours;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for conversation in conversations {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(statement, 1, conversation.id)
            try bind(statement, 2, conversation.kind.rawValue)
            try bind(statement, 3, conversation.title)
            try bind(statement, 4, conversation.subtitle)
            try bind(statement, 5, Int32(conversation.unreadCount))
            try bind(statement, 6, conversation.lastMessageAt?.timeIntervalSince1970)
            try bind(statement, 7, conversation.lastMessagePreview)
            try bind(statement, 8, Int32(conversation.aiEnabled ? 1 : 0))
            try bind(statement, 9, conversation.providerID)
            try bind(statement, 10, conversation.model)
            try bind(statement, 11, conversation.personaID)
            try bind(statement, 12, Int32(conversation.isPinned ? 1 : 0))
            try bind(statement, 13, Int32(conversation.isMuted ? 1 : 0))
            try bind(statement, 14, conversation.note)
            try bind(statement, 15, encodeWorkingHours(conversation.workingHours))
            try stepDone(statement)
        }
    }

    private func decodeConversation(_ statement: OpaquePointer?) throws -> Conversation {
        Conversation(
            id: try text(statement, 0),
            kind: ConversationKind(rawValue: try text(statement, 1)) ?? .direct,
            title: try text(statement, 2),
            subtitle: optionalText(statement, 3),
            unreadCount: Int(int(statement, 4)),
            lastMessageAt: optionalDate(statement, 5),
            lastMessagePreview: try text(statement, 6),
            aiEnabled: int(statement, 7) != 0,
            providerID: optionalText(statement, 8),
            model: optionalText(statement, 9),
            personaID: optionalText(statement, 10),
            isPinned: int(statement, 11) != 0,
            isMuted: int(statement, 12) != 0,
            note: try text(statement, 13),
            workingHours: decodeWorkingHours(optionalText(statement, 14))
        )
    }

    private func encodeWorkingHours(_ hours: WorkingHours?) -> String? {
        guard let hours, let data = try? JSONEncoder().encode(hours) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeWorkingHours(_ text: String?) -> WorkingHours? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkingHours.self, from: data)
    }

    // MARK: - Messages

    /// Batched insert/upsert. Used for inbound events and outbound status updates.
    func upsertMessages(_ messages: [ChatMessage]) throws {
        guard !messages.isEmpty else { return }
        try ensureOpen()
        try transaction {
            try upsertMessageRows(messages)
        }
    }

    /// Persists one event atomically: conversation metadata + message(s) in a single
    /// transaction instead of two round trips (one fsync/commit per inbound message).
    func upsertConversationAndMessages(_ conversation: Conversation, _ messages: [ChatMessage]) throws {
        try ensureOpen()
        try transaction {
            try upsertConversationRows([conversation])
            try upsertMessageRows(messages)
        }
    }

    /// Assumes an open database and an active transaction.
    private func upsertMessageRows(_ messages: [ChatMessage]) throws {
        guard !messages.isEmpty else { return }
        let sql = """
        INSERT INTO messages (
            id, conversation_id, sender_id, sender_name, direction, kind, text,
            media_path, media_url, timestamp, status, reply_to_id, raw_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            conversation_id = excluded.conversation_id,
            sender_id = excluded.sender_id,
            sender_name = excluded.sender_name,
            direction = excluded.direction,
            kind = excluded.kind,
            text = excluded.text,
            media_path = excluded.media_path,
            media_url = excluded.media_url,
            timestamp = excluded.timestamp,
            status = excluded.status,
            reply_to_id = excluded.reply_to_id,
            raw_json = excluded.raw_json;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for message in messages {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(statement, 1, message.id)
            try bind(statement, 2, message.conversationID)
            try bind(statement, 3, message.senderID)
            try bind(statement, 4, message.senderName)
            try bind(statement, 5, message.direction.rawValue)
            try bind(statement, 6, message.kind.rawValue)
            try bind(statement, 7, message.text)
            try bind(statement, 8, message.mediaPath)
            try bind(statement, 9, message.mediaURL)
            try bind(statement, 10, message.timestamp.timeIntervalSince1970)
            try bind(statement, 11, message.status.rawValue)
            try bind(statement, 12, message.replyToID)
            try bind(statement, 13, message.rawJSON)
            try stepDone(statement)
        }
    }

    /// Latest page for many conversations in **one** SQL query (startup preload).
    ///
    /// Uses the existing `(conversation_id, timestamp DESC)` index: one indexed lookup
    /// per conversation finds the page cutoff, the outer scan then returns only the
    /// newest `limit` rows per conversation. Replaces the previous N+1 pattern
    /// (one `fetchMessages` per conversation).
    func fetchLatestMessages(conversationIDs: [String], perConversation limit: Int = 30) throws -> [String: [ChatMessage]] {
        let ids = Array(conversationIDs.prefix(500))
        guard !ids.isEmpty else { return [:] }
        try ensureOpen()
        let boundedLimit = max(1, min(limit, 500))
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
        SELECT m.id, m.conversation_id, m.sender_id, m.sender_name, m.direction, m.kind, m.text,
               m.media_path, m.media_url, m.timestamp, m.status, m.reply_to_id, m.raw_json
        FROM messages m
        WHERE m.conversation_id IN (\(placeholders))
          AND m.timestamp >= COALESCE((
              SELECT m2.timestamp FROM messages m2
              WHERE m2.conversation_id = m.conversation_id
              ORDER BY m2.timestamp DESC LIMIT 1 OFFSET ?
          ), -1.0e18)
        ORDER BY m.conversation_id ASC, m.timestamp ASC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, id) in ids.enumerated() {
            try bind(statement, Int32(index + 1), id)
        }
        try bind(statement, Int32(ids.count + 1), Int32(boundedLimit - 1))
        var grouped: [String: [ChatMessage]] = [:]
        grouped.reserveCapacity(ids.count)
        for id in ids { grouped[id] = [] }
        while sqlite3_step(statement) == SQLITE_ROW {
            let message = try decodeMessage(statement)
            grouped[message.conversationID, default: []].append(message)
        }
        // Equal timestamps at the cutoff can return a few extra rows; keep the newest page.
        for (id, list) in grouped where list.count > boundedLimit {
            grouped[id] = Array(list.suffix(boundedLimit))
        }
        return grouped
    }

    /// Page of messages in chronological order (oldest → newest inside the page).
    /// Pass `before` to walk backwards through history.
    func fetchMessages(conversationID: String, limit: Int = 50, before: Date? = nil) throws -> [ChatMessage] {
        try ensureOpen()
        let boundedLimit = Int32(max(1, min(limit, 500)))
        let sql: String
        var bindBefore = false
        if before != nil {
            sql = """
            SELECT id, conversation_id, sender_id, sender_name, direction, kind, text,
                   media_path, media_url, timestamp, status, reply_to_id, raw_json
            FROM messages WHERE conversation_id = ? AND timestamp < ?
            ORDER BY timestamp DESC LIMIT ?;
            """
            bindBefore = true
        } else {
            sql = """
            SELECT id, conversation_id, sender_id, sender_name, direction, kind, text,
                   media_path, media_url, timestamp, status, reply_to_id, raw_json
            FROM messages WHERE conversation_id = ?
            ORDER BY timestamp DESC LIMIT ?;
            """
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, conversationID)
        if bindBefore, let before {
            try bind(statement, 2, before.timeIntervalSince1970)
            try bind(statement, 3, boundedLimit)
        } else {
            try bind(statement, 2, boundedLimit)
        }
        var rows: [ChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(try decodeMessage(statement))
        }
        return Array(rows.reversed())
    }

    func message(id: String) throws -> ChatMessage? {
        try ensureOpen()
        let statement = try prepare("""
        SELECT id, conversation_id, sender_id, sender_name, direction, kind, text,
               media_path, media_url, timestamp, status, reply_to_id, raw_json
        FROM messages WHERE id = ? LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeMessage(statement)
    }

    /// Full-text-ish search over message text. Newest first.
    func searchMessages(query: String, limit: Int = 100) throws -> [MemorySearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        try ensureOpen()
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let statement = try prepare("""
        SELECT m.id, m.conversation_id, m.sender_id, m.sender_name, m.direction, m.kind, m.text,
               m.media_path, m.media_url, m.timestamp, m.status, m.reply_to_id, m.raw_json,
               COALESCE(c.title, '')
        FROM messages m
        LEFT JOIN conversations c ON c.id = m.conversation_id
        WHERE m.text LIKE ? ESCAPE '\\'
        ORDER BY m.timestamp DESC
        LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, "%\(escaped)%")
        try bind(statement, 2, Int32(max(1, limit)))
        var hits: [MemorySearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let message = try decodeMessage(statement)
            let title = optionalText(statement, 13) ?? ""
            hits.append(MemorySearchHit(message: message, conversationTitle: title))
        }
        return hits
    }

    func messageCount(conversationID: String? = nil) throws -> Int {
        try ensureOpen()
        let sql = conversationID == nil
            ? "SELECT COUNT(*) FROM messages;"
            : "SELECT COUNT(*) FROM messages WHERE conversation_id = ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let conversationID { try bind(statement, 1, conversationID) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(int(statement, 0))
    }

    private func decodeMessage(_ statement: OpaquePointer?) throws -> ChatMessage {
        ChatMessage(
            id: try text(statement, 0),
            conversationID: try text(statement, 1),
            senderID: try text(statement, 2),
            senderName: try text(statement, 3),
            direction: ChatDirection(rawValue: try text(statement, 4)) ?? .incoming,
            kind: MessageKind(rawValue: try text(statement, 5)) ?? .text,
            text: try text(statement, 6),
            mediaPath: optionalText(statement, 7),
            mediaURL: optionalText(statement, 8),
            timestamp: date(statement, 9),
            status: DeliveryStatus(rawValue: try text(statement, 10)) ?? .received,
            replyToID: optionalText(statement, 11),
            rawJSON: optionalText(statement, 12)
        )
    }

    /// Deletes one message and refreshes the owning conversation's preview lazily via
    /// `refreshConversationPreview` from the runtime.
    func deleteMessage(id: String) throws {
        try ensureOpen()
        let statement = try prepare("DELETE FROM messages WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, id)
        try stepDone(statement)
    }

    /// Deletes all messages of one conversation and resets its preview fields.
    func clearMessages(conversationID: String) throws {
        try ensureOpen()
        try transaction {
            let delete = try prepare("DELETE FROM messages WHERE conversation_id = ?;")
            defer { sqlite3_finalize(delete) }
            try bind(delete, 1, conversationID)
            try stepDone(delete)

            let reset = try prepare("""
            UPDATE conversations
            SET last_message_at = NULL, last_message_preview = '', unread_count = 0
            WHERE id = ?;
            """)
            defer { sqlite3_finalize(reset) }
            try bind(reset, 1, conversationID)
            try stepDone(reset)

            let resetState = try prepare("DELETE FROM memory_state WHERE conversation_id = ?;")
            defer { sqlite3_finalize(resetState) }
            try bind(resetState, 1, conversationID)
            try stepDone(resetState)
        }
    }

    /// Deletes every message and resets conversation previews.
    func clearAllMessages() throws {
        try ensureOpen()
        try transaction {
            try execute("DELETE FROM messages;")
            try execute("""
            UPDATE conversations
            SET last_message_at = NULL, last_message_preview = '', unread_count = 0;
            """)
            try execute("DELETE FROM memory_state;")
        }
    }

    /// Total number of conversations (diagnostics / stats).
    func conversationCount() throws -> Int {
        try ensureOpen()
        let statement = try prepare("SELECT COUNT(*) FROM conversations;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(int(statement, 0))
    }

    // MARK: - Long-term memories

    func upsertMemory(_ memory: LongTermMemory) throws {
        try ensureOpen()
        let statement = try prepare("""
        INSERT INTO memories (
            id, conversation_id, summary, is_core, base_weight,
            created_at, updated_at, last_accessed_at, source_count, source, access_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            conversation_id = excluded.conversation_id,
            summary = excluded.summary,
            is_core = excluded.is_core,
            base_weight = excluded.base_weight,
            updated_at = excluded.updated_at,
            last_accessed_at = excluded.last_accessed_at,
            source_count = excluded.source_count,
            source = excluded.source,
            access_count = excluded.access_count;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, memory.id)
        try bind(statement, 2, memory.conversationID)
        try bind(statement, 3, memory.summary)
        try bind(statement, 4, Int32(memory.isCore ? 1 : 0))
        try bind(statement, 5, memory.baseWeight)
        try bind(statement, 6, memory.createdAt.timeIntervalSince1970)
        try bind(statement, 7, memory.updatedAt.timeIntervalSince1970)
        try bind(statement, 8, memory.lastAccessedAt?.timeIntervalSince1970)
        try bind(statement, 9, Int32(memory.sourceCount))
        try bind(statement, 10, memory.source)
        try bind(statement, 11, Int32(memory.accessCount))
        try stepDone(statement)
    }

    func fetchMemories(limit: Int = 500, search: String? = nil) throws -> [LongTermMemory] {
        try ensureOpen()
        let keyword = (search ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        if keyword.isEmpty {
            sql = """
            SELECT m.id, m.conversation_id, COALESCE(c.title, ''), m.summary, m.is_core,
                   m.base_weight, m.created_at, m.updated_at, m.last_accessed_at,
                   m.source_count, m.source, m.access_count
            FROM memories m LEFT JOIN conversations c ON c.id = m.conversation_id
            ORDER BY m.is_core DESC, m.updated_at DESC LIMIT ?;
            """
        } else {
            sql = """
            SELECT m.id, m.conversation_id, COALESCE(c.title, ''), m.summary, m.is_core,
                   m.base_weight, m.created_at, m.updated_at, m.last_accessed_at,
                   m.source_count, m.source, m.access_count
            FROM memories m LEFT JOIN conversations c ON c.id = m.conversation_id
            WHERE m.summary LIKE ? ESCAPE '\\'
            ORDER BY m.is_core DESC, m.updated_at DESC LIMIT ?;
            """
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if keyword.isEmpty {
            try bind(statement, 1, Int32(max(1, limit)))
        } else {
            let escaped = keyword
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            try bind(statement, 1, "%\(escaped)%")
            try bind(statement, 2, Int32(max(1, limit)))
        }
        var result: [LongTermMemory] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeMemory(statement))
        }
        return result.sorted {
            if $0.isCore != $1.isCore { return $0.isCore && !$1.isCore }
            return $0.timeWeight() > $1.timeWeight()
        }
    }

    /// 提示词用：当前会话记忆 + 全局记忆，按核心优先、手写次之、时间权重降序。
    /// 核心记忆同样遵守作用域：其他会话的核心记忆不会注入本会话。
    func fetchMemoriesForPrompt(conversationID: String, limit: Int = 6, now: Date = Date()) throws -> [LongTermMemory] {
        try ensureOpen()
        let statement = try prepare("""
        SELECT m.id, m.conversation_id, COALESCE(c.title, ''), m.summary, m.is_core,
               m.base_weight, m.created_at, m.updated_at, m.last_accessed_at,
               m.source_count, m.source, m.access_count
        FROM memories m LEFT JOIN conversations c ON c.id = m.conversation_id
        WHERE m.conversation_id = ? OR m.conversation_id = ''
        ORDER BY m.is_core DESC, m.updated_at DESC LIMIT 200;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, conversationID)
        var candidates: [LongTermMemory] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            candidates.append(try decodeMemory(statement))
        }
        candidates.sort {
            if $0.isCore != $1.isCore { return $0.isCore && !$1.isCore }
            let lManual = $0.source == "manual", rManual = $1.source == "manual"
            if lManual != rManual { return lManual }
            let l = $0.timeWeight(now: now), r = $1.timeWeight(now: now)
            if abs(l - r) > 0.000001 { return l > r }
            return $0.updatedAt > $1.updatedAt
        }
        var result: [LongTermMemory] = []
        var seen = Set<String>()
        for memory in candidates where !memory.summary.isEmpty {
            if seen.insert(memory.summary).inserted { result.append(memory) }
            if result.count >= limit { break }
        }
        return result
    }

    /// 同一会话最新一条自动滚动总结（`source = summary` 且非核心）。
    func latestAutoMemory(conversationID: String) throws -> LongTermMemory? {
        try ensureOpen()
        let statement = try prepare("""
        SELECT m.id, m.conversation_id, COALESCE(c.title, ''), m.summary, m.is_core,
               m.base_weight, m.created_at, m.updated_at, m.last_accessed_at,
               m.source_count, m.source, m.access_count
        FROM memories m LEFT JOIN conversations c ON c.id = m.conversation_id
        WHERE m.conversation_id = ? AND m.source = 'summary' AND m.is_core = 0
        ORDER BY m.updated_at DESC LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, conversationID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeMemory(statement)
    }

    /// 同一会话的全部自动滚动总结，按 `updated_at` 降序。
    /// 正常情况下只有一条；历史版本可能留下多条，由 ChatEngine 合并清理。
    func autoMemories(conversationID: String) throws -> [LongTermMemory] {
        try ensureOpen()
        let statement = try prepare("""
        SELECT m.id, m.conversation_id, COALESCE(c.title, ''), m.summary, m.is_core,
               m.base_weight, m.created_at, m.updated_at, m.last_accessed_at,
               m.source_count, m.source, m.access_count
        FROM memories m LEFT JOIN conversations c ON c.id = m.conversation_id
        WHERE m.conversation_id = ? AND m.source = 'summary' AND m.is_core = 0
        ORDER BY m.updated_at DESC, m.created_at DESC;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, conversationID)
        var result: [LongTermMemory] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeMemory(statement))
        }
        return result
    }

    /// 同一会话的用户手写记忆（非核心），按更新时间降序。
    /// 自动总结会把它们作为权威参考传入合并提示，但不覆盖手写内容。
    func manualMemories(conversationID: String) throws -> [LongTermMemory] {
        try ensureOpen()
        let statement = try prepare("""
        SELECT m.id, m.conversation_id, COALESCE(c.title, ''), m.summary, m.is_core,
               m.base_weight, m.created_at, m.updated_at, m.last_accessed_at,
               m.source_count, m.source, m.access_count
        FROM memories m LEFT JOIN conversations c ON c.id = m.conversation_id
        WHERE m.conversation_id = ? AND m.source = 'manual' AND m.is_core = 0
        ORDER BY m.updated_at DESC;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, conversationID)
        var result: [LongTermMemory] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeMemory(statement))
        }
        return result
    }

    /// 记录记忆被提示词召回：`access_count + 1` 并刷新 `last_accessed_at`。
    /// 只影响使用强化与衰减锚点，不修改摘要或 `updated_at`。
    func recordMemoryAccess(ids: [String], at date: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        try ensureOpen()
        let statement = try prepare("""
        UPDATE memories
        SET access_count = access_count + 1, last_accessed_at = ?
        WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try transaction {
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(statement, 1, date.timeIntervalSince1970)
                try bind(statement, 2, id)
                try stepDone(statement)
            }
        }
    }

    func deleteMemory(id: String) throws {
        try ensureOpen()
        let statement = try prepare("DELETE FROM memories WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, id)
        try stepDone(statement)
    }

    func memoryCount(conversationID: String? = nil) throws -> Int {
        try ensureOpen()
        let sql = conversationID == nil
            ? "SELECT COUNT(*) FROM memories;"
            : "SELECT COUNT(*) FROM memories WHERE conversation_id = ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let conversationID { try bind(statement, 1, conversationID) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(int(statement, 0))
    }

    /// 保留最近 `keep` 条消息；返回更早、尚未总结的一批消息。
    ///
    /// - Parameters:
    ///   - keep: 短期窗口保留的消息条数（默认 10）。
    ///   - minOverflow: 游标与 cutoff 之间未总结消息数低于该值时返回 nil，
    ///     用于“攒够一批再总结”，避免每条新消息都触发一次 AI 调用。
    ///   - maxMessages: 单批最多总结的消息条数，多出的部分留在下一批。
    func pendingMemoryOverflow(
        conversationID: String,
        keep: Int = 10,
        minOverflow: Int = 1,
        maxMessages: Int = 20
    ) throws -> MemoryOverflow? {
        try ensureOpen()
        let total = try messageCount(conversationID: conversationID)
        guard total > keep else { return nil }

        let cutoffStatement = try prepare("""
        SELECT rowid FROM messages WHERE conversation_id = ?
        ORDER BY rowid ASC LIMIT 1 OFFSET ?;
        """)
        defer { sqlite3_finalize(cutoffStatement) }
        try bind(cutoffStatement, 1, conversationID)
        try bind(cutoffStatement, 2, Int32(max(0, total - keep)))
        guard sqlite3_step(cutoffStatement) == SQLITE_ROW else { return nil }
        let cutoffRowID = sqlite3_column_int64(cutoffStatement, 0)

        let cursorStatement = try prepare("SELECT last_summarized_rowid FROM memory_state WHERE conversation_id = ? LIMIT 1;")
        defer { sqlite3_finalize(cursorStatement) }
        try bind(cursorStatement, 1, conversationID)
        let cursor: Int64 = sqlite3_step(cursorStatement) == SQLITE_ROW ? sqlite3_column_int64(cursorStatement, 0) : 0
        guard cursor < cutoffRowID else { return nil }

        // 游标与 cutoff 之间未总结的消息总数（不受 maxMessages 限制），
        // 用于判断是否攒够一批。
        let countStatement = try prepare("""
        SELECT COUNT(*) FROM messages
        WHERE conversation_id = ? AND rowid > ? AND rowid < ?;
        """)
        defer { sqlite3_finalize(countStatement) }
        try bind(countStatement, 1, conversationID)
        try bind(countStatement, 2, cursor)
        try bind(countStatement, 3, cutoffRowID)
        guard sqlite3_step(countStatement) == SQLITE_ROW else { return nil }
        let pendingCount = Int(sqlite3_column_int64(countStatement, 0))
        guard pendingCount >= max(1, minOverflow) else { return nil }

        let statement = try prepare("""
        SELECT id, conversation_id, sender_id, sender_name, direction, kind, text,
               media_path, media_url, timestamp, status, reply_to_id, raw_json, rowid
        FROM messages
        WHERE conversation_id = ? AND rowid > ? AND rowid < ?
        ORDER BY rowid ASC LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, conversationID)
        try bind(statement, 2, cursor)
        try bind(statement, 3, cutoffRowID)
        try bind(statement, 4, Int32(max(1, maxMessages)))

        var messages: [ChatMessage] = []
        var lastRowID: Int64 = cursor
        while sqlite3_step(statement) == SQLITE_ROW {
            messages.append(try decodeMessage(statement))
            lastRowID = sqlite3_column_int64(statement, 13)
        }
        guard !messages.isEmpty else { return nil }
        return MemoryOverflow(messages: messages, lastRowID: lastRowID)
    }

    func markMemorySummarized(conversationID: String, throughRowID: Int64) throws {
        try ensureOpen()
        let statement = try prepare("""
        INSERT INTO memory_state (conversation_id, last_summarized_rowid, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(conversation_id) DO UPDATE SET
            last_summarized_rowid = excluded.last_summarized_rowid,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, conversationID)
        try bind(statement, 2, throughRowID)
        try bind(statement, 3, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    func resetMemoryState(conversationID: String) throws {
        try ensureOpen()
        let statement = try prepare("DELETE FROM memory_state WHERE conversation_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, conversationID)
        try stepDone(statement)
    }

    private func decodeMemory(_ statement: OpaquePointer?) throws -> LongTermMemory {
        LongTermMemory(
            id: try text(statement, 0),
            conversationID: try text(statement, 1),
            conversationTitle: try text(statement, 2),
            summary: try text(statement, 3),
            isCore: int(statement, 4) != 0,
            baseWeight: sqlite3_column_double(statement, 5),
            createdAt: date(statement, 6),
            updatedAt: date(statement, 7),
            lastAccessedAt: optionalDate(statement, 8),
            sourceCount: Int(int(statement, 9)),
            accessCount: Int(int(statement, 11)),
            source: try text(statement, 10)
        )
    }

    // MARK: - Logs

    func appendLogs(_ entries: [LogEntry]) throws {
        guard !entries.isEmpty else { return }
        try ensureOpen()
        let sql = "INSERT OR REPLACE INTO logs (id, date, level, source, message) VALUES (?, ?, ?, ?, ?);"
        try transaction {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            for entry in entries {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(statement, 1, entry.id)
                try bind(statement, 2, entry.date.timeIntervalSince1970)
                try bind(statement, 3, entry.level.rawValue)
                try bind(statement, 4, entry.source)
                try bind(statement, 5, entry.message)
                try stepDone(statement)
            }
        }
    }

    /// Newest first. `level` filters to that severity and above.
    func fetchLogs(limit: Int = 500, minimumLevel: LogLevel? = nil) throws -> [LogEntry] {
        try ensureOpen()
        let allowedLevels = LogLevel.allCases
            .filter { level in
                guard let minimumLevel else { return true }
                return level.severityRank >= minimumLevel.severityRank
            }
            .map(\.rawValue)
        let placeholders = Array(repeating: "?", count: allowedLevels.count).joined(separator: ",")
        let sql = """
        SELECT id, date, level, source, message FROM logs
        WHERE level IN (\(placeholders))
        ORDER BY date DESC LIMIT ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, level) in allowedLevels.enumerated() {
            try bind(statement, Int32(index + 1), level)
        }
        try bind(statement, Int32(allowedLevels.count + 1), Int32(max(1, limit)))
        var result: [LogEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(LogEntry(
                id: try text(statement, 0),
                date: date(statement, 1),
                level: LogLevel(rawValue: try text(statement, 2)) ?? .info,
                source: try text(statement, 3),
                message: try text(statement, 4)
            ))
        }
        return result
    }

    /// Ring-buffer behaviour on disk: keeps only the newest `keep` rows.
    func pruneLogs(keep: Int = 5000) throws {
        try ensureOpen()
        let statement = try prepare("""
        DELETE FROM logs WHERE id NOT IN (
            SELECT id FROM logs ORDER BY date DESC LIMIT ?
        );
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, Int32(max(1, keep)))
        try stepDone(statement)
    }

    // MARK: - Contact directory

    /// 最近一次成功抓取并缓存的通讯录目录；没有缓存时返回 nil。
    ///
    /// 缓存只存成功快照（失败目录不落库），`kind` 决定条目回到 `users` 还是 `groups`。
    func loadContactDirectory() throws -> ContactDirectorySnapshot? {
        try ensureOpen()
        let statement = try prepare("""
        SELECT username, display, nickname, remark, kind, updated_at FROM contact_directory;
        """)
        defer { sqlite3_finalize(statement) }
        var users: [String: ContactDirectoryEntry] = [:]
        var groups: [String: ContactDirectoryEntry] = [:]
        var generatedAt: Date?
        while sqlite3_step(statement) == SQLITE_ROW {
            let username = try text(statement, 0)
            let entry = ContactDirectoryEntry(
                display: try text(statement, 1),
                nickname: optionalText(statement, 2),
                remark: optionalText(statement, 3)
            )
            if (try text(statement, 4)) == ConversationKind.group.rawValue {
                groups[username] = entry
            } else {
                users[username] = entry
            }
            let updatedAt = date(statement, 5)
            generatedAt = max(generatedAt ?? updatedAt, updatedAt)
        }
        guard !(users.isEmpty && groups.isEmpty) else { return nil }
        return ContactDirectorySnapshot(ok: true, generatedAt: generatedAt, users: users, groups: groups)
    }

    /// 事务内全量替换通讯录目录缓存。
    ///
    /// 失败态快照（`ok == false`）直接忽略，避免一次拿不到 DB key 就把可用缓存清空；
    /// 读不到目录时 App 行为与没有该功能时完全一致。
    func replaceContactDirectory(_ snapshot: ContactDirectorySnapshot) throws {
        guard snapshot.ok else { return }
        try ensureOpen()
        let updatedAt = (snapshot.generatedAt ?? Date()).timeIntervalSince1970
        let buckets: [(ConversationKind, [String: ContactDirectoryEntry])] = [
            (.direct, snapshot.users),
            (.group, snapshot.groups)
        ]
        try transaction {
            try execute("DELETE FROM contact_directory;")
            let statement = try prepare("""
            INSERT OR REPLACE INTO contact_directory
                (username, display, nickname, remark, kind, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(statement) }
            for (kind, entries) in buckets {
                for (username, entry) in entries {
                    guard !username.isEmpty else { continue }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(statement, 1, username)
                    try bind(statement, 2, entry.display)
                    try bind(statement, 3, entry.nickname)
                    try bind(statement, 4, entry.remark)
                    try bind(statement, 5, kind.rawValue)
                    try bind(statement, 6, updatedAt)
                    try stepDone(statement)
                }
            }
        }
    }

    // MARK: - Schedules

    func replaceSchedules(_ schedules: [ScheduledTask]) throws {
        try ensureOpen()
        try transaction {
            try execute("DELETE FROM schedules;")
            let sql = """
            INSERT OR REPLACE INTO schedules (
                id, name, enabled, conversation_id, conversation_title, kind, content,
                repeat_rule, fire_at, weekdays, last_fired_at, next_fire_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            for task in schedules {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(statement, 1, task.id)
                try bind(statement, 2, task.name)
                try bind(statement, 3, Int32(task.enabled ? 1 : 0))
                try bind(statement, 4, task.conversationID)
                try bind(statement, 5, task.conversationTitle)
                try bind(statement, 6, task.kind.rawValue)
                try bind(statement, 7, task.content)
                try bind(statement, 8, task.repeatRule.rawValue)
                try bind(statement, 9, task.fireAt.timeIntervalSince1970)
                try bind(statement, 10, task.weekdays.map(String.init).joined(separator: ","))
                try bind(statement, 11, task.lastFiredAt?.timeIntervalSince1970)
                try bind(statement, 12, task.nextFireAt?.timeIntervalSince1970)
                try stepDone(statement)
            }
        }
    }

    func fetchSchedules() throws -> [ScheduledTask] {
        try ensureOpen()
        let statement = try prepare("""
        SELECT id, name, enabled, conversation_id, conversation_title, kind, content,
               repeat_rule, fire_at, weekdays, last_fired_at, next_fire_at
        FROM schedules ORDER BY COALESCE(next_fire_at, fire_at) ASC;
        """)
        defer { sqlite3_finalize(statement) }
        var result: [ScheduledTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let weekdays = try text(statement, 9)
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            result.append(ScheduledTask(
                id: try text(statement, 0),
                name: try text(statement, 1),
                enabled: int(statement, 2) != 0,
                conversationID: try text(statement, 3),
                conversationTitle: try text(statement, 4),
                kind: ChatDirection(rawValue: try text(statement, 5)) ?? .outgoing,
                content: try text(statement, 6),
                repeatRule: ScheduleRepeat(rawValue: try text(statement, 7)) ?? .daily,
                fireAt: date(statement, 8),
                weekdays: weekdays,
                lastFiredAt: optionalDate(statement, 10),
                nextFireAt: optionalDate(statement, 11)
            ))
        }
        return result
    }

    // MARK: - Key/value settings

    func setSetting(key: String, value: String) throws {
        try ensureOpen()
        let statement = try prepare("""
        INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, key)
        try bind(statement, 2, value)
        try bind(statement, 3, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    func setting(key: String) throws -> String? {
        try ensureOpen()
        let statement = try prepare("SELECT value FROM settings WHERE key = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return optionalText(statement, 0)
    }

    func removeSetting(key: String) throws {
        try ensureOpen()
        let statement = try prepare("DELETE FROM settings WHERE key = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, key)
        try stepDone(statement)
    }

    func allSettings() throws -> [String: String] {
        try ensureOpen()
        let statement = try prepare("SELECT key, value FROM settings;")
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[try text(statement, 0)] = try text(statement, 1)
        }
        return result
    }

    // MARK: - SQLite helpers

    private func ensureOpen() throws {
        if !isOpen { try open() }
        guard db != nil else { throw MemoryStoreError.notOpen }
    }

    private func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw MemoryStoreError.notOpen }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if status != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorPointer)
            throw MemoryStoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let db else { throw MemoryStoreError.notOpen }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw MemoryStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            guard let db else { throw MemoryStoreError.notOpen }
            throw MemoryStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) throws {
        let status: Int32
        if let value {
            status = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        try checkBind(status)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) throws {
        let status = value.map { sqlite3_bind_double(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        try checkBind(status)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int32) throws {
        try checkBind(sqlite3_bind_int(statement, index, value))
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64) throws {
        try checkBind(sqlite3_bind_int64(statement, index, value))
    }

    private func checkBind(_ status: Int32) throws {
        guard status == SQLITE_OK else {
            guard let db else { throw MemoryStoreError.notOpen }
            throw MemoryStoreError.sqlite("bind failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) throws -> String {
        optionalText(statement, column) ?? ""
    }

    /// Idempotent column check used by `ALTER TABLE` migrations.
    private func columnExists(in table: String, column: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if optionalText(statement, 1) == column { return true }
        }
        return false
    }

    private func optionalText(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func int(_ statement: OpaquePointer?, _ column: Int32) -> Int32 {
        sqlite3_column_int(statement, column)
    }

    private func date(_ statement: OpaquePointer?, _ column: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func optionalDate(_ statement: OpaquePointer?, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return date(statement, column)
    }
}

// MARK: - Helpers

private extension LogLevel {
    var severityRank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }
}

/// SQLite's `SQLITE_TRANSIENT` sentinel: tells SQLite to copy bound text immediately.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
