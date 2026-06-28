import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var binaryPath = BinaryResolver.overridePath ?? ""
    @AppStorage("appLanguageOverride") private var languageOverride = "system"
    @State private var showRelaunchNote = false

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
