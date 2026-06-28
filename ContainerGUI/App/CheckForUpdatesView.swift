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

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Sprawdź aktualizacje…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
