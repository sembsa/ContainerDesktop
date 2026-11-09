import SwiftUI
import Sparkle

/// The tabs that hold a single control or two — too small for a file each.

struct TerminalSettings: View {
    @AppStorage(TerminalEngine.storageKey) private var terminalEngine = TerminalEngine.default.rawValue

    var body: some View {
        Form {
            Section {
                Picker(selection: $terminalEngine) {
                    ForEach(TerminalEngine.allCases) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                } label: {
                    Text("Silnik terminala")
                }
            } footer: {
                Text("Ghostty rysuje przez Metal — ostrzejszy tekst, ligatury i emoji. Jego API do wbudowywania nie jest jeszcze ustabilizowane, dlatego domyślny pozostaje SwiftTerm. Zmiana dotyczy nowo otwieranych terminali.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsTab(height: 170)
    }
}

struct UpdatesSettings: View {
    let updater: SPUUpdater

    var body: some View {
        Form {
            Section {
                LabeledContent("Wersja") {
                    Text(verbatim: RootView.appVersion)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                CheckForUpdatesView(updater: updater)
                    .buttonStyle(.glass)
            }
        }
        .settingsTab(height: 150)
    }
}

struct PrivacySettings: View {
    /// Stored as an opt-*out* so that the absent default — `false` — means the
    /// statistics are on, which is what a fresh install should do.
    @AppStorage(InstallIdentifier.optOutKey) private var metricsOptOut = false

    var body: some View {
        Form {
            Section {
                Toggle("Anonimowe statystyki", isOn: metricsEnabled)
            } footer: {
                Text("Przy sprawdzaniu aktualizacji wysyłany jest losowy identyfikator instalacji, wersja programu i wersja macOS — tyle, by policzyć, ilu ludzi używa programu i jakiej wersji. Nie wysyłamy adresu IP, nazwy komputera ani niczego, co wskazuje na Ciebie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsTab(height: 170)
    }

    private var metricsEnabled: Binding<Bool> {
        Binding(get: { !metricsOptOut }, set: { metricsOptOut = !$0 })
    }
}

struct SupportSettings: View {
    var body: some View {
        Form {
            Section {
                Link(destination: AppDocs.support) {
                    Label("Postaw kawę na Ko-fi", systemImage: "cup.and.saucer.fill")
                }
                Link(destination: AppDocs.sponsors) {
                    Label("Sponsoruj na GitHubie", systemImage: "heart.fill")
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Color.pink.gradient)
                    Text("Wspomóż projekt")
                }
            } footer: {
                Text("Container Desktop jest darmowy i taki zostanie. Jeśli oszczędza Ci czas, możesz wesprzeć jego rozwój.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsTab(height: 210)
    }
}
