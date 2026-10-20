import Foundation
import Observation

/// Central application store. UI reads observable state from here.
/// Runtime wiring (OneBot / AI / memory / scheduler) lives in `Services/` and is
/// composed by the `AppStore+Runtime` extension.
@MainActor
@Observable
final class AppStore {
    // Persisted state
    var settings: AppSettings
    var providers: [AIProvider]
    var personas: [Persona]
    var schedules: [ScheduledTask]

    // Runtime state
    var hookStatus = HookStatus()
    var stats = BotStats()
    var conversations: [Conversation] = []
    var messages: [String: [ChatMessage]] = [:]
    var longTermMemories: [LongTermMemory] = []
    var logs: [LogEntry] = []

    var sidebarSelection: SidebarItem? = .dashboard
    var selectedConversationID: String?
    var isBotRunning = false
    var isBusy = false
    var isOnboardingPresented = false
    var gatewayConnected = false
    var lastError: String?

    init(settings: AppSettings = SettingsStore.load()) {
        self.settings = settings
        self.providers = settings.providers
        self.personas = settings.personas
        self.schedules = settings.schedules
        self.hookStatus.versionConfigFile = settings.hook.versionConfigPath
        self.hookStatus.wechatVersion = Self.installedWeChatVersion(path: settings.hook.wechatPath) ?? ""
        RuntimeBootstrap.scheduleRuntime(for: self)
    }

    // MARK: Derived

    var selectedConversation: Conversation? {
        guard let id = selectedConversationID else { return nil }
        return conversations.first(where: { $0.id == id })
    }

    var selectedMessages: [ChatMessage] {
        guard let id = selectedConversationID else { return [] }
        return messages[id] ?? []
    }

    var defaultProvider: AIProvider? {
        settings.provider(id: settings.ai.defaultProviderID)
    }

    // MARK: Persistence

    func persist() {
        settings.providers = providers
        settings.personas = personas
        settings.schedules = schedules
        settings.bot.defaultProviderID = settings.ai.defaultProviderID
        let snapshot = settings
        // Encoding/atomic write happens on SettingsPersistence's actor, never on MainActor.
        Task { try? await SettingsPersistence.shared.save(snapshot) }
        RuntimeRegistry.existing(for: self)?.settingsDidChange()
    }

    func reload() {
        let loaded = SettingsStore.load()
        settings = loaded
        providers = loaded.providers
        personas = loaded.personas
        schedules = loaded.schedules
    }

    // MARK: Logs (runtime methods live in AppStore+Runtime.swift)

    func appendLog(_ level: LogLevel, _ source: String, _ message: String) {
        logs.append(LogEntry(level: level, source: source, message: message))
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }
    func clearLogs() { logs.removeAll() }

    // MARK: Helpers

    static func installedWeChatVersion(path: String) -> String? {
        let info = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["WeChatBundleVersion"] as? String ?? plist["CFBundleShortVersionString"] as? String
    }
}
