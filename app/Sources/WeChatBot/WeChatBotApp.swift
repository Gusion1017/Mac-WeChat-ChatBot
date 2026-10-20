import AppKit
import SwiftUI

@main
struct WeChatAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: AppStore
    @State private var toastCenter = ToastCenter()
    @State private var showMenuBar: Bool

    init() {
        let store = AppStore()
        _store = State(initialValue: store)
        _showMenuBar = State(initialValue: store.settings.general.showInMenuBar)
    }

    var body: some Scene {
        Window("WeChat AI", id: "main") {
            RootView()
                .syncActivationPolicy()
                .environment(store)
                .environment(toastCenter)
                .frame(minWidth: 1100, minHeight: 720)
                .background(Theme.pageGradient)
                .onChange(of: store.settings.general.showInMenuBar) { _, newValue in
                    showMenuBar = newValue
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            AppCommands(store: store)
        }

        Settings {
            SettingsView()
                .syncActivationPolicy()
                .environment(store)
                .environment(toastCenter)
                .frame(minWidth: 880, minHeight: 640)
                .toastOverlay()
                .preferredColorScheme(colorScheme(for: store.settings.general.appearance))
                .onChange(of: store.settings.general.showInMenuBar) { _, newValue in
                    showMenuBar = newValue
                }
        }

        MenuBarExtra(
            "WeChat AI",
            systemImage: "bubble.left.and.bubble.right",
            isInserted: menuBarInserted
        ) {
            MenuBarView()
                .environment(store)
                .environment(toastCenter)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { showMenuBar },
            set: { newValue in
                guard showMenuBar != newValue else { return }
                showMenuBar = newValue
                store.settings.general.showInMenuBar = newValue
                store.persist()
            }
        )
    }

    private func colorScheme(for mode: AppearanceMode) -> ColorScheme? {
        switch mode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Menu bar commands: page navigation (⌘1…⌘9, ⌘0 for settings) and onboarding.
struct AppCommands: Commands {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        // ⌘Q is deliberately unbound (⇧⌘Q is reserved by macOS for log out):
        // shortcut or the menu bar, so an accidental ⌘Q cannot stop the bot.
        CommandGroup(replacing: .appTermination) {
            Button("退出 WeChat AI") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command, .option])
        }

        CommandMenu("前往") {
            ForEach(SidebarItem.allCases) { item in
                Button(item.title) {
                    store.sidebarSelection = item
                    openMainWindow()
                }
                .keyboardShortcut(shortcut(for: item), modifiers: .command)
            }
        }
    }

    private func shortcut(for item: SidebarItem) -> KeyEquivalent {
        switch item {
        case .dashboard: "1"
        case .conversations: "2"
        case .bot: "3"
        case .ai: "4"
        case .personas: "5"
        case .memory: "6"
        case .schedules: "7"
        case .logs: "8"
        case .settings: "0"
        }
    }

    private func openMainWindow() {
        if MainWindowRegistry.show() { return }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
