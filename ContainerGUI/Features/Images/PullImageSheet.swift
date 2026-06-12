import SwiftUI

struct PullImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var reference = ""
    @State private var isPulling = false
    @State private var finished = false
    @State private var output: [LogLine] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Color.purple.gradient)
                    .font(.title3)
                Text("Pobierz obraz")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            // Form
            Form {
                Section {
                    HStack(spacing: 6) {
                        TextField("np. docker.io/library/nginx:latest", text: $reference)
                            .disabled(isPulling)
                            .onSubmit { if canPull { Task { await pull() } } }
                        InfoTip(text: String(localized: "Format: [rejestr/]repozytorium[:tag], np. nginx:latest albo ghcr.io/uzytkownik/app:1.0. Bez rejestru → docker.io, bez taga → latest."))
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .foregroundStyle(Color.purple.gradient)
                        Text("Referencja obrazu")
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
            Divider()
            // Footer
            HStack {
                Spacer()
                Button(finished ? "Gotowe" : "Zamknij") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await pull() }
                } label: {
                    if isPulling { ProgressView().controlSize(.small) } else { Text("Pobierz") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!canPull)
            }
            .padding(12)
        }
        .frame(width: 580)
    }

    private var canPull: Bool { !reference.isEmpty && !isPulling }

    private func pull() async {
        isPulling = true
        finished = false
        output = []
        defer { isPulling = false }

        let stream = ContainerCLI.shared.stream(["image", "pull", "--progress", "plain", reference])
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

/// Scrolling, autoscrolled, monospaced output box used by streaming sheets.
/// Backed by LogTextView: continuous selection + log-level colorizing.
struct StreamLogBox: View {
    let lines: [LogLine]

    var body: some View {
        LogTextView(lines: lines, showTimestamps: false, autoscroll: true, colorize: true)
            .frame(maxHeight: .infinity)
    }
}
