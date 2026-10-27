import XCTest
@testable import WeChatAI

/// 账号级设置（`profile.json`）与全局设置（`config.json`）拆分持久化测试。
///
/// 覆盖实施契约 §2.3：全局/账号字段分文件、双文件写入后合并加载、profile 缺失/损坏回退、
/// 旧版 config.json（含 bot/personas/schedules）兼容且被 profile 覆盖、双写按文件去重。
final class SettingsProfileTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL!
    private var profileURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechatai-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configURL = directory.appendingPathComponent("config.json")
        profileURL = directory
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent("wxid_test", isDirectory: true)
            .appendingPathComponent("profile.json")
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - File split

    func testGlobalAndAccountFieldsGoToSeparateFiles() async throws {
        var settings = AppSettings.default
        settings.general.language = "en"
        settings.hook.gadgetPort = 27043
        settings.onebot.port = 58090
        settings.ai.retryCount = 5
        settings.providers[0].name = "全局通道"
        settings.bot.enabled = true
        settings.bot.keywords = ["账号关键词"]
        settings.personas = [
            Persona(
                id: "persona-account",
                name: "账号人格",
                summary: "账号摘要",
                systemPrompt: "账号提示词",
                isDefault: true
            )
        ]
        settings.schedules = [
            ScheduledTask(
                id: "schedule-account",
                name: "账号任务",
                conversationID: "conversation-account",
                content: "早安"
            )
        ]

        let persistence = SettingsPersistence(configURL: configURL)
        let changed = try await persistence.save(settings, profileURL: profileURL)
        XCTAssertTrue(changed)

        // config.json：完整镜像，包含全部全局字段。
        let configRoot = try jsonObject(at: configURL)
        XCTAssertNotNil(configRoot["general"])
        XCTAssertNotNil(configRoot["hook"])
        XCTAssertNotNil(configRoot["onebot"])
        XCTAssertNotNil(configRoot["ai"])
        XCTAssertNotNil(configRoot["providers"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))

        // profile.json：只有账号级四个键，不含全局字段。
        let profileRoot = try jsonObject(at: profileURL)
        XCTAssertEqual(Set(profileRoot.keys), ["schemaVersion", "bot", "personas", "schedules"])
        XCTAssertNil(profileRoot["general"])
        XCTAssertNil(profileRoot["hook"])
        XCTAssertNil(profileRoot["onebot"])
        XCTAssertNil(profileRoot["ai"])
        XCTAssertNil(profileRoot["providers"])

        let profileBot = try XCTUnwrap(profileRoot["bot"] as? [String: Any])
        XCTAssertEqual(profileBot["enabled"] as? Bool, true)
        XCTAssertEqual(profileBot["keywords"] as? [String], ["账号关键词"])
        let profilePersonas = try XCTUnwrap(profileRoot["personas"] as? [[String: Any]])
        XCTAssertEqual(profilePersonas.first?["name"] as? String, "账号人格")
        let profileSchedules = try XCTUnwrap(profileRoot["schedules"] as? [[String: Any]])
        XCTAssertEqual(profileSchedules.first?["name"] as? String, "账号任务")
    }

    // MARK: - Merge on load

    func testLoadMergesGlobalConfigAndAccountProfile() async throws {
        var settings = AppSettings.default
        settings.general.language = "zh-Hant"
        settings.hook.wechatPath = "/Applications/WeChatBeta.app"
        settings.onebot.host = "10.0.0.2"
        settings.ai.retryCount = 7
        settings.providers[0].name = "合并通道"
        settings.bot.cooldownSeconds = 12
        settings.bot.keywords = ["合并关键词"]
        settings.personas = [
            Persona(id: "persona-merge", name: "合并人格", systemPrompt: "合并提示词", isDefault: true)
        ]
        settings.schedules = [
            ScheduledTask(
                id: "schedule-merge",
                name: "合并任务",
                conversationID: "conversation-merge",
                content: "午安"
            )
        ]

        let persistence = SettingsPersistence(configURL: configURL)
        _ = try await persistence.save(settings, profileURL: profileURL)

        let loaded = SettingsStore.load(configURL: configURL, profileURL: profileURL)
        XCTAssertEqual(loaded.general, settings.general)
        XCTAssertEqual(loaded.hook, settings.hook)
        XCTAssertEqual(loaded.onebot, settings.onebot)
        XCTAssertEqual(loaded.ai, settings.ai)
        XCTAssertEqual(loaded.providers, settings.providers)
        XCTAssertEqual(loaded.bot, settings.bot)
        XCTAssertEqual(loaded.personas, settings.personas)
        XCTAssertEqual(loaded.schedules, settings.schedules)
    }

    func testMissingProfileFallsBackToDefaultAccountSettings() async throws {
        var settings = AppSettings.default
        settings.general.language = "en"
        settings.bot.enabled = true
        settings.bot.keywords = ["只在 config 镜像里"]

        let persistence = SettingsPersistence(configURL: configURL)
        _ = try await persistence.save(settings, profileURL: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileURL.path))

        let loaded = SettingsStore.load(configURL: configURL, profileURL: profileURL)
        // 全局字段来自 config.json。
        XCTAssertEqual(loaded.general.language, "en")
        // 账号字段回退默认值。
        XCTAssertEqual(loaded.bot, ProfileSettings.default.bot)
        XCTAssertEqual(loaded.personas, ProfileSettings.default.personas)
        XCTAssertEqual(loaded.schedules, [ScheduledTask]())
    }

    func testCorruptProfileIsBackedUpAndFallsBackToDefaults() throws {
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let garbage = "{ 这不是合法 JSON"
        try Data(garbage.utf8).write(to: profileURL)

        let profile = SettingsStore.loadProfile(profileURL: profileURL)
        XCTAssertEqual(profile, ProfileSettings.default)

        let directoryURL = profileURL.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        let backups = names.filter { $0.hasPrefix("profile.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups.count, 1)
        let backupName = try XCTUnwrap(backups.first)
        let backupURL = directoryURL.appendingPathComponent(backupName)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), garbage)
    }

    // MARK: - Legacy config compatibility

    func testLegacyConfigAccountFieldsStillDecodeAndProfileOverrides() throws {
        var legacy = AppSettings.default
        legacy.bot.enabled = true
        legacy.bot.keywords = ["旧 config 关键词"]
        legacy.personas = [
            Persona(id: "persona-legacy", name: "旧人格", systemPrompt: "旧提示词", isDefault: true)
        ]
        legacy.schedules = [
            ScheduledTask(
                id: "schedule-legacy",
                name: "旧任务",
                conversationID: "conversation-legacy",
                content: "旧内容"
            )
        ]
        try JSONEncoder().encode(legacy).write(to: configURL)

        // 旧版单文件 config.json（自带 bot/personas/schedules）仍可正常 decode。
        let configOnly = SettingsStore.load(configURL: configURL, profileURL: nil)
        XCTAssertEqual(configOnly.bot, legacy.bot)
        XCTAssertEqual(configOnly.personas, legacy.personas)
        XCTAssertEqual(configOnly.schedules, legacy.schedules)

        // 有新 profile.json 时账号字段以 profile 为准（旧 config 的镜像值被覆盖）。
        var profileBot = BotSettings()
        profileBot.keywords = ["新 profile 关键词"]
        let profile = ProfileSettings(
            schemaVersion: 1,
            bot: profileBot,
            personas: [Persona(id: "persona-profile", name: "新人格", systemPrompt: "新提示词", isDefault: true)],
            schedules: []
        )
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(profile).write(to: profileURL)

        let merged = SettingsStore.load(configURL: configURL, profileURL: profileURL)
        XCTAssertEqual(merged.bot, profile.bot)
        XCTAssertEqual(merged.personas, profile.personas)
        XCTAssertEqual(merged.schedules, [ScheduledTask]())
        // 全局字段仍来自 config.json。
        XCTAssertEqual(merged.general, legacy.general)
        XCTAssertEqual(merged.hook, legacy.hook)
        XCTAssertEqual(merged.onebot, legacy.onebot)
        XCTAssertEqual(merged.ai, legacy.ai)
        XCTAssertEqual(merged.providers, legacy.providers)
    }

    func testLegacySaveWritesConfigOnly() async throws {
        let persistence = SettingsPersistence(configURL: configURL)
        var settings = AppSettings.default
        settings.bot.keywords = ["legacy save"]
        _ = try await persistence.save(settings)

        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: profileURL.path),
            "旧 save(_:) 等价 profileURL=nil，只写 config；账号字段由 persist() 显式双写"
        )
        let configOnly = SettingsStore.load(configURL: configURL, profileURL: nil)
        XCTAssertEqual(configOnly.bot.keywords, ["legacy save"])
    }

    // MARK: - Dedupe

    func testDoubleSaveDedupesPerFile() async throws {
        var settings = AppSettings.default
        settings.general.language = "en"
        let persistence = SettingsPersistence(configURL: configURL)

        let first = try await persistence.save(settings, profileURL: profileURL)
        XCTAssertTrue(first)
        let repeated = try await persistence.save(settings, profileURL: profileURL)
        XCTAssertFalse(repeated)

        // 只改全局字段：config 变化，profile 字节不变。
        settings.general.language = "zh-Hans"
        let globalChanged = try await persistence.save(settings, profileURL: profileURL)
        XCTAssertTrue(globalChanged)
        let globalRepeated = try await persistence.save(settings, profileURL: profileURL)
        XCTAssertFalse(globalRepeated)

        // 只改账号字段：profile 变化（config 镜像也随之变化）。
        settings.bot.keywords = ["仅账号字段变化"]
        let accountChanged = try await persistence.save(settings, profileURL: profileURL)
        XCTAssertTrue(accountChanged)
        let accountRepeated = try await persistence.save(settings, profileURL: profileURL)
        XCTAssertFalse(accountRepeated)
    }

    // MARK: - AppPaths delegation

    func testAppPathsDelegateAccountScopedLocations() {
        XCTAssertEqual(AppPaths.configFile.lastPathComponent, "config.json")
        XCTAssertEqual(AppPaths.profileFile.lastPathComponent, "profile.json")
        XCTAssertEqual(
            AppPaths.profileFile.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "accounts"
        )

        let accountDirectory = AppPaths.accountDirectory
        XCTAssertEqual(accountDirectory.deletingLastPathComponent(), AppPaths.accountsDirectory)
        XCTAssertEqual(AppPaths.databaseFile, accountDirectory.appendingPathComponent("chatbot.sqlite"))
        XCTAssertEqual(
            AppPaths.mediaDirectory,
            accountDirectory.appendingPathComponent("media", isDirectory: true)
        )
        XCTAssertEqual(
            AppPaths.logsDirectory,
            accountDirectory.appendingPathComponent("logs", isDirectory: true)
        )

        let supportDirectory = AppPaths.supportDirectory
        XCTAssertEqual(AppPaths.legacyDatabaseFile, supportDirectory.appendingPathComponent("chatbot.sqlite"))
        XCTAssertEqual(
            AppPaths.legacyMediaDirectory,
            supportDirectory.appendingPathComponent("media", isDirectory: true)
        )
        XCTAssertEqual(
            AppPaths.accountStateFile,
            supportDirectory.appendingPathComponent("account-state.json")
        )
        XCTAssertEqual(
            AppPaths.accountsDirectory,
            supportDirectory.appendingPathComponent("accounts", isDirectory: true)
        )
    }

    // MARK: - Old config compatibility (missing new keys)

    func testOldConfigMissingNewFieldsKeepsGlobalSections() throws {
        // 模拟旧版 config.json：bot 缺 humanize/workingHours/pat，ai 缺 streamReplies/vision。
        let json = """
        {
          "schemaVersion": 1,
          "hook": { "wechatPath": "/Applications/WeChat.app", "enableNativeSend": false },
          "onebot": { "host": "127.0.0.1", "port": 58080, "token": "legacy-token" },
          "ai": { "retryCount": 3 },
          "bot": { "enabled": true, "keywords": ["旧关键词"] },
          "providers": [{
            "id": "p1", "name": "DeepSeek", "kind": "deepSeek",
            "baseURL": "https://api.deepseek.com", "model": "deepseek-chat",
            "apiKeyReference": "p1", "temperature": 0.7, "maxTokens": 800,
            "timeoutSeconds": 60, "stream": true, "enabled": true, "isDefault": true
          }],
          "personas": [],
          "schedules": []
        }
        """
        try Data(json.utf8).write(to: configURL)

        let loaded = SettingsStore.load(configURL: configURL, profileURL: nil)

        // 关键全局字段不能被整份默认值覆盖。
        XCTAssertEqual(loaded.onebot.token, "legacy-token")
        XCTAssertEqual(loaded.hook.wechatPath, "/Applications/WeChat.app")
        XCTAssertEqual(loaded.ai.retryCount, 3)
        XCTAssertEqual(loaded.bot.keywords, ["旧关键词"])
        XCTAssertEqual(loaded.providers.first?.id, "p1")
        // 缺失的新键回退该字段默认值。
        XCTAssertEqual(loaded.bot.humanize, HumanizeSettings())
        XCTAssertEqual(loaded.bot.workingHours, WorkingHours())
        XCTAssertEqual(loaded.ai.streamReplies, true)
    }

    func testCorruptSingleSectionFallsBackLossilyInsteadOfResettingEverything() throws {
        // general 段被手改坏，但 hook/onebot/providers 仍然完好：只丢 general。
        let json = """
        {
          "schemaVersion": 1,
          "general": 12345,
          "hook": { "wechatPath": "/Applications/WeChat.app" },
          "onebot": { "host": "127.0.0.1", "port": 58080, "token": "keep-me" },
          "providers": [{
            "id": "p1", "name": "DeepSeek", "kind": "deepSeek",
            "baseURL": "https://api.deepseek.com", "model": "deepseek-chat",
            "apiKeyReference": "p1", "temperature": 0.7, "maxTokens": 800,
            "timeoutSeconds": 60, "stream": true, "enabled": true, "isDefault": true
          }]
        }
        """
        try Data(json.utf8).write(to: configURL)

        let loaded = SettingsStore.load(configURL: configURL, profileURL: nil)

        XCTAssertEqual(loaded.onebot.token, "keep-me")
        XCTAssertEqual(loaded.hook.wechatPath, "/Applications/WeChat.app")
        XCTAssertEqual(loaded.providers.first?.id, "p1")
        XCTAssertEqual(loaded.general, GeneralSettings())
    }

    // MARK: - Helpers

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
