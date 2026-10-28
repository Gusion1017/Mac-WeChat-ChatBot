import AppKit
import SwiftUI

@main
struct WeChatAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: AppStore
    @State private var toastCenter: ToastCenter

    init() {
        // 稳定性：布局安全阀必须早于任何 SwiftUI 场景 / AppKit 窗口出现，
        // 否则 macOS 26 的显示周期断言会把一次布局回环升级成 EXC_BREAKPOINT 闪退。
        // 细节与取证见 `Services/CrashReporter.swift`。
        AppKitLayoutGuard.install("App.init")
        // 崩溃取证：尽可能早安装（AppKit 启动时会覆盖顶层处理器，
        // AppDelegate 的 launch 回调里会再装回来）。
        CrashReporter.install()
        // 自愈：旧版 bridge 曾把日志写进 app bundle（Contents/Resources/bridge/log），
        // 破坏 ad-hoc 签名，导致下次启动被系统杀掉。新版已把日志外置；这里清掉残留。
        if AppResources.removeLegacyBridgeLog() {
            LogPipeline.shared.emit(.warning, "Runtime", "已清理 app bundle 内旧版 bridge 日志目录（修复签名）")
        }

        let store = AppStore()
        _store = State(initialValue: store)
        let toastCenter = ToastCenter()
        _toastCenter = State(initialValue: toastCenter)

        attachStabilityHooks(to: store)
        // 菜单栏不再使用 MenuBarExtra（无法区分左右键）：由 AppKit 状态栏条目承载，
        // 左键开合 NSPopover 状态面板，右键不执行操作。这里注入依赖，
        // AppDelegate 启动完成后再创建条目。
        MenuBarController.shared.configure(store: store)
    }

    /// 把主线程现场快照与看门狗回调挂到会话 store 上。
    ///
    /// 全部用 `[weak store]`：`CrashReporter` 的静态存储不会延长 `AppStore` 生命周期，
    /// 也不构成引用环。
    private func attachStabilityHooks(to store: AppStore) {
        CrashReporter.attach(
            probe: { [weak store] in
                let window = MainWindowRegistry.window
                let windowSummary: String
                if let window {
                    let size = window.frame.size
                    windowSummary = "main \(Int(size.width))×\(Int(size.height))"
                        + " visible=\(window.isVisible)"
                        + " key=\(window.isKeyWindow)"
                        + " mini=\(window.isMiniaturized)"
                        + " sheet=\(window.attachedSheet != nil)"
                } else {
                    windowSummary = "无主窗口"
                }
                return CrashReporter.Probe(
                    sidebarPage: store?.sidebarSelection?.title ?? "-",
                    botRunning: store?.isBotRunning ?? false,
                    windowSummary: windowSummary,
                    logCount: store?.logs.count ?? 0,
                    lastLogTime: store?.logs.last?.date.timeIntervalSince1970 ?? 0
                )
            },
            logs: { [weak store] in
                guard let store else { return [] }
                return Array(store.logs.suffix(50))
            }
        )

        MainThreadWatchdog.shared.onStall = { message in
            // 后台线程直接写入共享日志管道：`LogPipeline.emit` 是 nonisolated +
            // 锁保护，不经过 MainActor，主线程卡住时也不会死锁。
            LogPipeline.shared.emit(.warning, "Watchdog", message)
        }
    }

    var body: some Scene {
        Window("WeChat AI", id: MainWindowRegistry.mainWindowID) {
            RootView()
                .syncActivationPolicy()
                .captureMainWindowOpenAction()
                .environment(store)
                .environment(toastCenter)
                .environment(\.locale, appLocale)
                .frame(minWidth: 1100, minHeight: 720)
                .background(Theme.pageGradient)
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
                .environment(\.locale, appLocale)
                .frame(minWidth: 880, minHeight: 640)
                .toastOverlay()
                .preferredColorScheme(colorScheme(for: store.settings.general.appearance))
                // Environment modifiers must stay OUTERMOST on the Settings scene:
                // `toastOverlay()` and `syncActivationPolicy()` are views too, and when
                // `.environment(...)` was applied inside them the settings-window toast
                // overlay had no `ToastCenter`. Opening Settings then aborted with
                // "Fatal error: No Observable object of type ToastCenter found"
                // (reproduced on the previous release as well; covered by the smoke test).
                .environment(store)
                .environment(toastCenter)
        }
    }

    private var appLocale: Locale {
        (AppLanguage(rawValue: store.settings.general.language) ?? .system).locale
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
            Button(L("退出 WeChat AI")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command, .option])
        }

        CommandMenu(L("前往")) {
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
        case .logs: "7"
        case .settings: "0"
        }
    }

    private func openMainWindow() {
        if MainWindowRegistry.show() { return }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
