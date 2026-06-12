import SwiftUI

struct LogsView: View {
    let containerID: String

    @State private var lines: [LogLine] = []
    @State private var autoscroll = true
    @State private var streamEnded = false

    var body: some View {
        Group {
            if lines.isEmpty && streamEnded {
                EmptyStateView(
                    symbol: "doc.text",
                    title: String(localized: "Brak logów"),
                    message: String(localized: "Kontener nie wypisał nic na stdout/stderr. Kontenery typu `sleep` nie generują logów."),
                    tint: .blue
                )
            } else if lines.isEmpty && !streamEnded {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Wczytywanie logów…")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: lines.count) {
                        guard autoscroll, let last = lines.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Toggle("Autoprzewijanie", isOn: $autoscroll)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .padding(8)
                }
            }
        }
        .task(id: containerID) {
            await streamLogs()
        }
    }

    private func streamLogs() async {
        lines = []
        streamEnded = false
        let stream = ContainerCLI.shared.stream(["logs", "--follow", containerID])
        do {
            for try await line in stream {
                lines.append(LogLine(text: line))
                if lines.count > 2000 {
                    lines.removeFirst(lines.count - 2000)
                }
            }
        } catch {
            lines.append(LogLine(text: String(format: String(localized: "[błąd strumienia logów: %@]"), error.localizedDescription)))
        }
        streamEnded = true
    }
}

struct LogLine: Identifiable, Hashable {
    let id = UUID()
    let text: String
}
