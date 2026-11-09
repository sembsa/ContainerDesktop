import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var binaryPath = BinaryResolver.overridePath ?? ""
    @AppStorage("appLanguageOverride") private var languageOverride = "system"
    @AppStorage(TerminalEngine.storageKey) private var terminalEngine = TerminalEngine.default.rawValue
    /// Stored as an opt-*out* so that the absent default — `false` — means the
    /// statistics are on, which is what a fresh install should do.
    @AppStorage(InstallIdentifier.optOutKey) private var metricsOptOut = false
    @State private var showRelaunchNote = false
    @State private var mcpBusy = false
    @State private var mcpMessage: String?
    @State private var mcpFailed = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker(selection: $languageOverride) {
                    Text("System").tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "中文").tag("zh-Hans")
                    Text(verbatim: "Polski").tag("pl")
                } label: {
                    Text("Język aplikacji")
                }
                if showRelaunchNote {
                    HStack(spacing: 8) {
                        Text("Zmiana języka zacznie obowiązywać po ponownym uruchomieniu aplikacji.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Uruchom ponownie") { relaunch() }
                            .controlSize(.small)
                    }
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .foregroundStyle(Color.indigo.gradient)
                    Text("Język")
                }
            }

            Section {
                HStack(spacing: 6) {
                    TextField("Ścieżka pliku wykonywalnego", text: $binaryPath)
                    Button("Wybierz…") { choose() }
                    InfoTip(text: String(localized: "Domyślnie przeszukiwane są /usr/local/bin/container i /opt/homebrew/bin/container. Wskaż własną lokalizację, jeśli zainstalowałeś narzędzie gdzie indziej."))
                }
                LabeledContent("Wykryta ścieżka") {
                    HStack(spacing: 6) {
                        if let resolved = BinaryResolver.resolve() {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(resolved)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text("nie znaleziono")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(Color.blue.gradient)
                    Text("Narzędzie container")
                }
            }

            Section {
                Picker(selection: $terminalEngine) {
                    ForEach(TerminalEngine.allCases) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Silnik terminala")
                        InfoTip(text: String(localized: "Ghostty rysuje przez Metal — ostrzejszy tekst, ligatury i emoji. Jego API do wbudowywania nie jest jeszcze ustabilizowane, dlatego domyślny pozostaje SwiftTerm. Zmiana dotyczy nowo otwieranych terminali."))
                    }
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "apple.terminal.fill")
                        .foregroundStyle(Color.teal.gradient)
                    Text("Terminal")
                }
            }

            Section {
                LabeledContent("Ścieżka pomocnika") {
                    HStack(spacing: 6) {
                        if FileManager.default.isExecutableFile(atPath: MCPSetup.helperPath) {
                            Text(verbatim: MCPSetup.helperPath)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text("nie znaleziono")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("Dodaj do Claude Code") {
                        mcpBusy = true
                        Task {
                            let outcome = await MCPSetup.addToClaudeCode()
                            mcpMessage = outcome.message
                            mcpFailed = !outcome.ok
                            mcpBusy = false
                        }
                    }
                    .disabled(mcpBusy)
                    Button("Kopiuj konfigurację") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MCPSetup.configSnippet(helperPath: MCPSetup.helperPath), forType: .string)
                        mcpMessage = String(localized: "Skopiowano konfigurację do schowka.")
                        mcpFailed = false
                    }
                    if mcpBusy { ProgressView().controlSize(.small) }
                }
                if let mcpMessage {
                    Text(verbatim: mcpMessage)
                        .font(.caption)
                        .foregroundStyle(mcpFailed ? .red : .secondary)
                        .textSelection(.enabled)
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.purple.gradient)
                    Text("Agenci AI (MCP)")
                }
            } footer: {
                Text("Agenci AI (Claude Code, Codex, Cursor…) mogą zarządzać kontenerami, obrazami, wolumenami, sieciami i maszynami przez serwer MCP wbudowany w aplikację. Działa bez otwartego okna programu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(
                    value: $model.pollInterval,
                    in: 1...30,
                    step: 1
                ) {
                    Text("Co \(Int(model.pollInterval)) s")
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(Color.gray.gradient)
                    Text("Odświeżanie")
                }
            }

            Section {
                Toggle("Anonimowe statystyki", isOn: metricsEnabled)
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(Color.indigo.gradient)
                    Text("Prywatność")
                }
            } footer: {
                Text("Przy sprawdzaniu aktualizacji wysyłany jest losowy identyfikator instalacji, wersja programu i wersja macOS — tyle, by policzyć, ilu ludzi używa programu i jakiej wersji. Nie wysyłamy adresu IP, nazwy komputera ani niczego, co wskazuje na Ciebie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: binaryPath) { _, newValue in
            BinaryResolver.overridePath = newValue.isEmpty ? nil : newValue
            Task { await model.bootstrap() }
        }
        .onChange(of: languageOverride) { _, newValue in
            applyLanguage(newValue)
            showRelaunchNote = true
        }
    }

    private var metricsEnabled: Binding<Bool> {
        Binding(get: { !metricsOptOut }, set: { metricsOptOut = !$0 })
    }

    /// Overrides (or clears) the app's UI language by writing `AppleLanguages`.
    /// Takes effect on next launch.
    private func applyLanguage(_ code: String) {
        let defaults = UserDefaults.standard
        if code == "system" {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([code], forKey: "AppleLanguages")
        }
    }

    /// Relaunches the app so the language change takes effect immediately.
    private func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            binaryPath = url.path
        }
    }
}
