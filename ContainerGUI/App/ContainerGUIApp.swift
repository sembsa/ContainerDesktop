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

    /// MenuBarExtra ignores SwiftUI `.font` on its label, so size the status
    /// item glyph explicitly via an NSImage symbol configuration. The image is
    /// capped to the menu bar grid (~17 pt tall) — anything taller gets clipped
    /// and glitches when the status item highlights on click.
    private static func menuBarIcon(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Container Desktop")?
            .withSymbolConfiguration(config) ?? NSImage()
        let maxHeight: CGFloat = 17
        if image.size.height > maxHeight, image.size.height > 0 {
            let ratio = maxHeight / image.size.height
            image.size = NSSize(width: image.size.width * ratio, height: maxHeight)
        }
        image.isTemplate = true
        return image
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
            Image(nsImage: Self.menuBarIcon(iconName))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
