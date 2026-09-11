import SwiftUI
import AppKit
import Sparkle

@main
struct ContainerGUIApp: App {
    @State private var model = AppModel()

    /// Sparkle auto-updater. Starts on launch; feed URL and EdDSA public key
    /// come from Info.plist (SUFeedURL / SUPublicEDKey).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Sparkle schedules its automatic checks relative to the last one, so with the
    /// default one-day interval an app relaunched the same day never checks — a new
    /// release could sit unnoticed until the next day. This asks once per launch,
    /// which is quiet: Sparkle only surfaces UI when there is something to install.
    ///
    /// Delayed a little so the check does not compete with the CLI queries the app
    /// fires at startup.
    @MainActor
    private func checkForUpdatesOnLaunch() async {
        try? await Task.sleep(for: .seconds(3))
        guard updaterController.updater.canCheckForUpdates else { return }
        updaterController.updater.checkForUpdatesInBackground()
    }

    var body: some Scene {
        Window("Container Desktop", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 580)
                .task { await checkForUpdatesOnLaunch() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 720)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
                Button("Co nowego…") {
                    NotificationCenter.default.post(name: WhatsNew.reopenNotification, object: nil)
                }
            }
            CommandGroup(replacing: .help) {
                Button("Pomoc Container Desktop") {
                    NSWorkspace.shared.open(AppDocs.url())
                }
                .keyboardShortcut("?", modifiers: .command)
                Button("Dokumentacja Compose") {
                    NSWorkspace.shared.open(AppDocs.url(anchor: "compose"))
                }
                Button("Zgłoś problem…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/sembsa/ContainerDesktop/issues")!)
                }
            }
        }

        MenuBarExtra {
            MenuBarContent(updater: updaterController.updater)
                .environment(model)
        } label: {
            let iconName: String = {
                switch model.system.serviceState {
                case .running: return "shippingbox.fill"
                case .starting, .stopping: return "shippingbox.circle"
                default: return "shippingbox"
                }
            }()
            // The strip only appears while the service is up and something has
            // actually been measured, so a stopped or idle Mac keeps the plain
            // glyph it has always had.
            let activity = model.system.serviceState.isRunning
                ? model.containers.usageHistory.total.normalised()
                : []
            Image(nsImage: MenuBarIcon.image(symbolName: iconName, activity: activity))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
