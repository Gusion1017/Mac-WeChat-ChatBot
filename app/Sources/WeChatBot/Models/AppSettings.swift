import Foundation

// MARK: - Paths

enum AppPaths {
    static let appName = "WeChatAI"
    static let bundleID = "com.gusionw.wechatai"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    static var databaseFile: URL { supportDirectory.appendingPathComponent("chatbot.sqlite") }
    static var logsDirectory: URL { supportDirectory.appendingPathComponent("logs", isDirectory: true) }
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
    static var mediaDirectory: URL { supportDirectory.appendingPathComponent("media", isDirectory: true) }
    /// 运行期生成的 Hook 配置（含 4.1.15.55 / 4.2.0.5 R3 发送开关），不写仓库资源。
    static var runtimeDirectory: URL { supportDirectory.appendingPathComponent("runtime", isDirectory: true) }

    static func ensureDirectories() {
        for url in [supportDirectory, logsDirectory, bridgeLogDirectory, backupsDirectory, mediaDirectory, runtimeDirectory] {
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
    /// 4.1.15.55 / 4.2.0.5 使用 R3 原生文本发送（由 App 设置开启）。
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

// MARK: - Load / save

enum SettingsStore {
    static func load() -> AppSettings {
        AppPaths.ensureDirectories()
        guard let data = try? Data(contentsOf: AppPaths.configFile) else { return .default }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            NSLog("[WeChatAI] config decode failed: \(error)")
            let backup = AppPaths.supportDirectory.appendingPathComponent("config.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: AppPaths.configFile, to: backup)
            return .default
        }
    }

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
