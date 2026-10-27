import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// Applies the `general.sleepPrevention` preference to the power-management system.
///
/// The centre owns at most one `kIOPMAssertionTypePreventUserIdleSystemSleep`
/// assertion. It is created when the user's preference plus the current power source
/// require keeping the system awake, and released as soon as either changes.
///
/// Scope: only *idle system sleep* is prevented. Closing the lid, choosing
/// "Sleep" from the Apple menu, or letting the display sleep are unaffected.
///
/// The class is `@MainActor` because it feeds SwiftUI state and the power-source run
/// loop source is registered on the main run loop. `apply(mode:)` is idempotent and is
/// called from `AppDelegate` at launch, from the settings UI on appear/change, and from
/// the IOKit power-source callback.
@MainActor
@Observable
final class SleepPreventionCenter {
    static let shared = SleepPreventionCenter()

    /// Last mode applied through this centre.
    private(set) var mode: SleepPreventionMode = .never
    /// `true` while an idle-sleep assertion is held.
    private(set) var isPreventingSleep = false
    /// Whether the Mac is currently running on an external power adapter. Desktops
    /// without a battery report `true` (treated like AC power so the feature keeps
    /// working on a Mac mini / Mac Studio).
    private(set) var isOnExternalPower = true
    /// Human-readable description of the last assertion/monitor failure, if any.
    private(set) var lastError: String?

    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var isHoldingAssertion = false
    @ObservationIgnored private var powerSourceRunLoopSource: CFRunLoopSource?
    @ObservationIgnored private var isObservingPowerSource = false
    /// 机器人运行时才需要防睡眠：停止机器人后即使偏好是「始终」，也应释放断言，
    /// 否则整机在闲置时无法进入睡眠（笔记本待机功耗从 ~0.1W 升至数瓦）。
    @ObservationIgnored private var runtimeActive = false

    private static let assertionReason = "WeChat AI 正在运行，按设置防止系统空闲睡眠"

    init() {}

    // MARK: - Pure decision logic

    /// Whether an idle-sleep assertion should be held for the given preference and
    /// power source. Kept pure so it can be unit-tested without touching IOKit.
    nonisolated static func shouldPreventSleep(
        mode: SleepPreventionMode,
        onExternalPower: Bool
    ) -> Bool {
        switch mode {
        case .never:
            false
        case .externalPowerOnly:
            onExternalPower
        case .always:
            true
        }
    }

    // MARK: - Public control

    /// Applies `mode`: refreshes the power source, then creates or releases the
    /// assertion as needed. Safe to call repeatedly; only real state transitions touch
    /// IOKit.
    func apply(mode newMode: SleepPreventionMode) {
        mode = newMode
        startObservingPowerSourceIfNeeded()
        refreshPowerSource()
        evaluate()
        // 关闭功能后不再展示上一次持有断言失败的旧错误。
        if newMode == .never { lastError = nil }
    }

    /// 机器人启动/停止时更新「运行时是否活跃」。停止机器人后释放断言，
    /// 重新启动时按当前偏好恢复（用户偏好本身不变）。
    func setRuntimeActive(_ active: Bool) {
        guard runtimeActive != active else { return }
        runtimeActive = active
        startObservingPowerSourceIfNeeded()
        evaluate()
    }

    /// Re-reads the current power source (AC / battery). A `nil` result — desktops and
    /// any transient IOKit failure — is treated as external power.
    func refreshPowerSource() {
        isOnExternalPower = Self.currentlyOnExternalPower()
    }

    /// Releases the assertion without changing the saved preference/settings.
    /// Called from `applicationWillTerminate`.
    func release() {
        releaseAssertion()
        lastError = nil
    }

    // MARK: - Power source

    private nonisolated static func currentlyOnExternalPower() -> Bool {
        guard let sourceType = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String? else {
            // No power-source info: desktop Mac or a transient IOKit failure. Treating
            // it as external power keeps `.externalPowerOnly` useful instead of never
            // engaging on machines without a battery.
            return true
        }
        return sourceType == kIOPSACPowerValue
    }

    private func evaluate() {
        let shouldPrevent = runtimeActive
            && Self.shouldPreventSleep(mode: mode, onExternalPower: isOnExternalPower)
        if shouldPrevent {
            acquireAssertionIfNeeded()
        } else {
            releaseAssertion()
        }
        isPreventingSleep = isHoldingAssertion
    }

    private func handlePowerSourceChange() {
        refreshPowerSource()
        evaluate()
    }

    // MARK: - IOKit power-source notifications

    private func startObservingPowerSourceIfNeeded() {
        guard !isObservingPowerSource else { return }
        isObservingPowerSource = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let center = Unmanaged<SleepPreventionCenter>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                center.handlePowerSourceChange()
            }
        }

        guard let runLoopSource = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            isObservingPowerSource = false
            lastError = "无法注册电源状态监听，插拔电源后不会自动刷新防睡眠状态。"
            return
        }

        powerSourceRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    // MARK: - Assertion lifecycle

    private func acquireAssertionIfNeeded() {
        guard !isHoldingAssertion, assertionID == 0 else { return }

        var newAssertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionReason as CFString,
            &newAssertionID
        )

        guard result == kIOReturnSuccess else {
            assertionID = 0
            isHoldingAssertion = false
            lastError = "创建防睡眠断言失败（错误码 \(result)），系统仍可能进入空闲睡眠。"
            return
        }

        assertionID = newAssertionID
        isHoldingAssertion = true
        lastError = nil
    }

    private func releaseAssertion() {
        guard isHoldingAssertion || assertionID != 0 else {
            isPreventingSleep = false
            return
        }

        let result = IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHoldingAssertion = false
        isPreventingSleep = false

        if result == kIOReturnSuccess {
            lastError = nil
        } else {
            lastError = "释放防睡眠断言失败（错误码 \(result)）。"
        }
    }
}
