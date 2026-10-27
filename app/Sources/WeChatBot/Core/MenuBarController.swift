import AppKit
import Observation
import SwiftUI

/// 菜单栏图标的点击意图。
///
/// 抽成纯映射方便单测：SwiftUI 的 `MenuBarExtra` 无法区分左右键，所以菜单栏改用
/// `NSStatusItem` 承载，由本枚举决定点击后是开合状态面板，还是什么都不做。
enum MenuBarClickIntent: Equatable {
    /// 左键单击：开合状态面板（面板内提供「打开主窗口」等全部入口）。
    case togglePanel
    /// 右键单击 / Control-左键：不执行操作（已移除右键菜单）。
    case ignore

    static func resolve(
        eventType: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags
    ) -> MenuBarClickIntent {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        switch eventType {
        case .rightMouseDown, .rightMouseUp:
            return .ignore
        case .leftMouseDown, .leftMouseUp:
            return flags.contains(.control) ? .ignore : .togglePanel
        default:
            // VoiceOver / 键盘触发时没有鼠标事件，按左键语义处理。
            return .togglePanel
        }
    }
}

/// 状态栏图标在当前运行状态下使用的模板图标。
///
/// 只切换 SF Symbol 的填充/轮廓，不叠加颜色或状态点：模板图由系统按菜单栏亮度
/// 自动着色，浅色/深色/强调色菜单栏都能正确显示，也不需要为图标额外跑动画。
enum MenuBarIconState: Equatable {
    case running
    case idle

    init(isBotRunning: Bool) {
        self = isBotRunning ? .running : .idle
    }

    var symbolName: String {
        switch self {
        case .running: "bubble.left.and.bubble.right.fill"
        case .idle: "bubble.left.and.bubble.right"
        }
    }

    /// 图标的无障碍值：VoiceOver 聚焦时能直接听出机器人是否在运行。
    var accessibilityValue: String {
        switch self {
        case .running: L("机器人运行中")
        case .idle: L("机器人已停止")
        }
    }
}

/// 菜单栏图标与状态面板的 AppKit 控制器。
///
/// 行为约定：
/// - 左键单击图标：开合 `MenuBarView` 状态面板（面板内可打开主窗口、启停机器人、直达页面、退出）；
/// - 右键 / Control-左键：不执行操作（不弹菜单）；
/// - 面板使用 `.transient`：点面板外（含其它 App / 桌面）由系统自动收起；
///   本 App 内的点击由 local 监视器立即收起，另监听 Esc、应用失活/隐藏与系统菜单开始跟踪。
///   不使用 `clickCount`、双击或时间窗等启发式；
/// - 面板首次弹出后缓存复用；语言变化或隐藏菜单栏图标时释放；
/// - `settings.general.showInMenuBar` 变化时实时增删状态栏条目。
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    /// 首次点开时创建，关闭后保留复用；语言变化/隐藏菜单栏图标时丢弃。
    private var panel: NSPopover?
    /// 逻辑上的「面板正在显示」。比 `panel.isShown` 早一个动画帧更新，
    /// 用于点击开合与图标高亮，不受关闭动画影响。
    private var panelIsShown = false
    /// 关闭动画尚未结束时用户又点了图标：等 `popoverDidClose` 后再重开。
    private var pendingShow = false
    private var panelLanguage: String?
    private var escapeKeyMonitor: Any?
    private var localClickMonitor: Any?
    private var dismissObservers: [NSObjectProtocol] = []
    /// 常驻的图标鼠标监视器：左键开合面板；右键 / Control-左键在事件分发前被吞掉，
    /// 不触发任何操作。
    private var statusItemMouseMonitor: Any?
    private var prewarmTask: Task<Void, Never>?
    private weak var store: AppStore?
    private var hasStarted = false
    private var currentIconState: MenuBarIconState?
    /// 最近一次写入图标/无障碍文案时的界面语言，用于语言切换后刷新辅助功能描述。
    private var chromeLanguage: String?

    private override init() {
        super.init()
    }

    /// 由 `WeChatAIApp.init` 注入 store 并开始观察显示开关；此时还不创建状态栏条目。
    func configure(store: AppStore) {
        self.store = store
        observeMenuBarVisibility()
        observeIconState()
    }

    /// 由 `AppDelegate.applicationDidFinishLaunching` 调用，确保状态栏在 AppKit 启动完成后出现。
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        syncVisibility()
    }

    /// 从 AppKit 的其它入口（例如 Dock 重开）收起面板。
    func dismissPanel() {
        closePanel()
    }

    // MARK: - Visibility

    private func observeMenuBarVisibility() {
        guard let store else { return }
        withObservationTracking {
            _ = store.settings.general.showInMenuBar
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncVisibility()
                self.observeMenuBarVisibility()
            }
        }
    }

    /// 观察图标状态与语言：只在机器人启停/语言切换时刷新状态栏，不引入定时器。
    private func observeIconState() {
        guard let store else { return }
        withObservationTracking {
            _ = store.isBotRunning
            _ = store.settings.general.language
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshStatusItem()
                self.observeIconState()
            }
        }
    }

    private func syncVisibility() {
        guard hasStarted, let store else { return }
        if store.settings.general.showInMenuBar {
            installStatusItemIfNeeded()
        } else {
            removeStatusItem()
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 只响应左键按下；右键 / Control-左键由常驻监视器吞掉且不执行操作。
            button.sendAction(on: [.leftMouseDown])
            button.setAccessibilityLabel("WeChat AI")
        }
        statusItem = item
        currentIconState = nil
        refreshStatusItem()
        installStatusItemMouseMonitor()
        // 首屏点开前预构建一次缓存面板，避免第一次弹出时在系统动画中同步构建 SwiftUI 树。
        schedulePanelPrewarm()
    }

    private func removeStatusItem() {
        removeStatusItemMouseMonitor()
        prewarmTask?.cancel()
        prewarmTask = nil
        pendingShow = false
        discardPanel()
        currentIconState = nil
        chromeLanguage = nil
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    // MARK: - Status item chrome

    private func refreshStatusItem() {
        guard let store else { return }
        let state = MenuBarIconState(isBotRunning: store.isBotRunning)
        let language = L10n.language
        let stateChanged = currentIconState != state
        let languageChanged = chromeLanguage != language

        if let button = statusItem?.button {
            if stateChanged || button.image == nil {
                currentIconState = state
                let image = NSImage(
                    systemSymbolName: state.symbolName,
                    accessibilityDescription: "WeChat AI"
                )
                image?.isTemplate = true
                button.image = image
            }
            if stateChanged || languageChanged || button.image == nil {
                button.setAccessibilityValue(state.accessibilityValue)
            }
            // 只设置辅助功能帮助，不设置 button.toolTip：菜单栏图标不显示鼠标悬停提示。
            button.setAccessibilityHelp(accessibilityHelp(for: state))
            chromeLanguage = language
        }

        // 语言切换后，缓存面板里的文案与尺寸已经过期，立即丢弃并在空闲时重建，
        // 避免用户下次点开时在弹出动画里同步重建 SwiftUI 树。
        if panel != nil, panelLanguage != L10n.language {
            discardPanel()
            schedulePanelPrewarm()
        }
    }

    /// VoiceOver 聚焦状态栏图标时朗读的交互说明；不会弹出鼠标悬停 tooltip。
    private func accessibilityHelp(for state: MenuBarIconState) -> String {
        "\(state.accessibilityValue) · \(L("左键打开状态面板"))"
    }

    // MARK: - Click handling

    /// 状态栏图标的鼠标点击在事件分发前拦截并自己处理。
    ///
    /// - 左键：立即开合面板并吞掉事件，避免 `.transient` 的系统自动收起与按钮 action
    ///   各处理一次，造成“关掉又立刻打开”；
    /// - 右键 / Control-左键：吞掉事件、什么都不做（已移除右键菜单）。
    ///
    /// 按钮 action 仍保留给 VoiceOver `performClick` 等非鼠标路径。
    /// 该监视器只在状态栏图标存在期间安装，仅检查状态栏按钮范围内的事件。
    private func installStatusItemMouseMonitor() {
        guard statusItemMouseMonitor == nil else { return }
        statusItemMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard self.isStatusItemClick(event) else { return event }
            let intent = MenuBarClickIntent.resolve(
                eventType: event.type,
                modifiers: event.modifierFlags
            )
            switch intent {
            case .togglePanel:
                self.togglePanel()
            case .ignore:
                break
            }
            return nil
        }
    }

    private func removeStatusItemMouseMonitor() {
        guard let statusItemMouseMonitor else { return }
        NSEvent.removeMonitor(statusItemMouseMonitor)
        self.statusItemMouseMonitor = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let intent = MenuBarClickIntent.resolve(
            eventType: event?.type ?? .leftMouseDown,
            modifiers: event?.modifierFlags ?? []
        )
        switch intent {
        case .togglePanel:
            togglePanel()
        case .ignore:
            break
        }
    }

    private func togglePanel() {
        if panelIsShown {
            closePanel()
            return
        }
        // 关闭动画还没播完时再次点击：等关闭回调后再重开，避免 show 被系统忽略。
        if let panel, panel.isShown {
            pendingShow = true
            return
        }
        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem?.button,
              let store
        else { return }

        // 用户已经主动打开：取消尚未完成的预热。
        prewarmTask?.cancel()
        prewarmTask = nil
        pendingShow = false

        // 语言切换后旧面板的文案/排版已过期，丢弃缓存并重建。
        if panelLanguage != L10n.language {
            discardPanel()
        }

        if panel == nil {
            panel = makePanel(store: store)
        }
        guard let panel else { return }

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panelIsShown = true
        button.highlight(true)
        installDismissMonitoring()
    }

    private func closePanel() {
        pendingShow = false
        removeDismissMonitoring()
        statusItem?.button?.highlight(false)
        guard panelIsShown else { return }
        panelIsShown = false
        panel?.performClose(nil)
    }

    /// 释放缓存的弹层（隐藏菜单栏图标、语言切换时）。
    private func discardPanel() {
        prewarmTask?.cancel()
        prewarmTask = nil
        pendingShow = false
        removeDismissMonitoring()
        if let panel {
            panel.delegate = nil
            if panel.isShown { panel.close() }
        }
        panel = nil
        panelIsShown = false
        panelLanguage = nil
        statusItem?.button?.highlight(false)
    }

    // MARK: - Dismiss monitoring

    private func installDismissMonitoring() {
        installEscapeKeyMonitor()
        installClickMonitor()
        installDismissObservers()
    }

    private func removeDismissMonitoring() {
        removeEscapeKeyMonitor()
        removeClickMonitor()
        removeDismissObservers()
    }

    /// NSPopover 不保证把 Esc 转成关闭动作；面板没有输入框，Esc 直接收起符合预期。
    private func installEscapeKeyMonitor() {
        guard escapeKeyMonitor == nil else { return }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
            return nil
        }
    }

    private func removeEscapeKeyMonitor() {
        guard let escapeKeyMonitor else { return }
        NSEvent.removeMonitor(escapeKeyMonitor)
        self.escapeKeyMonitor = nil
    }

    /// 本 App 内其它窗口上的点击立即收起面板；其它 App / 桌面由 `.transient` 系统收起。
    ///
    /// 状态栏图标本身的点击由常驻监视器处理；这里只同步鼠标松开后的按下态。
    private func installClickMonitor() {
        guard localClickMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp,
        ]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if self.isStatusItemClick(event) {
                if event.type == .leftMouseUp || event.type == .rightMouseUp {
                    self.statusItem?.button?.highlight(self.panelIsShown)
                }
                return event
            }
            if self.isClickInsidePanel(event) { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self.closePanel()
            }
            return event
        }
    }

    private func removeClickMonitor() {
        guard let localClickMonitor else { return }
        NSEvent.removeMonitor(localClickMonitor)
        self.localClickMonitor = nil
    }

    /// 应用失活、系统菜单开始跟踪时收起；覆盖 Cmd-Tab、点其它状态栏图标、
    /// 应用菜单栏等不经过本 App 鼠标事件的路径。
    private func installDismissObservers() {
        guard dismissObservers.isEmpty else { return }
        let center = NotificationCenter.default

        dismissObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        })

        dismissObservers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        })

        // ⌘H 隐藏应用时面板会随应用一起隐藏；不收起的话再次显示应用时会留下旧面板。
        dismissObservers.append(center.addObserver(
            forName: NSApplication.didHideNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        })
    }

    private func removeDismissObservers() {
        guard !dismissObservers.isEmpty else { return }
        for observer in dismissObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        dismissObservers.removeAll()
    }

    private func isClickInsidePanel(_ event: NSEvent) -> Bool {
        guard let panelWindow = panel?.contentViewController?.view.window else { return false }
        if let eventWindow = event.window {
            return eventWindow === panelWindow
        }
        return panelWindow.frame.contains(NSEvent.mouseLocation)
    }

    private func isStatusItemClick(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button,
              let statusWindow = button.window
        else { return false }
        if event.window === statusWindow {
            return true
        }
        // 少数事件路径下 event.window 不是状态栏窗口，用屏幕坐标兜底。
        let buttonFrame = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonFrame.contains(NSEvent.mouseLocation)
    }

    // MARK: - Prewarm

    /// 状态栏图标出现后延迟预构建缓存面板。
    ///
    /// 第一次点开如果现建 SwiftUI 树 + 测量尺寸，正好叠在 NSPopover 的弹出动画上，
    /// 在部分机器上会看到明显掉帧；预热后首屏直接复用已渲染好的面板。
    private func schedulePanelPrewarm() {
        guard panel == nil,
              statusItem != nil,
              let store,
              store.settings.general.showInMenuBar
        else { return }

        prewarmTask?.cancel()
        prewarmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  let self,
                  self.panel == nil,
                  self.statusItem != nil,
                  let store = self.store,
                  store.settings.general.showInMenuBar
            else { return }
            self.panel = self.makePanel(store: store)
            self.prewarmTask = nil
        }
    }

    private func makePanel(store: AppStore) -> NSPopover {
        let popover = NSPopover()
        // `.transient` 由系统负责“点面板外即收起”（含其它 App / 桌面），
        // 不依赖需要辅助功能权限的全局事件监视器；图标自身点击已在上面的
        // 常驻监视器里吞掉，不会被系统自动收起干扰。
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let content = MenuBarView(onNavigate: { [weak self] in
            self?.closePanel()
        })
        .environment(store)
        .environment(\.locale, Locale(identifier: L10n.language))

        let hosting = NSHostingController(rootView: content)
        // 固定 contentSize：数据刷新（余额、统计、电量）不再触发 popover 自动重排，
        // 开合与面板内更新都更稳。语言切换会丢弃并重建，所以不会留下过期高度。
        hosting.sizingOptions = []
        popover.contentViewController = hosting

        // 预热阶段就把 SwiftUI 布局跑完，首屏 show 时不再同步测量。
        // 注意：`sizingOptions = []` 时离屏 `fittingSize` 恒为 0，必须用 `sizeThatFits(in:)`。
        let fitted = hosting.sizeThatFits(
            in: NSSize(width: MenuBarPanelLayout.width, height: CGFloat.greatestFiniteMagnitude)
        )
        // 兜底高度：正常情况下 `sizeThatFits` 一定能算出高度；若 SwiftUI 尚未完成布局，
        // 宁可给一个足够放下全部内容的默认高度，也不要让 popover 以 0 尺寸出现。
        let height = fitted.height > 0 ? ceil(fitted.height) : 360
        popover.contentSize = NSSize(width: MenuBarPanelLayout.width, height: height)
        panelLanguage = L10n.language
        return popover
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // 面板对象保留复用；只重置「正在显示」状态。`discardPanel()` 会先清空
        // `panel` 并移除 delegate，因此这条分支不会误清理新面板。
        guard let closed = notification.object as? NSPopover,
              panel === closed
        else { return }
        panelIsShown = false
        removeDismissMonitoring()
        statusItem?.button?.highlight(false)
        if pendingShow {
            pendingShow = false
            Task { @MainActor [weak self] in
                self?.showPanel()
            }
        }
    }
}
