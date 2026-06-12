import SwiftUI
import AppKit

struct BuildImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var contextDir = ""
    @State private var dockerfile = ""
    @State private var tag = ""
    @State private var noCache = false
    @State private var isBuilding = false
    @State private var finished = false
    @State private var output: [LogLine] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill")
                    .foregroundStyle(Color.purple.gradient)
                    .font(.title3)
                Text("Zbuduj obraz")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            // Form
            Form {
                Section {
                    contextDirRow
                    TextField("Dockerfile (opcjonalnie)", text: $dockerfile)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.purple.gradient)
                        Text("Katalog kontekstu")
                    }
                }
                Section {
                    tagRow
                    Toggle("Bez cache", isOn: $noCache)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(Color.gray.gradient)
                        Text("Opcje budowania")
                    }
                }
                if !output.isEmpty {
                    Section {
                        StreamLogBox(lines: output)
                            .frame(minHeight: 160)
                    } header: {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .foregroundStyle(Color.gray.gradient)
                            Text("Postęp")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isBuilding)
            Divider()
            // Footer
            HStack {
                Spacer()
                Button(finished ? "Gotowe" : "Zamknij") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await build() }
                } label: {
                    if isBuilding { ProgressView().controlSize(.small) } else { Text("Zbuduj") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!canBuild)
            }
            .padding(12)
        }
        .frame(width: 620)
    }

    private var canBuild: Bool { !contextDir.isEmpty && !tag.isEmpty && !isBuilding }

    private var contextDirRow: some View {
        HStack(spacing: 6) {
            TextField("Katalog kontekstu", text: $contextDir)
            Button("Wybierz…") { chooseFolder() }
            InfoTip(text: String(localized: "Katalog ze źródłami i Dockerfile. Polecenia COPY/ADD w Dockerfile widzą tylko pliki z tego katalogu."))
        }
    }

    private var tagRow: some View {
        HStack(spacing: 6) {
            TextField("Tag (np. moja-aplikacja:latest)", text: $tag)
            InfoTip(text: String(localized: "Nazwa budowanego obrazu, np. mojaapka:1.0. Bez tagu CLI nada losową nazwę."))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            contextDir = url.path
        }
    }

    private func build() async {
        isBuilding = true
        finished = false
        output = []
        defer { isBuilding = false }

        var args = ["build", "--progress", "plain", "--tag", tag]
        if noCache { args.append("--no-cache") }
        if !dockerfile.isEmpty { args.append(contentsOf: ["--file", dockerfile]) }
        args.append(contextDir)

        let stream = ContainerCLI.shared.stream(args)
        do {
            for try await line in stream {
                output.append(LogLine(text: line))
            }
            finished = true
        } catch {
            output.append(LogLine(text: String(format: String(localized: "[błąd: %@]"), error.localizedDescription)))
        }
        await model.images.refresh()
    }
}
