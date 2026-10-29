import Foundation

// MARK: - Paths

/// 应用文件路径。
///
/// - 全局（不随微信账号切换）：`config.json`、Keychain、bridge 日志、备份、运行期文件；
/// - 账号级（随微信账号切换）：`accounts/<id>/` 下的 `profile.json`、SQLite、媒体与日志。
///
/// 账号级路径全部委托给 `AccountProfile`（见 docs/accounts.md、实施契约 §2.3）。
/// 所有属性都是**纯计算**（只读路径、无副作用），因为 `AppPaths` 也会被
/// `SettingsPersistence` 等后台 actor 读取；`AccountProfile` 内部自行加锁。
enum AppPaths {
    static let appName = "WeChatAI"
    static let bundleID = "com.gusionw.wechatai"

    /// 测试专用覆盖：非 nil 时所有 Application Support 路径改到这个根目录。
    ///
    /// 单测（如音色库 CRUD）必须写临时目录：直接写用户的真实
    /// `~/Library/Application Support/WeChatAI` 既会污染用户数据，在受限沙箱/CI
    /// 里还会因权限不足直接失败（CoreAudio 报 -54）。
    nonisolated(unsafe) static var supportDirectoryOverride: URL?

    static var supportDirectory: URL {
        if let override = supportDirectoryOverride {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    /// 全局设置：完整 `AppSettings` 镜像（兼容旧版回滚），不随账号切换。
    static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }

    // MARK: 账号级（委托 AccountProfile，随微信账号切换）

    /// 当前账号的账号级设置（bot / personas / schedules）。
    static var profileFile: URL { AccountProfile.profileFile }
    /// 当前账号的记忆数据库。
    static var databaseFile: URL { AccountProfile.databaseFile }
    /// 当前账号的新媒体目录（入站图片/语音、TTS 输出）。
    static var mediaDirectory: URL { AccountProfile.mediaDirectory }
    /// 当前账号的日志目录。
    static var logsDirectory: URL { AccountProfile.logsDirectory }
    /// 当前账号的角色目录（每会话记忆卡，记忆 v2；人格来自人格设定）。
    static var charactersDirectory: URL { AccountProfile.charactersDirectory }
    /// 所有账号目录的父目录（`accounts/`）。
    static var accountsDirectory: URL { AccountProfile.layout.accountsDirectory }
    /// 当前账号目录（`accounts/<id>/`）。
    static var accountDirectory: URL { AccountProfile.activeDirectory }
    /// 当前账号状态（`accounts/../account-state.json`）。
    static var accountStateFile: URL { AccountProfile.layout.stateFile }
    /// 旧版单库（迁移后保留，只读回退用）。
    static var legacyDatabaseFile: URL { AccountProfile.layout.legacyDatabaseFile }
    /// 旧版遗留媒体目录（只读保留；旧消息里的绝对路径仍可读，不迁移、不删除、不主动创建）。
    static var legacyMediaDirectory: URL { AccountProfile.layout.legacyMediaDirectory }

    // MARK: 全局

    /// bridge 日志必须写在 app bundle 之外：写入 `Contents/Resources/bridge/log`
    /// 会破坏 ad-hoc 签名，导致下次启动被 macOS 以 Launch Constraint Violation 杀掉。
    /// 与 CrashReporter 的崩溃/面包屑保持同一目录（`~/Library/Logs/WeChatAI`）。
    static var bridgeLogDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/WeChatAI/bridge", isDirectory: true)
    }
    static var bridgeLogFile: URL { bridgeLogDirectory.appendingPathComponent("macos.log") }
    static var backupsDirectory: URL { supportDirectory.appendingPathComponent("backups", isDirectory: true) }
    /// 运行期生成的 Hook 配置（含 4.1.15.55 / 4.2.0.x R3 发送开关），不写仓库资源。
    static var runtimeDirectory: URL { supportDirectory.appendingPathComponent("runtime", isDirectory: true) }

    /// 创建全局目录 + 当前账号目录。
    ///
    /// 旧版根目录 `media/` 不再创建（旧媒体只读保留）；新媒体的账号目录由
    /// `AccountProfile` 的当前账号决定（含 `media/` 与 `logs/`）。
    static func ensureDirectories() {
        let urls = [
            supportDirectory,
            accountsDirectory,
            accountDirectory,
            mediaDirectory,
            logsDirectory,
            charactersDirectory,
            bridgeLogDirectory,
            backupsDirectory,
            runtimeDirectory,
        ]
        for url in urls {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Settings sections

enum AppearanceMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: L("跟随系统")
        case .light: L("浅色")
        case .dark: L("深色")
        }
    }
}

enum SleepPreventionMode: String, Codable, CaseIterable, Hashable, Identifiable {
    /// 允许系统按节能设置进入空闲睡眠。
    case never
    /// 仅在接入电源适配器时阻止空闲睡眠；使用电池时允许睡眠。
    case externalPowerOnly
    /// 即使使用电池也阻止空闲睡眠。
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: L("永不")
        case .externalPowerOnly: L("接入电源时")
        case .always: L("始终")
        }
    }

    var detail: String {
        switch self {
        case .never: L("允许系统按节能设置进入空闲睡眠。")
        case .externalPowerOnly: L("仅接入电源适配器时阻止系统空闲睡眠；使用电池时允许系统按节能设置睡眠。")
        case .always: L("即使使用电池也阻止系统空闲睡眠。")
        }
    }
}

struct GeneralSettings: Codable, Hashable {
    var appearance: AppearanceMode = .system
    var showInMenuBar: Bool = true
    var launchAtLogin: Bool = false
    var notificationsEnabled: Bool = true
    var soundEnabled: Bool = false
    var confirmBeforeQuit: Bool = true
    var showDockIcon: Bool = true
    var language: String = "system"
    var sleepPrevention: SleepPreventionMode = .never
}

// Custom Codable so config files written by older versions (which lack newer keys
// such as `sleepPrevention`) keep loading instead of failing the whole settings file.
// The implementation lives in an extension to preserve the synthesized memberwise init.
extension GeneralSettings {
    private enum CodingKeys: String, CodingKey {
        case appearance
        case showInMenuBar
        case launchAtLogin
        case notificationsEnabled
        case soundEnabled
        case confirmBeforeQuit
        case showDockIcon
        case language
        case sleepPrevention
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GeneralSettings()

        // Enums are decoded through their raw value so an unknown value falls back to
        // the default instead of throwing and discarding the user's whole config.
        let appearanceRaw = try container.decodeIfPresent(String.self, forKey: .appearance)
        appearance = appearanceRaw.flatMap { AppearanceMode(rawValue: $0) } ?? defaults.appearance
        showInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? defaults.showInMenuBar
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)
            ?? defaults.notificationsEnabled
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? defaults.soundEnabled
        confirmBeforeQuit = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeQuit)
            ?? defaults.confirmBeforeQuit
        showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? defaults.showDockIcon
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? defaults.language

        let sleepRaw = try container.decodeIfPresent(String.self, forKey: .sleepPrevention)
        sleepPrevention = sleepRaw.flatMap { SleepPreventionMode(rawValue: $0) } ?? defaults.sleepPrevention
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appearance.rawValue, forKey: .appearance)
        try container.encode(showInMenuBar, forKey: .showInMenuBar)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encode(soundEnabled, forKey: .soundEnabled)
        try container.encode(confirmBeforeQuit, forKey: .confirmBeforeQuit)
        try container.encode(showDockIcon, forKey: .showDockIcon)
        try container.encode(language, forKey: .language)
        try container.encode(sleepPrevention.rawValue, forKey: .sleepPrevention)
    }
}

struct HookSettings: Codable, Hashable {
    var wechatPath: String = "/Applications/WeChat.app"
    var gadgetPort: Int = 27042
    var autoLaunchWeChat: Bool = true
    var autoStartBridge: Bool = true
    var versionConfigPath: String = ""
    var lastBackupPath: String = ""
    var didInstallGadget: Bool = false
    /// 4.1.15.55 / 4.2.0.x 使用 R3 原生文本发送（由 App 设置开启）。
    /// 首次使用前需在本机微信手动发送一条消息以捕获发送句柄。
    var enableNativeSend: Bool = true

    private enum CodingKeys: String, CodingKey {
        case wechatPath, gadgetPort, autoLaunchWeChat, autoStartBridge
        case versionConfigPath, lastBackupPath, didInstallGadget, enableNativeSend
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HookSettings()
        wechatPath = try container.decodeIfPresent(String.self, forKey: .wechatPath) ?? defaults.wechatPath
        gadgetPort = try container.decodeIfPresent(Int.self, forKey: .gadgetPort) ?? defaults.gadgetPort
        autoLaunchWeChat = try container.decodeIfPresent(Bool.self, forKey: .autoLaunchWeChat) ?? defaults.autoLaunchWeChat
        autoStartBridge = try container.decodeIfPresent(Bool.self, forKey: .autoStartBridge) ?? defaults.autoStartBridge
        versionConfigPath = try container.decodeIfPresent(String.self, forKey: .versionConfigPath) ?? defaults.versionConfigPath
        lastBackupPath = try container.decodeIfPresent(String.self, forKey: .lastBackupPath) ?? defaults.lastBackupPath
        didInstallGadget = try container.decodeIfPresent(Bool.self, forKey: .didInstallGadget) ?? defaults.didInstallGadget
        enableNativeSend = try container.decodeIfPresent(Bool.self, forKey: .enableNativeSend) ?? defaults.enableNativeSend
    }
}

struct OneBotSettings: Codable, Hashable {
    var host: String = "127.0.0.1"
    var port: Int = 58080
    /// OneBot HTTP 鉴权 Token。默认留空：首次启动机器人时由 App 生成随机值并持久化，
    /// 避免所有部署共用公开的固定默认值。本地 Mock 可手动填 `wechatai-local-token`。
    var token: String = ""
    var connType: String = "websocket"
    var bridgePath: String = ""
    var imagePath: String = ""
}

extension OneBotSettings {
    private enum CodingKeys: String, CodingKey {
        case host, port, token, connType, bridgePath, imagePath
    }

    /// 逐键解码：旧配置缺 `connType` / `bridgePath` / `imagePath` 时不能整段回退，
    /// 否则随机生成的 OneBot token 会被重置，外部 bridge 直接连不上。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OneBotSettings()
        host = (try? container.decodeIfPresent(String.self, forKey: .host)) ?? defaults.host
        port = (try? container.decodeIfPresent(Int.self, forKey: .port)) ?? defaults.port
        token = (try? container.decodeIfPresent(String.self, forKey: .token)) ?? defaults.token
        connType = (try? container.decodeIfPresent(String.self, forKey: .connType))
            ?? defaults.connType
        bridgePath = (try? container.decodeIfPresent(String.self, forKey: .bridgePath))
            ?? defaults.bridgePath
        imagePath = (try? container.decodeIfPresent(String.self, forKey: .imagePath))
            ?? defaults.imagePath
    }
}

/// 识图（视觉）模型设置（2026-10-23 新增）。
///
/// 图片本身不直接进入回复模型上下文：收到图片后先用这里的通道/模型生成一段
/// 文字描述，描述随 `ChatMessage.imageDescription` 落库，再作为普通文本参与
/// 提示词组装。旧 `config.json` 没有 `vision` 键时按「未配置」处理，默认关闭，
/// 不改变既有回复行为。
struct VisionSettings: Codable, Hashable {
    /// 识图提示词默认值；模型只需要输出画面内容，不参与聊天人格。
    static let defaultPrompt = "请用简洁的中文描述这张图片：画面主体、人物与动作、图片里的文字，"
        + "以及可能影响聊天回复的关键信息。只输出描述本身，不要客套或解释，不超过 120 字。"

    /// 是否启用识图。
    var enabled: Bool = false
    /// 识图通道 ID；nil 表示跟随「默认通道」。
    var providerID: String?
    /// 识图模型名；空字符串表示跟随所选通道自己的模型。
    var model: String = ""
    /// 识图提示词；空字符串使用 `defaultPrompt`。
    var prompt: String = VisionSettings.defaultPrompt

    /// 有效模型覆盖；空字符串/空白视为「跟随通道」。
    var modelOverride: String? {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 有效提示词；空白回退到默认提示词。
    var promptText: String {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? Self.defaultPrompt : value
    }
}

struct AISettings: Codable, Hashable {
    var defaultProviderID: String?
    /// 流式总开关：关闭时所有通道都等待完整回复；开启时由各通道自己的 `stream` 决定。
    var streamReplies: Bool = true
    /// 失败后的**额外**重试次数（0 = 不重试），实际最多请求 `retryCount + 1` 次。
    var retryCount: Int = 1
    /// 按模型名（如 `deepseek-chat`）单独配置的温度。
    /// `nil` 表示尚未迁移；字典中缺失某个模型时，请求不发送 temperature，
    /// 由模型自身使用默认温度。
    var modelTemperatures: [String: Double]?
    /// 识图模型设置；nil 表示未配置（旧配置/默认关闭）。
    var vision: VisionSettings?
    /// 当前模型生效的自定义温度；未配置返回 `nil`（模型默认）。
    func temperature(forModel model: String) -> Double? {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let value = modelTemperatures?[key] else { return nil }
        return min(max(value, 0), 2)
    }
}

extension AISettings {
    private enum CodingKeys: String, CodingKey {
        case defaultProviderID, streamReplies, retryCount, modelTemperatures, vision
    }

    /// 旧 `config.json` 没有 `streamReplies` / `retryCount` / `vision` 时只回退这些
    /// 字段的默认值，不让整份 `AppSettings` 解码失败（那会连 onebot token 一起重置）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AISettings()
        defaultProviderID = try? container.decodeIfPresent(String.self, forKey: .defaultProviderID)
        streamReplies = (try? container.decodeIfPresent(Bool.self, forKey: .streamReplies))
            ?? defaults.streamReplies
        retryCount = (try? container.decodeIfPresent(Int.self, forKey: .retryCount))
            ?? defaults.retryCount
        modelTemperatures = try? container.decodeIfPresent(
            [String: Double].self, forKey: .modelTemperatures)
        vision = try? container.decodeIfPresent(VisionSettings.self, forKey: .vision)
    }
}

// MARK: - Full persisted state

struct AppSettings: Codable, Hashable {
    var schemaVersion: Int = 1
    var general = GeneralSettings()
    var hook = HookSettings()
    var onebot = OneBotSettings()
    var ai = AISettings()
    var bot = BotSettings()

    var providers: [AIProvider] = [AppSettings.makeDefaultProvider()]
    var personas: [Persona] = [AppSettings.makeDefaultPersona()]
    var schedules: [ScheduledTask] = []

    static func makeDefaultProvider() -> AIProvider {
        AIProvider(
            id: "provider-deepseek-default",
            name: "DeepSeek",
            kind: .deepSeek,
            baseURL: ProviderKind.deepSeek.defaultBaseURL,
            model: ProviderKind.deepSeek.defaultModel,
            apiKeyReference: "provider-deepseek-default",
            temperature: 0.7,
            maxTokens: 800,
            timeoutSeconds: 60,
            stream: true,
            enabled: true,
            isDefault: true
        )
    }

    static func makeDefaultPersona() -> Persona {
        Persona(
            id: "persona-default",
            name: "默认助手",
            summary: "自然、简洁、像真人聊天",
            systemPrompt: Persona.defaultSystemPrompt,
            isDefault: true
        )
    }

    static var `default`: AppSettings {
        var settings = AppSettings()
        settings.ai.defaultProviderID = settings.providers.first?.id
        settings.bot.defaultProviderID = settings.providers.first?.id
        settings.bot.defaultPersonaID = settings.personas.first?.id
        return settings
    }

    var defaultProvider: AIProvider? {
        if let id = ai.defaultProviderID, let p = providers.first(where: { $0.id == id }) { return p }
        return providers.first(where: \.isDefault) ?? providers.first
    }

    func provider(id: String?) -> AIProvider? {
        guard let id else { return defaultProvider }
        return providers.first(where: { $0.id == id }) ?? defaultProvider
    }

    /// 识图总开关：未配置 `vision` 视为关闭（旧配置行为不变）。
    var isVisionEnabled: Bool { ai.vision?.enabled == true }

    /// 识图通道：显式选择的通道存在时用它，否则回退到默认通道。
    var visionProvider: AIProvider? {
        if let id = ai.vision?.providerID,
           let provider = providers.first(where: { $0.id == id }) {
            return provider
        }
        return defaultProvider
    }

    /// 识图实际使用的模型名：设置里的覆盖值优先，否则跟随通道模型。
    func visionModel(for provider: AIProvider) -> String {
        ai.vision?.modelOverride ?? AIClient.effectiveModel(for: provider)
    }

    /// 识图请求使用的通道副本：模型换成识图模型，并用更短的超时/更小的输出上限，
    /// 避免识图失败把一次自动回复拖到 60 秒。非流式（只需要最终描述）。
    func visionRequestProvider(from provider: AIProvider) -> AIProvider {
        var copy = provider
        copy.model = visionModel(for: provider)
        copy.timeoutSeconds = min(max(provider.timeoutSeconds, 5), Self.visionTimeoutSeconds)
        copy.maxTokens = min(max(provider.maxTokens, 64), Self.visionMaxTokens)
        copy.stream = false
        return copy
    }

    /// 识图请求的最短/最长等待时间（秒）与输出上限。
    /// DeepSeek `deepseek-flash` 默认开启思考模式；识图请求会显式关闭（见
    /// `VisionSupport.thinkingMode`），因此 800 tokens 足够输出短描述。
    static let visionTimeoutSeconds: Double = 30
    static let visionMaxTokens: Int = 800

    func persona(id: String?) -> Persona? {
        if let id, let p = personas.first(where: { $0.id == id }) { return p }
        return personas.first(where: \.isDefault) ?? personas.first
    }
}

// MARK: - Account-level settings (profile.json)

/// 账号级设置：随微信账号切换，单独持久化到 `accounts/<id>/profile.json`。
///
/// `config.json` 仍然保存完整 `AppSettings` 镜像（兼容旧版回滚与迁移），但加载时
/// 以当前账号的 `profile.json` 覆盖 `bot / personas / schedules`；全局字段
/// （general / hook / onebot / ai / providers）只存在于 `config.json`。
struct ProfileSettings: Codable, Hashable {
    /// `profile.json` 的结构版本，与 `AppSettings.schemaVersion` 相互独立（当前都为 1）。
    var schemaVersion: Int = 1
    var bot = BotSettings()
    var personas: [Persona] = [AppSettings.makeDefaultPersona()]
    var schedules: [ScheduledTask] = []

    static var `default`: ProfileSettings { ProfileSettings() }
}

// 自定义解码：旧版/部分写入/手改的 profile.json 缺某个键时只回退该键的默认值，
// 不丢弃整份文件。实现放在 extension 里以保留合成的 memberwise init。
extension ProfileSettings {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bot, personas, schedules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProfileSettings()
        schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion))
            ?? defaults.schemaVersion
        bot = (try? container.decodeIfPresent(BotSettings.self, forKey: .bot)) ?? defaults.bot
        personas = (try? container.decodeIfPresent([Persona].self, forKey: .personas))
            ?? defaults.personas
        schedules = (try? container.decodeIfPresent([ScheduledTask].self, forKey: .schedules))
            ?? defaults.schedules
    }
}

extension AppSettings {
    /// 从完整设置中抽出账号级部分（用于写 `profile.json`）。
    var profile: ProfileSettings {
        get {
            // profile 结构版本独立于 AppSettings.schemaVersion，固定 1；
            // 全局 schema 升级不应连带把账号 profile 的版本号抬高。
            ProfileSettings(schemaVersion: 1, bot: bot, personas: personas, schedules: schedules)
        }
        set { applyProfile(newValue) }
    }

    /// 用账号级设置覆盖 `bot / personas / schedules`，其余全局字段保持不变。
    mutating func applyProfile(_ profile: ProfileSettings) {
        bot = profile.bot
        personas = profile.personas
        schedules = profile.schedules
    }
}

// MARK: - Load / save

enum SettingsStore {
    /// 应用默认加载：全局 `config.json` + 当前账号 `profile.json`。
    static func load() -> AppSettings {
        AppPaths.ensureDirectories()
        return load(configURL: AppPaths.configFile, profileURL: AppPaths.profileFile)
    }

    /// 可注入加载（测试用）：先读全局 config，再用账号 profile 覆盖账号字段。
    /// `profileURL == nil` 时只读 config（旧版行为，profile 不存在也走这里）。
    static func load(configURL: URL, profileURL: URL?) -> AppSettings {
        var settings = loadConfig(configURL: configURL)
        if let profileURL {
            settings.applyProfile(loadProfile(profileURL: profileURL))
        }
        return settings
    }

    /// 读取账号级 profile：缺失 → `.default`；损坏 → 备份 `profile.corrupt-<ts>.json` 后 `.default`。
    static func loadProfile(profileURL: URL) -> ProfileSettings {
        guard let data = try? Data(contentsOf: profileURL) else { return .default }
        do {
            return try JSONDecoder().decode(ProfileSettings.self, from: data)
        } catch {
            NSLog("[WeChatAI] profile decode failed: \(error)")
            let backup = profileURL.deletingLastPathComponent()
                .appendingPathComponent("profile.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: profileURL, to: backup)
            return .default
        }
    }

    private static func loadConfig(configURL: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: configURL) else { return .default }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            NSLog("[WeChatAI] config decode failed: \(error)")
            let backup = configURL.deletingLastPathComponent()
                .appendingPathComponent("config.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: configURL, to: backup)
            // 整体解码失败时按顶层段逐个降级解析：单个段损坏只丢该段，
            // 不让 onebot token / hook.wechatPath / providers 一起回退默认值。
            return decodeSectionsLossily(data)
        }
    }

    /// 逐段降级解析 `config.json`。
    ///
    /// 旧版配置缺新键、或某一段被手改坏时，`AppSettings` 整体 `decode` 会抛错；
    /// 这里按顶层 key 分别解码，失败的段保留 `AppSettings.default` 中的默认值。
    private static func decodeSectionsLossily(_ data: Data) -> AppSettings {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .default
        }
        var settings = AppSettings.default
        let decoder = JSONDecoder()

        func decode<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            guard let value = raw[key], JSONSerialization.isValidJSONObject(value),
                  let section = try? JSONSerialization.data(withJSONObject: value),
                  let decoded = try? decoder.decode(T.self, from: section)
            else { return nil }
            return decoded
        }

        if let number = raw["schemaVersion"] as? NSNumber {
            settings.schemaVersion = number.intValue
        }
        if let value = decode("general", as: GeneralSettings.self) { settings.general = value }
        if let value = decode("hook", as: HookSettings.self) { settings.hook = value }
        if let value = decode("onebot", as: OneBotSettings.self) { settings.onebot = value }
        if let value = decode("ai", as: AISettings.self) { settings.ai = value }
        if let value = decode("bot", as: BotSettings.self) { settings.bot = value }
        if let value = decode("providers", as: [AIProvider].self) { settings.providers = value }
        if let value = decode("personas", as: [Persona].self) { settings.personas = value }
        if let value = decode("schedules", as: [ScheduledTask].self) { settings.schedules = value }
        NSLog("[WeChatAI] config decoded lossily: 保留可用段，损坏段回退默认值")
        return settings
    }

    /// 只写全局 `config.json`（账号字段由 `SettingsPersistence.save(_:profileURL:)` 双写）。
    static func save(_ settings: AppSettings) {
        AppPaths.ensureDirectories()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            let tmp = AppPaths.configFile.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(AppPaths.configFile, withItemAt: tmp)
        } catch {
            NSLog("[WeChatAI] config save failed: \(error)")
        }
    }
}
