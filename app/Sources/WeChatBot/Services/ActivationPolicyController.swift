import AppKit
import SwiftUI

/// Applies the `general.showDockIcon` preference to the running app.
///
/// `NSApplication.ActivationPolicy` is the only supported way to hide/show the Dock
/// icon at runtime: `.regular` shows it, `.accessory` hides it (menu-bar-only mode).
/// The distribution bundle declares `LSUIElement` so it starts as a menu-bar agent;
/// `AppDelegate.applicationWillFinishLaunching` promotes it to `.regular` only when the
/// persisted preference is on. Without `LSUIElement`, AppKit/LaunchServices can flip a
/// hidden app back to `.regular` when it is activated from the menu bar.
///
/// The preference is applied once at launch (`AppDelegate`) and then kept in sync
/// through `ActivationPolicySync` whenever the switch changes.
///
/// The user preference is authoritative: Stage Manager must never turn a hidden Dock
/// icon back on. While Stage Manager is enabled an accessory app cannot join the Stage
/// Manager app strip, so the window is reopened from the menu bar instead; the Settings
/// UI explains that trade-off.
@MainActor
enum ActivationPolicyController {
    /// Last preference applied through this controller. Used to restore the policy
    /// after AppKit/LaunchServices activates the app (which can reset it to `.regular`).
    private(set) static var desiredShowDockIcon = true

    /// Pure mapping between the persisted preference and the AppKit policy.
    static func policy(showDockIcon: Bool) -> NSApplication.ActivationPolicy {
        showDockIcon ? .regular : .accessory
    }

    /// Applies the policy on the next main run-loop turn.
    ///
    /// Deferring keeps the AppKit call out of the middle of a SwiftUI view update, and
    /// the generation token drops stale requests when the switch is flipped quickly.
    static func apply(showDockIcon: Bool) {
        desiredShowDockIcon = showDockIcon
        generation &+= 1
        let token = generation
        DispatchQueue.main.async {
            guard token == generation else { return }
            applyEffectivePolicy()
        }
    }

    /// Applies the policy immediately. Used during launch and from `apply`.
    static func applyNow(showDockIcon: Bool) {
        desiredShowDockIcon = showDockIcon
        applyEffectivePolicy()
    }

    /// Re-asserts the policy after app/space activation.
    ///
    /// Even with `LSUIElement`, AppKit can briefly re-register the app as `.regular`
    /// during activation; the delayed second pass catches that late flip without
    /// fighting the user's toggle.
    static func reapplyCurrent() {
        applyEffectivePolicy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            applyEffectivePolicy()
        }
    }

    private static func applyEffectivePolicy() {
        let desired = policy(showDockIcon: desiredShowDockIcon)
        guard NSApp.activationPolicy() != desired else { return }
        if !NSApp.setActivationPolicy(desired) {
            // AppKit can refuse mid-window-transaction; retry once on the next turn.
            DispatchQueue.main.async {
                guard NSApp.activationPolicy() != desired else { return }
                NSApp.setActivationPolicy(desired)
            }
        }
        if desired == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static var generation = 0
}

// MARK: - Stage Manager

/// Read-only probe for the system Stage Manager preference
/// (`com.apple.WindowManager` → `GloballyEnabled`).
///
/// Used only for the informational notice in Settings. It deliberately does not feed
/// into the activation policy: a hidden Dock icon must stay hidden even with Stage
/// Manager enabled.
enum StageManagerSupport {
    static var isEnabled: Bool {
        let domain = "com.apple.WindowManager" as CFString
        let key = "GloballyEnabled" as CFString
        if let value = CFPreferencesCopyAppValue(key, domain) {
            if let number = value as? NSNumber { return number.boolValue }
            if let bool = value as? Bool { return bool }
        }
        return UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }
}

// MARK: - SwiftUI sync

/// Keeps the running activation policy in sync with `showDockIcon`.
///
/// Attached to both the main window and the Settings scene so the preference applies
/// no matter which window is open when it is changed.
private struct ActivationPolicySync: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content
            .onAppear {
                ActivationPolicyController.applyNow(
                    showDockIcon: store.settings.general.showDockIcon
                )
            }
            .onChange(of: store.settings.general.showDockIcon) { _, newValue in
                ActivationPolicyController.apply(showDockIcon: newValue)
            }
    }
}

extension View {
    /// Mirrors `general.showDockIcon` into the app's activation policy.
    func syncActivationPolicy() -> some View {
        modifier(ActivationPolicySync())
    }
}
