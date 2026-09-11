import SwiftUI
import Sparkle

/// Publishes whether the user can currently trigger an update check, so the
/// "Check for Updates…" menu item can enable/disable itself correctly.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// Menu button that triggers a Sparkle update check. Disabled while a check
/// is already in progress. Used both in the app menu (`CommandGroup`) and the
/// menu-bar popover.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater
    /// The app menu wants plain text, as macOS menus do; the menu-bar popover
    /// wants an icon like every other row in it.
    private let systemImage: String?

    init(updater: SPUUpdater, systemImage: String? = nil) {
        self.updater = updater
        self.systemImage = systemImage
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    @ViewBuilder
    var body: some View {
        if let systemImage {
            // Same row treatment as everything else in the popover, hover
            // highlight included.
            Button {
                updater.checkForUpdates()
            } label: {
                Label("Sprawdź aktualizacje…", systemImage: systemImage)
                    .menuBarRow()
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canCheckForUpdates)
        } else {
            Button("Sprawdź aktualizacje…") {
                updater.checkForUpdates()
            }
            .disabled(!viewModel.canCheckForUpdates)
        }
    }
}
