import SwiftUI

/// Root window: custom glass sidebar plus the routed detail page.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 216, ideal: Theme.sidebarWidth, max: 286)
        } detail: {
            PageRouter(item: store.sidebarSelection ?? .dashboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .background(PageBackground())
        .background(MainWindowBehavior())
        .frame(minWidth: 1100, minHeight: 720)
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: $store.isOnboardingPresented) {
            OnboardingView()
                .environment(store)
        }
        .onAppear {
            if !hasCompletedOnboarding {
                store.isOnboardingPresented = true
            }
        }
        .toastOverlay()
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: store.sidebarSelection)
    }

    private var preferredScheme: ColorScheme? {
        switch store.settings.general.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Routes the sidebar selection to its page. Keeps the switch in one place so
/// commands, the menu bar and onboarding can all drive navigation through the store.
struct PageRouter: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .dashboard: DashboardView()
        case .conversations: ConversationsView()
        case .bot: BotView()
        case .ai: AIModelsView()
        case .personas: PersonasView()
        case .memory: MemoryView()
        case .schedules: SchedulesView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}
