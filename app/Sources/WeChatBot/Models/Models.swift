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
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: L("总览")
        case .conversations: L("会话")
        case .bot: L("机器人")
        case .ai: L("AI 模型")
        case .personas: L("人格设定")
        case .memory: L("记忆库")
        case .logs: L("运行日志")
        case .settings: L("设置")
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
        case .logs: "text.alignleft"
        case .settings: "gearshape"
        }
    }

    static var main: [SidebarItem] {
        [.dashboard, .conversations]
    }

    static var automation: [SidebarItem] {
        [.bot, .ai, .personas]
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
        case .direct: L("私聊")
        case .group: L("群聊")
        case .official: L("公众号")
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

/// 会话 ID 的共享判定规则（App 解析与历史数据修复共用，避免两处漂移）。
///
/// 微信 4.1.15 的群 ID 契约是 `*@chatroom`；旧 hook 曾把私聊拍一拍里的 wxid
/// 写进 `group_id`，App 因此建出「kind=group 但 ID 是 wxid」的伪群会话。
/// `wxid_self` / `self` 是历史占位值（旧 bridge 未配置账号时的兜底），不是真实账号。
enum ConversationIdentity {
    /// 合法微信群 ID：非空且（忽略大小写）以 `@chatroom` 结尾。
    static func isGroupID(_ id: String) -> Bool {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !value.isEmpty && value.hasSuffix("@chatroom")
    }

    /// 历史占位「自己」ID（`wxid_self` / `self`，忽略大小写）；不能当作真实账号或会话目标。
    static func isPlaceholderSelfID(_ id: String) -> Bool {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "wxid_self" || value == "self"
    }

    /// 可作为私聊对象的 ID：非空、非群 ID、非占位自己、非 `@placeholder_` 前缀。
    static func isPlausiblePeerID(_ id: String) -> Bool {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if isGroupID(value) { return false }
        if isPlaceholderSelfID(value) { return false }
        if value.lowercased().hasPrefix("@placeholder_") { return false }
        return true
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

    /// 此会话是否获取图片：nil 表示跟随旧全局设置/默认开启。
    /// 用户在该会话菜单里切换后写入 true/false；照片下载成功后据此决定是否自动显示。
    var imageFetchEnabled: Bool?

    /// 用户重命名或微信下发的真实昵称；nil 表示当前只有自动兜底名称。
    var customTitle: String? {
        ConversationName.customTitle(title, conversationID: id, kind: kind)
    }

    /// 列表/详情/AI 提示词统一使用的展示名。微信 4.1.15 只下发 wxid，
    /// 因此空标题或 ID 形式的标题会落到 `ConversationName` 的可读兜底。
    var displayTitle: String {
        ConversationName.displayTitle(kind: kind, conversationID: id, storedTitle: title)
    }

    var usesCustomWorkingHours: Bool { workingHours != nil }

    /// 会话自定义时段优先，否则继承全局设置。
    func effectiveWorkingHours(global: WorkingHours) -> WorkingHours {
        workingHours ?? global
    }

    /// 生效值：会话覆盖 →（旧）全局默认 → true。
    func effectiveImageFetchEnabled(global: Bool) -> Bool {
        imageFetchEnabled ?? global
    }
}

/// 会话展示名解析。
///
/// 微信 4.1.15.55 / 4.2.0.x 的入站事件只有 wxid（Message 对象不含昵称，通讯录是加密 SQLite），
/// 所以「取不到真实名称」是常态。这里集中处理三件事，避免裸 wxid 渗透到列表、AI 提示词和日志：
/// 1. 判断标题是否真实可读（用户重命名 / 微信昵称）还是占位值；
/// 2. 决定某个 `sender.nickname` 能不能作为会话标题学习；
/// 3. 给没有真实名称的会话生成稳定、可辨识的兜底名（系统账号中文名 + 尾号）。
enum ConversationName {
    /// 微信内置账号的固定中文名（键为小写会话 ID）。
    private static let systemNames: [String: String] = [
        "filehelper": "文件传输助手",
        "weixin": "微信团队",
        "newsapp": "腾讯新闻",
        "fmessage": "朋友推荐消息",
        "medianote": "语音记事本",
        "floatbottle": "漂流瓶",
        "qqmail": "QQ邮箱提醒",
        "tmessage": "腾讯微博",
        "notifymessage": "服务通知",
        "mphelper": "公众平台助手",
        "voipnotify": "语音通话",
        "voipmsgs": "语音通话",
        "shakeapp": "摇一摇",
        "lbsapp": "位置消息",
        "radardetect": "雷达",
        "blogapp": "博客",
        "weapp": "小程序",
        "brandsessionholder": "服务号",
        "officialaccounts": "公众号"
    ]

    /// 微信内置/系统会话（文件传输助手、服务通知、公众号聚合等）。
    /// 这些会话没有长期记忆价值，运行时自动建记忆卡时会跳过（手动
    /// 「为现有会话创建记忆卡」同样跳过）。
    static func isSystemAccount(_ conversationID: String) -> Bool {
        let value = conversationID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !value.isEmpty && systemNames[value] != nil
    }

    /// 占位标题（空、裸 ID、`wxid_*`、`*@chatroom`、旧版「群聊 <id>」）不展示也不入库。
    static func isPlaceholderTitle(
        _ title: String,
        conversationID: String,
        kind: ConversationKind
    ) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        // 旧版本把群标题写成「群聊 <群 ID>」；只匹配这种精确格式，
        // 不误伤用户自己起的「群聊 兄弟」之类名称。
        if kind == .group, value.lowercased() == "群聊 \(conversationID.lowercased())" {
            return true
        }
        return !isReadableName(value, conversationID: conversationID, excludedID: "")
    }

    /// 真实可读标题；nil 表示该会话只有自动兜底名称（重命名输入框据此留空）。
    static func customTitle(
        _ title: String,
        conversationID: String,
        kind: ConversationKind
    ) -> String? {
        isPlaceholderTitle(title, conversationID: conversationID, kind: kind)
            ? nil
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 展示名：真实标题 > 系统账号中文名 > 可辨识兜底。
    static func displayTitle(
        kind: ConversationKind,
        conversationID: String,
        storedTitle: String
    ) -> String {
        if let custom = customTitle(storedTitle, conversationID: conversationID, kind: kind) {
            return custom
        }
        let lowerID = conversationID.lowercased()
        if let known = systemNames[lowerID] { return known }
        if kind == .group || lowerID.hasSuffix("@chatroom") {
            return "群聊 · \(shortSuffix(conversationID))"
        }
        if kind == .official || lowerID.hasPrefix("gh_") {
            return "公众号 · \(shortSuffix(conversationID))"
        }
        if lowerID.hasPrefix("wxid_") {
            return "微信好友 · \(shortSuffix(conversationID))"
        }
        return "会话 · \(shortSuffix(conversationID))"
    }

    /// 从事件里学习私聊标题：只接受可读昵称，拒绝 wxid/群 ID/自己/发送人 ID。
    static func learnedTitle(
        from name: String,
        conversationID: String,
        senderID: String,
        selfID: String
    ) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReadableName(value, conversationID: conversationID, excludedID: selfID) else { return nil }
        if !senderID.isEmpty, value.lowercased() == senderID.lowercased() { return nil }
        return value
    }

    /// 群聊副标题（最近发言人）同样只接受可读昵称，避免把 wxid 写进数据库。
    static func learnedSenderName(
        _ name: String,
        conversationID: String,
        senderID: String,
        selfID: String
    ) -> String? {
        learnedTitle(from: name, conversationID: conversationID, senderID: senderID, selfID: selfID)
    }

    /// 昵称型字符串：非空、不是「我/自己」、不是 wxid / 群 ID、不是会话 ID 或指定账号 ID。
    private static func isReadableName(
        _ name: String,
        conversationID: String,
        excludedID: String
    ) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if value == "我" || value == "自己" { return false }
        let lower = value.lowercased()
        if lower.hasPrefix("wxid_") { return false }
        if lower.contains("@chatroom") { return false }
        if lower == conversationID.lowercased() { return false }
        if !excludedID.isEmpty, lower == excludedID.lowercased() { return false }
        return true
    }

    /// 取稳定尾号用于区分未知会话：去掉 `wxid_` / `gh_` 前缀与 `@chatroom` 后缀。
    private static func shortSuffix(_ conversationID: String, length: Int = 6) -> String {
        var base = conversationID
        if let at = base.firstIndex(of: "@") { base = String(base[..<at]) }
        let lower = base.lowercased()
        if lower.hasPrefix("wxid_") { base = String(base.dropFirst(5)) }
        if lower.hasPrefix("gh_") { base = String(base.dropFirst(3)) }
        guard !base.isEmpty else { return conversationID }
        return String(base.suffix(length))
    }
}

// MARK: - Contact directory

/// 通讯录目录条目（bridge `get_contact_directory` 回包里 `users` / `groups` 的值）。
///
/// 微信 4.1.15 的入站事件只有 wxid，真实昵称/群名来自加密通讯录（契约见
/// `docs/architecture.md` §3）。`display` 已由 Hook 按「备注 > 昵称 > 别名 > ID」
/// 归一化，App 只负责消费。
struct ContactDirectoryEntry: Codable, Hashable, Sendable {
    var display: String
    var nickname: String?
    var remark: String?

    init(display: String, nickname: String? = nil, remark: String? = nil) {
        self.display = display
        self.nickname = nickname
        self.remark = remark
    }

    private enum CodingKeys: String, CodingKey {
        case display
        case nickname
        case remark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 缺字段（老 Hook / 无备注）不能让整包解码失败。
        display = (try? container.decodeIfPresent(String.self, forKey: .display)) ?? ""
        nickname = try? container.decodeIfPresent(String.self, forKey: .nickname)
        remark = try? container.decodeIfPresent(String.self, forKey: .remark)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(display, forKey: .display)
        try container.encodeIfPresent(nickname, forKey: .nickname)
        try container.encodeIfPresent(remark, forKey: .remark)
    }
}

/// bridge 通讯录目录快照：
/// `{"ok":true,"generated_at":<毫秒>,"users":{wxid:{...}},"groups":{id@chatroom:{...}}}`；
/// 失败时为 `{"ok":false,"reason":"key_missing"}`，`users`/`groups` 缺省为空。
struct ContactDirectorySnapshot: Codable, Hashable, Sendable {
    var ok: Bool
    /// `key_missing` / `db_missing` / `decrypt_failed` / `unsupported`。
    var reason: String?
    /// Hook 侧生成时间（毫秒时间戳换算）；缺省表示未提供。
    var generatedAt: Date?
    var users: [String: ContactDirectoryEntry]
    var groups: [String: ContactDirectoryEntry]

    init(
        ok: Bool,
        reason: String? = nil,
        generatedAt: Date? = nil,
        users: [String: ContactDirectoryEntry] = [:],
        groups: [String: ContactDirectoryEntry] = [:]
    ) {
        self.ok = ok
        self.reason = reason
        self.generatedAt = generatedAt
        self.users = users
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case reason
        case generatedAt = "generated_at"
        case users
        case groups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 字段缺失/类型异常都按「没有该信息」处理，避免一个坏字段让整包目录不可用。
        ok = (try? container.decodeIfPresent(Bool.self, forKey: .ok)) ?? false
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        users = (try? container.decodeIfPresent([String: ContactDirectoryEntry].self, forKey: .users)) ?? [:]
        groups = (try? container.decodeIfPresent([String: ContactDirectoryEntry].self, forKey: .groups)) ?? [:]
        // Hook 用毫秒整数；同时容忍秒（旧数据/手写测试夹具）。
        if let millis = try? container.decodeIfPresent(Double.self, forKey: .generatedAt) {
            generatedAt = Date(timeIntervalSince1970: millis > 10_000_000_000 ? millis / 1000 : millis)
        } else {
            generatedAt = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(users, forKey: .users)
        try container.encode(groups, forKey: .groups)
        if let generatedAt {
            try container.encode(Int64((generatedAt.timeIntervalSince1970 * 1000).rounded()), forKey: .generatedAt)
        }
    }

    var isEmpty: Bool { users.isEmpty && groups.isEmpty }

    /// 目录展示名：群聊只查 `groups`，私聊/公众号只查 `users`。
    ///
    /// 返回 nil 表示没有可用名字：缺失、空白，或 `display` 只是 ID 形式兜底值
    /// （Hook 在无备注/昵称/别名时会回退成 wxid / 群 ID，这类值不能写成会话标题）。
    func displayName(for id: String, kind: ConversationKind) -> String? {
        let entry = kind == .group ? groups[id] : users[id]
        guard let entry else { return nil }
        let name = entry.display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !ConversationName.isPlaceholderTitle(name, conversationID: id, kind: kind) else { return nil }
        return name
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

/// 入站语音的转写状态（2026-10-26）。
///
/// `nil` 表示旧数据/非语音消息；新消息在收到时即写入状态，气泡按状态展示
/// 「转写中 / 转写失败·重试 / 已转写 / 已关闭」。全部可选字段保证旧库可读。
enum VoiceTranscriptState: String, Codable, Hashable, Sendable {
    /// 已入队：等待语音下载或转写完成。
    case pending
    /// 转写成功（文本可能为空：静音/无有效内容）。
    case done
    /// 获取或转写失败，可手动重试。
    case failed
    /// 用户关闭了语音转写（全局开关），不下载、不转写。
    case disabled
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
    /// 识图结果：视觉模型对这张图片内容的文字描述（2026-10-23）。
    /// nil 表示未开启识图、识别失败或尚未识别；图片本身不会直接进入回复提示词。
    var imageDescription: String?

    // MARK: 语音（2026-10-26，全部可选以兼容旧库）

    /// 语音音频的本地路径（16k 单声道 WAV）；与 `mediaPath` 同步写入，
    /// 单独保留一份便于把「语音」与普通媒体路径区分开。
    var voiceMediaPath: String?
    /// 语音时长（毫秒）：优先 bridge `duration_ms`，其次 WAV 实际时长。
    var voiceDurationMs: Int?
    /// 转写文本（清洗后）；用于气泡展示、提示词与引用说明。
    /// 是否沉淀进长期记忆总结由 `VoiceSettings.saveTranscriptToMemory` 控制。
    var voiceTranscript: String?
    /// 全文最高置信度（0...1）；nil 表示旧数据或未拿到置信度。
    var voiceTranscriptConfidence: Double?
    /// 转写状态；nil 表示旧数据（按未转写处理）。
    var voiceTranscriptState: VoiceTranscriptState?

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

// MARK: - Live reply pipeline

/// 自动回复流水线的当前阶段。仅用于运行期 UI 展示（不写数据库、不参与重启恢复），
/// 让用户能直接看出消息卡在「AI 生成 / 拟人化延迟 / 发送」中的哪一步。
enum ReplyStage: String, Sendable, Equatable {
    /// 正在等待 AI 返回完整回复（请求已发出，耗时取决于模型与网络）。
    case generating
    /// AI 已返回，正在等待拟人化随机延迟结束；`countdownEnd` 是真实的发送倒计时。
    case waitingToSend
    /// 正在把消息提交给 OneBot / bridge（等待发送回执）。
    case sending
    /// 回复已投递成功（短暂展示后自动收起）。
    case completed
    /// 回复失败（保留展示，可手动关闭）。
    case failed

    var label: String {
        switch self {
        case .generating: L("AI 正在生成回复")
        case .waitingToSend: L("等待发送")
        case .sending: L("正在发送")
        case .completed: L("回复已发送")
        case .failed: L("回复失败")
        }
    }

    var isActive: Bool {
        self == .generating || self == .waitingToSend || self == .sending
    }

    /// 完成/失败态没有持续计时需求，UI 不需要以刷新频率驱动 TimelineView。
    var needsTicking: Bool { isActive }
}

/// 单个会话当前的自动回复进度快照。
///
/// `countdownEnd` 只在已知剩余时间时（拟人化延迟）存在；AI 生成阶段耗时不可预知，
/// 因此 UI 显示「已等待」正向计时，拟人化阶段显示「N 秒后发送」倒计时。
struct ReplyProgress: Identifiable, Equatable, Sendable {
    let conversationID: String
    var stage: ReplyStage
    /// 整个回复流水线开始时间（用于总耗时）。
    let startedAt: Date
    /// 当前阶段开始时间（用于阶段耗时）。
    var stageStartedAt: Date
    /// 已知延迟的结束时间；只有 `waitingToSend` 阶段设置。
    var countdownEnd: Date?
    /// 拟人化延迟总长度（秒），用于倒计时进度条比例。
    var countdownTotal: TimeInterval?
    var providerName: String?
    var model: String?
    var segmentIndex: Int?
    var segmentCount: Int?
    var note: String?
    var errorText: String?

    var id: String { conversationID }

    /// 当前倒计时剩余秒数；未设置倒计时时为 nil，倒计时结束后为 0。
    func remainingSeconds(at date: Date) -> TimeInterval? {
        guard let countdownEnd else { return nil }
        return max(0, countdownEnd.timeIntervalSince(date))
    }

    /// 倒计时已消耗比例（0...1），用于 determinate 进度条。
    func countdownFraction(at date: Date) -> Double? {
        guard let total = countdownTotal, total > 0,
              let remaining = remainingSeconds(at: date) else { return nil }
        return min(1, max(0, 1 - remaining / total))
    }

    func elapsedSeconds(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(startedAt))
    }

    func stageElapsedSeconds(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(stageStartedAt))
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
        case .ollama: L("Ollama 本地")
        case .custom: L("自定义兼容")
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

    /// DeepSeek / OpenAI 官方接口必须带 API Key；Ollama 与自定义兼容端点允许无密钥。
    /// UI 用它区分「必填 / 可选」并给出正确的缺失状态，而不是对所有通道都显示「未配置密钥」。
    var requiresAPIKey: Bool { kind == .deepSeek || kind == .openAI }

    /// 当前通道是否已经具备发起请求所需的凭据。
    var hasUsableCredential: Bool { hasAPIKey || !requiresAPIKey }
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
    /// 别人「引用」了机器人发过的消息（2026-10-22 新增，默认关闭）。
    case quote
    case prefix

    var id: String { rawValue }

    /// 群聊触发方式展示用：私聊语义不适用，省略「或私聊」。
    var groupLabel: String {
        switch self {
        case .always: L("所有消息")
        case .mention: "@"
        case .keyword: L("关键词")
        case .pat: L("拍一拍")
        case .quote: L("引用机器人")
        case .prefix: L("命令前缀")
        }
    }

    /// 群聊浮层可选触发方式。命令前缀保留给历史配置；
    /// 「引用机器人」需显式勾选，升级后不会自动改变既有触发行为。
    static let groupOptions: [TriggerMode] = [.always, .mention, .keyword, .pat, .quote]
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
        case .once: L("一次")
        case .daily: L("每天")
        case .weekly: L("每周")
        case .weekdays: L("工作日")
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
/// 核心记忆（isCore）在所属会话（或全局）内优先注入，但仍展示综合权重；
/// `baseWeight` 可由用户在记忆编辑器中自由调整（默认 1.0），核心记忆之间也按综合权重排序。
struct LongTermMemory: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    /// 空字符串表示全局记忆；否则为对应会话 ID。
    var conversationID: String = ""
    /// 仅用于展示（从 conversations 表 join 得到），不单独持久化。
    var conversationTitle: String = ""
    var summary: String
    var isCore: Bool = false
    /// 基础权重，默认 1.0；用户可在编辑器里自由调整（范围 `baseWeightRange`），
    /// 其它因子在此基础上计算。
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
    /// 用户可调基础权重：默认 1.0，编辑器中可在 0.1~10.0 之间自由调整。
    static let defaultBaseWeight: Double = 1.0
    static let baseWeightRange: ClosedRange<Double> = 0.1...10.0
    /// 编辑器里的快捷预设（倍率）。
    static let baseWeightPresets: [Double] = [0.5, 1.0, 2.0, 3.0, 5.0]

    var isGlobal: Bool { conversationID.isEmpty }

    /// 是否被用户调整过基础权重（用于卡片徽标与提示）。
    var hasCustomBaseWeight: Bool {
        abs(baseWeight - Self.defaultBaseWeight) > 0.000_001
    }

    /// 把任意输入收敛到可调范围：NaN/inf 回落到默认值，越界取边界。
    static func clampBaseWeight(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBaseWeight }
        return min(max(value, baseWeightRange.lowerBound), baseWeightRange.upperBound)
    }

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
        case .debug: L("调试")
        case .info: L("信息")
        case .warning: L("警告")
        case .error: L("错误")
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
        case .unknown: L("未知")
        case .notInstalled: L("未安装")
        case .installed: L("已安装")
        case .wechatNotRunning: L("微信未运行")
        case .waitingForGadget: L("等待注入")
        case .bridgeStarting: L("桥接启动中")
        case .connected: L("已连接")
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
    /// 4.1.15.55 / 4.2.0.x R3 原生发送是否启用/已拿到发送句柄（种子闭包）。
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
        let current = hour * 60 + minute
        if startMinute < endMinute {
            // 普通时段：当天星期 + [start, end)。
            return weekdays.contains(weekday) && current >= startMinute && current < endMinute
        }
        if startMinute > endMinute {
            // 跨夜时段（如 22:00–02:00）：窗口从 start 当天开始，到次日 end 结束。
            // - 前半夜（t >= start）：属于「今天」开始的窗口，按今天星期判定；
            // - 后半夜（t < end）：属于「昨天」开始的窗口，必须按前一天星期判定，
            //   否则周五 22:00–02:00 的窗口在周六 00:30 会被误判为休息。
            if current >= startMinute { return weekdays.contains(weekday) }
            if current < endMinute {
                let previousWeekday = weekday == 1 ? 7 : weekday - 1
                return weekdays.contains(previousWeekday)
            }
            return false
        }
        // start == end：零长度窗口（旧行为；UI 不提供该组合）。
        return false
    }
}

extension WorkingHours {
    /// 工作时间的展示状态。与 `RuleEngine` 使用同一个 `contains` 判定，
    /// 因此 `paused` 就代表当前消息会被规则引擎以「不在工作时段」拦截自动回复。
    enum Status: Equatable {
        /// 未启用时间限制（全局关闭或会话显式不限制），任何时间都允许自动回复。
        case unrestricted
        /// 已启用且当前在时段内。
        case active
        /// 已启用但当前不在时段内；自动回复会被拦截，手动发送不受影响。
        case paused
    }

    func status(at date: Date = Date(), calendar: Calendar = .current) -> Status {
        guard enabled else { return .unrestricted }
        return contains(date, calendar: calendar) ? .active : .paused
    }
}

// MARK: - WorkingHours 展示与收敛（纯函数）
//
// RuleEngine 直接使用上面的 `contains`；这里提供的都是不会改变既有判定语义的
// 辅助纯函数，供工作时间编辑器、徽标与全局卡片统一文案 / 兜底无效配置。
extension WorkingHours {
    /// 有效星期（过滤 1...7 之外的值并升序）。
    var validWeekdays: [Int] {
        weekdays.filter { (1...7).contains($0) }.sorted()
    }

    /// 一分钟精度的 `HH:mm`；越界分钟会先收敛到 0...1439。
    static func minuteText(_ minute: Int) -> String {
        let clamped = min(max(minute, 0), 1439)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    /// 只有时段的摘要，例如 `09:00–18:00`；跨夜时标注「次日」。
    var timeRangeText: String {
        let start = Self.minuteText(startMinute)
        let end = Self.minuteText(endMinute)
        return startMinute > endMinute ? Lf("%@–次日 %@", start, end) : "\(start)–\(end)"
    }

    /// 完整时段摘要，例如「工作日 09:00–18:00」「每天 22:00–次日 06:00」；
    /// 未启用时统一为「不限时段」，启用但没有有效星期时直接说明不会生效。
    var summaryText: String {
        guard enabled else { return L("不限时段") }
        guard !validWeekdays.isEmpty else { return L("未选择任何星期，不会生效") }
        return "\(UIFormat.weekdaySummary(validWeekdays)) \(timeRangeText)"
    }

    /// 开始与结束相同：零长度窗口，`contains` 永远为 false。
    var hasZeroLengthWindow: Bool { startMinute == endMinute }

    /// 启用后在真实判定中永远不会命中的配置（没有有效星期，或零长度窗口）。
    /// 只读判断，不改变 `contains` 的既有语义。
    var isNeverEffective: Bool {
        enabled && (validWeekdays.isEmpty || hasZeroLengthWindow)
    }

    /// 与 `sanitized` 不同即表示配置需要修复（供 UI 显示校验提示）。
    var needsRepair: Bool { self != sanitized }

    /// 收敛后的副本：
    /// - 分钟限制到 0...1439，星期过滤为 1...7；
    /// - 启用但没有有效星期时回退为每天，避免「看似开着却永不生效」；
    /// - 启用且开始 == 结束时把结束顺延一小时（23:30 → 次日 00:30）。
    var sanitized: WorkingHours {
        var copy = self
        copy.startMinute = min(max(startMinute, 0), 1439)
        copy.endMinute = min(max(endMinute, 0), 1439)
        copy.weekdays = Set(validWeekdays)
        if copy.enabled {
            if copy.weekdays.isEmpty {
                copy.weekdays = Set(1...7)
            }
            if copy.startMinute == copy.endMinute {
                copy.endMinute = (copy.startMinute + 60) % 1440
            }
        }
        return copy
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

/// 「别人拍一拍机器人」后的回复设置。整体作为 `BotSettings.pat` 的可选值保存：
/// 旧 config.json 没有该键时保持 nil，不会让整份配置解码失败。
///
/// 回拍已移除：只发送自定义文字和/或 AI 回复，两者可独立开启。
struct PatReplySettings: Codable, Hashable {
    /// 别人拍机器人时是否发送回复。
    var enabled: Bool = false
    /// 是否发送自定义文字。
    var fixedTextEnabled: Bool?
    /// AI 回复前发送的文字；nil/空表示不发送。
    var beforeText: String?
    /// AI 回复后发送的文字；nil/空表示不发送。
    var afterText: String?
    /// 是否附带 AI 回复。
    var aiReplyEnabled: Bool?
    /// 群聊被拍后是否在第一条回复前 @ 拍的人。旧配置缺省为关闭。
    var mentionPatterInGroup: Bool?

    /// 是否填写了任意自定义文字。
    var hasFixedText: Bool {
        !(beforeText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(afterText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 旧配置兼容：有文字但没写 fixedTextEnabled 时视为启用文字。
    var resolvedFixedTextEnabled: Bool {
        fixedTextEnabled ?? hasFixedText
    }

    var resolvedAIEnabled: Bool {
        aiReplyEnabled ?? false
    }

    var resolvedMentionPatterInGroup: Bool {
        mentionPatterInGroup ?? false
    }
}

/// 回拍附言的模板替换：`{name}` → 对方昵称（缺失时用「对方」）。
enum PatTextTemplate {
    static func render(_ template: String, name: String) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: "{name}", with: displayName.isEmpty ? "对方" : displayName)
    }
}

/// 群聊唤醒后的免唤醒窗口（2026-10-23 新增）。
///
/// 被任一触发方式唤醒后，**同一发送者**在窗口内继续发言无需再次唤醒（滑动续期）。
/// 作为 `BotSettings.wakeWindow` 的可选值保存：旧 config.json 没有该键时保持 nil，
/// 不会让整份配置解码失败；默认关闭，关闭时不影响既有触发行为。
struct WakeWindowSettings: Codable, Hashable {
    var enabled: Bool = false
    /// 窗口时长（秒）；默认 5 分钟。
    var seconds: Double = 300

    /// 生效时长：关闭或非正数时为 0；上限 60 分钟（与 UI 一致）。
    var effectiveSeconds: Double {
        guard enabled, seconds > 0 else { return 0 }
        return min(max(seconds, 1), 3600)
    }
}

// MARK: - 语音设置（2026-10-26）

/// 语音超长处理：默认改发文字，可切换为按句截断（TTS 使用）。
enum VoiceOverLimit: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case text
    case truncate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: L("改发文字")
        case .truncate: L("按句截断")
        }
    }
}

/// 语音功能设置（`BotSettings.voice` 的可选值，2026-10-26）。
///
/// 全部字段都有默认值，且通过自定义 Codable 容忍缺键/未知枚举值：
/// 旧 `config.json` 没有 `voice` 键时保持 nil，行为与旧版本完全一致；
/// 新配置即使只写了部分字段也能正常解码（缺失字段用默认值补齐）。
/// 数值在解码与保存时收敛到合法范围，避免手改配置把 UI 滑块撑坏。
struct VoiceSettings: Codable, Hashable {
    /// 入站语音是否转写（默认开启）。
    var transcriptionEnabled: Bool = true
    /// 气泡里是否显示转写文本（默认开启）。
    var showTranscriptInBubble: Bool = true
    /// 转写是否写入消息正文/长期记忆（默认开启）。
    var saveTranscriptToMemory: Bool = true
    /// 是否允许语音回复（默认关闭）。
    var replyEnabled: Bool = false
    /// 语音回复概率（0...1）。
    var replyProbability: Double = 0.3
    /// 对等：只有收到语音时才回语音（默认关闭）。
    var mirrorIncomingVoice: Bool = false
    /// 语音回复跳过拟人化延迟（默认开启）：本条已确定改发语音时直接合成发送，
    /// 不再叠加随机延迟，避免「TTS 合成 + 拟人化等待」让用户等太久。
    var skipHumanizeDelayForVoiceReply: Bool = true
    /// 仅短回复发语音（默认开启）。
    var shortReplyOnly: Bool = true
    /// 「短回复」的字符阈值。
    var shortReplyMaxChars: Int = 80
    /// 语音回复最长时长（秒），范围 5–60。
    var maxVoiceSeconds: Int = 30
    /// 超过时长上限时的处理方式。
    var overLimit: VoiceOverLimit = .text
    // MARK: CosyVoice3 本地服务（唯一 TTS 引擎）

    /// CosyVoice3 音色 ID（来自本机 voices.json / 服务端 `/voices`）。
    /// **不设默认音色**：App 不内置任何音色，空字符串表示「未选择音色」。
    var cosyVoiceVoiceID: String = ""
    /// 本地服务地址（默认 `http://127.0.0.1:5051`；改端口时同步改这里）。
    var cosyVoiceEndpoint: String = "http://127.0.0.1:5051"
    /// 允许语音回复时自动拉起本地服务（默认开启）。
    var cosyVoiceAutoStart: Bool = true
    /// CosyVoice3 语速（0.5–2.0，默认 1.0）。
    var cosyVoiceSpeed: Double = 1.0

    // MARK: 生效值

    /// 生效的语音时长上限（5...60 秒）。
    var effectiveMaxVoiceSeconds: Int {
        min(max(maxVoiceSeconds, 5), 60)
    }

    /// 生效的短回复字符阈值（1...500）。
    var effectiveShortReplyMaxChars: Int {
        min(max(shortReplyMaxChars, 1), 500)
    }

    /// 生效的语音回复概率（0...1）。
    var effectiveReplyProbability: Double {
        guard replyProbability.isFinite else { return 0.3 }
        return min(max(replyProbability, 0), 1)
    }

    /// 生效的 CosyVoice3 音色 ID：空白保持空（未选择音色），不自动回退到 girl。
    var effectiveCosyVoiceVoiceID: String {
        CosyVoiceVoiceCatalog.resolvedVoiceID(cosyVoiceVoiceID)
    }

    /// 是否已经选择了可用的 CosyVoice3 音色。
    var hasCosyVoiceVoice: Bool { !effectiveCosyVoiceVoiceID.isEmpty }

    /// 生效的 CosyVoice3 语速（0.5...2.0，默认 1.0）。
    var effectiveCosyVoiceSpeed: Double {
        guard cosyVoiceSpeed.isFinite else { return 1.0 }
        return min(max(cosyVoiceSpeed, 0.5), 2.0)
    }

    /// 用户填写的服务地址是否可解析（http/https + host）。
    var hasValidCosyVoiceEndpoint: Bool {
        CosyVoiceClient.normalizedEndpoint(cosyVoiceEndpoint) != nil
    }

    /// 生效的 CosyVoice3 服务地址：非法/空白回退默认 `127.0.0.1:5051`。
    var effectiveCosyVoiceEndpoint: URL {
        CosyVoiceClient.normalizedEndpoint(cosyVoiceEndpoint) ?? CosyVoiceClient.defaultEndpoint
    }
}

// Custom Codable in an extension: preserves the synthesized memberwise init used by
// tests and by programmatic defaults, while tolerating partial/legacy JSON.
extension VoiceSettings {
    private enum CodingKeys: String, CodingKey {
        case transcriptionEnabled
        case showTranscriptInBubble
        case saveTranscriptToMemory
        case replyEnabled
        case replyProbability
        case mirrorIncomingVoice
        case skipHumanizeDelayForVoiceReply
        case shortReplyOnly
        case shortReplyMaxChars
        case maxVoiceSeconds
        case overLimit
        case cosyVoiceVoiceID
        case cosyVoiceEndpoint
        case cosyVoiceAutoStart
        case cosyVoiceSpeed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoiceSettings()
        transcriptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .transcriptionEnabled)
            ?? defaults.transcriptionEnabled
        showTranscriptInBubble = try container.decodeIfPresent(Bool.self, forKey: .showTranscriptInBubble)
            ?? defaults.showTranscriptInBubble
        saveTranscriptToMemory = try container.decodeIfPresent(Bool.self, forKey: .saveTranscriptToMemory)
            ?? defaults.saveTranscriptToMemory
        replyEnabled = try container.decodeIfPresent(Bool.self, forKey: .replyEnabled)
            ?? defaults.replyEnabled
        replyProbability = try container.decodeIfPresent(Double.self, forKey: .replyProbability)
            ?? defaults.replyProbability
        mirrorIncomingVoice = try container.decodeIfPresent(Bool.self, forKey: .mirrorIncomingVoice)
            ?? defaults.mirrorIncomingVoice
        skipHumanizeDelayForVoiceReply = try container.decodeIfPresent(
            Bool.self, forKey: .skipHumanizeDelayForVoiceReply)
            ?? defaults.skipHumanizeDelayForVoiceReply
        shortReplyOnly = try container.decodeIfPresent(Bool.self, forKey: .shortReplyOnly)
            ?? defaults.shortReplyOnly
        shortReplyMaxChars = try container.decodeIfPresent(Int.self, forKey: .shortReplyMaxChars)
            ?? defaults.shortReplyMaxChars
        maxVoiceSeconds = try container.decodeIfPresent(Int.self, forKey: .maxVoiceSeconds)
            ?? defaults.maxVoiceSeconds
        // 未知 raw value 回退到默认，避免手改配置导致整份 config 解码失败。
        overLimit = (try container.decodeIfPresent(String.self, forKey: .overLimit))
            .flatMap { VoiceOverLimit(rawValue: $0) } ?? defaults.overLimit
        // CosyVoice3 是唯一 TTS 引擎：旧配置里的 engine/kokoroSpeakerID/kokoroSpeed/
        // cloneID/modelDownloadConsent 已移除，解码时直接忽略（不再写入）。
        // 旧配置没有 cosyVoice* 键时全部走默认值（空音色 / 127.0.0.1:5051 / 自动启动 / 1.0）。
        cosyVoiceVoiceID = try container.decodeIfPresent(String.self, forKey: .cosyVoiceVoiceID)
            ?? defaults.cosyVoiceVoiceID
        cosyVoiceEndpoint = try container.decodeIfPresent(String.self, forKey: .cosyVoiceEndpoint)
            ?? defaults.cosyVoiceEndpoint
        cosyVoiceAutoStart = try container.decodeIfPresent(Bool.self, forKey: .cosyVoiceAutoStart)
            ?? defaults.cosyVoiceAutoStart
        cosyVoiceSpeed = try container.decodeIfPresent(Double.self, forKey: .cosyVoiceSpeed)
            ?? defaults.cosyVoiceSpeed

        // 解码后收敛数值范围（手改配置/历史异常值）。
        maxVoiceSeconds = effectiveMaxVoiceSeconds
        shortReplyMaxChars = effectiveShortReplyMaxChars
        replyProbability = effectiveReplyProbability
        cosyVoiceVoiceID = effectiveCosyVoiceVoiceID
        cosyVoiceSpeed = effectiveCosyVoiceSpeed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcriptionEnabled, forKey: .transcriptionEnabled)
        try container.encode(showTranscriptInBubble, forKey: .showTranscriptInBubble)
        try container.encode(saveTranscriptToMemory, forKey: .saveTranscriptToMemory)
        try container.encode(replyEnabled, forKey: .replyEnabled)
        try container.encode(effectiveReplyProbability, forKey: .replyProbability)
        try container.encode(mirrorIncomingVoice, forKey: .mirrorIncomingVoice)
        try container.encode(skipHumanizeDelayForVoiceReply, forKey: .skipHumanizeDelayForVoiceReply)
        try container.encode(shortReplyOnly, forKey: .shortReplyOnly)
        try container.encode(effectiveShortReplyMaxChars, forKey: .shortReplyMaxChars)
        try container.encode(effectiveMaxVoiceSeconds, forKey: .maxVoiceSeconds)
        try container.encode(overLimit.rawValue, forKey: .overLimit)
        try container.encode(effectiveCosyVoiceVoiceID, forKey: .cosyVoiceVoiceID)
        try container.encode(CosyVoiceClient.normalizedEndpoint(cosyVoiceEndpoint)?.absoluteString
            ?? cosyVoiceEndpoint, forKey: .cosyVoiceEndpoint)
        try container.encode(cosyVoiceAutoStart, forKey: .cosyVoiceAutoStart)
        try container.encode(effectiveCosyVoiceSpeed, forKey: .cosyVoiceSpeed)
    }
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

    /// 别人拍一拍后的回复设置（不再回拍）。可选以兼容旧配置。
    var pat: PatReplySettings?

    /// 群聊唤醒后的免唤醒窗口（2026-10-23）。可选以兼容旧配置；nil 表示默认关闭。
    var wakeWindow: WakeWindowSettings?

    /// 语音功能设置（2026-10-26）。可选以兼容旧配置；nil 表示全部默认值
    /// （转写开启、语音回复关闭），旧配置行为不变。
    var voice: VoiceSettings?

    /// 语音设置的读写入口：nil 时返回默认值；写入时创建结构。
    var voiceSettings: VoiceSettings {
        get { voice ?? VoiceSettings() }
        set { voice = newValue }
    }

    /// 记忆 v2 设置（2026-10-28 起）。nil 表示旧配置，使用默认值。
    /// 随账号 `profile.json` 保存；缺键不会影响旧配置解码。
    var memory: MemorySettings?

    /// 记忆设置的读写入口：nil 时返回默认值并收敛范围。
    var memorySettings: MemorySettings {
        get { (memory ?? MemorySettings.default).sanitized }
        set { memory = newValue.sanitized }
    }

    /// 生效的语音转写总开关（旧配置缺省开启）。
    var voiceTranscriptionEnabled: Bool {
        get { voiceSettings.transcriptionEnabled }
        set { voiceSettings.transcriptionEnabled = newValue }
    }

    /// 生效的语音回复总开关（旧配置缺省关闭）。
    var voiceReplyEnabled: Bool {
        get { voiceSettings.replyEnabled }
        set { voiceSettings.replyEnabled = newValue }
    }

    /// 收到图片时是否向 bridge 请求图片内容（默认开启）。
    /// 旧配置缺少该键时保持开启；关闭后只显示「图片」占位，不下载、不落盘。
    /// 必须保持 `Bool?`：非可选 Bool 会让缺少该键的旧 config.json 解码失败。
    var imageFetchEnabled: Bool?

    var patReplyEnabled: Bool {
        get { pat?.enabled ?? false }
        set {
            var updated = pat ?? PatReplySettings()
            updated.enabled = newValue
            pat = updated
        }
    }

    var patFixedTextEnabled: Bool {
        get { pat?.resolvedFixedTextEnabled ?? false }
        set {
            var updated = pat ?? PatReplySettings()
            updated.fixedTextEnabled = newValue
            pat = updated
        }
    }

    var patAIEnabled: Bool {
        get { pat?.resolvedAIEnabled ?? false }
        set {
            var updated = pat ?? PatReplySettings()
            updated.aiReplyEnabled = newValue
            pat = updated
        }
    }

    /// 群聊被拍后是否在第一条回复前 @ 拍的人（默认关闭）。
    var patMentionPatterEnabled: Bool {
        get { pat?.resolvedMentionPatterInGroup ?? false }
        set {
            var updated = pat ?? PatReplySettings()
            updated.mentionPatterInGroup = newValue
            pat = updated
        }
    }

    /// AI 回复前文字（原样保存；发送时 trim，空串表示不发送）。
    var patBeforeText: String {
        get { pat?.beforeText ?? "" }
        set {
            var updated = pat ?? PatReplySettings()
            updated.beforeText = newValue.isEmpty ? nil : newValue
            pat = updated
        }
    }

    /// AI 回复后文字（原样保存；发送时 trim，空串表示不发送）。
    var patAfterText: String {
        get { pat?.afterText ?? "" }
        set {
            var updated = pat ?? PatReplySettings()
            updated.afterText = newValue.isEmpty ? nil : newValue
            pat = updated
        }
    }

    /// 群聊唤醒后免唤醒词开关（默认关闭）。
    var wakeWindowEnabled: Bool {
        get { wakeWindow?.enabled ?? false }
        set {
            var updated = wakeWindow ?? WakeWindowSettings()
            updated.enabled = newValue
            wakeWindow = updated
        }
    }

    /// 免唤醒窗口时长（秒）；未配置时返回默认 5 分钟，保存时收敛到 1 秒–60 分钟。
    var wakeWindowSeconds: Double {
        get { wakeWindow?.seconds ?? WakeWindowSettings().seconds }
        set {
            var updated = wakeWindow ?? WakeWindowSettings()
            updated.seconds = min(max(newValue, 1), 3600)
            wakeWindow = updated
        }
    }

    /// 生效的免唤醒窗口秒数；关闭时为 0。
    var effectiveWakeWindowSeconds: Double {
        wakeWindow?.effectiveSeconds ?? 0
    }

    /// 生效的「获取图片」开关：nil 视为开启（旧配置兼容）。
    var fetchImagesEnabled: Bool {
        get { imageFetchEnabled ?? true }
        set { imageFetchEnabled = newValue }
    }

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

// MARK: - 旧配置容错解码
//
// `WorkingHours` / `HumanizeSettings` / `BotSettings` 都含「后加的非可选字段」。
// Codable 的合成解码遇到缺失键会 throw，而 `AppSettings` 是整体解码的：
// 旧版 config.json 只要缺一个 `humanize.maxSegments`，整份全局设置（onebot token、
// hook.wechatPath、providers…）都会回退默认值并写回覆盖。这里逐键
// `decodeIfPresent`，缺键/类型损坏只回退该字段的默认值。

extension WorkingHours {
    private enum CodingKeys: String, CodingKey {
        case enabled, startMinute, endMinute, weekdays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WorkingHours()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        startMinute = (try? container.decodeIfPresent(Int.self, forKey: .startMinute))
            ?? defaults.startMinute
        endMinute = (try? container.decodeIfPresent(Int.self, forKey: .endMinute))
            ?? defaults.endMinute
        weekdays = (try? container.decodeIfPresent(Set<Int>.self, forKey: .weekdays))
            ?? defaults.weekdays
    }
}

extension HumanizeSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, minDelayMs, maxDelayMs, splitMessages, maxSegments, typingIndicator
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HumanizeSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        minDelayMs = (try? container.decodeIfPresent(Int.self, forKey: .minDelayMs))
            ?? defaults.minDelayMs
        maxDelayMs = (try? container.decodeIfPresent(Int.self, forKey: .maxDelayMs))
            ?? defaults.maxDelayMs
        splitMessages = (try? container.decodeIfPresent(Bool.self, forKey: .splitMessages))
            ?? defaults.splitMessages
        maxSegments = (try? container.decodeIfPresent(Int.self, forKey: .maxSegments))
            ?? defaults.maxSegments
        typingIndicator = (try? container.decodeIfPresent(Bool.self, forKey: .typingIndicator))
            ?? defaults.typingIndicator
    }
}

extension BotSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, dryRun, replyToDirect, groupTrigger, groupTriggers, keywords
        case commandPrefix, ignoreSelf, ignoreOfficialAccounts, cooldownSeconds
        case maxRepliesPerMinute, maxContextMessages, workingHours, humanize
        case defaultProviderID, defaultPersonaID, pat, wakeWindow, voice, memory
        case imageFetchEnabled, selfMentionNames, whitelistEntries, blacklistEntries
        case whitelistConversations, blacklistConversations, whitelistUsers, blacklistUsers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BotSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        dryRun = (try? container.decodeIfPresent(Bool.self, forKey: .dryRun)) ?? defaults.dryRun
        replyToDirect = (try? container.decodeIfPresent(Bool.self, forKey: .replyToDirect))
            ?? defaults.replyToDirect
        groupTrigger = (try? container.decodeIfPresent(TriggerMode.self, forKey: .groupTrigger))
            ?? defaults.groupTrigger
        groupTriggers = try? container.decodeIfPresent([TriggerMode].self, forKey: .groupTriggers)
        keywords = (try? container.decodeIfPresent([String].self, forKey: .keywords))
            ?? defaults.keywords
        commandPrefix = (try? container.decodeIfPresent(String.self, forKey: .commandPrefix))
            ?? defaults.commandPrefix
        ignoreSelf = (try? container.decodeIfPresent(Bool.self, forKey: .ignoreSelf))
            ?? defaults.ignoreSelf
        ignoreOfficialAccounts = (try? container.decodeIfPresent(
            Bool.self, forKey: .ignoreOfficialAccounts)) ?? defaults.ignoreOfficialAccounts
        cooldownSeconds = (try? container.decodeIfPresent(Double.self, forKey: .cooldownSeconds))
            ?? defaults.cooldownSeconds
        maxRepliesPerMinute = (try? container.decodeIfPresent(
            Int.self, forKey: .maxRepliesPerMinute)) ?? defaults.maxRepliesPerMinute
        maxContextMessages = (try? container.decodeIfPresent(
            Int.self, forKey: .maxContextMessages)) ?? defaults.maxContextMessages
        workingHours = (try? container.decodeIfPresent(WorkingHours.self, forKey: .workingHours))
            ?? defaults.workingHours
        humanize = (try? container.decodeIfPresent(HumanizeSettings.self, forKey: .humanize))
            ?? defaults.humanize
        defaultProviderID = try? container.decodeIfPresent(String.self, forKey: .defaultProviderID)
        defaultPersonaID = try? container.decodeIfPresent(String.self, forKey: .defaultPersonaID)
        pat = try? container.decodeIfPresent(PatReplySettings.self, forKey: .pat)
        wakeWindow = try? container.decodeIfPresent(WakeWindowSettings.self, forKey: .wakeWindow)
        voice = try? container.decodeIfPresent(VoiceSettings.self, forKey: .voice)
        memory = try? container.decodeIfPresent(MemorySettings.self, forKey: .memory)
        imageFetchEnabled = try? container.decodeIfPresent(Bool.self, forKey: .imageFetchEnabled)
        selfMentionNames = try? container.decodeIfPresent(
            [String: String].self, forKey: .selfMentionNames)
        whitelistEntries = try? container.decodeIfPresent([String].self, forKey: .whitelistEntries)
        blacklistEntries = try? container.decodeIfPresent([String].self, forKey: .blacklistEntries)
        whitelistConversations = (try? container.decodeIfPresent(
            [String].self, forKey: .whitelistConversations)) ?? defaults.whitelistConversations
        blacklistConversations = (try? container.decodeIfPresent(
            [String].self, forKey: .blacklistConversations)) ?? defaults.blacklistConversations
        whitelistUsers = (try? container.decodeIfPresent(
            [String].self, forKey: .whitelistUsers)) ?? defaults.whitelistUsers
        blacklistUsers = (try? container.decodeIfPresent(
            [String].self, forKey: .blacklistUsers)) ?? defaults.blacklistUsers
    }
}
