import SwiftUI
import Sparkle

/// The Settings window: one tab per area, like System Settings' older siblings
/// (Xcode, Mail). Each tab sizes itself; the window follows the selected one.
struct SettingsView: View {
    let updater: SPUUpdater
    @AppStorage("settingsTab") private var tab = Tab.general

    enum Tab: String {
        case general, terminal, virtualMachines, agents, updates, privacy, support
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("Ogólne", systemImage: "gearshape") }
                .tag(Tab.general)
            TerminalSettings()
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(Tab.terminal)
            VirtualMachinesSettings()
                .tabItem { Label("Maszyny wirtualne", systemImage: "pc") }
                .tag(Tab.virtualMachines)
            AgentsSettings()
                .tabItem { Label("Agenci AI", systemImage: "sparkles") }
                .tag(Tab.agents)
            UpdatesSettings(updater: updater)
                .tabItem { Label("Aktualizacje", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.updates)
            PrivacySettings()
                .tabItem { Label("Prywatność", systemImage: "hand.raised") }
                .tag(Tab.privacy)
            SupportSettings()
                .tabItem { Label("Wsparcie", systemImage: "heart") }
                .tag(Tab.support)
        }
    }
}

extension View {
    /// The shared look of a settings tab: a grouped form at the window's width,
    /// with a height chosen for that tab's content.
    func settingsTab(height: CGFloat) -> some View {
        formStyle(.grouped).frame(width: 520, height: height)
    }
}
