import AppKit

/// Keeps the running activation policy in sync with the main window's visibility.
///
/// The bundle is a menu-bar agent (`LSUIElement = true`), so its resting state has no
/// Dock icon and no app menu bar. Presenting the main window temporarily promotes the
/// process to `.regular`: that registers the Dock icon and, on macOS 26, lets Stage
/// Manager manage the window. Hiding/closing the window demotes back to `.accessory`,
/// so the Dock icon disappears and only the status item keeps the app reachable.
///
/// `NSApplication.ActivationPolicy` is the only supported way to show/hide the Dock
/// icon at runtime. The window's visibility is the single source of truth: the old
/// `general.showDockIcon` preference has been removed, so a user setting can no longer
/// contradict what the window state implies.
///
/// AppKit/LaunchServices can briefly re-register an accessory app as `.regular` when
/// it is activated (for example by clicking the status item). `reapplyCurrent()`
/// re-asserts the desired policy after app/space activation so the Dock icon does not
/// flash while the app is resting in the menu bar.
@MainActor
enum ActivationPolicyController {
    /// Policy the app should currently have. Re-asserted after AppKit activation
    /// notifications, which can reset a running agent back to `.regular`.
    private(set) static var desiredPolicy: NSApplication.ActivationPolicy = .accessory

    /// Pure mapping between main-window visibility and the AppKit policy.
    ///
    /// Kept free of AppKit calls so the rule is covered by unit tests.
    static func policy(forVisibleWindow isVisible: Bool) -> NSApplication.ActivationPolicy {
        isVisible ? .regular : .accessory
    }

    /// Promotes the app before a window is ordered front.
    ///
    /// Must run before `makeKeyAndOrderFront`: Stage Manager (and the Dock) only
    /// recognizes the window after the process becomes a regular app.
    static func presentMainWindow() {
        apply(.regular)
    }

    /// Called at launch because the main window is presented by SwiftUI at startup.
    static func presentMainWindowAtLaunch() {
        apply(.regular)
    }

    /// Called after the main window has been ordered out.
    ///
    /// Stays `.regular` while another app window (e.g. the Settings scene) is still
    /// visible; otherwise demotes to `.accessory` and yields focus back to the
    /// previously active app.
    static func mainWindowDidHide() {
        reconcileWithVisibleWindows()
    }

    /// Re-checks the window list after a window becomes key or closes.
    static func windowsDidChange() {
        reconcileWithVisibleWindows()
    }

    /// Re-asserts the current policy after app/space activation.
    ///
    /// If a real content window is visible but the desired policy says `.accessory`
    /// (for example the Settings scene was opened by a path that bypassed
    /// `presentMainWindow`), promote instead of hiding the window from the Dock.
    static func reapplyCurrent() {
        if hasVisibleApplicationWindow() {
            desiredPolicy = .regular
        }
        apply(desiredPolicy)
    }

    /// Whether `window` is a normal app content window (main window, Settings, …).
    ///
    /// Panels (popovers, status-bar windows) are excluded: showing the status panel
    /// must not register a Dock icon.
    static func isApplicationWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel) else { return false }
        guard window.styleMask.contains(.titled) else { return false }
        return window.canBecomeMain
    }

    // MARK: - AppKit plumbing

    private static func reconcileWithVisibleWindows() {
        let hasVisibleWindow = hasVisibleApplicationWindow()
        apply(policy(forVisibleWindow: hasVisibleWindow))
        if !hasVisibleWindow, NSApp.isActive {
            // The window was the last visible UI: hide the app so focus returns to the
            // previous app. The status item is not a window and stays in the menu bar.
            NSApp.hide(nil)
        }
    }

    private static func hasVisibleApplicationWindow() -> Bool {
        NSApp.windows.contains { window in
            guard isApplicationWindow(window) else { return false }
            // Miniaturized windows are still open; they must keep the Dock icon.
            return window.isVisible || window.isMiniaturized
        }
    }

    private static func apply(_ policy: NSApplication.ActivationPolicy) {
        desiredPolicy = policy
        guard NSApp.activationPolicy() != policy else { return }
        if !NSApp.setActivationPolicy(policy) {
            // AppKit can refuse mid-window-transaction; retry once on the next turn.
            DispatchQueue.main.async {
                guard NSApp.activationPolicy() != policy else { return }
                NSApp.setActivationPolicy(policy)
            }
        }
    }
}
