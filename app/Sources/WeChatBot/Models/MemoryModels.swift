import CryptoKit
import Foundation

// MARK: - Memory model (v2)

/// 记忆类别：事实 / 决策 / 待办 / 经验。
enum MemoryCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case fact
    case decision
    case todo
    case lesson

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fact: L("事实")
        case .decision: L("决策")
        case .todo: L("待办")
        case .lesson: L("经验")
        }
    }

    var symbol: String {
        switch self {
        case .fact: "text.book.closed"
        case .decision: "arrow.triangle.branch"
        case .todo: "checklist"
        case .lesson: "lightbulb"
        }
    }

    /// 归档/压缩时按类别合并，类别顺序用于导出与展示。
    static let displayOrder: [MemoryCategory] = [.fact, .decision, .todo, .lesson]
}

/// 记忆等级：普通 / 重要（慢衰减）。
///
/// 「最近记忆」不是存储类型，而是按 `MemorySettings.recentWindowHours` 计算出的时间分组。
enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case normal
    case important

    var label: String {
        switch self {
        case .normal: L("普通")
        case .important: L("重要")
        }
    }

    var symbol: String {
        switch self {
        case .normal: "circle"
        case .important: "exclamationmark.circle.fill"
        }
    }
}

enum MemorySource: String, Codable, CaseIterable, Sendable {
    case extraction
    case manual
    case legacyImport = "legacy-import"

    var label: String {
        switch self {
        case .extraction: L("自动提取")
        case .manual: L("手写")
        case .legacyImport: L("旧记忆导入")
        }
    }
}

/// v2 记忆的可调参数，保存在账号 `profile.json` 的 `bot.memory`。
///
/// 所有数值都会在写入/读取时收敛；旧配置缺键时逐字段回退默认值。
struct MemorySettings: Codable, Hashable, Sendable {
    /// 关闭后不提取、不召回，也不写全量互动；回复直接使用人格设定。
    var enabled: Bool = true
    /// 每多少条新互动触发一次提取（4...20）。
    var extractionBatchSize: Int = 8
    /// 「最近记忆」窗口（小时，1...168）。
    var recentWindowHours: Int = 72
    /// 普通记忆半衰期（天，1...365）。
    var normalHalfLifeDays: Int = 30
    /// 重要记忆半衰期（天，1...730）。
    var importantHalfLifeDays: Int = 180
    /// 判为「重要」的重要度阈值（5...10）。
    var importanceThreshold: Double = 7
    /// 自动折叠相似度阈值（0.80...1.0）。
    var mergeSimilarity: Double = 0.92
    /// 未访问多少天后自动归档（7...3650）。
    var archiveAfterDays: Int = 90
    /// 单轮召回条数上限（3...30）。
    var maxRecallCount: Int = 12
    /// 单轮召回正文字符上限（300...6000）。
    var maxRecallCharacters: Int = 1200
    /// 是否自动归档长期未访问的普通记忆。
    var autoArchive: Bool = true

    static let `default` = MemorySettings()

    static let extractionBatchRange: ClosedRange<Int> = 4...20
    static let recentWindowHourRange: ClosedRange<Int> = 1...168
    static let normalHalfLifeRange: ClosedRange<Int> = 1...365
    static let importantHalfLifeRange: ClosedRange<Int> = 1...730
    static let importanceThresholdRange: ClosedRange<Double> = 5...10
    static let mergeSimilarityRange: ClosedRange<Double> = 0.80...1.0
    static let archiveAfterRange: ClosedRange<Int> = 7...3650
    static let maxRecallCountRange: ClosedRange<Int> = 3...30
    static let maxRecallCharacterRange: ClosedRange<Int> = 300...6000

    init() {}

    /// 收敛到合法范围：NaN/inf 回退默认，越界取边界。
    var sanitized: MemorySettings {
        var value = self
        value.extractionBatchSize = Self.clampInt(
            extractionBatchSize, Self.extractionBatchRange, Self.default.extractionBatchSize)
        value.recentWindowHours = Self.clampInt(
            recentWindowHours, Self.recentWindowHourRange, Self.default.recentWindowHours)
        value.normalHalfLifeDays = Self.clampInt(
            normalHalfLifeDays, Self.normalHalfLifeRange, Self.default.normalHalfLifeDays)
        value.importantHalfLifeDays = Self.clampInt(
            importantHalfLifeDays, Self.importantHalfLifeRange, Self.default.importantHalfLifeDays)
        value.importanceThreshold = Self.clampDouble(
            importanceThreshold, Self.importanceThresholdRange, Self.default.importanceThreshold)
        value.mergeSimilarity = Self.clampDouble(
            mergeSimilarity, Self.mergeSimilarityRange, Self.default.mergeSimilarity)
        value.archiveAfterDays = Self.clampInt(
            archiveAfterDays, Self.archiveAfterRange, Self.default.archiveAfterDays)
        value.maxRecallCount = Self.clampInt(
            maxRecallCount, Self.maxRecallCountRange, Self.default.maxRecallCount)
        value.maxRecallCharacters = Self.clampInt(
            maxRecallCharacters, Self.maxRecallCharacterRange, Self.default.maxRecallCharacters)
        return value
    }

    private static func clampInt(_ value: Int, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
        guard value != Int.min, value != Int.max else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clampDouble(
        _ value: Double,
        _ range: ClosedRange<Double>,
        _ fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

extension MemorySettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, extractionBatchSize, recentWindowHours, normalHalfLifeDays
        case importantHalfLifeDays, importanceThreshold, mergeSimilarity, archiveAfterDays
        case maxRecallCount, maxRecallCharacters, autoArchive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MemorySettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        extractionBatchSize = (try? container.decodeIfPresent(
            Int.self, forKey: .extractionBatchSize)) ?? defaults.extractionBatchSize
        recentWindowHours = (try? container.decodeIfPresent(
            Int.self, forKey: .recentWindowHours)) ?? defaults.recentWindowHours
        normalHalfLifeDays = (try? container.decodeIfPresent(
            Int.self, forKey: .normalHalfLifeDays)) ?? defaults.normalHalfLifeDays
        importantHalfLifeDays = (try? container.decodeIfPresent(
            Int.self, forKey: .importantHalfLifeDays)) ?? defaults.importantHalfLifeDays
        importanceThreshold = (try? container.decodeIfPresent(
            Double.self, forKey: .importanceThreshold)) ?? defaults.importanceThreshold
        mergeSimilarity = (try? container.decodeIfPresent(
            Double.self, forKey: .mergeSimilarity)) ?? defaults.mergeSimilarity
        archiveAfterDays = (try? container.decodeIfPresent(
            Int.self, forKey: .archiveAfterDays)) ?? defaults.archiveAfterDays
        maxRecallCount = (try? container.decodeIfPresent(
            Int.self, forKey: .maxRecallCount)) ?? defaults.maxRecallCount
        maxRecallCharacters = (try? container.decodeIfPresent(
            Int.self, forKey: .maxRecallCharacters)) ?? defaults.maxRecallCharacters
        autoArchive = (try? container.decodeIfPresent(Bool.self, forKey: .autoArchive))
            ?? defaults.autoArchive
        self = sanitized
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let value = sanitized
        try container.encode(value.enabled, forKey: .enabled)
        try container.encode(value.extractionBatchSize, forKey: .extractionBatchSize)
        try container.encode(value.recentWindowHours, forKey: .recentWindowHours)
        try container.encode(value.normalHalfLifeDays, forKey: .normalHalfLifeDays)
        try container.encode(value.importantHalfLifeDays, forKey: .importantHalfLifeDays)
        try container.encode(value.importanceThreshold, forKey: .importanceThreshold)
        try container.encode(value.mergeSimilarity, forKey: .mergeSimilarity)
        try container.encode(value.archiveAfterDays, forKey: .archiveAfterDays)
        try container.encode(value.maxRecallCount, forKey: .maxRecallCount)
        try container.encode(value.maxRecallCharacters, forKey: .maxRecallCharacters)
        try container.encode(value.autoArchive, forKey: .autoArchive)
    }
}

// MARK: - Persona reference

/// 会话当前使用的人格模板快照（唯一来源：人格设定）。
///
/// 记忆卡不再保存每会话的人设卡副本；角色目录只需要记忆卡，人格由
/// `conversation.personaID ?? bot.defaultPersonaID` 解析到 `Persona`。
struct PersonaReference: Sendable, Hashable {
    var id: String
    var name: String
    var summary: String

    init(_ persona: Persona?) {
        id = persona?.id ?? ""
        name = (persona?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        summary = (persona?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Character directory

/// 会话 ID → 角色目录名。只保留安全字符，超长时追加 SHA256 前缀。
enum CharacterDirectory {
    static let prefix = "c-"
    static let maxEncodedLength = 160

    static func key(for conversationID: String) -> String {
        let trimmed = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prefix + "empty" }
        var encoded = ""
        for byte in trimmed.utf8 {
            if isAllowed(byte) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        if encoded.count <= maxEncodedLength {
            return prefix + encoded
        }
        var head = String(encoded.prefix(60))
        while head.hasSuffix("%") { head.removeLast() }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return prefix + head + "-" + hash
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0x2E, 0x5F, 0x2D, 0x40: return true // . _ - @
        default: return false
        }
    }
}

// MARK: - Memory

/// 记忆卡中的一条原子记忆。
struct CharacterMemory: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    /// 所属角色 = 会话 ID。
    var characterID: String = ""
    var category: MemoryCategory = .fact
    var kind: MemoryKind = .normal
    var content: String
    /// 压缩后的提示词版本；原文仍保存在 `content`。
    var compressedContent: String?
    var keywords: [String] = []
    var importance: Double = 3
    var pinned: Bool = false
    var archived: Bool = false
    var supersededBy: String?
    var supersedes: String?
    var supersededAt: Date?
    var source: MemorySource = .extraction
    var sourceMessageIDs: [String] = []
    var mergeCount: Int = 0
    var accessCount: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastAccessedAt: Date?

    var isSuperseded: Bool {
        (supersededBy?.isEmpty == false)
    }

    /// 当前应该展示/使用的等级：按置顶/重要度重算。
    func resolvedKind(threshold: Double) -> MemoryKind {
        if pinned || importance >= threshold { return .important }
        return .normal
    }

    /// 把 `kind` 收敛为当前置顶/重要度对应的值。
    mutating func normalizeKind(threshold: Double) {
        kind = resolvedKind(threshold: threshold)
    }

    var activityAt: Date {
        max(updatedAt, lastAccessedAt ?? createdAt)
    }

    var ageDays: Double {
        max(0, Date().timeIntervalSince(activityAt)) / 86_400
    }

    func isRecent(now: Date = Date(), settings: MemorySettings) -> Bool {
        now.timeIntervalSince(activityAt) <= Double(settings.recentWindowHours) * 3_600
    }

    /// 综合权重；见 docs/memory.md §5.1。
    func score(
        now: Date = Date(),
        settings: MemorySettings = .default
    ) -> Double {
        let activity = activityAt
        let ageSeconds = max(0, now.timeIntervalSince(activity))
        let ageDays = ageSeconds / 86_400
        let windowSeconds = max(1, Double(settings.recentWindowHours) * 3_600)
        let recencyProgress = max(0, 1 - ageSeconds / windowSeconds)
        let recency = 1 + 0.5 * recencyProgress
        let usage = 1 + 0.02 * Double(min(max(0, accessCount), 20))
        let halfLifeDays = Double(
            kind == .important ? settings.importantHalfLifeDays : settings.normalHalfLifeDays
        )
        let decay = pinned ? 1.0 : pow(0.5, ageDays / max(0.001, halfLifeDays))
        let clampedImportance = min(max(importance.isFinite ? importance : 3, 1), 10)
        return max(0.0001, clampedImportance * recency * usage * decay)
    }

    var weightLabel: String {
        String(format: "%.2f", score())
    }

    /// 提示词/卡片摘要用文本：过长时优先压缩版，否则截断。
    func promptText(limit: Int = 240) -> String {
        let maxLength = max(20, limit)
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count <= maxLength { return body }
        if let compressed = compressedContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !compressed.isEmpty, compressed.count <= maxLength {
            return compressed
        }
        guard maxLength > 1 else { return "" }
        return String(body.prefix(maxLength - 1)) + "…"
    }

    /// 归一化空白后的正文，用于相似度/去重显示。
    var normalizedContent: String {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var keywordsText: String { keywords.joined(separator: " ") }

    mutating func touchAccessed(at date: Date = Date()) {
        accessCount += 1
        lastAccessedAt = date
        // 召回不修改 updatedAt（避免刷新时间衰减锚点导致“越用越新”）
    }
}

/// 角色列表摘要（记忆页左栏），由 CharacterStore 扫描角色目录计算。
struct CharacterSummary: Identifiable, Hashable, Sendable {
    var id: String { conversationID }
    var conversationID: String
    var title: String
    var kind: ConversationKind
    var personaName: String
    /// 全局共享记忆卡（固定 ID，不属于任何微信会话）。
    var isGlobal: Bool = false
    var memoryCount: Int = 0
    var importantCount: Int = 0
    var todoCount: Int = 0
    var lastUpdated: Date?
    var directoryPath: String = ""
}

/// 全量互动记录（`interactions` 表），永久保存、不衰减。
struct CharacterInteraction: Identifiable, Hashable, Sendable {
    var id: Int64
    var messageID: String
    var direction: ChatDirection
    var senderID: String
    var senderName: String
    var content: String
    var timestamp: Date
    var createdAt: Date

    var speakerLabel: String {
        if direction == .outgoing { return "我" }
        let name = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != "self", name != "system" { return name }
        return senderID.isEmpty ? "对方" : senderID
    }
}

/// 写入 `interactions` 的一条纯文本互动；由运行时从 `ChatMessage` 构造。
struct CharacterInteractionInput: Sendable, Hashable {
    var messageID: String
    var direction: ChatDirection
    var senderID: String
    var senderName: String
    var content: String
    var timestamp: Date
}

/// 记忆卡完整快照，用于导出；人格由运行时从「人格设定」单独传入。
struct CharacterSnapshot: Sendable {
    var conversationID: String
    var conversationTitle: String
    var conversationKind: ConversationKind
    var memories: [CharacterMemory]
    var interactions: [CharacterInteraction]
}

/// AI 提取结果的一条候选记忆（尚未落库）。
struct ExtractedMemory: Sendable, Equatable {
    var category: MemoryCategory
    var content: String
    var importance: Double
    var keywords: [String]
    var supersedes: [String]

    var sanitized: ExtractedMemory {
        var value = self
        value.content = String(
            content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(300)
        )
        if !importance.isFinite { value.importance = 3 }
        value.importance = min(max(importance, 1), 10)
        var seen = Set<String>()
        value.keywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 24 }
            .filter { seen.insert($0).inserted }
            .prefix(8)
            .map { $0 }
        value.supersedes = Array(supersedes.prefix(4))
        return value
    }
}

/// 一轮召回结果。
struct MemoryRecall: Sendable {
    var memories: [CharacterMemory]
    var prompt: String?
    var omittedCount: Int
    var estimatedCharacters: Int

    static let empty = MemoryRecall(
        memories: [], prompt: nil, omittedCount: 0, estimatedCharacters: 0)
}

/// 一次批量提取/归档的结果，用于日志与 UI 刷新判断。
struct MemoryMaintenanceResult: Sendable, Equatable {
    var characterID: String
    var processedInteractions: Int = 0
    var added: Int = 0
    var merged: Int = 0
    var superseded: Int = 0
    var archived: Int = 0
    var usedFallback: Bool = false

    var didChange: Bool {
        processedInteractions > 0 || added > 0 || merged > 0 || superseded > 0 || archived > 0
    }
}

// MARK: - Similarity

/// 字符 bigram 余弦 + 包含关系。中文无需分词，够用且完全本地、可单测。
enum MemorySimilarity {
    static func score(_ lhs: String, _ rhs: String) -> Double {
        let a = normalize(lhs)
        let b = normalize(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        var containment = 0.0
        if shorter.count >= 4, longer.contains(shorter) {
            containment = 0.95
        }
        return max(cosine(bigrams(a), bigrams(b)), containment)
    }

    static func isDuplicate(
        _ lhs: String,
        _ rhs: String,
        threshold: Double = MemorySettings.default.mergeSimilarity
    ) -> Bool {
        score(lhs, rhs) >= threshold
    }

    /// 归一化：全角转半角、ASCII 小写、去掉标点与空白，只保留中日韩与字母数字。
    static func normalize(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            var value = scalar.value
            if value == 0x3000 { continue }
            if (0xFF01...0xFF5E).contains(value) {
                value -= 0xFEE0
            }
            if (0x30...0x39).contains(value)
                || (0x61...0x7A).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value) {
                result.unicodeScalars.append(Unicode.Scalar(value) ?? scalar)
            }
        }
        return result
    }

    private static func bigrams(_ text: String) -> [String: Double] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [:] }
        if characters.count == 1 { return [String(characters[0]): 1] }
        var result: [String: Double] = [:]
        for index in 0..<(characters.count - 1) {
            let gram = String(characters[index]) + String(characters[index + 1])
            result[gram, default: 0] += 1
        }
        return result
    }

    private static func cosine(_ lhs: [String: Double], _ rhs: [String: Double]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var dot = 0.0
        for (key, value) in lhs {
            if let other = rhs[key] { dot += value * other }
        }
        let lhsNorm = sqrt(lhs.values.reduce(0) { $0 + $1 * $1 })
        let rhsNorm = sqrt(rhs.values.reduce(0) { $0 + $1 * $1 })
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (lhsNorm * rhsNorm)
    }
}
