import AppKit
import SwiftUI

// MARK: - Main window registry

/// Remembers the main window so it can be hidden and shown again from the menu bar
/// or the Dock without tearing down SwiftUI scene state.
@MainActor
enum MainWindowRegistry {
    static weak var window: NSWindow?

    /// Brings the remembered main window back. Returns `false` when the window has
    /// never been created (or was released), letting callers fall back to `openWindow`.
    @discardableResult
    static func show() -> Bool {
        guard let window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ActivationPolicyController.reapplyCurrent()
        return true
    }

    static func hide() {
        window?.orderOut(nil)
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
                return
            }
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
            self.window = window
            window.isReleasedWhenClosed = false
            MainWindowRegistry.window = window
            applyCloseAction(to: window)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore.load()
        SleepPreventionCenter.shared.apply(mode: settings.general.sleepPrevention)
        // Re-assert the persisted Dock preference once the run loop is up; AppKit can
        // briefly re-register a menu-bar agent as `.regular` during launch.
        ActivationPolicyController.reapplyCurrent()
        closeShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleCloseShortcut(event)
        }
        // LaunchServices/AppKit can reset an accessory app to `.regular` when app or
        // space activation changes; re-assert the persisted preference each time.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    ActivationPolicyController.reapplyCurrent()
                }
            })
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The bundle declares LSUIElement, so it starts as a menu-bar agent; applying
        // the preference here shows a regular Dock icon before the first window appears
        // when the setting is on. It also re-asserts a hidden Dock icon at launch.
        ActivationPolicyController.applyNow(
            showDockIcon: SettingsStore.load().general.showDockIcon
        )
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
    /// active (e.g. reopening from Finder); re-assert the persisted Dock preference.
    func applicationDidBecomeActive(_ notification: Notification) {
        ActivationPolicyController.reapplyCurrent()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
