import Foundation
import SwiftUI

// MARK: - Navigation

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case conversations
    case bot
    case ai
    case personas
    case memory
    case schedules
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "总览"
        case .conversations: "会话"
        case .bot: "机器人"
        case .ai: "AI 模型"
        case .personas: "人格设定"
        case .memory: "记忆库"
        case .schedules: "定时任务"
        case .logs: "运行日志"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .conversations: "bubble.left.and.bubble.right"
        case .bot: "bolt.horizontal.circle"
        case .ai: "sparkles"
        case .personas: "person.crop.circle.badge.quote"
        case .memory: "brain"
        case .schedules: "calendar.badge.clock"
        case .logs: "text.alignleft"
        case .settings: "gearshape"
        }
    }

    static var main: [SidebarItem] {
        [.dashboard, .conversations]
    }

    static var automation: [SidebarItem] {
        [.bot, .ai, .personas, .schedules]
    }

    static var system: [SidebarItem] {
        [.memory, .logs, .settings]
    }
}

// MARK: - Conversations

enum ConversationKind: String, Codable, Hashable {
    case direct
    case group
    case official

    var label: String {
        switch self {
        case .direct: "私聊"
        case .group: "群聊"
        case .official: "公众号"
        }
    }

    var symbol: String {
        switch self {
        case .direct: "person.fill"
        case .group: "person.3.fill"
        case .official: "megaphone.fill"
        }
    }
}

struct Conversation: Identifiable, Codable, Hashable {
    var id: String
    var kind: ConversationKind
    var title: String
    var subtitle: String?
    var unreadCount: Int = 0
    var lastMessageAt: Date?
    var lastMessagePreview: String = ""
    var aiEnabled: Bool = true
    var providerID: String?
    var model: String?
    var personaID: String?
    var isPinned: Bool = false
    /// 旧数据库兼容字段：免打扰设置已从 UI 移除，规则引擎也不再使用（始终视为未静音）。
    var isMuted: Bool = false
    var note: String = ""
    /// nil 表示跟随全局工作时间；非 nil 表示此会话独立的工作时段。
    var workingHours: WorkingHours?

    var displayTitle: String { title.isEmpty ? id : title }

    var usesCustomWorkingHours: Bool { workingHours != nil }

    /// 会话自定义时段优先，否则继承全局设置。
    func effectiveWorkingHours(global: WorkingHours) -> WorkingHours {
        workingHours ?? global
    }
}

// MARK: - Messages

enum ChatDirection: String, Codable, Hashable {
    case incoming
    case outgoing
    case system
}

enum MessageKind: String, Codable, Hashable {
    case text
    case image
    case voice
    case emoji
    case file
    case video
    case link
    case system
}

enum DeliveryStatus: String, Codable, Hashable {
    case pending
    case sent
    case failed
    case received
    case generating
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: String
    var conversationID: String
    var senderID: String
    var senderName: String
    var direction: ChatDirection
    var kind: MessageKind = .text
    var text: String = ""
    var mediaPath: String?
    var mediaURL: String?
    var timestamp: Date
    var status: DeliveryStatus = .received
    var replyToID: String?
    var rawJSON: String?

    var isOutgoing: Bool { direction == .outgoing }

    var displaySender: String {
        if direction == .outgoing { return "我" }
        return senderName.isEmpty ? senderID : senderName
    }
}

// MARK: - AI Providers

enum ProviderKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case deepSeek
    case openAI
    case ollama
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI"
        case .ollama: "Ollama 本地"
        case .custom: "自定义兼容"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com/v1"
        case .openAI: "https://api.openai.com/v1"
        case .ollama: "http://127.0.0.1:11434/v1"
        case .custom: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepSeek: "deepseek-chat"
        case .openAI: "gpt-4o-mini"
        case .ollama: "qwen3:8b"
        case .custom: ""
        }
    }
}

struct AIProvider: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var kind: ProviderKind = .deepSeek
    var baseURL: String
    var model: String
    var apiKeyReference: String = ""   // Keychain account name; secret never stored in JSON
    /// 旧版“按通道”温度：仅用于升级时迁移到 `AISettings.modelTemperatures`，
    /// 不再参与请求生成，也不在 UI 中展示。
    var temperature: Double = 0.7
    var maxTokens: Int = 800
    var timeoutSeconds: Double = 60
    var stream: Bool = true
    var enabled: Bool = true
    var isDefault: Bool = false

    var hasAPIKey: Bool { !apiKeyReference.isEmpty }
}

// MARK: - Personas / triggers

struct Persona: Identifiable, Codable, Hashable {
    /// 内置默认人格使用的系统提示词；全局提示词已移除，人格是提示词的唯一来源。
    static let defaultSystemPrompt = "你是一个友好、自然、简洁的中文微信聊天助手。回答要像真人聊天，避免长篇大论和机械感。"

    var id: String = UUID().uuidString
    var name: String
    var summary: String = ""
    var systemPrompt: String
    var model: String? = nil
    var isDefault: Bool = false
}

enum TriggerMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case always
    case mention
    case keyword
    case pat
    case prefix

    var id: String { rawValue }

    /// 群聊触发方式展示用：私聊语义不适用，省略「或私聊」。
    var groupLabel: String {
        switch self {
        case .always: "所有消息"
        case .mention: "@"
        case .keyword: "关键词"
        case .pat: "拍一拍"
        case .prefix: "命令前缀"
        }
    }

    /// 群聊浮层可选触发方式。命令前缀保留给历史配置。
    static let groupOptions: [TriggerMode] = [.always, .mention, .keyword, .pat]
}

// MARK: - Schedules

enum ScheduleRepeat: String, Codable, CaseIterable, Hashable, Identifiable {
    case once
    case daily
    case weekly
    case weekdays

    var id: String { rawValue }

    var label: String {
        switch self {
        case .once: "一次"
        case .daily: "每天"
        case .weekly: "每周"
        case .weekdays: "工作日"
        }
    }
}

struct ScheduledTask: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var enabled: Bool = true
    var conversationID: String
    var conversationTitle: String = ""
    var kind: ChatDirection = .outgoing
    var content: String
    var repeatRule: ScheduleRepeat = .daily
    var fireAt: Date = Date()
    var weekdays: [Int] = [2, 3, 4, 5, 6]   // Calendar weekday: 1 = Sunday
    var lastFiredAt: Date?
    var nextFireAt: Date?
}

// MARK: - Long-term memory

/// 长期记忆：短期窗口（10 条消息）溢出后由 AI 批量总结生成，也可手动新增/编辑。
///
/// 综合权重 = baseWeight × 重要度 × 使用强化 × 30 天半衰期时间衰减：
/// - 重要度 = 1 + 0.12 × log2(1 + sourceCount)，随合并消息条数饱和增长（约 1~2.2）；
/// - 使用强化 = 1 + 0.02 × min(accessCount, 20)，最多 +40%；
/// - 衰减锚点取 `updatedAt` 与 `lastAccessedAt` 中较晚者：更新或召回都会刷新权重。
///
/// 核心记忆（isCore）始终加入上下文，但仍展示综合权重。
struct LongTermMemory: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    /// 空字符串表示全局记忆；否则为对应会话 ID。
    var conversationID: String = ""
    /// 仅用于展示（从 conversations 表 join 得到），不单独持久化。
    var conversationTitle: String = ""
    var summary: String
    var isCore: Bool = false
    /// 基础权重，默认 1.0；其它因子在此基础上计算。
    var baseWeight: Double = 1.0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastAccessedAt: Date?
    /// 与已有记忆合并的消息条数，用于重要度（对数增长）。
    var sourceCount: Int = 0
    /// 被提示词召回的次数，用于使用强化（最多 +40%）。
    var accessCount: Int = 0
    /// summary = 自动总结；manual = 用户新增/编辑。
    var source: String = "summary"

    static let halfLifeDays: Double = 30
    /// 重要度系数：sourceCount 每翻一倍约增加 0.12。
    static let importanceGrowth: Double = 0.12
    /// 使用强化：每次召回 +2%，最多 20 次（+40%）。
    static let usageGrowth: Double = 0.02
    static let usageCap: Int = 20

    var isGlobal: Bool { conversationID.isEmpty }

    /// 重要度：1 + 0.12 × log2(1 + sourceCount)，饱和增长约 1~2.2。
    var importanceFactor: Double {
        1 + Self.importanceGrowth * log2(1 + Double(max(0, sourceCount)))
    }

    /// 使用强化：1 + 0.02 × min(accessCount, 20)，最多 +40%。
    var usageFactor: Double {
        1 + Self.usageGrowth * Double(min(max(0, accessCount), Self.usageCap))
    }

    /// 衰减锚点：最近一次更新或召回中较晚的时间。
    var decayAnchor: Date {
        max(updatedAt, lastAccessedAt ?? .distantPast)
    }

    /// 综合权重：baseWeight × 重要度 × 使用强化 × 0.5^(距衰减锚点天数 / 30)。
    /// 更新越近、合并消息越多、被召回越频繁，权重越高。
    func timeWeight(now: Date = Date()) -> Double {
        let ageDays = max(0, now.timeIntervalSince(decayAnchor)) / 86_400
        let decay = pow(0.5, ageDays / Self.halfLifeDays)
        return max(0.0001, baseWeight * importanceFactor * usageFactor * decay)
    }

    var weightLabel: String {
        String(format: "%.2f", timeWeight())
    }
}

// MARK: - Logs / stats / hook

enum LogLevel: String, Codable, CaseIterable, Hashable, Identifiable {
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .debug: "调试"
        case .info: "信息"
        case .warning: "警告"
        case .error: "错误"
        }
    }

    var color: Color {
        switch self {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

struct LogEntry: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var date: Date = Date()
    var level: LogLevel
    var source: String
    var message: String
}

enum HookState: String, Codable, Hashable {
    case unknown
    case notInstalled
    case installed
    case wechatNotRunning
    case waitingForGadget
    case bridgeStarting
    case connected
    case failed

    var label: String {
        switch self {
        case .unknown: "未知"
        case .notInstalled: "未安装"
        case .installed: "已安装"
        case .wechatNotRunning: "微信未运行"
        case .waitingForGadget: "等待注入"
        case .bridgeStarting: "桥接启动中"
        case .connected: "已连接"
        case .failed: "异常"
        }
    }
}

struct HookStatus: Codable, Hashable {
    var state: HookState = .unknown
    var wechatVersion: String = ""
    var wechatBuild: String = ""
    var wechatRunning: Bool = false
    var gadgetInstalled: Bool = false
    var bridgeRunning: Bool = false
    var bridgePID: Int32 = 0
    var gatewayConnected: Bool = false
    var versionConfigFile: String = ""
    var matchedVersion: Bool = false
    /// 4.1.15.55 R3 原生发送是否启用/已拿到发送句柄（种子闭包）。
    var r3Active: Bool = false
    var r3Seeded: Bool = false
    var r3Queued: Int = 0
    var detail: String = ""
}

struct BotStats: Codable, Hashable {
    var receivedToday: Int = 0
    var repliedToday: Int = 0
    var failedToday: Int = 0
    var aiLatencyAverageMs: Double = 0
    var lastReplyAt: Date?
    var startedAt: Date?

    static let zero = BotStats()
}

// MARK: - Bot runtime settings

struct WorkingHours: Codable, Hashable {
    var enabled: Bool = false
    var startMinute: Int = 9 * 60
    var endMinute: Int = 22 * 60
    var weekdays: Set<Int> = [2, 3, 4, 5, 6, 7]

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute else { return true }
        guard weekdays.contains(weekday) else { return false }
        let current = hour * 60 + minute
        if startMinute <= endMinute {
            return current >= startMinute && current < endMinute
        }
        return current >= startMinute || current < endMinute
    }
}

struct HumanizeSettings: Codable, Hashable {
    var enabled: Bool = true
    var minDelayMs: Int = 700
    var maxDelayMs: Int = 2200
    // 4.1.12 上连续两条快速发送可能触发 mars coroutine stack canary；
    // 默认单条回复，避免自动回复拆分成多条后连续 send。
    var splitMessages: Bool = false
    var maxSegments: Int = 1
    var typingIndicator: Bool = true
}

struct BotSettings: Codable, Hashable {
    var enabled: Bool = false
    var dryRun: Bool = false
    var replyToDirect: Bool = true
    /// 旧版单选触发方式；仅用于解码历史配置。
    var groupTrigger: TriggerMode = .mention
    /// 群聊触发方式多选：「所有消息」与其他方式互斥，其余可任意组合。
    var groupTriggers: [TriggerMode]?
    var keywords: [String] = ["AI", "机器人", "小助手"]
    var commandPrefix: String = "/ai"
    var ignoreSelf: Bool = true
    var ignoreOfficialAccounts: Bool = true
    var cooldownSeconds: Double = 3
    var maxRepliesPerMinute: Int = 10
    /// 临时记忆窗口：默认 10 条消息；超出的旧消息由 ChatEngine 总结为长期记忆。
    var maxContextMessages: Int = 10
    var workingHours = WorkingHours()
    var humanize = HumanizeSettings()
    var defaultProviderID: String?
    var defaultPersonaID: String?

    /// 从结构化 @ 事件学到的「群昵称」映射（群 ID -> 机器人在该群的展示昵称）。
    /// 用于兼容只有正文、没有 at 段/mentions 的 @ 消息。旧配置缺省为 nil。
    var selfMentionNames: [String: String]?

    // 统一名单：条目既可以是会话 ID，也可以是发送者 wxid。
    // 白名单为空表示不限制；黑名单优先级高于白名单。
    // `nil` 表示旧版四列表尚未迁移。
    var whitelistEntries: [String]?
    var blacklistEntries: [String]?

    // 旧版分列表字段：仅用于迁移与解码兼容。
    var whitelistConversations: [String] = []
    var blacklistConversations: [String] = []
    var whitelistUsers: [String] = []
    var blacklistUsers: [String] = []

    /// 生效白名单：优先统一字段；旧配置回退为“会话 + 用户”合并。
    var effectiveWhitelist: [String] {
        normalizedIDs(whitelistEntries ?? (whitelistConversations + whitelistUsers))
    }

    /// 生效黑名单：优先统一字段；旧配置回退为“会话 + 用户”合并。
    var effectiveBlacklist: [String] {
        normalizedIDs(blacklistEntries ?? (blacklistConversations + blacklistUsers))
    }

    private func normalizedIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    /// 生效的群聊触发方式：多选优先；「所有消息」独占；
    /// 旧配置（只有 `groupTrigger`）自动回退为单选。
    var effectiveGroupTriggers: [TriggerMode] {
        let stored = groupTriggers ?? []
        if stored.contains(.always) { return [.always] }
        let normalized = TriggerMode.groupOptions.filter { stored.contains($0) }
        if !normalized.isEmpty { return normalized }
        return [groupTrigger]
    }
}
