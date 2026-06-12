import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var binaryPath = BinaryResolver.overridePath ?? ""

    var body: some View {
        @Bindable var model = model

        Form {
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
