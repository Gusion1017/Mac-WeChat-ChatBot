import AppKit
import SwiftUI

// MARK: - Main window registry

/// Remembers the main window so it can be hidden and shown again from the menu bar
/// or the Dock without tearing down SwiftUI scene state.
@MainActor
enum MainWindowRegistry {
    static let mainWindowID = "main"

    static weak var window: NSWindow?

    /// 主窗口内容捕获的 SwiftUI `openWindow` 动作。
    ///
    /// 菜单栏快捷面板由 `NSPopover` + `NSHostingController` 承载，不在 SwiftUI Scene
    /// 层级内，环境里的 `openWindow` 不可用；这里复用主场景在 `onAppear` 时捕获的动作，
    /// 以便主窗口尚未创建（或被释放）时仍能从菜单栏打开。
    static var openWindowAction: OpenWindowAction?

    /// Brings the remembered main window back. Returns `false` when the window has
    /// never been created (or was released), letting callers fall back to `openWindow`.
    @discardableResult
    static func show() -> Bool {
        // 主窗口出现时收起菜单栏面板，避免面板悬在刚打开的窗口上方
        // （也覆盖 Dock 重开与 ⌘1…⌘0 页面快捷键）。
        MenuBarController.shared.dismissPanel()
        guard let window else { return false }
        // 先切到 .regular 再显示窗口：Dock 图标/台前调度只认 regular App，
        // 顺序反了窗口会被当成 accessory 窗口，台前调度不接管。
        ActivationPolicyController.presentMainWindow()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// 菜单栏面板 / Dock 重开的统一入口：优先唤回已有窗口，其次重建主场景窗口。
    static func showOrOpen() {
        if show() { return }
        guard let openWindowAction else { return }
        // 窗口对象还不存在时也要先提升激活策略，SwiftUI 创建窗口后才能被台前调度识别。
        ActivationPolicyController.presentMainWindow()
        openWindowAction(id: mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hide() {
        guard let window else { return }
        window.orderOut(nil)
        // 窗口关闭后立即退回仅菜单栏模式；若设置窗口等其它窗口仍可见则保持 .regular。
        ActivationPolicyController.mainWindowDidHide()
    }
}

/// Captures the main scene's `openWindow` action for AppKit-side entry points
/// (the menu bar panel lives outside the SwiftUI scene graph).
private struct MainWindowOpenActionCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            MainWindowRegistry.openWindowAction = openWindow
        }
    }
}

extension View {
    /// Installs the `openWindow` capture used by `MainWindowRegistry.showOrOpen()`.
    func captureMainWindowOpenAction() -> some View {
        modifier(MainWindowOpenActionCapture())
    }
}

// MARK: - Hide instead of close

/// Re-targets the main window's close button at "hide window" and keeps the window
/// object alive, so closing the page leaves the app running in the menu bar.
///
/// `AppDelegate` additionally intercepts ⌘W for the main window; File ▸ Close still
/// uses AppKit's `performClose`, but the window object survives because
/// `isReleasedWhenClosed` is disabled and can be shown again from the menu bar.
struct MainWindowBehavior: NSViewRepresentable {
    @MainActor
    final class Coordinator: NSObject {
        weak var window: NSWindow?
        private var keyObserver: NSObjectProtocol?

        func attach(to window: NSWindow) {
            if self.window === window {
                MainWindowRegistry.window = window
                applyCloseAction(to: window)
                CrashReporter.noteMainWindowPresented()
                return
            }
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
            self.window = window
            window.isReleasedWhenClosed = false
            MainWindowRegistry.window = window
            applyCloseAction(to: window)
            // SwiftUI 场景真正挂载到窗口后记一笔面包屑：崩溃取证时能确认“主窗口已出现”。
            CrashReporter.noteMainWindowPresented()
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor in
                    guard let self, let window else { return }
                    self.applyCloseAction(to: window)
                }
            }
        }

        private func applyCloseAction(to window: NSWindow) {
            guard let close = window.standardWindowButton(.closeButton) else { return }
            close.target = self
            close.action = #selector(hideWindow(_:))
        }

        @objc private func hideWindow(_ sender: Any?) {
            MainWindowRegistry.hide()
        }

        deinit {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachView(frame: .zero)
        view.onWindowAttach = { [coordinator = context.coordinator] window in
            coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }
}

/// Calls back as soon as SwiftUI inserts the representable's view into a window.
@MainActor
private final class WindowAttachView: NSView {
    var onWindowAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowAttach?(window)
        }
    }
}

// MARK: - App delegate

/// Launch-time activation policy (Dock icon), close-to-hide behaviour and the
/// alternate quit shortcut all live on the AppKit delegate.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeShortcutMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动完成：AppKit 自己的顶层异常处理器可能在此前覆盖了 App.init 安装的那次，
        // 这里再装一遍（实测只有 launch 阶段安装的处理器才会被真正调用）。
        CrashReporter.reinstallExceptionHandler(phase: "didFinishLaunching")
        CrashReporter.markPhase(.running)
        CrashReporter.captureSnapshot(reason: "didFinishLaunching", force: true)
        // 主线程看门狗：给「卡顿 → 布局风暴 → 显示周期断言」这条链路留下时间线。
        MainThreadWatchdog.shared.start()

        let settings = SettingsStore.load()
        SleepPreventionCenter.shared.apply(mode: settings.general.sleepPrevention)
        // 启动时 SwiftUI 会展示主窗口，重新确认一次 `.regular`（AppKit 在启动早期
        // 可能把 agent 短暂重置回该策略）。
        ActivationPolicyController.reapplyCurrent()
        // 菜单栏条目依赖 AppKit 完成启动后再创建（依赖已由 `WeChatAIApp.init` 注入）。
        MenuBarController.shared.start()
        closeShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleCloseShortcut(event)
        }
        // LaunchServices/AppKit can reset an accessory app to `.regular` when app or
        // space activation changes; re-assert the desired policy each time.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    ActivationPolicyController.reapplyCurrent()
                }
            })
        }
        // 主窗口/设置窗口的显示与关闭是 Dock 图标与台前调度状态的唯一来源：
        // 任意内容窗口成为 key 时重新核对（例如设置场景从别处被打开），
        // 关闭后等 AppKit 完成收尾再判断是否退回仅菜单栏模式。
        // 注意 NSWindow 只有 `willCloseNotification`；Task 让核对发生在 close 收尾之后。
        let defaultCenter = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(defaultCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let window = notification.object as? NSWindow,
                      ActivationPolicyController.isApplicationWindow(window)
                else { return }
                Task { @MainActor in
                    ActivationPolicyController.windowsDidChange()
                }
            })
        }

        #if DEBUG
        // 诊断自检（仅 DEBUG 二进制）：WECHATAI_CRASHTEST=1 时主动抛一个未捕获异常，
        // 用来验证 crash-*.log 确实被写出。计划任务/正常使用不会设置这个变量。
        if ProcessInfo.processInfo.environment["WECHATAI_CRASHTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSException(
                    name: .internalInconsistencyException,
                    reason: "WECHATAI_CRASHTEST 诊断自检（不是真实故障）",
                    userInfo: nil
                ).raise()
            }
        }
        #endif
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 稳定性：App.init 已安装过安全阀，这里在 AppKit 窗口出现前再确认一次（幂等）。
        AppKitLayoutGuard.install("applicationWillFinishLaunching")
        // AppKit 在启动早期会覆盖 `NSSetUncaughtExceptionHandler`，
        // 必须在这里重新安装，否则未捕获异常处理器不会被调用（macOS 26 实测）。
        // `install()` 幂等：App.init 已装过时只会重装处理器。
        CrashReporter.install()
        CrashReporter.markPhase(.willFinishLaunch)

        // The bundle declares LSUIElement, so the process starts as a menu-bar agent.
        // The main window is presented at launch, so switch to `.regular` here, before
        // the first window appears: the Dock icon is registered and Stage Manager sees
        // a regular app window from the start.
        ActivationPolicyController.presentMainWindowAtLaunch()
    }

    /// Closing the last window hides the page; the app keeps running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock icon click / reopen after the window was hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, MainWindowRegistry.show() else { return false }
        return true
    }

    /// AppKit/LaunchServices can reset an accessory app to `.regular` when it becomes
    /// active (e.g. activating from the menu bar); re-assert the window-derived policy.
    func applicationDidBecomeActive(_ notification: Notification) {
        ActivationPolicyController.reapplyCurrent()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 正常退出：面包屑写 clean-exit（崩溃时不会走到这里，下次启动即可判定硬退出）。
        CrashReporter.noteCleanExit(reason: "applicationWillTerminate")
        MainThreadWatchdog.shared.stop()
        // Drop the idle-sleep assertion explicitly; the process would release it on
        // exit anyway, but this keeps the system state consistent for the whole shutdown.
        SleepPreventionCenter.shared.release()
        if let closeShortcutMonitor {
            NSEvent.removeMonitor(closeShortcutMonitor)
            self.closeShortcutMonitor = nil
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    /// ⌘W hides the main window; secondary windows (Settings, sheets) keep the
    /// standard close behaviour.
    private static func handleCloseShortcut(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w",
              let window = NSApp.keyWindow,
              window === MainWindowRegistry.window
        else { return event }
        MainWindowRegistry.hide()
        return nil
    }
}
