import SwiftUI
import AppKit

/// Shown when the `container` binary cannot be found. Lets the user locate it
/// manually or open the install page.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Nie znaleziono narzędzia container")
                .font(.title2.bold())

            Text("Aplikacja jest nakładką na narzędzie wiersza poleceń Apple container. Zainstaluj je lub wskaż lokalizację pliku wykonywalnego.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)

            HStack(spacing: 12) {
                Button("Wskaż plik…") { locateBinary() }
                    .buttonStyle(.borderedProminent)

                Link("Strona projektu", destination: URL(string: "https://github.com/apple/container")!)
                    .buttonStyle(.bordered)
            }

            Text("Szukane lokalizacje: /usr/local/bin/container, /opt/homebrew/bin/container")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func locateBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Wskaż plik wykonywalny container")
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            BinaryResolver.overridePath = url.path
            Task { await model.bootstrap() }
        }
    }
}
