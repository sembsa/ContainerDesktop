import AppKit
import SwiftUI

struct LogsView: View {
    let containerID: String

    @State private var lines: [LogLine] = []
    @State private var autoscroll = true
    @State private var showTimestamps = false
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
                LogTextView(
                    lines: lines,
                    showTimestamps: showTimestamps,
                    autoscroll: autoscroll,
                    colorize: true
                )
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 6) {
                        Button {
                            copyAll()
                        } label: {
                            Label("Kopiuj wszystko", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small)
                        .help(String(localized: "Kopiuje wszystkie widoczne linie logu do schowka"))

                        Toggle("Znaczniki czasu", isOn: $showTimestamps)
                            .toggleStyle(.button)
                            .controlSize(.small)

                        Toggle("Autoprzewijanie", isOn: $autoscroll)
                            .toggleStyle(.button)
                            .controlSize(.small)
                    }
                    .padding(8)
                }
            }
        }
        .task(id: containerID) {
            await streamLogs()
        }
    }

    /// Receipt-time timestamp: `container logs` does not emit timestamps, so
    /// lines from the initial backlog all carry the moment they were read.
    private func display(_ line: LogLine) -> String {
        let text = line.text.isEmpty ? " " : line.text
        guard showTimestamps else { return text }
        return "[\(Self.timeFormatter.string(from: line.date))] \(text)"
    }

    private func copyAll() {
        let content = lines.map(display).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

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
    let date = Date()
    let text: String
}
