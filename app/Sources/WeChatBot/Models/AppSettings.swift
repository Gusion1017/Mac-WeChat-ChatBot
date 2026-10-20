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
    /// 运行期生成的 Hook 配置（含 4.1.15.55 R3 发送开关），不写仓库资源。
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
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
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
        case .never: "永不"
        case .externalPowerOnly: "接入电源时"
        case .always: "始终"
        }
    }

    var detail: String {
        switch self {
        case .never: "允许系统按节能设置进入空闲睡眠。"
        case .externalPowerOnly: "仅接入电源适配器时阻止系统空闲睡眠；使用电池时允许系统按节能设置睡眠。"
        case .always: "即使使用电池也阻止系统空闲睡眠。"
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
    var language: String = "zh-Hans"
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
    /// 4.1.15.55 使用 R3 原生发送（构造 newsendmsg task + slot13 提交）。
    /// 首次使用前需在本机微信手动发送一条消息以捕获 hand-off 闭包（种子）。
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
    var token: String = "wechatai-local-token"
    var connType: String = "websocket"
    var bridgePath: String = ""
    var imagePath: String = ""
}

struct AISettings: Codable, Hashable {
    var defaultProviderID: String?
    var streamReplies: Bool = true
    var requestTimeoutSeconds: Double = 60
    var retryCount: Int = 1
    /// 按模型名（如 `deepseek-chat`）单独配置的温度。
    /// `nil` 表示尚未迁移；字典中缺失某个模型时，请求不发送 temperature，
    /// 由模型自身使用默认温度。
    var modelTemperatures: [String: Double]?

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
